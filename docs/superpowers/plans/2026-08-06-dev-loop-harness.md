# dev-loop ハーネス核（P1）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub Issue を入口に Maker → Verifier → 人間の merge が自動で回る Loop Engineering テンプレートのハーネス核を、Docker 1 コンテナで常駐する形で構築する。

**Architecture:** シェルスクリプト群（`.loop/bin/`）が制御フローを持ち、設定の読み出しと構造解析だけを Node（`.loop/lib/*.mjs`）に委ねる。設定は `defaults.toml`（テンプレート所有）を `config.toml`（ユーザ所有）で上書きする 2 層。エージェント起動は `agent-run` → `.loop/agents/<provider>.sh` の 1 段のみ抽象化する。状態の背骨は git 管理下の `loops/*.md`。

**Tech Stack:** bash / Node.js 24 (ESM) / smol-toml 1.7.1 / bats-core 1.13.0 / Docker + Compose / GitHub CLI (gh) / supercronic

**Spec:** `docs/superpowers/specs/2026-08-05-dev-loop-harness-design.md`

## Global Constraints

- **bash 3.2 互換で書く。** macOS のシステム bash でテストを回すため、`mapfile` / `declare -A` / `${var^^}` / `readarray` を使わない。配列は `while IFS= read -r` + プロセス置換で組み立てる
- **すべてのシェルスクリプトは `set -uo pipefail` で始める。** `set -e` は使わない（終了コードを明示的に拾う箇所が多く、暗黙終了は誤動作の元になる）
- **Node の依存は `smol-toml` のみ。** テスト用に `bats` を devDependency に置く。`.loop/package.json` は `"type": "module"`、実行ファイルは `.mjs`
- **コードの所在と設定の所在を分ける。** シェルスクリプトは自身のパスから `LIB_DIR`（コード）を求め、設定・プロンプト・provider は `LOOP_DIR`（環境変数で上書き可能、既定は `LIB_DIR/..`）から読む。これによりテストが実物のコードで fixture の設定を使える
- **`REPO_ROOT` も環境変数で上書き可能にする**（既定は `LIB_DIR/../..`）。テストが一時 git リポジトリを対象にできる
- **ユーザ向けメッセージは日本語**、コード中の識別子は英語
- **対象 OS は macOS / Linux。** Windows は WSL2 の中で使う前提
- **コミットは Conventional Commits**（`feat:` / `fix:` / `test:` / `docs:` / `chore:`）
- **テスト実行は `cd .loop && npx bats tests/`**
- **bats の `setup()` は `.loop/tests/helpers.bash` の共通関数を呼ぶ。** 各タスクの
  テストコードは `setup()` を展開した形で書かれているが、実装時は
  `make_test_repo "$TMP"` / `use_mock_agent` / `use_gh_stub` / `use_ccusage_stub <name>` に
  置き換えること（Task 1 で定義済み。挙動は同一）。`teardown()` は
  `cleanup_test_repo; rm -rf "$TMP"` とする
- **`dispatch-maker` / `dispatch-verifier` / `dispatch-fixer` は 3 本の独立したスクリプトとして書く。**
  三者は worktree の扱いが本質的に異なる（新規作成 / detached checkout して必ず削除 /
  既存を再利用）ため、共通化すると分岐だらけの関数になる。表層的な行の重複よりも
  各スクリプトが単体で読めることを優先する、という設計判断（2026-08-06 に決定）

## File Structure

```
dev-loop/                              ← このテンプレートリポジトリ自身
├── .claude/
│   ├── settings.json          [S] superpowers 宣言・権限
│   └── skills/
│       ├── loop-mtg/SKILL.md  [T] 毎日のミーティング
│       └── loop-status/SKILL.md [T] キューの現在地（読み取り専用）
├── .loop/
│   ├── package.json           [T] smol-toml / bats
│   ├── defaults.toml          [T] 全キー + 説明コメント
│   ├── config.toml            [S] ユーザが触る唯一の設定
│   ├── OWNERSHIP.toml         [T] 同期の所有境界
│   ├── VERSION                [T] テンプレートのバージョン
│   ├── lib/
│   │   ├── common.sh          [T] シェル共通ヘルパー
│   │   ├── config.mjs         [T] TOML 2 層マージ（純関数）
│   │   ├── config-cli.mjs     [T] loop-config の実体
│   │   ├── gate.mjs           [T] Issue 構造検証（純関数）
│   │   ├── gate-cli.mjs       [T] loop-gate の実体
│   │   └── sum-usage.mjs      [T] ccusage 出力の集計
│   ├── bin/                   [T] loop-config, loop-gate, agent-run, budget-check,
│   │                              cleanup-merged, dispatch-maker, dispatch-verifier,
│   │                              dispatch-fixer, firing, preview, gen-crontab
│   ├── agents/claude.sh       [T] provider 実装
│   ├── prompts/               [T] maker.md, verifier.md, fixer.md
│   ├── skills/                [T] run-a-loop.md, maker-workflow.md, verifier-workflow.md
│   └── tests/                 [T] *.bats, helpers.bash, fixtures/
├── loops/                     [U] STATE.md, DECISIONS.md, INCIDENTS.md, mtg/, runs/
├── docker/                    Dockerfile [S] / compose.yml [T] / entrypoint.sh [T]
├── docs/                      [U]
├── CLAUDE.md                  [S]
├── README.md                  [T]
└── .gitignore                 [T]
```

責務の分割方針: **制御フローはシェル、構造解析は Node、判定ロジックは純関数。** `gate.mjs` と `config.mjs` は I/O を持たない純関数にし、`*-cli.mjs` が I/O を担う。これにより判定ロジックが GitHub なしでテストできる。

---

### Task 1: リポジトリ骨格と設定 2 層（`loop-config`）

**Files:**
- Create: `.gitignore`
- Create: `.loop/package.json`
- Create: `.loop/defaults.toml`
- Create: `.loop/config.toml`
- Create: `.loop/lib/config.mjs`
- Create: `.loop/lib/config-cli.mjs`
- Create: `.loop/bin/loop-config`
- Test: `.loop/tests/helpers.bash`, `.loop/tests/loop-config.bats`

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces:
  - `loop-config get <dotted.key>` → 値を 1 行で標準出力、未定義なら終了コード 1 で無出力。配列は改行区切り、真偽値は `true` / `false`
  - `loop-config dump` → マージ結果を JSON で標準出力
  - 環境変数 `LOOP_DIR` で設定ディレクトリを差し替え可能
  - `.loop/lib/config.mjs` が `loadConfig(loopDir)` / `getKey(cfg, dotted)` / `formatValue(v)` を export

- [ ] **Step 1: `.loop/package.json` と依存をインストールする**

```json
{
  "name": "dev-loop-harness",
  "private": true,
  "type": "module",
  "dependencies": {
    "smol-toml": "1.7.1"
  },
  "devDependencies": {
    "bats": "1.13.0"
  }
}
```

Run: `cd .loop && npm install`

- [ ] **Step 2: `.gitignore` を書く**

```gitignore
node_modules/
.loop/.preview.pid
loops/runs/*.log
.DS_Store
```

- [ ] **Step 3: 失敗するテストを書く**

`.loop/tests/helpers.bash`:

```bash
# bats から source される共通ヘルパー。
# 全 bats ファイルの setup() はここの関数を呼ぶ（各ファイルに書き下さない）。
LOOP_REAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LOOP_REAL_DIR

# fixture 用の LOOP_DIR を作る。defaults.toml は実物をコピーし、
# config.toml は呼び出し側が書き込む。コード(lib/bin)は実物を使う
make_loop_dir() {
  local dest="$1"
  mkdir -p "$dest/agents" "$dest/prompts"
  cp "$LOOP_REAL_DIR/defaults.toml" "$dest/defaults.toml"
  : > "$dest/config.toml"
  echo "$dest"
}

# 一時 git リポジトリを作り、REPO_ROOT / LOOP_DIR / TEST_TMP を export する。
# $1 = 一時ディレクトリ（呼び出し側が mktemp -d して teardown で消す）
make_test_repo() {
  TEST_TMP="$1"; export TEST_TMP
  REPO_ROOT="$1/repo"; export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs" "$REPO_ROOT/loops/mtg"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"; export LOOP_DIR
  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
}

# mock provider を有効にし、実物のプロンプトを fixture にコピーする。
# config.toml を provider=mock + [project] コマンド付きで上書きする
use_mock_agent() {
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/" 2>/dev/null || true
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"
}

# gh スタブを PATH の先頭に置き、呼び出しログを GH_LOG に貯める
use_gh_stub() {
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"; export PATH
  GH_LOG="$TEST_TMP/gh.log"; export GH_LOG
}

# ccusage スタブを差し込む。$1 = ok | over | garbage | fail
use_ccusage_stub() {
  chmod +x "$BATS_TEST_DIRNAME/fixtures/ccusage/$1.sh"
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/$1.sh"; export LOOP_CCUSAGE_CMD
}

# teardown から呼ぶ。worktree の登録を消してから一時ディレクトリを消す
cleanup_test_repo() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
}
```

**注意:** `make_test_repo` 以降の 4 関数は、Task 6 以降のテストが使うものです。
Task 1 の時点では `make_loop_dir` しか使いませんが、後続タスクが各 bats ファイルに
setup() を書き下さずに済むよう、ここでまとめて定義しておきます。
`use_mock_agent` / `use_ccusage_stub` が参照する fixture は Task 4・Task 5 で作られるため、
Task 1 の時点では未使用のまま置かれます。

`.loop/tests/loop-config.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
}

teardown() { rm -rf "$TMP"; }

@test "defaults の値を返す" {
  run "$LOOP_REAL_DIR/bin/loop-config" get models.maker
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-5" ]
}

@test "config.toml が defaults を上書きする" {
  printf '[models]\nmaker = "claude-opus-5"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-config" get models.maker
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-5" ]
}

@test "テーブルは深くマージされ、上書きしていないキーは defaults のまま" {
  printf '[models]\nmaker = "claude-opus-5"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-config" get models.verifier
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-5" ]
}

@test "トップレベルのキーを取れる" {
  run "$LOOP_REAL_DIR/bin/loop-config" get maturity
  [ "$status" -eq 0 ]
  [ "$output" = "L2" ]
}

@test "真偽値は true/false になる" {
  run "$LOOP_REAL_DIR/bin/loop-config" get mtg.voice
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "配列は改行区切りになる" {
  run "$LOOP_REAL_DIR/bin/loop-config" get gate.required_sections
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## 背景" ]
  [ "${lines[4]}" = "## 依存" ]
}

@test "未定義のキーは終了コード 1 で無出力" {
  run "$LOOP_REAL_DIR/bin/loop-config" get nope.nothing
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "dump は妥当な JSON を返す" {
  run "$LOOP_REAL_DIR/bin/loop-config" dump
  [ "$status" -eq 0 ]
  echo "$output" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s))'
}
```

- [ ] **Step 4: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/loop-config.bats`
Expected: FAIL（`defaults.toml` も `bin/loop-config` も存在しないため、全ケースが失敗する）

- [ ] **Step 5: `.loop/defaults.toml` を書く**

```toml
# dev-loop ハーネスの既定値。このファイルはテンプレート所有。
# テンプレート同期のたびに丸ごと上書きされる。
# 変えたい値は .loop/config.toml に書く（同期で触られない）。

# L1 = 判定と報告だけ。dispatch しない
# L2 = Maker → PR → Verifier まで自動。merge は人間（既定）
# L3 = Verifier approve かつ loop.auto_merge_label が付いていれば自動 merge
maturity = "L2"

[agent]
# .loop/agents/<provider>.sh を呼ぶ
provider = "claude"

[models]
maker = "claude-sonnet-5"
verifier = "claude-sonnet-5"
fixer = "claude-sonnet-5"

[turns]
# 1 回の実行の最大ターン数。粒度ゲート(gate.max_files_touched)をすり抜けた
# ときの最後の砦であり、日常的に触るダイヤルではない
maker = 120
verifier = 30
fixer = 60

[budget]
# 1 日のトークン上限。超えたら firing は dispatch しない（fail-closed）
daily_tokens = 120000000

[schedule]
# start_hour を起点に 24/firings_per_day 時間おきに発火する
firings_per_day = 12
start_hour = 1
timezone = "Asia/Tokyo"

[loop]
max_open_prs = 4
max_dispatch_per_day = 10
# Verifier の request-changes 後に Fixer が再修正する回数の上限（0 で無効）
auto_fix_rounds = 1
# L3 で自動 merge を許可する Issue ラベル
auto_merge_label = "loop:auto-merge"

[retry]
# 一過性エラー（DNS/接続系）を検知したときのリトライ待ち秒数
delay_seconds = 600

[gate]
required_sections = ["## 背景", "## 受け入れ基準", "## 実装方針", "## スコープ外", "## 依存"]
max_files_touched = 8
max_acceptance_criteria = 6

[project]
# このプロジェクト固有のコマンド。config.toml で必ず設定する
test = "echo 'project.test が未設定です' && false"
lint = "echo 'project.lint が未設定です' && false"
preview = ""
preview_port = 3000

[mtg]
# VOICEVOX による読み上げ（opt-in）
voice = false
voice_speaker_id = 29

[agents.claude]
tools_maker = [
  "Read", "Glob", "Grep", "Edit", "Write",
  "Bash(git:*)", "Bash(gh issue view:*)", "Bash(gh issue comment:*)",
  "Bash(gh issue edit:*)", "Bash(gh pr create:*)"
]
tools_verifier = [
  "Read", "Glob", "Grep",
  "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr review:*)",
  "Bash(gh pr edit:*)", "Bash(gh pr comment:*)", "Bash(gh issue view:*)",
  "Bash(git log:*)", "Bash(git diff:*)"
]
tools_fixer = [
  "Read", "Glob", "Grep", "Edit", "Write",
  "Bash(git:*)", "Bash(gh pr view:*)", "Bash(gh pr diff:*)",
  "Bash(gh pr comment:*)", "Bash(gh issue view:*)"
]
# プロジェクトのビルド/テストコマンドは config.toml でここに足す
# 例: extra_tools = ["Bash(pnpm:*)", "Bash(npx:*)", "Bash(node:*)"]
extra_tools = []
```

- [ ] **Step 6: `.loop/config.toml`（スターター）を書く**

```toml
# このファイルはあなたのもの。テンプレート同期で上書きされない。
# 全キーと説明は .loop/defaults.toml を見る。

maturity = "L2"

[models]
maker = "claude-sonnet-5"
verifier = "claude-sonnet-5"

[budget]
daily_tokens = 120000000

[schedule]
firings_per_day = 12
timezone = "Asia/Tokyo"

[loop]
max_open_prs = 4
max_dispatch_per_day = 10
auto_fix_rounds = 1

[gate]
max_files_touched = 8
max_acceptance_criteria = 6

# ここは必ず自分のプロジェクトに合わせて書き換える
[project]
test = "echo 'project.test を設定してください' && false"
lint = "echo 'project.lint を設定してください' && false"
preview = ""
preview_port = 3000

[mtg]
voice = false

[agents.claude]
# Maker/Verifier に許可する追加コマンド（プロジェクトのツールチェーン）
extra_tools = []
```

- [ ] **Step 7: `.loop/lib/config.mjs` を書く**

```javascript
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { parse } from 'smol-toml';

const isPlainObject = (v) =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

export function deepMerge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over)) {
    out[k] = isPlainObject(v) && isPlainObject(base[k]) ? deepMerge(base[k], v) : v;
  }
  return out;
}

export function loadConfig(loopDir) {
  const defaultsPath = join(loopDir, 'defaults.toml');
  if (!existsSync(defaultsPath)) {
    throw new Error(`defaults.toml が見つからない: ${defaultsPath}`);
  }
  const defaults = parse(readFileSync(defaultsPath, 'utf8'));
  const overridePath = join(loopDir, 'config.toml');
  const overrides = existsSync(overridePath)
    ? parse(readFileSync(overridePath, 'utf8'))
    : {};
  return deepMerge(defaults, overrides);
}

