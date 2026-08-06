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
}

@test "--role がないと 2 で落ちる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 2 ]
}
