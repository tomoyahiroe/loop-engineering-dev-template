# dev-loop テンプレート — ハーネス核（P1）設計書

作成日: 2026-08-05
参考実装: `~/code_box/projects/al-exp-taskmanager`（Loop Engineering の実運用リポジトリ）

---

## 1. このドキュメントの範囲

開発用 Loop Engineering テンプレート `dev-loop` の**ハーネス核**を設計する。

テンプレート全体は独立した 5 つのサブプロジェクトに分解される。本書は **P1 のみ**を扱う。

| | サブプロジェクト | 内容 | 本書の対象 |
|---|---|---|---|
| P1 | ハーネス核 | config、状態ファイル、プロンプト、dispatch スクリプト、予算ゲート、スケジューラ | **○** |
| P2 | ワンショットセットアップ | クローンから常駐開始までの対話セットアップ | × |
| P3 | コントロールプレーン UI | ダッシュボード・Issue ビュー・プレビュー起動ボタン | × |
| P4 | TUI | P3 と同じ API を叩く btop 風ビュー | × |
| P5 | テンプレート同期 | 派生プロジェクトへの新機能取り込み | × |

依存関係は P1 → P2 → P3 →（P4, P5 は並列）。P3 と P4 は同じ API の別フロントエンドなので、P3 の時点で API を分離すれば P4 は薄く済む。

P5 は後続サイクルだが、**所有境界（テンプレート所有 / ユーザ所有）は P1 で確定させる**（§4）。境界を後から引き直すと既存の派生プロジェクトが壊れるため。

`research-loop` は別リポジトリとして別途設計する。

---

## 2. 前提と設計方針

### 対象ユーザ

開発者。当初あった「開発経験のない人でも使える」という要件は取り下げた。これにより、会話 UI の自作が不要になり、ターミナルの `claude` をそのまま会話の場として使える。

### 中心的な目標

**「あ、これ違った」を減らすこと。** 開発時間の短縮は副次的な目標である。この優先順位が、以下の設計判断すべての根拠になっている。

- 人間の関与時間を削らない（MTG は 30〜60 分を許容する）
- 要件と設計の合意には人間の時間を使い、粒度判定とゲート検証は機械に任せる
- 1 日 1 回、必ず前日の成果を動かして見る枠を強制する

### 人間の役割

マネージャー。1 日 1 回の朝会（`/loop-mtg`）に出席し、前日の成果を確認し、新しいタスクを積む。実装は 1 日に複数回発火するループが進める。

MTG で**複数のタスクを積めること**が要件である。そのためエージェントには、会話中に要件をタスク分解し、抜けている依存タスクを指摘する働きが求められる。

### すべてのタスクが設計されていること

「サクサク作れる軽いタスク」という区分は設けない。すべての Issue が背景・受け入れ基準・実装方針・スコープ外・依存を持つ。これを文章の規約ではなく**機械的なゲート**で強制する（§7.2）。

---

## 3. 決定事項

| # | 決定 | 理由 |
|---|---|---|
| 1 | ハーネスとアプリは**同居**する | 参考リポジトリと同じ形で実績がある。テンプレート自身をループで回す（自己ホスティング）が自然に成立する |
| 2 | 真実の源は **GitHub Issues + PR** | PR が Verifier の判定単位として最初から存在する。自作すると diff 表示・レビュー記録・マージ操作を全部作ることになる |
| 3 | 実行環境は **Docker 1 コンテナ + docker.sock (DooD)** | OS 依存の常駐登録が不要。ユーザのアプリが Docker を使っても兄弟コンテナとしてホストに立つ |
| 4 | 会話は**ターミナルの `claude`**。UI は観測・制御専用 | チャット UI の自作は Claude Code の劣化版になる。UI は「ターミナルより見やすいもの」だけを担う |
| 5 | config は **defaults + overrides の 2 層** | テンプレートがキーを追加しても派生プロジェクトの設定と衝突しない |
| 6 | タスク生成の入口は **`/loop-mtg` 1 本**（30〜60 分） | 設計を機械に渡すと「違った」が増える。人間の時間は要件と設計に使う |
| 7 | `loop:ready` 付与前に**機械的な品質ゲート**を通す | 文章の規約は守られないが、ゲートは守られる |
| 8 | provider 切り替えを**最初から実装**する | ユーザの決定。抽象化の粒度は「プロセスを起動して終了コードとログを返す」までに留める |
| 9 | Verifier の指摘後、**Maker が既定で 1 回だけ再修正**する | 朝の MTG までに指摘が反映されている状態を作る。上限は config で調整可能 |
| 10 | 成熟度ラダー **L1 / L2 / L3 を 3 段とも実装**する | 3 値すべてに固有の動作を持たせ、死んだ抽象にしない |
| 11 | L3 の自動 merge は **`loop:auto-merge` ラベル付きの Issue に限定**する | 全 PR を自動 merge すると「違った」の巻き戻しコストが上がる。低リスクの雑務だけを人間が指名する |
| 12 | VOICEVOX 読み上げは **opt-in**（既定 off） | 音声を望むユーザは限られる |
| 13 | **superpowers を `.claude/settings.json` で宣言**する | クローン後の trust 時にインストールが促される。テンプレート自身のスキルはプラグインにせず `.claude/skills/` に直接置く |

