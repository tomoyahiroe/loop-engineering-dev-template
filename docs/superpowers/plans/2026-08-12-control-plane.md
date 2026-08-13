# P3 コントロールプレーン（観測カット）実装計画

設計書: `docs/superpowers/specs/2026-08-12-control-plane-design.md`

## Global Constraints

1. **seeded 境界を越えない。** `docker/Dockerfile`・`.loop/config.toml`・
   `.claude/settings.json`・`CLAUDE.md` は 1 バイトも変更しない。
   新しい設定キーは `defaults.toml`（template 所有）にのみ足す
2. **node 標準ライブラリのみ。** `.loop/package.json` に依存を追加しない。
   フロントもビルド工程なし
3. **層構造を守る。** 判定・整形は純関数（`*.mjs`）、I/O は CLI（`*-cli.mjs`）、
   制御フローは bash、人間向けの表現はスキル。既存の
   `config.mjs`/`config-cli.mjs`、`gate.mjs`/`gate-cli.mjs` と同じ形にする
4. **bash で JSON を組み立てない。** `gate_out` は複数行を含み、メッセージには
   引用符が入る。タイムスタンプも `date -Is` が BSD date（macOS）にないため
   使えない（firing はコンテナ内 Debian で動くが、bats はホストの macOS で走る）。
   **両方 node 側で処理する**
5. 既存テストを壊さない（着手時点で 297 件。設計書が引用している「213 件」は
   P1 当時の数字で、現在は増えている）

## File Structure

```
新規 [T]
  .loop/lib/events.mjs           純関数: 1 行の組み立て・パース・末尾 N 件
  .loop/lib/events-cli.mjs       I/O: append / tail
  .loop/lib/control-plane.mjs    HTTP サーバ本体
  .loop/bin/control-plane        起動スクリプト（bash）
  .loop/web/index.html
  .loop/web/app.js
  .loop/web/app.css
  .loop/tests/events.bats
  .loop/tests/control-plane.bats

変更 [T]
  .loop/lib/common.sh            record_event() を追加
  .loop/bin/firing               record_event() を 9 経路に配線
  .loop/defaults.toml            [ui] セクション
  docker/entrypoint.sh           supercronic の前にサーバを起動
  .claude/skills/loop-status/SKILL.md   API を叩く形に書き換え
  .loop/tests/skill-references.bats     照合を追加

変更 [U]
  .gitignore                     loops/events.jsonl

変更しない [S]
  docker/Dockerfile / .loop/config.toml / .claude/settings.json / CLAUDE.md
docker/compose.yml も変更しない（設計書 §3.1 で検証済み）
```

---

## Task 0: host networking の検証 — **完了済み（2026-08-12）**

設計書 §3.1 に結果を記録した。ホスト → `127.0.0.1:7717` は到達、
LAN → 同ポートは到達しない。`docker/compose.yml` の変更は不要。

---

## Task 1: `events.mjs` / `events-cli.mjs` — **完了（2026-08-12）**

実装中に計画になかった不具合を 1 件見つけて直した。**切れた行の直後の追記が、
そのイベントごと失われる**問題。コンテナが書き込みの途中で kill されると最終行に
改行がなく、次の tick の追記がその行に連結されて 2 件とも壊れる（kill 1 回で
2 件消える）。`appendFileSync` の前に末尾バイトを見て、改行がなければ先頭に
改行を足すようにした。ファイル全体は読まない（ログは増え続けるため）。
回帰テスト「切れた行の直後の追記が、そのイベントごと失われない」を追加済み。


### `.loop/lib/events.mjs`（純関数・I/O なし）

