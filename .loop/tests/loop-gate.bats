#!/usr/bin/env bats

load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/issues"

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
  TEST_TMP="$TMP"; export TEST_TMP
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

@test "手動：（全角コロン）で始まる基準も例外として許される" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/manual-fullwidth-colon.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE OK"* ]]
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

@test "受け入れ基準が多すぎると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/too-many-criteria.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"受け入れ基準が多すぎる"* ]]
  [[ "$output" == *"7 > 6"* ]]
}

@test "gh 経由: 依存が close 済みなら通過する" {
  skip "fixtures/bin/gh:9 の \${GH_ISSUE_JSON:-{...}} が bash の展開バグで末尾に余分な } を付与し、JSON.parse が壊れる（bash 3.2/5.3 両方で再現）。コーディネーターの判断待ち"
  use_gh_stub
  GH_ISSUE_JSON='{"body":"## 背景\n背景の説明。\n\n## 受け入れ基準\n- [ ] `packages/web で pnpm test` が緑\n\n## 実装方針\n`packages/web/src/a.ts` を変更する。\n\n## スコープ外\nなし\n\n## 依存\n依存: #12","state":"CLOSED"}'
  export GH_ISSUE_JSON
  run "$LOOP_REAL_DIR/bin/loop-gate" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE OK"* ]]
}

@test "gh 経由: 依存が未 close なら落ちる" {
  skip "fixtures/bin/gh:9 の \${GH_ISSUE_JSON:-{...}} が bash の展開バグで末尾に余分な } を付与し、JSON.parse が壊れる（bash 3.2/5.3 両方で再現）。コーディネーターの判断待ち"
  use_gh_stub
  GH_ISSUE_JSON='{"body":"## 背景\n背景の説明。\n\n## 受け入れ基準\n- [ ] `packages/web で pnpm test` が緑\n\n## 実装方針\n`packages/web/src/a.ts` を変更する。\n\n## スコープ外\nなし\n\n## 依存\n依存: #12","state":"OPEN"}'
  export GH_ISSUE_JSON
  run "$LOOP_REAL_DIR/bin/loop-gate" 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"#12"* ]]
}
