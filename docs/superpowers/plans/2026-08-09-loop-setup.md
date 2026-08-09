# P2 ワンショットセットアップ 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** クローンから常駐開始までを `/loop-setup` の 1 コマンドに畳み、設定の不整合を `/loop-doctor` でいつでも検出できるようにする。

**Architecture:** 検査と検出のロジックはテスト可能なコード（`.loop/bin/loop-doctor`、`.loop/lib/detect-project.mjs`）に置き、2 つのスキルはそれを呼んで人間向けに整えるだけの薄い層にする。判定ロジックは純関数、I/O は CLI 側。

**Tech Stack:** bash 3.2 / Node.js ESM / bats-core / 既存の `.loop/lib/common.sh`

**Spec:** `docs/superpowers/specs/2026-08-09-loop-setup-design.md`

## Global Constraints

- **bash 3.2 互換**（`/bin/bash` は 3.2.57）: `mapfile` / `readarray` / `declare -A` / `${var^^}` を使わない。配列は `while IFS= read -r` + プロセス置換
- すべてのシェルスクリプトは `set -uo pipefail` で始める。`set -e` は使わない
- **`$VAR` の直後に全角文字を置かない。** `"$LOG（…）"` は変数名に全角括弧が吸われて unbound variable になる（bash 3.2 / 5 の両方で再現）。必ず `${LOG}` の形にする
- **`${VAR:-{"a":"b"}}` の形を書かない。** VAR が設定されているとき末尾に余分な `}` が付く。既定値は変数に入れてから `${VAR:-$DEFAULT}` にする
- Node の依存は増やさない（`smol-toml` のみ）。実行ファイルは `.mjs`
- ユーザー向けメッセージは日本語、識別子は英語
- Conventional Commits
- テストは `cd .loop && npx bats tests/`
- bats の `setup()` は `.loop/tests/helpers.bash` の共通関数を使う

## File Structure

```
.loop/lib/
  detect-project.mjs        [新規] 検出の純関数群（I/O なし）
  detect-project-cli.mjs    [新規] detect-project の CLI（ファイル読み込み）
.loop/bin/
  detect-project            [新規] CLI の bash ラッパー
  loop-doctor               [新規] 検査の実体
.claude/skills/
  loop-setup/SKILL.md       [新規] ホストで走る対話セットアップ
  loop-doctor/SKILL.md      [新規] loop-doctor を呼んで整える
  loop-mtg/SKILL.md         [変更] ①に loop-doctor を足す
.loop/tests/
  detect-project.bats       [新規]
  loop-doctor.bats          [新規]
  skill-references.bats     [新規] 全スキルの参照を機械的に照合
  fixtures/bin/gh           [変更] label list / label create を追加
  fixtures/bin/docker       [新規] docker スタブ
  fixtures/projects/**      [新規] 検出テスト用のプロジェクト断片
README.md                   [変更] 手順を /loop-setup に置き換える
```

**責務の分割:** 判定は純関数（`detect-project.mjs`）、I/O は CLI、制御フローは bash、人間向けの表現はスキル。P1 と同じ層構造を保つ。

---

### Task 1: プロジェクト検出（`detect-project`）

**Files:**
- Create: `.loop/lib/detect-project.mjs`
- Create: `.loop/lib/detect-project-cli.mjs`
- Create: `.loop/bin/detect-project`
- Test: `.loop/tests/detect-project.bats`, `.loop/tests/fixtures/projects/**`

**Interfaces:**
- Consumes: なし（新規）
- Produces:
  - `detect-project.mjs` が `detectProject(inputs)` を export する。`inputs` は
    `{ packageJson, lockfiles, makefileTargets, pyproject, cargo }`。
    返り値は `{ test, lint, preview, extraTools, source }`
  - `.loop/bin/detect-project --dir <path>` が検出結果を TOML 断片として標準出力に書く
  - **`extraTools` は `test`/`lint` と同じ検出から導出する。** これにより
    「片方だけ設定される」状態が構造的に起こらない（spec 達成条件 C）

- [ ] **Step 1: fixture を作る**

`.loop/tests/fixtures/projects/pnpm/package.json`:

```json
{
  "name": "sample",
  "scripts": { "test": "vitest run", "lint": "eslint .", "dev": "vite" }
}
```

`.loop/tests/fixtures/projects/pnpm/pnpm-lock.yaml`: 空ファイル（存在だけが意味を持つ）

`.loop/tests/fixtures/projects/npm/package.json`:

```json
{
  "name": "sample",
  "scripts": { "test": "jest" }
}
```

`.loop/tests/fixtures/projects/npm/package-lock.json`: `{}`

`.loop/tests/fixtures/projects/cargo/Cargo.toml`:

```toml
[package]
name = "sample"
version = "0.1.0"
```

`.loop/tests/fixtures/projects/python/pyproject.toml`:

```toml
[project]
name = "sample"
```

`.loop/tests/fixtures/projects/make/Makefile`:

```makefile
test:
	go test ./...

lint:
	golangci-lint run
```

`.loop/tests/fixtures/projects/empty/.gitkeep`: 空ファイル

- [ ] **Step 2: 失敗するテストを書く**

`.loop/tests/detect-project.bats`:

