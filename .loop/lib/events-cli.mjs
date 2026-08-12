// loops/events.jsonl の読み書き。判定と整形は events.mjs（純関数）の仕事。
//
// 用法:
//   events-cli.mjs append --kind <kind> [--field k=v ...]
//   events-cli.mjs tail [--limit N]
//
// append は観測のためのログなので、失敗してもループ本体を止めない。
// 書き込めなかったことを stderr に出して終了コード 0 で抜ける（firing は
// この呼び出しを || true で囲っているが、二重に守る）。
// 例外は「未知の kind」で、これは配線ミスなので終了コード 2 で落とす。

import {
  appendFileSync, readFileSync, mkdirSync,
  statSync, openSync, readSync, closeSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { buildLine, parseField, tail } from './events.mjs';

const argv = process.argv.slice(2);
const cmd = argv[0];

const REPO_ROOT = process.env.REPO_ROOT || process.cwd();
const LOG_PATH = join(REPO_ROOT, 'loops', 'events.jsonl');

function optValue(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

// 末尾が改行で終わっているか。ファイル全体は読まない（ログは増え続ける）。
// 存在しない・読めない場合は true（= 先頭に改行を足さない）を返す
function endsWithNewline(path) {
  let fd;
  try {
    const { size } = statSync(path);
    if (size === 0) return true;
    fd = openSync(path, 'r');
    const buf = Buffer.alloc(1);
    readSync(fd, buf, 0, 1, size - 1);
    return buf[0] === 0x0a;
  } catch {
    return true;
  } finally {
    if (fd !== undefined) { try { closeSync(fd); } catch { /* noop */ } }
  }
}

function optValues(name) {
  const out = [];
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === name && argv[i + 1] !== undefined) out.push(argv[i + 1]);
  }
  return out;
}

if (cmd === 'append') {
  const kind = optValue('--kind');
  if (!kind) {
    process.stderr.write('--kind が必要です\n');
    process.exit(2);
  }

  const fields = {};
  for (const kv of optValues('--field')) {
    const parsed = parseField(kv);
    if (parsed) Object.assign(fields, parsed);
  }

  let line;
  try {
    line = buildLine(kind, fields);
  } catch (e) {
    // 未知の kind は配線ミス。握りつぶすと値域と実装のズレが表に出ないまま
    // 残るので、ここだけは落とす（tests/events.bats が双方向に照合している）
    process.stderr.write(`${e.message}\n`);
    process.exit(2);
  }

  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    // 前回の書き込みがコンテナの kill で途中終了していると、最終行に改行が
    // ない。そのまま追記すると切れた行と今回の行が 1 行に連結され、
    // **今回のイベントまで失われる**（kill 1 回で 2 件消える）。
    // 改行を足して切り離せば、壊れるのは切れた行だけで済む
    const prefix = endsWithNewline(LOG_PATH) ? '' : '\n';
    appendFileSync(LOG_PATH, `${prefix}${line}\n`);
  } catch (e) {
    process.stderr.write(`events.jsonl に追記できませんでした: ${e.message}\n`);
  }
  process.exit(0);
}

if (cmd === 'tail') {
  const limit = optValue('--limit') ?? 50;
  let text = '';
  try {
    text = readFileSync(LOG_PATH, 'utf8');
  } catch {
    // ログがまだない（セットアップ直後・初回 firing 前）は空配列を返す。
    // UI 側でエラー表示にしない
  }
  process.stdout.write(`${JSON.stringify(tail(text, limit))}\n`);
  process.exit(0);
}

process.stderr.write('用法: events-cli.mjs append --kind <kind> [--field k=v ...] | tail [--limit N]\n');
process.exit(2);
