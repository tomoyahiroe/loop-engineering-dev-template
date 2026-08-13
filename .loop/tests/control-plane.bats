#!/usr/bin/env bats
# コントロールプレーン（観測 UI）のテスト。
#
# 重点は 3 つ:
#   1. 127.0.0.1 にしか bind しないこと（compose が network_mode: host なので、
#      ここが崩れると同一 LAN の全員に Issue とトークン消費量が見える）
#   2. 状態を変える経路がないこと（GET 以外を断る）
#   3. gh が落ちても 500 にせず、取れた分は返すこと

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"

  # 実運用の 7717 とぶつからず、かつテストどうしでも衝突しないポートを使う。
  # 前のテストの kill は非同期なので、全テストで同じポートを使い回すと
  # まだ掴んでいるソケットに当たって EADDRINUSE で落ちることがある
  PORT=$((7791 + BATS_TEST_NUMBER))

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
  chmod +x "$BATS_TEST_DIRNAME/fixtures/ccusage/"*.sh

  SERVER_PID=""
}

teardown() {
  # ポート番号を頼りに落とす。bats はテスト本体を teardown とは別のサブシェルで
  # 走らせるため、テスト内で代入した PID は teardown から見えない。一方 PORT は
  # setup で決まるので確実に参照できる。
  # 落とし損ねると、ソケットを掴んだままのサーバが積み上がり、次の実行が
  # 前回の残骸（別の fixture を見ている）に問い合わせて謎の失敗が並ぶ
  local pids i=0
  pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    while [ "$i" -lt 30 ] && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; do
      sleep 0.1
      i=$((i + 1))
    done
    pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  fi
  cleanup_test_repo
  rm -rf "$TMP"
}

# サーバを起動して待つ。
#
# 3>&- が必須。bats は FD 3 を自分の出力に使っており、常駐する子プロセスが
# それを継承したままだとテストが終わったと判定できず、スイート全体がハングする
# （stdout/stderr をファイルに向けるだけでは足りない）
start_server() {
  # ポートが既に埋まっていたら即座に失敗させる。ここを黙って進むと、
  # 前の実行が残したサーバ（別の fixture を見ている）に問い合わせて
  # しまい、原因の分からない失敗が並ぶ
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ポート $PORT が既に使用中。前の実行のサーバが残っている可能性がある"
    return 1
  fi

  "$LOOP_REAL_DIR/bin/control-plane" --port "$PORT" > "$TMP/server.log" 2>&1 3>&- &
  SERVER_PID=$!
  local i=0
  while [ "$i" -lt 50 ]; do
    # 自分が起動したプロセスが生きていることを毎回確認する。
    # 死んでいるのに疎通するなら、それは他人のサーバ
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "サーバが終了した:"; cat "$TMP/server.log"
      return 1
    fi
    curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/api/events" 2>/dev/null && return 0
    sleep 0.2
    i=$((i + 1))
  done
  echo "サーバが起動しない:"; cat "$TMP/server.log"
  return 1
}