```bash
#!/usr/bin/env bats

load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/projects"

@test "pnpm: lockfile から pnpm を選び、scripts を拾う" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/pnpm"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = "pnpm test"'* ]]
  [[ "$output" == *'lint = "pnpm lint"'* ]]
  [[ "$output" == *'preview = "pnpm dev"'* ]]
}

@test "pnpm: extra_tools が pnpm を含む" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/pnpm"
  [[ "$output" == *'Bash(pnpm:*)'* ]]
}

@test "npm: lockfile が package-lock.json なら npm を選ぶ" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm"
  [[ "$output" == *'test = "npm test"'* ]]
  [[ "$output" == *'Bash(npm:*)'* ]]
}

@test "npm: scripts に無いものは空文字になる" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/npm"
  [[ "$output" == *'lint = ""'* ]]
}

@test "cargo: Cargo.toml から cargo のコマンドを出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/cargo"
  [[ "$output" == *'test = "cargo test"'* ]]
  [[ "$output" == *'Bash(cargo:*)'* ]]
}

@test "python: pyproject.toml から pytest を出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/python"
  [[ "$output" == *'pytest'* ]]
}

@test "make: Makefile の target から make のコマンドを出す" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/make"
  [[ "$output" == *'test = "make test"'* ]]
  [[ "$output" == *'lint = "make lint"'* ]]
  [[ "$output" == *'Bash(make:*)'* ]]
}

@test "empty: 何も検出できなければ空の値を返し、終了コードは 0" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test = ""'* ]]
}

@test "empty: 検出できなかったことが source に出る" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/empty"
  [[ "$output" == *"検出できません"* ]]
}

@test "test/lint が空なら extra_tools も空（対応が崩れない）" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/empty"
  [[ "$output" == *'extra_tools = []'* ]]
}

@test "存在しないディレクトリは終了コード 2" {
  run "$LOOP_REAL_DIR/bin/detect-project" --dir "$FIX/nope"
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 3: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/detect-project.bats`
Expected: FAIL（`bin/detect-project` が存在しない）

- [ ] **Step 4: `.loop/lib/detect-project.mjs` を書く**

```javascript
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
```

- [ ] **Step 5: `.loop/lib/detect-project-cli.mjs` を書く**

```javascript
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
```

- [ ] **Step 6: `.loop/bin/detect-project` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# プロジェクトの test / lint / preview を推測して TOML 断片を出力する
# 用法: detect-project [--dir <path>]
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SELF_DIR/../lib/detect-project-cli.mjs" "$@"
```

Run: `chmod +x .loop/bin/detect-project`

- [ ] **Step 7: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/detect-project.bats`
Expected: 11 tests, all PASS

- [ ] **Step 8: 全テストを実行して退行がないことを確認する**

Run: `cd .loop && npx bats tests/`
Expected: 213 + 11 = 224 tests, all PASS

- [ ] **Step 9: コミット**

```bash
git add .loop/lib/detect-project.mjs .loop/lib/detect-project-cli.mjs \
        .loop/bin/detect-project .loop/tests/detect-project.bats \
        .loop/tests/fixtures/projects
git commit -m "feat(setup): プロジェクトの test/lint/preview を検出する detect-project を追加"
```

---

### Task 2: 健全性チェック（`loop-doctor`）

**Files:**
- Create: `.loop/bin/loop-doctor`
- Modify: `.loop/tests/fixtures/bin/gh`（`label list` / `label create` を追加）
- Create: `.loop/tests/fixtures/bin/docker`（docker スタブ）
- Test: `.loop/tests/loop-doctor.bats`

**Interfaces:**
- Consumes: `.loop/lib/common.sh` の `cfg` / `LOOP_DIR` / `REPO_ROOT`、`.loop/bin/loop-config`、`.loop/bin/gen-crontab`
- Produces:
  - `loop-doctor` — 全検査を実行し、1 項目 1 行で結果を出す。終了コード 0 = 全合格 / 1 = 1 件以上失敗
  - `loop-doctor --quiet` — 失敗した項目だけを出す
  - 各行の形式: `OK   <検査名>: <補足>` / `NG   <検査名>: <何が問題か>` / `SKIP <検査名>: <なぜ確認できないか>`
  - **`SKIP` は失敗として数えない**（確認できないことと壊れていることは違う）

**検査項目と依存関係:**

```
1. config 構文        loop-config dump が通るか
2. project/tools 対応  [project] test/lint と extra_tools の対応
3. cron 発火時刻       gen-crontab が妥当な行を出すか
4. worktree 残骸       所有者のいない -verify-pr-* があるか
5. コンテナ稼働        docker compose ps
6. claude 認証         ← 5 が OK のときだけ実行。NG なら SKIP
7. gh 認証             ← 5 が OK のときだけ実行。NG なら SKIP
8. ラベル 3 つ         ← 7 が OK のときだけ実行。NG なら SKIP
```

6〜8 はコンテナの中を見る必要があるため、5 が失敗したら **SKIP**（失敗ではない）。
「確認できない」を「壊れている」と報告すると、doctor 自体が信用されなくなる。

- [ ] **Step 1: `gh` スタブに label 対応を追加する**

`.loop/tests/fixtures/bin/gh` の `case` に追加する（既存の分岐は触らない）:

```bash
  "label list")   echo "${GH_LABEL_LIST_JSON:-[]}" ;;
  "label create") exit "${GH_LABEL_CREATE_EXIT:-${GH_EXIT:-0}}" ;;
  "auth status")  exit "${GH_AUTH_EXIT:-${GH_EXIT:-0}}" ;;
```

既定値は必ず変数に入れてから `${VAR:-$DEFAULT}` の形で使うこと（波括弧を直接書くと
VAR が設定されているとき末尾に `}` が付く）。

- [ ] **Step 2: `docker` スタブを作る**

`.loop/tests/fixtures/bin/docker`:

