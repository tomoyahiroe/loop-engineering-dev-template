import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.mjs';
import { checkIssue, extractDepRefs } from './gate.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const loopDir = process.env.LOOP_DIR || resolve(here, '..');

const argv = process.argv.slice(2);
let bodyFile = null;
let issue = null;
const depStates = {};

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--body-file') {
    bodyFile = argv[++i];
  } else if (a === '--dep-state') {
    const [n, s] = String(argv[++i]).split('=');
    depStates[n] = s;
  } else if (/^\d+$/.test(a)) {
    issue = a;
  } else {
    process.stderr.write(`不明な引数: ${a}\n`);
    process.exit(2);
  }
}

if (!bodyFile && !issue) {
  process.stderr.write('usage: loop-gate <issue-number> | loop-gate --body-file <path> [--dep-state N=CLOSED]...\n');
  process.exit(2);
}

const gh = (args) => execFileSync('gh', args, { encoding: 'utf8' });

let body;
if (bodyFile) {
  body = readFileSync(bodyFile, 'utf8');
} else {
  try {
    body = JSON.parse(gh(['issue', 'view', issue, '--json', 'body'])).body || '';
  } catch (e) {
    process.stderr.write(`Issue #${issue} を取得できない: ${e.message}\n`);
    process.exit(2);
  }
  for (const ref of extractDepRefs(body)) {
    if (depStates[ref]) continue;
    try {
      depStates[ref] = JSON.parse(gh(['issue', 'view', ref, '--json', 'state'])).state;
    } catch {
      depStates[ref] = 'unknown';
    }
  }
}

const config = loadConfig(loopDir);
const { ok, violations } = checkIssue({ body, config, depStates });

if (ok) {
  process.stdout.write('GATE OK\n');
  process.exit(0);
}
process.stdout.write(`GATE FAILED (${violations.length} 件)\n`);
for (const x of violations) process.stdout.write(`- ${x}\n`);
process.exit(1);
