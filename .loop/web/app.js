// dev-loop コントロールプレーンの画面。読み取り専用（fetch は GET のみ）。
//
// 一番大事な性質は「嘘をつかないこと」。サーバが落ちたときに古い値を黙って
// 表示し続けるのは、観測 UI として最悪の壊れ方なので、接続状態と最終取得
// 時刻を常に画面に出す。

'use strict';

const $ = (id) => document.getElementById(id);

// events.mjs の KINDS に対応する表示名と重み。
// ここが実装とズレると画面だけが古くなるので、知らない kind は
// そのまま生の値を出す（黙って握りつぶさない）
const KIND_LABEL = {
  idle: ['待ち', '', 'ready な Issue なし'],
  report: ['報告のみ', '', 'L1 のため dispatch しない'],
  dispatch: ['dispatch', 'good', ''],
  skip: ['スキップ', 'attention', ''],
  gate_failed: ['gate 不合格', 'bad', ''],
  gate_retry: ['gate 再試行', 'attention', ''],
  fix: ['Fixer 起動', 'attention', ''],
  fix_exhausted: ['自動修正の上限', 'bad', ''],
  automerge: ['自動 merge', 'good', ''],
  automerge_failed: ['自動 merge 失敗', 'bad', ''],
  conflict: ['コンフリクトで中止', 'bad', ''],
};

const SKIP_REASON = {
  open_prs: 'open PR の上限',
  daily: '本日の dispatch 上限',
  budget: 'トークン予算',
};

let pollSeconds = 10;
let timer = null;
let lastOk = null;

const pad = (n) => String(n).padStart(2, '0');

function timeText(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso ?? '');
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return sameDay ? hm : `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${hm}`;
}

function relative(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const sec = Math.round((d - new Date()) / 1000);
  const abs = Math.abs(sec);
  const unit = abs < 60 ? `${abs} 秒`
    : abs < 3600 ? `${Math.round(abs / 60)} 分`
      : `${Math.round(abs / 3600)} 時間`;
  return sec >= 0 ? `あと ${unit}` : `${unit}前`;
}

const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  // textContent を使う。Issue タイトルなど外部由来の文字列を innerHTML に
  // 入れない（ローカル専用でも、他人が立てた Issue の文字列は流れてくる）
  if (text !== undefined) n.textContent = text;
  return n;
};

function link(url, text, cls) {
  if (!url) return el('span', cls, text);
  const a = el('a', cls, text);
  a.href = url;
  a.target = '_blank';
  a.rel = 'noreferrer';
  return a;
}

function replace(node, children) {
  node.replaceChildren(...children);
}

// --- 接続状態 ---------------------------------------------------------------

function setConn(state, text) {
  const c = $('conn');
  c.dataset.state = state;
  c.textContent = text;
}

function showErrors(list) {
  const box = $('errors');
  if (!list || list.length === 0) { box.hidden = true; return; }
  const ul = el('ul');
  for (const e of list) ul.append(el('li', null, e));
  replace(box, [ul]);
  box.hidden = false;
}

// --- サマリ -----------------------------------------------------------------

function renderStatus(s) {
  const b = s.budget ?? {};
  const bar = $('budget-bar');
  if (Number.isFinite(b.used) && Number.isFinite(b.limit) && b.limit > 0) {
    const pct = Math.min(100, (b.used / b.limit) * 100);
    bar.style.width = `${pct}%`;
    bar.className = `meter-fill${pct >= 90 ? ' danger' : pct >= 70 ? ' warn' : ''}`;
    $('budget-text').textContent = `${pct.toFixed(1)}%`;
    $('budget-reason').textContent =
      `${b.used.toLocaleString()} / ${b.limit.toLocaleString()}`;
    $('budget-reason').hidden = false;
    $('budget-reason').className = 'card-note';
  } else {
    bar.style.width = '0';
    $('budget-text').textContent = '—';
    $('budget-reason').hidden = false;
    $('budget-reason').className = 'card-note warn';
    $('budget-reason').textContent = b.reason || '使用量を取得できません';
  }
  // 予算切れは「使い切った」ことがひと目で分かる必要がある
  if (b.blocked && b.reason) {
    $('budget-reason').className = 'card-note warn';
    $('budget-reason').textContent = b.reason;
    $('budget-reason').hidden = false;
  }

  $('maturity').textContent = s.maturity ?? '—';
  $('maturity-note').textContent =
    s.maturity === 'L1' ? '判定と報告のみ'
      : s.maturity === 'L2' ? 'PR まで自動・merge は人間'
        : s.maturity === 'L3' ? 'ラベル付きは自動 merge'
          : '';

  const prs = s.prs ?? {};
  $('prs').textContent = prs.open === null || prs.open === undefined
    ? '—' : `${prs.open} / ${prs.max ?? '?'}`;
  const q = s.queue ?? {};
  $('dispatched').textContent =
    `本日 dispatch ${q.dispatched_today ?? 0} / ${q.max_per_day ?? '?'}`
    + (q.ready === null || q.ready === undefined ? '' : `・ready ${q.ready} 件`);

  const f = s.firing ?? {};
  $('next-firing').textContent = f.next ? timeText(f.next) : '—';
  $('firing-note').textContent = f.next
    ? `${relative(f.next)}・1 日 ${f.firings_per_day} 回`
    : '発火時刻を読めません';

  showErrors(s.errors);
}

