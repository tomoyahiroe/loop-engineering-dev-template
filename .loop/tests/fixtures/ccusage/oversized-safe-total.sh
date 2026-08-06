#!/usr/bin/env bash
# totalTokens = 5,000,000,000,000,000（16 桁）。Number.isSafeInteger の
# 範囲（2^53-1 ≒ 9.007e15）には収まるので sum-usage.mjs 側の検証は通過するが、
# is_uint の 15 桁上限は超える。budget-check 側の is_uint(USED) が
# sum-usage.mjs の検証結果に頼らず単独でも効いていることを確認するための
# フィクスチャ（この値だけが唯一「mjs は通すが is_uint は拒否する」帯域）。
echo '{"daily":[{"totalTokens":5000000000000000}]}'
