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

# --- テンプレート同梱の .loop/config.toml（クローン直後の初期値） -------------
# 設計書の達成条件 G / 受け入れ基準「maturity の初期値が L1 になっている」を
# 直接固定する。defaults.toml の既定は L2 で、同梱の config.toml がそれを
# L1 に落としていないと、クローンした人の**最初の firing がいきなり本物の
# Maker を dispatch する**（README が約束している「まず数回観察する期間」が
# 存在しない）。/loop-setup ④ の「L2/L3 が既に設定されていれば触らない」も、
# 同梱値が L2 だと常にそちらが勝ってしまい L1 にならない
@test "テンプレート同梱の config.toml は maturity = L1" {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  run env LOOP_DIR="$REPO/.loop" "$LOOP_REAL_DIR/bin/loop-config" get maturity
  [ "$status" -eq 0 ]
  [ "$output" = "L1" ]
}

@test "dump は妥当な JSON を返す" {
  run "$LOOP_REAL_DIR/bin/loop-config" dump
  [ "$status" -eq 0 ]
  echo "$output" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s))'
}
