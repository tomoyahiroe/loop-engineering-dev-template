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

# --- Fix round 1（レビューで見つかった 2 つ目の破壊的な穴への回帰テスト） ---
# git status --porcelain は既定では .gitignore 対象のファイルを一切報告
# しない。ブランチが merge 済みで porcelain 上は「クリーン」に見えても、
# worktree に .env のような gitignore 対象の未追跡ファイル（実データ）が
# 残っている場合、旧実装は気付かずに worktree ごと削除していた
# （レビューで実際に .env の内容が消えることを確認された再現ケース）。
@test "マージ済みでも gitignore 対象のファイル(.env 等)が残る worktree には触らない" {
  make_wt 6 hi
  # .gitignore 自体をブランチのコミットに含める（main にマージされる内容の
  # 一部にする）。こうしないと .env が「gitignore 対象」と認識されない
  printf '.env\n' > "$TMP/repo-issue-6/.gitignore"
  git -C "$TMP/repo-issue-6" add .gitignore
  git -C "$TMP/repo-issue-6" commit -qm "add gitignore"
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-6
  # ブランチは main に merge 済み。ここで gitignore 対象の未追跡ファイルを
  # 置く。plain な `git status --porcelain` はこれを一切報告しない
  echo 'DB_PASSWORD=secret' > "$TMP/repo-issue-6/.env"
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-6" ]
  [ -f "$TMP/repo-issue-6/.env" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-6
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# 仕様は loop/issue-* と loop/preview-* にしか触れないと明記している。旧実装
# の case パターンは "loop/" prefix 全体にマッチしており、人間が手で作った
# loop/my-experiment のような、想定外のブランチまで merge 済み・クリーンなら
# 削除してしまっていた。
@test "loop/ prefix でも issue-*/preview-* 以外(loop/my-experiment)には触らない" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/experiment" -b loop/my-experiment main
  echo x > "$TMP/experiment/e.txt"
  git -C "$TMP/experiment" add -A
  git -C "$TMP/experiment" commit -qm "experiment"
  git -C "$REPO_ROOT" merge -q --no-edit loop/my-experiment
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/experiment" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/my-experiment
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# loop/preview-* は仕様上ちゃんと対象内であることの正例（loop/my-experiment
# を弾く修正のせいで一緒に弾かれていないことを確認する）
@test "loop/preview-* の worktree はマージ済みかつクリーンなら削除する" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/preview-1" -b loop/preview-1 main
  echo p > "$TMP/preview-1/p.txt"
  git -C "$TMP/preview-1" add -A
  git -C "$TMP/preview-1" commit -qm "preview 1"
  git -C "$REPO_ROOT" merge -q --no-edit loop/preview-1
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/preview-1" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/preview-1
  [ "$status" -ne 0 ]
}

# worktree のパスは全編クォートして扱っているはずだが、実リポジトリの
# 置き場所自体が空白や非 ASCII を含むこともあるため安価に確認しておく
@test "パスに空白や非 ASCII 文字を含む worktree でも正しく扱う" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo issue 7 テスト" -b loop/issue-7 main
  echo y > "$TMP/repo issue 7 テスト/y.txt"
  git -C "$TMP/repo issue 7 テスト" add -A
  git -C "$TMP/repo issue 7 テスト" commit -qm "work 7"
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-7
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo issue 7 テスト" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-7
  [ "$status" -ne 0 ]
}

# ローカルブランチの削除(git branch -D)が何らかの理由で失敗した場合、
# リモート削除や「片付け:」の成功reportがそのまま走ってしまうと、
# 「リモートは消えたのにローカルは残っている」という不整合な状態を
# 成功として報告してしまう。branch -D の終了コードを実際に確認してから
# 後続処理をゲートしていることを、branch -D だけを失敗させる git stub で
# 検証する
@test "ローカルブランチの削除が失敗したらリモート削除も成功reportもしない" {
  make_wt 9 hi
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-9

  GIT_REAL="$(command -v git)"
  export GIT_REAL
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "branch" ] && [ "$2" = "-D" ] && [ "$3" = "loop/issue-9" ]; then
  echo "stub: forced branch -D failure" >&2
  exit 1
fi
if [ "$1" = "push" ] && [ "$2" = "origin" ] && [ "$3" = "--delete" ]; then
  echo "STUB_PUSH_CALLED" >> "$TMP/push.log"
fi
exec "$GIT_REAL" "$@"
STUB
  chmod +x "$TMP/stubbin/git"

  PATH="$TMP/stubbin:$PATH" run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/push.log" ]
  [[ "$output" != *"片付け"* ]]
  # stub が branch -D を横取りしたので、本物の branch -D は一度も走って
  # おらず、ブランチ自体はまだ残っているはず
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-9
  [ "$status" -eq 0 ]
}
