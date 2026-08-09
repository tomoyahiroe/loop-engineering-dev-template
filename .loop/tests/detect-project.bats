#!/usr/bin/env bats

load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/projects"

@test "pnpm: lockfile から pnpm を選び、scripts を拾う" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/pnpm"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = "pnpm test"'* ]]
  [[ "$output" == *'lint = "pnpm lint"'* ]]
  [[ "$output" == *'preview = "pnpm dev"'* ]]
}

@test "pnpm: extra_tools が pnpm を含む" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/pnpm"
  [[ "$output" == *'Bash(pnpm:*)'* ]]
}

@test "npm: lockfile が package-lock.json なら npm を選ぶ" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm"
  [[ "$output" == *'test = "npm test"'* ]]
  [[ "$output" == *'Bash(npm:*)'* ]]
}

@test "npm: scripts に無いものは空文字になる" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm"
  [[ "$output" == *'lint = ""'* ]]
}

@test "cargo: Cargo.toml から cargo のコマンドを出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/cargo"
  [[ "$output" == *'test = "cargo test"'* ]]
  [[ "$output" == *'Bash(cargo:*)'* ]]
}

@test "python: pyproject.toml から pytest を出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/python"
  [[ "$output" == *'pytest'* ]]
}

@test "make: Makefile の target から make のコマンドを出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/make"
  [[ "$output" == *'test = "make test"'* ]]
  [[ "$output" == *'lint = "make lint"'* ]]
  [[ "$output" == *'Bash(make:*)'* ]]
}

@test "empty: 何も検出できなければ空の値を返し、終了コードは 0" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = ""'* ]]
}

@test "empty: 検出できなかったことが source に出る" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/empty"
  [[ "$output" == *"検出できません"* ]]
}

@test "test/lint が空なら extra_tools も空（対応が崩れない）" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/empty"
  [[ "$output" == *'extra_tools = []'* ]]
}

@test "存在しないディレクトリは終了コード 2" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/nope"
  [ "$status" -eq 2 ]
}