---

## 4. リポジトリ構成と所有境界

### 4.1 構成

```
my-app/                          ← テンプレートを clone したリポジトリ
├── .claude/
│   ├── settings.json            [S] superpowers 宣言・権限・SessionStart hook
│   └── skills/
│       ├── loop-mtg/SKILL.md    [T] 毎日の MTG
│       └── loop-status/SKILL.md [T] キューの現在地（読み取り専用）
├── .loop/                       ← ハーネス本体
│   ├── defaults.toml            [T] 全キー + 説明コメント
│   ├── config.toml              [S] ユーザが触る唯一の設定
│   ├── OWNERSHIP.toml           [T] 同期の所有境界マニフェスト
│   ├── VERSION                  [T] テンプレートのバージョン
│   ├── bin/                     [T] loop-config, loop-gate, agent-run, firing,
│   │                                dispatch-maker, dispatch-verifier, dispatch-fixer,
│   │                                budget-check, cleanup-merged, preview
│   ├── agents/
│   │   └── claude.sh            [T] provider 実装
│   ├── prompts/
│   │   ├── maker.md             [T]
│   │   ├── verifier.md          [T]
│   │   └── fixer.md             [T]
│   └── skills/                  [T] maker-workflow.md, verifier-workflow.md, run-a-loop.md
├── loops/                       [U] 状態の背骨（git 管理）
│   ├── STATE.md                 唯一のスナップショット
│   ├── DECISIONS.md             設計判断の追記専用ログ
│   ├── INCIDENTS.md             誤動作の記録と追加したガード
│   ├── mtg/YYYY-MM-DD.md        議事録
│   └── runs/                    実行ログ
├── docker/
│   ├── compose.yml              [T]
│   └── Dockerfile               [S] ユーザがツールチェーンを育てる
├── docs/                        [U]
├── CLAUDE.md                    [S] 雛形を置き、ユーザが育てる
└── (アプリ本体)                  [U]
```

### 4.2 所有境界

| 分類 | 意味 | 同期時の挙動 |
|---|---|---|
| **[T] template-owned** | ハーネスの実装 | 常に上書きする。ユーザは編集しない |
| **[S] seeded** | テンプレートが初期版だけ置く | **絶対に触らない**。新版があれば差分を通知するのみ |
| **[U] user-owned** | ユーザのもの | テンプレートは存在を関知しない |

境界は `.loop/OWNERSHIP.toml` に glob で明示する。上から順に評価し、最初に一致したルールを適用する。

```toml
[[rules]]
kind = "seeded"
paths = [".loop/config.toml", "docker/Dockerfile", "CLAUDE.md", ".claude/settings.json"]

[[rules]]
kind = "template"
paths = [".loop/**", ".claude/skills/**", "docker/compose.yml"]

[[rules]]
kind = "user"
paths = ["**"]
```

P5 の同期スクリプトはこのファイルだけを見て動く。境界を変えるときの変更箇所が 1 つで済む。

---

## 5. config

### 5.1 2 層構造

- `.loop/defaults.toml` — テンプレート所有。**全キー**を説明コメント付きで持つ。同期のたびに丸ごと上書きされる
- `.loop/config.toml` — ユーザ所有。**変えたい値だけ**書く。同期で絶対に触られない

