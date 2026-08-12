// コントロールプレーン（観測 UI）の HTTP サーバ。
// 判定と整形は control-plane.mjs（純関数）の仕事。ここは I/O だけを持つ。
//
// 設計上の約束:
//   - **すべて GET。** 状態を変える経路を一切持たない。プレビュー起動などの
//     制御は次のカットで、認証と CSRF の設計とセットで入れる
//   - **127.0.0.1 にだけ bind する。** 設定では変えられない。compose が
//     network_mode: host なので、0.0.0.0 にすると同一 LAN の全員に
//     Issue タイトルとトークン消費量が見える
//   - **gh が落ちても 500 にしない。** その部分だけ欠けた JSON を返す。
//     GitHub が一時的に不調なだけで UI 全体が真っ白になるのは観測手段として
//     質が悪い。どこが取れなかったかは errors に入れて画面に出す

import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { dirname, resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, getKey } from './config.mjs';
import {
  parseCrontabHours, nextFiring, parseBudget,
  safeJoin, classifyIssues, summarizePrs,
} from './control-plane.mjs';
import { tail } from './events.mjs';

const HOST = '127.0.0.1'; // 固定。設定で変えられないのは意図的
const here = dirname(fileURLToPath(import.meta.url));

// common.sh と同じ原則で、コードの所在と設定の所在を分ける。
//   here     … コードの所在。bin/ と web/ はここから引く
//   LOOP_DIR … 設定の所在。config.toml / defaults.toml はここから読む
//   REPO_ROOT… データの所在。loops/ はここから読む
// テストは実物のコードのまま fixture の設定とリポジトリを使うため、
// bin/ を LOOP_DIR から引くと fixture 側に bin/ がなく実行できなくなる
const CODE_DIR = resolve(here, '..');
const LOOP_DIR = process.env.LOOP_DIR || CODE_DIR;
const REPO_ROOT = process.env.REPO_ROOT || resolve(CODE_DIR, '..');
const BIN_DIR = resolve(CODE_DIR, 'bin');
const WEB_DIR = resolve(CODE_DIR, 'web');
const RUNS_DIR = resolve(REPO_ROOT, 'loops', 'runs');
const EVENTS_PATH = resolve(REPO_ROOT, 'loops', 'events.jsonl');

let cfg = {};
try {
  cfg = loadConfig(LOOP_DIR);
} catch (e) {
  process.stderr.write(`設定を読めません: ${e.message}\n`);
  process.exit(2);
}
const num = (key, fallback) => {
  const v = Number(getKey(cfg, key));
  return Number.isFinite(v) && v > 0 ? v : fallback;
};

const argPort = (() => {
  const i = process.argv.indexOf('--port');
  return i >= 0 ? Number(process.argv[i + 1]) : NaN;
})();
const PORT = Number.isFinite(argPort) && argPort > 0 ? argPort : num('ui.port', 7717);
const POLL_SECONDS = num('ui.poll_seconds', 10);
const CACHE_MS = num('ui.cache_seconds', 30) * 1000;
const CMD_TIMEOUT = num('ui.command_timeout_seconds', 20) * 1000;
const READY_LABEL = 'loop:ready';

// --- 子プロセス -------------------------------------------------------------

// シェルを経由しない（execFile）。タイムアウトを必ず付ける — gh がハングすると
// ポーリングが詰まって UI ごと固まる。
// 終了コードが非 0 でも stdout は返す。budget-check は fail-closed の SKIP を
// 非 0 で返すが、その理由こそ表示したい情報だから
function run(cmd, args = []) {
  return new Promise((done) => {
    execFile(cmd, args, {
      cwd: REPO_ROOT,
      timeout: CMD_TIMEOUT,
      maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, REPO_ROOT, LOOP_DIR },
    }, (err, stdout, stderr) => {
      // 失敗の説明は stderr → stdout → エラーコードの順に拾う。
      // ENOENT や ETIMEDOUT は stderr が空のまま返るので、ここで拾わないと
      // 画面に「取得できません: 」とだけ出て原因が一切分からなくなる
      const detail = String(stderr ?? '').trim() || String(stdout ?? '').trim();
      done({
        code: err?.code ?? 0,
        stdout: String(stdout ?? ''),
        stderr: String(stderr ?? ''),
        failed: Boolean(err),
        timedOut: err?.killed === true,
        detail: detail
          ? detail.split('\n')[0]
          : (err ? `${cmd} を実行できません (${err.code ?? 'unknown'})` : ''),
      });
    });
  });
}

// gh 呼び出しの短期キャッシュ。プロセス内メモリのみ。
// ポーリングのたびに叩くと体感が遅く、GitHub のレート制限も無駄に減る
const cache = new Map();
async function cached(key, fn) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.value;
  const value = await fn();
  cache.set(key, { at: Date.now(), value });
  return value;
}

const ghJson = (args) => cached(`gh:${args.join(' ')}`, async () => {
  const r = await run('gh', args);
  if (r.failed) return { ok: false, data: null, error: r.detail };
  try {
    return { ok: true, data: JSON.parse(r.stdout), error: null };
  } catch {
    return { ok: false, data: null, error: 'gh の出力を JSON として解釈できません' };
  }
});

const listIssues = () => ghJson(['issue', 'list', '--state', 'open',
  '--limit', '50', '--json', 'number,title,labels,url']);
const listPrs = () => ghJson(['pr', 'list', '--state', 'open',
  '--limit', '50', '--json', 'number,title,headRefName,reviewDecision,url']);

// --- エンドポイント ---------------------------------------------------------