```bash
#!/usr/bin/env bash
# テスト用の docker スタブ。呼び出しを $DOCKER_LOG に記録し、環境変数で応答を決める
set -uo pipefail
[ -n "${DOCKER_LOG:-}" ] && echo "$*" >> "$DOCKER_LOG"

DEFAULT_PS_JSON='[]'

case "${1:-} ${2:-}" in
  "compose ps")
    echo "${DOCKER_PS_JSON:-$DEFAULT_PS_JSON}"
    exit "${DOCKER_PS_EXIT:-0}"
    ;;
  "compose exec")
    # 最後の引数側にある実コマンドで応答を変える
    case "$*" in
      *"claude"*) exit "${DOCKER_CLAUDE_EXIT:-0}" ;;
      *"gh auth status"*) exit "${DOCKER_GH_AUTH_EXIT:-0}" ;;
      *"gh label list"*) echo "${GH_LABEL_LIST_JSON:-[]}"; exit 0 ;;
      *) exit "${DOCKER_EXEC_EXIT:-0}" ;;
    esac
    ;;
  *) exit "${DOCKER_EXIT:-0}" ;;
esac
```

Run: `chmod +x .loop/tests/fixtures/bin/docker`

- [ ] **Step 3: 失敗するテストを書く**

`.loop/tests/loop-doctor.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  use_gh_stub
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/docker"
  DOCKER_LOG="$TEST_TMP/docker.log"; export DOCKER_LOG
  # 既定は「全部健全」
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"},{"name":"needs-human"},{"name":"loop:auto-merge"}]'
  export GH_LABEL_LIST_JSON
  DOCKER_PS_JSON='[{"Service":"loop","State":"running"}]'; export DOCKER_PS_JSON
  printf '[project]\ntest = "make test"\nlint = "make lint"\n\n[agents.claude]\nextra_tools = ["Bash(make:*)"]\n' \
    > "$LOOP_DIR/config.toml"
}

teardown() { cleanup_test_repo; rm -rf "$TMP"; }

@test "全部健全なら終了コード 0" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NG"* ]]
}

@test "ラベルが欠けていたら NG になり終了コード 1" {
  GH_LABEL_LIST_JSON='[{"name":"loop:ready"}]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NG"* ]]
  [[ "$output" == *"needs-human"* ]]
}

@test "test が設定済みで extra_tools が空なら NG" {
  printf '[project]\ntest = "make test"\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra_tools"* ]]
}

@test "test も lint も空なら extra_tools が空でも OK" {
  printf '[project]\ntest = ""\nlint = ""\n\n[agents.claude]\nextra_tools = []\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}

@test "config.toml が壊れていたら NG" {
  printf 'これは TOML ではない [[[\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
}

@test "コンテナが動いていなければ NG、認証は SKIP になる" {
  DOCKER_PS_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
}

@test "SKIP は失敗として数えない（コンテナ OK・他は全部健全なら 0）" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 0 ]
}

@test "claude の認証が切れていたら NG" {
  DOCKER_CLAUDE_EXIT=1 run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude"* ]]
}

@test "所有者のいない検証用 worktree を検出する" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify-pr-9"* ]]
}

@test "生きた所有者のいる worktree は残骸として報告しない" {
  git -C "$REPO_ROOT" worktree add --detach -q "$TEST_TMP/repo-verify-pr-9" main
  printf '%s\n' "$$" > "$REPO_ROOT/loops/.wt-owner-verify-pr-9"
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" != *"verify-pr-9"* ]]
}

@test "cron の発火時刻を報告する" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  [[ "$output" == *"1,3,5"* ]]
}

@test "--quiet は失敗した項目だけを出す" {
  GH_LABEL_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/loop-doctor" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK"* ]]
  [[ "$output" == *"NG"* ]]
}

@test "--quiet で全部健全なら無出力・終了コード 0" {
  run "$LOOP_REAL_DIR/bin/loop-doctor" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "各行は OK / NG / SKIP のいずれかで始まる" {
  run "$LOOP_REAL_DIR/bin/loop-doctor"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == OK* || "$line" == NG* || "$line" == SKIP* ]]
  done <<< "$output"
}
```