ユーザが編集するのは `config.toml` 1 枚だけなので、体験は「設定ファイル 1 つ」のまま。テンプレートがキーを追加しても衝突しない。

### 5.2 `config.toml`（スターターの内容）

日常的に触るダイヤルだけを置く。

```toml
maturity = "L2"                    # L1 報告のみ / L2 実装可・merge は人間 / L3 自動 merge

[agent]
provider = "claude"                # .loop/agents/<provider>.sh を呼ぶ

[models]
maker = "claude-sonnet-5"
verifier = "claude-sonnet-5"

[budget]
daily_tokens = 120_000_000

[schedule]
firings_per_day = 12
timezone = "Asia/Tokyo"

[loop]
max_open_prs = 4
max_dispatch_per_day = 10
auto_fix_rounds = 1                # Verifier 指摘後の Maker 再修正の上限（0 で無効）

[gate]
max_files_touched = 8
max_acceptance_criteria = 6

[project]                          # このプロジェクト固有
test = "pnpm -r test"
lint = "pnpm -r lint"
preview = "pnpm dev"
preview_port = 3000

[mtg]
voice = false                      # VOICEVOX 読み上げ（opt-in）
```

### 5.3 `defaults.toml` にのみ置くキー

日常のダイヤルではないもの。いじりたい人だけが `defaults.toml` を読んで `config.toml` に写して上書きする。

- `maker_max_turns` / `verifier_max_turns` / `fixer_max_turns`
- `retry_delay_seconds`（一過性エラーのリトライ待ち）
- `schedule.start_hour`（発火の起点時刻）
- `[agents.claude] allowed_tools`（provider 固有のツール許可リスト）
- `gate.required_sections`

**`max_turns` の位置づけを参考リポジトリから変更する。** 参考リポジトリでは Issue #2 が `max_turns: 60` で中断し、人間が手動で再開している。制約としては機能したが、機能した結果が事故だった（中断した WIP が worktree に残り、人間の手当てが必要になる）。

本テンプレートでは、粒度ゲート（§7.2）を中断の根本対策とし、`max_turns` は「ゲートをすり抜けたときの最後の砦」として `defaults.toml` の奥に置く。中断が起きたときの受け皿は §9 に定める。

### 5.4 読み出し

すべての読み出しは `.loop/bin/loop-config get <dotted.key>` を経由する。

- `defaults.toml` を読み、`config.toml` で上書きした結果を返す
- キーが存在しなければ空文字を出力し、終了コード 1
- シェル・Node・将来の UI がすべて同じ経路を使う

参考リポジトリは `awk -F': *'` で `BUDGET.md` を舐めていた。これを置き換える。

---

## 6. 実行環境

### 6.1 コンテナ構成

service は 1 つ。コントロールプレーン（P3）も後からこのコンテナに同居させる。

```yaml
services:
  loop:
    build: ./docker
    volumes:
      - ${PWD}:${PWD}                              # ホストと同じ絶対パスに置く
      - /var/run/docker.sock:/var/run/docker.sock  # DooD
      - loop-claude-auth:/home/loop/.claude        # 認証の永続化
      - loop-gh-auth:/home/loop/.config/gh
    working_dir: ${PWD}
    restart: unless-stopped
volumes:
  loop-claude-auth:
  loop-gh-auth:
```

### 6.2 Docker-out-of-Docker

ユーザのアプリが Docker を使う場合、コンテナ内から `docker compose up` を打つと、**ホストの Docker デーモンが兄弟コンテナを立てる**。入れ子（DinD）にはならない。

成立の条件は、**バインドマウントのパスがホストとコンテナで一致していること**。ホストのデーモンはホスト側のパスしか解決できないため、`${PWD}:${PWD}` で同じ絶対パスに置く。

副次的な利点として、アプリのコンテナはホスト上に立つのでポートがそのままホストに公開され、プレビューは `localhost:<preview_port>` で見える。ループコンテナ経由のポート転送を考えなくてよい。

**代償を明記する:**

1. `docker.sock` を渡すことは、そのコンテナにホストの root 相当の権限を与えることを意味する。ローカル開発ツールとしては一般的な妥協だが無害ではない。README に明記する
2. Windows はパス整合が素直に決まらない。**v1 の対象は macOS / Linux とし、Windows は WSL2 の中で使う前提**とする

