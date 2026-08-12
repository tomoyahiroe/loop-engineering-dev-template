#!/usr/bin/env bats
# loops/events.jsonl（コントロールプレーンが読む機械向けの記録）のテスト。
#
# 最重要は「firing が渡す kind」と「events.mjs の KINDS」の双方向照合。
# 値域と配線がズレたまま気づかないのが、このハーネスで最も高くつくバグの型
# （P1 の /loop-status 集計ズレ、firing の .retry.md 除外漏れと同じ形）。

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  source "$LOOP_REAL_DIR/lib/common.sh"
  CLI="$LOOP_REAL_DIR/lib/events-cli.mjs"
  LOG="$REPO_ROOT/loops/events.jsonl"
}

teardown() { cleanup_test_repo; rm -rf "$TMP"; }

# 追記された JSON から 1 つのキーを取り出す（行番号は 1 始まり、末尾から数える）
ev_field() {
  REPO_ROOT="$REPO_ROOT" node "$CLI" tail --limit "${2:-1}" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const a=JSON.parse(s); const v=a[a.length-1]?.["'"$1"'"];
  process.stdout.write(v===undefined?"":String(v));})'
}

# --- 値域と配線の照合（最重要） --------------------------------------------

@test "firing が渡す kind はすべて events.mjs の KINDS に含まれる" {
  local used known missing
  used="$(grep -oE 'record_event [a-z_]+' "$LOOP_REAL_DIR/bin/firing" \
          | awk '{print $2}' | sort -u)"
  # 抽出が空回りしていないこと。過去 2 回（cc0be7c, 65fbf46）、この種の
  # 照合が空集合どうしの比較になっていて常に通っていたバグを踏んでいる
  [ -n "$used" ] || { echo "firing から record_event の呼び出しを抽出できない"; false; }

  known="$(node -e 'import(process.argv[1]).then(m=>console.log(m.KINDS.join("\n")))' \
           "$LOOP_REAL_DIR/lib/events.mjs" | sort -u)"
  [ -n "$known" ] || { echo "events.mjs から KINDS を取り出せない"; false; }

  missing="$(comm -23 <(echo "$used") <(echo "$known"))"
  [ -z "$missing" ] || { echo "firing が使うが KINDS にない kind: $missing"; false; }
}

@test "KINDS のうち firing が配線していないものがない" {
  # 逆向き。値域だけ増やして配線を忘れるのを防ぐ
  local used known unused
  used="$(grep -oE 'record_event [a-z_]+' "$LOOP_REAL_DIR/bin/firing" \
          | awk '{print $2}' | sort -u)"
  [ -n "$used" ] || { echo "firing から record_event の呼び出しを抽出できない"; false; }

  known="$(node -e 'import(process.argv[1]).then(m=>console.log(m.KINDS.join("\n")))' \
           "$LOOP_REAL_DIR/lib/events.mjs" | sort -u)"
  [ -n "$known" ] || { echo "events.mjs から KINDS を取り出せない"; false; }

  unused="$(comm -13 <(echo "$used") <(echo "$known"))"
  [ -z "$unused" ] || { echo "KINDS にあるが firing が配線していない kind: $unused"; false; }
}

@test "未知の kind は終了コード 2 で落ちる（配線ミスを黙って飲まない）" {
  run env REPO_ROOT="$REPO_ROOT" node "$CLI" append --kind bogus_kind
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown kind"* ]]
  [ ! -f "$LOG" ]
}

# --- 1 行の組み立て --------------------------------------------------------

@test "record_event が events.jsonl に 1 行追記する" {
  record_event idle
  [ -f "$LOG" ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
  run ev_field kind
  [ "$output" = "idle" ]
}

@test "ts はオフセット付きの ISO 8601 になる（date -Is は BSD date にない）" {
  record_event idle
  run ev_field ts
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]
}

@test "複数行を含む gate_out を渡しても jsonl が 1 行に収まる" {
  # loop-gate の出力は複数行。bash で JSON を組むとここで壊れる
  record_event gate_failed "issue=7" "gate_out=NG: 1 行目
2 行目に \"引用符\"
3 行目"
  [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
  run ev_field gate_out
  [[ "$output" == *"2 行目に \"引用符\""* ]]
}

@test "値に = が含まれても最初の = だけで分割する" {
  record_event skip "reason=budget" "msg=SKIP: a=b=c"
  run ev_field msg
  [ "$output" = "SKIP: a=b=c" ]
}

@test "宣言された数値フィールドだけ数値になり、自由文は文字列のまま" {
  record_event dispatch "issue=42" "maturity=L2"
  run env REPO_ROOT="$REPO_ROOT" node "$CLI" tail --limit 1
  [[ "$output" == *'"issue":42'* ]]
  [[ "$output" == *'"maturity":"L2"'* ]]
}

@test "空の値を持つフィールドは落とす" {
  record_event report "issue=5" "msg="
  run env REPO_ROOT="$REPO_ROOT" node "$CLI" tail --limit 1
  [[ "$output" != *'"msg"'* ]]
}

# --- 破損耐性 --------------------------------------------------------------

@test "途中で切れた行があっても残りは読める" {
  record_event idle
  printf '{"ts":"2026-08-12T17:00:00+09:00","kind":"repo' >> "$LOG"
  run env REPO_ROOT="$REPO_ROOT" node "$CLI" tail
  [[ "$output" == *'"idle"'* ]]
}

@test "切れた行の直後の追記が、そのイベントごと失われない" {
  # コンテナが書き込みの途中で kill されると最終行に改行がない。
  # そのまま追記すると 2 件が 1 行に連結され、新しいほうまで消える
  record_event idle
  printf '{"ts":"2026-08-12T17:00:00+09:00","kind":"repo' >> "$LOG"
  record_event dispatch "issue=42"
  record_event report "issue=43"

  local n
  n="$(env REPO_ROOT="$REPO_ROOT" node "$CLI" tail | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>
  process.stdout.write(String(JSON.parse(s).length)))')"
  # 失われるのは破損した 1 行だけ
  [ "$n" -eq 3 ]
}

@test "通常の追記で空行が混じらない" {
  record_event idle
  record_event idle
  [ "$(grep -c '^$' "$LOG" || true)" -eq 0 ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 ]
}

@test "ログがまだ無くても tail は空配列を返す（初回 firing 前）" {
  run env REPO_ROOT="$REPO_ROOT" node "$CLI" tail
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tail は新しい順に返し、--limit を尊重する" {
  record_event idle
  record_event report "issue=1"
  record_event dispatch "issue=2"
  run env REPO_ROOT="$REPO_ROOT" node "$CLI" tail --limit 2
  # 先頭が最新（dispatch）で、最も古い idle は含まれない
  [[ "$output" == '[{"ts"'*'"kind":"dispatch"'* ]]
  [[ "$output" != *'"idle"'* ]]
}

@test "書き込めなくても record_event はループを止めない" {
  # 観測のためのログがループ本体を落とすのは本末転倒
  chmod 500 "$REPO_ROOT/loops"
  run record_event idle
  chmod 700 "$REPO_ROOT/loops"
  [ "$status" -eq 0 ]
}
