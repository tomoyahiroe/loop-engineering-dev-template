#!/usr/bin/env bats

load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/issues"

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
}

teardown() { rm -rf "$TMP"; }

@test "正しい Issue は通過する" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/good.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE OK"* ]]
}

@test "必須セクションが欠けていると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/missing-section.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"## スコープ外"* ]]
}

@test "検証コマンドのない受け入れ基準は落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/no-command.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"検証コマンドがない"* ]]
}

@test "手動: で始まる基準は例外として許される" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/good.md"
  [ "$status" -eq 0 ]
}

@test "未 close の依存があると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/dep-open.md" --dep-state 12=OPEN
  [ "$status" -eq 1 ]
  [[ "$output" == *"#12"* ]]
}

@test "close 済みの依存なら通過する" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/dep-open.md" --dep-state 12=CLOSED
  [ "$status" -eq 0 ]
}

@test "触るパスが多すぎると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/too-many-paths.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"多すぎる"* ]]
}

@test "実装方針にパスがないと落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/no-path.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"パスがない"* ]]
}

@test "gate.max_files_touched を config で緩められる" {
  printf '[gate]\nmax_files_touched = 20\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/too-many-paths.md"
  [ "$status" -eq 0 ]
}
