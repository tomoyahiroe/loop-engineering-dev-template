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

# --- Fix round 1: レビューで見つかった、fixture では出ないが実プロジェクトで出るバグの回帰テスト ---

@test "npm: 既定の no-test スタブは本物のテストとして採用しない（DoD の緑を永久に満たせなくなる回避）" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm-stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = ""'* ]]
  [[ "$output" != *'test = "npm test"'* ]]
}

@test "npm: no-test スタブがあっても他の scripts（lint）は通常どおり検出する" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm-stub"
  [[ "$output" == *'lint = "npm run lint"'* ]]
}

@test "npm: no-test スタブを検出したことが source に出る" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm-stub"
  [[ "$output" == *"npm の既定スタブ"* ]]
}

@test "toToml: バックスラッシュや制御文字を含む値でも smol-toml でパースできる TOML を生成する" {
  run node "$LOOP_REAL_DIR/tests/fixtures/toml-escape-check.mjs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "cargo: workspace ルート（[package] が無い仮想マニフェスト）では preview を提案しない" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = "cargo test"'* ]]
  [[ "$output" == *'lint = "cargo clippy"'* ]]
  [[ "$output" == *'preview = ""'* ]]
}

@test "bun: test は 'bun test'（組み込みランナー）ではなく 'bun run test'（scripts.test の実行）にする" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/bun"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = "bun run test"'* ]]
  [[ "$output" != *'test = "bun test"'* ]]
  [[ "$output" == *'lint = "bun run lint"'* ]]
}

@test "python: pyproject.toml に ruff/pytest の根拠があるときだけ lint も出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/python"
  [[ "$output" == *'lint = "ruff check ."'* ]]
}

@test "python: pytest/ruff への言及が無い pyproject.toml では何も提案しない（存在だけで決め打ちしない）" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/python-noconfig"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = ""'* ]]
  [[ "$output" == *'lint = ""'* ]]
  [[ "$output" == *'extra_tools = []'* ]]
}

@test "make: 1 行に複数 target（'test lint: build'）を書いても両方拾う" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/make-multi"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = "make test"'* ]]
  [[ "$output" == *'lint = "make lint"'* ]]
}

@test "monorepo ルート: workspaces はあるが scripts が無い package.json では、検出したと偽らない" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/monorepo-root"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = ""'* ]]
  [[ "$output" != *'package.json の scripts'* ]]
  [[ "$output" == *"検出できません"* ]]
}
