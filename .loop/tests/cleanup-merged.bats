#!/usr/bin/env bats
# cleanup-merged: main に取り込み済みの loop worktree / branch の片付け。
# LOOP_DIR/REPO_ROOT の組み立ては helpers.bash の make_test_repo に任せる
# （各 .bats ファイルで書き下さない）。

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
}

teardown() {
  cleanup_test_repo
  rm -rf "$TMP"
}

make_wt() { # $1 = issue 番号, $2 = ファイル内容
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-$1" -b "loop/issue-$1" main
  echo "$2" > "$TMP/repo-issue-$1/b.txt"
  git -C "$TMP/repo-issue-$1" add -A
  git -C "$TMP/repo-issue-$1" commit -qm "work $1"
}

@test "main に取り込み済みの worktree とブランチを削除する" {
  make_wt 1 hello
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-1
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-1" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-1
  [ "$status" -ne 0 ]
}

@test "未マージの worktree には触らない" {
  make_wt 2 world
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-2" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-2
  [ "$status" -eq 0 ]
}

@test "loop/ 以外の worktree には触らない" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/other" -b feature/mine main
  git -C "$REPO_ROOT" merge -q --no-edit feature/mine
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/other" ]
}

@test "片付けるものがなければ何も出力しない" {
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- ここから brief の 4 本を超える安全側の追加テスト ---
# これらは「消してよいか迷ったら消さない」という本タスクの中心的な性質を
# 直接検証する。ブランチが main の祖先であるかどうかしか見ない実装だと、
# 以下のケースで作業（コミットされていない変更）を消してしまう。

@test "マージ済みでも未コミットの変更が残る worktree には触らない" {
  make_wt 3 hi
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-3
  # 追跡済みファイルへの未コミットの変更
  echo dirty >> "$TMP/repo-issue-3/b.txt"
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-3" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-3
  [ "$status" -eq 0 ]
  # 何も片付けていないので出力もない
  [ -z "$output" ]
}

@test "マージ済みでも未追跡ファイルが残る worktree には触らない" {
  make_wt 4 hi
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-4
  # git add されていない新規ファイル（--force なら worktree remove で
  # 一緒に消えてしまう）
  echo scratch > "$TMP/repo-issue-4/untracked.txt"
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-4" ]
  [ -f "$TMP/repo-issue-4/untracked.txt" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-4
  [ "$status" -eq 0 ]
}

@test "detached HEAD の worktree には触らない" {
  git -C "$REPO_ROOT" worktree add -q --detach "$TMP/detached" main
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/detached" ]
}

@test "メインの作業ツリー自体には触らない" {
  make_wt 5 hello
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-5
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$REPO_ROOT" ]
  run git -C "$REPO_ROOT" rev-parse --is-inside-work-tree
  [ "$status" -eq 0 ]
}
