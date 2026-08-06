#!/usr/bin/env bats
# dispatch-maker: Issue 用に隔離された worktree を作り、Maker を headless 起動する。
# 冪等性（in-flight の二重起動防止で SKIP=0）と、失敗時に worktree を残して
# needs-human を付ける（作業保全）ことがこのスクリプトの核。
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
}

teardown() {
  cleanup_test_repo
  rm -rf "$TMP"
}

@test "worktree と branch を作って Maker を起動する" {
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-7" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-7
  [ "$status" -eq 0 ]
}

@test "プロンプトに Issue 番号とプロジェクトのコマンドを埋める" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-7.md"
  [[ "$output" == *"#7"* ]]
  [[ "$output" == *"pnpm -r test"* ]]
}

@test "loop:ready ラベルを外す" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
}

@test "既に worktree があれば SKIPPED で 0 を返す" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
}

@test "in-flight スキップでも loop:ready を剥がし直す（待ち行列が先頭で詰まらない）" {
  # loop:ready の除去は dispatch 時に best-effort で 1 回試みるだけなので、
  # gh の一過性エラーや人間の re-label で簡単に元に戻る。その状態で
  # スキップ分岐がラベルに触れないと、firing は毎 tick この Issue を
  # min(loop:ready) として選び続け、後ろの ready な Issue が永久に
  # dispatch されない（待ち行列全体が止まる）
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  rm -f "$GH_LOG"
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
}

@test "in-flight スキップが続いても STATE 記録は 1 回、除去は毎回リトライされる（3 回）" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  rm -f "$GH_LOG"
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run bash -c "grep -c 'maker issue-7 SKIPPED' \"$REPO_ROOT/loops/STATE.md\""
  [ "$output" -eq 1 ]
  run bash -c "grep -c '^issue edit 7 --remove-label loop:ready' \"$GH_LOG\""
  [ "$output" -eq 3 ]
  [ -f "$REPO_ROOT/loops/.inflight-skip-7" ]
}

@test "in-flight が解消したらスキップマーカーは片付く（次に詰まったらまた記録できる）" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ -f "$REPO_ROOT/loops/.inflight-skip-7" ]

  # worktree と branch が片付いた状態にしてから再 dispatch する
  git -C "$REPO_ROOT" worktree remove --force "$TMP/repo-issue-7"
  git -C "$REPO_ROOT" branch -D loop/issue-7
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ ! -f "$REPO_ROOT/loops/.inflight-skip-7" ]
}

@test "Maker の実行中に cleanup-merged が走っても worktree は消されない" {
  # 実機で踏んだ事故の再現: コミット前の Maker の worktree は「branch が main
  # と同一・作業ツリーはクリーン」なので、cleanup-merged からは片付けてよい
  # 残骸と完全に同じ姿に見える。並行する firing（毎 tick cleanup-merged を
  # 呼ぶ）が実行中の Maker の足元を消してしまっていた。
  # provider スタブの中から実際に cleanup-merged を走らせて直接確認する
  printf '[agent]\nprovider = "concurrent-cleanup"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"
  cat > "$LOOP_DIR/agents/concurrent-cleanup.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# Maker が「まだ何もコミットしていない」時点で cleanup-merged を走らせる
"$LOOP_REAL_DIR/bin/cleanup-merged" > "$TMP/cleanup-out.txt" 2>&1
# 自分の作業ディレクトリがまだ生きているかを記録する
if [ -d "\$LOOP_CWD" ]; then echo alive > "$TMP/wt-state"; else echo gone > "$TMP/wt-state"; fi
exit 0
EOF
  chmod +x "$LOOP_DIR/agents/concurrent-cleanup.sh"

  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/wt-state")" = "alive" ]
  [ -d "$TMP/repo-issue-7" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-7
  [ "$status" -eq 0 ]
  # cleanup 側も「片付けた」と報告していない
  run cat "$TMP/cleanup-out.txt"
  [[ "$output" != *"片付け"* ]]
}

