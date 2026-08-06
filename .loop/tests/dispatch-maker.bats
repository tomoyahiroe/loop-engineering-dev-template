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
