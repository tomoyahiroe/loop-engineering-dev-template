# P3 — コントロールプレーン UI（観測カット）設計書

前提: P1（ハーネス核）・P2（ワンショットセットアップ）実装済み。
`docs/superpowers/specs/2026-08-05-dev-loop-harness-design.md` §13 の
「P3（UI）: 観測・制御専用。ダッシュボード・Issue ビュー・プレビュー起動ボタン。
P4 のために API を分離して作る」を出発点とする。

## 1. 目的

ループが今どうなっているかを、リポジトリを開かずに一目で見る。

現状、状態を知る手段は `/loop-status`（`claude` を開いて実行する 38 行の散文スキル）
しかない。2 時間ごとに firing が動いているのに、何が起きたかは STATE.md の
追記を目で追うしかない。

副次的だが同じくらい重要な目的として、**P4（TUI）が叩く API をここで確定させる**。
P3 と P4 は同じ API の別フロントエンドなので、ここで分離を済ませれば P4 は薄く済む。

## 2. 達成条件

1. ブラウザで開くと、トークン消費 / maturity / 次の firing / 成否履歴 / Issue 一覧が見える
2. すべて GET。状態を変える経路を持たない
3. `docker/Dockerfile`・`.claude/settings.json`・`.loop/config.toml`・`CLAUDE.md`
   を一切変更せずに動く（`OWNERSHIP.toml` の seeded 境界を越えない）
4. UI と API が分離していて、P4 が同じ API を叩ける
5. akashic-recorder に `.loop/**` と `docker/compose.yml`・`docker/entrypoint.sh`
   のコピーだけで入る（= template 所有ファイルのみで完結する）

## 3. 決定事項

| # | 決定 | 理由 |
|---|---|---|
| 1 | firing の各 tick に構造化イベントを 1 行出す（`loops/events.jsonl`）。**API は STATE.md をパースしない** | STATE.md は時刻を持たず（`record_state` は `date +%Y-%m-%d` のみ）、追記は末尾に積まれるため実際には `## Budget` 見出しの下に溜まっており、内容は日本語の散文。akashic-recorder では 08-12 の 8 回の firing が全部同一の 1 行になっている。これをパースするのは P2 の決定 3 が名指しした「散文とコードの実態がズレる」穴に自分から入る行為 |
| 2 | 「何もしなかった」tick もイベントを出す | 現状 ready な Issue がないと `exit 0` で無記録（`firing:141-143`）。gate マーカー一致（`:190-196`）とコメント失敗（`:211-213`）も同様に無記録で抜ける。ダッシュボードに理由の書かれていない空白が並ぶのを防ぐ |
| 3 | `record_state` は残し、`record_event` を併置する | STATE.md は人間が MTG で読むためのもの。機械向けの要求で散文を壊さない。2 つの宛先は用途が違う |
| 4 | node 標準ライブラリのみ。フロントは素の HTML/CSS/JS、ビルド工程なし | `docker/Dockerfile` は seeded = 同期で降りないため、依存を足すと派生プロジェクトごとに手作業の追記が要る。ベースが `node:24-bookworm` なので `node:http` で足りる |
| 5 | **127.0.0.1 に bind する**（0.0.0.0 にしない） | compose が `network_mode: host`。0.0.0.0 だと同一 LAN の全員に開く。観測専用でも Issue タイトルとトークン消費量は外に出したくない |
| 6 | 読み取り専用（GET のみ）。プレビュー起動ボタンは次のカットに回す | 状態を変える経路を持つと認証と CSRF の設計が要り、API の形の確定が遅れる。P4 の前提を早く固めることを優先する |
| 7 | `/loop-status` を、API を叩く形に書き換える | 現状は「この gh コマンドを叩け」と散文で指示している。P1 で起きた「`/loop-status` の集計ズレ」はこの構造が原因。集計を実装に一本化すれば同じバグが構造的に起きなくなる |
| 8 | `loops/events.jsonl` は git 管理しない | 2 時間ごとに増える運用ログ。コミットに乗せると Maker の PR が無関係な差分で汚れる |
| 9 | サーバは既存の loop コンテナに同居させる。service は増やさない | 設計書 §7 の「コントロールプレーン（P3）も後からこのコンテナに同居させる」に従う。compose の service を増やすと seeded でない compose.yml の差分が大きくなる |

### 3.1 検証済み: host networking でホストから到達できる（2026-08-12）

`docker/compose.yml` は `network_mode: host` を指定している。Docker Desktop for Mac
の host networking は Linux と挙動が異なり、コンテナのポートをホストに公開しない
場合がある。現在のループは外向き通信しか使っておらず、P3 は**初めてホストから
コンテナのポートを叩く機能**になるため、実装前にこの 1 点だけを切り出して検証した。

