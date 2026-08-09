#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  use_gh_stub
  # ccusage は必ずスタブする。このファイルには doctor の判定と実行時ガードの
  # 一致を確かめるために dispatch-maker を起動するテストがあり、スタブが無いと
  # budget-check が本物の `npx ccusage@latest` を叩いて**開発者のその日の実際の
  # トークン使用量**で合否が変わる（実際に、使用量が budget.daily_tokens の
  # 既定 120M を超えた時点で 3 本が落ちた）。ここで見たいのは予算ゲートでは
  # ないので、環境に依存しない値に固定する
  use_ccusage_stub ok
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/docker"
  DOCKER_LOG="$TEST_TMP/docker.log"; export DOCKER_LOG
  # 既定は「全部健全」
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"},{"name":"needs-human"},{"name":"loop:auto-merge"}]'
  export GH_LABEL_LIST_JSON
  DOCKER_PS_JSON='[{"Service":"loop","State":"running"}]'; export DOCKER_PS_JSON
  printf '[project]\ntest = "make test"\nlint = "make lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
}

teardown() { cleanup_test_repo; rm -rf "$TMP"; }

@test "全部健全なら終了コード 0" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "ラベルが欠けていたら NG になり終了コード 1" {
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"}]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG"* ]]
  [[ "$output" == *"needs-human"* ]]
}

@test "test が設定済みで extra_tools が空なら NG" {
  printf '[project]\ntest = "make test"\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra_tools"* ]]
}

@test "test も lint も空なら extra_tools が空でも OK" {
  printf '[project]\ntest = ""\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}

@test "config.toml が壊れていたら NG" {
  printf 'これは TOML ではない [[[\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   config 構文"* ]]
}

# --- 最終レビューの修正: 読めない入力から答えを出さない -----------------------

@test "config を読めないとき、後続の検査は OK ではなく SKIP になる" {
  # コードレビュー指摘: config が読めないのに project/tools 検査が
  # 「OK … 未設定」と答えていた（読んでいない入力から OK を出していた）。
  # さらに生の TOML パースエラーが結果行の間に混ざり、「各行は OK/NG/SKIP で
  # 始まる」という出力形式の契約も壊れていた
  printf 'これは TOML ではない [[[\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP project/tools 対応"* ]]
  [[ "$output" == *"SKIP cron 発火時刻"* ]]
  [[ "$output" != *"OK   project/tools 対応"* ]]
  [[ "$output" != *"OK   cron 発火時刻"* ]]
  # 出力形式の契約（生のパースエラーが行の間に漏れていない）
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == OK* || "$line" == NG* || "$line" == SKIP* ]]
  done <<< "$output"
}

@test "依存が入っていないだけの状態を config 構文エラーと誤診しない" {
  # クローン直後は .loop/node_modules が無い（gitignore されている）。
  # このとき loop-config は ERR_MODULE_NOT_FOUND で落ちるが、これは
  # config.toml の内容とは無関係。「TOML の構文を確認する」と案内すると、
  # ユーザーは完全に妥当なファイルを延々と読み直すことになる
  STUB="$TEST_TMP/nodestub"
  mkdir -p "$STUB"
  cat > "$STUB/node" <<'EOF'
#!/usr/bin/env bash
echo "Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'smol-toml'" >&2
exit 1
EOF
  chmod +x "$STUB/node"
  PATH="$STUB:$PATH" run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   実行環境"* ]]
  [[ "$output" == *"npm ci"* ]]
  [[ "$output" != *"NG   config 構文"* ]]
  [[ "$output" != *"TOML の構文"* ]]
  [[ "$output" == *"SKIP config 構文"* ]]
}

@test "node が無ければ実行環境が NG になり、config は SKIP になる" {
  # /usr/bin:/bin に node がある環境ではこの経路を作れないので飛ばす
  if PATH=/usr/bin:/bin command -v node >/dev/null 2>&1; then
    skip "この環境では PATH から node を外せない"
  fi
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:/usr/bin:/bin" run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   実行環境"* ]]
  [[ "$output" == *"node"* ]]
  [[ "$output" == *"SKIP config 構文"* ]]
}

@test "コンテナが動いていなければ NG、認証は SKIP になる" {
  DOCKER_PS_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
}

