#!/usr/bin/env bash
# テスト用の provider。受け取った環境変数を出力し、MOCK_EXIT の終了コードで終わる
set -uo pipefail
echo "ROLE=$LOOP_ROLE"
echo "MODEL=${LOOP_MODEL:-}"
echo "MAX_TURNS=${LOOP_MAX_TURNS:-}"
echo "CWD=$LOOP_CWD"
echo "PROMPT=$(cat "$LOOP_PROMPT_FILE")"
exit "${MOCK_EXIT:-0}"
