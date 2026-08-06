// ccusage の JSON を標準入力から読み、totalTokens を合計して標準出力に整数を書く。
// fail-closed: 以下はすべて終了コード 1（呼び出し側が fail-closed で扱う）。
//   - JSON として解析できない
//   - daily/data フィールド自体が存在しない（スキーマ不明・エラーペイロード等）
//   - daily/data キーは存在するが値が配列でない（null や "" を含む。`||` による
//     フォールバックは falsy な既存値 [null, 0, '', false] を黙って [] に
//     すり替えてしまうため使わない。キーの有無と値の形は別々に検証する）
//   - 行の totalTokens が「安全な非負整数」でない（数値でない・NaN/Infinity・
//     小数・負・Number.MAX_SAFE_INTEGER=2^53-1 を超える。JSON の巨大な数値
//     リテラルは double への変換で精度を失い、有限だが不正確な値になり得る
//     ため Number.isFinite だけでは弾けない。Number.isSafeInteger で弾く）
//   - 合計が「安全な非負整数」でない（個々の行は安全でも、大量の桁数が
//     近い値を足し合わせると合計が精度を失うことがあるため、合計側でも
//     同じ基準で検証し直す）
let s = '';
process.stdin.on('data', (d) => { s += d; });
process.stdin.on('end', () => {
  try {
    const j = JSON.parse(s);
    const isPlainObj = j !== null && typeof j === 'object';
    const hasDaily = isPlainObj && Object.prototype.hasOwnProperty.call(j, 'daily');
    const hasData = isPlainObj && Object.prototype.hasOwnProperty.call(j, 'data');

    let rows;
    if (hasDaily) {
      rows = j.daily;
    } else if (hasData) {
      rows = j.data;
    } else {
      throw new Error('daily/data フィールドがない');
    }
    if (!Array.isArray(rows)) throw new Error('daily/data が配列でない');

    let total = 0;
    for (const row of rows) {
      const t = row && typeof row === 'object' ? row.totalTokens : undefined;
      if (t === undefined || t === null) continue;
      if (typeof t !== 'number' || !Number.isSafeInteger(t) || t < 0) {
        throw new Error('totalTokens が安全な非負整数でない');
      }
      total += t;
    }
    if (!Number.isSafeInteger(total) || total < 0) {
      throw new Error('合計が安全な非負整数でない');
    }
    process.stdout.write(`${total}\n`);
  } catch {
    process.exit(1);
  }
});