@test "SKIP は失敗として数えない（コンテナ OK・他は全部健全なら 0）" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}

@test "claude が起動できなければ NG" {
  DOCKER_CLAUDE_EXIT=1 run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  # "claude" という文字列だけだと OK 行にも常に出るため真になってしまう。
  # NG 行そのものに絞って確認する
  [[ "$output" == *"NG   claude CLI"* ]]
}

@test "claude 認証は「確認できない」と言う（--version の成功を認証済みと報告しない）" {
  # コードレビュー指摘: `claude --version` は認証が切れていても 0 で終わる。
  # それを「claude 認証: コンテナ内で利用できる」と報告するのは、確かめて
  # いないことを報告していることになる。検査名を実際に確かめたこと
  # （CLI が起動する）に合わせ、認証は SKIP として明示する
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK   claude CLI"* ]]
  [[ "$output" == *"SKIP claude 認証"* ]]
  [[ "$output" != *"OK   claude 認証"* ]]
}

# --- Task 3 Fix round 1 で追加・更新した回帰テスト ---------------------------
# コードレビュー指摘: 「worktree 残骸」の NG は所有者のいない worktree を
# verify-pr-N というキーでしか報告しておらず、/loop-doctor スキルの対応表が
# 案内する `git worktree remove --force <path>` の <path> を人間もエージェントも
# 出力から取れなかった（別途 git worktree list を叩いてパスを組み立て直す
# 必要があった）。loop-doctor 側でキーではなく実パス（$WT）を出すよう修正し、
# 対応表のコマンドがそのままコピペで機能することをテストで固定する

@test "所有者のいない検証用 worktree を検出する（実パスが出力に含まれ、そのままコピペできる）" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  # git worktree list --porcelain が実際に返すパスを別途取得する（symlink 解決
  # などで $TEST_TMP と一致しないことがあるため、doctor と同じ経路で取る）
  WT_PATH="$(git -C "$REPO_ROOT" worktree list --porcelain | awk '/verify-pr-9/{print $2}')"
  [ -n "$WT_PATH" ]

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify-pr-9"* ]]
  # コードレビュー指摘: 以前はキー（verify-pr-9）しか出しておらず、
  # `git worktree remove --force <path>` を実行するには別途
  # git worktree list でパスを組み立て直す必要があった。実パスがそのまま
  # 出力に含まれていること（単なるキー文字列ではなく実在パスであること）を
  # 直接確認する
  [[ "$output" == *"$WT_PATH"* ]]
  [[ "$WT_PATH" == */repo-verify-pr-9 ]]
}

@test "doctor が出す実パスをそのまま git worktree remove --force に渡すと片付く（対応表の手順が実際に機能することの確認）" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   worktree 残骸"* ]]

  # NG 行に出た文字列から抜き出すのではなく、出力に含まれているはずの実パスを
  # git 自身から取り直して、それをそのまま remove --force に渡す。これは
  # 「対応表のコマンドをコピペしたら実際に直る」ことの確認であり、対応表の
  # 記述と loop-doctor の出力が食い違っていない（プレースホルダではなく
  # 実行可能な値になっている）ことを保証する
  WT_PATH="$(git -C "$REPO_ROOT" worktree list --porcelain | awk '/verify-pr-9/{print $2}')"
  [[ "$output" == *"$WT_PATH"* ]]
  git -C "$REPO_ROOT" worktree remove --force "$WT_PATH"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" == *"worktree 残骸: なし"* ]]
}

@test "空白を含むパスの残骸 worktree でも、1 件 1 行で境界が曖昧にならない" {
  # コードレビュー指摘: 残骸パスを空白で連結していたため、空白を含むパスが
  # 混ざると境界が消え、対応表が案内する
  # `git worktree remove --force <path>` のコピペが別の worktree を消し得た
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/my repo-verify-pr-8" main
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  WT8="$(git -C "$REPO_ROOT" worktree list --porcelain | grep 'verify-pr-8$' | sed 's/^worktree //')"
  [ -n "$WT8" ]

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  # 2 件が別々の行に出る（各行はちょうど 1 つのパスを含む）
  N_LINES="$(printf '%s\n' "$output" | grep -c '^NG   worktree 残骸')"
  [ "$N_LINES" -eq 2 ]
  [[ "$output" == *"$WT8"* ]]
  # 出力形式の契約は保たれている
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == OK* || "$line" == NG* || "$line" == SKIP* ]]
  done <<< "$output"

  # 出力に出たパスをそのまま渡せば片付く
  git -C "$REPO_ROOT" worktree remove --force "$WT8"
  git -C "$REPO_ROOT" worktree remove --force "$TEST_TMP/repo-verify-pr-9"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" == *"worktree 残骸: なし"* ]]
}

