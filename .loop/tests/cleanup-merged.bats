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
# --- Final review: squash merge の検出（片付け漏れ）と、その裏返しである
# 「未マージを消さない」性質の両方向を固定する -------------------------------
# firing の L3 自動 merge は `gh pr merge --squash` を使う。squash merge された
# ブランチの先頭コミットは main の祖先にならないため、merge-base --is-ancestor
# だけを見る旧実装では、ループが自分で merge した PR の worktree とブランチが
# 1 件も片付かなかった（merge のたびにフルチェックアウトが 1 つ増え続ける）。

make_squash_merged_wt() { # $1 = issue 番号（2 コミット持つブランチを squash merge する）
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-$1" -b "loop/issue-$1" main
  printf 'first\n' > "$TMP/repo-issue-$1/s.txt"
  git -C "$TMP/repo-issue-$1" add -A
  git -C "$TMP/repo-issue-$1" commit -qm "work $1 part 1"
  printf 'first\nsecond\n' > "$TMP/repo-issue-$1/s.txt"
  git -C "$TMP/repo-issue-$1" add -A
  git -C "$TMP/repo-issue-$1" commit -qm "work $1 part 2"
  git -C "$REPO_ROOT" merge -q --squash "loop/issue-$1" >/dev/null
  git -C "$REPO_ROOT" commit -qm "squash merge of issue $1"
}

@test "squash merge されたブランチは片付ける（先頭コミットは main の祖先にならない）" {
  make_squash_merged_wt 11
  # 前提の確認: 祖先判定だけでは検出できないこと自体をテストで固定する
  run git -C "$REPO_ROOT" merge-base --is-ancestor loop/issue-11 main
  [ "$status" -ne 0 ]

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-11" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-11
  [ "$status" -ne 0 ]
}

@test "squash merge のあと main が先に進んでいても片付ける" {
  make_squash_merged_wt 12
  echo later > "$REPO_ROOT/later.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm "別の作業が main に入った"

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-12" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-12
  [ "$status" -ne 0 ]
}

@test "内容が似ているだけの未マージブランチには触らない（同じファイルの別内容）" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-13" -b loop/issue-13 main
  printf 'similar content\n' > "$TMP/repo-issue-13/c.txt"
  git -C "$TMP/repo-issue-13" add -A
  git -C "$TMP/repo-issue-13" commit -qm "issue 13 の実装"
  # main 側に「似ているが同一ではない」変更が入る
  printf 'similar content but not the same\n' > "$REPO_ROOT/c.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm "main 側の別実装"

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-13" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-13
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "空白だけが違う未マージブランチにも触らない（patch-id 方式なら誤検出する罠）" {
  # git cherry / git patch-id は差分の空白を無視するため、この 2 つを
  # 「同等の変更」とみなす。ツリーの完全一致で判定していれば未マージのまま
  # 残るはず。判定方式を patch-id に戻したらこのテストが落ちる
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-14" -b loop/issue-14 main
  printf 'hello  world\n' > "$TMP/repo-issue-14/w.txt"
  git -C "$TMP/repo-issue-14" add -A
  git -C "$TMP/repo-issue-14" commit -qm "issue 14"
  printf 'hello world\n' > "$REPO_ROOT/w.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm "main 側は空白が 1 つ少ない"

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-14" ]
  [ -f "$TMP/repo-issue-14/w.txt" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-14
  [ "$status" -eq 0 ]
}

@test "squash merge 済みでも未コミットの変更が残る worktree には触らない（既存ガードの維持）" {
  make_squash_merged_wt 15
  echo dirty >> "$TMP/repo-issue-15/s.txt"
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-15" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-15
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "squash merge 済みでも gitignore 対象のファイルが残る worktree には触らない（既存ガードの維持）" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-16" -b loop/issue-16 main
  printf '.env\n' > "$TMP/repo-issue-16/.gitignore"
  printf 'first\n' > "$TMP/repo-issue-16/s.txt"
  git -C "$TMP/repo-issue-16" add -A
  git -C "$TMP/repo-issue-16" commit -qm "work 16"
  git -C "$REPO_ROOT" merge -q --squash loop/issue-16 >/dev/null
  git -C "$REPO_ROOT" commit -qm "squash merge of issue 16"
  echo 'DB_PASSWORD=secret' > "$TMP/repo-issue-16/.env"

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-16" ]
  [ -f "$TMP/repo-issue-16/.env" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-16
  [ "$status" -eq 0 ]
}

@test "squash merge 済みでも loop/issue-* / loop/preview-* 以外には触らない（既存スコープの維持）" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/experiment2" -b loop/my-experiment main
  echo x > "$TMP/experiment2/e.txt"
  git -C "$TMP/experiment2" add -A
  git -C "$TMP/experiment2" commit -qm experiment
  git -C "$REPO_ROOT" merge -q --squash loop/my-experiment >/dev/null
  git -C "$REPO_ROOT" commit -qm "squash merge of experiment"

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/experiment2" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/my-experiment
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "merge 後に main 側で revert されたブランチには触らない（安全側に倒れる）" {
  make_squash_merged_wt 17
  git -C "$REPO_ROOT" rm -q s.txt
  git -C "$REPO_ROOT" commit -qm "revert: issue 17 の変更を取り消す"

  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-17" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-17
  [ "$status" -eq 0 ]
}

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
