// プロジェクトの test / lint / preview コマンドを推測する純関数群。
// I/O は一切しない（呼び出し側が読んだ内容を渡す）。
//
// extra_tools は test / lint と同じ検出結果から導出する。
// これにより「[project] は設定されているのに extra_tools が空」という
// 状態が構造的に起こらない（spec 達成条件 C）。
//
// 方針: 間違った提案をするより、検出できなかったと言うほうが良い。
// ユーザーは空欄なら気づくが、もっともらしい間違いには気づかない。

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
  // bun の `bun <name>` はスクリプト実行のショートカットではなく、
  // 名前が衝突すると Bun 自身の組み込みサブコマンドが動く（顕著なのは
  // `bun test` = Bun の組み込みテストランナーで、scripts.test が
  // vitest/jest でも黙って無視される）。常に明示形の `bun run <name>` を使う
  if (pm === 'bun') return `bun run ${name}`;
  return `${pm} ${name}`;
}

// npm init が生成する既定の test スタブ。「テストが緑」を満たせないコマンドを
// 本物のテストとして採用しないためのガード
const NPM_TEST_STUB_RE = /no test specified/i;

function fromPackageJson(packageJson, lockfiles) {
  const scripts = (packageJson && packageJson.scripts) || {};
  const pm = pickPackageManager(lockfiles);
  const isStubTest = Boolean(scripts.test) && NPM_TEST_STUB_RE.test(scripts.test);
  const hasTest = Boolean(scripts.test) && !isStubTest;
  const preview = ['dev', 'start', 'serve'].find((k) => scripts[k]);
  const test = hasTest ? scriptCmd(pm, 'test') : '';
  const lint = scripts.lint ? scriptCmd(pm, 'lint') : '';
  const previewCmd = preview ? scriptCmd(pm, preview) : '';

  // 何も見つからなかった（スタブの検出すら無かった）なら、package.json の
  // scripts から検出したと名乗らない。monorepo のルート package.json に
  // workspaces はあっても scripts が無いケースがこれに当たる
  if (!test && !lint && !previewCmd && !isStubTest) return null;

  const base = `package.json の scripts（パッケージマネージャ: ${pm}）`;
  const source = isStubTest
    ? `${base}。npm の既定スタブ（"no test specified"）を検出したので test は未設定にしました`
    : base;

  return { test, lint, preview: previewCmd, tools: [pm], source };
}

function fromCargo(cargo) {
  const hasPackage = Boolean(cargo && cargo.package);
  const hasWorkspace = Boolean(cargo && cargo.workspace);
  // [workspace] のみで [package] が無い＝仮想マニフェスト（workspace ルート）。
  // 実行可能な単一クレートが無いので `cargo run` は提案しない
  const isWorkspaceRoot = hasWorkspace && !hasPackage;
  return {
    test: 'cargo test',
    lint: 'cargo clippy',
    preview: isWorkspaceRoot ? '' : 'cargo run',
    tools: ['cargo'],
    source: isWorkspaceRoot
      ? 'Cargo.toml（workspace ルート。preview は各メンバーで実行してください）'
      : 'Cargo.toml',
  };
}

function collectDepNames(list, into) {
  if (!Array.isArray(list)) return;
  for (const entry of list) {
    if (typeof entry !== 'string') continue;
    const m = entry.match(/^[A-Za-z0-9][A-Za-z0-9_.-]*/);
    if (m) into.add(m[0].toLowerCase());
  }
}

function pyprojectDependencyNames(pyproject) {
  const names = new Set();
  const project = (pyproject && pyproject.project) || {};
  collectDepNames(project.dependencies, names);
  const optional = project['optional-dependencies'] || {};
  for (const list of Object.values(optional)) collectDepNames(list, names);
  const groups = (pyproject && pyproject['dependency-groups']) || {};
  for (const list of Object.values(groups)) collectDepNames(list, names);
  const poetry = pyproject && pyproject.tool && pyproject.tool.poetry;
  if (poetry) {
    for (const key of Object.keys(poetry.dependencies || {})) names.add(key.toLowerCase());
    const poetryGroups = poetry.group || {};
    for (const group of Object.values(poetryGroups)) {
      for (const key of Object.keys((group && group.dependencies) || {})) names.add(key.toLowerCase());
    }
  }
  return names;
}

function fromPyproject(pyproject) {
  // pyproject.toml の存在だけでは pytest/ruff が入っている根拠にならない
  // （Cargo.toml と違い、これらは同梱ツールではない）。依存関係の記載か
  // 各ツールの設定セクションが実際にあるときだけ提案する
  const names = pyprojectDependencyNames(pyproject);
  const tool = (pyproject && pyproject.tool) || {};
  const hasPytest = names.has('pytest') || Boolean(tool.pytest);
  const hasRuff = names.has('ruff') || Boolean(tool.ruff);
  if (!hasPytest && !hasRuff) return null;

  const tools = [];
  if (hasPytest) tools.push('pytest');
  if (hasRuff) tools.push('ruff');
  tools.push('python3');

  return {
    test: hasPytest ? 'pytest' : '',
    lint: hasRuff ? 'ruff check .' : '',
    preview: '',
    tools,
    source: 'pyproject.toml の依存関係（pytest/ruff の記載を検出）',
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
  else if (cargo) hit = fromCargo(cargo);
  else if (pyproject) hit = fromPyproject(pyproject);
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

// TOML basic string の正しいエスケープ。バックスラッシュは他の何よりも先に
// 一回のパスで処理する必要がある（"\"" のような値を先に `"` → `\"` に
// 置換してから `\` を処理すると、既に挿入した `\` まで二重にエスケープされ
// 壊れた TOML になる）。1 文字ずつ見て都度エスケープ形を出力することで
// その順序問題を構造的に避ける
const TOML_ESCAPES = {
  '\\': '\\\\',
  '"': '\\"',
  '\b': '\\b',
  '\t': '\\t',
  '\n': '\\n',
  '\f': '\\f',
  '\r': '\\r',
};

function q(value) {
  const str = String(value);
  let out = '"';
  for (const ch of str) {
    if (TOML_ESCAPES[ch]) {
      out += TOML_ESCAPES[ch];
      continue;
    }
    const code = ch.codePointAt(0);
    out += code < 0x20 || code === 0x7f ? `\\u${code.toString(16).padStart(4, '0')}` : ch;
  }
  return `${out}"`;
}

export function toToml(d) {
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
