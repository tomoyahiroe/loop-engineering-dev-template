#!/usr/bin/env bats
# 1 サイクル（ready な Issue → gate → Maker → PR → Verifier）を
# mock provider と gh スタブで通す。
#
# brief 原文の integration.bats は harness が完成する前に書かれており、
# firing の fix-chain / L3 セクション、gh スタブの GH_STATE_DIR、
# dispatch-maker のガード並び替え、gate remediation のマーカーファイルは
# まだ存在しない前提だった。実装後に照らし合わせて確認したところ、brief の
# 1 本目のテストはそのままで（弱めずに）通ることを確認したので、内容は
# ほぼそのまま残す。ただし「本当に gate を通した結果として Maker が起動した
# のか、それとも gate 判定が事実上バイパスされていて常に起動するだけなのか」
# を区別できないという弱点があったため、直接の証拠となるアサーション
# （gate-fail マーカーが無い・loop:ready が外れた・PR checkout が --detach で
# 実際に呼ばれた・検証用 worktree が後始末された、等）を追加し、さらに
# 「gate に落ちれば Maker は起動しない」という対照テストを 1 本足して、
# 1 本目のテストが空虚な成功（何をしても通る）ではないことの裏取りにした。

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs" "$REPO_ROOT/loops/mtg"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/"
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "true"\nlint = "true"\n' \
    > "$LOOP_DIR/config.toml"

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
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "1 サイクルが完走する: gate 通過 → Maker → PR 検出 → Verifier" {
  GOOD_BODY="$(cat "$BATS_TEST_DIRNAME/fixtures/issues/good.md")"
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  export GH_ISSUE_JSON="$(node -e 'process.stdout.write(JSON.stringify({body:process.argv[1],state:"OPEN"}))' "$GOOD_BODY")"
  export GH_PR_LIST_JSON='[{"number":40,"headRefName":"loop/issue-5","reviewDecision":null,"labels":[]}]'

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  # gate が本当に評価されて通過した証拠（バイパスされていない）:
  # remediation マーカーは無く、loop:ready は正規の dispatch 経路で外れている
  [ ! -f "$REPO_ROOT/loops/.gate-failed-5" ]

  # Maker が worktree/branch を作って実際に起動した
  [ -d "$TMP/repo-issue-5" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-5
  [ "$status" -eq 0 ]
  MAKER_LOG="$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-5.md"
  [ -f "$MAKER_LOG" ]
  run cat "$MAKER_LOG"
  [[ "$output" == *"#5"* ]]

  # Verifier が PR #40 に対して起動し、--detach で checkout した
  # （K3 ガード: 同一ブランチの二重 checkout を避けるための detach が
  # 単体テストだけでなくチェーン経由でも実際に呼ばれていることの確認）
  VERIFIER_LOG="$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-40.md"
  [ -f "$VERIFIER_LOG" ]
  run cat "$VERIFIER_LOG"
  [[ "$output" == *"#40"* ]]
  run cat "$GH_LOG"
  [[ "$output" == *"pr checkout 40 --detach"* ]]
  [[ "$output" == *"issue edit 5 --remove-label loop:ready"* ]]

  # 検証用の使い捨て worktree はチェーン経由でもちゃんと後始末される
  [ ! -d "$TMP/repo-verify-pr-40" ]

  # STATE に両方が記録された
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"maker issue-5 ok"* ]]
  [[ "$output" == *"verifier pr-40 ok"* ]]

  # merge はしていない（L2 が既定）。needs-human も付いていない（成功経路）
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
  [[ "$output" != *"issue edit 5 --add-label needs-human"* ]]
}

# --- 裏取り: 上のテストが「何を渡しても Maker が起動するだけ」の空虚な成功で
# はないことを確認する。同じ setup・同じ mock provider・同じ gh スタブ配線の
# まま Issue 本文だけを gate 不合格にすると、Maker は起動せず gate
# remediation 経路（loop:ready 除去 + needs-human 付与 + マーカー）に入る -----

@test "対照: gate 不合格の Issue では Maker は起動せず remediation だけが走る" {
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  export GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}'

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  # Maker は起動していない（worktree も branch も無い）
  [ ! -d "$TMP/repo-issue-5" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-5
  [ "$status" -ne 0 ]
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-5.md" ]

  # gate remediation 経路に入った証拠
  [ -f "$REPO_ROOT/loops/.gate-failed-5" ]
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
  [[ "$output" == *"--add-label needs-human"* ]]
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"dispatch 中止 #5"* ]]
}