```js
// firing の各 tick を 1 行の JSON にする。I/O はしない（events-cli.mjs の仕事）。
//
// STATE.md ではなくこのログを API の源にしている理由は設計書の決定 1 を見る。
// 要点: record_state は日付しか持たず、追記が末尾に積まれるため実際には
// "## Budget" 見出しの下に溜まり、内容は日本語の散文になっている。

// kind の値域。firing の終了経路と 1 対 1 に対応する。
// ここを増やしたら firing 側にも配線する（tests/events.bats が照合する）
export const KINDS = [
  'conflict',
  'automerge', 'automerge_failed',
  'fix', 'fix_exhausted',
  'idle',
  'skip',
  'gate_failed', 'gate_retry',
  'report',
  'dispatch',
];

// ISO 8601 をオフセット付きで作る。date -Is は GNU 拡張で BSD date にないため
// シェルではなくここで作る（テストはホストの macOS で走る）
export function stamp(now = new Date()) {
  const off = -now.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  const p = (n) => String(Math.floor(Math.abs(n))).padStart(2, '0');
  return now.getFullYear()
    + '-' + p(now.getMonth() + 1) + '-' + p(now.getDate())
    + 'T' + p(now.getHours()) + ':' + p(now.getMinutes()) + ':' + p(now.getSeconds())
    + sign + p(off / 60) + ':' + p(off % 60);
}

// 1 行分の JSON 文字列を作る。改行は JSON.stringify が \n にエスケープするので
// jsonl が壊れない（gate_out は複数行を含む）
export function buildLine(kind, fields = {}, now = new Date()) {
  if (!KINDS.includes(kind)) throw new Error(`unknown kind: ${kind}`);
  const clean = {};
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null || v === '') continue;
    clean[k] = v;
  }
  return JSON.stringify({ ts: stamp(now), kind, ...clean });
}

// 壊れた行はスキップする。コンテナが書き込みの途中で kill されると
// 最終行が切れる。1 行の破損で履歴全体が読めなくなってはいけない
export function parseLines(text) {
  const out = [];
  for (const line of String(text).split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const o = JSON.parse(s);
      if (o && typeof o === 'object' && typeof o.kind === 'string') out.push(o);
    } catch { /* 破損行は捨てる */ }
  }
  return out;
}

// 新しい順に N 件
export function tail(text, limit = 50) {
  const all = parseLines(text);
  const n = Number.isFinite(limit) && limit > 0 ? Math.floor(limit) : 50;
  return all.slice(-n).reverse();
}
```

### `.loop/lib/events-cli.mjs`

`append` は追記のみ。**書き込み失敗で firing を落とさない**（観測のためのログが
ループ本体を止めるのは本末転倒）。失敗は stderr に出して終了コード 0 で抜ける。

```
用法:
  events-cli.mjs append --kind <kind> [--field k=v ...]   # REPO_ROOT/loops/events.jsonl に追記
  events-cli.mjs tail [--limit N]                          # JSON 配列を stdout へ
```

数値に見える値（`issue`, `pr`, `open_prs` など）は数値に変換する。
`--field` の値に `=` が含まれる場合は最初の `=` だけで分割する（`msg=a=b` を壊さない）。

### テスト `.loop/tests/events.bats`

- `buildLine` が未知の kind を弾く
- 複数行を含む `gate_out` を渡しても出力が 1 行に収まる
- 破損した最終行があっても `tail` が残りを返す
- `tail --limit` が新しい順であること
- `stamp` がオフセット付きの ISO 8601 になること
- **`KINDS` と `firing` が実際に渡す kind が一致すること**（Task 2 と対で最重要）

---

## Task 2: `record_event` と firing への配線 — **完了（2026-08-12）**

11 kind すべてを配線し、双方向の照合テストをミューテーションで検証した
（firing に未知の kind を混ぜると 2 件とも落ち、KINDS にだけ足すと
「配線忘れ」を見るほうだけが落ちる）。過去 2 回踏んだ「照合が空集合どうしの
比較になっていて常に通る」バグは、非空ガードとこの変異確認の両方で塞いだ。

`firing` 冒頭の「何もすることがなければ何も記録せず終了する」というコメントは
実態とズレるので書き換えた。既存テスト名「ready な Issue がなければ何も記録せず
0 で終わる」も同様に更新した（STATE には書かないが events には書く）。


### `.loop/lib/common.sh`

`record_state` の直後に足す。既存の `record_state` は消さない（STATE.md は
人間が MTG で読むためのもの。設計書の決定 3）。

