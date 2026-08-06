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

TOOLS=()
while IFS= read -r line; do
  [ -n "$line" ] && TOOLS+=("$line")
done < <("$CONFIG" get "agents.claude.tools_$LOOP_ROLE" || true)
while IFS= read -r line; do
  [ -n "$line" ] && TOOLS+=("$line")
done < <("$CONFIG" get "agents.claude.extra_tools" || true)

ARGS=(-p "$(cat "$LOOP_PROMPT_FILE")")
[ -n "${LOOP_MODEL:-}" ] && ARGS+=(--model "$LOOP_MODEL")
[ -n "${LOOP_MAX_TURNS:-}" ] && ARGS+=(--max-turns "$LOOP_MAX_TURNS")
[ "${#TOOLS[@]}" -gt 0 ] && ARGS+=(--allowedTools "${TOOLS[@]}")

cd "$LOOP_CWD" || exit 1
exec claude "${ARGS[@]}"
