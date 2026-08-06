#!/usr/bin/env bats
# dispatch-verifier: PR を検証用の使い捨て worktree に detached で checkout し、
# Verifier を headless 起動する。
#
# --detach が必須である理由: PR の head ブランチは Maker の worktree が
# 既に保持しており、git は同一ブランチの二重 checkout を拒否する。
# これは本番で実際に踏んだバグなので、checkout が起きたことだけでなく
# 引数に --detach が含まれることそのものをテストで固定する。
#
# 検証用 worktree は throwaway。成功/エージェント失敗/checkout失敗/予算スキップの
# どの終了経路でも必ず削除されることを確認する（trap が worktree 作成の
# 直後に 1 本だけ install されており、PROMPT 用の trap を後から別に
# install して上書き・消失させていないことも含む）。
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
}

teardown() {
  cleanup_test_repo
  rm -rf "$TMP"
}

@test "detached で checkout する" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  run cat "$GH_LOG"
  [[ "$output" == *"pr checkout 21 --detach"* ]]
}

@test "プロンプトに PR 番号とプロジェクトのコマンドを埋める" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.md"
  [[ "$output" == *"#21"* ]]
  [[ "$output" == *"pnpm -r test"* ]]
}

@test "終了時に検証用 worktree を削除する" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ ! -d "$TMP/repo-verify-pr-21" ]
}

@test "成功したら STATE に ok を記録する" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"verifier pr-21 ok"* ]]
}

@test "失敗したら STATE に FAILED を記録して 1 を返す" {
  MOCK_EXIT=2 run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}

# --- ここから brief の 5 本を超える追加テスト（brief が残したギャップを埋める） ---

@test "エージェントが失敗しても検証用 worktree を削除する（throwaway なので残置しない）" {
  MOCK_EXIT=2 run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  [ ! -d "$TMP/repo-verify-pr-21" ]
}

@test "--detach checkout に失敗したら STATE に FAILED を記録し worktree を削除する" {
  GH_EXIT=1 run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  [ ! -d "$TMP/repo-verify-pr-21" ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"gh pr checkout"* ]]
}

@test "予算ゲートでスキップしたら worktree を作らずに STATE へ記録して 1 を返す" {
  use_ccusage_stub over
  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  [ ! -d "$TMP/repo-verify-pr-21" ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"スキップ"* ]]
}

@test "maturity = L1 では拒否し worktree を作らない" {
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  [[ "$output" == *"L1"* ]]
  [ ! -d "$TMP/repo-verify-pr-21" ]
}

@test "一過性エラーは 1 回だけ自動リトライし、1 回目のログを上書きしない" {
  # dispatch-maker で採用された「リトライは別名の .retry.md に書く」修正を
  # dispatch-verifier にも同様に適用したので、ここでも直接確認する。
  # agent-run --log は非追記の tee なので、同じログパスへ 2 回書くと
  # 1 回目の失敗理由（なぜ落ちたか）が消えてしまう
  printf '[agent]\nprovider = "retry-mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[retry]\ndelay_seconds = 0\n' \
    > "$LOOP_DIR/config.toml"

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

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]
  [ -f "$MARK" ]
  run tail -5 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"一過性エラー"* ]]
  [[ "$output" == *"リトライ"* ]]

  ORIG_LOG="$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.md"
  RETRY_LOG="$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.retry.md"
  [ -f "$ORIG_LOG" ]
  [ -f "$RETRY_LOG" ]
  run cat "$ORIG_LOG"
  [[ "$output" == *"ETIMEDOUT"* ]]
  run cat "$RETRY_LOG"
  [[ "$output" == *"retry succeeded"* ]]

  # リトライ経路でも throwaway worktree はちゃんと消える
  [ ! -d "$TMP/repo-verify-pr-21" ]
}
