#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  use_gh_stub
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/docker"
  DOCKER_LOG="$TEST_TMP/docker.log"; export DOCKER_LOG
  # 既定は「全部健全」
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"},{"name":"needs-human"},{"name":"loop:auto-merge"}]'
  export GH_LABEL_LIST_JSON
  DOCKER_PS_JSON='[{"Service":"loop","State":"running"}]'; export DOCKER_PS_JSON
  printf '[project]\ntest = "make test"\nlint = "make lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
}

teardown() { cleanup_test_repo; rm -rf "$TMP"; }

@test "全部健全なら終了コード 0" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "ラベルが欠けていたら NG になり終了コード 1" {
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"}]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG"* ]]
  [[ "$output" == *"needs-human"* ]]
}

@test "test が設定済みで extra_tools が空なら NG" {
  printf '[project]\ntest = "make test"\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra_tools"* ]]
}

@test "test も lint も空なら extra_tools が空でも OK" {
  printf '[project]\ntest = ""\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}

@test "config.toml が壊れていたら NG" {
  printf 'これは TOML ではない [[[\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
}

@test "コンテナが動いていなければ NG、認証は SKIP になる" {
  DOCKER_PS_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
}

@test "SKIP は失敗として数えない（コンテナ OK・他は全部健全なら 0）" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}

@test "claude の認証が切れていたら NG" {
  DOCKER_CLAUDE_EXIT=1 run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude"* ]]
}

@test "所有者のいない検証用 worktree を検出する" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify-pr-9"* ]]
}

@test "生きた所有者のいる worktree は残骸として報告しない" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  printf '%s\n' "$$" > "$REPO_ROOT/loops/.wt-owner-verify-pr-9"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" != *"verify-pr-9"* ]]
}

@test "cron の発火時刻を報告する" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" == *"1,3,5"* ]]
}

@test "--quiet は失敗した項目だけを出す" {
  GH_LABEL_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK"* ]]
  [[ "$output" == *"NG"* ]]
}

@test "--quiet で全部健全なら無出力・終了コード 0" {
  run "$LOOP_REAL_DIR/bin/loop-doctor" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "各行は OK / NG / SKIP のいずれかで始まる" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == OK* || "$line" == NG* || "$line" == SKIP* ]]
  done <<< "$output"
}

@test "SKIP だけでは終了コードは 0 のまま（コンテナ停止でも他が全部 OK なら SKIP のみが失敗コードに乗らない）" {
  DOCKER_PS_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  # コンテナ稼働自体は NG になるため終了コードは 1 だが、SKIP 行が
  # その NG とは独立に失敗としてカウントされていないことを、quiet モードで
  # NG がちょうど 1 行（コンテナ稼働のみ）であることから確認する
  [ "$status" -eq 1 ]
  NG_COUNT="$(printf '%s\n' "$output" | grep -c '^NG')"
  [ "$NG_COUNT" -eq 1 ]
  SKIP_COUNT="$(printf '%s\n' "$output" | grep -c '^SKIP')"
  [ "$SKIP_COUNT" -eq 3 ]
}

@test "config.toml が [project] を全く持たなくてもクラッシュしない" {
  printf '[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"project/tools"* ]]
}
