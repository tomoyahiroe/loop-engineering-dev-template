#!/usr/bin/env bats
# ツール許可リストのガード（common.sh の require_project_tools_allowed）。
#
# maker.md / verifier.md / fixer.md は {{TEST_CMD}} / {{LINT_CMD}} を完了条件
# として埋め込むが、claude provider の --allowedTools（defaults.toml の
# tools_* + extra_tools）は既定で git / gh の Bash しか許可していない。
# extra_tools を足し忘れると Verifier はテストを 1 つも実行できないまま
# diff だけを読んで approve する — エラーにならず静かに壊れるので、無人運用
# では人間が気付けない。起動前に落とすのが唯一の防ぎ方。
#
# mock provider は許可リストを一切見ないため、この種のバグは既存の
# mock ベースのテストでは踏めない。ここだけ provider = "claude" を使い、
# 実物の agents/claude.sh + claude スタブで検証する。

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  use_claude_agent
  use_gh_stub
  use_ccusage_stub ok
  LOOP_SKIP_VERIFIER=1; export LOOP_SKIP_VERIFIER
  # 「test / lint は実コマンドだが extra_tools は空（= defaults.toml の [] のまま）」
  # という、README どおりに [project] だけ書き換えたユーザーの状態
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"
}

teardown() {
  cleanup_test_repo
  rm -rf "$TMP"
}

allow_extra_tools() {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[agents.claude]\nextra_tools = ["Bash(pnpm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
}

@test "extra_tools が空なら dispatch-maker は起動を拒否し、理由に extra_tools を名指しする" {
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"extra_tools"* ]]
  # worktree も branch も作らない
  [ ! -d "$TMP/repo-issue-7" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-7
  [ "$status" -ne 0 ]
  # 人間が朝に気付けるよう STATE に 1 行残る
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"ツール許可がない"* ]]
  [ -f "$REPO_ROOT/loops/.tools-misconfig" ]
}

@test "拒否は GitHub 側に一切触れない（loop:ready は剥がれず、設定を直せばそのまま dispatch される）" {
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  # gh は一度も呼ばれていない = ラベルは元のまま
  [ ! -f "$GH_LOG" ]

  # 設定を直すと、同じ Issue がそのまま dispatch される
  allow_extra_tools
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-7" ]
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
  # 設定が直ったのでマーカーも片付く（次に壊れたらまた 1 回報告できる）
  [ ! -f "$REPO_ROOT/loops/.tools-misconfig" ]
}

@test "設定ミスが続いても STATE への記録は高々 1 回（3 tick）" {
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  run bash -c "grep -c 'ツール許可がない' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]
}

@test "extra_tools を設定すれば dispatch-maker は通常どおり起動する" {
  allow_extra_tools
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-7" ]
  # claude スタブに --allowedTools がちゃんと渡っている（配線の裏取り）
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-7.md"
  [[ "$output" == *"--allowedTools"* ]]
  [[ "$output" == *"Bash(pnpm:*)"* ]]
}

@test "test / lint が空のプロジェクトは extra_tools が空でも拒否されない（逃げ道）" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = ""\nlint = ""\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-7" ]
  [ ! -f "$REPO_ROOT/loops/.tools-misconfig" ]
}

@test "extra_tools が空なら dispatch-verifier も起動を拒否し、検証用 worktree を作らない" {
  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra_tools"* ]]
  [ ! -d "$TMP/repo-verify-pr-21" ]
  # 予算チェックより先に落ちている（ccusage を無駄に叩かない・理由が化けない）
  [[ "$output" != *"BUDGET"* ]]
}

@test "extra_tools が空なら dispatch-fixer も起動を拒否する" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-9" -b loop/issue-9 main
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra_tools"* ]]
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "許可リストを見ない provider（mock）はこのガードの対象外" {
  # ツール許可リストの意味論は provider 固有。mock provider は
  # extra_tools を読まないので、同じ設定でも拒否されない
  # （既存の mock ベースのテスト群が回帰しないことの直接確認）
  use_mock_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-7" ]
  [ ! -f "$REPO_ROOT/loops/.tools-misconfig" ]
}

@test "defaults.toml の tools_maker / tools_verifier だけでは test/lint を実行できない（ガードの前提の確認）" {
  # このガードが必要である理由そのものを固定する。tools_* に
  # プロジェクトのツールチェーン（pnpm 等）が入っていないことを直接確認する。
  # ここが将来変わってツールチェーンが既定で許可されるようになったら、
  # このテストが落ちてガードの見直しを促す
  run "$LOOP_REAL_DIR/bin/loop-config" get agents.claude.tools_verifier
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm"* ]]
  [[ "$output" != *"npx"* ]]
  [[ "$output" != *"Bash(:*)"* ]]
  run "$LOOP_REAL_DIR/bin/loop-config" get agents.claude.extra_tools
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