export function getKey(cfg, dotted) {
  return dotted
    .split('.')
    .reduce((o, k) => (o === null || o === undefined ? undefined : o[k]), cfg);
}

export function formatValue(v) {
  if (v === undefined || v === null) return null;
  if (Array.isArray(v)) return v.join('\n');
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return String(v);
}
```

- [ ] **Step 8: `.loop/lib/config-cli.mjs` を書く**

```javascript
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
```

- [ ] **Step 9: `.loop/bin/loop-config` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# 設定の読み出し口。defaults.toml を config.toml で上書きした結果を返す
# 用法: loop-config get <dotted.key> | loop-config dump
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOOP_DIR="${LOOP_DIR:-$(cd "$SELF_DIR/.." && pwd)}"
exec node "$SELF_DIR/../lib/config-cli.mjs" "$@"
```

Run: `chmod +x .loop/bin/loop-config`

- [ ] **Step 10: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/loop-config.bats`
Expected: 8 tests, all PASS

- [ ] **Step 11: コミット**

```bash
git add .gitignore .loop/package.json .loop/package-lock.json .loop/defaults.toml \
        .loop/config.toml .loop/lib/config.mjs .loop/lib/config-cli.mjs \
        .loop/bin/loop-config .loop/tests/helpers.bash .loop/tests/loop-config.bats
git commit -m "feat(config): defaults + overrides の 2 層設定と loop-config を追加"
```

---

### Task 2: シェル共通ヘルパー（`lib/common.sh`）

**Files:**
- Create: `.loop/lib/common.sh`
- Test: `.loop/tests/common.bats`

**Interfaces:**
- Consumes: `loop-config`（Task 1）
- Produces: 以下を定義する。すべての `.loop/bin/*` がこれを source する
  - 変数 `LIB_DIR` / `LOOP_DIR` / `REPO_ROOT`（`LOOP_DIR` と `REPO_ROOT` は環境変数で上書き可能）
  - `cfg <dotted.key>` — 設定値を返す。未定義なら終了コード 1
  - `record_state <text>` — `loops/STATE.md` の末尾に `- YYYY-MM-DD: <text>` を追記
  - `is_transient_error <logfile>` — DNS/接続系のエラーを含めば 0
  - `render_prompt <template> KEY=VALUE...` — `{{KEY}}` を置換して標準出力。`sed` を使わないので値に `/` や `&` が含まれても壊れない
  - `retry_delay` — `retry.delay_seconds` を返す

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/common.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/repo/.loop")"
  export LOOP_DIR
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  source "$LOOP_REAL_DIR/lib/common.sh"
}

teardown() { rm -rf "$TMP"; }

@test "cfg が設定値を返す" {
  run cfg maturity
  [ "$status" -eq 0 ]
  [ "$output" = "L2" ]
}

@test "cfg は未定義キーで 1 を返す" {
  run cfg nope.nothing
  [ "$status" -eq 1 ]
}

@test "record_state が STATE.md に 1 行追記する" {
  record_state "テスト行"
  run tail -1 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"テスト行"* ]]
  [[ "$output" == -* ]]
}

@test "is_transient_error が接続系エラーを検出する" {
  printf 'fetch failed ENOTFOUND api.example.com\n' > "$TMP/log"
  run is_transient_error "$TMP/log"
  [ "$status" -eq 0 ]
}

@test "is_transient_error は通常の失敗を検出しない" {
  printf 'AssertionError: expected 1 to equal 2\n' > "$TMP/log"
  run is_transient_error "$TMP/log"
  [ "$status" -ne 0 ]
}

@test "render_prompt が複数のプレースホルダを置換する" {
  printf 'Issue #{{ISSUE}} を {{TEST_CMD}} で検証する。#{{ISSUE}} 再掲。\n' > "$TMP/t.md"
  run render_prompt "$TMP/t.md" "ISSUE=42" "TEST_CMD=pnpm -r test"
  [ "$status" -eq 0 ]
  [ "$output" = "Issue #42 を pnpm -r test で検証する。#42 再掲。" ]
}

@test "render_prompt はスラッシュやアンパサンドを含む値でも壊れない" {
  printf 'cmd: {{CMD}}\n' > "$TMP/t.md"
  run render_prompt "$TMP/t.md" "CMD=cd packages/web && npm test"
  [ "$status" -eq 0 ]
  [ "$output" = "cmd: cd packages/web && npm test" ]
}

@test "retry_delay が既定値を返す" {
  run retry_delay
  [ "$status" -eq 0 ]
  [ "$output" = "600" ]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/common.bats`
Expected: FAIL（`lib/common.sh` が存在せず `source` に失敗する）

- [ ] **Step 3: `.loop/lib/common.sh` を書く**

```bash
# shellcheck shell=bash
# すべての .loop/bin/* から source される共通ヘルパー。
# コードの所在(LIB_DIR)と設定の所在(LOOP_DIR)を分けている。
# テストは実物のコードで fixture の設定を使えるように LOOP_DIR / REPO_ROOT を上書きする。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="${LOOP_DIR:-$(cd "$LIB_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$LIB_DIR/../.." && pwd)}"
export LOOP_DIR REPO_ROOT

# 設定値を 1 つ取り出す。未定義なら終了コード 1
cfg() {
  LOOP_DIR="$LOOP_DIR" "$LIB_DIR/../bin/loop-config" get "$1"
}

# loops/STATE.md の末尾に 1 行追記する
record_state() {
  printf -- '- %s: %s\n' "$(date +%Y-%m-%d)" "$1" >> "$REPO_ROOT/loops/STATE.md"
}

# 一過性エラー（DNS/接続系）の判定。$1 = 実行ログのパス
is_transient_error() {
  [ -f "$1" ] || return 1
  grep -qiE 'ENOTFOUND|ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|getaddrinfo|fetch failed' "$1"
}

retry_delay() {
  cfg retry.delay_seconds
}

# テンプレートの {{KEY}} を置換して標準出力する。
# bash のパターン置換を使うので、値に / & \ が含まれても壊れない（sed との違い）
render_prompt() {
  local tpl="$1"; shift
  local out pair k v
  out="$(cat "$tpl")"
  for pair in "$@"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    out="${out//\{\{$k\}\}/$v}"
  done
  printf '%s\n' "$out"
}
```

- [ ] **Step 4: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/common.bats`
Expected: 8 tests, all PASS

- [ ] **Step 5: コミット**

```bash
git add .loop/lib/common.sh .loop/tests/common.bats
git commit -m "feat(lib): シェル共通ヘルパー common.sh を追加"
```

---

### Task 3: Issue 品質ゲート（`loop-gate`）

**Files:**
- Create: `.loop/lib/gate.mjs`
- Create: `.loop/lib/gate-cli.mjs`
- Create: `.loop/bin/loop-gate`
- Test: `.loop/tests/loop-gate.bats`, `.loop/tests/fixtures/issues/*.md`

**Interfaces:**
- Consumes: `loadConfig` / `getKey`（Task 1 の `config.mjs`）
- Produces:
  - `gate.mjs`: `splitSections(body)` → `Map<string, string[]>`、`extractDepRefs(body)` → `string[]`、`checkIssue({body, config, depStates})` → `{ok: boolean, violations: string[]}`
  - `loop-gate <issue-number>` — `gh` で本文と依存の状態を取得して検証。通過で `GATE OK` + 終了コード 0、不合格で違反を `- ` 付きで列挙して終了コード 1
  - `loop-gate --body-file <path> [--dep-state N=CLOSED]...` — GitHub にアクセスせず検証（テスト・オフライン用）

- [ ] **Step 1: fixture の Issue 本文を作る**

`.loop/tests/fixtures/issues/good.md`:

```markdown
## 背景
ログイン後のリダイレクト先が固定になっており、意図した画面に戻れない。

## 受け入れ基準
- [ ] `packages/web で pnpm test -- redirect` が緑
- [ ] 手動: ログイン後、直前に見ていた画面に戻る

## 実装方針
`packages/web/src/auth/redirect.ts` に戻り先の保存を追加し、
`packages/web/src/auth/LoginForm.tsx` から呼ぶ。

## スコープ外
OAuth プロバイダの追加、セッション期限の変更

## 依存
なし
```

`.loop/tests/fixtures/issues/missing-section.md`（`## スコープ外` を欠く）:

```markdown
## 背景
背景の説明。

## 受け入れ基準
- [ ] `packages/web で pnpm test` が緑

## 実装方針
`packages/web/src/a.ts` を変更する。

## 依存
なし
```

`.loop/tests/fixtures/issues/no-command.md`:

```markdown
## 背景
背景の説明。

## 受け入れ基準
- [ ] ちゃんと動くこと

## 実装方針
`packages/web/src/a.ts` を変更する。

## スコープ外
なし

## 依存
なし
```

`.loop/tests/fixtures/issues/dep-open.md`:

```markdown
## 背景
背景の説明。

## 受け入れ基準
- [ ] `packages/web で pnpm test` が緑

## 実装方針
`packages/web/src/a.ts` を変更する。

## スコープ外
なし

## 依存
依存: #12
```

`.loop/tests/fixtures/issues/too-many-paths.md`:

```markdown
## 背景
背景の説明。

## 受け入れ基準
- [ ] `packages/web で pnpm test` が緑

## 実装方針
`src/a.ts` `src/b.ts` `src/c.ts` `src/d.ts` `src/e.ts`
`src/f.ts` `src/g.ts` `src/h.ts` `src/i.ts` を変更する。

## スコープ外
なし

## 依存
なし
```

`.loop/tests/fixtures/issues/no-path.md`:

```markdown
## 背景
背景の説明。

## 受け入れ基準
- [ ] `packages/web で pnpm test` が緑

## 実装方針
適当にいい感じに直す。

## スコープ外
なし

## 依存
なし
```

- [ ] **Step 2: 失敗するテストを書く**

`.loop/tests/loop-gate.bats`:

```bash
#!/usr/bin/env bats

load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/issues"

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
}

teardown() { rm -rf "$TMP"; }

@test "正しい Issue は通過する" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/good.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE OK"* ]]
}

@test "必須セクションが欠けていると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/missing-section.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"## スコープ外"* ]]
}

@test "検証コマンドのない受け入れ基準は落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/no-command.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"検証コマンドがない"* ]]
}

@test "手動: で始まる基準は例外として許される" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/good.md"
  [ "$status" -eq 0 ]
}

@test "未 close の依存があると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/dep-open.md" --dep-state 12=OPEN
  [ "$status" -eq 1 ]
  [[ "$output" == *"#12"* ]]
}

@test "close 済みの依存なら通過する" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/dep-open.md" --dep-state 12=CLOSED
  [ "$status" -eq 0 ]
}

@test "触るパスが多すぎると落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/too-many-paths.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"多すぎる"* ]]
}

@test "実装方針にパスがないと落ちる" {
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/no-path.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"パスがない"* ]]
}

@test "gate.max_files_touched を config で緩められる" {
  printf '[gate]\nmax_files_touched = 20\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/loop-gate" --body-file "$FIX/too-many-paths.md"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/loop-gate.bats`
Expected: FAIL（`bin/loop-gate` が存在しない）

- [ ] **Step 4: `.loop/lib/gate.mjs` を書く**

```javascript
// Issue 本文の「構造」だけを検証する純関数群。
// 「受け入れ基準が本当に観察可能か」といった妥当性は検証しない（MTG で人間が見る）。

export function splitSections(body) {
  const sections = new Map();
  let current = null;
  for (const line of body.split(/\r?\n/)) {
    const m = /^##\s+(.+?)\s*$/.exec(line);
    if (m) {
      current = `## ${m[1]}`;
      sections.set(current, []);
      continue;
    }
    if (current) sections.get(current).push(line);
  }
  return sections;
}

function depBodyOf(sections) {
  const raw = (sections.get('## 依存') || []).join('\n').trim();
  return raw.replace(/^依存\s*[:：]\s*/, '').trim();
}

export function extractDepRefs(body) {
  const dep = depBodyOf(splitSections(body));
  if (dep === '' || dep === 'なし') return [];
  return [...dep.matchAll(/#(\d+)/g)].map((m) => m[1]);
}

export function checkIssue({ body, config, depStates = {} }) {
  const v = [];
  const sections = splitSections(body);

  for (const s of config.gate.required_sections) {
    if (!sections.has(s)) v.push(`必須セクションがない: ${s}`);
  }

  const acLines = sections.get('## 受け入れ基準') || [];
  const items = acLines
    .filter((l) => /^\s*-\s\[[ xX]\]/.test(l))
    .map((l) => l.replace(/^\s*-\s\[[ xX]\]\s*/, '').trim());

  if (items.length === 0) {
    v.push('受け入れ基準にチェックボックス（- [ ]）が 1 つもない');
  }
  for (const it of items) {
    if (!/`[^`]+`/.test(it) && !it.startsWith('手動:')) {
      v.push(`受け入れ基準に検証コマンドがない（コマンドで検証できないものは「手動:」で始める）: ${it}`);
    }
  }
  if (items.length > config.gate.max_acceptance_criteria) {
    v.push(`受け入れ基準が多すぎる（粒度超過）: ${items.length} > ${config.gate.max_acceptance_criteria}`);
  }

  const dep = depBodyOf(sections);
  if (sections.has('## 依存')) {
    if (dep === '') {
      v.push('依存が空。「なし」または #N を書く');
    } else if (dep !== 'なし') {
      const refs = [...dep.matchAll(/#(\d+)/g)].map((m) => m[1]);
      if (refs.length === 0) {
        v.push(`依存の書式が不正（「なし」または #N）: ${dep}`);
      }
      for (const r of refs) {
        const st = depStates[r];
        if (st !== 'CLOSED') {
          v.push(`依存 #${r} が未 close (state=${st || 'unknown'})`);
        }
      }
    }
  }

  const plan = (sections.get('## 実装方針') || []).join('\n');
  const paths = [...plan.matchAll(/`([^`]+)`/g)]
    .map((m) => m[1])
    .filter((t) => t.includes('/') || t.includes('.'));
  if (paths.length === 0) {
    v.push('実装方針に触るファイル/ディレクトリのパスがない（`path/to/file` の形で書く）');
  }
  if (paths.length > config.gate.max_files_touched) {
    v.push(`触るパスが多すぎる（粒度超過。分割する）: ${paths.length} > ${config.gate.max_files_touched}`);
  }

  return { ok: v.length === 0, violations: v };
}
```

- [ ] **Step 5: `.loop/lib/gate-cli.mjs` を書く**

```javascript
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
```

- [ ] **Step 6: `.loop/bin/loop-gate` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# Issue の構造を機械検証する。通過で 0、不合格で 1（違反を列挙）
# 用法: loop-gate <issue-number>
#       loop-gate --body-file <path> [--dep-state N=CLOSED]...
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOOP_DIR="${LOOP_DIR:-$(cd "$SELF_DIR/.." && pwd)}"
exec node "$SELF_DIR/../lib/gate-cli.mjs" "$@"
```

Run: `chmod +x .loop/bin/loop-gate`

- [ ] **Step 7: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/loop-gate.bats`
Expected: 9 tests, all PASS

- [ ] **Step 8: コミット**

```bash
git add .loop/lib/gate.mjs .loop/lib/gate-cli.mjs .loop/bin/loop-gate \
        .loop/tests/loop-gate.bats .loop/tests/fixtures/issues
git commit -m "feat(gate): Issue 構造の機械検証 loop-gate を追加"
```

---

### Task 4: エージェント起動の抽象（`agent-run` + claude provider）

**Files:**
- Create: `.loop/bin/agent-run`
- Create: `.loop/agents/claude.sh`
- Test: `.loop/tests/agent-run.bats`, `.loop/tests/fixtures/agents/mock.sh`

**Interfaces:**
- Consumes: `common.sh`（Task 2）、`loop-config`（Task 1）
- Produces:
  - `agent-run --role maker|verifier|fixer --prompt-file <path> --cwd <dir> [--log <path>]`
  - provider スクリプトに渡す環境変数: `LOOP_ROLE` `LOOP_PROMPT_FILE` `LOOP_CWD` `LOOP_MODEL` `LOOP_MAX_TURNS` `LOOP_DIR`
  - provider の終了コードをそのまま返す。`--log` があれば標準出力と標準エラーを `tee` で保存する

- [ ] **Step 1: mock provider と失敗するテストを書く**

`.loop/tests/fixtures/agents/mock.sh`:

```bash
#!/usr/bin/env bash
# テスト用の provider。受け取った環境変数を出力し、MOCK_EXIT の終了コードで終わる
set -uo pipefail
echo "ROLE=$LOOP_ROLE"
echo "MODEL=${LOOP_MODEL:-}"
echo "MAX_TURNS=${LOOP_MAX_TURNS:-}"
echo "CWD=$LOOP_CWD"
echo "PROMPT=$(cat "$LOOP_PROMPT_FILE")"
exit "${MOCK_EXIT:-0}"
```

`.loop/tests/agent-run.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  printf '[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  printf 'こんにちは\n' > "$TMP/prompt.md"
}

teardown() { rm -rf "$TMP"; }

@test "provider に role とモデルと max-turns を渡す" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROLE=maker"* ]]
  [[ "$output" == *"MODEL=claude-sonnet-5"* ]]
  [[ "$output" == *"MAX_TURNS=120"* ]]
}

@test "role ごとに max-turns が変わる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role verifier --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MAX_TURNS=30"* ]]
}

@test "プロンプトの中身が渡る" {
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [[ "$output" == *"PROMPT=こんにちは"* ]]
}

@test "provider の終了コードをそのまま返す" {
  MOCK_EXIT=3 run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 3 ]
}

@test "--log で終了コードを保ったままログを保存する" {
  MOCK_EXIT=4 run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" \
    --cwd "$TMP" --log "$TMP/out/run.md"
  [ "$status" -eq 4 ]
  [ -f "$TMP/out/run.md" ]
  grep -q "ROLE=maker" "$TMP/out/run.md"
}

@test "存在しない provider は 2 で落ちる" {
  printf '[agent]\nprovider = "nope"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/agent-run" --role maker --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 2 ]
}

@test "--role がないと 2 で落ちる" {
  run "$LOOP_REAL_DIR/bin/agent-run" --prompt-file "$TMP/prompt.md" --cwd "$TMP"
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/agent-run.bats`
Expected: FAIL（`bin/agent-run` が存在しない）

- [ ] **Step 3: `.loop/bin/agent-run` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# エージェント起動の唯一の入口。provider の差し替えはここ 1 箇所で完結する。
# 抽象化は「プロセスを起動して終了コードとログを返す」までに留める。
# 用法: agent-run --role maker|verifier|fixer --prompt-file <path> --cwd <dir> [--log <path>]
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

ROLE=""; PROMPT_FILE=""; RUN_CWD="$PWD"; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)        ROLE="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --cwd)         RUN_CWD="${2:-}"; shift 2 ;;
    --log)         LOG="${2:-}"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

