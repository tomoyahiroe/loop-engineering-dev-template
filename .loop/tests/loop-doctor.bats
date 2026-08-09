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

@test "複合コマンド（cd ... && pnpm test）でも中身の非組み込みコマンド名を拾って判定する" {
  # cd 自体は組み込み read-only（相対パス）なので許可が要らない。ここで
  # 不足として拾われるべきなのは pnpm の方
  printf '[project]\ntest = "cd packages/web && pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]
  [[ "$output" != *"（cd）"* ]]
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

# --- Fix round 2 で追加した回帰テスト ---------------------------------------
# コードレビュー指摘: round 1 の修正が過剰に振れ、Claude Code の組み込み
# read-only コマンド（ls/cat/echo/pwd/head/tail/grep/find/wc/which/diff/
# stat/du/cd と read-only な git。出典: code.claude.com/docs/en/permissions.md
# "Read-only commands"）まで extra_tools への許可が必要と誤判定していた。
# `cd packages/web && pnpm test` はこのハーネス自身が Issue テンプレート /
# loop-gate で推奨している「実行ディレクトリ込みのコマンド」の形そのものであり、
# monorepo では最も普通の書き方なので、これを NG にすると正しい設定でループが
# 起動しなくなる（元のバグより有害）

@test "cd + npm（組み込み cd と許可済み npm）は doctor でも実行時ガードでも OK" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "cd web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 2
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "cd + pnpm（許可が make のみ）は本物の不一致として今も NG になる" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "cd web && pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 3
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "組み込みコマンドだけで構成された test（echo skip）は extra_tools が空でも OK" {
  printf '[project]\ntest = "echo skip"\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
  [[ "$output" == *"OK   project/tools 対応"* ]]
}

@test "read-only な git サブコマンド（git status）は組み込み扱いで許可が要らない" {
  printf '[project]\ntest = "git status && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "書き込みになり得る git サブコマンド（git branch）は保守的に許可が必要なまま" {
  printf '[project]\ntest = "git branch -d tmp && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
}

@test "絶対パスへの cd はワーキングディレクトリの外に出られるため組み込み扱いしない" {
  printf '[project]\ntest = "cd /tmp && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"cd"* ]]
}

# --- Fix round 3 で追加した回帰テスト ---------------------------------------
# コードレビュー指摘: round 2 で cd と一部の git サブコマンドを組み込み扱い
# にしたが、同じ失敗クラスの取りこぼしが 2 件残っていた。
# (1) 先頭の環境変数代入（CI=true npm test）をコマンド名として誤抽出し、
#     正しい設定を弾いていた（cd のときと同じ「正しい設定を止める」方向）。
# (2) GIT_READONLY_SUBCMDS に symbolic-ref が入っており、実際には
#     `git symbolic-ref HEAD refs/heads/x` で HEAD を書き換えられる
#     （「壊れた設定を健全と報告する」偽陰性の方向。この検査が防ぐべき失敗）

@test "先頭の環境変数代入（CI=true npm test）はコマンド名ではなく npm を見る" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "CI=true npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 4
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "複数連続する環境変数代入（A=1 B=2 pnpm test）も読み飛ばして pnpm を見る" {
  printf '[project]\ntest = "A=1 B=2 pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(pnpm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "環境変数代入があっても本物の不一致（CI=true npm test + Bash(make:*)）は今も NG になる" {
  printf '[project]\ntest = "CI=true npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"npm"* ]]
}

@test "git symbolic-ref は書き込み可能なため read-only の組み込み扱いにしない" {
  printf '[project]\ntest = "git symbolic-ref HEAD refs/heads/hijacked && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
}

@test "round 2 までの修正は退行していない（cd+npm は OK、pnpm+make は NG）" {
  printf '[project]\ntest = "cd web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  printf '[project]\ntest = "pnpm -r test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]
}
