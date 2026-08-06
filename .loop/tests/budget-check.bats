#!/usr/bin/env bats
# budget-check: fail-closed のトークン予算ゲート。
# LOOP_DIR/REPO_ROOT の組み立てと ccusage スタブの用意は helpers.bash の
# make_test_repo / use_ccusage_stub に任せる（各 .bats ファイルで書き下さない）。

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
}

teardown() {
  cleanup_test_repo
  rm -rf "$TMP"
}

@test "上限内なら 0 を返す" {
  use_ccusage_stub ok
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"used=1000"* ]]
}

@test "上限を超えたら 1 を返す" {
  use_ccusage_stub over
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
}

@test "ccusage が失敗したら fail-closed で 1 を返す" {
  use_ccusage_stub fail
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"取得できない"* ]]
}

@test "出力が解析できなければ fail-closed で 1 を返す" {
  use_ccusage_stub garbage
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
}

@test "config で上限を下げると同じ使用量でも落ちる" {
  printf '[budget]\ndaily_tokens = 500\n' > "$LOOP_DIR/config.toml"
  use_ccusage_stub ok
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
}

# --- ここから brief の 5 本を超える fail-closed 経路の追加テスト ---
# JSON としては妥当でも totalTokens が数値でない場合、bash の
# `[ "$USED" -ge "$LIMIT" ]` は非数値を渡されると stderr にエラーを出しつつ
# 終了コード 2 を返すだけで、set -e ではないため if は「偽」に落ちて比較なしに
# exit 0 してしまう（fail-open のバグ）。sum-usage.mjs 側で型を検証して弾き、
# budget-check 側でも is_uint による二重チェックでこの経路を塞いでいる。
@test "使用量が数値でなければ fail-closed で 1 を返す" {
  use_ccusage_stub non-numeric
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
}

@test "daily/data フィールドがなければ fail-closed で 1 を返す" {
  use_ccusage_stub missing-total
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
}

@test "budget.daily_tokens が未設定なら fail-closed で 1 を返す" {
  printf '' > "$LOOP_DIR/defaults.toml"
  use_ccusage_stub ok
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
  [[ "$output" == *"未設定"* ]]
}
