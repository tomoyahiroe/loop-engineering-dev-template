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

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_FETCH=1; export LOOP_SKIP_FETCH
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
  chmod +x "$BATS_TEST_DIRNAME/fixtures/ccusage/"*.sh
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

# gate を通る Issue 本文（本文中の \n は JSON エスケープ。実際の改行ではない）
GOOD_ISSUE_JSON='{"body":"## 背景\nx\n\n## 受け入れ基準\n- [ ] `pnpm test`\n\n## 実装方針\n`a.txt` を編集\n\n## スコープ外\nなし\n\n## 依存\nなし\n","state":"OPEN"}'

@test "ready な Issue がなければ何も記録せず 0 で終わる" {
  GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run wc -l < "$REPO_ROOT/loops/STATE.md"
  [ "$output" -eq 1 ]
}

@test "--dry-run は判定だけ出して副作用を起こさない" {
  GH_ISSUE_LIST_JSON='[{"number":5}]' run "$LOOP_REAL_DIR/bin/firing" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"#5"* ]]
  [ ! -d "$TMP/repo-issue-5" ]
}

@test "maturity = L1 では dispatch せず STATE に記録する" {
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  # brief 原文はここで GH_ISSUE_JSON を渡していないが、実行順は
  # gate 再検証 → L1（コーディネーター確認済み）なので、gh スタブの既定
  # DEFAULT_ISSUE_JSON（body 空）のままだと gate が先に不合格になり、
  # L1 分岐に到達できず本文の "L1" アサーションが失敗する
  # （制御側で bash 3.2.57 上で再現確認済み）。gate を通す本文を渡す
  GH_ISSUE_LIST_JSON='[{"number":5}]' GH_ISSUE_JSON="$GOOD_ISSUE_JSON" \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-5" ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"L1"* ]]
  [[ "$output" == *"#5"* ]]
}

@test "open PR が上限に達していればスキップを記録する" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nmax_open_prs = 1\n' > "$LOOP_DIR/config.toml"
  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  GH_PR_LIST_JSON='[{"number":1,"headRefName":"loop/issue-1"}]' \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"PR 上限"* ]]
}

@test "本日の dispatch 上限に達していればスキップを記録する" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nmax_dispatch_per_day = 1\n' > "$LOOP_DIR/config.toml"
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-3.md"
  GH_ISSUE_LIST_JSON='[{"number":5}]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"日次上限"* ]]
}

@test "予算超過ならスキップを記録する" {
  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/over.sh" \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"予算"* ]]
}

@test "gate を通らない Issue は ready を剥がして needs-human にする" {
  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}' \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
  [[ "$output" == *"--add-label needs-human"* ]]
}

# --- ここから brief が明示していないギャップを埋めるテスト -----------------

@test "仕事がない tick は STATE にも loops/runs/ にも gate-fail マーカーにも一切痕跡を残さない（バイト単位で確認）" {
  cp "$REPO_ROOT/loops/STATE.md" "$TMP/state-before.md"

  GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  run cmp -s "$TMP/state-before.md" "$REPO_ROOT/loops/STATE.md"
  [ "$status" -eq 0 ]

  run bash -c 'ls -A "$0" 2>/dev/null | wc -l | tr -d " "' "$REPO_ROOT/loops/runs"
  [ "$output" = "0" ]

  # fix round 2 で導入した gate-fail マーカー（loops/.gate-failed-<N>）も、
  # 仕事がない tick では一切作られない
  run bash -c "ls -A '$REPO_ROOT/loops'/.gate-failed-* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "--dry-run は、実行すれば dispatch されるはずの状況でも STATE と worktree 一覧を変えない" {
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  export GH_ISSUE_JSON="$GOOD_ISSUE_JSON"

  cp "$REPO_ROOT/loops/STATE.md" "$TMP/state-before.md"
  git -C "$REPO_ROOT" worktree list > "$TMP/wt-before.txt"

  run "$LOOP_REAL_DIR/bin/firing" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"#5"* ]]

  run cmp -s "$TMP/state-before.md" "$REPO_ROOT/loops/STATE.md"
  [ "$status" -eq 0 ]

  git -C "$REPO_ROOT" worktree list > "$TMP/wt-after.txt"
  run cmp -s "$TMP/wt-before.txt" "$TMP/wt-after.txt"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-5" ]

  # 裏取り: 同じ状況で --dry-run を外すと実際に dispatch されることを確認する
  # （このテストが「本来なら dispatch されるはずの状況」を正しく再現できて
  # いることの証明。裏取りをしないと、dry-run が「何もしなくて当然の状況」で
  # 何もしていないだけ、という空虚な成功になりかねない）
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-5" ]
}

