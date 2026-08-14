#!/usr/bin/env bash
# crontab を config から生成して supercronic を起動する
set -uo pipefail

# 引数付きで起動された場合（docker compose run --rm loop <cmd> や
# --entrypoint を使わない one-off 実行）は、常駐ループを起動せず
# その場でコマンドを実行して終了する。ENTRYPOINT を exec 形式にしている
# ため、これを入れないと <cmd> は黙って無視されて常駐ループが起動して
# しまう（docker compose run --rm loop bash -lc '...' が返ってこない、
# という壊れ方をする）。harness 自体が壊れていてもデバッグ用に bash 等を
# 起動できるよう、以降のどのチェックよりも先に評価する。
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

REPO_ROOT="${REPO_ROOT:-$PWD}"
CRONTAB=/tmp/loop.crontab
LOOP_DIR="$REPO_ROOT/.loop"

# エラーメッセージを揃えて出し、非0で終了する共通処理。
# $1 = 一行目のエラー概要、$2以降 = 続く行（原因・対処）
fail() {
  local summary="$1"; shift
  local line
  echo "======================================================================" >&2
  echo "ERROR: $summary" >&2
  for line in "$@"; do
    echo "$line" >&2
  done
  echo "======================================================================" >&2
  exit 1
}

if [ ! -x "$LOOP_DIR/bin/gen-crontab" ]; then
  fail "$LOOP_DIR/bin/gen-crontab が見つかりません。ループを起動できません。" \
    "考えられる原因:" \
    "  - docker compose をリポジトリのルート以外（例: docker/ ディレクトリの中）から起動した" \
    "    → \${PWD} は「docker compose を実行したシェルのカレントディレクトリ」に展開されます。" \
    "      必ずリポジトリのルートで次のように実行してください:" \
    "        cd <リポジトリのルート> && docker compose -f docker/compose.yml up -d" \
    "  - docker/compose.yml の working_dir とホストのマウント先の絶対パスが一致していない" \
    "  - このリポジトリに .loop（dev-loop ハーネス）が入っていない、または壊れている" \
    "  - REPO_ROOT 環境変数が誤ったパスを指している（現在値: ${REPO_ROOT}）"
fi

NODE_MODULES_DIR="$LOOP_DIR/node_modules"
LOCK_FILE="$LOOP_DIR/package-lock.json"

NEED_INSTALL=0
if [ ! -d "$NODE_MODULES_DIR" ]; then
  NEED_INSTALL=1
elif [ -f "$LOCK_FILE" ] && [ "$LOCK_FILE" -nt "$NODE_MODULES_DIR" ]; then
  # package-lock.json が node_modules より新しい（git pull 等で更新された）
  NEED_INSTALL=1
  echo "package-lock.json が更新されているため .loop の依存を入れ直します"
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
  echo "セットアップ: .loop の依存をインストールします"
  if ! ( cd "$LOOP_DIR" && npm ci --omit=dev ); then
    # 失敗した node_modules を残すと、次回起動時に「ディレクトリはある」
    # という理由だけでインストール済み扱いされ、二度とリトライされない。
    # 必ず削除して、再起動時にこの分岐へもう一度入れるようにする。
    rm -rf "$NODE_MODULES_DIR"
    fail "$LOOP_DIR で npm ci が失敗しました。依存をインストールできません。" \
      "loop は起動できません（不完全な状態で起動を続けると、設定が読めない" \
      "ことが単なる『非数値』として丸められ、原因不明のまま既定スケジュールで" \
      "動き続けてしまうため、ここで止めています）。" \
      "よくある原因: ネットワーク未接続・レジストリ到達不可、" \
      "package.json と package-lock.json の不整合、npm キャッシュ/権限の問題" \
      "対処: 上のログで原因を確認して直してから" \
      "docker compose up -d --force-recreate loop で再起動してください" \
      "（node_modules は削除済みなので、再起動すれば最初からやり直します）"
  fi
fi

# harness が実際に動くかを、cron を起動する前に確認する（smoke check）。
# npm ci 自体が成功しても、実行時 import で落ちるような壊れた依存が
# 入ることがあり、それを確認せずに cron を起動すると gen-crontab が
# 「設定が読めない」を「非数値」として丸めてしまい、原因が全く見えない
# まま意図しない既定スケジュールで動き続ける（このタスクで見つかった
# 一番まずい壊れ方）。
if ! SMOKE_OUT="$("$LOOP_DIR/bin/loop-config" get maturity 2>&1)"; then
  fail "$LOOP_DIR の動作確認に失敗しました（loop-config get maturity が失敗）。" \
    "依存はインストールされているように見えますが、設定を読み込めません。" \
    "loop-config の出力: $SMOKE_OUT" \
    "よくある原因: node_modules が壊れている、.loop/defaults.toml が壊れている、" \
    "LOOP_DIR/REPO_ROOT が誤っている" \
    "対処: docker compose down してから、ホスト側で .loop/node_modules を削除し、" \
    "docker compose up -d --force-recreate loop で入れ直してください"
fi

# CLAUDE_CONFIG_DIR を volume の中に向ける前から動いている環境のための移行。
# 旧レイアウトでは ~/.claude.json だけが volume の外にあり、コンテナを
# 作り直すと消えていた。まだ移していなければ 1 回だけ引き継ぐ。
# 上書きはしない（新しい側が正）
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f /root/.claude.json ] \
   && [ ! -f "$CLAUDE_CONFIG_DIR/.claude.json" ]; then
  mkdir -p "$CLAUDE_CONFIG_DIR"
  if cp /root/.claude.json "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null; then
    echo "Claude の設定を $CLAUDE_CONFIG_DIR/.claude.json へ引き継ぎました"
  fi
fi

"$LOOP_DIR/bin/gen-crontab" > "$CRONTAB"
echo "生成した crontab:"
cat "$CRONTAB"

# コントロールプレーン（観測 UI）を同居させる。service は増やさない。
#
# ここでの失敗は cron を止めない。UI は観測手段であって、ループ本体の
# 動作条件ではない。逆に UI が落ちてもループは回り続ける必要がある。
#
# -x の確認を挟むのは、entrypoint.sh だけ新しくて .loop/bin/control-plane が
# まだ無い派生プロジェクトでも起動できるようにするため。テンプレート同期
# （P5）が未実装の間は、この組み合わせが実際に起こり得る。
if [ -x "$LOOP_DIR/bin/control-plane" ]; then
  UI_PORT="$("$LOOP_DIR/bin/loop-config" get ui.port 2>/dev/null || echo 7717)"
  # 出力はコンテナの stdout に流す。docker logs を 1 か所見れば
  # cron と UI の両方が分かる（起動行とエラーしか出さないので埋もれない）
  "$LOOP_DIR/bin/control-plane" &
  echo "コントロールプレーン: http://127.0.0.1:${UI_PORT}"
else
  echo "注意: $LOOP_DIR/bin/control-plane が無いため観測 UI なしで続行します" >&2
fi

exec supercronic -passthrough-logs "$CRONTAB"
