// firing の各 tick を 1 行の JSON にする純関数群。I/O は一切しない
// （読み書きは events-cli.mjs の仕事）。
//
// STATE.md ではなくこのログをコントロールプレーンの源にしている理由は
// 設計書 2026-08-12-control-plane-design.md の決定 1 を見る。要点は、
// record_state が日付しか持たず（date +%Y-%m-%d）、追記が末尾に積まれるため
// 実際には "## Budget" 見出しの下に溜まり、内容が日本語の散文であること。
// 散文をパースして機械が読む値を作るのは、P1 で最も高くついたバグの型。

// kind の値域。firing の終了経路と 1 対 1 に対応する。
// ここを増やしたら firing 側にも配線する（tests/events.bats が双方向に照合する）
export const KINDS = [
  // tick の開始と終了。稼働時間の集計（.loop/bin/loop-uptime）が読む。
  // start は gh を叩く前に、finish は EXIT トラップで書く。start があるのに
  // finish が無い tick は「ハングまたは強制終了」を意味する
  'start',
  'finish',
  'conflict',
  'automerge',
  'automerge_failed',
  'fix',
  'fix_exhausted',
  'idle',
  'skip',
  'gate_failed',
  'gate_retry',
  'report',
  'dispatch',
];

// 数値として扱うフィールド。CLI は k=v の文字列しか受け取れないため、
// ここで宣言したものだけを Number に変換する（msg のような自由文は触らない）
export const NUMERIC_FIELDS = [
  'issue',
  'pr',
  'round',
  'open_prs',
  'max_prs',
  'today',
  'max_today',
  'duration_ms',
  'rc',
];

// ISO 8601 をオフセット付きで作る。
// date -Is は GNU 拡張で BSD date（macOS）にない。firing はコンテナ内の
// Debian で動くが bats テストはホストの macOS で走るため、シェルではなく
// ここで組み立てる
export function stamp(now = new Date()) {
  const off = -now.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  const p = (n) => String(Math.floor(Math.abs(n))).padStart(2, '0');
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`
    + `T${p(now.getHours())}:${p(now.getMinutes())}:${p(now.getSeconds())}`
    + `${sign}${p(off / 60)}:${p(off % 60)}`;
}

// "k=v" を { k: v } にする。値に = が含まれる場合は最初の = だけで分割する
// （msg=a=b を壊さない）。宣言済みの数値フィールドだけ Number に変換する
export function parseField(kv) {
  const s = String(kv);
  const i = s.indexOf('=');
  if (i <= 0) return null;
  const key = s.slice(0, i);
  const raw = s.slice(i + 1);
  if (NUMERIC_FIELDS.includes(key)) {
    const n = Number(raw);
    return Number.isFinite(n) ? { [key]: n } : { [key]: raw };
  }
  return { [key]: raw };
}

// 1 行分の JSON 文字列を作る。
// 改行は JSON.stringify が \n にエスケープするので jsonl が壊れない
// （gate_out は loop-gate の複数行出力をそのまま含む）
export function buildLine(kind, fields = {}, now = new Date()) {
  if (!KINDS.includes(kind)) throw new Error(`unknown kind: ${kind}`);
  const clean = {};
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null || v === '') continue;
    clean[k] = v;
  }
  return JSON.stringify({ ts: stamp(now), kind, ...clean });
}

// 壊れた行はスキップする。コンテナが書き込みの途中で kill されると最終行が
// 切れる。1 行の破損で履歴全体が読めなくなってはいけない
export function parseLines(text) {
  const out = [];
  for (const line of String(text).split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const o = JSON.parse(s);
      if (o && typeof o === 'object' && typeof o.kind === 'string') out.push(o);
    } catch {
      // 破損行は捨てる
    }
  }
  return out;
}

// 新しい順に N 件
export function tail(text, limit = 50) {
  const all = parseLines(text);
  const n = Number.isFinite(Number(limit)) && Number(limit) > 0
    ? Math.floor(Number(limit))
    : 50;
  return all.slice(-n).reverse();
}
