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
  # status だけだと無関係な理由（例: 別の SKIP 経路）で落ちても通ってしまう。
  # 「使用量 1000 と下げた上限 500 を実際に比較して over と判定した」ことまで
  # 見る
  [[ "$output" == *"used=1000 limit=500"* ]]
  [[ "$output" == *"予算を使い切った"* ]]
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

# --- Fix round 1: レビューで見つかった fail-open 経路への回帰テスト ---
# 20 桁の totalTokens。JS の double 変換で精度を失い、Number.isFinite は
# 通ってしまう有限値になる（レビューで実際に「比較なしで exit 0」に
# 落ちることを確認された再現ケース）。Number.isSafeInteger で弾く。
@test "totalTokens が桁あふれ（安全な整数の範囲外）なら fail-closed で 1 を返す" {
  use_ccusage_stub overflow
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
  # 桁あふれした値で「比較した体」にすらなっていないことを保証する
  [[ "$output" != *"used="* ]]
}

# daily キーは存在するが値が null。`||` フォールバックだと falsy な既存値が
# 黙って [] にすり替わり used=0 になる（レビューで実際に exit 0 に落ちることを
# 確認された再現ケース）。キーの有無と値の形を別々に検証して弾く。
@test "daily が null なら fail-closed で 1 を返す" {
  use_ccusage_stub null-daily
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
  [[ "$output" != *"used="* ]]
}

# 個々の行が負の totalTokens を持つ場合、合計だけを見ると上限内に収まって
# しまうことがある（正の行を負の行が打ち消すだけ）。行単位で非負を検証する。
@test "行の totalTokens が負なら fail-closed で 1 を返す" {
  use_ccusage_stub negative-row
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
}

# is_uint(USED) を「sum-usage.mjs の型検証が通った後」に単独で到達させる回帰
# テスト。totalTokens=5,000,000,000,000,000（16 桁）は Number.isSafeInteger
# の範囲内（2^53-1 ≒ 9.007e15 未満）なので sum-usage.mjs 側の検証は通過するが、
# is_uint の 15 桁上限は超える。このテストがないと、budget-check 側の
# is_uint(USED) チェックは「report に書いてあるだけで実際には一度も
# 実行経路に乗らない」死んだコードになってしまう
# （non-numeric.sh は sum-usage.mjs 側で先に弾かれるため、この経路を通らない）。
@test "使用量が mjs の検証は通るが桁数が大きすぎるなら is_uint 単独で fail-closed になる" {
  use_ccusage_stub oversized-safe-total
  run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"数値として不正、または大きすぎる"* ]]
  # sum-usage.mjs の解析自体は成功しており、is_uint が単独で弾いたことを示す
  # （「解析できない」ではなく「大きすぎる」の文言で分岐が違うことを確認する）
  [[ "$output" != *"解析できない"* ]]
}
