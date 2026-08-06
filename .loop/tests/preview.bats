#!/usr/bin/env bats
# preview: アプリのプレビュー起動・停止。
# LOOP_DIR/REPO_ROOT の組み立ては helpers.bash の make_test_repo に任せる
# （各 .bats ファイルで書き下さない）。

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  printf '[project]\npreview = "sleep 30"\npreview_port = 4321\n' > "$LOOP_DIR/config.toml"
}

teardown() {
  # テストが assertion 失敗で早期リターンしても、起動しっぱなしの
  # バックグラウンドプロセスと worktree を必ず片付ける
  "$LOOP_REAL_DIR/bin/preview" stop >/dev/null 2>&1 || true
  # pgid フォールバックのテストが作る「PID ファイルには載らないグループ
  # リーダー」用の後始末。他のテストではこのファイルは存在しないので no-op
  if [ -f "$TMP/leader.pid" ]; then
    kill -9 "$(cat "$TMP/leader.pid")" 2>/dev/null || true
  fi
  cleanup_test_repo
  rm -rf "$TMP"
}

@test "main を起動すると PID ファイルができて status が RUNNING になる" {
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/.preview.pid" ]
  run "$LOOP_REAL_DIR/bin/preview" status
  [[ "$output" == RUNNING* ]]
  [[ "$output" == *"4321"* ]]
}

@test "stop するとプロセスが止まり status が STOPPED になる" {
  "$LOOP_REAL_DIR/bin/preview" main
  run "$LOOP_REAL_DIR/bin/preview" stop
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/preview" status
  [ "$output" = "STOPPED" ]
}

@test "起動していないときの status は STOPPED" {
  run "$LOOP_REAL_DIR/bin/preview" status
  [ "$output" = "STOPPED" ]
}

@test "二重起動は拒否する" {
  "$LOOP_REAL_DIR/bin/preview" main
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"既に起動"* ]]
}

@test "project.preview が空なら 1 を返す" {
  printf '[project]\npreview = ""\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"project.preview が未設定"* ]]
}

# --- ここから brief の 5 本を超える追加テスト ---
# タスクの中心的な懸念（stale pid で詰まらない／stop が実際に資源を解放する
# ／PR worktree の後片付け）を直接検証する。

@test "存在しない pid が残っていても main の起動をブロックしない（stale pid）" {
  # OS の pid_max（macOS の既定は kern.maxproc=6000 程度）を確実に超える
  # 値なので、実在するプロセスと衝突しない
  echo 999999 > "$REPO_ROOT/loops/.preview.pid"
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/preview" status
  [[ "$output" == RUNNING* ]]
}

@test "数値でない壊れた pid ファイルが残っていても main の起動をブロックしない" {
  echo "not-a-pid" > "$REPO_ROOT/loops/.preview.pid"
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/preview" status
  [[ "$output" == RUNNING* ]]
}

@test "stop は記録した pid だけでなく、その子プロセスも含めて止める" {
  # npm 等、実サーバーを fork するだけで自身は exec しないラッパーを模す。
  # $! に記録されるのはこのラッパーの pid であり、実際に資源（ここでは
  # 子プロセス）を握っているのは fork された子の方。preview stop が pid
  # ファイルを消すだけで子プロセスを取りこぼすと、このテストで検出できる。
  cat > "$TMP/fake-server.sh" <<EOF
#!/bin/sh
sleep 5 &
echo \$! > "$TMP/child.pid"
wait
EOF
  chmod +x "$TMP/fake-server.sh"
  printf '[project]\npreview = "%s"\npreview_port = 4321\n' "$TMP/fake-server.sh" \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 0 ]

  # 子プロセスの pid が書かれるまで少し待つ
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TMP/child.pid" ] && break
    sleep 0.2
  done
  [ -f "$TMP/child.pid" ]
  CHILD_PID="$(cat "$TMP/child.pid")"
  kill -0 "$CHILD_PID"  # 前提: 子プロセスはまだ生きている

  run "$LOOP_REAL_DIR/bin/preview" stop
  [ "$status" -eq 0 ]

  # pid ファイルが消えたことだけでなく、実プロセス（子）が本当に
  # 止まっていることを検証する
  run kill -0 "$CHILD_PID"
  [ "$status" -ne 0 ]
}

