#!/usr/bin/env bash
# daily キーは存在するが値が null。`j.daily || j.data || []` のような
# フォールバックだと null は falsy なので黙って [] にすり替わり used=0 に
# なってしまう（レビューで見つかった実際の fail-open 再現ケース）。
echo '{"daily":null}'