case "$ROLE" in
  maker|verifier|fixer) ;;
  *) echo "--role は maker|verifier|fixer のいずれか（受け取った値: '${ROLE}'）" >&2; exit 2 ;;
esac
[ -f "$PROMPT_FILE" ] || { echo "--prompt-file が見つからない: $PROMPT_FILE" >&2; exit 2; }
[ -d "$RUN_CWD" ] || { echo "--cwd が見つからない: $RUN_CWD" >&2; exit 2; }

PROVIDER="$(cfg agent.provider)" || { echo "agent.provider が未設定" >&2; exit 2; }
SCRIPT="$LOOP_DIR/agents/$PROVIDER.sh"
[ -x "$SCRIPT" ] || { echo "provider スクリプトがない、または実行権限がない: $SCRIPT" >&2; exit 2; }

LOOP_ROLE="$ROLE"
LOOP_PROMPT_FILE="$PROMPT_FILE"
LOOP_CWD="$RUN_CWD"
LOOP_MODEL="$(cfg "models.$ROLE" || true)"
LOOP_MAX_TURNS="$(cfg "turns.$ROLE" || true)"
export LOOP_ROLE LOOP_PROMPT_FILE LOOP_CWD LOOP_MODEL LOOP_MAX_TURNS

if [ -n "$LOG" ]; then
  mkdir -p "$(dirname "$LOG")"
  "$SCRIPT" 2>&1 | tee "$LOG"
  exit "${PIPESTATUS[0]}"
fi
exec "$SCRIPT"
```

- [ ] **Step 4: `.loop/agents/claude.sh` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# Claude Code provider。ツール許可リストの意味論は provider 固有なので
# 共通層では扱わず、ここで defaults.toml から組み立てる。
set -uo pipefail
: "${LOOP_ROLE:?LOOP_ROLE が未設定}"
: "${LOOP_PROMPT_FILE:?LOOP_PROMPT_FILE が未設定}"
: "${LOOP_CWD:?LOOP_CWD が未設定}"
: "${LOOP_DIR:?LOOP_DIR が未設定}"

# 設定の読み出しは実物の loop-config を使う（LOOP_DIR は環境変数で引き継がれる）
CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/loop-config"

TOOLS=()
while IFS= read -r line; do
  [ -n "$line" ] && TOOLS+=("$line")
done < <("$CONFIG" get "agents.claude.tools_$LOOP_ROLE" || true)
while IFS= read -r line; do
  [ -n "$line" ] && TOOLS+=("$line")
done < <("$CONFIG" get "agents.claude.extra_tools" || true)

ARGS=(-p "$(cat "$LOOP_PROMPT_FILE")")
[ -n "${LOOP_MODEL:-}" ] && ARGS+=(--model "$LOOP_MODEL")
[ -n "${LOOP_MAX_TURNS:-}" ] && ARGS+=(--max-turns "$LOOP_MAX_TURNS")
[ "${#TOOLS[@]}" -gt 0 ] && ARGS+=(--allowedTools "${TOOLS[@]}")

cd "$LOOP_CWD" || exit 1
exec claude "${ARGS[@]}"
```

Run: `chmod +x .loop/bin/agent-run .loop/agents/claude.sh`

- [ ] **Step 5: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/agent-run.bats`
Expected: 7 tests, all PASS

- [ ] **Step 6: コミット**

```bash
git add .loop/bin/agent-run .loop/agents/claude.sh .loop/tests/agent-run.bats \
        .loop/tests/fixtures/agents/mock.sh
