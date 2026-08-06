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

**必ずリポジトリのルートディレクトリから実行してください。**
`docker/compose.yml` は `${PWD}`（= docker compose を実行したシェルのカレント
ディレクトリ）でホストと同じ絶対パスにマウントします。`docker/` の中に
`cd` してから `docker compose up -d` のように実行すると、マウント先が
ホストの実際のリポジトリパスとズレて起動に失敗します。

```bash
cd <このリポジトリのルート>
docker compose -f docker/compose.yml up -d --build
docker compose -f docker/compose.yml exec loop claude      # ブラウザでログイン
docker compose -f docker/compose.yml exec loop gh auth login
```

この 2 つの `exec`（`claude` と `gh auth login`）は、ブラウザでの認可が要る
**手動・対話的・一度きり**のステップです。認証情報は名前付き volume
（`loop-claude-auth` / `loop-gh-auth`）に保存されるので、コンテナを作り直さない
限り 2 回目以降は不要です。ここから先、ターミナルを開く必要は基本的にありません
— ループは cron（supercronic）が自動で起こします。

続いて、この 3 つを自分のプロジェクトに合わせて編集します。

1. `.loop/config.toml` — **2 か所をセットで**書き換えます

   ```toml
   [project]
   test = "pnpm -r test"      # あなたのプロジェクトのテストコマンド
   lint = "pnpm -r lint"      # 同 lint コマンド
   preview = "pnpm dev"       # 任意（MTG で実際に動かして見るため）

   [agents.claude]
   # ↑ の test / lint を実行するための許可。空のままにしない
   extra_tools = ["Bash(pnpm:*)", "Bash(npx:*)", "Bash(node:*)"]
   ```

   エージェントに既定で許可されているツールは `git` と `gh` だけです。
   `extra_tools` にプロジェクトのツールチェーンを足さないと、**Verifier は
   テストを 1 つも実行できず、diff を読むだけでレビューする**ことになります
   （ハーネスの主要な品質シグナルが静かに無効化されます）。
   そのため、`test` / `lint` が設定されているのに `extra_tools` が空の場合、
   ループは dispatch を拒否し、理由を `loops/STATE.md` に記録します。
   テストや lint を持たないプロジェクトなら `test` / `lint` を `""` にしてください。
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
与えることを意味します。** コンテナ内のプロセスはホスト上の任意のコンテナを
起動・停止・削除でき、事実上ホストを操作できます。これはローカル開発ツール
としての意図的な妥協です。

許容できない、またはアプリが Docker を一切使わないなら、
`docker/compose.yml` の `volumes:` から次の 2 行を削除してください
（削除すればコンテナはホストの Docker を一切操作できなくなります）:

```yaml
- /var/run/docker.sock:/var/run/docker.sock
# ↑ 上の「★ 注意」参照: ホストの root 相当の権限をコンテナに渡す。...
```

## コンテナの中でコマンドを叩きたいとき

`docker compose exec loop <cmd>` は常駐中のコンテナの中でコマンドを実行します
（依存は起動時に入れ済みです）。

一方 `docker compose run --rm loop <cmd>` は**常駐コンテナとは別の使い捨て
コンテナ**で `<cmd>` をそのまま実行します。依存のインストール（`.loop` の
`npm ci` 等）は常駐用の entrypoint だけが行う処理なので、`run --rm` はこれを
**行いません**。`node_modules` がまだ無い状態で `run --rm` を使うと、
依存が必要なコマンド（例: `cd .loop && npx bats tests/`）は失敗します。
依存を確認・インストールしたい場合は、先に一度 `up -d` している常駐コンテナに
対して `exec` を使ってください。

## テスト

これは開発者がホスト側（自分の Mac/Linux。コンテナの外）で直接叩くコマンドです。
セットアップの「ターミナルを使うのはここだけ」はループ運用のための操作の話で、
ハーネス自体の開発・変更時にホストでテストを回すのは対象外です。
コンテナの中で実行したい場合は上の `docker compose exec loop <cmd>` を使ってください
（依存インストール済みなので `npm install` は不要です）。

```bash
cd .loop && npm install && npx bats tests/
```

## ディレクトリ

| | |
|---|---|
| `.loop/` | ハーネス本体。`config.toml` 以外は編集しない |
| `loops/` | 状態の背骨。STATE / DECISIONS / INCIDENTS / 議事録 / 実行ログ |
| `docker/` | コンテナ定義 |
