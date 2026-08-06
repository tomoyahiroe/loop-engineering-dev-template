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
