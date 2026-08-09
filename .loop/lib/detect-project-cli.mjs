import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { parse } from 'smol-toml';
import { detectProject, toToml } from './detect-project.mjs';

const argv = process.argv.slice(2);
const i = argv.indexOf('--dir');
const dir = i >= 0 ? argv[i + 1] : process.cwd();

if (!existsSync(dir)) {
  process.stderr.write(`ディレクトリがありません: ${dir}\n`);
  process.exit(2);
}

const readJson = (p) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; }
};
const readToml = (p) => {
  try { return parse(readFileSync(p, 'utf8')); } catch { return null; }
};

const entries = readdirSync(dir);
const makefilePath = join(dir, 'Makefile');
const makefileTargets = existsSync(makefilePath)
  ? [...readFileSync(makefilePath, 'utf8').matchAll(/^([A-Za-z0-9_-]+):/gm)].map((m) => m[1])
  : [];

const result = detectProject({
  packageJson: existsSync(join(dir, 'package.json')) ? readJson(join(dir, 'package.json')) : null,
  lockfiles: entries,
  makefileTargets,
  pyproject: existsSync(join(dir, 'pyproject.toml')) ? readToml(join(dir, 'pyproject.toml')) : null,
  cargo: existsSync(join(dir, 'Cargo.toml')) ? readToml(join(dir, 'Cargo.toml')) : null,
});

process.stdout.write(`${toToml(result)}\n`);