@test "生きた所有者のいる worktree は残骸として報告しない" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  printf '%s\n' "$$" > "$REPO_ROOT/loops/.wt-owner-verify-pr-9"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" != *"verify-pr-9"* ]]
}

@test "cron の発火時刻を報告する" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" == *"1,3,5"* ]]
}

# --- 最終レビューの修正: 丸め込まれた発火回数を OK と言わない -----------------
# gen-crontab は壊れた crontab を吐かないために異常値を安全側へ丸め、何を
# 丸めたかを stderr にだけ知らせる。doctor がその stderr を捨てると、
# 「12 回/日を頼んだのに 1 回/日で回り続ける」が OK として報告される
# （設計書がこの検査の存在理由として名指ししている壊れ方）

@test "firings_per_day が数値でなければ NG（丸め込みを OK と報告しない）" {
  printf '[schedule]\nfirings_per_day = "twelve"\n\n[project]\ntest = ""\nlint = ""\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   cron 発火時刻"* ]]
  [[ "$output" == *"twelve"* ]]
  [[ "$output" != *"OK   cron 発火時刻"* ]]
}

@test "24 を割り切らない firings_per_day も NG（設定と実際のズレを黙らせない）" {
  printf '[schedule]\nfirings_per_day = 5\nstart_hour = 0\n\n[project]\ntest = ""\nlint = ""\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   cron 発火時刻"* ]]
}

@test "設定どおりの発火回数なら OK で、実際の回数も出す" {
  printf '[schedule]\nfirings_per_day = 4\nstart_hour = 0\n\n[project]\ntest = ""\nlint = ""\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK   cron 発火時刻"* ]]
  [[ "$output" == *"0,6,12,18"* ]]
  [[ "$output" == *"4 回/日"* ]]
}

@test "--quiet は失敗した項目だけを出す" {
  GH_LABEL_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK"* ]]
  [[ "$output" == *"NG"* ]]
}

@test "--quiet で全部健全なら無出力・終了コード 0" {
  run "$LOOP_REAL_DIR/bin/loop-doctor" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "各行は OK / NG / SKIP のいずれかで始まる" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == OK* || "$line" == NG* || "$line" == SKIP* ]]
  done <<< "$output"
}

@test "SKIP だけでは終了コードは 0 のまま（コンテナ停止でも他が全部 OK なら SKIP のみが失敗コードに乗らない）" {
  DOCKER_PS_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  # コンテナ稼働自体は NG になるため終了コードは 1 だが、SKIP 行が
  # その NG とは独立に失敗としてカウントされていないことを、quiet モードで
  # NG がちょうど 1 行（コンテナ稼働のみ）であることから確認する
  [ "$status" -eq 1 ]
  NG_COUNT="$(printf '%s\n' "$output" | grep -c '^NG')"
  [ "$NG_COUNT" -eq 1 ]
  # claude CLI / claude 認証 / gh 認証 / ラベル の 4 件
  SKIP_COUNT="$(printf '%s\n' "$output" | grep -c '^SKIP')"
  [ "$SKIP_COUNT" -eq 4 ]
}

@test "config.toml が [project] を全く持たなくてもクラッシュしない" {
  printf '[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"project/tools"* ]]
}

# --- Fix round 1 で追加した回帰テスト ---------------------------------------

@test "extra_tools が件数だけ揃っていても中身が test/lint と対応していなければ NG（コードレビュー指摘の再現）" {
  # extra_tools は 1 件あるが make であって、test が使う pnpm には対応していない。
  # 件数だけを見る判定だとここが OK になってしまい、Verifier は pnpm を
  # 実行できないまま diff だけを読んで approve する — この検査が本来
  # 捕まえるべき、まさにその失敗
  printf '[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "複合コマンド（cd ... && pnpm test）でも中身の非組み込みコマンド名を拾って判定する" {
  # cd 自体は組み込み read-only（相対パス）なので許可が要らない。ここで
  # 不足として拾われるべきなのは pnpm の方
  printf '[project]\ntest = "cd packages/web && pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]
  [[ "$output" != *"（cd）"* ]]
}