@test "stop で PR 用の worktree も片付く（detached なので cleanup-merged では消せない）" {
  use_gh_stub
  run "$LOOP_REAL_DIR/bin/preview" pr 7
  [ "$status" -eq 0 ]
  WT="$TMP/repo-preview-pr-7"
  [ -d "$WT" ]
  run git -C "$REPO_ROOT" worktree list --porcelain
  [[ "$output" == *"preview-pr-7"* ]]

  run "$LOOP_REAL_DIR/bin/preview" stop
  [ "$status" -eq 0 ]
  [ ! -d "$WT" ]
  run git -C "$REPO_ROOT" worktree list --porcelain
  [[ "$output" != *"preview-pr-7"* ]]
}

# --- Fix round 1（コーディネーターレビュー対応）で追加した 2 本 ---

@test "main 起動中に pr を実行すると worktree を作らずに拒否する（起動中チェックが worktree 作成より先）" {
  use_gh_stub
  "$LOOP_REAL_DIR/bin/preview" main
  run "$LOOP_REAL_DIR/bin/preview" pr 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"既に起動"* ]]
  WT="$TMP/repo-preview-pr-9"
  [ ! -d "$WT" ]
  run git -C "$REPO_ROOT" worktree list --porcelain
  [[ "$output" != *"preview-pr-9"* ]]
}

@test "pid が自分自身のグループリーダーでなければ単発 kill にとどめ、同じグループの他プロセスは巻き込まない" {
  # 自前でプロセスグループを作る。LEADER がグループリーダー（pgid=自分の pid）、
  # CHILD はその中で fork された非リーダー（pgid=LEADER の pid、CHILD 自身の
  # pid とは一致しない）。PID ファイルには CHILD の pid だけを書き込み、
  # 「pid ファイルが指すプロセスは実在するが、そのプロセスグループの
  # リーダーではない」状況（pid 再利用や外部要因で pid ファイルの中身が
  # preview 自身の起動対象とズレたケースを模す）を再現する。
  # LEADER は CHILD の生死と無関係に一定時間生き続けるようにし
  # （CHILD を待たない）、CHILD だけを先に消してもテストが安定するようにする。
  set -m
  ( sleep 4 & echo $! > "$TMP/group-child.pid"; sleep 4 ) &
  LEADER_PID=$!
  set +m
  echo "$LEADER_PID" > "$TMP/leader.pid"  # 失敗時も teardown が必ず片付けられるように

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TMP/group-child.pid" ] && break
    sleep 0.2
  done
  [ -f "$TMP/group-child.pid" ]
  CHILD_PID="$(cat "$TMP/group-child.pid")"

  # 前提: CHILD は生きているが、自分自身のグループリーダーではない
  kill -0 "$CHILD_PID"
  kill -0 "$LEADER_PID"
  PGID_OF_CHILD="$(ps -o pgid= -p "$CHILD_PID" | tr -d ' ')"
  [ "$PGID_OF_CHILD" != "$CHILD_PID" ]
  [ "$PGID_OF_CHILD" = "$LEADER_PID" ]

  echo "$CHILD_PID" > "$REPO_ROOT/loops/.preview.pid"
  printf 'main http://localhost:4321\n' > "$REPO_ROOT/loops/.preview.meta"

  run "$LOOP_REAL_DIR/bin/preview" stop
  [ "$status" -eq 0 ]

  # 単発 kill で CHILD 自体は止まっている
  run kill -0 "$CHILD_PID"
  [ "$status" -ne 0 ]
  # しかし同じグループの LEADER（sibling）は無事
  # （プロセスグループ全体を巻き込んでいたら道連れで死んでいるはず）
  kill -0 "$LEADER_PID"
}