- [ ] **Step 4: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/loop-doctor.bats`
Expected: FAIL（`bin/loop-doctor` が存在しない）

- [ ] **Step 5: `.loop/bin/loop-doctor` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# ハーネスの健全性を検査する。設定の崩れは静かに起きるので、いつでも叩けるようにする。
# 用法: loop-doctor [--quiet]
#   終了コード 0 = 全項目合格 / 1 = 1 件以上の失敗
#   SKIP は失敗として数えない（確認できないことと壊れていることは違う）
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

FAILED=0
COMPOSE=(docker compose -f docker/compose.yml)

emit() { # $1 = OK|NG|SKIP, $2 = 検査名, $3 = 補足
  case "$1" in
    NG) FAILED=$((FAILED + 1)) ;;
  esac
  if [ "$QUIET" = 1 ] && [ "$1" != "NG" ]; then return 0; fi
  printf '%-4s %s: %s\n' "$1" "$2" "$3"
}

# --- 1. config 構文 -------------------------------------------------------
if "$BIN_DIR/loop-config" dump >/dev/null 2>&1; then
  emit OK "config 構文" "$LOOP_DIR/config.toml は妥当"
else
  emit NG "config 構文" "${LOOP_DIR}/config.toml を読めない。TOML の構文を確認する"
fi

# --- 2. [project] と extra_tools の対応 ------------------------------------
# ここが崩れると Verifier がテストを実行せず diff だけでレビューする
P_TEST="$(cfg project.test || echo '')"
P_LINT="$(cfg project.lint || echo '')"
N_TOOLS="$("$BIN_DIR/loop-config" get agents.claude.extra_tools 2>/dev/null | grep -c . || true)"
if [ -z "$P_TEST" ] && [ -z "$P_LINT" ]; then
  emit OK "project/tools 対応" "test も lint も未設定（ループはテストを実行しない）"
elif [ "$N_TOOLS" -gt 0 ]; then
  emit OK "project/tools 対応" "extra_tools が ${N_TOOLS} 件"
else
  emit NG "project/tools 対応" \
    "[project] に test/lint があるのに extra_tools が空。Verifier がテストを実行できない"
fi

# --- 3. cron 発火時刻 -----------------------------------------------------
CRON_LINE="$("$BIN_DIR/gen-crontab" 2>/dev/null)"
if [ -n "$CRON_LINE" ]; then
  emit OK "cron 発火時刻" "$(printf '%s' "$CRON_LINE" | awk '{print $2}') 時"
else
  emit NG "cron 発火時刻" "gen-crontab が行を出せない"
fi

# --- 4. worktree 残骸 -----------------------------------------------------
STALE=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*"-verify-pr-"*)
      WT="${line#worktree }"
      KEY="verify-pr-${WT##*-verify-pr-}"
      OWNER_FILE="$REPO_ROOT/loops/.wt-owner-$KEY"
      OWNER=""
      [ -f "$OWNER_FILE" ] && OWNER="$(cat "$OWNER_FILE" 2>/dev/null)"
      if [ -z "$OWNER" ] || ! kill -0 "$OWNER" 2>/dev/null; then
        STALE="$STALE $KEY"
      fi
      ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
if [ -z "$STALE" ]; then
  emit OK "worktree 残骸" "なし"
else
  emit NG "worktree 残骸" "所有者のいない検証用 worktree:${STALE}（その PR の検証が止まる）"
fi

# --- 5. コンテナ稼働 ------------------------------------------------------
CONTAINER_UP=0
PS_JSON="$("${COMPOSE[@]}" ps --format json 2>/dev/null)"
if printf '%s' "$PS_JSON" | grep -q 'running'; then
  CONTAINER_UP=1
  emit OK "コンテナ稼働" "loop サービスが running"
else
  emit NG "コンテナ稼働" "loop サービスが動いていない。docker compose -f docker/compose.yml up -d"
fi

# --- 6/7/8. コンテナの中を見る検査 -----------------------------------------
if [ "$CONTAINER_UP" = 0 ]; then
  emit SKIP "claude 認証" "コンテナが動いていないので確認できない"
  emit SKIP "gh 認証" "コンテナが動いていないので確認できない"
  emit SKIP "ラベル" "コンテナが動いていないので確認できない"
else
  if "${COMPOSE[@]}" exec -T loop claude --version >/dev/null 2>&1; then
    emit OK "claude 認証" "コンテナ内で利用できる"
  else
    emit NG "claude 認証" "コンテナ内の claude が使えない。docker compose -f docker/compose.yml exec loop claude"
  fi

  GH_OK=0
  if "${COMPOSE[@]}" exec -T loop gh auth status >/dev/null 2>&1; then
    GH_OK=1
    emit OK "gh 認証" "コンテナ内で認証済み"
  else
    emit NG "gh 認証" "コンテナ内の gh が未認証。docker compose -f docker/compose.yml exec loop gh auth login"
  fi

  if [ "$GH_OK" = 0 ]; then
    emit SKIP "ラベル" "gh が未認証なので確認できない"
  else
    LABELS="$("${COMPOSE[@]}" exec -T loop gh label list --json name 2>/dev/null)"
    MISSING=""
    for L in loop:ready needs-human loop:auto-merge; do
      printf '%s' "$LABELS" | grep -q "\"$L\"" || MISSING="$MISSING $L"
    done
    if [ -z "$MISSING" ]; then
      emit OK "ラベル" "3 つとも存在する"
    else
      emit NG "ラベル" "不足:${MISSING}（キューもエスカレーションも黙って機能しない）"
    fi
  fi
fi

[ "$FAILED" -eq 0 ] && exit 0
exit 1
```

Run: `chmod +x .loop/bin/loop-doctor`

- [ ] **Step 6: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/loop-doctor.bats`
Expected: 14 tests, all PASS

- [ ] **Step 7: 全テストを実行する**

Run: `cd .loop && npx bats tests/`
Expected: 224 + 14 = 238 tests, all PASS

- [ ] **Step 8: コミット**

```bash
git add .loop/bin/loop-doctor .loop/tests/loop-doctor.bats \
        .loop/tests/fixtures/bin/gh .loop/tests/fixtures/bin/docker
git commit -m "feat(doctor): ハーネスの健全性を検査する loop-doctor を追加"
```

---

### Task 3: `/loop-doctor` スキルと `/loop-mtg` への組み込み

**Files:**
- Create: `.claude/skills/loop-doctor/SKILL.md`
- Modify: `.claude/skills/loop-mtg/SKILL.md`（①の冒頭に doctor を足す）
- Modify: `.claude/settings.json`（`.loop/bin/loop-doctor` の許可）

**Interfaces:**
- Consumes: `.loop/bin/loop-doctor`（Task 2）
- Produces: `/loop-doctor` が呼べる。`/loop-mtg` の①が毎朝 doctor を実行する

**この Task は散文が成果物。** コードは書かない。書いた内容がコードの実態と一致していることは Task 5 のテストが機械的に検証する。

- [ ] **Step 1: `.claude/skills/loop-doctor/SKILL.md` を書く**

```markdown
---
name: loop-doctor
description: ハーネスの健全性を検査する読み取り専用スキル。ラベル欠落・認証切れ・設定の不整合・worktree の残骸など、放っておくと静かに壊れる箇所をまとめて確認する。「/loop-doctor」「ループの調子を見て」「セットアップ壊れてない?」が合図
---

# /loop-doctor — ハーネスの健全性チェック

