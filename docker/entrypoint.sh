#!/usr/bin/env bash
# crontab を config から生成して supercronic を起動する
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
CRONTAB=/tmp/loop.crontab

if [ ! -x "$REPO_ROOT/.loop/bin/gen-crontab" ]; then
  echo "======================================================================" >&2
  echo "ERROR: $REPO_ROOT/.loop/bin/gen-crontab が見つかりません。ループを起動できません。" >&2
  echo "考えられる原因:" >&2
  echo "  - docker/compose.yml の working_dir とホストのマウント先の絶対パスが一致していない" >&2
  echo "    （このコンテナは DooD 構成のため \${PWD}:\${PWD} で同じ絶対パスにマウントする必要があります）" >&2
  echo "  - このリポジトリに .loop（dev-loop ハーネス）が入っていない、または壊れている" >&2
  echo "  - REPO_ROOT 環境変数が誤ったパスを指している（現在値: $REPO_ROOT）" >&2
  echo "======================================================================" >&2
  exit 1
fi

if [ ! -d "$REPO_ROOT/.loop/node_modules" ]; then
  echo "初回セットアップ: .loop の依存をインストールします"
  ( cd "$REPO_ROOT/.loop" && npm ci --omit=dev )
fi

"$REPO_ROOT/.loop/bin/gen-crontab" > "$CRONTAB"
echo "生成した crontab:"
cat "$CRONTAB"

exec supercronic -passthrough-logs "$CRONTAB"
