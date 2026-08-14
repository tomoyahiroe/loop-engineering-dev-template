// Loop 稼働集計の判定・整形。I/O は一切しない（読み書きは uptime-cli.mjs）。
//
// 目的は表を作ることではなく、「1 発火に何分かかっているか」を見えるように
// すること。mmm-loops では総稼働時間の 62% が「失敗するまでに 2 時間以上
// ハングしていた時間」で、それは STATE を目で追っても分からず、集計して
// 初めて見えた。

import { KINDS } from './events.mjs';

// --- 表示幅 -----------------------------------------------------------------

// 幅 2 とみなすコードポイント範囲。参照実装（mmm-loops）は python の
// unicodedata.east_asian_width の W/F を使うが node には無いため、主要な範囲で
// 近似する。日本語の見出しと罫線が揃えばよい
const WIDE_RANGES = [
  [0x1100, 0x115f], // ハングル字母
  [0x2e80, 0xa4cf], // CJK 各種（漢字・かな・記号）
  [0xac00, 0xd7a3], // ハングル音節
  [0xf900, 0xfaff], // CJK 互換漢字
  [0xfe30, 0xfe6f], // CJK 互換形
  [0xff00, 0xff60], // 全角英数・記号
  [0xffe0, 0xffe6], // 全角通貨記号
];

export function charWidth(cp) {
  for (const [lo, hi] of WIDE_RANGES) if (cp >= lo && cp <= hi) return 2;
  return 1;
}

export function width(s) {
  let w = 0;
  for (const ch of String(s ?? '')) w += charWidth(ch.codePointAt(0));
  return w;
}

export function pad(s, w, align = 'left') {
  const text = String(s ?? '');
  const fill = Math.max(0, w - width(text));
  if (align === 'right') return ' '.repeat(fill) + text;
  if (align === 'center') {
    const l = Math.floor(fill / 2);
    return ' '.repeat(l) + text + ' '.repeat(fill - l);
  }
  return text + ' '.repeat(fill);
}

// 罫線つきの表。行ごとに区切り線を入れる（値を縦に読みやすくするため。
// 参照実装の判断を踏襲）
export function table(headers, rows, aligns = []) {
  const cols = headers.length;
  const w = headers.map((h, i) => Math.max(
    width(h),
    ...rows.map((r) => width(r[i] ?? '')),
  ));
  const line = (l, m, r) => l + w.map((x) => '─'.repeat(x + 2)).join(m) + r;
  const row = (cells, align) => '│'
    + cells.map((c, i) => ` ${pad(c ?? '', w[i], align[i] ?? 'left')} `).join('│')
    + '│';

  const a = Array.from({ length: cols }, (_, i) => aligns[i] ?? 'left');
  const out = [line('┌', '┬', '┐'), row(headers, headers.map(() => 'center'))];
  for (const r of rows) {
    out.push(line('├', '┼', '┤'));
    out.push(row(r, a));
  }
  out.push(line('└', '┴', '┘'));
  return out.join('\n');
}

// --- 時間の整形 -------------------------------------------------------------

