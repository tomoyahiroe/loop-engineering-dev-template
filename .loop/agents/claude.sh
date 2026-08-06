#!/usr/bin/env bash
# Claude Code provider。ツール許可リストの意味論は provider 固有なので
# 共通層では扱わず、ここで defaults.toml から組み立てる。
set -uo pipefail
: "${LOOP_ROLE:?LOOP_ROLE が未設定}"
: "${LOOP_PROMPT_FILE:?LOOP_PROMPT_FILE が未設定}"
: "${LOOP_CWD:?LOOP_CWD が未設定}"
: "${LOOP_DIR:?LOOP_DIR が未設定}"

# 設定の読み出しは実物の loop-config を使う（LOOP_DIR は環境変数で引き継がれる）
CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/loop-config"

# loop-config get の終了コード 1（キー未定義）は許容して空扱いにする。
# それ以外（config.toml が壊れているなどの読み込み失敗、終了コード 2）まで
# || true で握りつぶすと、ツール許可リストが黙って空になり claude が
# --allowedTools なしの無制限モードで起動してしまう。ツール許可リストは
# 無人実行の唯一の安全境界なので、ここでは 2 種類のエラーを区別し、
# 後者は握りつぶさず必ず中断する（誤って subshell の中で exit しても
# 親プロセスには伝わらないため、コマンド置換はここでは使わない）。
TOOLS=()

TOOLS_OUT="$("$CONFIG" get "agents.claude.tools_$LOOP_ROLE" 2>&1)"; TOOLS_RC=$?
if [ "$TOOLS_RC" -eq 1 ]; then
  TOOLS_OUT=""
elif [ "$TOOLS_RC" -ne 0 ]; then
  echo "設定の読み出しに失敗しました（agents.claude.tools_${LOOP_ROLE}）: $TOOLS_OUT" >&2
  exit 2
fi
while IFS= read -r line; do
  [ -n "$line" ] && TOOLS+=("$line")
done <<< "$TOOLS_OUT"

EXTRA_OUT="$("$CONFIG" get "agents.claude.extra_tools" 2>&1)"; EXTRA_RC=$?
if [ "$EXTRA_RC" -eq 1 ]; then
  EXTRA_OUT=""
elif [ "$EXTRA_RC" -ne 0 ]; then
  echo "設定の読み出しに失敗しました（agents.claude.extra_tools）: $EXTRA_OUT" >&2
  exit 2
fi
while IFS= read -r line; do
  [ -n "$line" ] && TOOLS+=("$line")
done <<< "$EXTRA_OUT"

ARGS=(-p "$(cat "$LOOP_PROMPT_FILE")")
[ -n "${LOOP_MODEL:-}" ] && ARGS+=(--model "$LOOP_MODEL")
[ -n "${LOOP_MAX_TURNS:-}" ] && ARGS+=(--max-turns "$LOOP_MAX_TURNS")
[ "${#TOOLS[@]}" -gt 0 ] && ARGS+=(--allowedTools "${TOOLS[@]}")

cd "$LOOP_CWD" || exit 1
exec claude "${ARGS[@]}"
