# shellcheck shell=bash
# すべての .loop/bin/* から source される共通ヘルパー。
# コードの所在(LIB_DIR)と設定の所在(LOOP_DIR)を分けている。
# テストは実物のコードで fixture の設定を使えるように LOOP_DIR / REPO_ROOT を上書きする。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="${LOOP_DIR:-$(cd "$LIB_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$LIB_DIR/../.." && pwd)}"
export LOOP_DIR REPO_ROOT

# bash 5.2+ は既定で patsub_replacement が有効で、${var/pat/repl} の repl 中の
# & をマッチした文字列（sed の & と同じ意味）として展開してしまう。
# render_prompt が値に & を含むケース（例: "cd a && b"）を壊さないよう、
# source された時点で一度だけ無効化する（shopt はプロセス全体に効き、関数に
# スコープされないため、render_prompt 内ではなくここで固定する）。
# bash 3.2 にはこのオプション自体が無いのでエラーを握りつぶす
shopt -u patsub_replacement 2>/dev/null || true

# 設定値を 1 つ取り出す。未定義なら終了コード 1
cfg() {
  LOOP_DIR="$LOOP_DIR" "$LIB_DIR/../bin/loop-config" get "$1"
}

# loops/STATE.md の末尾に 1 行追記する
record_state() {
  printf -- '- %s: %s\n' "$(date +%Y-%m-%d)" "$1" >> "$REPO_ROOT/loops/STATE.md"
}

# 一過性エラー（DNS/接続系）の判定。$1 = 実行ログのパス
is_transient_error() {
  [ -f "$1" ] || return 1
  grep -qiE 'ENOTFOUND|ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|getaddrinfo|fetch failed' "$1"
}

retry_delay() {
  cfg retry.delay_seconds
}

# --- [project] の test/lint と extra_tools の対応判定 -----------------------
# loop-doctor（診断）と require_project_tools_allowed（実行時ガード、下）の
# 両方がここを呼ぶ。判定をここ 1 箇所に集約することで、「doctor は OK と
# 言うのに実行時は拒否される」ような食い違い（P1 で何度も踏んだ「部品同士が
# 黙って矛盾する」パターン）が起こらないようにする。

# Claude Code の組み込み read-only allowlist。extra_tools に書かなくても
# 常に実行できるコマンドなので、不足判定の対象から除外する。
#
# 出典: https://code.claude.com/docs/en/permissions.md 「Read-only commands」
# 原文: "Claude Code recognizes a built-in set of Bash commands as read-only
#   and runs them without a permission prompt in every mode. These include
#   ls, cat, echo, pwd, head, tail, grep, find, wc, which, diff, stat, du,
#   cd, and read-only forms of git. The set is not configurable"
#
# この一覧は 2026-08-10 に上記ドキュメントを直接取得して確認したもの。
# P1 で `tr` を「組み込みだと思ったら違っていた」で個別に extra_tools へ
# 足す羽目になった教訓があるため、ここは常に一次情報（公式ドキュメント）を
# 確認してから書く。確信が持てないコマンドは足さない（除外し過ぎて NG を
# 誤って出す方が、含め過ぎて壊れた設定を OK と報告するより安全）
BUILTIN_READONLY_CMDS="ls cat echo pwd head tail grep find wc which diff stat du"

# git は「read-only な形」だけが組み込み扱いで、サブコマンド次第。公式
# ドキュメントはサブコマンドの厳密な一覧までは挙げていないため、ここでは
# 疑いようのない読み取り専用サブコマンドだけの保守的な部分集合を使う。
# branch / tag / remote / config / checkout はフラグ次第で書き込みになり
# 得るため、意図的にこの一覧へ含めない（`tr` のときと同じ理由で、確信が
# 持てないものは「組み込み」に分類しない）。symbolic-ref も同じ理由で
# 除外する: `git symbolic-ref HEAD refs/heads/x` は引数次第で HEAD を
# 書き換える（実測で確認済み）。判断がつかないサブコマンドは含めない方を
# 選ぶ — 含め損ねると正しい設定が弾かれるだけだが、誤って含めると壊れた
# 設定を健全と報告してしまい、この検査が防ぐはずの偽陰性そのものになる
GIT_READONLY_SUBCMDS="status log diff show blame describe rev-parse ls-files ls-tree cat-file shortlog rev-list merge-base name-rev"

