# shellcheck shell=bash
# すべての .loop/bin/* から source される共通ヘルパー。
# コードの所在(LIB_DIR)と設定の所在(LOOP_DIR)を分けている。
# テストは実物のコードで fixture の設定を使えるように LOOP_DIR / REPO_ROOT を上書きする。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="${LOOP_DIR:-$(cd "$LIB_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$LIB_DIR/../.." && pwd)}"
export LOOP_DIR REPO_ROOT

# bash 5.2+ は既定で patsub_replacement が有効で、${var/pat/repl} の repl 中の
# & をマッチした文字列（sed の & と同じ意味）として展開してしまう。
# render_prompt が値に & を含むケース（例: "cd a && b"）を壊さないよう、
# source された時点で一度だけ無効化する（shopt はプロセス全体に効き、関数に
# スコープされないため、render_prompt 内ではなくここで固定する）。
# bash 3.2 にはこのオプション自体が無いのでエラーを握りつぶす
shopt -u patsub_replacement 2>/dev/null || true

# 設定値を 1 つ取り出す。未定義なら終了コード 1
cfg() {
  LOOP_DIR="$LOOP_DIR" "$LIB_DIR/../bin/loop-config" get "$1"
}

# loops/STATE.md の末尾に 1 行追記する
record_state() {
  printf -- '- %s: %s\n' "$(date +%Y-%m-%d)" "$1" >> "$REPO_ROOT/loops/STATE.md"
}

# 一過性エラー（DNS/接続系）の判定。$1 = 実行ログのパス
is_transient_error() {
  [ -f "$1" ] || return 1
  grep -qiE 'ENOTFOUND|ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|getaddrinfo|fetch failed' "$1"
}

retry_delay() {
  cfg retry.delay_seconds
}

# [project] の test/lint を実行できるツール許可があるかを確認する。
# 許可がなければ 1 を返す（呼び出し側は起動を拒否する）。
#
# なぜ必要か: maker.md / verifier.md / fixer.md は {{TEST_CMD}} / {{LINT_CMD}}
# を「完了条件」として埋め込むが、claude provider の --allowedTools は
# defaults.toml の tools_maker / tools_verifier / tools_fixer から組み立てられ、
# そこには git/gh の Bash しかない。プロジェクトのツールチェーン
# （pnpm/npx/make 等）は agents.claude.extra_tools に足さない限り実行できない。
# 足し忘れたまま起動すると、Verifier は 1 つもテストを実行できないまま diff
# だけを読んで approve する — ハーネスの主要な品質シグナルが「エラーにならず
# 静かに」無効化される。無人で回る以上、人間が気付く手立てが無いので、
# 起動前に落として理由を伝える。
#
# 判定は「導出」ではなく「拒否」にしてある。設定されたコマンドから許可リストを
# 自動生成すると、誤った導出がエージェントに意図より広い権限を与えかねない
# （許可リストは無人実行の唯一の安全境界）。extra_tools に何か 1 つでも
# 書かれていれば「人間が意図して設定した」とみなして通す。
require_project_tools_allowed() {
  local provider extra test_cmd lint_cmd marker
  provider="$(cfg agent.provider 2>/dev/null || echo '')"
  # 許可リストの意味論は provider 固有（agents/claude.sh のコメント参照）。
  # extra_tools を読まない provider（テスト用の mock 等）には適用しない
  [ "$provider" = "claude" ] || return 0

  marker="$REPO_ROOT/loops/.tools-misconfig"
  extra="$(cfg agents.claude.extra_tools 2>/dev/null || echo '')"
  test_cmd="$(cfg project.test 2>/dev/null || echo '')"
  lint_cmd="$(cfg project.lint 2>/dev/null || echo '')"

  if [ -n "$extra" ] || { [ -z "$test_cmd" ] && [ -z "$lint_cmd" ]; }; then
    # 設定が直った（または test/lint を持たないプロジェクト）。次に壊れたとき
    # また 1 回だけ報告できるよう、マーカーを片付けてから通す
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi

  echo "REFUSED: [project] の test/lint を実行できるツール許可がありません。"
  echo "  .loop/config.toml の [agents.claude] extra_tools に、そのコマンドを"
  echo "  実行できる Bash 許可を追加してください。"
  echo "  例: extra_tools = [\"Bash(pnpm:*)\", \"Bash(npx:*)\", \"Bash(node:*)\"]"
  echo "  test/lint を持たないプロジェクトなら [project] の test / lint を \"\" にしてください。"
  echo "  現在の設定: test=\"$test_cmd\" lint=\"$lint_cmd\" extra_tools=（空）"

  # 設定ミスは tick を跨いでも自然には直らない持続的な原因なので、STATE.md
  # （人間が毎朝読む一次情報）への記録はローカルマーカーで 1 回に抑える
  # （gate-remediation・L3 merge 失敗と同じ方式）。原則も同じ:
  # 「以後の報告を抑制する操作（マーカー作成）は informative な手より後」
  if [ ! -f "$marker" ]; then
    record_state "dispatch 中止: [project] の test/lint を実行するツール許可がない（[agents.claude] extra_tools が空）"
    touch "$marker" 2>/dev/null || true
  fi
  return 1
}

# --- worktree の所有権マーカー ----------------------------------------------
# cleanup-merged は無人で worktree とブランチを消すが、「まだ 1 度もコミット
# していない Maker の worktree」は main と同じ内容・完全にクリーンなので、
# 放置された残骸と見分けが付かない（実行中の Maker ごと消される。
# turns.maker = 120 の実行は発火間隔 2 時間を超え得るため現実に起きる）。
# dispatcher が実行中だけ所有権を主張できるようにする。
#
# 判定材料はこのリポジトリが所有するローカルなファイルだけで完結させる
# （GitHub 側の状態には一切依存しない）。マーカーの中身は所有者の PID で、
# 参照側は kill -0 で生存を確認する。SIGKILL でマーカーが残っても PID が
# 死んでいれば所有権は失効するので、片付けが永久に止まることはない。
wt_owner_file() { # $1 = キー（"loop/issue-5" でも "issue-5" でも可）
  printf '%s/loops/.wt-owner-%s' "$REPO_ROOT" "${1#loop/}"
}

claim_worktree() { # $1 = キー
  printf '%s\n' "$$" > "$(wt_owner_file "$1")" 2>/dev/null || true
}

release_worktree() { # $1 = キー
  rm -f "$(wt_owner_file "$1")" 2>/dev/null || true
}

# 生きた所有者がいるか。マーカーが壊れている等で判断できない場合は
# 「所有されている」= 触らない側に倒す（cleanup-merged の中心的な原則）
worktree_is_claimed() { # $1 = キー
  local f pid
  f="$(wt_owner_file "$1")"
  [ -f "$f" ] || return 1
  pid="$(head -1 "$f" 2>/dev/null)"
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# テンプレートの {{KEY}} を置換して標準出力する。
# bash のパターン置換を使うので、値に / & \ が含まれても壊れない（sed との違い）
render_prompt() {
  local tpl="$1"; shift
  local out pair k v
  out="$(cat "$tpl")"
  for pair in "$@"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    out="${out//\{\{$k\}\}/$v}"
  done
  printf '%s\n' "$out"
}