git commit -m "feat(agent): provider 差し替え可能な agent-run と claude provider を追加"
```

---

### Task 5: 予算ゲート（`budget-check`）

**Files:**
- Create: `.loop/lib/sum-usage.mjs`
- Create: `.loop/bin/budget-check`
- Test: `.loop/tests/budget-check.bats`, `.loop/tests/fixtures/ccusage/*`

**Interfaces:**
- Consumes: `common.sh`（Task 2）
- Produces:
  - `budget-check` — 終了コード 0 で実行可、1 でスキップ。標準出力に `BUDGET: used=<n> limit=<n>` または `SKIP: <理由>`
  - 環境変数 `LOOP_CCUSAGE_CMD` で使用量取得コマンドを差し替え可能（既定 `npx --yes ccusage@latest`）
  - **fail-closed**: 使用量が取得できない・解析できない場合はスキップ（終了コード 1）

- [ ] **Step 1: fixture と失敗するテストを書く**

`.loop/tests/fixtures/ccusage/ok.sh`（使用量 1000 を返すスタブ）:

```bash
#!/usr/bin/env bash
echo '{"daily":[{"totalTokens":600},{"totalTokens":400}]}'
```

`.loop/tests/fixtures/ccusage/over.sh`:

```bash
#!/usr/bin/env bash
echo '{"daily":[{"totalTokens":999999999}]}'
```

`.loop/tests/fixtures/ccusage/garbage.sh`:

```bash
#!/usr/bin/env bash
echo 'not json at all'
```

`.loop/tests/fixtures/ccusage/fail.sh`:

```bash
#!/usr/bin/env bash
exit 1
```

`.loop/tests/budget-check.bats`:

```bash
#!/usr/bin/env bats

load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/ccusage"

setup() {
  TMP="$(mktemp -d)"
  LOOP_DIR="$(make_loop_dir "$TMP/repo/.loop")"
  export LOOP_DIR
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  chmod +x "$FIX"/*.sh
}

teardown() { rm -rf "$TMP"; }

@test "上限内なら 0 を返す" {
  LOOP_CCUSAGE_CMD="$FIX/ok.sh" run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"used=1000"* ]]
}

@test "上限を超えたら 1 を返す" {
  LOOP_CCUSAGE_CMD="$FIX/over.sh" run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
}

@test "ccusage が失敗したら fail-closed で 1 を返す" {
  LOOP_CCUSAGE_CMD="$FIX/fail.sh" run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"取得できない"* ]]
}

@test "出力が解析できなければ fail-closed で 1 を返す" {
  LOOP_CCUSAGE_CMD="$FIX/garbage.sh" run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"解析できない"* ]]
}

@test "config で上限を下げると同じ使用量でも落ちる" {
  printf '[budget]\ndaily_tokens = 500\n' > "$LOOP_DIR/config.toml"
  LOOP_CCUSAGE_CMD="$FIX/ok.sh" run "$LOOP_REAL_DIR/bin/budget-check"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/budget-check.bats`
Expected: FAIL（`bin/budget-check` が存在しない）

- [ ] **Step 3: `.loop/lib/sum-usage.mjs` を書く**

```javascript
// ccusage の JSON を標準入力から読み、totalTokens を合計して標準出力に整数を書く。
// 解析できなければ終了コード 1（呼び出し側が fail-closed で扱う）。
let s = '';
process.stdin.on('data', (d) => { s += d; });
process.stdin.on('end', () => {
  try {
    const j = JSON.parse(s);
    const rows = j.daily || j.data || [];
    if (!Array.isArray(rows)) throw new Error('daily が配列でない');
    const total = rows.reduce((a, r) => a + (r.totalTokens || 0), 0);
    process.stdout.write(`${total}\n`);
  } catch {
    process.exit(1);
  }
});
```

- [ ] **Step 4: `.loop/bin/budget-check` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# 予算ゲート（fail-closed）。0 = 実行可 / 1 = スキップ
# 使用量が取れない・解析できない場合は「使い切ったものとして扱う」
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

LIMIT="$(cfg budget.daily_tokens)" || { echo "SKIP: budget.daily_tokens が未設定"; exit 1; }

TODAY="$(date +%Y%m%d)"
CCUSAGE="${LOOP_CCUSAGE_CMD:-npx --yes ccusage@latest}"

RAW="$($CCUSAGE daily --json --since "$TODAY" --until "$TODAY" 2>/dev/null)" \
  || { echo "SKIP: 使用量を取得できない（fail-closed）"; exit 1; }

USED="$(printf '%s' "$RAW" | node "$LIB_DIR/sum-usage.mjs")" \
  || { echo "SKIP: 使用量を解析できない（fail-closed）"; exit 1; }

echo "BUDGET: used=$USED limit=$LIMIT"
if [ "$USED" -ge "$LIMIT" ]; then
  echo "SKIP: 本日のトークン予算を使い切った"
  exit 1
fi
exit 0
```

Run: `chmod +x .loop/bin/budget-check`

- [ ] **Step 5: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/budget-check.bats`
Expected: 5 tests, all PASS

- [ ] **Step 6: コミット**

```bash
git add .loop/lib/sum-usage.mjs .loop/bin/budget-check .loop/tests/budget-check.bats \
        .loop/tests/fixtures/ccusage
git commit -m "feat(budget): fail-closed の予算ゲート budget-check を追加"
```

---

### Task 6: マージ済み worktree の片付け（`cleanup-merged`）

**Files:**
- Create: `.loop/bin/cleanup-merged`
- Test: `.loop/tests/cleanup-merged.bats`

**Interfaces:**
- Consumes: `common.sh`（Task 2）
- Produces:
  - `cleanup-merged` — `loop/issue-*` / `loop/preview-*` の worktree のうち、ブランチが `main` に取り込み済みのものを削除し、ローカルブランチも削除する。削除したものを 1 行ずつ標準出力に書く
  - リモートブランチの削除は best-effort（失敗しても無視）
  - 未マージの worktree には触らない（作業中の可能性があるため）

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/cleanup-merged.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  mkdir -p "$REPO_ROOT/loops"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

make_wt() { # $1 = issue 番号, $2 = ファイル内容
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-$1" -b "loop/issue-$1" main
  echo "$2" > "$TMP/repo-issue-$1/b.txt"
  git -C "$TMP/repo-issue-$1" add -A
  git -C "$TMP/repo-issue-$1" commit -qm "work $1"
}

@test "main に取り込み済みの worktree とブランチを削除する" {
  make_wt 1 hello
  git -C "$REPO_ROOT" merge -q --no-edit loop/issue-1
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-1" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-1
  [ "$status" -ne 0 ]
}

@test "未マージの worktree には触らない" {
  make_wt 2 world
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-2" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-2
  [ "$status" -eq 0 ]
}

@test "loop/ 以外の worktree には触らない" {
  git -C "$REPO_ROOT" worktree add -q "$TMP/other" -b feature/mine main
  git -C "$REPO_ROOT" merge -q --no-edit feature/mine
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -d "$TMP/other" ]
}

@test "片付けるものがなければ何も出力しない" {
  run "$LOOP_REAL_DIR/bin/cleanup-merged"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/cleanup-merged.bats`
Expected: FAIL（`bin/cleanup-merged` が存在しない）

- [ ] **Step 3: `.loop/bin/cleanup-merged` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# main に取り込み済みの loop worktree / branch を片付ける。
# 未マージのものには触らない（Maker が作業中の可能性があるため）。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
cd "$REPO_ROOT" || exit 1

# worktree のパスとブランチを対にして取り出す
WT_PATH=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) WT_PATH="${line#worktree }" ;;
    "branch refs/heads/loop/"*)
      BRANCH="${line#branch refs/heads/}"
      # main に取り込み済みか
      if git merge-base --is-ancestor "$BRANCH" main 2>/dev/null; then
        git worktree remove --force "$WT_PATH" 2>/dev/null
        git branch -D "$BRANCH" >/dev/null 2>&1
        git push origin --delete "$BRANCH" >/dev/null 2>&1 || true
        echo "片付け: $BRANCH ($WT_PATH)"
      fi
      ;;
  esac
done < <(git worktree list --porcelain)

git worktree prune
exit 0
```

Run: `chmod +x .loop/bin/cleanup-merged`

- [ ] **Step 4: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/cleanup-merged.bats`
Expected: 4 tests, all PASS

- [ ] **Step 5: コミット**

```bash
git add .loop/bin/cleanup-merged .loop/tests/cleanup-merged.bats
git commit -m "feat(cleanup): マージ済み loop worktree の片付けを追加"
```

---

### Task 7: Maker の起動（`dispatch-maker` + プロンプト + workflow スキル）

**Files:**
- Create: `.loop/prompts/maker.md`
- Create: `.loop/skills/maker-workflow.md`
- Create: `.loop/bin/dispatch-maker`
- Test: `.loop/tests/dispatch-maker.bats`, `.loop/tests/fixtures/bin/gh`

**Interfaces:**
- Consumes: `common.sh`（Task 2）、`agent-run`（Task 4）、`budget-check`（Task 5）
- Produces:
  - `dispatch-maker <issue-number>` — worktree `../<repo>-issue-<N>` を branch `loop/issue-<N>` で作り、Maker を起動する。ログは `loops/runs/YYYY-MM-DD-maker-issue-<N>.md`
  - 冪等: worktree か branch が既にあれば `SKIPPED` を記録して終了コード 0
  - `maturity = L1` では終了コード 1 で拒否
  - 一過性エラーかつ worktree が手つかずのときだけ 1 回リトライ
  - 環境変数 `LOOP_SKIP_VERIFIER=1` で Verifier チェーンを抑止（テスト用）
  - テスト用の `gh` スタブは `PATH` の先頭に置いて差し替える

- [ ] **Step 1: `gh` スタブを書く**

`.loop/tests/fixtures/bin/gh`:

```bash
#!/usr/bin/env bash
# テスト用の gh スタブ。呼び出しを $GH_LOG に記録し、$GH_* 環境変数で応答を決める
set -uo pipefail
[ -n "${GH_LOG:-}" ] && echo "$*" >> "$GH_LOG"

# 既定の JSON は必ず変数に入れてから ${VAR:-$DEFAULT} の形で使う。
# ${VAR:-{"a":"b"}} のように波括弧を直接書くと、VAR が設定されているときだけ
# 末尾に余分な } が付いて JSON が壊れる（bash 3.2 / 5.3 の両方で再現）
DEFAULT_ISSUE_JSON='{"body":"","state":"OPEN"}'
DEFAULT_PR_VIEW_JSON='{}'

# set -u 下で単独引数（gh --version 等）でも落ちないよう既定値を付ける
case "${1:-} ${2:-}" in
  "issue view")
    if [ "${3:-}" = "--json" ] || [ "${4:-}" = "--json" ]; then
      echo "${GH_ISSUE_JSON:-$DEFAULT_ISSUE_JSON}"
    fi
    ;;
  "issue list") echo "${GH_ISSUE_LIST_JSON:-[]}" ;;
  "pr list")    echo "${GH_PR_LIST_JSON:-[]}" ;;
  "pr view")    echo "${GH_PR_VIEW_JSON:-$DEFAULT_PR_VIEW_JSON}" ;;
  "pr merge")   ;;
  *) ;;
esac
exit "${GH_EXIT:-0}"

**注意:** この fixture は Task 3 の fix round で前倒し作成済み。
Task 7 の時点では既存を確認するだけでよい（内容が上記と一致すること）。
```

- [ ] **Step 2: 失敗するテストを書く**

`.loop/tests/dispatch-maker.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/maker.md" "$LOOP_DIR/prompts/maker.md"
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_VERIFIER=1; export LOOP_SKIP_VERIFIER
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
  chmod +x "$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "worktree と branch を作って Maker を起動する" {
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo-issue-7" ]
  run git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/loop/issue-7
  [ "$status" -eq 0 ]
}

@test "プロンプトに Issue 番号とプロジェクトのコマンドを埋める" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-7.md"
  [[ "$output" == *"#7"* ]]
  [[ "$output" == *"pnpm -r test"* ]]
}

@test "loop:ready ラベルを外す" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
}

@test "既に worktree があれば SKIPPED で 0 を返す" {
  "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"SKIPPED"* ]]
}

@test "maturity = L1 では拒否する" {
  # maturity はトップレベルのキーなので、テーブル見出しより前に書く
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"L1"* ]]
}

@test "エージェントが失敗したら STATE に FAILED を記録し worktree を残す" {
  MOCK_EXIT=5 run "$LOOP_REAL_DIR/bin/dispatch-maker" 7
  [ "$status" -eq 1 ]
  [ -d "$TMP/repo-issue-7" ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}
```

- [ ] **Step 3: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/dispatch-maker.bats`
Expected: FAIL（`bin/dispatch-maker` も `prompts/maker.md` も存在しない）

- [ ] **Step 4: `.loop/prompts/maker.md` を書く**

```markdown
あなたは Maker です。Issue #{{ISSUE}} を実装します。専用の git worktree の中にいます。
`.loop/skills/maker-workflow.md` に従ってください。

1. `gh issue view {{ISSUE}}` で背景・受け入れ基準・実装方針・**スコープ外**を読む
2. `CLAUDE.md` とリポジトリの既存パターンを読む
3. TDD で実装する。失敗するテスト → 最小実装 → 緑。時刻依存はモックする
   **最初のテストが緑になった時点で必ず 1 回コミットする**
   （max-turns で中断されても成果が branch に残るようにするため）
4. 完了条件: `{{TEST_CMD}}` と `{{LINT_CMD}}` が緑
5. `git push -u origin loop/issue-{{ISSUE}}` → `gh pr create`
   PR 本文には受け入れ基準のチェックリストと `Closes #{{ISSUE}}` を入れる

**禁止:**
- main への直接コミット
- Issue の「スコープ外」に書かれた変更、および受け入れ基準にない変更
- `loops/` と `.loop/` の編集

**完了できない場合:** PR を作らず、`gh issue comment {{ISSUE}}` に理由を書き、
`gh issue edit {{ISSUE}} --add-label needs-human` を付けて終了する。
```

- [ ] **Step 5: `.loop/skills/maker-workflow.md` を書く**

```markdown
# Skill: Maker の作業手順

## 隔離
- 必ず自分専用の worktree（`../<repo>-issue-<N>`）と branch（`loop/issue-<N>`）で作業する
- main には絶対に直接コミットしない

## TDD
1. 受け入れ基準の 1 項目を選ぶ
2. その項目が満たされていないことを示す**失敗するテスト**を書く
3. テストを実行して、期待どおりの理由で失敗することを確認する
4. 通す最小の実装を書く
5. テストを実行して緑を確認する
6. コミットする（Conventional Commits）
7. 次の項目へ

**最初の緑で必ず 1 回コミットする。** 中断されても成果が残る。

## テストの書き方
- 時刻に依存するものはモックする（実時刻を使うテストは不安定になる）
- 境界値を含める
- 同じ入力で 2 回実行しても同じ結果になること（冪等性）を確認する

## Safe-Stop
作業は小さい単位に分割し、単位の完了ごとにコミットする。
停止は常に安全であること — 現在の単位を完了するかクリーンに破棄し、
merge 途中の worktree を残さない。

## 判断できないとき
勝手に決めない。`needs-human` ラベルを付けて人間に回す。
```

- [ ] **Step 6: `.loop/bin/dispatch-maker` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# Maker を headless 起動する。PR ができたら Verifier をチェーンする。
# 用法: dispatch-maker <issue-number>
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

ISSUE="${1:-}"
[ -n "$ISSUE" ] || { echo "用法: dispatch-maker <issue-number>" >&2; exit 2; }

MATURITY="$(cfg maturity)"
if [ "$MATURITY" = "L1" ]; then
  echo "REFUSED: maturity=L1（報告のみ）。昇格は .loop/config.toml を人間が編集して行う"
  exit 1
fi

"$BIN_DIR/budget-check" || { echo "SKIP: 予算ゲート"; exit 1; }

WT="$REPO_ROOT/../$(basename "$REPO_ROOT")-issue-$ISSUE"
BRANCH="loop/issue-$ISSUE"

if [ -d "$WT" ] || git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  record_state "maker issue-$ISSUE SKIPPED (既に in-flight: worktree/branch が存在)"
  echo "SKIP: issue-$ISSUE は既に in-flight"
  exit 0
fi

git worktree add "$WT" -b "$BRANCH" main || {
  record_state "maker issue-$ISSUE FAILED (worktree 作成に失敗)"
  exit 1
}
gh issue edit "$ISSUE" --remove-label loop:ready >/dev/null 2>&1 || true

PROMPT="$(mktemp)"
trap 'rm -f "$PROMPT"' EXIT
render_prompt "$LOOP_DIR/prompts/maker.md" \
  "ISSUE=$ISSUE" \
  "TEST_CMD=$(cfg project.test || echo '')" \
  "LINT_CMD=$(cfg project.lint || echo '')" > "$PROMPT"

LOG="loops/runs/$(date +%Y-%m-%d)-maker-issue-$ISSUE.md"

run_maker() {
  "$BIN_DIR/agent-run" --role maker --prompt-file "$PROMPT" --cwd "$WT" --log "$LOG"
}

RC=0
run_maker || RC=$?

# 一過性エラーは 1 回だけ自動リトライ。worktree が手つかず（未コミット変更なし・
# main から進んでいない）のときだけ。作業途中で死んだ WIP は残置して人間が確認する
if [ "$RC" -ne 0 ] && is_transient_error "$LOG" \
   && [ -z "$(git -C "$WT" status --porcelain)" ] \
   && [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse main)" ]; then
  DELAY="$(retry_delay)"
  record_state "maker issue-$ISSUE 一過性エラー — ${DELAY}s 後に 1 回リトライ"
  sleep "$DELAY"
  RC=0
  run_maker || RC=$?
fi

if [ "$RC" -ne 0 ]; then
  record_state "maker issue-$ISSUE FAILED rc=$RC (log: $LOG)"
  gh issue edit "$ISSUE" --add-label needs-human >/dev/null 2>&1 || true
  echo "maker FAILED rc=$RC -> $LOG（worktree $WT は残置。人間が WIP を確認する）"
  exit 1
fi

# --jq には依存しない（gh のビルドによっては使えないため）。firing と同じく node で取り出す
PR="$(gh pr list --head "$BRANCH" --state open --json number,headRefName 2>/dev/null \
  | node -e "
let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
  try{const a=JSON.parse(s);
    const hit=a.find(p=>String(p.headRefName)==='$BRANCH')||a[0];
    process.stdout.write(hit&&hit.number?String(hit.number):'');}
  catch{process.stdout.write('')}})")

if [ -z "$PR" ]; then
  record_state "maker issue-$ISSUE 完了したが PR なし (log: $LOG)"
  gh issue edit "$ISSUE" --add-label needs-human >/dev/null 2>&1 || true
  echo "maker done (PR なし) -> $LOG"
  exit 0
fi

record_state "maker issue-$ISSUE ok -> PR #$PR (log: $LOG)"
echo "maker done -> $LOG / PR #$PR"

if [ "${LOOP_SKIP_VERIFIER:-0}" = "1" ]; then
  exit 0
fi
echo "chain: dispatch-verifier for PR #$PR"
"$BIN_DIR/dispatch-verifier" "$PR" || true
```

Run: `chmod +x .loop/bin/dispatch-maker`

- [ ] **Step 7: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/dispatch-maker.bats`
Expected: 6 tests, all PASS

- [ ] **Step 8: コミット**

```bash
git add .loop/prompts/maker.md .loop/skills/maker-workflow.md .loop/bin/dispatch-maker \
        .loop/tests/dispatch-maker.bats .loop/tests/fixtures/bin/gh
git commit -m "feat(maker): Maker の headless 起動 dispatch-maker を追加"
```

---

### Task 8: Verifier の起動（`dispatch-verifier` + プロンプト + workflow スキル）

**Files:**
- Create: `.loop/prompts/verifier.md`
- Create: `.loop/skills/verifier-workflow.md`
- Create: `.loop/bin/dispatch-verifier`
- Test: `.loop/tests/dispatch-verifier.bats`

**Interfaces:**
- Consumes: `common.sh`（Task 2）、`agent-run`（Task 4）、`budget-check`（Task 5）
- Produces:
  - `dispatch-verifier <pr-number>` — `../<repo>-verify-pr-<N>` に **detached** で PR を checkout し、Verifier を起動する。ログは `loops/runs/YYYY-MM-DD-verifier-pr-<N>.md`
  - 終了時に検証用 worktree を必ず削除する（`trap`）
  - `--detach` は必須。PR の head ブランチは Maker の worktree が保持しており、git は同一ブランチの二重 checkout を拒否する

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/dispatch-verifier.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/verifier.md" "$LOOP_DIR/prompts/verifier.md"
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "detached で checkout する" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  run cat "$GH_LOG"
  [[ "$output" == *"pr checkout 21 --detach"* ]]
}

@test "プロンプトに PR 番号とプロジェクトのコマンドを埋める" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-21.md"
  [[ "$output" == *"#21"* ]]
  [[ "$output" == *"pnpm -r test"* ]]
}

@test "終了時に検証用 worktree を削除する" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ ! -d "$TMP/repo-verify-pr-21" ]
}

@test "成功したら STATE に ok を記録する" {
  "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"verifier pr-21 ok"* ]]
}

@test "失敗したら STATE に FAILED を記録して 1 を返す" {
  MOCK_EXIT=2 run "$LOOP_REAL_DIR/bin/dispatch-verifier" 21
  [ "$status" -eq 1 ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/dispatch-verifier.bats`
Expected: FAIL（`bin/dispatch-verifier` も `prompts/verifier.md` も存在しない）

- [ ] **Step 3: `.loop/prompts/verifier.md` を書く**

```markdown
あなたは Verifier です。PR #{{PR}} を検証します。
Maker の会話・思考は一切知りません。まっさらな目で判定してください。
PR のブランチが detached で checkout 済みの worktree の中にいます。
`.loop/skills/verifier-workflow.md` に従ってください。

1. `gh pr view {{PR}}` と `gh pr diff {{PR}}`、および紐づく Issue の受け入れ基準を読む
2. `{{TEST_CMD}}` と `{{LINT_CMD}}` を実行する
3. 観点: 受け入れ基準の充足 / `CLAUDE.md` の規約 / テストの妥当性（時刻モック・境界値・冪等性）
   / Issue の「スコープ外」に手を出していないか
4. **まず判定チェックリストを PR コメントに投稿する。**
   `gh pr comment {{PR}} --body "<チェックリスト>"`
   冒頭に `## Verifier 判定: approve 相当 / request-changes / 判断不能` を明記する
5. 判定（3 択、必ずどれか 1 つ）:
   - `gh pr review {{PR}} --approve --body "<根拠>"`
   - `gh pr review {{PR}} --request-changes --body "<具体的な指摘>"`
   - 判断不能: `gh pr edit {{PR}} --add-label needs-human`（review は submit しない）

**注意:** gh アカウントが PR 作成者と同一の場合、GitHub は review の submit を拒否します。
その場合は手順 4 のコメントが判定の正本になるので、
`gh pr edit {{PR}} --add-label needs-human` を付けて終了してください
（判断不能という意味ではなく、人間へのルーティングです）。

**禁止:** コードの修正 / merge（merge は常に人間、または L3 の自動 merge）
```

- [ ] **Step 4: `.loop/skills/verifier-workflow.md` を書く**

```markdown
# Skill: Verifier の作業手順

## 原則
あなたは Maker の思考過程を知らない。**diff と受け入れ基準だけを見る。**
Maker の意図を推測して補完しない。書かれていないことは「されていない」と扱う。

## 手順
1. Issue の受け入れ基準を 1 項目ずつ表にする
2. 各項目について、diff のどこがそれを満たすかを指し示す。指せなければ未充足
3. 受け入れ基準に書かれた検証コマンドを**実際に実行する**。結果を記録する
4. Issue の「スコープ外」に書かれたものに手が入っていないか diff を確認する
5. テストの妥当性を見る:
   - 実時刻に依存していないか（モックされているか）
   - 境界値が含まれるか
   - 2 回実行しても同じ結果になるか

## 判定
- **approve 相当**: 全項目が充足し、検証コマンドが緑
- **request-changes**: 充足していない項目がある、または検証コマンドが赤
- **判断不能**: 受け入れ基準そのものが解釈できない、または検証手段がない

判定の根拠は必ずチェックリストの形で PR コメントに残す。
これが人間の merge 判断の材料になる。

## 禁止
コードの修正、merge。
```

- [ ] **Step 5: `.loop/bin/dispatch-verifier` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# Verifier を headless 起動する（まっさらなコンテキスト）。
# 実行結果は自分で loops/STATE.md に記録する（呼び出し側は || true で受けてよい）
# 用法: dispatch-verifier <pr-number>
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

PR="${1:-}"
[ -n "$PR" ] || { echo "用法: dispatch-verifier <pr-number>" >&2; exit 2; }

MATURITY="$(cfg maturity)"
if [ "$MATURITY" = "L1" ]; then
  echo "REFUSED: maturity=L1（報告のみ）"
  exit 1
fi

GATE_RC=0
GATE="$("$BIN_DIR/budget-check")" || GATE_RC=$?
echo "$GATE"
if [ "$GATE_RC" -ne 0 ]; then
  record_state "verifier pr-$PR スキップ ($(echo "$GATE" | grep '^SKIP' | head -1))"
  exit 1
fi

WT="$REPO_ROOT/../$(basename "$REPO_ROOT")-verify-pr-$PR"
git worktree add --detach "$WT" main >/dev/null 2>&1 || {
  record_state "verifier pr-$PR FAILED (worktree 作成に失敗)"
  exit 1
}
trap 'git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1; git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1' EXIT

# --detach は必須。PR の head ブランチは Maker の worktree が保持しており、
# git は同一ブランチの二重 checkout を拒否する
( cd "$WT" && gh pr checkout "$PR" --detach ) || {
  record_state "verifier pr-$PR FAILED (gh pr checkout)"
  exit 1
}

PROMPT="$(mktemp)"
render_prompt "$LOOP_DIR/prompts/verifier.md" \
  "PR=$PR" \
  "TEST_CMD=$(cfg project.test || echo '')" \
  "LINT_CMD=$(cfg project.lint || echo '')" > "$PROMPT"

LOG="loops/runs/$(date +%Y-%m-%d)-verifier-pr-$PR.md"

run_verifier() {
  "$BIN_DIR/agent-run" --role verifier --prompt-file "$PROMPT" --cwd "$WT" --log "$LOG"
}

RC=0
run_verifier || RC=$?

if [ "$RC" -ne 0 ] && is_transient_error "$LOG"; then
  DELAY="$(retry_delay)"
  record_state "verifier pr-$PR 一過性エラー — ${DELAY}s 後に 1 回リトライ"
  sleep "$DELAY"
  RC=0
  run_verifier || RC=$?
fi

rm -f "$PROMPT"

if [ "$RC" -ne 0 ]; then
  record_state "verifier pr-$PR FAILED rc=$RC (log: $LOG)"
  echo "verifier FAILED rc=$RC -> $LOG"
  exit 1
fi

record_state "verifier pr-$PR ok (log: $LOG)"
echo "verifier done -> $LOG"
```

Run: `chmod +x .loop/bin/dispatch-verifier`

- [ ] **Step 6: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/dispatch-verifier.bats`
Expected: 5 tests, all PASS

- [ ] **Step 7: コミット**

```bash
git add .loop/prompts/verifier.md .loop/skills/verifier-workflow.md \
        .loop/bin/dispatch-verifier .loop/tests/dispatch-verifier.bats
git commit -m "feat(verifier): Verifier の headless 起動 dispatch-verifier を追加"
```

---

### Task 9: Fixer の起動（`dispatch-fixer` + プロンプト）

**Files:**
- Create: `.loop/prompts/fixer.md`
- Create: `.loop/bin/dispatch-fixer`
- Test: `.loop/tests/dispatch-fixer.bats`

**Interfaces:**
- Consumes: `common.sh`（Task 2）、`agent-run`（Task 4）、`dispatch-verifier`（Task 8）
- Produces:
  - `dispatch-fixer <pr-number> <issue-number> <round>` — Maker の worktree を再利用して Verifier の指摘を修正し、完了したら Verifier を再実行する
  - ログは `loops/runs/YYYY-MM-DD-fixer-pr-<N>-r<round>.md`。ファイル名の `r<round>` が実施済みラウンド数の記録になる（別途カウンタを持たない）
  - worktree がなければ（Maker の worktree が既に片付いている等）`needs-human` を付けて終了コード 1
  - 環境変数 `LOOP_SKIP_VERIFIER=1` で Verifier 再実行を抑止（テスト用）

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/dispatch-fixer.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/fixer.md" "$LOOP_DIR/prompts/fixer.md"
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "pnpm -r test"\nlint = "pnpm -r lint"\n' \
    > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-9" -b loop/issue-9 main

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_VERIFIER=1; export LOOP_SKIP_VERIFIER
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "Maker の worktree を再利用して起動する" {
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 0 ]
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md"
  [[ "$output" == *"CWD=$TMP/repo-issue-9"* ]]
}

@test "プロンプトに PR 番号とラウンドを埋める" {
  "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  run cat "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md"
  [[ "$output" == *"#30"* ]]
}

@test "worktree がなければ needs-human を付けて 1 を返す" {
  run "$LOOP_REAL_DIR/bin/dispatch-fixer" 31 99 1
  [ "$status" -eq 1 ]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
}

@test "失敗したら STATE に FAILED を記録する" {
  MOCK_EXIT=7 run "$LOOP_REAL_DIR/bin/dispatch-fixer" 30 9 1
  [ "$status" -eq 1 ]
  run tail -3 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"FAILED"* ]]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/dispatch-fixer.bats`
Expected: FAIL（`bin/dispatch-fixer` も `prompts/fixer.md` も存在しない）

- [ ] **Step 3: `.loop/prompts/fixer.md` を書く**

```markdown
あなたは Fixer です。PR #{{PR}}（Issue #{{ISSUE}}）に対する Verifier の指摘を修正します。
これは修正ラウンド {{ROUND}} 回目です。Maker が使っていた worktree の中にいます。

1. `gh pr view {{PR}} --comments` で Verifier の判定チェックリストと指摘を読む
2. **指摘された点だけを直す。** 新しい機能を足さない。リファクタリングもしない
3. 各修正ごとに、それを検証するテストが緑になることを確認してからコミットする
4. `{{TEST_CMD}}` と `{{LINT_CMD}}` が緑になったら push する
5. `gh pr comment {{PR}}` に「どの指摘をどう直したか」を 1 対 1 で対応させて書く

**禁止:**
- 指摘されていない変更
- 受け入れ基準の変更
- merge
- `loops/` と `.loop/` の編集

**指摘の意味が分からない、または直せない場合:**
`gh pr comment {{PR}}` に理由を書き、
`gh issue edit {{ISSUE}} --add-label needs-human` を付けて終了する。
推測で直さない。
```

- [ ] **Step 4: `.loop/bin/dispatch-fixer` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# Verifier の指摘を Maker の worktree で修正し、Verifier を再実行する。
# 用法: dispatch-fixer <pr-number> <issue-number> <round>
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

PR="${1:-}"; ISSUE="${2:-}"; ROUND="${3:-}"
[ -n "$PR" ] && [ -n "$ISSUE" ] && [ -n "$ROUND" ] \
  || { echo "用法: dispatch-fixer <pr-number> <issue-number> <round>" >&2; exit 2; }

"$BIN_DIR/budget-check" || { echo "SKIP: 予算ゲート"; exit 1; }

WT="$REPO_ROOT/../$(basename "$REPO_ROOT")-issue-$ISSUE"
if [ ! -d "$WT" ]; then
  record_state "fixer pr-$PR 起動できない (worktree $WT がない) — needs-human"
  gh issue edit "$ISSUE" --add-label needs-human >/dev/null 2>&1 || true
  echo "FAILED: worktree がない: $WT"
  exit 1
fi

PROMPT="$(mktemp)"
trap 'rm -f "$PROMPT"' EXIT
render_prompt "$LOOP_DIR/prompts/fixer.md" \
  "PR=$PR" "ISSUE=$ISSUE" "ROUND=$ROUND" \
  "TEST_CMD=$(cfg project.test || echo '')" \
  "LINT_CMD=$(cfg project.lint || echo '')" > "$PROMPT"

LOG="loops/runs/$(date +%Y-%m-%d)-fixer-pr-$PR-r$ROUND.md"

RC=0
"$BIN_DIR/agent-run" --role fixer --prompt-file "$PROMPT" --cwd "$WT" --log "$LOG" || RC=$?

if [ "$RC" -ne 0 ]; then
  record_state "fixer pr-$PR r$ROUND FAILED rc=$RC (log: $LOG)"
  gh issue edit "$ISSUE" --add-label needs-human >/dev/null 2>&1 || true
  echo "fixer FAILED rc=$RC -> $LOG"
  exit 1
fi

record_state "fixer pr-$PR r$ROUND ok (log: $LOG)"
echo "fixer done -> $LOG"

if [ "${LOOP_SKIP_VERIFIER:-0}" = "1" ]; then
  exit 0
fi
echo "chain: dispatch-verifier for PR #$PR (再検証)"
"$BIN_DIR/dispatch-verifier" "$PR" || true
```

Run: `chmod +x .loop/bin/dispatch-fixer`

- [ ] **Step 5: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/dispatch-fixer.bats`
Expected: 4 tests, all PASS

- [ ] **Step 6: コミット**

```bash
git add .loop/prompts/fixer.md .loop/bin/dispatch-fixer .loop/tests/dispatch-fixer.bats
git commit -m "feat(fixer): Verifier 指摘の自動修正 dispatch-fixer を追加"
```

---

### Task 10: 発火の本体（`firing`）

**Files:**
- Create: `.loop/bin/firing`
- Test: `.loop/tests/firing.bats`

**Interfaces:**
- Consumes: すべての `bin/*`（Task 3〜9）
- Produces:
  - `firing [--dry-run]` — cron から呼ばれる唯一の入口
  - 実行順: origin/main 同期 → cleanup-merged → fix 待ち PR → ready の最小番号選定 → gate 再検証 → 上限チェック → maker → verifier → L3 自動 merge
  - **空回りゼロ**: 仕事がなければ何も記録せず終了コード 0
  - `--dry-run` は判定結果だけを `DRY RUN: <判定>` の形で出力し、副作用を起こさない
  - `maturity = L1` では dispatch せず、判定結果を STATE に記録する

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/firing.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/"
  printf '[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_FETCH=1; export LOOP_SKIP_FETCH
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
  chmod +x "$BATS_TEST_DIRNAME/fixtures/ccusage/"*.sh
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "ready な Issue がなければ何も記録せず 0 で終わる" {
  GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run wc -l < "$REPO_ROOT/loops/STATE.md"
  [ "$output" -eq 1 ]
}

@test "--dry-run は判定だけ出して副作用を起こさない" {
  GH_ISSUE_LIST_JSON='[{"number":5}]' run "$LOOP_REAL_DIR/bin/firing" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"#5"* ]]
  [ ! -d "$TMP/repo-issue-5" ]
}

@test "maturity = L1 では dispatch せず STATE に記録する" {
  printf 'maturity = "L1"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_ISSUE_LIST_JSON='[{"number":5}]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo-issue-5" ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"L1"* ]]
  [[ "$output" == *"#5"* ]]
}

@test "open PR が上限に達していればスキップを記録する" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nmax_open_prs = 1\n' > "$LOOP_DIR/config.toml"
  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  GH_PR_LIST_JSON='[{"number":1,"headRefName":"loop/issue-1"}]' \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"PR 上限"* ]]
}

@test "本日の dispatch 上限に達していればスキップを記録する" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nmax_dispatch_per_day = 1\n' > "$LOOP_DIR/config.toml"
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-3.md"
  GH_ISSUE_LIST_JSON='[{"number":5}]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"日次上限"* ]]
}

@test "予算超過ならスキップを記録する" {
  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/over.sh" \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run tail -2 "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"予算"* ]]
}

@test "gate を通らない Issue は ready を剥がして needs-human にする" {
  GH_ISSUE_LIST_JSON='[{"number":5}]' \
  GH_ISSUE_JSON='{"body":"中身がない","state":"OPEN"}' \
    run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  run cat "$GH_LOG"
  [[ "$output" == *"--remove-label loop:ready"* ]]
  [[ "$output" == *"--add-label needs-human"* ]]
}
```

- [ ] **Step 2: `gh` スタブに issue list / pr merge を足す**

`.loop/tests/fixtures/bin/gh` の `case` に以下を追加する:

```bash
  "issue list") echo "${GH_ISSUE_LIST_JSON:-[]}" ;;
  "pr merge")   ;;
```

`--jq` を使わずに済むよう、`firing` 側は `--json` の生 JSON を `node -e` で処理する。

- [ ] **Step 3: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/firing.bats`
Expected: FAIL（`bin/firing` が存在しない）

- [ ] **Step 4: `.loop/bin/firing` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# スケジュール発火の唯一の入口。cron から呼ばれる。
# 何もすることがなければ何も記録せず終了する（空回りゼロ）。
# 用法: firing [--dry-run]
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

DATE="$(date +%Y-%m-%d)"
MATURITY="$(cfg maturity)"

# JSON から値を取り出す小さなヘルパー（jq に依存しない）
jnode() { node -e "$1"; }

# --- 0. origin/main 同期 ---------------------------------------------------
if [ "$DRY" = 0 ] && [ "${LOOP_SKIP_FETCH:-0}" != "1" ]; then
  git fetch origin >/dev/null 2>&1 || true
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    if ! git merge --no-edit origin/main >/dev/null 2>&1; then
      git merge --abort >/dev/null 2>&1 || true
      record_state "firing 中止: origin/main とのコンフリクト"
      exit 1
    fi
  fi
fi

# --- 1. マージ済み worktree の片付け ---------------------------------------
[ "$DRY" = 0 ] && "$BIN_DIR/cleanup-merged" || true

# --- 2. 状況の収集 ---------------------------------------------------------
READY_JSON="$(gh issue list --label loop:ready --state open --json number 2>/dev/null || echo '[]')"
NEXT_ISSUE="$(printf '%s' "$READY_JSON" | jnode '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{const a=JSON.parse(s);const n=a.map(x=>x.number);
    process.stdout.write(n.length?String(Math.min(...n)):"");}catch{process.stdout.write("")}})')"

PR_JSON="$(gh pr list --state open --json number,headRefName 2>/dev/null || echo '[]')"
N_OPEN="$(printf '%s' "$PR_JSON" | jnode '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{const a=JSON.parse(s);
    process.stdout.write(String(a.filter(p=>String(p.headRefName).startsWith("loop/issue-")).length));}
  catch{process.stdout.write("999")}})')"

MAX_PRS="$(cfg loop.max_open_prs)"
MAXD="$(cfg loop.max_dispatch_per_day)"
N_TODAY="$(ls "loops/runs/$DATE"-maker-issue-*.md 2>/dev/null | wc -l | tr -d ' ')"

# --- 3. 何もすることがなければ静かに終わる ---------------------------------
if [ -z "$NEXT_ISSUE" ]; then
  [ "$DRY" = 1 ] && echo "DRY RUN: ready な Issue なし（何もしない）"
  exit 0
fi

# --- 4. 上限チェック（fail-closed） ----------------------------------------
if [ "$N_OPEN" -ge "$MAX_PRS" ]; then
  MSG="dispatch スキップ #$NEXT_ISSUE (open PR 上限 $N_OPEN/$MAX_PRS)"
  [ "$DRY" = 1 ] && { echo "DRY RUN: $MSG"; exit 0; }
  record_state "$MSG"; exit 0
fi
if [ "$N_TODAY" -ge "$MAXD" ]; then
  MSG="dispatch スキップ #$NEXT_ISSUE (本日の日次上限 $N_TODAY/$MAXD)"
  [ "$DRY" = 1 ] && { echo "DRY RUN: $MSG"; exit 0; }
  record_state "$MSG"; exit 0
fi

GATE_RC=0
GATE_OUT="$("$BIN_DIR/budget-check")" || GATE_RC=$?
if [ "$GATE_RC" -ne 0 ]; then
  MSG="dispatch スキップ #$NEXT_ISSUE (予算: $(echo "$GATE_OUT" | grep '^SKIP' | head -1))"
  [ "$DRY" = 1 ] && { echo "DRY RUN: $MSG"; exit 0; }
  record_state "$MSG"; exit 0
fi

# --- 5. gate 再検証（Issue は MTG 後に編集されうる） ------------------------
GRC=0
GOUT="$("$BIN_DIR/loop-gate" "$NEXT_ISSUE" 2>&1)" || GRC=$?
if [ "$GRC" -ne 0 ]; then
  MSG="dispatch 中止 #$NEXT_ISSUE (gate 不合格。ready を剥がして needs-human)"
  if [ "$DRY" = 1 ]; then echo "DRY RUN: $MSG"; echo "$GOUT"; exit 0; fi
  gh issue edit "$NEXT_ISSUE" --remove-label loop:ready >/dev/null 2>&1 || true
  gh issue edit "$NEXT_ISSUE" --add-label needs-human >/dev/null 2>&1 || true
  gh issue comment "$NEXT_ISSUE" --body "loop-gate 不合格のため dispatch を中止しました。

\`\`\`
$GOUT
\`\`\`"  >/dev/null 2>&1 || true
  record_state "$MSG"
  exit 0
fi

# --- 6. L1 は報告だけ ------------------------------------------------------
if [ "$MATURITY" = "L1" ]; then
  MSG="L1 (報告のみ): 今なら #$NEXT_ISSUE を dispatch する"
  [ "$DRY" = 1 ] && { echo "DRY RUN: $MSG"; exit 0; }
  record_state "$MSG"; exit 0
fi

if [ "$DRY" = 1 ]; then
  echo "DRY RUN: #$NEXT_ISSUE を dispatch する (open PR $N_OPEN/$MAX_PRS, 本日 $N_TODAY/$MAXD)"
  exit 0
fi

# --- 7. Maker → Verifier ---------------------------------------------------
echo "firing: dispatching maker for issue #$NEXT_ISSUE"
"$BIN_DIR/dispatch-maker" "$NEXT_ISSUE" || echo "maker dispatch 失敗（loops/runs/ を確認）"
exit 0
```

- [ ] **Step 5: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/firing.bats`
Expected: 7 tests, all PASS

- [ ] **Step 6: コミット**

```bash
git add .loop/bin/firing .loop/tests/firing.bats .loop/tests/fixtures/bin/gh
git commit -m "feat(firing): 発火の本体 firing を追加（空回りゼロ・dry-run・L1 対応）"
```

---

### Task 11: 自動修正チェーンと L3 自動 merge（`firing` の拡張）

**Files:**
- Modify: `.loop/bin/firing`（`--- 2. 状況の収集 ---` の直後に fix 待ち処理を、末尾に L3 merge を追加）
- Create: `.loop/lib/pr-triage.mjs`
- Test: `.loop/tests/firing-chain.bats`

**Interfaces:**
- Consumes: `dispatch-fixer`（Task 9）、`firing`（Task 10）
- Produces:
  - `pr-triage.mjs` — `gh pr list --json number,headRefName,reviewDecision,labels` の JSON を標準入力で受け、`--mode needs-fix` なら `<pr>\t<issue>` を、`--mode auto-merge` なら `<pr>\t<issue>` を 1 行ずつ出力する
  - `firing` が `auto_fix_rounds` 以内の request-changes PR を最優先で Fixer に回す
  - `firing` が `maturity = L3` かつ `loop.auto_merge_label` 付きかつ `reviewDecision = APPROVED` の PR を merge する

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/firing-chain.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/"
  printf '[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
  git -C "$REPO_ROOT" worktree add -q "$TMP/repo-issue-9" -b loop/issue-9 main

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_FETCH=1; export LOOP_SKIP_FETCH
  LOOP_SKIP_VERIFIER=1; export LOOP_SKIP_VERIFIER
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

CHANGES_PR='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"CHANGES_REQUESTED","labels":[]}]'
APPROVED_AM='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"APPROVED","labels":[{"name":"loop:auto-merge"}]}]'
APPROVED_PLAIN='[{"number":30,"headRefName":"loop/issue-9","reviewDecision":"APPROVED","labels":[]}]'

@test "request-changes の PR に Fixer を回す" {
  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "auto_fix_rounds を超えたら needs-human にして Fixer を回さない" {
  touch "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md"
  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r2.md" ]
  run cat "$GH_LOG"
  [[ "$output" == *"--add-label needs-human"* ]]
}

@test "auto_fix_rounds = 0 なら Fixer を回さない" {
  printf '[agent]\nprovider = "mock"\n\n[loop]\nauto_fix_rounds = 0\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$CHANGES_PR" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  [ ! -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-fixer-pr-30-r1.md" ]
}

@test "L3 かつ auto-merge ラベルかつ approve なら merge する" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$APPROVED_AM" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  run cat "$GH_LOG"
  [[ "$output" == *"pr merge 30"* ]]
}

@test "L3 でも auto-merge ラベルがなければ merge しない" {
  printf 'maturity = "L3"\n[agent]\nprovider = "mock"\n' > "$LOOP_DIR/config.toml"
  GH_PR_LIST_JSON="$APPROVED_PLAIN" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
}

@test "L2 では auto-merge ラベルがあっても merge しない" {
  GH_PR_LIST_JSON="$APPROVED_AM" GH_ISSUE_LIST_JSON='[]' run "$LOOP_REAL_DIR/bin/firing"
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/firing-chain.bats`
Expected: FAIL（fix 待ち処理も L3 merge も未実装）

- [ ] **Step 3: `.loop/lib/pr-triage.mjs` を書く**

```javascript
// gh pr list の JSON を標準入力で受け、対象 PR を <pr>\t<issue> の形で列挙する。
// --mode needs-fix   : reviewDecision = CHANGES_REQUESTED の loop PR
// --mode auto-merge  : reviewDecision = APPROVED かつ指定ラベルを持つ loop PR (--label で指定)
const argv = process.argv.slice(2);
const get = (name, def) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : def;
};
const mode = get('--mode', 'needs-fix');
const label = get('--label', 'loop:auto-merge');

let s = '';
process.stdin.on('data', (d) => { s += d; });
process.stdin.on('end', () => {
  let rows = [];
  try { rows = JSON.parse(s); } catch { process.exit(0); }
  if (!Array.isArray(rows)) process.exit(0);
  for (const p of rows) {
    const ref = String(p.headRefName || '');
    const m = /^loop\/issue-(\d+)$/.exec(ref);
    if (!m) continue;
    const labels = (p.labels || []).map((l) => l.name);
    const ok =
      mode === 'needs-fix'
        ? p.reviewDecision === 'CHANGES_REQUESTED'
        : p.reviewDecision === 'APPROVED' && labels.includes(label);
    if (ok) process.stdout.write(`${p.number}\t${m[1]}\n`);
  }
});
```

- [ ] **Step 4: `firing` の状況収集を拡張する**

`PR_JSON` を取得している行を、ラベルとレビュー結果も取るように差し替える:

```bash
PR_JSON="$(gh pr list --state open --json number,headRefName,reviewDecision,labels 2>/dev/null || echo '[]')"
```

- [ ] **Step 5: `firing` に fix 待ち処理を追加する**

`# --- 3. 何もすることがなければ静かに終わる ---` の**直前**に挿入する:

```bash
# --- 2.5 request-changes の PR を最優先で Fixer に回す ---------------------
AUTO_FIX_ROUNDS="$(cfg loop.auto_fix_rounds)"
if [ "$DRY" = 0 ] && [ "$MATURITY" != "L1" ] && [ "$AUTO_FIX_ROUNDS" -gt 0 ]; then
  while IFS="$(printf '\t')" read -r FPR FISSUE; do
    [ -n "$FPR" ] || continue
    DONE_ROUNDS="$(ls "loops/runs/$DATE"-fixer-pr-"$FPR"-r*.md 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$DONE_ROUNDS" -ge "$AUTO_FIX_ROUNDS" ]; then
      record_state "pr-$FPR 自動修正の上限 ($DONE_ROUNDS/$AUTO_FIX_ROUNDS) — needs-human"
      gh issue edit "$FISSUE" --add-label needs-human >/dev/null 2>&1 || true
      continue
    fi
    NEXT_ROUND=$((DONE_ROUNDS + 1))
    echo "firing: dispatching fixer for PR #$FPR (round $NEXT_ROUND)"
    "$BIN_DIR/dispatch-fixer" "$FPR" "$FISSUE" "$NEXT_ROUND" || true
  done < <(printf '%s' "$PR_JSON" | node "$LIB_DIR/pr-triage.mjs" --mode needs-fix)
fi

# --- 2.6 L3: approve 済み かつ auto-merge ラベル付きの PR を merge ---------
if [ "$DRY" = 0 ] && [ "$MATURITY" = "L3" ]; then
  AM_LABEL="$(cfg loop.auto_merge_label)"
  while IFS="$(printf '\t')" read -r MPR MISSUE; do
    [ -n "$MPR" ] || continue
    if gh pr merge "$MPR" --squash --delete-branch >/dev/null 2>&1; then
      record_state "L3 自動 merge: PR #$MPR (issue #$MISSUE)"
      echo "firing: auto-merged PR #$MPR"
    else
      record_state "L3 自動 merge に失敗: PR #$MPR — needs-human"
      gh issue edit "$MISSUE" --add-label needs-human >/dev/null 2>&1 || true
    fi
  done < <(printf '%s' "$PR_JSON" | node "$LIB_DIR/pr-triage.mjs" --mode auto-merge --label "$AM_LABEL")
fi
```

- [ ] **Step 6: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/firing-chain.bats && npx bats tests/firing.bats`
Expected: 6 + 7 tests, all PASS

- [ ] **Step 7: コミット**

```bash
git add .loop/lib/pr-triage.mjs .loop/bin/firing .loop/tests/firing-chain.bats
git commit -m "feat(firing): 自動修正チェーンと L3 ラベル限定の自動 merge を追加"
```

---

### Task 12: プレビュー（`preview`）

**Files:**
- Create: `.loop/bin/preview`
- Test: `.loop/tests/preview.bats`

**Interfaces:**
- Consumes: `common.sh`（Task 2）
- Produces:
  - `preview main` — リポジトリのルートで `[project] preview` を起動する
  - `preview pr <N>` — `../<repo>-preview-pr-<N>` に detached で PR を checkout して起動する
  - `preview stop` — 起動中のプレビューを止め、PR 用の worktree を片付ける
  - `preview status` — 起動中なら `RUNNING <pid> <url>`、そうでなければ `STOPPED`
  - PID は `loops/.preview.pid`、起動情報は `loops/.preview.meta` に置く
  - `[project] preview` が空なら `SKIP: project.preview が未設定` を出して終了コード 1

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/preview.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  printf '[project]\npreview = "sleep 30"\npreview_port = 4321\n' > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init
}

teardown() {
  "$LOOP_REAL_DIR/bin/preview" stop >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "main を起動すると PID ファイルができて status が RUNNING になる" {
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/loops/.preview.pid" ]
  run "$LOOP_REAL_DIR/bin/preview" status
  [[ "$output" == RUNNING* ]]
  [[ "$output" == *"4321"* ]]
}

@test "stop するとプロセスが止まり status が STOPPED になる" {
  "$LOOP_REAL_DIR/bin/preview" main
  run "$LOOP_REAL_DIR/bin/preview" stop
  [ "$status" -eq 0 ]
  run "$LOOP_REAL_DIR/bin/preview" status
  [ "$output" = "STOPPED" ]
}

@test "起動していないときの status は STOPPED" {
  run "$LOOP_REAL_DIR/bin/preview" status
  [ "$output" = "STOPPED" ]
}

@test "二重起動は拒否する" {
  "$LOOP_REAL_DIR/bin/preview" main
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"既に起動"* ]]
}

@test "project.preview が空なら 1 を返す" {
  printf '[project]\npreview = ""\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/preview" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"project.preview が未設定"* ]]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/preview.bats`
Expected: FAIL（`bin/preview` が存在しない）

- [ ] **Step 3: `.loop/bin/preview` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# アプリのプレビューを起動・停止する。MTG ① で「実際に動かして見る」ために使う。
# DooD 構成なので、アプリが Docker を使っていてもポートはホストに公開される。
# 用法: preview main | preview pr <N> | preview stop | preview status
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
cd "$REPO_ROOT" || exit 1

PID_FILE="$REPO_ROOT/loops/.preview.pid"
META_FILE="$REPO_ROOT/loops/.preview.meta"

is_running() {
  [ -f "$PID_FILE" ] || return 1
  kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start_in() { # $1 = 作業ディレクトリ, $2 = 説明
  local dir="$1" what="$2" cmd port
  cmd="$(cfg project.preview || echo '')"
  if [ -z "$cmd" ]; then
    echo "SKIP: project.preview が未設定です（.loop/config.toml に書いてください）"
    exit 1
  fi
  if is_running; then
    echo "既に起動しています（$(cat "$META_FILE" 2>/dev/null)）。先に preview stop してください"
    exit 1
  fi
  port="$(cfg project.preview_port || echo 3000)"
  mkdir -p "$REPO_ROOT/loops/runs"
  ( cd "$dir" && exec sh -c "$cmd" ) >> "$REPO_ROOT/loops/runs/preview.log" 2>&1 &
  echo $! > "$PID_FILE"
  printf '%s http://localhost:%s\n' "$what" "$port" > "$META_FILE"
  echo "プレビュー起動: $what -> http://localhost:$port （停止は preview stop）"
}

case "${1:-}" in
  main)
    start_in "$REPO_ROOT" "main"
    ;;
  pr)
    PR="${2:-}"
    [ -n "$PR" ] || { echo "用法: preview pr <N>" >&2; exit 2; }
    WT="$REPO_ROOT/../$(basename "$REPO_ROOT")-preview-pr-$PR"
    if [ ! -d "$WT" ]; then
      git worktree add --detach "$WT" main >/dev/null 2>&1 || {
        echo "worktree の作成に失敗しました" >&2; exit 1; }
      ( cd "$WT" && gh pr checkout "$PR" --detach ) || {
        git worktree remove --force "$WT" >/dev/null 2>&1
        echo "PR #$PR の checkout に失敗しました" >&2; exit 1; }
    fi
    start_in "$WT" "PR #$PR"
    ;;
  stop)
    if is_running; then
      PID="$(cat "$PID_FILE")"
      kill "$PID" 2>/dev/null || true
      sleep 1
      kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$META_FILE"
    # PR プレビュー用の worktree を片付ける
    while IFS= read -r line; do
      case "$line" in
        "worktree "*"-preview-pr-"*)
          git worktree remove --force "${line#worktree }" >/dev/null 2>&1 || true ;;
      esac
    done < <(git worktree list --porcelain)
    git worktree prune >/dev/null 2>&1
    echo "プレビューを停止しました"
    ;;
  status)
    if is_running; then
      echo "RUNNING $(cat "$PID_FILE") $(cat "$META_FILE" 2>/dev/null)"
    else
      echo "STOPPED"
    fi
    ;;
  *)
    echo "用法: preview main | preview pr <N> | preview stop | preview status" >&2
    exit 2
    ;;
esac
```

Run: `chmod +x .loop/bin/preview`

- [ ] **Step 4: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/preview.bats`
Expected: 5 tests, all PASS

- [ ] **Step 5: コミット**

```bash
git add .loop/bin/preview .loop/tests/preview.bats
git commit -m "feat(preview): アプリのプレビュー起動・停止を追加"
```

---

### Task 13: Docker 一式（イメージ・compose・cron）

**Files:**
- Create: `.loop/bin/gen-crontab`
- Create: `docker/Dockerfile`
- Create: `docker/compose.yml`
- Create: `docker/entrypoint.sh`
- Test: `.loop/tests/gen-crontab.bats`

**Interfaces:**
- Consumes: `common.sh`（Task 2）、`firing`（Task 10）
- Produces:
  - `gen-crontab` — `schedule.*` から supercronic 用の crontab を標準出力に生成する。行は `<分> <時リスト> * * * <firing のフルパス>`
  - `docker/compose.yml` — service `loop` 1 つ。`${PWD}:${PWD}` / `docker.sock` / 認証用 named volume
  - `docker compose up -d` でループが常駐する

- [ ] **Step 1: 失敗するテストを書く**

`.loop/tests/gen-crontab.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
}

teardown() { rm -rf "$TMP"; }

@test "既定（12 回/日・起点 1 時）で 2 時間おきの時リストを生成する" {
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 1,3,5,7,9,11,13,15,17,19,21,23 * * * "* ]]
}

@test "firings_per_day = 4 なら 6 時間おきになる" {
  printf '[schedule]\nfirings_per_day = 4\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [[ "$output" == "0 0,6,12,18 * * * "* ]]
}

@test "firings_per_day = 24 なら毎時になる" {
  printf '[schedule]\nfirings_per_day = 24\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0,1,2,3"* ]]
  [[ "$output" == *",23 * * * "* ]]
}

@test "firing のフルパスを含む" {
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [[ "$output" == *"/bin/firing"* ]]
}

@test "24 を割り切らない値は切り捨てて実際の回数を stderr に出す" {
  printf '[schedule]\nfirings_per_day = 5\nstart_hour = 0\n' > "$LOOP_DIR/config.toml"
  run "$LOOP_REAL_DIR/bin/gen-crontab"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 0,4,8,12,16,20 * * * "* ]]
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `cd .loop && npx bats tests/gen-crontab.bats`
Expected: FAIL（`bin/gen-crontab` が存在しない）

- [ ] **Step 3: `.loop/bin/gen-crontab` を書いて実行権限を付ける**

```bash
#!/usr/bin/env bash
# schedule.* から supercronic 用の crontab を生成して標準出力に書く。
# start_hour を起点に 24/firings_per_day 時間おき。24 を割り切らない値は切り捨てる。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N="$(cfg schedule.firings_per_day)"
START="$(cfg schedule.start_hour)"
[ "$N" -ge 1 ] 2>/dev/null || N=1
[ "$N" -le 24 ] 2>/dev/null || N=24

STEP=$(( 24 / N ))
[ "$STEP" -ge 1 ] || STEP=1
ACTUAL=$(( 24 / STEP ))

HOURS=""
H="$START"
I=0
while [ "$I" -lt "$ACTUAL" ]; do
  HOUR=$(( H % 24 ))
  if [ -z "$HOURS" ]; then HOURS="$HOUR"; else HOURS="$HOURS,$HOUR"; fi
  H=$(( H + STEP ))
  I=$(( I + 1 ))
done

if [ "$ACTUAL" -ne "$N" ]; then
  echo "注意: firings_per_day=$N は 24 を割り切らないため $ACTUAL 回/日に切り捨てました" >&2
fi

echo "0 $HOURS * * * $BIN_DIR/firing"
```

Run: `chmod +x .loop/bin/gen-crontab`

- [ ] **Step 4: テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/gen-crontab.bats`
Expected: 5 tests, all PASS

- [ ] **Step 5: `docker/Dockerfile` を書く**

```dockerfile
# ループを常駐させるコンテナ。
# ユーザのアプリのツールチェーンはこのファイルに足していく（seeded = 同期で上書きされない）。
FROM node:24-bookworm

ARG SUPERCRONIC_VERSION=v0.2.33

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates gnupg less procps tini \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI（DooD: ホストの docker.sock を叩いて兄弟コンテナを立てる）
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# supercronic（cron。root でなくても動き、ログを stdout に出す）
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/supercronic \
       "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${ARCH}" \
    && chmod +x /usr/local/bin/supercronic

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# ここから下にプロジェクトのツールチェーンを足す
# 例: RUN corepack enable && corepack prepare pnpm@latest --activate
# 例: RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 6: `docker/entrypoint.sh` を書く**

```bash
#!/usr/bin/env bash
# crontab を config から生成して supercronic を起動する
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
CRONTAB=/tmp/loop.crontab

if [ ! -x "$REPO_ROOT/.loop/bin/gen-crontab" ]; then
  echo "ERROR: $REPO_ROOT/.loop/bin/gen-crontab が見つかりません。" >&2
  echo "compose.yml の working_dir とマウント先が一致しているか確認してください。" >&2
  exit 1
fi

if [ ! -d "$REPO_ROOT/.loop/node_modules" ]; then
  echo "初回セットアップ: .loop の依存をインストールします"
  ( cd "$REPO_ROOT/.loop" && npm ci --omit=dev )
fi

"$REPO_ROOT/.loop/bin/gen-crontab" > "$CRONTAB"
echo "生成した crontab:"
cat "$CRONTAB"

exec supercronic -passthrough-logs "$CRONTAB"
```

- [ ] **Step 7: `docker/compose.yml` を書く**

```yaml
# ループを常駐させる。docker compose up -d で起動し、以降ターミナルは不要。
#
# ${PWD}:${PWD} でホストと同じ絶対パスにマウントしているのは意図的です。
# コンテナ内から docker compose を叩いたとき、ホストの Docker デーモンは
# ホスト側のパスしか解決できないため、パスを一致させる必要があります（DooD）。
#
# 注意: docker.sock を渡すことは、このコンテナにホストの root 相当の権限を
# 与えることを意味します。ローカル開発ツールとしての妥協です。
services:
  loop:
    build:
      context: .
      dockerfile: Dockerfile
    volumes:
      - ${PWD}:${PWD}
      - /var/run/docker.sock:/var/run/docker.sock
      - loop-claude-auth:/root/.claude
      - loop-gh-auth:/root/.config/gh
    working_dir: ${PWD}
    environment:
      - REPO_ROOT=${PWD}
      - TZ=${LOOP_TZ:-Asia/Tokyo}
    network_mode: host
    restart: unless-stopped

volumes:
  loop-claude-auth:
  loop-gh-auth:
```

- [ ] **Step 8: イメージがビルドでき、cron が起動することを確認する**

Run: `docker compose -f docker/compose.yml build`
Expected: ビルド成功

Run: `docker compose -f docker/compose.yml run --rm loop bash -lc 'gh --version && claude --version && docker --version && node --version'`
Expected: 4 つのバージョンがすべて表示される

- [ ] **Step 9: コミット**

```bash
git add .loop/bin/gen-crontab .loop/tests/gen-crontab.bats \
        docker/Dockerfile docker/compose.yml docker/entrypoint.sh
git commit -m "feat(docker): DooD 構成の 1 コンテナと supercronic による発火を追加"
```

---

### Task 14: Claude Code のスキルと設定（`/loop-mtg`, `/loop-status`）

**Files:**
- Create: `.claude/settings.json`
- Create: `.claude/skills/loop-mtg/SKILL.md`
- Create: `.claude/skills/loop-status/SKILL.md`

**Interfaces:**
- Consumes: `loop-gate`（Task 3）、`preview`（Task 12）、`firing`（Task 10）
- Produces: ターミナルの `claude` から `/loop-mtg` と `/loop-status` が使える。superpowers が trust 時にインストールを促される

- [ ] **Step 1: `.claude/settings.json` を書く**

```json
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  },
  "permissions": {
    "allow": [
      "Bash(gh issue:*)",
      "Bash(gh pr:*)",
      "Bash(git:*)",
      "Bash(.loop/bin/loop-config:*)",
      "Bash(.loop/bin/loop-gate:*)",
      "Bash(.loop/bin/preview:*)",
      "Bash(.loop/bin/firing --dry-run)"
    ]
  }
}
```

- [ ] **Step 2: `.claude/skills/loop-mtg/SKILL.md` を書く**

````markdown
---
name: loop-mtg
description: 毎日 1 回・30〜60 分の Loop ミーティング。①前回の成果を実際に動かして確認 → ②要件の対話 → ③タスク分解 → ④並列調査による設計 → ⑤Issue 化とゲート通過 → ⑥議事録。「ループミーティング」「/loop-mtg」「今日のループMTG」が合図
---

# /loop-mtg — 毎日の Loop ミーティング

ユーザー = マネージャー（意思決定者）。あなた = Loop の窓口エンジニア。
所要 30〜60 分。**1 回の MTG で複数のタスクを積むことが目的。**

このスキルの存在理由は「あ、これ違った」を減らすことです。時間の短縮ではありません。

## 進行ルール

1. 1 発言 = 1 論点 = 1 質問。3 行以内。**必ず叩き台を出す**
2. 調べられる事実は聞かない。聞くのは「決め」だけ
3. 合意していないことは実装しない
4. **MTG 中のコード変更は禁止**（書いてよいのは議事録・STATE・Issue のみ）
5. マネージャーの決定を上書きしない（技術的懸念は 1 回だけ短く述べ、決定には従う）
6. `.loop/config.toml` の `[mtg] voice` が `true` のときだけ、毎ターン
   `mcp__voicevox__text_to_speech` で読み上げる（speaker_id は `mtg.voice_speaker_id`、
   100 字以内、コード・パス・英字略語は外す。失敗しても黙って続行）。
   **既定は false。false のときは音声関連の処理を一切しない**

## ① 前回の結果を見る（必須・飛ばさない）

自分で調べる: `loops/STATE.md` / `gh pr list --state open` / `gh issue list --state open` /
`git log --oneline -10` / `git worktree list` / 直近の `loops/runs/*-verifier-pr-*.md`

open PR ごとに、この順で扱う:

1. Verifier の判定チェックリストの要点を 2 行で報告する
2. **`.loop/bin/preview pr <N>` で実際に動かし、ユーザーに触ってもらう**
   - UI のない変更、または `project.preview` が未設定の場合は、
     受け入れ基準に書かれた検証コマンドを実行して結果を見せることで代替する
3. マージ判断を仰ぐ
4. 確認が済んだら `.loop/bin/preview stop`

続けて、失敗した loop / `needs-human` の Issue / 残骸の worktree を報告する。

## ② 要件の対話

ユーザーが作りたいものを聞く。1 論点ずつ、叩き台を添えて詰める。
「何をもって完成とするか」を必ず言葉にする。

## ③ タスク分解案の提示

要件をタスクに分解して提示する。このとき**抜けている依存タスクを必ず指摘する**
（マイグレーション、設定追加、テスト基盤、型定義、ドキュメント更新など）。
ユーザーの承認を取る。

## ④ 各タスクの設計

タスクごとに Task ツールでサブエージェントを**並列に**走らせ、リポジトリを調査させる:

- 触るファイルとディレクトリ（パスを具体的に）
- 既存の似たパターン（真似すべき先行実装）
- テスト方針（どのテストファイルに何を足すか）
- 粒度の見積り（触るパス数、受け入れ基準の数）

**調査の完了を人間に待たせない。** 裏で走らせながら次の論点を進める。

調査結果をユーザーにレビューしてもらう。粒度が
`.loop/bin/loop-config get gate.max_files_touched` を超えるものは
**分割案を出して承認を取る**。

## ⑤ Issue 化 → ゲート → ready

タスクごとに下のテンプレで Issue を作る。作成後、必ず:

```
.loop/bin/loop-gate <N>
```

**通過したものにだけ** `gh issue edit <N> --add-label loop:ready` を付ける。
不合格なら本文を直して再検証する（ゲートを迂回しない）。

依存が未 close のタスクには `loop:ready` を付けない（ゲートが弾く）。

`maturity` が `L3` のとき、低リスクと**ユーザーが判断した**ものにだけ
`gh issue edit <N> --add-label loop:auto-merge` を付ける。あなたが勝手に付けない。

### Issue 本文テンプレ

```markdown
## 背景
（なぜやるか。1〜3 行）

## 受け入れ基準
- [ ] `実行ディレクトリ込みのコマンド` が緑
- [ ] 手動: （コマンドで検証できないものはこの形で書く）

## 実装方針
`触る/ファイルの/パス` を具体的に列挙する。MTG ④ の調査結果を書く。

## スコープ外
（この Issue で触ってはいけないもの。Maker の逸脱を防ぐ）

## 依存
なし（または #N）
```

## ⑥ クロージング

1. 議事録を `loops/mtg/YYYY-MM-DD.md` に保存（`## 決定` / `## 保留` / `## 作成 Issue`）
2. `loops/STATE.md` の Now / Next を更新
3. `git add loops/ && git commit -m "loop: mtg YYYY-MM-DD"`
4. 次の firing で何が起きるかを 1 行で予告する（`.loop/bin/firing --dry-run` の結果）

## 禁止

- 受け入れ基準のない Issue の作成
- `loop-gate` を通していない Issue への `loop:ready` 付与
- MTG 中のコード変更
- `loop:auto-merge` をあなたの判断で付けること
````

- [ ] **Step 3: `.claude/skills/loop-status/SKILL.md` を書く**

````markdown
---
name: loop-status
description: Loop に積まれているタスクの現在地を一覧する読み取り専用スキル。loop:ready の待ち行列、open PR と Verifier 判定、in-flight worktree、本日の dispatch 残数、次の firing の予測をまとめて表示。「/loop-status」「ループの状況」「今何が積まれてる?」が合図
---

# /loop-status — Loop の現在地

**読み取り専用。** ラベル操作・commit・ファイル書き込みは一切しない
（現状把握と決定は `/loop-mtg` の仕事）。

## 集める情報（並列で取得してよい）

1. **待ち行列**: `gh issue list --label loop:ready --state open --json number,title`
   — dispatch は番号の昇順に 1 firing 1 件。この順が実行順
2. **要人間**: `gh issue list --label needs-human --state open`
3. **レビュー待ち**: `gh pr list --state open --json number,headRefName,title,reviewDecision`
   の `loop/issue-*`。各 PR に対応する `loops/runs/*-verifier-pr-<N>.md` の末尾の結論を 1 行添える
4. **in-flight**: `git worktree list` の `-issue-<N>`（Maker 作業中、または残骸）
5. **本日の残数**: `ls loops/runs/<今日>-maker-*.md | wc -l` と
   `.loop/bin/loop-config get loop.max_dispatch_per_day` / `loop.max_open_prs`
6. **次の firing の予測**: `.loop/bin/firing --dry-run` を実行してそのまま示す
7. **プレビュー**: `.loop/bin/preview status`

## 出力フォーマット

```
## Loop の現在地（HH:MM 時点）
| 順 | Issue | タイトル | 状態 |

要人間: （あれば列挙、なければ「なし」）
本日 dispatch: X/N（open PR Y/M）
次の firing: （--dry-run の 1 行）
プレビュー: （status の 1 行）
```

表は 1 画面に収める。タイトルは 40 字で切る。音声読み上げはしない（即答性優先）。
````

- [ ] **Step 4: スキルのフロントマターが正しいことを確認する**

Claude Code はフロントマターの `name` と `description` でスキルを認識します。
両方が存在し、`name` がディレクトリ名と一致することを確認します。

Run:

```bash
for d in .claude/skills/*/; do
  n="$(basename "$d")"
  node -e '
    const fs=require("fs");
    const [dir,name]=process.argv.slice(1);
    const t=fs.readFileSync(dir+"/SKILL.md","utf8");
    const m=/^---\n([\s\S]*?)\n---/.exec(t);
    if(!m) throw new Error(name+": フロントマターがない");
    if(!/^name:\s*/m.test(m[1])) throw new Error(name+": name がない");
    if(!/^description:\s*/m.test(m[1])) throw new Error(name+": description がない");
    const got=/^name:\s*(.+)$/m.exec(m[1])[1].trim();
    if(got!==name) throw new Error(name+": name がディレクトリ名と不一致 ("+got+")");
    console.log(name+" OK");
  ' "$d" "$n"