# $1 が、空白区切りの一覧 $2 に単語として含まれるか
is_word_in_list() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# project.test / project.lint のようなシェルコマンド文字列から、extra_tools
# の許可が必要なコマンド名を抜き出す（先頭トークン、および && ; | の後ろの
# 先頭トークン。ただし CI=true npm test のような先頭の環境変数代入
# （VAR=val、複数連続も可）は読み飛ばし、その後ろの実コマンドを見る）。
# Claude Code の組み込み read-only コマンド（上の BUILTIN_READONLY_CMDS /
# GIT_READONLY_SUBCMDS）は許可が要らないので、ここで除外して出力しない。
# クォートは shell の入れ子規則どおりに読み飛ばす（例: echo 'a && b' の
# 中の && は区切りとして扱わない）。ただしコマンド置換・リダイレクト・
# `||`・バックスラッシュ・`sh -c "..."` のように実際に実行されるコマンドが
# 引数の中に隠れる形は、自信を持って解析できないので何も出力せず終了コード
# 1 を返す。呼び出し側はこれを「件数チェックにフォールバックする」合図として
# 扱うこと（解析できないことを理由に通してしまうより、解析できないと言う
# ほうが安全側）
extract_command_names() {
  local raw="$1"
  local i len ch in_squote in_dquote seg segs cmd rest sub cd_target

  case "$raw" in
    *'$('*|*'`'*|*'<'*|*'>'*|*'||'*|*'|&'*|*'\'*)
      return 1
      ;;
  esac

  len=${#raw}
  in_squote=0
  in_dquote=0
  seg=""
  segs=""
  i=0
  while [ "$i" -lt "$len" ]; do
    ch="${raw:$i:1}"
    if [ "$in_squote" = 1 ]; then
      seg="$seg$ch"
      [ "$ch" = "'" ] && in_squote=0
    elif [ "$in_dquote" = 1 ]; then
      seg="$seg$ch"
      [ "$ch" = '"' ] && in_dquote=0
    else
      case "$ch" in
        "'") in_squote=1; seg="$seg$ch" ;;
        '"') in_dquote=1; seg="$seg$ch" ;;
        '&'|';'|'|')
          segs="$segs
$seg"
          seg=""
          ;;
        *) seg="$seg$ch" ;;
      esac
    fi
    i=$((i + 1))
  done
  segs="$segs
