# dev-loop

開発用 Loop Engineering テンプレート。GitHub Issue を入口に、
Maker → Verifier → 人間の merge が 1 日に複数回自動で回ります。

人間の役割はマネージャーです。1 日 1 回の朝会（`/loop-mtg`）に出席し、
前日の成果を確認して、次のタスクを積みます。

## 適用範囲 — 個人リポジトリ専用です

**このテンプレートは、自分ひとりが所有するリポジトリで使うものです。**
チームで共有しているリポジトリには入れないでください。

ループは GitHub の Issue を待ち行列に、PR を判定の単位に、ラベルを状態機械に
使います。どれもリポジトリ全体で共有されるものなので、チームのリポジトリに
入れると、あなたの個人的な実験がそのままチーム全員に見えます。

- ラベル 3 つがチームの Issue トラッカーに生えます
- Maker が PR を作ります（既定で 1 日 12 回発火します）
- Issue にループのコメントが付きます
- `.loop/` と `loops/` で 100 ファイル以上がリポジトリに増えます
- `maturity = "L3"` にすると、承認済み PR が自動でマージされます

技術的には動きますが、同意なく持ち込んでよい変更ではありません。
既存の**個人**プロジェクトに導入するのは問題ありません（下の「既存プロジェクトに
導入する」を参照）。複数の既存リポジトリをまとめて回す用途は、このテンプレートの
範囲外です。別テンプレートとして分離する予定です。

## 必要なもの

- Docker（Docker Desktop など）
- **Node.js 18 以上**（ホスト側。`.loop/bin/*` は node で動きます。
  `/loop-setup` と `/loop-doctor`、毎朝の `/loop-mtg` がホストからこれを叩きます）
- Git と、GitHub アカウント + このリポジトリの push 権限
- Claude Code のサブスクリプション

対象は **macOS / Linux** です。Windows は WSL2 の中で使ってください。

## セットアップ

ターミナルで `claude` を開き、次のように打ちます。

```
/loop-setup
```

これだけです。`.loop` の依存インストール、プロジェクトの検出、設定ファイルの生成、
リモート（`origin`）の確認、GitHub ラベルの作成、
コンテナのビルドと起動、最後の健全性チェックまでを対話で進めます。

クローンしたままだと `origin` はテンプレート側を指しています。
`/loop-setup` はラベル作成の前に必ず確認を取りますが、
**先に自分のリポジトリへ差し替えておくほうが確実です**
（`gh repo create <name> --private --source=. --remote=origin --push`）。

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

## 既存プロジェクトに導入する

すでに中身のある**個人**リポジトリでループを回す場合は、このテンプレートを
クローンするのではなく、**ハーネス一式をそのリポジトリにコピー**します。
ハーネスは「自分が入っているリポジトリ」を対象に動くので、対象リポジトリの
中に置く必要があります。

```bash
cd <あなたのプロジェクト>
D=<dev-loop をクローンした場所>
cp -R "$D/.loop" "$D/.claude" "$D/docker" .
mkdir -p loops/runs loops/mtg
cp "$D/loops/STATE.md" "$D/loops/DECISIONS.md" "$D/loops/INCIDENTS.md" loops/
cat "$D/.gitignore" >> .gitignore     # 既存の .gitignore に追記する
```

コピーする対象は `.loop/OWNERSHIP.toml` が定義している配布境界と同じです。

**上書きに注意してください。** `loops/STATE.md` `CLAUDE.md` `.gitignore` は
同名ファイルがあれば潰します。既存のものがある場合は、コピー前に退避するか
手で統合してください。

## 導入済みのプロジェクトでハーネスを更新する

テンプレート側で機能が増えたときは、**テンプレート所有のファイルだけ**を
上書きします（境界は `.loop/OWNERSHIP.toml`）。

```bash
cd <あなたのプロジェクト>
D=<dev-loop をクローンした場所>
for i in agents bin lib prompts skills tests web defaults.toml \
         OWNERSHIP.toml VERSION package.json package-lock.json; do
  [ -e "$D/.loop/$i" ] && cp -R "$D/.loop/$i" .loop/
done
cp -R "$D/.claude/skills" .claude/
cp "$D/docker/compose.yml" "$D/docker/entrypoint.sh" docker/

# ★ --build が必要（--force-recreate だけでは足りない）
docker compose -f docker/compose.yml up -d --build loop
```

`.loop/config.toml`・`docker/Dockerfile`・`.claude/settings.json`・`CLAUDE.md`
は **seeded** なので触りません。あなたが書いた設定はそのまま残り、新しく
増えた設定キーは `defaults.toml` 側から自動的に効きます。

**`.gitignore` は自分で追従してください。** `.gitignore` はユーザー所有
（`[U]`）なので上書きされません。テンプレート側で新しい除外が増えたときは、
自分のプロジェクトの `.gitignore` に手で足す必要があります。足し忘れると、
ハーネスが吐く運用ファイルが未追跡のまま溜まり、やがて Maker の PR に
無関係な差分として混入します。テンプレート側の `.gitignore` と見比べて
ください:

```bash
diff <(sort .gitignore) <(sort "$D/.gitignore")
```

**`--build` を忘れないでください。** `docker/entrypoint.sh` は Dockerfile の
`COPY` でイメージに焼き込まれるため、ホスト側のファイルを差し替えただけでは
コンテナに反映されません。`--force-recreate` は既存イメージからコンテナを
作り直すだけなので、**古い entrypoint のまま静かに起動します**
（新機能が動かないのに、コンテナは正常に Up のまま）。

`.loop/**` と `docker/compose.yml` はホストからマウントされるので、こちらは
再ビルドなしで反映されます。反映されたかどうかは `/loop-doctor` か、
`docker logs <コンテナ名>` の起動ログで確認してください。

あとは通常どおりです。

```
/loop-setup
```

`detect-project` があなたのプロジェクトの `package.json` / `Cargo.toml` /
`Makefile` / `pyproject.toml` を読んで test / lint / preview を推測するので、
新規プロジェクトより設定は楽になります。

## 使い方

毎日 1 回、ターミナルで `claude` を開いて:

```
/loop-mtg
```

状況を見るだけなら `/loop-status`。

## 最初は L1 から

`.loop/config.toml` の `maturity` は**同梱の時点で `"L1"`** です。
数回の firing で「ループが何をしようとしているか」を `loops/STATE.md` で
観察してください。納得できたら自分で `"L2"` に上げます
（`L1` の間、ループは判定と報告だけを行い、Maker を起動しません）。

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

**`docker compose` は必ずリポジトリのルートディレクトリから実行してください。**
`docker/compose.yml` は `${PWD}`（= docker compose を実行したシェルのカレント
ディレクトリ）でホストと同じ絶対パスにマウントします。`docker/` の中に
`cd` してから実行すると、マウント先がホストの実際のリポジトリパスとズレて
失敗します（`/loop-setup` はこれを踏まないよう常にリポジトリのルートから
実行します。手で `docker compose` を叩くときだけ注意してください）。

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
`/loop-setup` はループ運用のための操作で、ハーネス自体の開発・変更時に
ホストでテストを回すのは対象外です。
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