@test "extra_tools の中身が test/lint のコマンドをちゃんと covers していれば OK（誤検知しない）" {
  printf '[project]\ntest = "cd packages/web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(cd:*)", "Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "sh -c '...' のように中身が読み切れない形は件数チェックにフォールバックする（安全側）" {
  printf '[project]\ntest = "sh -c \\"pnpm test\\""\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(anything:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "loop-doctor と実行時ガード（require_project_tools_allowed）は同じ設定に対して同じ答えを返す（doctor は NG、dispatch-maker は REFUSED）" {
  # コードレビュー指摘: doctor と実行時ガードが同じ穴（件数だけを見る判定）を
  # 共有していた。共通ヘルパーに切り出した後、両者が食い違わないことを直接確認する
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "リポジトリのパスに -verify-pr- を含んでいても、それだけでは残骸扱いしない（ベース名でアンカーする）" {
  # コードレビュー指摘: パス全体の部分一致で判定すると、リポジトリ名
  # （の親ディレクトリ）に -verify-pr- が含まれるだけでプライマリ worktree
  # 自身を誤検知し、健全な状態でも毎回 NG が出続けていた
  OUTER="$(mktemp -d)"
  TMP2="$OUTER/my-verify-pr-template"
  mkdir -p "$TMP2"
  make_test_repo "$TMP2"
  use_gh_stub
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/docker"
  DOCKER_LOG="$TEST_TMP/docker2.log"; export DOCKER_LOG
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"},{"name":"needs-human"},{"name":"loop:auto-merge"}]'
  export GH_LABEL_LIST_JSON
  DOCKER_PS_JSON='[{"Service":"loop","State":"running"}]'; export DOCKER_PS_JSON
  printf '[project]\ntest = "make test"\nlint = "make lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  # リポジトリのパス自体（$LOOP_DIR/config.toml 等）には "verify-pr" を含む
  # 文字列が正当に出てくる（config 構文チェックのメッセージ等）ので、
  # 全体を verify-pr で検索するのではなく worktree 残骸の行だけを見る
  [[ "$output" == *"worktree 残骸: なし"* ]]
  [[ "$output" != *"NG   worktree 残骸"* ]]

  rm -rf "$OUTER"
}

# --- Fix round 2 で追加した回帰テスト ---------------------------------------
# コードレビュー指摘: round 1 の修正が過剰に振れ、Claude Code の組み込み
# read-only コマンド（ls/cat/echo/pwd/head/tail/grep/find/wc/which/diff/
# stat/du/cd と read-only な git。出典: code.claude.com/docs/en/permissions.md
# "Read-only commands"）まで extra_tools への許可が必要と誤判定していた。
# `cd packages/web && pnpm test` はこのハーネス自身が Issue テンプレート /
# loop-gate で推奨している「実行ディレクトリ込みのコマンド」の形そのものであり、
# monorepo では最も普通の書き方なので、これを NG にすると正しい設定でループが
# 起動しなくなる（元のバグより有害）

@test "cd + npm（組み込み cd と許可済み npm）は doctor でも実行時ガードでも OK" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "cd web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 2
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "cd + pnpm（許可が make のみ）は本物の不一致として今も NG になる" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "cd web && pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 3
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "組み込みコマンドだけで構成された test（echo skip）は extra_tools が空でも OK" {
  printf '[project]\ntest = "echo skip"\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
  [[ "$output" == *"OK   project/tools 対応"* ]]
}

# round 2 にはここに「read-only な git サブコマンド（git status）は組み込み扱いで
# 許可が要らない」というテストがあった。round 4 で git の特別扱いを撤去したため
# 期待値が反転し、round 5 で削除した（同じ設定を、実行時ガードまで見る上位互換の
# テスト「git を使う test は Bash(git:*) が無ければ NG」が下の round 4 節にある）。

@test "git branch も許可が必要（git はサブコマンドを問わず判定対象）" {
  printf '[project]\ntest = "git branch -d tmp && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
}

@test "絶対パスへの cd はワーキングディレクトリの外に出られるため組み込み扱いしない" {
  printf '[project]\ntest = "cd /tmp && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"cd"* ]]
}

# --- Fix round 3 で追加した回帰テスト ---------------------------------------
# コードレビュー指摘: round 2 で cd と一部の git サブコマンドを組み込み扱い
# にしたが、同じ失敗クラスの取りこぼしが 2 件残っていた。
# (1) 先頭の環境変数代入（CI=true npm test）をコマンド名として誤抽出し、
#     正しい設定を弾いていた（cd のときと同じ「正しい設定を止める」方向）。
# (2) 当時あった「read-only な git サブコマンドの一覧」に symbolic-ref が
#     入っており、実際には `git symbolic-ref HEAD refs/heads/x` で HEAD を
#     書き換えられた（「壊れた設定を健全と報告する」偽陰性の方向）。
#     round 4 でその一覧ごと撤去し、git はサブコマンドを問わず判定対象に
#     なったので、(2) のテストは今も通るが理由が変わっている（「一覧から
#     外したから」ではなく「git 全体が対象だから」）

@test "先頭の環境変数代入（CI=true npm test）はコマンド名ではなく npm を見る" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "CI=true npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 4
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "複数連続する環境変数代入（A=1 B=2 pnpm test）も読み飛ばして pnpm を見る" {
  printf '[project]\ntest = "A=1 B=2 pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(pnpm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "環境変数代入があっても本物の不一致（CI=true npm test + Bash(make:*)）は今も NG になる" {
  printf '[project]\ntest = "CI=true npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"npm"* ]]
}

@test "git symbolic-ref も許可が必要（round 3 の偽陰性の回帰。今は git 一律の判定で通る）" {
  printf '[project]\ntest = "git symbolic-ref HEAD refs/heads/hijacked && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
}

@test "round 2 までの修正は退行していない（cd+npm は OK、pnpm+make は NG）" {
  printf '[project]\ntest = "cd web && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  printf '[project]\ntest = "pnpm -r test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"pnpm"* ]]
}

# --- Fix round 4 で追加した回帰テスト ---------------------------------------
# GIT_READONLY_SUBCMDS（「read-only な git サブコマンド」の手組み一覧。
# この定数はもう存在しない。名前が出てくるのはこの履歴の記述だけ）を
# 撤去し、git を pnpm や make と全く同じに扱うようにした。round 3 で
# symbolic-ref を外した直後、残っていた 14 件のうち 6 件（log/diff/show/
# blame/shortlog/rev-list）が --output=<path> でリポジトリ外のファイルを
# 上書きできることが実測で分かったため、一覧を「また 1 件直す」のではなく
# 消した。理由の詳細は common.sh の該当コメント。

@test "git を使う test は Bash(git:*) が無ければ NG（doctor・実行時ガードとも）" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "git status && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
  # 何を足せばいいのかが分かる形で名指しされていること（この NG の代償は
  # 「人間が 1 行足せば直る」ことが前提なので、名指しは仕様の一部）
  [[ "$output" == *"extra_tools"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 11
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"git"* ]]
}