get() { curl -sS --max-time 20 "http://127.0.0.1:$PORT$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

# --- bind 先 ---------------------------------------------------------------

@test "127.0.0.1 で待ち受ける" {
  start_server
  run get /api/events
  [ "$status" -eq 0 ]
  [[ "$output" == *'"events"'* ]]
}

@test "0.0.0.0 では待ち受けない（LAN に開かない）" {
  # ホストの LAN IP から繋がらないことを直接確かめる。IP が取れない
  # 環境ではスキップする（CI 等）
  local ip
  ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [ -n "$ip" ] || skip "LAN IP を取得できない環境"

  start_server
  run curl -sS -o /dev/null --max-time 3 "http://$ip:$PORT/api/events"
  [ "$status" -ne 0 ]
}

@test "bind 先はソースで固定されていて設定から変えられない" {
  # 「127.0.0.1 に bind する」を設定可能にすると、いつか 0.0.0.0 が
  # 書かれる。ソースに固定されていることを機械的に守る
  run grep -c "const HOST = '127.0.0.1'" "$LOOP_REAL_DIR/lib/control-plane-cli.mjs"
  [ "$output" -eq 1 ]
  # 文字列リテラルとしての 0.0.0.0 が無いこと。説明コメント中の言及は
  # 引っかけない（ここを素朴に grep すると、危険性を説明した注意書きの
  # せいでテストが落ちる）
  run grep -cE "['\"]0\.0\.0\.0['\"]" "$LOOP_REAL_DIR/lib/control-plane-cli.mjs"
  [ "$output" -eq 0 ]
  # listen が HOST 以外を渡していないこと
  run grep -c "server.listen(PORT, HOST" "$LOOP_REAL_DIR/lib/control-plane-cli.mjs"
  [ "$output" -eq 1 ]
}

# --- 読み取り専用 -----------------------------------------------------------

@test "GET 以外は 405 で断る" {
  start_server
  for m in POST PUT DELETE PATCH; do
    run code -X "$m" "http://127.0.0.1:$PORT/api/status"
    [ "$output" = "405" ] || { echo "$m が $output を返した"; false; }
  done
}

# --- パスの正規化 -----------------------------------------------------------

@test "loops/runs の外を指すファイル名を拒否する" {
  start_server
  run code "http://127.0.0.1:$PORT/api/runs/..%2f..%2f..%2fetc%2fpasswd"
  [ "$output" = "400" ]
  run code "http://127.0.0.1:$PORT/api/runs/%2e%2e%2fconfig.toml"
  [ "$output" = "400" ]
}

@test "静的配信でも web ディレクトリの外に出られない" {
  start_server
  run code "http://127.0.0.1:$PORT/..%2fconfig.toml"
  [ "$output" = "400" ]
}

@test "loops/runs のファイルは読める" {
  printf '結論: approve\n' > "$REPO_ROOT/loops/runs/2026-08-12-verifier-pr-3.md"
  start_server
  run get "/api/runs/2026-08-12-verifier-pr-3.md"
  [[ "$output" == *"approve"* ]]
}

@test ".md 以外は拒否する" {
  printf 'secret\n' > "$REPO_ROOT/loops/runs/note.txt"
  start_server
  run code "http://127.0.0.1:$PORT/api/runs/note.txt"
  [ "$output" = "400" ]
}

# --- 集約 -------------------------------------------------------------------

@test "/api/status が maturity と budget と発火時刻を返す" {
  printf 'maturity = "L2"\n' > "$LOOP_DIR/config.toml"
  start_server
  run get /api/status
  [[ "$output" == *'"maturity":"L2"'* ]]
  [[ "$output" == *'"used":'* ]]
  [[ "$output" == *'"limit":'* ]]
  # gen-crontab の既定（1 時起点・12 回/日）
  [[ "$output" == *'"hours":[1,3,5'* ]]
}

@test "/api/issues が needs-human と ready を分けて返す" {
  export GH_ISSUE_LIST_JSON='[
    {"number":3,"title":"c","url":"u3","labels":[{"name":"needs-human"}]},
    {"number":2,"title":"b","url":"u2","labels":[{"name":"loop:ready"}]},
    {"number":9,"title":"i","url":"u9","labels":[]}]'
  start_server
  run get /api/issues
  [[ "$output" == *'"needs_human":[{"number":3'* ]]
  [[ "$output" == *'"ready":[{"number":2'* ]]
  [[ "$output" == *'"other":[{"number":9'* ]]
}

@test "ループが作った PR だけを数える" {
  export GH_PR_LIST_JSON='[
    {"number":1,"title":"a","headRefName":"loop/issue-5"},
    {"number":2,"title":"b","headRefName":"feature/manual"}]'
  start_server
  run get /api/status
  [[ "$output" == *'"open":1'* ]]
}

