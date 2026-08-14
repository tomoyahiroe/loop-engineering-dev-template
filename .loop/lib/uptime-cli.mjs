// Loop 稼働集計の I/O。集計と整形は uptime.mjs（純関数）の仕事。
//
// **完全に読み取り専用。** events.jsonl も STATE.md も GitHub も書き換えない。
//
// 用法:
//   loop-uptime [--month YYYY-MM | --all] [--weekly] [--threshold 30m] [--plain]

import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseLines } from './events.mjs';
import { parseCrontabHours } from './control-plane.mjs';
import {
  table, formatDuration, parseThreshold, foldTicks,
  aggregateByDay, aggregateByWeek, foldMeasuringPrefix,
  breakdown, overThreshold, missingSlots,
} from './uptime.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CODE_DIR = resolve(here, '..');
const REPO_ROOT = process.env.REPO_ROOT || resolve(CODE_DIR, '..');
const EVENTS = resolve(REPO_ROOT, 'loops', 'events.jsonl');

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };

if (has('--help') || has('-h')) {
  process.stdout.write(
    '用法: loop-uptime [--month YYYY-MM | --all] [--weekly] [--threshold 30m] [--plain]\n'
    + '  --month     対象月（既定: 今月）\n'
    + '  --all       全期間\n'
    + '  --weekly    日別ではなく週別にまとめる\n'
    + '  --threshold 長時間発火とみなす閾値（既定: 30m）\n'
    + '  --plain     タブ区切り。罫線を描かない（他ツール連携用）\n',
  );
  process.exit(0);
}

const PLAIN = has('--plain');
const WEEKLY = has('--weekly');
const THRESHOLD = parseThreshold(val('--threshold') ?? '30m') ?? 30 * 60 * 1000;

const pad2 = (n) => String(n).padStart(2, '0');
const now = new Date();
const MONTH = has('--all')
  ? null
  : (val('--month') ?? `${now.getFullYear()}-${pad2(now.getMonth() + 1)}`);

// --- 読み取り ---------------------------------------------------------------

let text = '';
try {
  text = readFileSync(EVENTS, 'utf8');
} catch {
  process.stderr.write(
    `${EVENTS} がありません。まだ 1 度も firing が動いていないか、\n`
    + 'このリポジトリにループが入っていません。\n',
  );
  process.exit(1);
}

const all = foldTicks(parseLines(text));
const ticks = MONTH ? all.filter((t) => String(t.start).startsWith(MONTH)) : all;

if (ticks.length === 0) {
  const scope = MONTH ? `${MONTH} の` : '';
  process.stderr.write(
    `${scope}記録がありません。\n`
    + 'tick の開始・終了の記録は後から入った機能なので、それ以前の発火は\n'
    + '集計できません（--all で全期間を見られます）。\n',
  );
  process.exit(1);
}

// 発火スロットは gen-crontab の出力から取る（crontab を自前で解釈しない）
let hours = [];
try {
  const out = execFileSync(resolve(CODE_DIR, 'bin', 'gen-crontab'), {
    cwd: REPO_ROOT, encoding: 'utf8', timeout: 20000,
    env: { ...process.env, REPO_ROOT },
  });
  hours = parseCrontabHours(out.split('\n')[0] ?? '');
} catch {
  // 取れなくても集計はできる。未発火スロットの節だけ出せなくなる
}

// --- 出力 -------------------------------------------------------------------

const out = [];
const emit = (headers, rows, aligns) => {
  if (PLAIN) {
    out.push([headers.join('\t'), ...rows.map((r) => r.join('\t'))].join('\n'));
  } else {
    out.push(table(headers, rows, aligns));
  }
};

// 1. 日別（または週別）サマリ
const rowsRaw = WEEKLY ? aggregateByWeek(ticks) : aggregateByDay(ticks);
const { prefix, rest } = foldMeasuringPrefix(rowsRaw);
const summary = [];
const line = (r, label, measuring) => [
  label,
  String(r.fired), String(r.skip), String(r.failed), String(r.dispatch),
  // 0m00s と「記録が無い」を混同させない
  measuring ? '(計測前)' : formatDuration(r.duration_ms),
];
if (prefix) summary.push(line(prefix, prefix.key, true));
for (const r of rest) summary.push(line(r, WEEKLY ? `${r.key} 週` : r.key.slice(5), false));

const totals = rowsRaw.reduce((a, r) => {
  for (const k of ['fired', 'skip', 'failed', 'dispatch']) a[k] += r[k];
  a.duration_ms += r.duration_ms;
  return a;
}, { fired: 0, skip: 0, failed: 0, dispatch: 0, duration_ms: 0 });
summary.push(line(totals, '合計', false));

out.push(MONTH ? `## ${MONTH} の稼働` : '## 全期間の稼働');
emit(
  ['日付', '発火', 'skip', '失敗', 'dispatch', '稼働時間'],
  summary,
  ['left', 'right', 'right', 'right', 'right', 'right'],
);

// 2. 稼働時間の内訳
const bd = breakdown(ticks);
if (bd.length > 0) {
  out.push('\n## 稼働時間の内訳');
  emit(
    ['種別', '回数', '合計', '1 回平均', '割合'],
    bd.map((b) => [
      b.label, String(b.count), formatDuration(b.total_ms),
      formatDuration(b.avg_ms), `${Math.round(b.ratio * 100)}%`,
    ]),
    ['left', 'right', 'right', 'right', 'right'],
  );
}

// 3. 閾値を超えた発火
const slow = overThreshold(ticks, THRESHOLD);
out.push(`\n## ${formatDuration(THRESHOLD)} を超えた発火`);
if (slow.length === 0) {
  out.push('  なし');
} else {
  emit(
    ['日付', '時刻', '所要', '結果'],
    slow.map((t) => [
      String(t.start).slice(5, 10), String(t.start).slice(11, 16),
      formatDuration(t.duration_ms), String(t.outcome ?? '-'),
    ]),
    ['left', 'left', 'right', 'left'],
  );
}

// 4. 未発火スロット（1 件以上あるときだけ）
if (hours.length > 0) {
  const missing = missingSlots(ticks, hours, ticks[0].start, ticks[ticks.length - 1].start);
  if (missing.length > 0) {
    out.push('\n## 発火しなかったスロット');
    out.push('  前の発火がまだ走っていて supercronic が起動を見送った可能性があります');
    emit(['日時'], missing.map((m) => [m.replace('T', ' ') + ':00']), ['left']);
  }
}

// 記録の無い tick（start はあるが finish が無い＝ハングまたは強制終了）
const unfinished = ticks.filter((t) => !t.finish);
if (unfinished.length > 0) {
  out.push('\n## 終了が記録されていない発火');
  out.push('  ハングしたか、途中で強制終了された可能性があります');
  emit(
    ['日付', '時刻'],
    unfinished.map((t) => [String(t.start).slice(5, 10), String(t.start).slice(11, 16)]),
    ['left', 'left'],
  );
}

process.stdout.write(`${out.join('\n')}\n`);
