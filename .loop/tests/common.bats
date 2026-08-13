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

# --- compose プロジェクト名 -------------------------------------------------
# docker/compose.yml が docker/ 配下にあるため、compose の既定のプロジェクト名は
# どのリポジトリでも "docker" になる。複数のループが互いのコンテナを奪い合う

@test "compose_project_name は config 未設定ならディレクトリ名を使う" {
  run compose_project_name
  [ "$output" = "repo" ]   # make_test_repo は $TMP/repo を作る
}

@test "compose_project_name は config の指定を優先する" {
  printf '[docker]\nproject_name = "my-loop"\n' > "$LOOP_DIR/config.toml"
  run compose_project_name
  [ "$output" = "my-loop" ]
}

@test "compose に使えない文字を正規化する" {
  printf '[docker]\nproject_name = "My Repo!!"\n' > "$LOOP_DIR/config.toml"
  run compose_project_name
  [ "$output" = "my-repo" ]
}

@test "正規化で空になっても一意な名前を返す（衝突を防ぐのが目的のため）" {
  # 非 ASCII だけの名前。固定文字列に落とすと別リポジトリと衝突してしまう
  printf '[docker]\nproject_name = "日本語だけ"\n' > "$LOOP_DIR/config.toml"
  run compose_project_name
  [[ "$output" =~ ^loop-[0-9a-f]{8}$ ]]
}

@test "同じ名前でもリポジトリのパスが違えば別の名前になる" {
  printf '[docker]\nproject_name = "です"\n' > "$LOOP_DIR/config.toml"
  local a b
  a="$(compose_project_name)"
  REPO_ROOT="$TMP/other" b="$(compose_project_name)"
  [ "$a" != "$b" ]
}