@test "L1 は maker を dispatch しない（worktree/branch が作られない）ことを直接確認する" {
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  export GH_ISSUE_JSON="$GOOD_ISSUE_JSON"

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-5" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-5
  [ "$status" -ne 0 ]
}

@test "ready な Issue が複数あれば番号が最小のものを選ぶ" {
  export GH_ISSUE_LIST_JSON='[{"number":9},{"number":5},{"number":7}]'
  export GH_ISSUE_JSON="$GOOD_ISSUE_JSON"

  run "$LOOP_REAL_DIR/bin/firing" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"#5"* ]]
  [[ "$output" != *"#9"* ]]
  [[ "$output" != *"#7"* ]]
}

@test "open PR 上限は budget-check（ccusage）より先に評価され、上限到達時は ccusage を呼ばない" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nmax_open_prs = 1\n' > "$LOOP_DIR/config.toml"
  CCUSAGE_LOG="$TMP/ccusage.log"
  cat > "$TMP/ccusage-spy.sh" <<EOF
#!/usr/bin/env bash
echo called >> "$CCUSAGE_LOG"
exec "$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh" "\$@"
EOF
  chmod +x "$TMP/ccusage-spy.sh"

  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  GH_PR_LIST_JSON='[{"number":1,"headRefName":"loop/issue-1"}]' \
  LOOP_CCUSAGE_CMD="$TMP/ccusage-spy.sh" \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -f "$CCUSAGE_LOG" ]
}

@test "実際に dispatch する（L2、既定設定、gate 通過）と maker が起動し STATE に記録される" {
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  export GH_ISSUE_JSON="$GOOD_ISSUE_JSON"

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-5" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-5
  [ "$status" -eq 0 ]
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"maker issue-5"* ]]
}

@test "origin/main が存在しない（リモート未設定）のは正常系で、エラーにならず何も記録しない" {
  unset LOOP_SKIP_FETCH
  GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run wc -l < "$REPO_ROOT/loops/STATE.md"
  [ "$output" -eq 1 ]
}

# --- Fix round 1: レビュー指摘の回帰テスト ----------------------------------

@test "gate 不合格の remediation は複数 tick に渡っても高々 1 回のコメント/STATE記録に留まる（2 tick）" {
  export GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}'
  export GH_ISSUE_LIST_JSON='[{"number":5}]'

  # tick 1: マーカーがまだない → 通常どおり remediate する
  # （ready 除去 + コメント成功 → needs-human 付与 + マーカー書き込み + STATE 1 行）
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  # tick 2: 同じ Issue がまた ready 一覧に出てきた状況を再現する（例: 前回
  # --remove-label loop:ready が失敗した）。マーカーはローカルファイルとして
  # 実際に $REPO_ROOT/loops に残っているので、gh 側の状態を偽装する必要はない
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  run bash -c "grep -c '^issue comment 5 ' \"$GH_LOG\""
  [ "$output" -eq 1 ]

  run bash -c "grep -c 'dispatch 中止 #5' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]

  # ready の除去自体は tick 2 でも諦めずに再試行されている
  # （自己修復の手段を残すため）
  run bash -c "grep -c '^issue edit 5 --remove-label loop:ready' \"$GH_LOG\""
  [ "$output" -eq 2 ]

  [ -f "$REPO_ROOT/loops/.gate-failed-5" ]
}

