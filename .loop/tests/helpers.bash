# bats から source される共通ヘルパー。
# 全 bats ファイルの setup() はここの関数を呼ぶ（各ファイルに書き下さない）。
LOOP_REAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LOOP_REAL_DIR

# fixture 用の LOOP_DIR を作る。defaults.toml は実物をコピーし、
# config.toml は呼び出し側が書き込む。コード(lib/bin)は実物を使う
make_loop_dir() {
  local dest="$1"
  mkdir -p "$dest/agents" "$dest/prompts"
  cp "$LOOP_REAL_DIR/defaults.toml" "$dest/defaults.toml"
  : > "$dest/config.toml"
  echo "$dest"
}

# 一時 git リポジトリを作り、REPO_ROOT / LOOP_DIR / TEST_TMP を export する。
# $1 = 一時ディレクトリ（呼び出し側が mktemp -d して teardown で消す）
make_test_repo() {
  TEST_TMP="$1"; export TEST_TMP
  REPO_ROOT="$1/repo"; export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs" "$REPO_ROOT/loops/mtg"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"; export LOOP_DIR
  # compose のプロジェクト名。健全な初期状態の一部として作る（無いと
  # loop-doctor が「他のリポジトリのループと衝突する」と正しく NG を出し、
  # doctor 以外を見たいテストまで巻き添えで落ちる）。
  # 名前は実物の解決ロジックに決めさせる（ここで直書きするとズレる）
  mkdir -p "$REPO_ROOT/docker"
  LOOP_DIR="$LOOP_DIR" REPO_ROOT="$REPO_ROOT" \
    "$LOOP_REAL_DIR/bin/compose-env" >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
}

# mock provider を有効にし、実物のプロンプトを fixture にコピーする。
# config.toml を provider=mock + [project] コマンド付きで上書きする
use_mock_agent() {
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/" 2>/dev/null || true
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"
}

# claude provider を有効にする。実物の agents/claude.sh とプロンプトを
# fixture にコピーし、PATH には fixtures/bin の claude スタブを置く。
# config.toml は呼び出し側が書く（ツール許可リストの検証が目的のため）。
# mock provider は許可リストを一切見ないので、その手のガードは mock では
# 踏めない。provider = "claude" を使うテストだけがここを通る
use_claude_agent() {
  cp "$LOOP_REAL_DIR/agents/claude.sh" "$LOOP_DIR/agents/claude.sh"
  chmod +x "$LOOP_DIR/agents/claude.sh"
  # agents/claude.sh は設定の読み出し口を自分からの相対パス（../bin/loop-config）
  # で解決し、その loop-config はさらに ../lib/config-cli.mjs を読む。fixture の
  # LOOP_DIR には bin/ も lib/ も無いので、実物への symlink を張って実コードの
  # まま動かす（設定自体は LOOP_DIR 経由で fixture 側が使われる）。
  # lib も張るのは、node が ".." を先に字句解決してから開くため
  # （$LOOP_DIR/bin/../lib = $LOOP_DIR/lib を探しに行く）
  [ -e "$LOOP_DIR/bin" ] || ln -s "$LOOP_REAL_DIR/bin" "$LOOP_DIR/bin"
  [ -e "$LOOP_DIR/lib" ] || ln -s "$LOOP_REAL_DIR/lib" "$LOOP_DIR/lib"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/" 2>/dev/null || true
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/claude"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"; export PATH
}

# gh スタブを PATH の先頭に置き、呼び出しログを GH_LOG に貯める
use_gh_stub() {
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"; export PATH
  GH_LOG="$TEST_TMP/gh.log"; export GH_LOG
}

# ccusage スタブを差し込む。$1 = ok | over | garbage | fail
use_ccusage_stub() {
  chmod +x "$BATS_TEST_DIRNAME/fixtures/ccusage/$1.sh"
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/$1.sh"; export LOOP_CCUSAGE_CMD
}

# teardown から呼ぶ。worktree の登録を消してから一時ディレクトリを消す
cleanup_test_repo() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
}