稼働中の `docker-loop-1` の中で 127.0.0.1:7717 に listen させ、3 方向から確認した:

| 経路 | 結果 |
|---|---|
| コンテナ内 → `127.0.0.1:7717` | 到達 |
| **ホスト → `127.0.0.1:7717`** | **到達** |
| **LAN（`192.168.3.2:7717`）→** | **到達しない** |

**結論: `docker/compose.yml` の変更は不要。** `network_mode: host` のまま、
コンテナ内で 127.0.0.1 に bind すればホストのブラウザから開ける。同時に決定 5 の
前提（loopback bind なら LAN に開かない）も成立している。

副次的な確認として、テストサーバの起動・停止で supercronic（PID 7）は影響を
受けなかった。§9 の「UI が落ちてもループ本体は回り続ける」は同居構成で成立する。

なお **この結果は macOS + Docker Desktop での実測**である。Linux ホストでは
host networking がそのまま効くため同じかそれ以上に確実だが、`docker/compose.yml`
を変更する必要が出た場合は、`network_mode: host` を外すと DooD（`docker.sock`
経由で兄弟コンテナを立てる経路）と `.loop/bin/preview` の到達性に影響し得る点に
注意する。

## 4. イベントログ

`loops/events.jsonl` — 1 行 1 JSON、append-only。

```json
{"ts":"2026-08-12T15:00:03+09:00","kind":"report","maturity":"L1","issue":2,"open_prs":1,"max_prs":4,"today":0,"max_today":10,"msg":"L1 (報告のみ): 今なら #2 を dispatch する"}
```

`ts` は ISO 8601（`date -Is`）。`record_state` が日付しか持たない問題をここで解消する。

`kind` の値域は firing の終了経路と 1 対 1 に対応させる:

| kind | firing の該当箇所 | 補足フィールド |
|---|---|---|
| `conflict` | `:25` origin/main とのコンフリクトで中止 | — |
| `automerge` / `automerge_failed` | `:124` / `:133` L3 自動 merge | `pr`, `issue` |
| `fix` / `fix_exhausted` | `:95` / `:84` fixer 起動・上限到達 | `pr`, `issue`, `round` |
| `idle` | `:141-143` ready な Issue なし | — |
| `skip` | `:148` / `:153` / `:161` 上限・予算 | `reason` = `open_prs` \| `daily` \| `budget` |
| `gate_failed` | `:175` gate 不合格 | `issue`, `gate_out` |
| `gate_retry` | `:190-196` remediate 済み、ラベル除去のリトライのみ | `issue` |
| `report` | `:236` L1 は報告のみ | `issue` |
| `dispatch` | `:247` Maker 起動 | `issue` |

**この対応表が散文としてズレないことを、テストで機械的に照合する**（§8-3）。

書き込みは `.loop/lib/common.sh` に `record_event()` を足し、既存の `record_state`
呼び出し箇所に併置する。`record_state` を持たない経路（`idle`・`gate_retry`）には
`record_event` だけを置く。

## 5. API

`.loop/lib/control-plane.mjs`（`node:http`）。すべて GET、JSON を返す。

| エンドポイント | 返すもの | 源 |
|---|---|---|
| `GET /api/status` | maturity, budget(used/limit), next_firing, open_prs/max, today/max | `loop-config`, `budget-check`, `gen-crontab`, `gh pr list` |
| `GET /api/events?limit=50` | events.jsonl の末尾 N 件（新しい順） | `loops/events.jsonl` |
| `GET /api/issues` | ready / needs-human / その他 に分けた Issue 一覧 | `gh issue list` |
| `GET /api/runs/:name` | `loops/runs/` の 1 ファイルの中身（Verifier の結論を読むため） | `loops/runs/*.md` |
| `GET /` `/app.js` `/app.css` | 静的ファイル | `.loop/web/` |

**gh 呼び出しは短期キャッシュを挟む**（既定 30 秒）。ポーリングのたびに叩くと
体感が遅く、GitHub のレート制限も無駄に減る。キャッシュはプロセス内のメモリのみ。

`budget-check` は `BUDGET: used=N limit=N` を stdout に出すので、そのまま使える。
ただし終了コード非 0（fail-closed の SKIP）でも表示は必要なので、**API は
終了コードで捨てず、`SKIP:` 行を理由として返す**。

パスの正規化（`..` の拒否）は `/api/runs/:name` と静的配信の両方に効かせる。

## 6. UI