export function formatDuration(ms) {
  if (!Number.isFinite(ms) || ms < 0) return '–';
  const s = Math.round(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}h${String(m).padStart(2, '0')}m`;
  if (m > 0) return `${m}m${String(sec).padStart(2, '0')}s`;
  return `${sec}s`;
}

// "30m" / "2h" / "90" (秒) を ms にする
export function parseThreshold(text) {
  const s = String(text ?? '').trim();
  const m = s.match(/^(\d+(?:\.\d+)?)\s*(ms|s|m|h)?$/i);
  if (!m) return null;
  const n = Number(m[1]);
  const unit = (m[2] || 's').toLowerCase();
  const mul = { ms: 1, s: 1000, m: 60000, h: 3600000 }[unit];
  return Math.round(n * mul);
}

// --- kind → 表の列 ----------------------------------------------------------

// 結末（finish.outcome に入る生の kind）を表の列に対応づける。
// **KINDS の全要素がここに現れること**をテストで照合する。値域が増えたときに
// 分類が漏れると、増えた分が黙って「その他」に落ちて数字が狂う
export const OUTCOME_BUCKETS = {
  dispatch: 'dispatch',
  fix: 'dispatch',

  skip: 'skip',

  gate_failed: 'failed',
  automerge_failed: 'failed',
  fix_exhausted: 'failed',
  conflict: 'failed',

  idle: 'idle',
  report: 'idle',
  gate_retry: 'idle',
  automerge: 'idle',

  // start / finish は結末になり得ない（tick の区切りそのもの）
  start: null,
  finish: null,

  // 判断イベントが 1 つも無いまま終わった tick
  none: 'unknown',
};

export const BUCKET_LABEL = {
  dispatch: 'dispatch あり',
  skip: 'skip',
  failed: '失敗',
  idle: 'dispatch なし（空振り）',
  unknown: '結末不明',
};

// KINDS のうち結末になり得るものが、すべて OUTCOME_BUCKETS に載っているか
export function missingOutcomeKinds() {
  return KINDS.filter((k) => !(k in OUTCOME_BUCKETS));
}

// --- tick への畳み込み ------------------------------------------------------

// events を tick 単位のレコードにする。
// start から次の start までを 1 tick とみなす（finish が無い tick =
// ハングまたは強制終了 を落とさないため、finish を区切りに使わない）
export function foldTicks(events) {
  const rows = [...(events ?? [])]
    .filter((e) => e && typeof e.kind === 'string' && e.ts)
    .sort((a, b) => new Date(a.ts) - new Date(b.ts));

  const ticks = [];
  let cur = null;
  for (const e of rows) {
    if (e.kind === 'start') {
      if (cur) ticks.push(cur);
      cur = { start: e.ts, finish: null, duration_ms: null, outcome: null, rc: null };
      continue;
    }
    if (!cur) {
      // start / finish が入る前の tick。判断イベントは 1 発火につき 1 行なので、
      // それ自体を 1 tick として数える。**捨ててはいけない** — 捨てると計測前の
      // 期間が表から丸ごと消え、「その頃は動いていなかった」ように見える。
      // duration は無いので (計測前) として扱われる
      if (e.kind !== 'finish') {
        ticks.push({
          start: e.ts, finish: e.ts, duration_ms: null,
          outcome: e.kind, rc: null, unmeasured: true,
        });
      }
      continue;
    }
    if (e.kind === 'finish') {
      cur.finish = e.ts;
      cur.duration_ms = Number.isFinite(e.duration_ms) ? e.duration_ms : null;
      cur.outcome = e.outcome ?? 'none';
      cur.rc = Number.isFinite(e.rc) ? e.rc : null;
    }
  }
  if (cur) ticks.push(cur);
  return ticks;
}

const dayOf = (iso) => String(iso).slice(0, 10);

const pad2 = (n) => String(n).padStart(2, '0');

// その日を含む週の月曜日（ローカル時刻。toISOString は UTC なので使わない）
export function weekStart(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return dayOf(iso);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); // 月曜 = 0
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

const emptyBucket = () => ({
  fired: 0, skip: 0, failed: 0, dispatch: 0, idle: 0, unknown: 0,
  duration_ms: 0, measured: 0,
});

function addTick(acc, t) {
  acc.fired += 1;
  const bucket = OUTCOME_BUCKETS[t.outcome ?? 'none'] ?? 'unknown';
  if (bucket && bucket in acc) acc[bucket] += 1;
  if (Number.isFinite(t.duration_ms)) {
    acc.duration_ms += t.duration_ms;
    acc.measured += 1;
  }
  return acc;
}

export function aggregate(ticks, keyFn) {
  const map = new Map();
  for (const t of ticks) {
    const k = keyFn(t.start);
    if (!map.has(k)) map.set(k, emptyBucket());
    addTick(map.get(k), t);
  }
  return [...map.entries()]
    .sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map(([key, v]) => ({ key, ...v }));
}

export const aggregateByDay = (ticks) => aggregate(ticks, dayOf);
export const aggregateByWeek = (ticks) => aggregate(ticks, weekStart);

// 計測データ（duration_ms）が 1 件も無い先頭の連続行をまとめる。
// **0m00s と表示してはいけない。** 0 分と「記録が無い」の混同は
// mmm-loops が実際に踏んだ
export function foldMeasuringPrefix(rows) {
  let i = 0;
  while (i < rows.length && rows[i].measured === 0) i += 1;
  if (i === 0) return { prefix: null, rest: rows };
  const merged = rows.slice(0, i).reduce((a, r) => {
    for (const k of ['fired', 'skip', 'failed', 'dispatch', 'idle', 'unknown']) a[k] += r[k];
    return a;
  }, emptyBucket());
  // 他の行と同じ MM-DD 表記に揃える（年は表題に出ている）
  const label = i === 1 ? rows[0].key.slice(5)
    : `${rows[0].key.slice(5)}〜${rows[i - 1].key.slice(5)}`;
  return { prefix: { ...merged, key: label, measured: 0 }, rest: rows.slice(i) };
}

// --- 内訳・閾値・未発火 -----------------------------------------------------

export function breakdown(ticks) {
  const total = ticks.filter((t) => Number.isFinite(t.duration_ms));
  const sum = total.reduce((a, t) => a + t.duration_ms, 0);
  const map = new Map();
  for (const t of total) {
    const b = OUTCOME_BUCKETS[t.outcome ?? 'none'] ?? 'unknown';
    if (!b) continue;
    if (!map.has(b)) map.set(b, { count: 0, total_ms: 0 });
    const e = map.get(b);
    e.count += 1;
    e.total_ms += t.duration_ms;
  }
  return [...map.entries()]
    .map(([bucket, v]) => ({
      bucket,
      label: BUCKET_LABEL[bucket] ?? bucket,
      count: v.count,
      total_ms: v.total_ms,
      avg_ms: v.count ? Math.round(v.total_ms / v.count) : 0,
      ratio: sum ? v.total_ms / sum : 0,
    }))
    .sort((a, b) => b.total_ms - a.total_ms);
}

export function overThreshold(ticks, ms) {
  return ticks
    .filter((t) => Number.isFinite(t.duration_ms) && t.duration_ms >= ms)
    .sort((a, b) => b.duration_ms - a.duration_ms);
}

// 期待される発火スロットのうち、start が 1 件も無いもの。
//
// ロック衝突（前の発火がまだ走っていて supercronic が次を起動しない）は
// firing の中では記録できない。firing が起動すらしないため。外側から
// 「あるはずの時刻に start が無い」ことで検出する
export function missingSlots(ticks, hours, fromISO, toISO) {
  if (!Array.isArray(hours) || hours.length === 0) return [];
  const seen = new Set(ticks.map((t) => String(t.start).slice(0, 13))); // YYYY-MM-DDTHH
  const out = [];
  const from = new Date(fromISO);
  const to = new Date(toISO);
  const d = new Date(from);
  d.setMinutes(0, 0, 0);
  while (d <= to) {
    if (hours.includes(d.getHours())) {
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
        + `-${String(d.getDate()).padStart(2, '0')}T${String(d.getHours()).padStart(2, '0')}`;
      if (d >= from && d <= to && !seen.has(key)) out.push(key);
    }
    d.setHours(d.getHours() + 1);
  }
  return out;
}
