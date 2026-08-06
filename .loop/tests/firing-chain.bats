#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/"
  printf '[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-9" -b loop/issue-9 main
  # この worktree は「open な PR を持つ Issue の作業ツリー」を再現するもの。
  # 実運用では PR が open な間、必ず main には無いコミットを持っているので、
  # ここで 1 コミット進めてその状態に合わせる。
  #
  # （なお「実行中の Maker/Fixer の worktree を cleanup-merged が消してしまう」
  # 問題自体は、dispatcher が実行中だけ主張する所有権マーカー
  # loops/.wt-owner-* で製品側が塞いである。ここでその仕組みに頼らないのは、
  # このセットアップが dispatcher を経由せずテストが直接作った worktree で
  # あり、所有者がいないため。所有権の挙動自体は cleanup-merged.bats と
  # dispatch-maker.bats が別途カバーしている）
  echo two > "$TMP/repo-issue-9/b.txt"
  git -C "$TMP/repo-issue-9" add -A
  git -C "$TMP/repo-issue-9" commit -qm wip

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_FETCH=1; export LOOP_SKIP_FETCH
  LOOP_SKIP_VERIFIER=1; export LOOP_SKIP_VERIFIER
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

CHANGES_PR='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"CHANGES_REQUESTED","labels":[]}]'
APPROVED_AM='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"APPROVED","labels":[{"name":"loop:auto-merge"}]}]'
APPROVED_PLAIN='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"APPROVED","labels":[]}]'
# APPROVED ラベルなし・reviewDecision も未承認（L3 かつラベルありでも
# 承認が取れていなければ merge しないことを、ラベル条件とは独立に確認する用）
PENDING_AM='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"REVIEW_REQUIRED","labels":[{"name":"loop:auto-merge"}]}]'

@test "request-changes の PR に Fixer を回す" {
  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "auto_fix_rounds を超えたら needs-human にして Fixer を回さない" {
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md"
  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r2.md" ]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
}

@test "auto_fix_rounds = 0 なら Fixer を回さない" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nauto_fix_rounds = 0\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "L3 かつ auto-merge ラベルかつ approve なら merge する" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$APPROVED_AM" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  run cat "$GH_LOG"
  [[ "$output" == *"pr merge 30"* ]]
}

@test "L3 でも auto-merge ラベルがなければ merge しない" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$APPROVED_PLAIN" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
}

@test "L2 では auto-merge ラベルがあっても merge しない" {
  GH_PR_LIST_JSON="$APPROVED_AM" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
}

# --- ここから brief が明示していないギャップを埋めるテスト -----------------

@test "L3 かつ auto-merge ラベルありでも、承認が取れていなければ merge しない（承認条件を単独で確認）" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$PENDING_AM" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
}

@test "--dry-run は、実行すれば merge されるはずの L3 approve+ラベル済み PR でも merge しない" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  export GH_PR_LIST_JSON="$APPROVED_AM"
  export GH_ISSUE_LIST_JSON='[]'

  cp "$REPO_ROOT/loops/STATE.md" "$TMP/state-before.md"

  run "$LOOP_REAL_DIR/bin/firing" --dry-run
  [ "$status" -eq 0 ]

  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]

  # STATE.md にも一切書き込まれない（--dry-run は STATE 書き込みも副作用として禁止）
  run cmp -s "$TMP/state-before.md" "$REPO_ROOT/loops/STATE.md"
  [ "$status" -eq 0 ]

  # 裏取り: 同じ状況で --dry-run を外すと実際に merge されることを確認する。
  # これがないと「そもそも merge されない状況で何もしていないだけ」の
  # 空虚な成功になりかねない
  rm -f "$GH_LOG"
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run cat "$GH_LOG"
  [[ "$output" == *"pr merge 30"* ]]
}

