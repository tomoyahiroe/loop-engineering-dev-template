// プロジェクトの test / lint / preview コマンドを推測する純関数群。
// I/O は一切しない（呼び出し側が読んだ内容を渡す）。
//
// extra_tools は test / lint と同じ検出結果から導出する。
// これにより「[project] は設定されているのに extra_tools が空」という
// 状態が構造的に起こらない（spec 達成条件 C）。

const PM_BY_LOCKFILE = {
  'pnpm-lock.yaml': 'pnpm',
  'yarn.lock': 'yarn',
  'bun.lockb': 'bun',
  'package-lock.json': 'npm',
};

export function pickPackageManager(lockfiles) {
  for (const [file, pm] of Object.entries(PM_BY_LOCKFILE)) {
    if (lockfiles.includes(file)) return pm;
  }
  return 'npm';
}

function scriptCmd(pm, name) {
  if (pm === 'npm') return name === 'test' ? 'npm test' : `npm run ${name}`;
  return `${pm} ${name}`;
}

function fromPackageJson(packageJson, lockfiles) {
  const scripts = (packageJson && packageJson.scripts) || {};
  const pm = pickPackageManager(lockfiles);
  const preview = ['dev', 'start', 'serve'].find((k) => scripts[k]);
  return {
    test: scripts.test ? scriptCmd(pm, 'test') : '',
    lint: scripts.lint ? scriptCmd(pm, 'lint') : '',
    preview: preview ? scriptCmd(pm, preview) : '',
    tools: [pm],
    source: `package.json の scripts（パッケージマネージャ: ${pm}）`,
  };
}

function fromCargo() {
  return {
    test: 'cargo test',
    lint: 'cargo clippy',
    preview: 'cargo run',
    tools: ['cargo'],
    source: 'Cargo.toml',
  };
}

function fromPyproject() {
  return {
    test: 'pytest',
    lint: 'ruff check .',
    preview: '',
    tools: ['pytest', 'ruff', 'python3'],
    source: 'pyproject.toml',
  };
}

function fromMakefile(targets) {
  const has = (t) => targets.includes(t);
  if (!has('test') && !has('lint')) return null;
  return {
    test: has('test') ? 'make test' : '',
    lint: has('lint') ? 'make lint' : '',
    preview: has('dev') ? 'make dev' : '',
    tools: ['make'],
    source: 'Makefile の target',
  };
}

const EMPTY = {
  test: '',
  lint: '',
  preview: '',
  tools: [],
  source: '検出できませんでした。手で設定してください',
};

export function detectProject(inputs) {
  const { packageJson, lockfiles = [], makefileTargets = [], pyproject, cargo } = inputs;

  let hit = null;
  if (packageJson) hit = fromPackageJson(packageJson, lockfiles);
  else if (cargo) hit = fromCargo();
  else if (pyproject) hit = fromPyproject();
  if (!hit || (!hit.test && !hit.lint)) {
    const mk = fromMakefile(makefileTargets);
    if (mk) hit = mk;
  }
  if (!hit) hit = EMPTY;

  // test も lint も無いなら extra_tools も空にする（対応を崩さない）
  const needsTools = Boolean(hit.test || hit.lint);
  const extraTools = needsTools ? hit.tools.map((t) => `Bash(${t}:*)`) : [];

  return {
    test: hit.test,
    lint: hit.lint,
    preview: hit.preview,
    extraTools,
    source: hit.source,
  };
}

export function toToml(d) {
  const q = (s) => `"${String(s).replace(/"/g, '\\"')}"`;
  const tools = d.extraTools.length
    ? `[${d.extraTools.map(q).join(', ')}]`
    : '[]';
  return [
    `# 検出元: ${d.source}`,
    '[project]',
    `test = ${q(d.test)}`,
    `lint = ${q(d.lint)}`,
    `preview = ${q(d.preview)}`,
    '',
    '[agents.claude]',
    `extra_tools = ${tools}`,
  ].join('\n');
}
