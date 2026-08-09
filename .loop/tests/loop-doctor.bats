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
  # "claude" という文字列だけだと OK 行（"claude 認証: コンテナ内で利用できる"）
  # にも常に出るため真になってしまう。NG 行そのものに絞って確認する
  [[ "$output" == *"NG   claude 認証"* ]]
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

# --- Fix round 1 で追加した回帰テスト ---------------------------------------

@test "extra_tools が件数だけ揃っていても中身が test/lint と対応していなければ NG（コードレビュー指摘の再現）" {
  # extra_tools は 1 件あるが make であって、test が使う pnpm には対応していない。
  # 件数だけを見る判定だとここが OK になってしまい、Verifier は pnpm を
  # 実行できないまま diff だけを読んで approve する — この検査が本来
  # 捕まえるべき、まさにその失敗
  printf '[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "複合コマンド（cd ... && npm test）でも中身のコマンド名を拾って判定する" {
  printf '[project]\ntest = "cd packages/web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  # npm は許可されているが cd は許可されていないため、複合コマンドの
  # 先頭トークンまで拾えているなら cd が不足として NG になるはず
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"cd"* ]]
}

@test "extra_tools の中身が test/lint のコマンドをちゃんと covers していれば OK（誤検知しない）" {
  printf '[project]\ntest = "cd packages/web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(cd:*)", "Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "sh -c '...' のように中身が読み切れない形は件数チェックにフォールバックする（安全側）" {
  printf '[project]\ntest = "sh -c \\"pnpm test\\""\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(anything:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "loop-doctor と実行時ガード（require_project_tools_allowed）は同じ設定に対して同じ答えを返す（doctor は NG、dispatch-maker は REFUSED）" {
  # コードレビュー指摘: doctor と実行時ガードが同じ穴（件数だけを見る判定）を
  # 共有していた。共通ヘルパーに切り出した後、両者が食い違わないことを直接確認する
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "リポジトリのパスに -verify-pr- を含んでいても、それだけでは残骸扱いしない（ベース名でアンカーする）" {
  # コードレビュー指摘: パス全体の部分一致で判定すると、リポジトリ名
  # （の親ディレクトリ）に -verify-pr- が含まれるだけでプライマリ worktree
  # 自身を誤検知し、健全な状態でも毎回 NG が出続けていた
  OUTER="$(mktemp -d)"
  TMP2="$OUTER/my-verify-pr-template"
  mkdir -p "$TMP2"
  make_test_repo "$TMP2"
  use_gh_stub
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/docker"
  DOCKER_LOG="$TEST_TMP/docker2.log"; export DOCKER_LOG
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"},{"name":"needs-human"},{"name":"loop:auto-merge"}]'
  export GH_LABEL_LIST_JSON
  DOCKER_PS_JSON='[{"Service":"loop","State":"running"}]'; export DOCKER_PS_JSON
  printf '[project]\ntest = "make test"\nlint = "make lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  # リポジトリのパス自体（$LOOP_DIR/config.toml 等）には "verify-pr" を含む
  # 文字列が正当に出てくる（config 構文チェックのメッセージ等）ので、
  # 全体を verify-pr で検索するのではなく worktree 残骸の行だけを見る
  [[ "$output" == *"worktree 残骸: なし"* ]]
  [[ "$output" != *"NG   worktree 残骸"* ]]

  rm -rf "$OUTER"
}