@test "所有権マーカーは実行中だけ存在し、終了時に必ず片付く" {
  cat > "$LOOP_DIR/agents/probe.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [ -f "$REPO_ROOT/loops/.wt-owner-issue-7" ]; then
  echo "claimed:\$(cat "$REPO_ROOT/loops/.wt-owner-issue-7")" > "$TMP/claim-state"
else
  echo "unclaimed" > "$TMP/claim-state"
fi
exit \${MOCK_EXIT:-0}
EOF
  chmod +x "$LOOP_DIR/agents/probe.sh"
  printf '[agent]\nprovider = "probe"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  run cat "$TMP/claim-state"
  [[ "$output" == claimed:* ]]
  # 終了後は解放されている（残ると cleanup-merged が永久に片付けられなくなる）
  [ ! -f "$REPO_ROOT/loops/.wt-owner-issue-7" ]
}

@test "エージェントが失敗しても所有権マーカーは解放される（片付けを永久に止めない）" {
  MOCK_EXIT=5 run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  [ ! -f "$REPO_ROOT/loops/.wt-owner-issue-7" ]
  # 失敗時に worktree を残置する既存の保証は維持されている
  [ -d "$TMP/repo-issue-7" ]
}

@test "maturity = L1 では拒否する" {
  # maturity はトップレベルのキーなので、テーブル見出しより前に書く
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"L1"* ]]
}

@test "エージェントが失敗したら STATE に FAILED を記録し worktree を残す" {
  MOCK_EXIT=5 run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  [ -d "$TMP/repo-issue-7" ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}

# --- ここから brief の 6 本を超える追加テスト（brief が残したギャップを埋める） ---

@test "エージェントが失敗したら worktree 残置とあわせて needs-human ラベルを付ける" {
  MOCK_EXIT=5 run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  # 「残置」と「needs-human」は別々の保証なので両方を同じテストで確認する
  [ -d "$TMP/repo-issue-7" ]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
}

@test "loop:ready の除去はエージェント起動前に起きる（クラッシュしても即再ディスパッチされない）" {
  # MOCK_EXIT=5 でエージェントを失敗させても、--remove-label は
  # --add-label needs-human より前の行として記録されているはず。
  # remove-label はエージェント起動より前、add-label はエージェント終了後にしか
  # 呼ばれないので、この前後関係が「起動前に外れている」ことの直接証拠になる。
  MOCK_EXIT=5 run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  REMOVE_LINE="$(grep -n -- '--remove-label loop:ready' "$GH_LOG" | head -1 | cut -d: -f1)"
  ADD_LINE="$(grep -n -- '--add-label needs-human' "$GH_LOG" | head -1 | cut -d: -f1)"
  [ -n "$REMOVE_LINE" ]
  [ -n "$ADD_LINE" ]
  [ "$REMOVE_LINE" -lt "$ADD_LINE" ]
}

@test "一過性エラーは worktree が手つかずなら 1 回だけ自動リトライして成功する" {
  # is_transient_error / retry_delay 自体は common.bats で単体テスト済みだが、
  # dispatch-maker が実際にその 2 つを正しく配線し、かつ「worktree 手つかず」の
  # 追加条件込みでリトライを発火できることをここで end-to-end に確認する。
  # retry.delay_seconds を 0 にしてテストを高速化する（mock provider に切り替える
  # ので [agent] も含めて丸ごと書き直す）。
  printf '[agent]\nprovider = "retry-mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[retry]\ndelay_seconds = 0\n' \
    > "$LOOP_DIR/config.toml"

  # 1 回目は一過性エラー（ETIMEDOUT）で失敗、2 回目（リトライ）は成功する provider。
  # 状態はテスト専用の目印ファイルの有無で切り替える
  MARK="$TMP/retry-attempted"
  cat > "$LOOP_DIR/agents/retry-mock.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [ ! -f "$MARK" ]; then
  touch "$MARK"
  echo "connect ETIMEDOUT 127.0.0.1:443"
  exit 1
fi
echo "ROLE=\$LOOP_ROLE (retry succeeded)"
exit 0
EOF
  chmod +x "$LOOP_DIR/agents/retry-mock.sh"

  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -f "$MARK" ]
  run tail -5 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"一過性エラー"* ]]
  [[ "$output" == *"リトライ"* ]]

  # fix round 1: リトライは同じログファイルを上書きしない。1 回目の失敗理由
  # （ETIMEDOUT）は元のログに残り、2 回目（成功）は別名の .retry.md に残るはず
  ORIG_LOG="$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-7.md"
  RETRY_LOG="$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-7.retry.md"
  [ -f "$ORIG_LOG" ]
  [ -f "$RETRY_LOG" ]
  run cat "$ORIG_LOG"
  [[ "$output" == *"ETIMEDOUT"* ]]
  run cat "$RETRY_LOG"
  [[ "$output" == *"retry succeeded"* ]]
}