// --- 成否履歴 ---------------------------------------------------------------

function eventRow(e) {
  const [label, tone, hint] = KIND_LABEL[e.kind] ?? [e.kind, '', ''];
  const row = el('div', 'row');
  row.append(el('span', 'row-time', timeText(e.ts)));
  row.append(el('span', `row-kind ${tone}`.trim(), label));

  const parts = [];
  if (e.kind === 'skip' && e.reason) parts.push(SKIP_REASON[e.reason] ?? e.reason);
  if (e.issue !== undefined) parts.push(`#${e.issue}`);
  if (e.pr !== undefined) parts.push(`PR #${e.pr}`);
  if (e.round !== undefined) parts.push(`round ${e.round}`);
  if (parts.length === 0 && hint) parts.push(hint);
  row.append(el('span', 'row-main', parts.join(' · ')));

  // gate 不合格の理由は 1 行目だけ添える（全文は Issue のコメントにある）
  const detail = e.gate_out ? String(e.gate_out).split('\n')[0] : '';
  if (detail) row.append(el('span', 'row-detail', detail));
  return row;
}

function renderEvents(events) {
  const box = $('events');
  if (!events || events.length === 0) {
    replace(box, [el('p', 'empty',
      'まだ記録がありません。次の firing で最初の行が入ります')]);
    return;
  }
  replace(box, events.map(eventRow));
}

// --- Issues / PR ------------------------------------------------------------

function issueRow(issue, tagText, tagCls) {
  const row = el('div', 'row');
  row.append(el('span', 'row-time', `#${issue.number}`));
  row.append(link(issue.url, issue.title || '(タイトルなし)', 'row-main'));
  if (tagText) row.append(el('span', `tag ${tagCls}`.trim(), tagText));
  return row;
}

function renderIssues(data) {
  const box = $('issues');
  const rows = [];
  for (const i of data.needs_human ?? []) rows.push(issueRow(i, 'needs-human', 'human'));
  for (const i of data.ready ?? []) rows.push(issueRow(i, 'loop:ready', 'ready'));
  for (const i of data.other ?? []) rows.push(issueRow(i, '', ''));
  if (rows.length === 0) rows.push(el('p', 'empty', 'open な Issue はありません'));
  replace(box, rows);
  if (data.errors && data.errors.length) showErrors(data.errors);
}

function renderPrs(prs) {
  const box = $('prlist');
  const items = prs?.items ?? [];
  if (items.length === 0) {
    replace(box, [el('p', 'empty', 'ループが作った open PR はありません')]);
    return;
  }
  replace(box, items.map((p) => {
    const row = el('div', 'row');
    row.append(el('span', 'row-time', `#${p.number}`));
    row.append(link(p.url, p.title || p.headRefName, 'row-main'));
    const rd = p.reviewDecision;
    if (rd) {
      const cls = rd === 'APPROVED' ? 'ready' : rd === 'CHANGES_REQUESTED' ? 'human' : '';
      row.append(el('span', `tag ${cls}`.trim(),
        rd === 'APPROVED' ? 'approved'
          : rd === 'CHANGES_REQUESTED' ? 'changes-requested' : rd.toLowerCase()));
    }
    return row;
  }));
}

// --- ポーリング -------------------------------------------------------------

async function getJson(path) {
  const res = await fetch(path, { cache: 'no-store' });
  if (!res.ok) throw new Error(`${path} が ${res.status} を返しました`);
  return res.json();
}

async function refresh() {
  try {
    const [status, events, issues] = await Promise.all([
      getJson('/api/status'),
      getJson('/api/events?limit=40'),
      getJson('/api/issues'),
    ]);

    renderStatus(status);
    renderEvents(events.events);
    renderIssues(issues);
    renderPrs(status.prs);

    lastOk = new Date();
    setConn('ok', `更新 ${timeText(lastOk.toISOString())}`);
    $('footer').textContent =
      `${pollSeconds} 秒ごとに更新・読み取り専用（このページから状態は変えられません）`;

    // サーバが返した間隔に合わせる（[ui] poll_seconds）
    if (Number.isFinite(status.poll_seconds) && status.poll_seconds > 0
        && status.poll_seconds !== pollSeconds) {
      pollSeconds = status.poll_seconds;
      schedule();
    }
  } catch (e) {
    // 取得に失敗したら、表示中の値が古いことを必ず伝える。
    // 黙って前回の値を出し続けない
    const since = lastOk ? `最終更新 ${timeText(lastOk.toISOString())}` : '未取得';
    setConn(lastOk ? 'stale' : 'down', `接続できません（${since}）`);
    showErrors([`サーバに接続できません: ${e.message}`,
      'コンテナが起動しているか確認してください（docker compose ps）']);
  }
}

function schedule() {
  if (timer) clearInterval(timer);
  timer = setInterval(refresh, pollSeconds * 1000);
}

refresh();
schedule();
// タブを再表示したときは間隔を待たずに取り直す
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) refresh();
});
