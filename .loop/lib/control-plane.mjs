// コントロールプレーン（観測 UI）の判定・整形。I/O は一切しない
// （HTTP と子プロセスの実行は control-plane-cli.mjs の仕事）。
//
// ここに切り出しているのは、UI を立ち上げずにテストしたい判定だけ:
// crontab から次の発火時刻を出す、budget-check の出力を読む、
// パスのトラバーサルを弾く、Issue を状態で分ける。

import { resolve, sep } from 'node:path';

// gen-crontab の stdout 1 行から時リストを取り出す。
// 行の形: "0 1,3,5,7,9,11,13,15,17,19,21,23 * * * /path/to/firing"
// crontab を自前で組み立て直さず、既存の生成結果をそのまま読む
export function parseCrontabHours(line) {
  const fields = String(line).trim().split(/\s+/);
  if (fields.length < 6) return [];
  const hours = fields[1].split(',')
    .map((h) => Number(h))
    .filter((h) => Number.isInteger(h) && h >= 0 && h <= 23);
  return [...new Set(hours)].sort((a, b) => a - b);
}

// 次に firing が動く時刻。firing は必ず分 0 に発火する。
// 「今ちょうど分 0」の場合は今まさに動いている最中なので次の枠を返す
export function nextFiring(hours, now = new Date()) {
  if (!Array.isArray(hours) || hours.length === 0) return null;
  for (const h of hours) {
    const c = new Date(now);
    c.setHours(h, 0, 0, 0);
    if (c > now) return c;
  }
  const c = new Date(now);
  c.setDate(c.getDate() + 1);
  c.setHours(hours[0], 0, 0, 0);
  return c;
}

// budget-check の出力を読む。
// 正常時は "BUDGET: used=N limit=N"、fail-closed 時は "SKIP: 理由" を出す。
// **終了コードで捨てない。** 予算を使い切った状態こそ UI に出したい情報で、
// 非 0 で返るからといって表示しないのは本末転倒
export function parseBudget(stdout) {
  const text = String(stdout ?? '');
  const out = { used: null, limit: null, reason: null };

  const m = text.match(/^BUDGET:\s*used=(\d+)\s+limit=(\d+)/m);
  if (m) {
    out.used = Number(m[1]);
    out.limit = Number(m[2]);
  }

  const skip = text.match(/^SKIP:\s*(.+)$/m);
  if (skip) out.reason = skip[1].trim();

  return out;
}

// ベースディレクトリの外を指すパスを弾く。
// basename 一致だけの検査にしない（"a/../../etc/passwd" のような名前を
// 弾けないため）。resolve した結果がベースの下にあることまで確認する
export function safeJoin(baseDir, name) {
  const raw = String(name ?? '');
  if (!raw) return null;
  // セパレータを含む時点で受け付けない。UI が渡すのはファイル名だけ
  if (raw.includes('/') || raw.includes('\\') || raw.includes('\0')) return null;
  if (raw === '.' || raw === '..') return null;

  const base = resolve(baseDir);
  const full = resolve(base, raw);
  if (full !== base && !full.startsWith(base + sep)) return null;
  return full;
}

const pad2 = (n) => String(n).padStart(2, '0');

// firing の $DATE と同じ「ローカルの今日」。
// toISOString() は UTC なので、JST では午前 9 時前に日付が 1 日ずれる
// （08-13 08:00 JST = 08-12 23:00 UTC）。firing は date +%Y-%m-%d を使う
export function localDate(now = new Date()) {
  return `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
}

// 本日の dispatch 数。**firing の N_TODAY と同じものを数える。**
//
//   firing: ls "loops/runs/$DATE"-maker-issue-*.md | grep -v '\.retry\.md$' | wc -l
//
// ここがズレると、画面の「本日 dispatch X / N」が firing が実際に使う上限
// 判定と食い違う。P1 で /loop-status が起こしたのと同じ事故（.retry.md を
// 数えてしまい 3 対 2 の食い違い）なので、tests で式そのものを照合している。
//
// events の dispatch を数える実装にしてはいけない。dispatch イベントは
// dispatch-maker を呼ぶ直前に記録されるため、ツール許可ガードで
// dispatch-maker が起動を拒否した場合にイベントだけが残り、firing の
// 数え方と食い違う
export function countDispatchedToday(filenames, date) {
  const prefix = `${date}-maker-issue-`;
  return (Array.isArray(filenames) ? filenames : []).filter(
    (f) => f.startsWith(prefix) && f.endsWith('.md') && !f.endsWith('.retry.md'),
  ).length;
}

const labelNames = (issue) => (issue?.labels ?? [])
  .map((l) => (typeof l === 'string' ? l : l?.name))
  .filter(Boolean);

// Issue を状態で分ける。needs-human は「人間が見ないと進まない」状態なので
// loop:ready より優先して分類する（gate 不合格の直後は両方付き得る）
export function classifyIssues(issues, readyLabel = 'loop:ready') {
  const out = { needs_human: [], ready: [], other: [] };
  for (const issue of Array.isArray(issues) ? issues : []) {
    const labels = labelNames(issue);
    const row = {
      number: issue.number,
      title: issue.title,
      url: issue.url,
      labels,
    };
    if (labels.includes('needs-human')) out.needs_human.push(row);
    else if (labels.includes(readyLabel)) out.ready.push(row);
    else out.other.push(row);
  }
  // 待ち行列は firing と同じ順（若い番号から）で見せる
  out.ready.sort((a, b) => a.number - b.number);
  return out;
}

// ループが作った PR だけを数える。firing の N_OPEN と同じ判定にする
// （headRefName が loop/issue- で始まるもの）
export function summarizePrs(prs) {
  const list = (Array.isArray(prs) ? prs : [])
    .filter((p) => String(p?.headRefName ?? '').startsWith('loop/issue-'));
  return {
    open: list.length,
    items: list.map((p) => ({
      number: p.number,
      title: p.title,
      url: p.url,
      headRefName: p.headRefName,
      reviewDecision: p.reviewDecision ?? null,
    })),
  };
}