done
```

Expected: `loop-mtg OK` と `loop-status OK` が出力され、終了コード 0

- [ ] **Step 5: `claude` がスキルを読み込めることを対話で確認する（人間が実施）**

`claude` を起動し、`/` を打ってサジェストに `loop-mtg` と `loop-status` が出ることを目視で確認する。
出ない場合は `.claude/skills/<name>/SKILL.md` の配置とフロントマターを見直す。

- [ ] **Step 6: コミット**

```bash
git add .claude/settings.json .claude/skills
git commit -m "feat(skills): /loop-mtg と /loop-status を追加、superpowers を宣言"
```

---

### Task 15: 初期ドキュメントと所有境界、統合テスト

**Files:**
- Create: `.loop/OWNERSHIP.toml`, `.loop/VERSION`, `.loop/skills/run-a-loop.md`
- Create: `loops/STATE.md`, `loops/DECISIONS.md`, `loops/INCIDENTS.md`, `loops/mtg/.gitkeep`, `loops/runs/.gitkeep`
- Create: `CLAUDE.md`, `README.md`
- Test: `.loop/tests/integration.bats`

**Interfaces:**
- Consumes: すべてのタスク
- Produces: クローンしてすぐ使える状態のテンプレート一式と、1 サイクルを通す統合テスト

- [ ] **Step 1: `.loop/OWNERSHIP.toml` と `.loop/VERSION` を書く**

`.loop/OWNERSHIP.toml`:

```toml
# テンプレート同期（P5）の所有境界。上から順に評価し、最初に一致したルールを適用する。
#
#   template = テンプレート所有。同期で常に上書きする
#   seeded   = テンプレートが初期版だけ置く。同期では絶対に触らない（新版があれば通知のみ）
#   user     = ユーザー所有。テンプレートは存在を関知しない

