#!/usr/bin/env bash
# JSON としては妥当だが daily/data フィールド自体が存在しない
# （ccusage のスキーマ変更やエラーペイロードを想定）
echo '{"note":"no usage data in this response"}'
