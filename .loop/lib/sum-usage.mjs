// ccusage の JSON を標準入力から読み、totalTokens を合計して標準出力に整数を書く。
// fail-closed: 以下はすべて終了コード 1（呼び出し側が fail-closed で扱う）。
//   - JSON として解析できない
//   - daily/data フィールド自体が存在しない（スキーマ不明・エラーペイロード等）
//   - daily/data が配列でない
//   - 行の totalTokens が数値でない（例: JSON 上は妥当でも文字列 "600" など）
//   - 合計が有限の非負数にならない
let s = '';
process.stdin.on('data', (d) => { s += d; });
process.stdin.on('end', () => {
  try {
    const j = JSON.parse(s);
    const hasDaily = j !== null && typeof j === 'object' && Object.prototype.hasOwnProperty.call(j, 'daily');
    const hasData = j !== null && typeof j === 'object' && Object.prototype.hasOwnProperty.call(j, 'data');
    if (!hasDaily && !hasData) throw new Error('daily/data フィールドがない');
    const rows = j.daily || j.data || [];
    if (!Array.isArray(rows)) throw new Error('daily が配列でない');
    let total = 0;
    for (const row of rows) {
      const t = row && typeof row === 'object' ? row.totalTokens : undefined;
      if (t === undefined || t === null) continue;
      if (typeof t !== 'number' || !Number.isFinite(t)) {
        throw new Error('totalTokens が数値でない');
      }
      total += t;
    }
    if (!Number.isFinite(total) || total < 0) throw new Error('合計が不正な値');
    process.stdout.write(`${Math.trunc(total)}\n`);
  } catch {
    process.exit(1);
  }
});