**読み取り専用。** 設定の変更・ラベルの付け外し・commit は一切しない。
直すのは人間か `/loop-setup` の仕事。

## やること

`.loop/bin/loop-doctor` を実行し、結果を人間向けに整理して報告する。

```
.loop/bin/loop-doctor
```

各行は `OK` / `NG` / `SKIP` のいずれかで始まる。

- **OK** — 検査に合格した
- **NG** — 壊れている。**放置すると静かに機能が失われる**
- **SKIP** — 確認できなかった（例: コンテナが動いていないので中を見られない）。
  失敗ではない

終了コードは 0（全合格）か 1（1 件以上の NG）。

## 報告のしかた

1. まず 1 行で総括する（「全項目 OK です」「NG が 2 件あります」）
2. NG があれば、**それぞれについて「放置すると何が起きるか」を添える**
   単に「ラベルがありません」ではなく「ラベルが無いと待ち行列も
   エスカレーションもエラーを出さずに機能しません」と伝える
3. 直し方を具体的なコマンドで示す。`loop-doctor` の出力に含まれているものを使う
4. SKIP は最後にまとめて 1 行で触れる。NG と混ぜない

## 直し方の対応表

| NG の項目 | 直し方 |
|---|---|
| config 構文 | `.loop/config.toml` の TOML 構文を直す |
| project/tools 対応 | `.loop/config.toml` の `[agents.claude] extra_tools` に、`[project]` の test/lint を実行できるツールを足す |
| cron 発火時刻 | `.loop/config.toml` の `[schedule]` を確認する |
| worktree 残骸 | `git worktree remove --force <path>` |
| コンテナ稼働 | `docker compose -f docker/compose.yml up -d` |
| claude 認証 | `docker compose -f docker/compose.yml exec loop claude` |
| gh 認証 | `docker compose -f docker/compose.yml exec loop gh auth login` |
| ラベル | `/loop-setup` を再実行する（冪等なので安全） |

## 禁止

- 検査結果を要約しすぎて NG を埋もれさせること
- 自分で設定を直すこと（読み取り専用）
- `loop-doctor` を実行せずに「たぶん大丈夫です」と答えること
```

- [ ] **Step 2: `/loop-mtg` の①に doctor を足す**

`.claude/skills/loop-mtg/SKILL.md` の `## ① 前回の結果を見る（必須・飛ばさない）` の
直後、「自分で調べる:」の行の **前** に挿入する:

```markdown
まず `.loop/bin/loop-doctor` を実行する。NG があれば、その日の作業に入る前に
報告する（設定が壊れたままループを回しても、静かに空回りするだけになる）。
SKIP は失敗ではないので、NG と混ぜて報告しない。
```

- [ ] **Step 3: `.claude/settings.json` に許可を足す**

`permissions.allow` の配列に追加する:

```
"Bash(.loop/bin/loop-doctor:*)"
```

既存の `.loop/bin/*` の許可と同じ形にすること。`ls` / `grep` / `wc` は
Claude Code の組み込み読み取り専用 allowlist にあるので追加不要
（`tr` は組み込みではないので既に個別に入っている）。

- [ ] **Step 4: フロントマターを検証する**

Run:

```bash
node -e '
  const fs=require("fs");
  const dir=".claude/skills/loop-doctor";
  const t=fs.readFileSync(dir+"/SKILL.md","utf8");
  const m=/^---\n([\s\S]*?)\n---/.exec(t);
  if(!m) throw new Error("フロントマターがない");
  const name=/^name:\s*(.+)$/m.exec(m[1])[1].trim();
  if(name!=="loop-doctor") throw new Error("name がディレクトリ名と不一致: "+name);
  if(!/^description:\s*/m.test(m[1])) throw new Error("description がない");
  console.log("loop-doctor OK");
'
```

Expected: `loop-doctor OK`

- [ ] **Step 5: 全テストを実行する**

Run: `cd .loop && npx bats tests/`
Expected: 238 tests, all PASS（この Task はコードを変えないので件数は変わらない）

- [ ] **Step 6: コミット**

```bash
git add .claude/skills/loop-doctor .claude/skills/loop-mtg/SKILL.md .claude/settings.json
git commit -m "feat(skills): /loop-doctor を追加し、/loop-mtg の①に組み込む"
```

---

### Task 4: `/loop-setup` スキル

**Files:**
- Create: `.claude/skills/loop-setup/SKILL.md`
- Modify: `.claude/settings.json`（`detect-project` の許可）

**Interfaces:**
- Consumes: `.loop/bin/detect-project`（Task 1）、`.loop/bin/loop-doctor`（Task 2）
- Produces: `/loop-setup` が呼べる

**このスキルはホストの `claude` セッションで走る。** コンテナの中ではない。
コンテナ内で走らせると、セットアップが用意するはずの「コンテナ内 `claude` の認証」を
前提にしてしまい循環する。

- [ ] **Step 1: `.claude/skills/loop-setup/SKILL.md` を書く**

