#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
}

teardown() { rm -rf "$TMP"; }

@test "既定（12 回/日・起点 1 時）で 2 時間おきの時リストを生成する" {
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 1,3,5,7,9,11,13,15,17,19,21,23 * * * "* ]]
}

@test "firings_per_day = 4 なら 6 時間おきになる" {
  printf '[schedule]\nfirings_per_day = 4\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [[ "$output" == "0 0,6,12,18 * * * "* ]]
}

@test "firings_per_day = 24 なら毎時になる" {
  printf '[schedule]\nfirings_per_day = 24\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0,1,2,3"* ]]
  [[ "$output" == *",23 * * * "* ]]
}

@test "firing のフルパスを含む" {
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [[ "$output" == *"/bin/firing"* ]]
}

@test "24 を割り切らない値は切り捨てて実際の回数を stderr に出す" {
  printf '[schedule]\nfirings_per_day = 5\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 0,4,8,12,16,20 * * * "* ]]
}

# --- 以下、brief の 5 本を超える追加ケース（degenerate input） ------------

@test "firings_per_day = 0 は 1 回/日にクランプし、crontab は壊れない" {
  printf '[schedule]\nfirings_per_day = 0\nstart_hour = 3\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 3 * * * "* ]]
}

@test "firings_per_day が負数なら 1 回/日にクランプする" {
  printf '[schedule]\nfirings_per_day = -5\nstart_hour = 2\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 2 * * * "* ]]
}

@test "firings_per_day = 25 は 24 回/日（毎時）にクランプする" {
  printf '[schedule]\nfirings_per_day = 25\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0,1,2,3"* ]]
  [[ "$output" == *",23 * * * "* ]]
}

@test "firings_per_day が数値でなければ 1 回/日として扱い、crontab は壊れない" {
  printf '[schedule]\nfirings_per_day = "abc"\nstart_hour = 5\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 5 * * * "* ]]
}

@test "firings_per_day が小数なら整数でないため 1 回/日として扱う" {
  printf '[schedule]\nfirings_per_day = 4.5\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 0 * * * "* ]]
}

@test "start_hour が負数なら 0-23 の範囲に正規化する" {
  printf '[schedule]\nfirings_per_day = 1\nstart_hour = -1\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 23 * * * "* ]]
}

@test "start_hour が 24 以上なら 0-23 の範囲に正規化する" {
  printf '[schedule]\nfirings_per_day = 1\nstart_hour = 30\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 6 * * * "* ]]
}

@test "start_hour が数値でなければ 0 時起点として扱う" {
  printf '[schedule]\nfirings_per_day = 1\nstart_hour = "noon"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 0 * * * "* ]]
}

@test "firings_per_day・start_hour が両方不正でも crontab は壊れず既定に丸まる" {
  printf '[schedule]\nfirings_per_day = "nope"\nstart_hour = "nope"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 0 * * * "* ]]
}