```bash
# loops/events.jsonl に 1 行追記する。$1 = kind、$2 以降 = k=v
#
# 観測のためのログなので、失敗してもループ本体を止めない。JSON の組み立てと
# タイムスタンプは node 側でやる（bash で JSON を組むと gate_out の複数行と
# 引用符で壊れ、date -Is は macOS の BSD date にない）
record_event() {
  local kind="$1"; shift
  local args=()
  local kv
  for kv in "$@"; do args+=(--field "$kv"); done
  REPO_ROOT="$REPO_ROOT" node "$LIB_DIR/events-cli.mjs" append \
    --kind "$kind" "${args[@]}" 2>/dev/null || true
}
```

### `.loop/bin/firing` の配線

設計書 §4 の対応表の通り、9 経路すべてに置く。`record_state` があるところは
併置、ないところ（`idle`・`gate_retry`）は `record_event` だけを置く。

| 行 | 追加する呼び出し |
|---|---|
| `:25` | `record_event conflict` |
| `:124` | `record_event automerge "pr=$MPR" "issue=$MISSUE"` |
| `:133` | `record_event automerge_failed "pr=$MPR" "issue=$MISSUE"` |
| `:84` | `record_event fix_exhausted "pr=$FPR" "issue=$FISSUE" "round=$DONE_ROUNDS"` |
| `:95` | `record_event fix "pr=$FPR" "issue=$FISSUE" "round=$NEXT_ROUND"` |
| `:141` | `record_event idle`（**現在は無記録で `exit 0`**） |
| `:148` | `record_event skip "reason=open_prs" "issue=$NEXT_ISSUE" "open_prs=$N_OPEN" "max_prs=$MAX_PRS"` |
| `:153` | `record_event skip "reason=daily" "issue=$NEXT_ISSUE" "today=$N_TODAY" "max_today=$MAXD"` |
| `:161` | `record_event skip "reason=budget" "issue=$NEXT_ISSUE" "msg=$GATE_OUT"` |
| `:175`(実行は`:220`付近) | `record_event gate_failed "issue=$NEXT_ISSUE" "gate_out=$GOUT"` |
| `:194` | `record_event gate_retry "issue=$NEXT_ISSUE"`（**現在は無記録**） |
| `:236` | `record_event report "issue=$NEXT_ISSUE" "maturity=$MATURITY"` |
| `:247` | `record_event dispatch "issue=$NEXT_ISSUE" "open_prs=$N_OPEN" "today=$N_TODAY"` |

**`--dry-run`（`DRY=1`）の経路では記録しない。** 既存の `record_state` が
DRY で呼ばれないのと同じ扱いにする。DRY は「何が起きるかを見る」ためのもので、
履歴を汚してはいけない。

`gate_failed` は `record_state` と同じ位置（マーカー書き込みの後、
`loop:ready` 除去の前）に置く。`:190-196` の「remediate 済みで静かに抜ける」
経路とは別扱いにするのが `gate_retry` を分けた理由。

### テスト（`events.bats` に含める）

**kind 値域の機械照合。** これが Task 1・2 で一番重要なテスト。

```bash
@test "firing が渡す kind は events.mjs の KINDS に含まれる" {
  # firing から record_event の第 1 引数を抜く
  local used
  used="$(grep -oE 'record_event [a-z_]+' "$LOOP_REAL_DIR/bin/firing" \
          | awk '{print $2}' | sort -u)"
  [ -n "$used" ]   # 抽出が空回りしていないこと（skill-references.bats の教訓）

  local known
  known="$(node -e '
    import("'"$LOOP_REAL_DIR"'/lib/events.mjs").then(m =>
      console.log(m.KINDS.join("\n")))' | sort -u)"

  local missing
  missing="$(comm -23 <(echo "$used") <(echo "$known"))"
  [ -z "$missing" ]
}

@test "KINDS のうち firing が使っていないものがない" {
  # 逆向き。値域だけ増やして配線を忘れるのを防ぐ
  ...
}
```

`[ -n "$used" ]` の非空ガードは必須。`cc0be7c` と `65fbf46` で、
抽出が空回りしていて照合が常に通っていたバグを 2 回踏んでいる。

さらに firing の統合テスト（`firing-chain.bats` に追加）:

