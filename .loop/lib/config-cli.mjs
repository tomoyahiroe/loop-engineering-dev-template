import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, getKey, formatValue } from './config.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const loopDir = process.env.LOOP_DIR || resolve(here, '..');

const [cmd, key] = process.argv.slice(2);

let cfg;
try {
  cfg = loadConfig(loopDir);
} catch (e) {
  process.stderr.write(`${e.message}\n`);
  process.exit(2);
}

if (cmd === 'dump') {
  process.stdout.write(`${JSON.stringify(cfg, null, 2)}\n`);
  process.exit(0);
}

if (cmd !== 'get' || !key) {
  process.stderr.write('usage: loop-config get <dotted.key> | loop-config dump\n');
  process.exit(2);
}

const out = formatValue(getKey(cfg, key));
if (out === null) process.exit(1);
process.stdout.write(`${out}\n`);
