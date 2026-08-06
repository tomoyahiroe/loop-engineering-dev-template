#!/usr/bin/env bats
# .loop/agents/claude.sh の argv 組み立てを、実物の claude の代わりに
# fixtures/bin/claude スタブで検証する。実際の claude CLI は使わない。

load helpers

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/claude"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"; export PATH
  printf 'hello\n' > "$TMP/prompt.md"
}

teardown() { rm -rf "$TMP"; }

@test "extra_tools が --allowedTools に含まれる" {
  printf '[agents.claude]\nextra_tools = ["Bash(pnpm:*)"]\n' > "$LOOP_DIR/config.toml"
  LOOP_ROLE=maker LOOP_PROMPT_FILE="$TMP/prompt.md" LOOP_CWD="$TMP" LOOP_DIR="$LOOP_DIR" \
    run "$LOOP_REAL_DIR/agents/claude.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG: --allowedTools"* ]]
  [[ "$output" == *"ARG: Bash(pnpm:*)"* ]]
}

@test "設定の読み出しに失敗すると 2 で落ちて claude を起動しない" {
  printf '[agent]\nprovider = "claude"\nbogus = \n' > "$LOOP_DIR/config.toml"
  LOOP_ROLE=maker LOOP_PROMPT_FILE="$TMP/prompt.md" LOOP_CWD="$TMP" LOOP_DIR="$LOOP_DIR" \
    run "$LOOP_REAL_DIR/agents/claude.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"設定の読み出しに失敗しました"* ]]
  [[ "$output" != *"ARG:"* ]]
}