1 枚の HTML。`fetch` で `/api/status` `/api/events` `/api/issues` を定期取得
（既定 10 秒）。SSE は使わない（必要になったら後から足せる。最初から入れると
再接続とバックオフの実装が要る）。

レイアウトは上から: サマリ（トークン消費バー・maturity・open PR・次の firing）→
成否履歴（events を時刻付きで新しい順）→ Issues（ready / needs-human / その他）。

## 7. ファイル構成

```
.loop/bin/control-plane          [T] 起動スクリプト（bash）
.loop/lib/control-plane.mjs      [T] HTTP サーバ本体
.loop/lib/events.mjs             [T] events.jsonl の読み書き（純関数）
.loop/lib/common.sh              [T] record_event() を追加
.loop/bin/firing                 [T] record_event() 呼び出しを追加
.loop/web/index.html             [T] UI
.loop/web/app.js  app.css        [T]
.loop/defaults.toml              [T] [ui] セクションを追加
docker/compose.yml               [T] 変更なし（§3.1 で検証済み）
docker/entrypoint.sh             [T] supercronic の前にサーバを起動
.claude/skills/loop-status/      [T] API を叩く形に書き換え
.loop/tests/control-plane.bats   [T]
.loop/tests/events.bats          [T]
.gitignore                       [U] loops/events.jsonl を追加
```

**変更しないファイル（seeded）**: `docker/Dockerfile`、`.loop/config.toml`、
`.claude/settings.json`、`CLAUDE.md`。

新しい設定キーは `defaults.toml`（template 所有・同期で上書きされる）に置く:

```toml
[ui]
port = 7717
poll_seconds = 10
cache_seconds = 30
```

`config.toml`（seeded）は触らない。**この 2 層構造のおかげで、新キーは派生
プロジェクトに自動で降りる。** ユーザーが値を変えたいときだけ config.toml に書く。

`entrypoint.sh` は現在 `exec supercronic` で終わっている。その手前でサーバを
バックグラウンド起動する。サーバの起動失敗は cron を止めない（観測 UI が
落ちてもループ本体は回り続けるべき）。ただし失敗はログに出す。

## 8. テスト戦略

P1・P2 と同じ 3 層。

1. **純関数**: `events.mjs` の追記・末尾 N 件取得・壊れた行のスキップ。
   ログが途中で切れた行（コンテナが kill された場合）で全体が読めなくならないこと
2. **CLI / HTTP**: bats でサーバを起動して curl。gh をスタブする
   （`loop-doctor.bats` が ccusage をスタブしているのと同じ形）。
   127.0.0.1 以外から繋がらないこと、`..` を含むパスが拒否されること
3. **散文と実装の照合**（最重要）: `skill-references.bats` と同じ形で、
   - `/loop-status` が API を叩く形になっていて、そこに書かれたエンドポイントが
     実際に `control-plane.mjs` に存在すること
   - §4 の `kind` 値域と、`firing` が実際に `record_event` に渡す kind が一致すること

   3 は P1 で最も高くついた種類の検証。`/loop-status` の集計ズレも、firing の
   `.retry.md` 除外漏れも、どちらも「散文とコードがズレる」バグで、213 件の
   テストが 1 つも捕まえられなかった。

## 9. 受け入れ基準

- [ ] ホストのブラウザで `http://127.0.0.1:7717` を開くと現在の状態が表示される
- [ ] LAN の別ホストからは繋がらない
- [ ] firing が動くと、10 秒以内に成否履歴に**時刻付きで**新しい行が現れる
- [ ] ready な Issue がない tick も履歴に `idle` として現れる（空白にならない）
- [ ] `docker/Dockerfile` の差分が 0
- [ ] コンテナを止めてもループ本体（supercronic）は影響を受けない、逆も同様
- [ ] akashic-recorder に template 所有ファイルのコピーだけで入り、`config.toml` を
      手で編集せずに UI が立ち上がる
- [ ] テストが緑（既存 213 件 + 新規）

## 10. スコープ外

| 項目 | 理由 |
|---|---|
| 制御操作（プレビュー起動 / merge / dispatch 手動実行） | 次のカット。認証と CSRF の設計とセットで行う |
| 認証 | 127.0.0.1 bind で代替する。制御操作を入れる時に再検討 |
| SSE / WebSocket | ポーリングで足りる。再接続とバックオフの実装コストに見合わない |
| P4 TUI | 本カットで API を確定させるのが前提条件。実装は別サイクル |
| Dockerfile の変更 | 決定 4。seeded 境界を越えない |
| 複数リポジトリの一覧表示 | 2026-08-10 の決定（個人リポジトリ専用）の範囲外 |
| events.jsonl のローテーション | 1 日 12 行。当面問題にならない。必要になってから |