# --- Fix round 1: レビュー指摘の回帰テスト ----------------------------------
# 指摘1: L3 merge 失敗分岐（firing:98-100 相当）にテストが無かった。gh スタブに
# 選択的なノブ（GH_PR_MERGE_EXIT）を追加し、pr merge だけを狙って失敗させて
# カバーする

@test "L3 merge が失敗したら STATE と needs-human ラベルを記録し、成功として報告しない" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$APPROVED_AM" GH_ISSUE_LIST_JSON='[]' GH_PR_MERGE_EXIT=1 \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  # 成功したかのような報告（stdout の "auto-merged"）は出ない
  [[ "$output" != *"auto-merged"* ]]

  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"L3 自動 merge に失敗: PR #30"* ]]

  run cat "$GH_LOG"
  [[ "$output" == *"pr merge 30"* ]]
  [[ "$output" == *"issue edit 9 --add-label needs-human"* ]]

  [ -f "$REPO_ROOT/loops/.merge-failed-30" ]
}

# 指摘2: merge 失敗は一過性とは限らない（branch protection / conflict は
# tick を跨いでも解消しない）ため、gate-remediation と同じマーカー方式で
# 「記録は PR ごとに高々1回、merge のリトライ自体は毎tick静かに続ける」を
# 確認する

@test "L3 merge が持続的に失敗し続けても STATE 記録は高々1回、merge 自体は毎tick再試行される（3 tick）" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  export GH_PR_LIST_JSON="$APPROVED_AM"
  export GH_ISSUE_LIST_JSON='[]'
  export GH_PR_MERGE_EXIT=1

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  run bash -c "grep -c 'L3 自動 merge に失敗' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]

  # needs-human も 1 回だけ（記録済みマーカーがある間は付与を再試行しない）
  run bash -c "grep -c 'issue edit 9 --add-label needs-human' \"$GH_LOG\""
  [ "$output" -eq 1 ]

  # merge そのものは毎 tick 静かにリトライされている（自己修復の可能性を残す）
  run bash -c "grep -c '^pr merge 30 ' \"$GH_LOG\""
  [ "$output" -eq 3 ]

  [ -f "$REPO_ROOT/loops/.merge-failed-30" ]
}

@test "L3 merge が失敗記録後に成功すると、失敗マーカーは消える" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  export GH_PR_LIST_JSON="$APPROVED_AM"
  export GH_ISSUE_LIST_JSON='[]'

  GH_PR_MERGE_EXIT=1 run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/.merge-failed-30" ]

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO_ROOT/loops/.merge-failed-30" ]
  run cat "$GH_LOG"
  [[ "$output" == *"pr merge 30"* ]]
}

@test "同じ issue 番号の dispatch-maker retry ログがあっても fix round の数え上げに混ざらない" {
  # dispatch-maker が一過性エラーのリトライで書く .retry.md は issue 番号で
  # 名前が付く（*-maker-issue-<N>.md / .retry.md）。fixer 側の round カウント
  # glob は PR 番号ベース（*-fixer-pr-<PR>-r*.md）で完全に別プレフィックスだが、
  # N_TODAY で一度 *.retry.md の二重カウント事故が起きた教訓を踏まえ、
  # 無関係なログが紛れ込んでいても round 0 のまま正しく r1 が dispatch
  # されることを直接確認する（issue 番号 9 が PR 30 の issue 番号と一致する
  # ケースで検証し、番号の偶然の一致にも強いことを示す）
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-9.md"
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-9.retry.md"

  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
  # r2 も作られていない = round 0 からの正しい1回目としてカウントされた
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r2.md" ]
}

@test "PR も Issue も何もない tick は STATE にも痕跡を残さない（新セクション追加後の回帰確認）" {
  cp "$REPO_ROOT/loops/STATE.md" "$TMP/state-before.md"
  GH_ISSUE_LIST_JSON='[]' GH_PR_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run cmp -s "$TMP/state-before.md" "$REPO_ROOT/loops/STATE.md"
  [ "$status" -eq 0 ]
}