[[rules]]
kind = "seeded"
paths = [
  ".loop/config.toml",
  "docker/Dockerfile",
  "CLAUDE.md",
  ".claude/settings.json",
]

[[rules]]
kind = "template"
paths = [
  ".loop/**",
  ".claude/skills/**",
  "docker/compose.yml",
  "docker/entrypoint.sh",
  "README.md",
]

[[rules]]
kind = "user"
paths = ["**"]
```

`.loop/VERSION`:

```
0.1.0
```

- [ ] **Step 2: `.loop/skills/run-a-loop.md` を書く**

```markdown
# Skill: Loop 実行の共通手順

すべてのループ（Maker / Verifier / Fixer）が従う骨格。
タスクの選定と設計は毎日の `/loop-mtg`（人間とのミーティング）が担い、
`loop:ready` の付いた GitHub Issue がループへの正式な入口です。

1. **予算ゲートがステップゼロ**（スクリプトが自動実行する）。超過なら即終了
2. **`loops/STATE.md` を読む** — Now / Next / Blocked を把握してから動く
3. **自分の仕事だけをする** — プロンプトに書かれたスコープ、および Issue の
   「スコープ外」に書かれた境界を越えない
4. **`loops/STATE.md` の更新は最後に 1 回だけ** — 途中で書かない（中断安全）
5. **困ったら人間へ** — 判断不能・スコープ疑義は `needs-human` ラベル。勝手に決めない