@test "2 回連続で実行しても 2 つ目の worktree は作られない（冪等性の副作用チェック）" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  run git -C "$REPO_ROOT" worktree list --porcelain
  # "worktree " で始まる行が「メインの作業ツリー」と issue-7 用の 1 つだけ
  # (= 合計 2 行) であること。SKIP が本当に新しい worktree を作っていないことの
  # 直接的な証拠にする
  COUNT="$(printf '%s\n' "$output" | grep -c '^worktree ')"
  [ "$COUNT" -eq 2 ]
}

# --- ここから fix round 1（レビュー指摘への対応） ---------------------------

@test "予算を使い切っていても既に in-flight なら SKIPPED で 0 を返す（冪等性が budget-check より優先）" {
  # 1 回目は通常どおり worktree/branch を作る（ccusage は ok のまま）
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  # 2 回目は予算を使い切った状態にしてから叩く。in-flight チェックが
  # budget-check より先に効けば、予算超過でも exit 1「SKIP: 予算ゲート」ではなく
  # exit 0「SKIPPED」になるはず
  use_ccusage_stub over
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  [[ "$output" != *"予算ゲート"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
}

@test "branch だけが既にあれば worktree がなくても SKIPPED で 0 を返す" {
  # クラッシュ後に「branch は作られたが worktree はまだ」という状態を再現する
  git -C "$REPO_ROOT" branch loop/issue-7
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
  [ ! -d "$TMP/repo-issue-7" ]
}

@test "worktree ディレクトリだけが既にあれば branch がなくても SKIPPED で 0 を返す" {
  # クラッシュ後に「worktree ディレクトリだけ残って branch 登録は無い」状態を再現する
  mkdir -p "$TMP/repo-issue-7"
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-7
  [ "$status" -eq 1 ]
}

@test "エージェントがコミット済みなら一過性エラーでもリトライしない（作業を上書きしない）" {
  # リトライ条件の中で一番重要なケース: 「途中まで進んだ WIP」を黙って
  # 2 回目の実行で踏みつぶさないこと。retry-mock.sh と同じ手法で、今度は
  # 1 回目の呼び出し内で worktree にコミットしてから一過性エラーを起こす
  # provider スタブをその場で作る
  printf '[agent]\nprovider = "commit-then-fail"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[retry]\ndelay_seconds = 0\n' \
    > "$LOOP_DIR/config.toml"

  COUNTER="$TMP/attempt-count"
  cat > "$LOOP_DIR/agents/commit-then-fail.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
COUNT_FILE="$COUNTER"
N=0
[ -f "\$COUNT_FILE" ] && N="\$(cat "\$COUNT_FILE")"
N=\$((N + 1))
echo "\$N" > "\$COUNT_FILE"
cd "\$LOOP_CWD"
echo wip > wip.txt
git add wip.txt
git -c user.email=t@example.com -c user.name=t commit -qm "wip: partial work" >/dev/null
echo "connect ETIMEDOUT 127.0.0.1:443"
exit 1
EOF
  chmod +x "$LOOP_DIR/agents/commit-then-fail.sh"

  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  # 1 回しか呼ばれていない（= リトライしていない）ことを直接数える
  [ "$(cat "$COUNTER")" -eq 1 ]
  run tail -5 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" != *"リトライ"* ]]
  # worktree のコミットが上書き・破棄されずに残っている
  run git -C "$TMP/repo-issue-7" log --oneline -1
  [[ "$output" == *"wip: partial work"* ]]
}