### 6.3 認証

macOS の Claude Code は認証情報を Keychain に保存するため、コンテナからは読めない。コンテナ内で一度ログインし、その結果を named volume に永続化する。

セットアップでターミナルが必要なのは 3 コマンドだけ。

```
docker compose up -d
docker compose exec loop claude          # ブラウザでログイン
docker compose exec loop gh auth login
```

以降は常駐する。（この体験をさらに削るのが P2 の仕事。）

### 6.4 スケジューラ

コンテナ内の cron（supercronic）が `.loop/bin/firing` を叩く。発火時刻は `schedule.start_hour` を起点に `24 / firings_per_day` 時間おきの等間隔で生成する（既定の 12 回 / `start_hour = 1` なら 01:00, 03:00, …, 23:00）。`24` を割り切らない値は切り捨て、実際の発火回数を起動時にログへ出す。タイムゾーンは `schedule.timezone` をコンテナの TZ として設定する。

launchd の plist を絶対パス書き換えして登録する処理が不要になり、macOS / Linux で同じものが動く。参考リポジトリは plist にリポジトリの絶対パスを 3 箇所ハードコードしていた。

---

## 7. ループの構成要素

### 7.1 `/loop-mtg` — 毎日のミーティング

`.claude/skills/loop-mtg/SKILL.md`。テンプレート専用に書き下ろす（ユーザがグローバルに持つ同名スキルとは別物）。想定 30〜60 分、1 日 1 回。

```
① 前回の結果を見る（必須）
   - open PR ごとに: Verifier 判定の要点 → プレビューで実際に触る → マージ判断
   - UI のない変更、または preview 未設定の場合は
     「受け入れ基準の検証コマンドを実行して結果を見る」に置換する
   - 失敗した loop / needs-human / 中断した worktree の残骸を確認

② 要件の対話
   - 1 発言 = 1 論点 = 1 質問。必ず叩き台を出す
   - 調べられる事実は聞かない。聞くのは「決め」だけ

③ タスク分解案の提示
   - エージェントが分解案を出す
   - 抜けている依存タスク（マイグレーション、設定、テスト基盤など）を必ず指摘する

④ 各タスクの設計
   - サブエージェントを並列で走らせてリポジトリを調査する
     （触るファイル / 既存パターン / テスト方針 / 粒度）
   - 調査の完了を人間に待たせない。裏で走らせながら次の論点を進める
   - 粒度超過は分割案を出して承認を取る

⑤ Issue 化 → loop-gate 検証 → loop:ready 付与
   - maturity = L3 のとき、低リスクと人間が判断したものに loop:auto-merge を付ける

⑥ 議事録（loops/mtg/YYYY-MM-DD.md）+ STATE 更新 + commit
```

**①が「あ、これ違った」の検出装置である。** 1 日 1 回、前日の成果を実際に動かして見る枠を強制することで、検出が最短になる。参考リポジトリの MTG はマージ判断はしていたが「動かして見る」は入っていなかった。

**禁止事項:**

- MTG 中のコード変更（書いてよいのは議事録・STATE・Issue のみ）
- 合意していないことの実装
- 受け入れ基準のない Issue の作成
- 人間の決定の上書き（技術的懸念は 1 回だけ短く述べ、決定には従う）

**音声:** `[mtg] voice = true` のときだけ有効になる条件付きの節として書く。既定は off。

### 7.2 `loop-gate` — 品質ゲート

`.loop/bin/loop-gate <issue-number>`。終了コード 0 で通過、1 で不合格（理由を標準出力に列挙）。

**構造だけを検証する。妥当性は検証しない。** 「受け入れ基準が本当に観察可能か」の判断は MTG ④で人間が行う。

| ルール | 判定 |
|---|---|
| 必須セクション | `## 背景` `## 受け入れ基準` `## 実装方針` `## スコープ外` `## 依存` がすべて存在する |
| 受け入れ基準の検証可能性 | `- [ ]` が 1 つ以上ある。各行がバッククォートで囲まれたコマンドを含む、または `手動:` で始まる |
| 依存の解決 | `## 依存` の本文が `なし` または `#N` の列。参照先の Issue がすべて closed |
| 粒度の上限 | `## 実装方針` 中のパス（`/` または `.` を含むバッククォート付きトークン）の数 ≤ `gate.max_files_touched`。`- [ ]` の数 ≤ `gate.max_acceptance_criteria` |