## Safe-Stop Protocol

作業は小さい単位に分割し、単位の完了ごとにコミットする。
停止は常に安全であること — 現在の単位を完了するかクリーンに破棄し、
再開ポイントを記録し、merge 途中の worktree を残さない。

継続性はセッションではなく State の背骨が担っているので、
いつ止まっても次の実行が続きを引き継げる。
```

- [ ] **Step 3: `loops/` の初期ファイルを書く**

`loops/STATE.md`:

```markdown
# STATE（最終更新: セットアップ時）

## Now
- ハーネスをセットアップしたところ。まだタスクは積まれていない
- 最初の `/loop-mtg` で最初のタスクを決める

## Next
- `.loop/config.toml` の `[project]` に test / lint / preview コマンドを書く
- `docker/Dockerfile` にプロジェクトのツールチェーンを足す
- `CLAUDE.md` にビルド手順と規約を書く
- `maturity = "L1"` で数回 firing を観察してから `L2` に上げる

## Blocked
- （なし）

## Done（直近 7 日）
- （なし）

## Budget
```

`loops/DECISIONS.md`:

```markdown
# DECISIONS（設計判断の追記専用ログ）

決着した議論を蒸し返さないための記録。形式: 日付 / 決定 / 理由。

## 成熟度ラダーについて