@test "/api/events が新しい順で limit を尊重する" {
  source "$LOOP_REAL_DIR/lib/common.sh"
  record_event idle
  record_event dispatch "issue=7"
  start_server
  run get "/api/events?limit=1"
  [[ "$output" == *'"kind":"dispatch"'* ]]
  [[ "$output" != *'"idle"'* ]]
}

@test "events.jsonl がまだ無くてもエラーにならない（初回 firing 前）" {
  start_server
  run get /api/events
  [ "$output" = '{"events":[]}' ]
}

# --- 壊れたときの振る舞い ---------------------------------------------------

@test "gh が落ちても 500 にせず、取れた分を返して errors に理由を入れる" {
  # GitHub が一時的に不調なだけで UI 全体が真っ白になるのは観測手段として
  # 質が悪い。budget と maturity はローカルで取れるので必ず返す
  export GH_EXIT=1
  start_server
  run code "http://127.0.0.1:$PORT/api/status"
  [ "$output" = "200" ]

  run get /api/status
  [[ "$output" == *'"maturity"'* ]]
  [[ "$output" == *'"used":'* ]]
  [[ "$output" == *'"open":null'* ]]
  [[ "$output" == *"取得できません"* ]]
}

@test "budget-check が非 0 でも SKIP の理由を返す（予算切れこそ見たい）" {
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"
  printf '[budget]\ndaily_tokens = 1\n' > "$LOOP_DIR/config.toml"
  start_server
  run code "http://127.0.0.1:$PORT/api/status"
  [ "$output" = "200" ]
  run get /api/status
  [[ "$output" == *'"blocked":true'* ]]
  [[ "$output" == *'"reason":"'* ]]
}

@test "不明な API エンドポイントは 404" {
  start_server
  run code "http://127.0.0.1:$PORT/api/nope"
  [ "$output" = "404" ]
}

@test "画面の kind 表示名が events.mjs の KINDS を網羅している" {
  # 網羅が崩れても画面は生の kind を出すだけで壊れないが、
  # 日本語の表示名が付かないまま気づかれない状態が続く。
  # 値域を増やしたら画面も更新する、を機械的に守る
  local known ui missing
  known="$(node -e 'import(process.argv[1]).then(m=>console.log(m.KINDS.join("\n")))' \
           "$LOOP_REAL_DIR/lib/events.mjs" | sort -u)"
  [ -n "$known" ] || { echo "KINDS を取り出せない"; false; }

  # KIND_LABEL のキーだけを抜く（值はここでは見ない）
  ui="$(sed -n '/^const KIND_LABEL = {/,/^};/p' "$LOOP_REAL_DIR/web/app.js" \
        | grep -oE '^  [a-z_]+:' | tr -d ' :' | sort -u)"
  [ -n "$ui" ] || { echo "app.js から KIND_LABEL のキーを抽出できない"; false; }

  missing="$(comm -23 <(echo "$known") <(echo "$ui"))"
  [ -z "$missing" ] || { echo "画面に表示名がない kind: $missing"; false; }
}

@test "画面が読む API のパスがすべてサーバに実在する" {
  local used p
  used="$(grep -oE "getJson\('/api/[a-z]+" "$LOOP_REAL_DIR/web/app.js" \
          | sed "s/getJson('//" | sort -u)"
  [ -n "$used" ] || { echo "app.js から API パスを抽出できない"; false; }
  while read -r p; do
    [ -n "$p" ] || continue
    grep -q "p === '$p'" "$LOOP_REAL_DIR/lib/control-plane-cli.mjs" \
      || { echo "app.js が叩く $p がサーバに無い"; false; }
  done <<< "$used"
}

@test "静的ファイルを配信する" {
  # web/ はコードの所在から引く（テンプレート所有のため）。fixture 側には
  # 置かないので、中身ではなく配信できていることを見る
  start_server
  run code "http://127.0.0.1:$PORT/"
  [ "$output" = "200" ]
  run curl -sS -o /dev/null -w '%{content_type}' --max-time 20 "http://127.0.0.1:$PORT/"
  [[ "$output" == *"text/html"* ]]
}