- ready な Issue がない tick で `idle` が 1 行記録される
- L1 の tick で `report` が記録され、**STATE.md への追記も従来通り残る**
- `--dry-run` では events.jsonl が増えない

---

## Task 3: HTTP サーバ — **完了（2026-08-12）**

計画では `control-plane.mjs` 1 本だったが、テストしたい判定が多いので
`control-plane.mjs`（純関数）と `control-plane-cli.mjs`（HTTP と子プロセス）に
分けた。既存の `gate.mjs`/`gate-cli.mjs` と同じ形。

実装中に見つけて直したもの:

- **`bin/` と `web/` を設定の所在（`LOOP_DIR`）から引いていた。** `common.sh`
  冒頭が定めている「コードの所在と設定の所在を分ける」原則を破っており、
  fixture 設定を使うテストで `gen-crontab` と `budget-check` を見失っていた
- 子プロセスが ENOENT で落ちると stderr が空のまま返り、画面に
  「取得できません: 」とだけ出て原因が分からなかった。エラーコードを拾うようにした

テストの足回りで踏んだもの:

- **bats は FD 3 を自身の出力に使う。** 常駐する子プロセスがそれを継承すると
  テスト完了を検出できず、スイート全体がハングする。`3>&-` が必須
- **bats はテスト本体を teardown とは別のサブシェルで走らせる。** テスト内で
  代入した PID は teardown から見えない。ポート番号で落とす方式にした。
  これを直す前は 1 回の実行で 16 個のサーバが残り、次の実行が前回の残骸
  （別の fixture を見ている）に問い合わせて謎の失敗が並んでいた

### Task 3 の後で見つかった不具合（Task 6 着手時に発見・修正済み）

`/api/status` の `dispatched_today` を **events の `dispatch` を数えて**
実装していたが、`firing` は `loops/runs/<日付>-maker-issue-*.md`（`.retry.md`
を除外）を数える。**P1 の「/loop-status 集計ズレ」と同じ型の事故を、新しい
場所で作り込んでいた。** 加えて日付を `toISOString()`（UTC）で出しており、
JST では午前 9 時前に毎朝 1 日ずれる。

どちらも修正し、`countDispatchedToday` / `localDate` として純関数に切り出して、
実データで firing の式と突き合わせるテストを追加した。

### `.loop/lib/control-plane.mjs`

`node:http` のみ。すべて GET。

```js
const HOST = '127.0.0.1';   // 0.0.0.0 にしない（設計書の決定 5）
```

エンドポイントは設計書 §5 の表の通り。実装上の注意:

1. **`budget-check` の終了コードで捨てない。** fail-closed の SKIP でも
   表示は必要なので、非 0 のときは `SKIP:` 行を `reason` として返す。
   `BUDGET: used=N limit=N` が出ていればそれも併せて返す
2. **gh 呼び出しは短期キャッシュ**（`[ui] cache_seconds`、既定 30 秒）。
   プロセス内 Map のみ。ポーリングのたびに叩くと体感が遅く、レート制限も減る
3. **`GET /api/runs/:name` と静的配信でパスを正規化する。**
   `..` とスラッシュ始まりを拒否し、`path.resolve` した結果が
   それぞれ `loops/runs` / `.loop/web` の下にあることを確認する。
   basename 一致だけの検査にしない
4. **子プロセスの実行は `execFile`（シェルを経由しない）。** タイムアウトを
   付ける（gh がハングしたら UI ごと固まる）
5. `next_firing` は `gen-crontab` の出力から次の発火時刻を算出する。
   crontab を自前でパースせず、既存の生成結果を使う

### `.loop/bin/control-plane`

```bash
#!/usr/bin/env bash
# コントロールプレーン（観測 UI）を起動する。
# 用法: control-plane [--port N]
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
PORT="${1:-$(cfg ui.port)}"
exec node "$LIB_DIR/control-plane.mjs" --port "$PORT"
```

### `.loop/defaults.toml`

```toml
[ui]
# コントロールプレーン（観測 UI）。127.0.0.1 にのみ bind する
port = 7717
# ブラウザ側のポーリング間隔（秒）
poll_seconds = 10
# gh 呼び出しのキャッシュ（秒）。レート制限と体感速度のため
cache_seconds = 30
```