| | 動作 |
|---|---|
| L1 | firing は判定と報告だけ。dispatch しない |
| L2 | Maker → PR → Verifier まで自動。**merge は人間**（既定） |
| L3 | Verifier approve かつ `loop:auto-merge` ラベルがあれば自動 merge |

**L1 から始める。** 信頼は実績で獲得する。最初から L3 を与えない。
L3 のラベル限定は「低リスクの雑務のみ自動 merge する」を機械的に効かせるためのもの。
自動 merge は「あ、これ違った」の検出を事後にし、巻き戻しコストを上げる。
```

`loops/INCIDENTS.md`:

```markdown
# INCIDENTS（誤動作の記録とガード）

記録形式: 事象 / 影響 / 原因 / 追加したガード。
**ガードを入れてからループを再開する。** これがループを時間とともに安全にする仕組み。

---

## 既知の落とし穴（テンプレート同梱。参考実装で実際に起きたもの）

このテンプレートには、以下の 4 件に対するガードが最初から入っています。
似た事象が起きたときの参考にしてください。

### K1: dispatch の実行ログが未コミットのまま作業ツリーに残る
- **原因:** ログを `tee` で書くだけで、コミット処理がなかった
- **ガード:** ログは `loops/runs/` に書き、STATE の更新とあわせて人間が commit する

### K2: Verifier 起動が手動だと maker/checker 分離が形骸化する
- **原因:** 人間の朝のルーティンに定着しなかった
- **ガード:** `dispatch-maker` が PR 作成後に `dispatch-verifier` を自動チェーンする

### K3: `gh pr checkout` がブランチ二重 checkout で失敗する
- **原因:** PR の head ブランチを Maker の worktree が保持しており、
  git は同一ブランチの二重 checkout を拒否する
- **ガード:** `dispatch-verifier` は `gh pr checkout <N> --detach` を使う

### K4: stale な local main から branch を切るとコンフリクトする
- **原因:** PR のマージは GitHub 上で起きるが、local main を同期する処理がなかった
- **ガード:** `firing` の冒頭（cleanup の前）で `git fetch origin` +
  `git merge --no-edit origin/main`。コンフリクト時は abort して fail-closed

---

## このプロジェクトのインシデント

（ここに追記していく）
```

Run: `mkdir -p loops/mtg loops/runs && touch loops/mtg/.gitkeep loops/runs/.gitkeep`

- [ ] **Step 4: `CLAUDE.md`（雛形）を書く**

```markdown
# CLAUDE.md

このファイルはあなた（プロジェクトの所有者）が育てるものです。
テンプレート同期では上書きされません。

## このプロジェクトは何か

（1〜3 行で書く）

## ビルドとテスト

```bash
# 依存のインストール
# テスト
# lint
# 開発サーバ
```

これらは `.loop/config.toml` の `[project]` にも同じものを書いてください。
ループはそこから読み取ります。

## コード規約

（命名、ディレクトリ構成、使っているフレームワークの流儀）

## Definition of Done

- [ ] テストが緑
- [ ] lint が緑
- [ ] 受け入れ基準をすべて満たしている
- [ ] Issue の「スコープ外」に手を出していない

## ループについて

このリポジトリは Loop Engineering のハーネスを持っています。

- 毎日 `claude` を開いて `/loop-mtg` を実行する（30〜60 分）
- 状況を見るだけなら `/loop-status`
- ハーネスの設定は `.loop/config.toml`
- 詳細は `README.md`
```

- [ ] **Step 5: `README.md` を書く**

````markdown
# dev-loop

開発用 Loop Engineering テンプレート。GitHub Issue を入口に、
Maker → Verifier → 人間の merge が 1 日に複数回自動で回ります。

人間の役割はマネージャーです。1 日 1 回の朝会（`/loop-mtg`）に出席し、
前日の成果を確認して、次のタスクを積みます。

## 必要なもの

- Docker（Docker Desktop など）
- GitHub アカウントとこのリポジトリの push 権限
- Claude Code のサブスクリプション

対象は **macOS / Linux** です。Windows は WSL2 の中で使ってください。

## セットアップ（ターミナルを使うのはここだけ）

```bash
docker compose -f docker/compose.yml up -d --build
docker compose -f docker/compose.yml exec loop claude      # ブラウザでログイン
docker compose -f docker/compose.yml exec loop gh auth login
```

続いて、この 3 つを自分のプロジェクトに合わせて編集します。

1. `.loop/config.toml` の `[project]` — test / lint / preview コマンド
2. `docker/Dockerfile` — プロジェクトのツールチェーン（追記して `--build` で再ビルド）
3. `CLAUDE.md` — ビルド手順と規約

## 使い方

毎日 1 回、ターミナルで `claude` を開いて:

```
/loop-mtg
```

状況を見るだけなら `/loop-status`。

## 最初は L1 から

`.loop/config.toml` の `maturity` は最初 `"L1"` にして、数回の firing で
「ループが何をしようとしているか」を `loops/STATE.md` で観察してください。
納得できたら `"L2"` に上げます。

| | 動作 |
|---|---|
| `L1` | 判定と報告だけ。何も実行しない |
| `L2` | Maker → PR → Verifier まで自動。merge は人間 |
| `L3` | 上記に加え、`loop:auto-merge` ラベル付きの approve 済み PR を自動 merge |

## 設定

触るのは `.loop/config.toml` 1 枚だけです。
全キーと説明は `.loop/defaults.toml` にあります（こちらは編集しないでください。
テンプレート同期で上書きされます）。

## セキュリティ上の注意

`docker/compose.yml` はコンテナに `/var/run/docker.sock` を渡しています。
これは、あなたのアプリが Docker を使う場合に、ループコンテナから
**ホスト上に兄弟コンテナを立てる**ため（DooD）に必要です。入れ子の Docker にはなりません。

ただし **docker.sock を渡すことは、そのコンテナにホストの root 相当の権限を
与えることを意味します。** ローカル開発ツールとしての妥協です。
許容できない場合は `compose.yml` から該当行を削除してください
（アプリが Docker を使わないなら削除して問題ありません）。

## テスト

```bash
cd .loop && npm install && npx bats tests/
```

## ディレクトリ

| | |
|---|---|
| `.loop/` | ハーネス本体。`config.toml` 以外は編集しない |
| `loops/` | 状態の背骨。STATE / DECISIONS / INCIDENTS / 議事録 / 実行ログ |
| `docker/` | コンテナ定義 |
````

- [ ] **Step 6: 統合テストを書く**

`.loop/tests/integration.bats`:

```bash
#!/usr/bin/env bats
# 1 サイクル（ready な Issue → gate → Maker → PR → Verifier）を
# mock provider と gh スタブで通す。

load helpers

setup() {
  TMP="$(mktemp -d)"
  REPO_ROOT="$TMP/repo"
  export REPO_ROOT
  mkdir -p "$REPO_ROOT/loops/runs" "$REPO_ROOT/loops/mtg"
  printf '# STATE\n' > "$REPO_ROOT/loops/STATE.md"
  LOOP_DIR="$(make_loop_dir "$REPO_ROOT/.loop")"
  export LOOP_DIR
  cp "$BATS_TEST_DIRNAME/fixtures/agents/mock.sh" "$LOOP_DIR/agents/mock.sh"
  chmod +x "$LOOP_DIR/agents/mock.sh"
  cp "$LOOP_REAL_DIR/prompts/"*.md "$LOOP_DIR/prompts/"
  printf '[agent]\nprovider = "mock"\n\n[project]\ntest = "true"\nlint = "true"\n' \
    > "$LOOP_DIR/config.toml"

  git -C "$REPO_ROOT" init -q -b main
  git -C "$REPO_ROOT" config user.email t@example.com
  git -C "$REPO_ROOT" config user.name t
  echo one > "$REPO_ROOT/a.txt"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm init

  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin/gh"
  PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export PATH
  GH_LOG="$TMP/gh.log"; export GH_LOG
  LOOP_SKIP_FETCH=1; export LOOP_SKIP_FETCH
  LOOP_CCUSAGE_CMD="$BATS_TEST_DIRNAME/fixtures/ccusage/ok.sh"; export LOOP_CCUSAGE_CMD
}

teardown() {
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$TMP"
}

@test "1 サイクルが完走する: gate 通過 → Maker → PR 検出 → Verifier" {
  GOOD_BODY="$(cat "$BATS_TEST_DIRNAME/fixtures/issues/good.md")"
  export GH_ISSUE_LIST_JSON='[{"number":5}]'
  export GH_ISSUE_JSON="$(node -e 'process.stdout.write(JSON.stringify({body:process.argv[1],state:"OPEN"}))' "$GOOD_BODY")"
  export GH_PR_LIST_JSON='[{"number":40,"headRefName":"loop/issue-5","reviewDecision":null,"labels":[]}]'

  run "$LOOP_REAL_DIR/bin/firing"
  [ "$status" -eq 0 ]

  # Maker が走った
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-maker-issue-5.md" ]
  # Verifier が走った
  [ -f "$REPO_ROOT/loops/runs/$(date +%Y-%m-%d)-verifier-pr-40.md" ]
  # STATE に両方が記録された
  run cat "$REPO_ROOT/loops/STATE.md"
  [[ "$output" == *"maker issue-5 ok"* ]]
  [[ "$output" == *"verifier pr-40 ok"* ]]
  # merge はしていない（L2）
  run cat "$GH_LOG"
  [[ "$output" != *"pr merge"* ]]
}
```

- [ ] **Step 7: 全テストを実行して通過を確認する**

Run: `cd .loop && npx bats tests/`
Expected: 全 bats ファイルが PASS（ユニット + 統合、合計 60 件前後）

- [ ] **Step 8: コミット**

```bash
git add .loop/OWNERSHIP.toml .loop/VERSION .loop/skills/run-a-loop.md \
        .loop/tests/integration.bats loops/ CLAUDE.md README.md
git commit -m "feat(template): 初期ドキュメント・所有境界・統合テストを追加"
```

- [ ] **Step 9: 実リポジトリでの手動スモークテスト（人間が実施）**

自動テストは `gh` をスタブしているため、GitHub との実際のやり取りは検証していません。
最後に人間が 1 回だけ実リポジトリで確認します。

1. GitHub に空のプライベートリポジトリを作り、このテンプレートを push する
2. `docker compose -f docker/compose.yml up -d --build` と 2 つのログインを済ませる
3. `.loop/config.toml` の `[project]` を埋める
4. `claude` で `/loop-mtg` を実行し、小さな Issue を 1 件作って `loop:ready` まで付ける
5. `.loop/bin/firing --dry-run` が `#N を dispatch する` と言うことを確認する
6. `maturity = "L2"` にして `.loop/bin/firing` を手で 1 回叩く
7. PR が作られ、Verifier のチェックリストコメントが付くことを確認する
8. `.loop/bin/preview pr <N>` でアプリが `localhost:<port>` に出ることを確認する
9. 人間が merge → 次の firing で worktree と branch が片付くことを確認する

うまくいかなかった点は `loops/INCIDENTS.md` に記録し、
**ガードを入れてからループを再開する。**

---

## 自己レビューの結果

spec の各節を実装タスクに対応付けた結果:

| spec の節 | 対応するタスク |
|---|---|
| §4 構成と所有境界 | Task 1（骨格）、Task 15（OWNERSHIP.toml） |
| §5 config 2 層 | Task 1 |
| §6 実行環境（DooD・認証・cron） | Task 13 |
| §7.1 `/loop-mtg` | Task 14 |
| §7.2 `loop-gate` | Task 3 |
| §7.3 `firing` | Task 10, 11 |
| §7.4 成熟度ラダー L1/L2/L3 | Task 7（L1 拒否）、Task 10（L1 報告）、Task 11（L3 merge） |
| §7.5 provider 抽象 | Task 4 |
| §7.6 Maker / Verifier / Fixer | Task 7, 8, 9 |
| §7.7 プレビュー | Task 12 |
| §8 状態の背骨 | Task 2（`record_state`）、Task 15（初期ファイル） |
| §9 安全装置 | Task 5（予算 fail-closed）、Task 7/8（中断検知・リトライ）、Task 15（INCIDENTS） |
| §10 テスト戦略 | 各タスクの bats、Task 10（`--dry-run`）、Task 15（統合） |
| §11 受け入れ基準 | 全タスク + Task 15 Step 9 の手動スモーク |

**spec との差分（意図的なもの）:**

- spec §5.2 では `daily_tokens = 120_000_000` とアンダースコア区切りで書いたが、
  実装では `120000000` にする（TOML の仕様上どちらも有効だが、パーサ依存の疑いを残さない）
- spec §7.3 の「fix 待ちの PR を最優先 dispatch」は、実装では Task 10 ではなく
  Task 11 で `firing` に追加する（Task 10 を単体でテストできる大きさに保つため）
- 自動修正のラウンド数は別カウンタを持たず、
  `loops/runs/<date>-fixer-pr-<N>-r<round>.md` の存在数で数える（状態を増やさないため）