**呼ばれる場所は 2 箇所。**

1. MTG ⑤の `loop:ready` 付与前
2. firing の dispatch 直前（Issue は後から編集されうるため、fail-closed で再検証する。落ちたら `loop:ready` を剥がして `needs-human` を付ける）

「実行ディレクトリ込みのコマンド」を要求するのは、参考リポジトリで実際に効いた知見に基づく（PR #18 の `drizzle-kit generate` という表記が、どのディレクトリで実行するのか分からず人間の検証を迷わせた）。UI の見た目のようにコマンドで検証できない基準のために `手動:` プレフィックスを逃げ道として用意する。

### 7.3 `firing` — スケジュール発火の本体

```
0. origin/main 同期        コンフリクトなら STATE 記録して中止（参考リポジトリ INCIDENT #4）
1. cleanup-merged          マージ済み worktree / branch の片付け
2. fix 待ちの PR があれば   auto_fix_rounds 以内なら Fixer を最優先 dispatch
3. loop:ready の最小番号を選定
4. loop-gate 再検証        落ちたら ready を剥がして needs-human
5. 上限チェック            open PR 数 / 本日の dispatch 数 / budget（すべて fail-closed）
6. dispatch-maker → PR → dispatch-verifier
7. maturity = L3 かつ loop:auto-merge かつ Verifier approve なら merge + close
8. 仕事がなければ commit もログも残さず終了（空回りゼロ）
```

`maturity = "L1"` のときは 2〜7 を実行せず、「今なら #N を dispatch する」という判定結果を STATE に記録して終了する。

`--dry-run` オプションで、判定分岐を実行せずに確認できる。

### 7.4 成熟度ラダー

| | 動作 |
|---|---|
| **L1** | firing は判定と報告だけ。dispatch しない。導入初日にループの意図を観察して信頼を作るために使う |
| **L2**（既定） | Maker → PR → Verifier まで自動。**merge は人間**が MTG ①で判断する |
| **L3** | Verifier が approve し、かつ Issue に `loop:auto-merge` が付いていれば自動 merge + close。付いていない PR は L2 と同じ振る舞い |

3 値すべてに固有の動作がある。参考リポジトリでは `maturity != L2` が単に REFUSED を返すだけで、実質 1 値だった。

L3 のラベル限定は Osmani の「L3 は低リスクの雑務のみ」を機械的に効かせるもの。依存パッケージの更新、型修正、テスト追加のようなものに MTG で人間が印を付ける。

### 7.5 provider 抽象

```
.loop/bin/agent-run --role maker|verifier|fixer --prompt-file <path> --cwd <dir> --log <path>
```

`agent-run` は `agent.provider` を読み、`.loop/agents/<provider>.sh` に環境変数（`LOOP_ROLE` `LOOP_PROMPT_FILE` `LOOP_CWD` `LOOP_MODEL` `LOOP_MAX_TURNS`）を渡して起動する。

**抽象化は「プロセスを起動して終了コードとログを返す」より深くしない。** ツール許可リストの意味論は provider ごとに異なるため共通化せず、`.loop/agents/claude.sh` が `defaults.toml` の `[agents.claude] allowed_tools` を読んで自分で組み立てる。

dispatch スクリプトは `agent-run` だけを呼ぶ。2 つ目の provider を繋ぐときに触るのは `.loop/agents/` 配下だけになる。

### 7.6 Maker / Verifier / Fixer

プロンプトは汎用化し、プロジェクト固有のコマンドを config から注入する（`{{TEST_CMD}}` `{{LINT_CMD}}` を `[project]` から埋める）。

**Maker** — 専用 worktree (`../<repo>-issue-<N>`, branch `loop/issue-<N>`) で TDD。

- **最初のテストが緑になった時点で必ず 1 回コミットする**（max-turns で中断しても成果が branch に残る）
- 完了条件は `[project] test` と `[project] lint` が緑
- `gh pr create` の本文に受け入れ基準チェックリストと `Closes #N`
- 禁止: main への直接コミット / スコープ外の変更 / `loops/` と `.loop/` の編集
- 完了できない場合は PR を作らず、Issue にコメントして `needs-human` を付けて終了

