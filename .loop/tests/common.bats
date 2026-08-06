#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  source "$LOOP_REAL_DIR/lib/common.sh"
}

teardown() { cleanup_test_repo; rm -rf "$TMP"; }

@test "cfg が設定値を返す" {
  run cfg maturity
  [ "$status" -eq 0 ]
  [ "$output" = "L2" ]
}

@test "cfg は未定義キーで 1 を返す" {
  run cfg nope.nothing
  [ "$status" -eq 1 ]
}

@test "record_state が STATE.md に 1 行追記する" {
  record_state "テスト行"
  run tail -1 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"テスト行"* ]]
  [[ "$output" == -* ]]
}

@test "is_transient_error が接続系エラーを検出する" {
  printf 'fetch failed ENOTFOUND api.example.com\n' > "$TMP/log"
  run is_transient_error "$TMP/log"
  [ "$status" -eq 0 ]
}

@test "is_transient_error は通常の失敗を検出しない" {
  printf 'AssertionError: expected 1 to equal 2\n' > "$TMP/log"
  run is_transient_error "$TMP/log"
  [ "$status" -ne 0 ]
}

@test "render_prompt が複数のプレースホルダを置換する" {
  printf 'Issue #{{ISSUE}} を {{TEST_CMD}} で検証する。#{{ISSUE}} 再掲。\n' > "$TMP/t.md"
  run render_prompt "$TMP/t.md" "ISSUE=42" "TEST_CMD=pnpm -r test"
  [ "$status" -eq 0 ]
  [ "$output" = "Issue #42 を pnpm -r test で検証する。#42 再掲。" ]
}

@test "render_prompt はスラッシュやアンパサンドを含む値でも壊れない" {
  printf 'cmd: {{CMD}}\n' > "$TMP/t.md"
  run render_prompt "$TMP/t.md" "CMD=cd packages/web && npm test"
  [ "$status" -eq 0 ]
  [ "$output" = "cmd: cd packages/web && npm test" ]
}

@test "retry_delay が既定値を返す" {
  run retry_delay
  [ "$status" -eq 0 ]
  [ "$output" = "600" ]
}