async function apiStatus() {
  const errors = [];

  const budgetRes = await cached('budget', () => run(resolve(BIN_DIR, 'budget-check')));
  const budget = parseBudget(budgetRes.stdout);
  if (budgetRes.timedOut) errors.push('budget-check がタイムアウトしました');

  const cron = await cached('cron', () => run(resolve(BIN_DIR, 'gen-crontab')));
  const hours = parseCrontabHours(cron.stdout.split('\n')[0] ?? '');
  const next = nextFiring(hours);
  if (hours.length === 0) errors.push('crontab から発火時刻を読めませんでした');

  const prs = await listPrs();
  if (!prs.ok) errors.push(`PR 一覧を取得できません: ${prs.error}`);

  const issues = await listIssues();
  if (!issues.ok) errors.push(`Issue 一覧を取得できません: ${issues.error}`);
  const ready = issues.ok
    ? classifyIssues(issues.data, READY_LABEL).ready.length
    : null;

  const today = new Date().toISOString().slice(0, 10);
  const events = tail(await readText(EVENTS_PATH), 500);
  const dispatchedToday = events
    .filter((e) => e.kind === 'dispatch' && String(e.ts ?? '').startsWith(today))
    .length;

  return {
    maturity: getKey(cfg, 'maturity') ?? null,
    budget: {
      used: budget.used,
      limit: budget.limit,
      reason: budget.reason,
      // 非 0 で返っていても used/limit が取れていれば表示する
      blocked: budgetRes.failed,
    },
    firing: {
      hours,
      next: next ? next.toISOString() : null,
      firings_per_day: hours.length,
    },
    prs: prs.ok
      ? { ...summarizePrs(prs.data), max: getKey(cfg, 'loop.max_open_prs') ?? null }
      : { open: null, items: [], max: getKey(cfg, 'loop.max_open_prs') ?? null },
    queue: {
      ready,
      dispatched_today: dispatchedToday,
      max_per_day: getKey(cfg, 'loop.max_dispatch_per_day') ?? null,
    },
    poll_seconds: POLL_SECONDS,
    generated_at: new Date().toISOString(),
    errors,
  };
}

async function readText(path) {
  try {
    return await readFile(path, 'utf8');
  } catch {
    // ログがまだない（初回 firing 前）はエラーにしない
    return '';
  }
}

async function apiEvents(url) {
  const limit = Number(url.searchParams.get('limit')) || 50;
  return { events: tail(await readText(EVENTS_PATH), limit) };
}

async function apiIssues() {
  const res = await listIssues();
  if (!res.ok) {
    return { needs_human: [], ready: [], other: [], errors: [`Issue 一覧を取得できません: ${res.error}`] };
  }
  return { ...classifyIssues(res.data, READY_LABEL), errors: [] };
}

async function apiRun(name) {
  const path = safeJoin(RUNS_DIR, name);
  if (!path) return { status: 400, body: { error: '不正なファイル名です' } };
  if (!path.endsWith('.md')) return { status: 400, body: { error: '.md のみ参照できます' } };
  try {
    return { status: 200, body: { name, content: await readFile(path, 'utf8') } };
  } catch {
    return { status: 404, body: { error: '見つかりません' } };
  }
}

// --- 静的配信 ---------------------------------------------------------------

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
};

async function serveStatic(pathname, res) {
  // %2f のような符号化されたセパレータを素通しにしない。デコードしてから
  // safeJoin に渡すことで、/api/runs/:name と同じ基準で弾ける
  let name;
  try {
    name = pathname === '/' ? 'index.html' : decodeURIComponent(pathname.slice(1));
  } catch {
    return send(res, 400, { error: '不正なパスです' });
  }
  const path = safeJoin(WEB_DIR, name);
  if (!path) return send(res, 400, { error: '不正なパスです' });
  try {
    const body = await readFile(path);
    res.writeHead(200, {
      'content-type': MIME[extname(path)] ?? 'application/octet-stream',
      'cache-control': 'no-store',
    });
    res.end(body);
  } catch {
    send(res, 404, { error: '見つかりません' });
  }
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(text);
}

// --- ルーティング -----------------------------------------------------------

const server = createServer(async (req, res) => {
  // 状態を変える経路を持たないので、GET 以外は入口で断る
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(res, 405, { error: 'このサーバは読み取り専用です（GET のみ）' });
  }

  const url = new URL(req.url, `http://${HOST}:${PORT}`);
  const p = url.pathname;

  try {
    if (p === '/api/status') return send(res, 200, await apiStatus());
    if (p === '/api/events') return send(res, 200, await apiEvents(url));
    if (p === '/api/issues') return send(res, 200, await apiIssues());
    if (p.startsWith('/api/runs/')) {
      const r = await apiRun(decodeURIComponent(p.slice('/api/runs/'.length)));
      return send(res, r.status, r.body);
    }
    if (p.startsWith('/api/')) return send(res, 404, { error: '不明なエンドポイントです' });
    return await serveStatic(p, res);
  } catch (e) {
    // 想定外の例外でもプロセスを落とさない。観測 UI が落ちてループ本体の
    // 監視ができなくなるほうが困る
    process.stderr.write(`control-plane: ${e?.stack ?? e}\n`);
    return send(res, 500, { error: '内部エラー' });
  }
});

server.listen(PORT, HOST, () => {
  process.stdout.write(`control-plane: http://${HOST}:${PORT} で待機中\n`);
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    process.stderr.write(
      `control-plane: ポート ${PORT} は使用中です。`
      + '.loop/config.toml の [ui] port を変えるか、既に起動しているサーバを止めてください\n',
    );
    process.exit(1);
  }
  process.stderr.write(`control-plane: ${e.message}\n`);
  process.exit(1);
});