```markdown
---
name: loop-setup
description: dev-loop テンプレートをクローンした直後の対話セットアップ。前提確認 → プロジェクト検出 → config 生成 → Dockerfile 提案 → ラベル作成 → 起動 → 認証 → 健全性チェックまでを 1 本で通す。「/loop-setup」「セットアップして」「初期設定」が合図
---

# /loop-setup — 初回セットアップ

**ホストのターミナルで実行する。** コンテナの中ではない。

このスキルの目的は 2 つある。ユーザーの手間を減らすことと、
**設定の不整合が品質を静かに殺すのを防ぐこと**。後者のほうが重い。

## 進行ルール

1. 各ステップは「既に済んでいるか」を先に確認し、済んでいれば飛ばして次へ進む
   （**冪等**。途中で失敗しても、もう一度 `/loop-setup` を叩けば続きから進む）
2. ユーザーに聞くのは決めだけ。調べられることは自分で調べる
3. 破壊的な変更の前には必ず確認を取る（特に `docker/Dockerfile` の追記）
4. 途中で失敗したら、そこで止めて理由と次の手を示す。黙って先に進まない

## ① 前提の確認

`docker` / `git` があるか確認する。`gh` は無くてもよい（⑤でコンテナ経由に切り替える）。

無いものがあれば、入れ方を示して**そこで止める**。

## ② プロジェクトの検出

```
.loop/bin/detect-project
```

TOML 断片が返る。冒頭のコメントに検出元が書いてある。

これをユーザーに見せて確認を取る。**「これでいいですか」ではなく
「こう検出しました。違っていれば教えてください」**の形で聞く。

`test` と `lint` が両方空だった場合は、テストを持たないプロジェクトなのか、
検出に失敗しただけなのかを聞く。**空のまま進めてよい**（その場合ループは
テストを実行しないが、それは正しい設定でありうる）。

## ③ config.toml の生成

`.loop/config.toml` に②の結果を反映する。

**既存の値を尊重し、差分だけ当てる。** このファイルはユーザー所有
（テンプレート同期で触られない）なので、上書きしてはいけない。
既に値が入っているキーは、変更前に確認を取る。

`maturity` は `L1` にする（数回観察してから昇格する、という運用のため）。
既に `L2` / `L3` が設定されていれば触らない。

**`[project]` の test/lint と `[agents.claude] extra_tools` は必ずセットで書く。**
片方だけの状態で先に進んではいけない。②の検出結果は既に対応が取れている。

## ④ Dockerfile の提案

②で検出したツールチェーンが `docker/Dockerfile` に無ければ、追記すべき行を
**提示して承認を取る**。承認なしに書き換えない。

追記はマーカーで囲む:

```dockerfile
# >>> loop-setup: プロジェクトのツールチェーン
RUN corepack enable && corepack prepare pnpm@latest --activate
# <<< loop-setup
```

既にマーカーがあれば、その中身を置き換える（マーカー外は触らない）。

## ⑤ ラベルの作成

ループが動くのに必要な 3 つを作る。**これが無いと待ち行列も
エスカレーションもエラーを出さずに機能しない。**

ホストに `gh` があり認証済みならホストで、無ければ⑥のあとコンテナ経由で実行する。

```bash
gh label create loop:ready      --color 0E8A16 --description "ゲート通過済み。次の firing で着手する" --force
gh label create needs-human     --color D93F0B --description "人間の判断が要る。ループは触らない"      --force
gh label create loop:auto-merge --color 1D76DB --description "L3 で自動 merge を許可する（人間が付ける）" --force
```

`--force` を付けているので何度実行しても安全。

## ⑥ ビルドと起動

**必ずリポジトリのルートから実行する。** `docker/compose.yml` は `${PWD}` で
ホストと同じ絶対パスにマウントするため、`docker/` の中から叩くとマウント先がズレる。

```bash
docker compose -f docker/compose.yml up -d --build
```

## ⑦ 認証（ユーザーの手作業）

ここだけは人間がブラウザで認可する必要がある。コマンドを提示して、
**終わったら教えてもらう**。勝手に次へ進まない。

```bash
docker compose -f docker/compose.yml exec loop claude
docker compose -f docker/compose.yml exec loop gh auth login
```

認証情報は名前付き volume に保存されるので、コンテナを作り直さない限り
2 回目以降は不要だと伝える。

## ⑧ 健全性チェック

```
.loop/bin/loop-doctor
```

全項目の合否を見せて終わる。NG があれば直し方を示す。

最後に次の一歩を 1 行で伝える: **「明日から毎日 `/loop-mtg` を実行してください」**。

## 禁止

- 承認なしに `docker/Dockerfile` を書き換えること
- `.loop/config.toml` を丸ごと上書きすること
- `[project]` を設定して `extra_tools` を空のまま先に進むこと
- 認証が終わったことを確認せずに⑧へ進むこと
- 失敗を黙って飛ばして「完了しました」と報告すること
```

- [ ] **Step 2: `.claude/settings.json` に許可を足す**

`permissions.allow` の配列に追加する:

```
"Bash(.loop/bin/detect-project:*)"
```

- [ ] **Step 3: フロントマターを検証する**

Run:

```bash
node -e '
  const fs=require("fs");
  const dir=".claude/skills/loop-setup";
  const t=fs.readFileSync(dir+"/SKILL.md","utf8");
  const m=/^---\n([\s\S]*?)\n---/.exec(t);
  if(!m) throw new Error("フロントマターがない");
  const name=/^name:\s*(.+)$/m.exec(m[1])[1].trim();
  if(name!=="loop-setup") throw new Error("name がディレクトリ名と不一致: "+name);
  console.log("loop-setup OK");
'
```

Expected: `loop-setup OK`

- [ ] **Step 4: 全テストを実行する**

Run: `cd .loop && npx bats tests/`
Expected: 238 tests, all PASS

- [ ] **Step 5: コミット**

```bash
git add .claude/skills/loop-setup .claude/settings.json
git commit -m "feat(skills): 初回セットアップの /loop-setup を追加"
```

---

### Task 5: README の差し替えと、スキル参照の機械的照合

**Files:**
- Modify: `README.md`（手順を `/loop-setup` に置き換える）
- Create: `.loop/tests/skill-references.bats`

**Interfaces:**
- Consumes: 全スキル（Task 3, 4 と既存の `loop-mtg` / `loop-status`）
- Produces: スキルの散文がコードの実態とズレていないことを機械的に保証するテスト

