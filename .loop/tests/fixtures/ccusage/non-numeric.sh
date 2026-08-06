#!/usr/bin/env bash
# totalTokens が数値でない（引用符付き文字列）。JSON としては妥当だが
# 合計を計算できないため sum-usage.mjs は終了コード 1 になるべき
echo '{"daily":[{"totalTokens":"999999999"}]}'
