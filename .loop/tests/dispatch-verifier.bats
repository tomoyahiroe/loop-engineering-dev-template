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

# --- ここから fix round 1（レビュー指摘への対応） ---------------------------
# STATE.md は人間が毎朝読む一次情報。「検証用 worktree パスが既に存在する」
# という良性のレース（他の起動が同じ PR を検証中、等）を本物のエラーと同じ
# FAILED で記録すると、運用者が FAILED を無視する学習をしてしまう。
# このケースだけ SKIPPED として exit 0 にし、かつ他の起動が使っている
# （かもしれない）ディレクトリには一切触れない（trap 未 install のまま return）
# ことを固定する。

@test "検証用 worktree パスが既に存在する場合は SKIPPED で 0 を返し、既存ディレクトリに触れない" {
  mkdir -p "$TMP/repo-verify-pr-21"
  echo "other-invocation-marker" > "$TMP/repo-verify-pr-21/marker.txt"

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]

  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
  [[ "$output" != *"FAILED"* ]]

  # 既存ディレクトリとその中身が trap で消されていない（他の起動の worktree
  # を巻き込んでいないことの直接証拠）
  [ -d "$TMP/repo-verify-pr-21" ]
  run cat "$TMP/repo-verify-pr-21/marker.txt"
  [[ "$output" == "other-invocation-marker" ]]

  # gh pr checkout まで到達していない（パス存在チェックで即 return したこと）
  [ ! -f "$GH_LOG" ]
}

# --- Final review: 所有者のいない残骸 worktree を引き取る --------------------
# SIGKILL で dispatch-verifier が死ぬと、使い捨てのはずの検証用 worktree が
# 残る。cleanup-merged は detached worktree を対象にせず、preview stop は
# preview パスしか見ないので、誰も片付けない。旧実装はパスの存在だけで
# 一律 SKIP していたため、その PR の検証が二度と行われなくなっていた。

@test "所有者のいない残骸の検証用 worktree は引き取って検証をやり直す" {
  # SIGKILL で残った状態を再現する（worktree は登録済み・所有者マーカーは
  # 無い、または死んだ PID）
  git -C "$REPO_ROOT" worktree add -q --detach "$TMP/repo-verify-pr-21" main
  echo 999999 > "$REPO_ROOT/loops/.wt-owner-verify-pr-21"

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]

  # 実際に検証が走った（ログがあり、STATE に ok が記録される）
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.md" ]
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"引き取った"* ]]
  [[ "$output" == *"verifier pr-21 ok"* ]]

  # 使い捨て worktree は最後に片付き、所有権マーカーも残らない
  [ ! -d "$TMP/repo-verify-pr-21" ]
  [ ! -f "$REPO_ROOT/loops/.wt-owner-verify-pr-21" ]
}

@test "所有者マーカーが無いだけの残骸も引き取る（旧バージョンからの移行）" {
  git -C "$REPO_ROOT" worktree add -q --detach "$TMP/repo-verify-pr-21" main
  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.md" ]
  [ ! -d "$TMP/repo-verify-pr-21" ]
}

@test "所有権マーカーが壊れていても検証は止まらない（引き取る側は逆に倒す）" {
  # cleanup-merged（削除する側）は壊れたマーカーを「所有されている」と読んで
  # 触らないのが正しいが、こちら（引き取る側）で同じ既定にすると、壊れた
  # マーカー 1 つでその PR が毎 tick SKIP され、二度と検証されなくなる
  # （finding 7 で塞いだはずの静かな恒久停止がマーカー経由で復活する）
  git -C "$REPO_ROOT" worktree add -q --detach "$TMP/repo-verify-pr-21" main
  printf 'not-a-pid\n' > "$REPO_ROOT/loops/.wt-owner-verify-pr-21"

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]
  [[ "$output" != *"SKIP"* ]]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.md" ]
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"verifier pr-21 ok"* ]]
  [ ! -d "$TMP/repo-verify-pr-21" ]
}

@test "生きた所有者がいる検証用 worktree には触らず SKIPPED で 0 を返す" {
  git -C "$REPO_ROOT" worktree add -q --detach "$TMP/repo-verify-pr-21" main
  echo "other-invocation-marker" > "$TMP/repo-verify-pr-21/marker.txt"
  # 生きている PID（このテストプロセス自身）を所有者として書く
  echo $$ > "$REPO_ROOT/loops/.wt-owner-verify-pr-21"

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
  [[ "$output" != *"FAILED"* ]]

  # 他の起動が使っているディレクトリとその中身に一切触れていない
  [ -d "$TMP/repo-verify-pr-21" ]
  run cat "$TMP/repo-verify-pr-21/marker.txt"
  [[ "$output" == "other-invocation-marker" ]]
  [ ! -f "$GH_LOG" ]
}

@test "検証中は所有権マーカーがあり、正常終了で解放される" {
  cat > "$LOOP_DIR/agents/probe.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [ -f "$REPO_ROOT/loops/.wt-owner-verify-pr-21" ]; then
  echo claimed > "$TMP/claim-state"
else
  echo unclaimed > "$TMP/claim-state"
fi
exit 0
EOF
  chmod +x "$LOOP_DIR/agents/probe.sh"
  printf '[agent]\nprovider = "probe"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/claim-state")" = "claimed" ]
  [ ! -f "$REPO_ROOT/loops/.wt-owner-verify-pr-21" ]
}

@test "既存パス以外の理由で worktree 作成に失敗したら FAILED を記録して 1 を返す" {
  # main ブランチ名を変えて git worktree add --detach <WT> main を
  # 「main が解決できない」という、パス存在とは無関係な genuine failure にする
  git -C "$REPO_ROOT" branch -m main renamed-main

  run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]

  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" != *"SKIPPED"* ]]

  [ ! -d "$TMP/repo-verify-pr-21" ]
}
