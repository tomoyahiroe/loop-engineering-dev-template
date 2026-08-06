#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
}

teardown() { rm -rf "$TMP"; }

@test "defaults の値を返す" {
  run "$LOOP_REAL_DIR/bin/loop-config" get models.maker
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-5" ]
}

@test "config.toml が defaults を上書きする" {
  printf '[models]\nmaker = "claude-opus-5"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-config" get models.maker
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-5" ]
}

@test "テーブルは深くマージされ、上書きしていないキーは defaults のまま" {
  printf '[models]\nmaker = "claude-opus-5"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-config" get models.verifier
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-5" ]
}

@test "トップレベルのキーを取れる" {
  run "$LOOP_REAL_DIR/bin/loop-config" get maturity
  [ "$status" -eq 0 ]
  [ "$output" = "L2" ]
}

@test "真偽値は true/false になる" {
  run "$LOOP_REAL_DIR/bin/loop-config" get mtg.voice
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "配列は改行区切りになる" {
  run "$LOOP_REAL_DIR/bin/loop-config" get gate.required_sections
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## 背景" ]
  [ "${lines[4]}" = "## 依存" ]
}

@test "未定義のキーは終了コード 1 で無出力" {
  run "$LOOP_REAL_DIR/bin/loop-config" get nope.nothing
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "dump は妥当な JSON を返す" {
  run "$LOOP_REAL_DIR/bin/loop-config" dump
  [ "$status" -eq 0 ]
  echo "$output" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s))'
}