**この Task が P2 で一番重要。** P1 で最も高くついたのは「散文が語る内容と
コードの実態がズレる」種類のバグで、213 件のテストが 1 件も捕まえられなかった。
具体的には、Verifier のプロンプトが許可リスト外のコマンドを指示していた件と、
`/loop-status` の集計式が `firing` の集計と食い違っていた件。
**どちらも人間が目視で見つけた。** 今回は仕組みにする。

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/skill-references.bats`:

```bash
#!/usr/bin/env bats
# スキル（散文）が参照しているコマンド・パス・設定キーが、
# 実際のコードに存在することを機械的に照合する。
#
# P1 では、プロンプトが許可リスト外のコマンドを指示していた件と、
# /loop-status の集計式が firing とズレていた件を、どちらもテストが
# 捕まえられなかった。散文はテストされないという構造的な穴を塞ぐ。

load helpers

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

skill_files() {
  find "$REPO/.claude/skills" -name SKILL.md
}

@test "全スキルのフロントマターに name と description があり、name がディレクトリ名と一致する" {
  while IFS= read -r f; do
    dir="$(basename "$(dirname "$f")")"
    run node -e '
      const fs=require("fs");
      const [file,dir]=process.argv.slice(1);
      const t=fs.readFileSync(file,"utf8");
      const m=/^---\n([\s\S]*?)\n---/.exec(t);
      if(!m) throw new Error(dir+": フロントマターがない");
      if(!/^description:\s*\S/m.test(m[1])) throw new Error(dir+": description がない");
      const n=/^name:\s*(.+)$/m.exec(m[1]);
      if(!n) throw new Error(dir+": name がない");
      if(n[1].trim()!==dir) throw new Error(dir+": name 不一致 "+n[1].trim());
    ' "$f" "$dir"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done < <(skill_files)
}

@test "スキルが参照する .loop/bin のコマンドがすべて実在し、実行可能である" {
  MISSING=""
  while IFS= read -r cmd; do
    [ -x "$REPO/$cmd" ] || MISSING="$MISSING $cmd"
  done < <(skill_files | xargs grep -ohE '\.loop/bin/[a-z-]+' | sort -u)
  [ -z "$MISSING" ] || { echo "実在しない、または実行権限がない:$MISSING"; false; }
}

@test "スキルが参照する loop-config のキーがすべて defaults.toml に存在する" {
  MISSING=""
  while IFS= read -r key; do
    "$REPO/.loop/bin/loop-config" get "$key" >/dev/null 2>&1 || MISSING="$MISSING $key"
  done < <(skill_files | xargs grep -ohE 'loop-config get [a-z_.]+' | awk '{print $3}' | sort -u)
  [ -z "$MISSING" ] || { echo "defaults.toml に無いキー:$MISSING"; false; }
}

@test "スキルが参照する loops/ のパスが .gitignore と矛盾しない" {
  # スキルが「読め」と言っているファイルが gitignore されていたら、
  # クローン直後には存在せず、指示が空振りする
  BAD=""
  while IFS= read -r p; do
    case "$p" in
      *"*"*) continue ;;  # glob は対象外
    esac
    if git -C "$REPO" check-ignore -q "$p" 2>/dev/null; then BAD="$BAD $p"; fi
  done < <(skill_files | xargs grep -ohE 'loops/[A-Za-z0-9_./-]+' | sort -u)
  [ -z "$BAD" ] || { echo "gitignore されているのにスキルが参照:$BAD"; false; }
}

@test "スキルが数える dispatch 数の式が firing の N_TODAY と一致する" {
  # P1 で実際にズレた箇所。firing は .retry.md を除外するが、
  # /loop-status がそれを数えていた（3 対 2 の食い違い）
  FIRING_EXPR="$(grep -oE 'ls "?loops/runs/[^|]*\| *grep -v[^|]*\| *wc -l' "$REPO/.loop/bin/firing" | head -1)"
  [ -n "$FIRING_EXPR" ]
  # スキル側に maker のログを数える式があるなら、.retry.md の除外を含むこと
  while IFS= read -r line; do
    [[ "$line" == *"retry"* ]] || { echo "retry 除外を含まない集計式: $line"; false; }
  done < <(skill_files | xargs grep -ohE 'ls loops/runs/[^`]*maker[^`]*wc -l' || true)
}

@test "プロンプトが指示する gh コマンドが、その role の許可リストに含まれている" {
  # P1 の F1 と同じ形。prompts/<role>.md が呼ぶ gh のサブコマンドが
  # agents.claude.tools_<role> に無ければ、実 provider 下で静かに失敗する
  BAD=""
  for role in maker verifier fixer; do
    P="$REPO/.loop/prompts/$role.md"
    [ -f "$P" ] || continue
    ALLOW="$("$REPO/.loop/bin/loop-config" get "agents.claude.tools_$role" 2>/dev/null)"
    while IFS= read -r c; do
      printf '%s' "$ALLOW" | grep -q "Bash($c" || BAD="$BAD [$role: $c]"
    done < <(grep -ohE 'gh [a-z]+ [a-z]+' "$P" | sort -u)
  done
  [ -z "$BAD" ] || { echo "許可リスト外のコマンドを指示:$BAD"; false; }
}
```

- [ ] **Step 2: テストを実行して、いまの実装で通ることを確認する**

Run: `cd .loop && npx bats tests/skill-references.bats`
Expected: 6 tests, all PASS

**もし落ちたら、それは実際のズレを見つけたということ。** テストを緩めずに、
落ちた側（スキルかコード）を直す。どちらを直すべきか判断がつかない場合は
報告して指示を仰ぐこと。

- [ ] **Step 3: テストが本当に効くことを確認する（ミューテーション）**

一時的にスキルへ実在しないコマンドを書き足し、テストが落ちることを確認する:

```bash
echo '実在しないコマンド: `.loop/bin/nonexistent-command`' >> .claude/skills/loop-doctor/SKILL.md
cd .loop && npx bats tests/skill-references.bats   # 落ちること
cd .. && git checkout .claude/skills/loop-doctor/SKILL.md
```

Expected: 追記した状態でテストが落ち、戻すと通る

- [ ] **Step 4: `README.md` のセットアップ節を差し替える**

現在の「コマンド 4 つ + 手編集 3 ファイル」を、`/loop-setup` を案内する形に置き換える。

置き換え後の内容:

```markdown
## セットアップ