@test "git を使う test は Bash(git:*) を足せば OK（doctor・実行時ガードとも）" {
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "git status && npm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)", "Bash(git:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
  [[ "$output" == *"OK   project/tools 対応"* ]]

  use_claude_agent
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "git log --output=<path> はリポジトリ外を上書きできる。組み込み扱いしないので NG になる" {
  # 一覧を撤去した直接の引き金。`git log --output=<外部ファイル>` は exit 0 で
  # 任意のファイルをコミットログで上書きする（実測済み）。サブコマンド名
  # （log）だけを見て read-only と判定すると、この設定が「健全」と報告される
  printf '[project]\ntest = "git log --output=/tmp/loop-doctor-should-not-be-written"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(npm:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
}

@test "git diff を許可が必要にしても、単体の POSIX diff は組み込みのまま（両者は無関係）" {
  # permissions.md の組み込み一覧にある diff は standalone の diff コマンドで
  # あって git diff とは別物。git の特別扱いを外した副作用で diff まで
  # 巻き込んでいないことを直接固定する
  printf '[project]\ntest = "diff expected.txt actual.txt"\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]

  printf '[project]\ntest = "git diff --exit-code"\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"git"* ]]
}

# --- 最終レビューの修正: コンテナ稼働と provider 差 --------------------------

@test "コンテナ名に running が含まれていても、State が running でなければ NG" {
  # コードレビュー指摘: `docker compose ps --format json` の塊全体を
  # 'running' で grep していたため、リポジトリのディレクトリ名から作られる
  # Name に "running" が含まれるだけで、クラッシュを繰り返しているコンテナが
  # 「稼働中」と報告された
  DOCKER_PS_JSON='[{"Service":"loop","Name":"my-running-repo-loop-1","State":"exited"}]' \
    run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   コンテナ稼働"* ]]
}

@test "State が running なら OK（正常系が退行していない）" {
  DOCKER_PS_JSON='[{"Service":"loop","Name":"my-running-repo-loop-1","State":"running"}]' \
    run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK   コンテナ稼働"* ]]
}

@test "provider が claude 以外なら doctor は NG ではなく SKIP（実行時ガードと同じ答え）" {
  # コードレビュー指摘: 実行時ガードは provider != claude で早期 return して
  # 通すのに、doctor 側にはその判定が無く NG と言っていた（doctor が NG・
  # 実行時は OK という、以前に塞いだのとは逆向きの食い違い）
  use_mock_agent   # provider = "mock" / test = pnpm / extra_tools は空

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" == *"SKIP project/tools 対応"* ]]
  [[ "$output" != *"NG   project/tools 対応"* ]]

  LOOP_SKIP_VERIFIER=1 run "$LOOP_REAL_DIR/bin/dispatch-maker" 77
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "狭い許可（Bash(pnpm test:*)）でも doctor は OK、dispatch も止まらない" {
  # コードレビュー指摘: Bash(cmd:*) / Bash(cmd) の 2 形しか受け付けず、
  # サブコマンドまで絞った**より狭い＝より安全な**形
  # （defaults.toml の tools_verifier 自身が使っている Bash(git log:*) の形）を
  # 「許可が無い」と判定して、3 つの dispatcher すべての起動を拒否していた
  printf '[agent]\nprovider = "claude"\n\n[project]\ntest = "pnpm test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(pnpm test:*)"]\n' \
    > "$LOOP_DIR/config.toml"

  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
  [[ "$output" == *"OK   project/tools 対応"* ]]

  use_claude_agent
  LOOP_SKIP_VERIFIER=1 run "$LOOP_REAL_DIR/bin/dispatch-maker" 78
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "狭い許可でも別コマンドは覆わない（Bash(pnpm test:*) は make を許可しない）" {
  printf '[project]\ntest = "make test"\nlint = ""\n\n[agents.claude]\nextra_tools = ["Bash(pnpm test:*)"]\n' \
    > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG   project/tools 対応"* ]]
  [[ "$output" == *"make"* ]]
}

@test "round 3 までの判定表は退行していない（7 行すべて）" {
  # コーディネーターが「これは全部正しい、壊すな」と明示した組み合わせ。
  # git の撤去がこれらのどれにも触れていないことを 1 テストで直接固定する
  check_row() { # $1 = test, $2 = extra_tools の中身, $3 = 期待する終了コード
    printf '[project]\ntest = "%s"\nlint = ""\n\n[agents.claude]\nextra_tools = [%s]\n' \
      "$1" "$2" > "$LOOP_DIR/config.toml"
    run "$LOOP_REAL_DIR/bin/loop-doctor"
    [ "$status" -eq "$3" ] || {
      echo "row failed: test=$1 extra=$2 expected=$3 got=$status"
      echo "$output"
      return 1
    }
  }

  check_row 'pnpm -r test'     '"Bash(make:*)"' 1
  check_row 'cd web && npm test' '"Bash(npm:*)"' 0
  check_row 'CI=true npm test' '"Bash(npm:*)"' 0
  check_row 'A=1 B=2 pnpm test' '"Bash(pnpm:*)"' 0
  check_row 'CI=true npm test' '"Bash(make:*)"' 1
  check_row 'echo skip'        '' 0

  printf '[project]\ntest = ""\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}