**Verifier** — Maker の思考を一切知らないまっさらなコンテキストで、`gh pr checkout <N> --detach` した worktree の中で判定する。

- `--detach` は必須。PR の head ブランチは Maker の worktree が保持しており、同一ブランチの二重 checkout を git が拒否するため（参考リポジトリ INCIDENT #3）
- **判定チェックリストを PR コメントに投稿してから** review を submit する
- **同一 gh アカウントでは review の submit が GitHub に拒否される。** その場合はコメントを判定の正本とし、`needs-human` を付けて人間にルーティングする経路を最初から組み込む
- 禁止: コードの修正 / merge

**Fixer** — Verifier の指摘だけを読んで修正する。

- Maker の worktree を再利用する
- 新機能を足さない。指摘への対応のみ
- 完了したら Verifier を再実行する
- `auto_fix_rounds` を超えたら `needs-human`

### 7.7 プレビュー

```
.loop/bin/preview main         # メインの作業ツリーで [project] preview を実行
.loop/bin/preview pr <N>       # 一時 worktree に PR を detached checkout して実行
.loop/bin/preview stop
```

DooD なので、アプリが Docker を使っていてもホスト上に立ち、`localhost:<preview_port>` で見える。

MTG ①がこれを使う。P3 の UI のボタンも同じスクリプトを叩く。

---

## 8. 状態の背骨

参考リポジトリを踏襲する。**すべてのループ実行は `STATE.md` を読むことから始まり、`STATE.md` を更新して終わる。**

| ファイル | 役割 |
|---|---|
| `loops/STATE.md` | 唯一のスナップショット。Now / Next / Blocked / Done / Budget |
| `loops/DECISIONS.md` | 設計判断とその理由の追記専用ログ |
| `loops/INCIDENTS.md` | 誤動作の記録と、それに対して追加したガード |
| `loops/mtg/` | MTG 議事録 |
| `loops/runs/` | 実行ログ |

`INCIDENTS.md` には**参考リポジトリで実際に起きた 4 件を「既知の落とし穴」として最初から載せる**。運用ルールは「事象 / 影響 / 原因 / 追加したガード を記録し、**ガードを入れてからループを再開する**」。

テンプレートに同梱する既知の落とし穴:

1. dispatch の実行ログが未コミットのまま作業ツリーに残る
2. Verifier 起動が手動だと maker/checker 分離が形骸化する
3. `gh pr checkout` がブランチ二重 checkout で失敗する（`--detach` で解決）
4. stale な local main から branch を切るとコンフリクトする（firing 冒頭の origin/main 同期で解決）

---

## 9. 安全装置

- **merge は L2 では常に人間。** L3 でも `loop:auto-merge` ラベルで人間が明示的に指名したものに限る
- **予算ゲートがステップゼロ。** `budget-check` が fail-closed（使用量が取れなければスキップする）
- **中断検知。** max-turns 中断や rc≠0 を検知したら `needs-human` を付け、worktree は残置して翌朝の MTG の議題にする。中断した WIP を機械が勝手に片付けない
- **一過性エラー**（DNS / 接続系）は `retry_delay_seconds` 後に 1 回だけ自動リトライ。ただし worktree が手つかず（未コミット変更なし、main から進んでいない）のときのみ。作業途中で死んだ WIP は残置する
- **Safe-Stop Protocol.** 作業は小さい単位に分割し、単位の完了ごとにコミットする。停止は常に安全であること。merge 途中の worktree を残さない
- **空回りゼロ.** 仕事がなければ commit もログも残さず終了する

---

## 10. テスト戦略

シェルスクリプトなので 3 層にする。

1. **bats-core によるユニットテスト**
   - `loop-config`: defaults ← config のマージ、欠損キー、型（数値・真偽値・文字列）
   - `loop-gate`: 4 ルールそれぞれの合格・不合格ケース、`手動:` の逃げ道
2. **`firing --dry-run`**: 判定分岐（ready なし / gate 不合格 / PR 上限 / 日次上限 / budget 超過 / L1）を実行せずに検証する
3. **統合テスト**: 空の GitHub リポジトリにテンプレートを clone し、1 サイクル（Issue → Maker → PR → Verifier）を実走させる