@test "N_TODAY はリトライログを二重カウントしない（1 回の dispatch が retry しても 1 件）" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nmax_dispatch_per_day = 2\n' > "$LOOP_DIR/config.toml"
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-3.md"
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-3.retry.md"

  GH_ISSUE_LIST_JSON='[{"number":5}]' GH_ISSUE_JSON="$GOOD_ISSUE_JSON" \
    run "$LOOP_REAL_DIR/bin/firing" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"日次上限"* ]]
  [[ "$output" == *"DRY RUN: #5 を dispatch する"* ]]
}

# --- Fix round 2: レビュー指摘の回帰テスト -----------------------------------
# round 1 の「needs-human ラベルの有無」による冪等性判定は、判定材料自体が
# gh 呼び出し（失敗し得る）で決まるため、2 つの新しい失敗モードを生んでいた。
# ローカルマーカーファイル方式への切り替えで両方を塞いだことを確認する

@test "コメント投稿が tick 1 で失敗し tick 2 で成功する場合、説明は最終的に届き STATE は 1 行だけになる" {
  export GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}'
  export GH_ISSUE_LIST_JSON='[{"number":5}]'

  # tick 1: コメント投稿だけ失敗させる（ready 除去・後段の needs-human 付与は
  # 成功する状況を再現）。round 1 の実装ならここで「remediate 済み」と誤認して
  # 以後二度とコメントを試みなくなっていた（今回のレビューで発見された新規バグ）
  GH_ISSUE_COMMENT_EXIT=1 run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  # コメントは失敗した扱いなので、マーカーもSTATE記録もまだ無い
  [ ! -f "$REPO_ROOT/loops/.gate-failed-5" ]
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" != *"dispatch 中止 #5"* ]]

  # tick 2: コメントが成功するようになった（一過性障害が解消した想定）
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  # 説明は最終的にちゃんと届き、STATE には 1 行だけ記録される
  [ -f "$REPO_ROOT/loops/.gate-failed-5" ]
  run bash -c "grep -c 'dispatch 中止 #5' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]
}

@test "remove-label も add-label も 3 tick 連続で失敗し続けても、コメント/STATE記録は高々 1 回に留まる" {
  export GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}'
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  # issue edit（remove-label と add-label の両方）を恒久的に失敗させる。
  # round 1 の実装なら「needs-human が付かない → 未remediate と誤認」が
  # 毎 tick 続き、コメント・STATE 記録が無限に増殖していた
  export GH_ISSUE_EDIT_EXIT=1

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  run bash -c "grep -c '^issue comment 5 ' \"$GH_LOG\""
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'dispatch 中止 #5' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]
  # loop:ready の除去は自己修復のため 3 tick とも試みられている
  run bash -c "grep -c '^issue edit 5 --remove-label loop:ready' \"$GH_LOG\""
  [ "$output" -eq 3 ]
}

@test "既存の 2 tick 冪等性テストは変わらず通る（マーカー方式でも回帰しないことの確認）" {
  export GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}'
  export GH_ISSUE_LIST_JSON='[{"number":5}]'

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  run bash -c "grep -c '^issue comment 5 ' \"$GH_LOG\""
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'dispatch 中止 #5' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]
}

@test "仕事がない tick は fix round 2 のあとも STATE に一切痕跡を残さない（回帰確認）" {
  cp "$REPO_ROOT/loops/STATE.md" "$TMP/state-before.md"
  GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run cmp -s "$TMP/state-before.md" "$REPO_ROOT/loops/STATE.md"
  [ "$status" -eq 0 ]
}

@test "gate に通ったら過去の gate-fail マーカーは片付く（regression 時に再度 remediate できるように）" {
  export GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}'
  export GH_ISSUE_LIST_JSON='[{"number":5}]'

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/.gate-failed-5" ]

  # Issue が編集されて gate を通るようになった
  export GH_ISSUE_JSON="$GOOD_ISSUE_JSON"
  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO_ROOT/loops/.gate-failed-5" ]
}