`config.toml`（seeded）は触らない。この 2 層構造により、新キーは派生
プロジェクトに `defaults.toml` の同期だけで降りる。

### テスト `.loop/tests/control-plane.bats`

`loop-doctor.bats` が ccusage をスタブしているのと同じ形で `gh` をスタブする。

- `/api/status` が maturity と budget を返す
- `budget-check` が非 0 でも 200 が返り、`reason` に SKIP が入る
- `/api/events` が新しい順で `limit` を尊重する
- `/api/runs/../../etc/passwd` が 400 で拒否される
- 静的配信で `../` が拒否される
- gh が失敗しても 500 にせず、その部分だけ欠けた JSON を返す
  （UI 全体が真っ白になるのを防ぐ）

---

## Task 4: UI（`.loop/web/`）— **完了（2026-08-12）**

ブラウザで実データを描画して確認した（API が 200 を返すことと画面が出ることは
別物なので、目視を省かない）。正常時の描画、コンソールエラーなし、サーバを
落とした状態での警告表示まで見た。行内リンクの下線が flex 幅いっぱいに伸びて
罫線に見えていたのを修正。これは API のテストでは絶対に出てこない種類の問題。

`KIND_LABEL` が `KINDS` を網羅していること、`app.js` が叩く API パスが
サーバに実在することを照合するテストを追加（どちらも変異で確認済み）。

1 枚の HTML + `app.js` + `app.css`。ビルド工程なし。

- `fetch` で 3 エンドポイントを `[ui] poll_seconds` ごとに取得
- 上から: サマリ（トークン消費バー・maturity・open PR・次の firing）→
  成否履歴（時刻付き・新しい順）→ Issues（ready / needs-human / その他）
- **サーバが落ちている / 応答が古いことを画面に出す。** 黙って古い値を
  表示し続けるのが観測 UI として一番悪い
- Issue と PR は GitHub へのリンクにする（詳細はブラウザで見れば済む）

---

## Task 5: コンテナへの同居 — **完了（2026-08-12）**

`entrypoint.sh` はコンテナ前提で bats から直接動かせないため、参照している
実行ファイルと設定キーが実在することを `skill-references.bats` で照合する形に
した。コンテナ内での実起動確認は Task 7 に集約する（そこで再起動するため）。

## Task 5 の実装内容

`docker/entrypoint.sh` の `exec supercronic` の**手前**に足す。

```bash
# コントロールプレーン（観測 UI）を起動する。ここでの失敗は cron を止めない
# （UI が落ちてもループ本体は回り続けるべき）。失敗はログにだけ残す
if [ -x "$LOOP_DIR/bin/control-plane" ]; then
  "$LOOP_DIR/bin/control-plane" >>/tmp/control-plane.log 2>&1 &
  echo "コントロールプレーンを起動しました: http://127.0.0.1:$("$LOOP_DIR/bin/loop-config" get ui.port 2>/dev/null || echo 7717)"
else
  echo "警告: control-plane が見つかりません。観測 UI なしで続行します" >&2
fi
```

`-x` チェックを挟むのは、**古い `.loop` を持つ派生プロジェクトでも
起動できるようにする**ため。P5 の同期がまだない以上、entrypoint.sh だけ
新しくて `.loop/bin/control-plane` がない組み合わせが実際に起こり得る。

`.gitignore` に `loops/events.jsonl` を追加。

---

## Task 6: `/loop-status` を API 経由にする — **完了（2026-08-12）**

既存の照合テスト「スキルが数える dispatch 数の式が firing の N_TODAY と
一致する」は、テスト自身が「/loop-status から集計をなくしたなら、このテストも
更新すること」と書いていた。規則を**「スキルは集計しない」**に反転させた。
firing と API の一致は `control-plane.bats` が実データで見る。

API が応答しないときの経路では、本日の dispatch 数・予算・次の firing を
**出さない**ことにした。ここで代替の数え方を書くと、それがまさに P1 で
ズレた式の再生産になるため。代わりに「コントロールプレーンに接続できない
＝ループが動いていない可能性がある」ことを最初に報告し、`/loop-doctor` に
渡す。