ターミナルで `claude` を開き、次のように打ちます。

```
/loop-setup
```

これだけです。プロジェクトの検出、設定ファイルの生成、GitHub ラベルの作成、
コンテナのビルドと起動、最後の健全性チェックまでを対話で進めます。

途中 1 回だけ、ブラウザでの認可が必要な手作業があります（`claude` と
`gh` のログイン）。コマンドはスキルが提示するので、それを実行して戻ってください。
認証情報は名前付き volume に保存されるので、コンテナを作り直さない限り
2 回目以降は不要です。

`/loop-setup` は**何度実行しても安全**です。途中で失敗したら、もう一度叩けば
続きから進みます。

### うまく動かないとき

```
/loop-doctor
```

何が壊れているか、放置すると何が起きるか、どう直すかを一覧で出します。
セットアップ後に設定が崩れたとき（ラベルを消した、認証が切れた、
`config.toml` を編集して対応が崩れた）にも使えます。

### 手動でやりたい場合

`/loop-setup` が何をしているかは `.claude/skills/loop-setup/SKILL.md` に
すべて書いてあります。手で進めたい場合はそれを読んでください。
```

**旧手順のうち、以下は残す**（`/loop-setup` が失敗したときの手がかりとして
必要なため、「手動でやりたい場合」の参照先が SKILL.md であることを明記した上で削除する）:
- リポジトリのルートから実行する必要がある理由（`${PWD}` のマウント）
- `docker.sock` のセキュリティ上の注意とオプトアウト手順

これらは README の別セクション（「セキュリティ上の注意」など）に既にあるので、
セットアップ節から消しても失われない。**消す前に確認すること。**

- [ ] **Step 5: README の記述がコードと一致することを確認する**

Run:

```bash
grep -oE '\.loop/bin/[a-z-]+|/loop-[a-z]+' README.md | sort -u | while read -r r; do
  case "$r" in
    /loop-*) d=".claude/skills/${r#/}"; [ -d "$d" ] && echo "OK   $r" || echo "NG   $r" ;;
    *)       [ -x "$r" ] && echo "OK   $r" || echo "NG   $r" ;;
  esac
done
```

Expected: すべて `OK`

- [ ] **Step 6: 全テストを実行する**

Run: `cd .loop && npx bats tests/`
Expected: 238 + 6 = 244 tests, all PASS

- [ ] **Step 7: コミット**

```bash
git add README.md .loop/tests/skill-references.bats
git commit -m "feat(setup): README を /loop-setup 中心に書き換え、スキル参照の照合テストを追加"
```

---

## 自己レビューの結果

spec の各節を実装タスクに対応付けた結果:

| spec の節 | 対応するタスク |
|---|---|
| §2 達成条件 A（1 コマンド） | Task 4 |
| §2 達成条件 B（自動検出） | Task 1 |
| §2 達成条件 C（不整合の検出） | Task 1（構造的に防ぐ）+ Task 2（検査）+ Task 4（進行の禁止） |
| §2 達成条件 D（ラベル作成） | Task 4 ⑤ |
| §2 達成条件 E（完了の検証） | Task 2 + Task 4 ⑧ |
| §2 達成条件 F（冪等） | Task 4 進行ルール 1 |
| §2 達成条件 G（L1 初期値） | Task 4 ③ |
| §2 達成条件 H（いつでも検出） | Task 2 + Task 3 |
| §4 `/loop-setup` の流れ | Task 4 |
| §5 `/loop-doctor` の検査項目 | Task 2 |
| §6 ファイル構成 | Task 1〜5 |
| §7 テスト戦略の 1（検出のユニット） | Task 1 |
| §7 テスト戦略の 2（doctor の bats） | Task 2 |
| §7 テスト戦略の 3（スキルの照合） | **Task 5** |
| §8 受け入れ基準 | 各タスク + 実リポジトリでの手動確認 |

**spec との差分（意図的なもの）:**

- spec §5 のインターフェースは `loop-doctor` と `--quiet` のみだったが、
  出力形式を `OK` / `NG` / `SKIP` の 3 値に明示した。`SKIP` を失敗と区別しないと、
  コンテナ停止中に doctor が全項目 NG を出して信用されなくなる
- spec §6 のファイル構成に `detect-project-cli.mjs` と `.loop/bin/detect-project` を
  追加した。純関数と I/O を分けるという spec §3 決定 3 の方針に従うと 2 ファイルになる
- Task 5 の照合テストは spec §7 の「3」を具体化したもので、
  **既存のスキル（`loop-mtg` / `loop-status`）も検査対象に含める**

**この計画で検証できないこと（実リポジトリでの手動確認が要る）:**

- `/loop-setup` を実際に通したときの体験
- ホストに `gh` が無い場合のコンテナ経由への切り替え
- `docker compose exec` を伴う doctor の検査 6〜8（テストではスタブ）
