#!/usr/bin/env bash
# totalTokens が 20 桁。JSON としては妥当だが、JS の double に変換すると
# Number.isSafeInteger の範囲(2^53-1)を大きく超え、精度も失われる。
# レビューで見つかった実際の fail-open 再現ケース。
echo '{"daily":[{"totalTokens":99999999999999999999}]}'
