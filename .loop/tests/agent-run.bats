#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  printf '[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  printf 'こんにちは\n' > "$TMP/prompt.md"
}

teardown() { rm -rf "$TMP"; }

@test "provider に role とモデルと max-turns を渡す" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROLE=maker"* ]]
  [[ "$output" == *"MODEL=claude-sonnet-5"* ]]
  [[ "$output" == *"MAX_TURNS=120"* ]]
}

@test "role ごとに max-turns が変わる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role verifier --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MAX_TURNS=30"* ]]
}

@test "プロンプトの中身が渡る" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [[ "$output" == *"PROMPT=こんにちは"* ]]
}

@test "provider の終了コードをそのまま返す" {
  MOCK_EXIT=3 run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 3 ]
}

@test "--log で終了コードを保ったままログを保存する" {
  MOCK_EXIT=4 run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" \
    --cwd "$TMP" --log "$TMP/out/run.md"
  [ "$status" -eq 4 ]
  [ -f "$TMP/out/run.md" ]
  grep -q "ROLE=maker" "$TMP/out/run.md"
}

@test "存在しない provider は 2 で落ちる" {
  printf '[agent]\nprovider = "nope"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"provider スクリプトがない"* ]]
}

@test "--role がないと 2 で落ちる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"maker|verifier|fixer"* ]]
}

@test "存在しない prompt-file は 2 で落ちる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/nope.md" --cwd "$TMP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--prompt-file が見つからない"* ]]
}

@test "存在しない --cwd は 2 で落ちる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--cwd が見つからない"* ]]
}

# 以下 4 件は「値のないフラグでハングしない」ことを保証する回帰テスト。
# shift 2 の前のガードが失われると、while ループが $# を消費できず
# 無限ループする。run はプロセスの終了を待つので、退行するとこのテストは
# 通過も失敗もせず bats 全体がハングする（黙って通ってしまうことがない）。
@test "--role に値がないと 2 で落ちる（ハングしない）" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role
  [ "$status" -eq 2 ]
  [[ "$output" == *"「--role」に値がありません"* ]]
}

@test "--prompt-file に値がないと 2 で落ちる（ハングしない）" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file
  [ "$status" -eq 2 ]
  [[ "$output" == *"「--prompt-file」に値がありません"* ]]
}

@test "--cwd に値がないと 2 で落ちる（ハングしない）" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd
  [ "$status" -eq 2 ]
  [[ "$output" == *"「--cwd」に値がありません"* ]]
}

@test "--log に値がないと 2 で落ちる（ハングしない）" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP" --log
  [ "$status" -eq 2 ]
  [[ "$output" == *"「--log」に値がありません"* ]]
}