## Task 6 の実装内容

現状は「この gh コマンドを叩け」と散文で指示する 38 行。P1 の
「`/loop-status` の集計ズレ」の原因はこの構造そのもの。

書き換え後は `curl -s http://127.0.0.1:<port>/api/...` を叩いて整形するだけにする。
**サーバが起動していない場合のフォールバックを明記する**（コンテナが
止まっているときに `/loop-status` まで使えなくなると困る）。

`skill-references.bats` に追加する照合:

- SKILL.md に書かれたエンドポイントが `control-plane.mjs` に実在すること
- 抽出が空でないこと（非空ガード）

---

## Task 7: akashic-recorder への展開確認 — **完了（2026-08-13）**

実地で確認した結果:

| 受け入れ基準 | 結果 |
|---|---|
| seeded 4 ファイルの差分が 0 | ✅ `Dockerfile` / `config.toml` / `settings.json` / `CLAUDE.md` すべて無変更 |
| `config.toml` を編集せずに UI が上がる | ✅ `[ui]` は `config.toml` に無く、`loop-config get ui.port` は `defaults.toml` から 7717 を返した |
| ユーザーの設定が保たれる | ✅ `maturity = "L2"`、`npm run test/lint`、`extra_tools` すべて温存 |
| ホストのブラウザから見える | ✅ 実データを表示（budget 0/360M、次の firing 13:00、Issue #3） |
| LAN からは見えない | ✅ |
| ループ本体が無傷 | ✅ supercronic と control-plane が並走 |

### 手順の欠陥（実地で判明・README に反映済み）

**`--force-recreate` では足りない。`--build` が要る。**

`docker/entrypoint.sh` は Dockerfile の `COPY` でイメージに焼き込まれる
（`docker/Dockerfile:45`）。ホスト側のファイルを差し替えて
`up -d --force-recreate` しても、既存イメージからコンテナを作り直すだけなので
**古い entrypoint のまま静かに起動する**。コンテナは正常に Up のままで、
UI だけが上がらない。実際にこれを踏み、ログに起動行も警告行も出ないことから
気づいた。

`.loop/**` と `docker/compose.yml` はマウントされるので再ビルド不要。
**焼き込まれるのは entrypoint.sh だけ**という非対称性が罠になっている。
P5（テンプレート同期）を作るときは、`docker/entrypoint.sh` が変わった場合に
再ビルドを促す必要がある。

### コピー対象について

計画では `{bin,lib,web,defaults.toml}` だけを挙げていたが、**`tests` も
含める必要がある**。`bin/firing` を新しくして `tests/firing.bats` を古いまま
にすると、変更した firing に対して古いテストが落ちる。テンプレート所有
（`.loop/**`）は原則まとめて更新する。

なお派生プロジェクトの `.loop/node_modules` は `npm ci --omit=dev` で入るため
bats（devDependency）が無く、そちらでテストは走らない。派生側はハーネスを
**動かす**側で、テストはテンプレート側で回す、という分担で正しい。

## 検証手順（end-to-end）

1. `.loop/tests` の全 bats が緑（既存 213 件 + 新規）
2. dev-loop 側でサーバを直接起動し `curl http://127.0.0.1:7717/api/status`
3. LAN IP 経由で繋がらないことを確認（`curl http://192.168.3.2:7717` が失敗）
4. akashic-recorder で Task 7 を実施し、ブラウザで開く
5. **次の firing（奇数時）を待ち、履歴に時刻付きの新しい行が出ることを確認。**
   今 `#2` に `loop:ready` が付いていて maturity が L2 なので、
   次の firing は初の実ディスパッチになる見込み。`dispatch` イベントが出るはず
6. `docker compose stop loop` → UI が「応答なし」を表示すること
7. UI のプロセスだけ kill → supercronic が生き残ること（逆方向の独立性）

## 実装順序

Task 1 → 2 を先に済ませる。**イベントが溜まり始めてからでないと UI の
確認材料がない**（2 時間に 1 行しか増えない）。サーバと UI を先に作ると、
空のダッシュボードを眺めることになる。

Task 1・2 をマージしたら、Task 3 以降を進めている間に履歴が自然に溜まる。
