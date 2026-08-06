#!/usr/bin/env bats
# dispatch-fixer: Verifier の指摘を Maker の worktree（生きた作業）で修正し、
# 完了したら Verifier を再実行する。dispatch-verifier の使い捨て worktree とは
# 違い、ここでは worktree を作りも消しもしない。存在しなければ needs-human で
# 終了するだけ（作れない。作ってしまうと PR の head ブランチと無関係な worktree
# を勝手に生やすことになる）。
#
# ラウンド数は別カウンタを持たず、ログファイル名の r<round> がそのまま
# 「実施済みラウンド」の記録になる（Task 10 がこれを数える）。
#
# setup() の repo/agent/gh/ccusage 組み立ては helpers.bash の共通関数に任せる
# （brief のように各 .bats ファイルへ手書きで展開しない）。

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  use_mock_agent
  use_gh_stub
  use_ccusage_stub ok
  LOOP_SKIP_VERIFIER=1; export LOOP_SKIP_VERIFIER

  # dispatch-fixer は Maker の worktree を「再利用する」前提のスクリプトなので、
  # テストでも先に Maker 相当の worktree を用意しておく
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-9" -b loop/issue-9 main
}

teardown() {
  cleanup_test_repo
  rm -rf "$TMP"
}

@test "Maker の worktree を再利用して起動する" {
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 0 ]
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md"
  [[ "$output" == *"CWD=$TMP/repo-issue-9"* ]]
}

@test "プロンプトに PR 番号とラウンドを埋める" {
  "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md"
  [[ "$output" == *"#30"* ]]
  [[ "$output" == *"1 回目"* ]]
}

@test "worktree がなければ needs-human を付けて 1 を返す" {
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 31 99 1
  [ "$status" -eq 1 ]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
}

@test "失敗したら STATE に FAILED を記録する" {
  MOCK_EXIT=7 run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}

# --- ここから brief の 4 本を超える追加テスト（brief が残したギャップを埋める） ---

@test "失敗しても Maker の worktree とそのコミットは無傷で残る（生きた作業を壊さない）" {
  # dispatch-verifier の使い捨て worktree と違い、ここは Maker の実作業。
  # エージェントが失敗しても worktree 自体はもちろん、その中の既存コミットも
  # 一切触られていないことを直接確認する
  BEFORE_SHA="$(git -C "$TMP/repo-issue-9" rev-parse HEAD)"
  MOCK_EXIT=7 run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  [ -d "$TMP/repo-issue-9" ]
  AFTER_SHA="$(git -C "$TMP/repo-issue-9" rev-parse HEAD)"
  [ "$BEFORE_SHA" = "$AFTER_SHA" ]
  run git -C "$TMP/repo-issue-9" status --porcelain
  [ -z "$output" ]
}

@test "ラウンド番号がログファイル名にそのまま出る（Task 10 がこれを数える前提）" {
  # round=1 に決め打ちせず、別のラウンド番号でもファイル名にそのまま反映される
  # ことを確認する。ここが崩れると Task 10 のラウンド計数が壊れる
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 2
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r2.md" ]
  # r1 用のログは作られていない（別ラウンドのログと混同しない）
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "エージェントが失敗してもログファイルは残る（失敗ラウンドも 1 回として数えられる）" {
  # agent-run --log は tee 経由でまずファイルを作ってから書くので、rc!=0 でも
  # ログ自体は残る。ラウンドを「消費した試行」として数える設計が壊れていないか
  # を直接確認する
  MOCK_EXIT=7 run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "maturity = L1 では拒否し worktree に触らない" {
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  BEFORE_SHA="$(git -C "$TMP/repo-issue-9" rev-parse HEAD)"
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"L1"* ]]
  AFTER_SHA="$(git -C "$TMP/repo-issue-9" rev-parse HEAD)"
  [ "$BEFORE_SHA" = "$AFTER_SHA" ]
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "worktree 消失は予算超過より優先して needs-human と判定される（誤解を招く終了理由にしない）" {
  # worktree が無い場合は budget-check より前に判定すべき（cheap check first の
  # 原則）。budget-check を先に呼ぶと、予算切れの日には本当の原因（worktree
  # 消失）が「SKIP: 予算ゲート」に化けて needs-human が付かないまま埋もれる
  use_ccusage_stub over
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 31 99 1
  [ "$status" -eq 1 ]
  [[ "$output" != *"予算"* ]]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
}

@test "予算ゲートでスキップしたら STATE に記録するが needs-human は付けない（一時的な事情と区別する）" {
  use_ccusage_stub over
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"スキップ"* ]]
  run cat "$GH_LOG"
  [[ "$output" != *"needs-human"* ]]
}

@test "成功したら STATE に ok を記録する" {
  "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"fixer pr-30 r1 ok"* ]]
}

@test "LOOP_SKIP_VERIFIER を外すと成功時に Verifier を再チェーンする" {
  unset LOOP_SKIP_VERIFIER
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"chain: dispatch-verifier"* ]]
  # 実際に dispatch-verifier まで到達し、その処理が動いたことをログの存在で確認する
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-30.md" ]
}

# --- ここから fix round 1（レビュー指摘への対応） ---------------------------

@test "worktree パス解決に失敗しても needs-human を付ける（他の失敗経路と同じ扱いにする）" {
  # -d チェック成功後に cd が失敗する経路（本来は TOCTOU: -d 判定と cd の間に
  # worktree が消える競合状態）を、bats から決定的に再現するのは困難なので、
  # 同じコード分岐を別の決定的な原因（chmod でディレクトリの実行/検索権限を
  # 落とし、-d は真のまま cd だけを失敗させる）で踏む。分岐そのものが
  # needs-human を付けるかどうかが焦点であり、失敗の引き金が消失か権限かは
  # このテストの本質ではない
  chmod 000 "$TMP/repo-issue-9"
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  chmod 755 "$TMP/repo-issue-9"
  [ "$status" -eq 1 ]
  [[ "$output" == *"worktree パス解決に失敗"* ]]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}

@test "defaults.toml の tools_fixer に gh issue edit の許可が含まれる（needs-human の逃げ道を塞がない）" {
  # fixer.md の唯一のエスカレーション手段は gh issue edit --add-label
  # needs-human。claude provider の --allowedTools はここ（agents.claude.
  # tools_fixer）から読むので、欠けていると本番でこの逃げ道だけが静かに
  # ブロックされる（mock provider はツール権限を見ないのでテストでは検出
  # できない・claude.sh 側の配線自体は Task 4 の claude-agent.bats が別途
  # 担保している）。ここでは loop-config 経由で defaults.toml の設定値
  # そのものを検証する（$LOOP_DIR/defaults.toml は setup() が本物からコピー
  # したもの）
  run "$LOOP_REAL_DIR/bin/loop-config" get agents.claude.tools_fixer
  [ "$status" -eq 0 ]
  found=0
  for line in "${lines[@]}"; do
    [ "$line" = "Bash(gh issue edit:*)" ] && found=1
  done
  [ "$found" -eq 1 ]
}