$seg"

  # クォートが閉じきらずに終わった＝解析を諦める
  [ "$in_squote" = 1 ] && return 1
  [ "$in_dquote" = 1 ] && return 1

  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    read -r cmd rest <<< "$seg"
    [ -z "$cmd" ] && continue

    # 先頭の環境変数代入（VAR=val）を読み飛ばす。CI=true npm test のような
    # 形は CI では最も普通の書き方で、代入をコマンド名扱いすると npm では
    # なく "CI=true" の許可を要求してしまう。複数連続（A=1 B=2 npm test）
    # にも対応する
    while :; do
      case "$cmd" in
        [A-Za-z_]*=*) : ;;
        *) break ;;
      esac
      read -r cmd rest <<< "$rest"
      [ -z "$cmd" ] && break
    done
    [ -z "$cmd" ] && continue

    case "$cmd" in
      # 実際に実行されるコマンドが引数の中に隠れる形は解析を諦める
      sh|bash|zsh|dash|env|xargs|eval|nohup|time|sudo|command)
        return 1
        ;;
    esac

    if is_word_in_list "$cmd" "$BUILTIN_READONLY_CMDS"; then
      continue  # 組み込み read-only。許可が要らないので判定対象にしない
    fi

    if [ "$cmd" = "cd" ]; then
      # cd はワーキングディレクトリの内側への移動だけが read-only 扱い
      # （ドキュメント: "A cd into a path inside your working directory ...
      #  is also read-only"）。絶対パスはその外に出られるため対象外のまま
      # 判定に回す（安全側）。相対パスは組み込みとして扱う
      read -r cd_target _ <<< "$rest"
      case "$cd_target" in
        /*) : ;;
        *) continue ;;
      esac
    elif [ "$cmd" = "git" ]; then
      read -r sub _ <<< "$rest"
      if is_word_in_list "$sub" "$GIT_READONLY_SUBCMDS"; then
        continue  # 読み取り専用サブコマンドの組み込み扱い
      fi
    fi

    printf '%s\n' "$cmd"
  done <<< "$segs"
  return 0
}

# コマンド名 $1 に対応する Bash 許可が $2（loop-config get の生出力、
# 改行区切り）の中にあるか
extra_tools_covers_cmd() {
  local cmd="$1" tools="$2" line
  while IFS= read -r line; do
    case "$line" in
      "Bash($cmd:"*|"Bash($cmd)") return 0 ;;
    esac
  done <<< "$tools"
  return 1
}

# project.test / project.lint を実行できるツール許可が揃っているかを判定する。
# $1 = project.test（空文字可）, $2 = project.lint（空文字可）,
# $3 = extra_tools（loop-config get の生出力、改行区切り。空でもよい）
# 標準出力に判定結果を 1 行:
#   unneeded                      test も lint も未設定で、そもそも確認が要らない
#   ok [<確認できたコマンド...>]   test/lint はあるが、必要なコマンドは組み込み
#                                  read-only か extra_tools で全部揃っている。
#                                  末尾のコマンド一覧は空のこともある
#                                  （中身が全部組み込みコマンドだった場合）
#   ambiguous <N>                 解析に自信が持てない。N=extra_tools の件数
#                                  （中身を見ない件数チェックへのフォールバック）
#   missing <コマンド...>         解析はできたが、許可が足りないコマンドがある
#
# "unneeded" と "ok"（コマンド一覧が空のことがある）を別の語にしてあるのは、
# test/lint が組み込みコマンドだけで構成される場合（例: echo skip）に
# 「確認できたコマンドが 0 件の ok」と「そもそも未設定」を呼び出し側が
# 区別できるようにするため
project_tools_check() {
  local test_cmd="$1" lint_cmd="$2" tools="$3"
  local confident names all_names missing found cmd n_tools

  if [ -z "$test_cmd" ] && [ -z "$lint_cmd" ]; then
    echo unneeded
    return 0
  fi

  confident=1
  all_names=""
  if [ -n "$test_cmd" ]; then
    names="$(extract_command_names "$test_cmd")" || confident=0
    [ -n "$names" ] && all_names="$all_names
$names"
  fi
  if [ -n "$lint_cmd" ]; then
    names="$(extract_command_names "$lint_cmd")" || confident=0
    [ -n "$names" ] && all_names="$all_names
$names"
  fi

  if [ "$confident" -ne 1 ]; then
    n_tools="$(printf '%s\n' "$tools" | grep -c . || true)"
    echo "ambiguous $n_tools"
    return 0
  fi

  missing=""
  found=""
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    case " $found $missing " in
      *" $cmd "*) continue ;;
    esac
    if extra_tools_covers_cmd "$cmd" "$tools"; then
      if [ -z "$found" ]; then found="$cmd"; else found="$found $cmd"; fi
    else
      if [ -z "$missing" ]; then missing="$cmd"; else missing="$missing $cmd"; fi
    fi
  done <<< "$all_names"

  if [ -n "$missing" ]; then
    echo "missing $missing"
  else
    echo "ok $found"
  fi
}

# [project] の test/lint を実行できるツール許可があるかを確認する。
# 許可がなければ 1 を返す（呼び出し側は起動を拒否する）。
#
# なぜ必要か: maker.md / verifier.md / fixer.md は {{TEST_CMD}} / {{LINT_CMD}}
# を「完了条件」として埋め込むが、claude provider の --allowedTools は
# defaults.toml の tools_maker / tools_verifier / tools_fixer から組み立てられ、
# そこには git/gh の Bash しかない。プロジェクトのツールチェーン
# （pnpm/npx/make 等）は agents.claude.extra_tools に足さない限り実行できない。
# 足し忘れたまま起動すると、Verifier は 1 つもテストを実行できないまま diff
# だけを読んで approve する — ハーネスの主要な品質シグナルが「エラーにならず
# 静かに」無効化される。無人で回る以上、人間が気付く手立てが無いので、
# 起動前に落として理由を伝える。
#
# 判定は「導出」ではなく「拒否」にしてある。設定されたコマンドから許可リストを
# 自動生成すると、誤った導出がエージェントに意図より広い権限を与えかねない
# （許可リストは無人実行の唯一の安全境界）。extra_tools に何か 1 つでも
# 書かれていれば「人間が意図して設定した」とみなして通す。
require_project_tools_allowed() {
  local provider extra test_cmd lint_cmd marker result n missing extra_label
  provider="$(cfg agent.provider 2>/dev/null || echo '')"
  # 許可リストの意味論は provider 固有（agents/claude.sh のコメント参照）。
  # extra_tools を読まない provider（テスト用の mock 等）には適用しない
  [ "$provider" = "claude" ] || return 0

  marker="$REPO_ROOT/loops/.tools-misconfig"
  extra="$(cfg agents.claude.extra_tools 2>/dev/null || echo '')"
  test_cmd="$(cfg project.test 2>/dev/null || echo '')"
  lint_cmd="$(cfg project.lint 2>/dev/null || echo '')"

  # 判定は project_tools_check（上）に一本化してある。loop-doctor も同じ
  # 関数を呼ぶので、ここと doctor が違う答えを返すことは構造的に起こらない
  result="$(project_tools_check "$test_cmd" "$lint_cmd" "$extra")"
  missing=""
  case "$result" in
    unneeded|ok|"ok "*)
      # 設定が直った（または test/lint を持たないプロジェクト、または必要な
      # コマンドが組み込み read-only だけで揃っている）。次に壊れたときまた
      # 1 回だけ報告できるよう、マーカーを片付けてから通す
      rm -f "$marker" 2>/dev/null || true
      return 0
      ;;
    "ambiguous "*)
      n="${result#ambiguous }"
      # 中身までは解析できなかった。何か 1 つでも extra_tools が設定されて
      # いれば「人間が意図して設定した」とみなして通す（従来どおりの
      # 件数ベースのフォールバック。誤って拒否するより誤って通すほうが
      # 実害が小さい設計判断はここでも変えない）
      if [ "$n" -gt 0 ] 2>/dev/null; then
        rm -f "$marker" 2>/dev/null || true
        return 0
      fi
      ;;
    "missing "*)
      missing="${result#missing }"
      ;;
  esac

  echo "REFUSED: [project] の test/lint を実行できるツール許可がありません。"
  if [ -n "$missing" ]; then
    echo "  次のコマンドに対応する Bash 許可が extra_tools に見当たりません: $missing"
  fi
  echo "  .loop/config.toml の [agents.claude] extra_tools に、そのコマンドを"
  echo "  実行できる Bash 許可を追加してください。"
  echo "  例: extra_tools = [\"Bash(pnpm:*)\", \"Bash(npx:*)\", \"Bash(node:*)\"]"
  echo "  test/lint を持たないプロジェクトなら [project] の test / lint を \"\" にしてください。"
  extra_label='（空）'
  if [ -n "$extra" ]; then
    extra_label="$(printf '%s' "$extra" | tr '\n' ',')"
    extra_label="${extra_label%,}"
  fi
  echo "  現在の設定: test=\"$test_cmd\" lint=\"$lint_cmd\" extra_tools=${extra_label}"

  # 設定ミスは tick を跨いでも自然には直らない持続的な原因なので、STATE.md
  # （人間が毎朝読む一次情報）への記録はローカルマーカーで 1 回に抑える
  # （gate-remediation・L3 merge 失敗と同じ方式）。原則も同じ:
  # 「以後の報告を抑制する操作（マーカー作成）は informative な手より後」
  if [ ! -f "$marker" ]; then
    record_state "dispatch 中止: [project] の test/lint を実行するツール許可がない（[agents.claude] extra_tools が対応していない）"
    touch "$marker" 2>/dev/null || true
  fi
  return 1
}

# --- worktree の所有権マーカー ----------------------------------------------
# cleanup-merged は無人で worktree とブランチを消すが、「まだ 1 度もコミット
# していない Maker の worktree」は main と同じ内容・完全にクリーンなので、
# 放置された残骸と見分けが付かない（実行中の Maker ごと消される。
# turns.maker = 120 の実行は発火間隔 2 時間を超え得るため現実に起きる）。
# dispatcher が実行中だけ所有権を主張できるようにする。
#
# 判定材料はこのリポジトリが所有するローカルなファイルだけで完結させる
# （GitHub 側の状態には一切依存しない）。マーカーの中身は所有者の PID で、
# 参照側は kill -0 で生存を確認する。SIGKILL でマーカーが残っても PID が
# 死んでいれば所有権は失効するので、片付けが永久に止まることはない。
wt_owner_file() { # $1 = キー（"loop/issue-5" でも "issue-5" でも可）
  printf '%s/loops/.wt-owner-%s' "$REPO_ROOT" "${1#loop/}"
}

claim_worktree() { # $1 = キー
  printf '%s\n' "$$" > "$(wt_owner_file "$1")" 2>/dev/null || true
}

release_worktree() { # $1 = キー
  rm -f "$(wt_owner_file "$1")" 2>/dev/null || true
}

# 生きた所有者がいるか。
#
# $2 = マーカーが壊れていて判断できないときの答え（既定 0 = 所有されている扱い）。
# 「安全側」がどちらかは呼び出し側で逆になるので、既定に任せず明示する:
#   - cleanup-merged（削除する側）: 既定の 0。判断できないなら消さない。
#     削除は復旧不能なので、疑わしきは触らない
#   - dispatch-verifier（引き取る側）: 1 を渡す。壊れたマーカーを
#     「使用中」と読むと、その PR の検証が毎 tick SKIP され二度と行われない
#     （まさに finding 7 で塞いだ静かな恒久停止）。使い捨ての worktree を
#     取り違えて作り直す代償は小さいので、こちらは「所有されていない」に倒す
worktree_is_claimed() { # $1 = キー, $2 = 判断できないときの戻り値
  local f pid unknown
  unknown="${2:-0}"
  f="$(wt_owner_file "$1")"
  [ -f "$f" ] || return 1
  pid="$(head -1 "$f" 2>/dev/null)"
  case "$pid" in
    ''|*[!0-9]*) return "$unknown" ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# テンプレートの {{KEY}} を置換して標準出力する。
# bash のパターン置換を使うので、値に / & \ が含まれても壊れない（sed との違い）
render_prompt() {
  local tpl="$1"; shift
  local out pair k v
  out="$(cat "$tpl")"
  for pair in "$@"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    out="${out//\{\{$k\}\}/$v}"
  done
  printf '%s\n' "$out"
}