---

## 11. 受け入れ基準

- [ ] テンプレートを clone し、`docker compose up -d` → `claude` ログイン → `gh auth login` の 3 コマンドでループが常駐する
- [ ] `.loop/bin/loop-config get models.maker` が `config.toml` の値を返し、未設定のキーは `defaults.toml` の値を返す
- [ ] `.loop/bin/loop-gate <N>` が 4 ルールすべてを検証し、不合格時に理由を列挙して終了コード 1 を返す（bats テストが緑）
- [ ] `.loop/bin/firing --dry-run` が全判定分岐を正しく報告する（bats テストが緑）
- [ ] `maturity = "L1"` で firing が dispatch せず、判定結果を `STATE.md` に記録する
- [ ] `maturity = "L2"` で Issue → Maker → PR → Verifier が自動で流れ、merge されずに人間の判断を待つ
- [ ] Verifier が request-changes を出したとき、`auto_fix_rounds = 1` で Fixer が 1 回だけ走り、再 Verify される。2 回目は `needs-human` になる
- [ ] `maturity = "L3"` かつ `loop:auto-merge` かつ Verifier approve のとき自動 merge + close され、ラベルのない PR は人間待ちのまま残る
- [ ] `.loop/bin/preview pr <N>` が PR のブランチでアプリを起動し、`localhost:<preview_port>` で見える
- [ ] ユーザのアプリが Docker を使う構成で、ループコンテナ内から `docker compose up` が兄弟コンテナをホストに立てられる
- [ ] `/loop-mtg` を実行すると①〜⑥が順に進行し、⑤でゲートを通った Issue にだけ `loop:ready` が付く
- [ ] `[mtg] voice = false` のとき読み上げが一切発生しない
- [ ] クローン直後に Claude Code を開くと superpowers のインストールが促される
- [ ] 統合テストが空リポジトリで 1 サイクル完走する

---

## 12. 参考リポジトリからの変更点

| 項目 | 参考リポジトリ | 本テンプレート | 理由 |
|---|---|---|---|
| config | `loops/BUDGET.md` の key: value を `awk` で読む | `.loop/defaults.toml` + `config.toml`、`loop-config` 経由 | 同期の無衝突化と、UI からの読み書き |
| タスク生成 | `/loop-mtg` 20 分（マージ判断 + Issue 化） | `/loop-mtg` 30〜60 分（+ 動作確認 + 並列調査による設計） | 「違った」の検出と、設計品質の確保 |
| 品質ゲート | スキルの文面のみ | `loop-gate` による機械検証 | 文章の規約は守られない |
| 成熟度 | `maturity != L2` で REFUSED（実質 1 値） | L1 / L2 / L3 それぞれに固有の動作 | 死んだ抽象の解消 |
| 修正ループ | なし（人間が拾う） | `auto_fix_rounds`（既定 1） | 朝の MTG までに指摘が反映されている状態 |
| スケジューラ | launchd plist に絶対パスをハードコード | コンテナ内 cron | OS 依存の解消 |
| エージェント | dispatch スクリプトに `claude` を直書き | `agent-run` + `.loop/agents/<provider>.sh` | provider 差し替え |
| プレビュー | なし | `.loop/bin/preview` | MTG ①の動作確認と P3 の UI ボタン |
| Issue テンプレ | 背景 / 受け入れ基準 / 実装方針 / 依存 | + **スコープ外** | Maker のスコープ逸脱を減らす |

---

## 13. 次のサイクルへの申し送り

- **P2（セットアップ）**: ターミナルの 3 コマンドをさらに削る。`config.toml` の対話生成、`[project]` のコマンド自動検出
- **P3（UI）**: 観測・制御専用。ダッシュボード（トークン消費・実行中のループ・成否履歴）、Issue ビュー、プレビュー起動ボタン。P4 のために API を分離して作る
- **P4（TUI）**: P3 と同じ API を叩く
- **P5（同期）**: `.loop/OWNERSHIP.toml` を読み、template を upstream remote として [T] のみ更新、[S] は差分通知のみ、[U] は不可視
- **L3 の運用実績**: 自動 merge の巻き戻しが実際にどれくらい起きるかを `INCIDENTS.md` で観測し、ラベル限定を緩めるかどうかを判断する
