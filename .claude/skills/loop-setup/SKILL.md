---
name: loop-setup
description: dev-loop テンプレートをクローンした直後の対話セットアップ。前提確認 → 依存インストール → プロジェクト検出 → config 生成 → Dockerfile 提案 → リモート確認 → ラベル作成 → 起動 → 認証 → 健全性チェックまでを 1 本で通す。「/loop-setup」「セットアップして」「初期設定」が合図
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

`docker` / `git` / `node` があるか確認する。`gh` は無くてもよい（⑦でコンテナ経由に切り替える）。

- `docker` はコマンドの有無だけでなく `docker info` でデーモンに到達できるかも
  確認する（コマンドはあってもデーモンが止まっていると⑧のビルドまで気づけない）
- `node` は **ホスト側に必要**。`.loop/bin/*` は薄いシェルのラッパで、中身は
  node で動く（Node.js 18 以上）。②以降でこのスキルが叩くコマンド
  （`.loop/bin/detect-project`、`.loop/bin/loop-doctor`）も、毎朝の
  `/loop-mtg` が①で叩く `loop-doctor` もホストの node を使う。
  コンテナの中にも node はあるが、それが立ち上がるのは⑧なので間に合わない

無いものがあれば、入れ方を示して**そこで止める**。デーモンに到達できなければ、
起動を促して**そこで止める**。

## ② `.loop` の依存をインストール

`.loop/node_modules` は gitignore されていて、クローン直後には存在しない。
入れないまま②以降へ進むと `.loop/bin/*` が軒並み `ERR_MODULE_NOT_FOUND` で
落ちる（コンテナ側の依存インストールは⑧の中で起きるので、3 ステップ遅い）。

```bash
cd .loop && npm ci --omit=dev
```

既に `.loop/node_modules` があり、次のコマンドが値を返すなら済んでいる（飛ばす）:

```bash
.loop/bin/loop-config get maturity
```

失敗したら理由を示して**そこで止める**（ネットワーク未接続・レジストリ到達不可など）。

## ③ プロジェクトの検出

```
.loop/bin/detect-project
```

TOML 断片が返る。冒頭のコメントに検出元が書いてある。

これをユーザーに見せて確認を取る。**「これでいいですか」ではなく
「こう検出しました。違っていれば教えてください」**の形で聞く。

`test` と `lint` が両方空だった場合は、テストを持たないプロジェクトなのか、
検出に失敗しただけなのかを聞く。**空のまま進めてよい**（その場合ループは
テストを実行しないが、それは正しい設定でありうる）。

## ④ config.toml の生成

`.loop/config.toml` に③の結果を反映する。

**既存の値を尊重し、差分だけ当てる。** このファイルはユーザー所有
（テンプレート同期で触られない）なので、上書きしてはいけない。
既に値が入っているキーは、変更前に確認を取る。

`maturity` はテンプレート同梱の時点で `L1` になっている（数回観察してから
昇格する、という運用のため）。**`L1` のままにする。**
ユーザーが自分で `L2` / `L3` に上げていれば触らない。

**`[project]` の test/lint と `[agents.claude] extra_tools` は必ずセットで書く。**
片方だけの状態で先に進んではいけない。③の検出結果は既に対応が取れている。

`extra_tools` は**全ロール（Maker / Verifier / Fixer）に効く**ので、
狭い許可で足りるなら広げない。サブコマンドまで絞った形
（例: `Bash(pnpm test:*)`）も有効。

## ⑤ Dockerfile の提案

③で検出したツールチェーンが `docker/Dockerfile` に無ければ、追記すべき行を
**提示して承認を取る**。承認なしに書き換えない。

追記はマーカーで囲む:

```dockerfile
# >>> loop-setup: プロジェクトのツールチェーン
RUN corepack enable && corepack prepare pnpm@latest --activate
# <<< loop-setup
```

既にマーカーがあれば、その中身を置き換える（マーカー外は触らない）。

## ⑥ リモートの確認（このリポジトリを自分のものにする）

テンプレートをクローンしただけだと、`origin` は**テンプレート側のリポジトリ**を
指したままになっている。その状態で⑦のラベル作成や以降の push を行うと、
ラベルも Issue も PR も**他人のリポジトリ**に向かう。

```bash
git remote -v
```

現在の `origin` をユーザーに見せて、**「ループを回すのはこのリポジトリで
合っていますか」と確認を取る**。

**確認が取れるまで、`gh` の書き込み系コマンド（ラベル作成など）も push も
実行しない。** 読み取り（`git remote -v` / `gh repo view`）だけにとどめる。

違う場合は、次のどちらかを案内して**そこで止める**:

```bash
# 新しく自分のリポジトリを作って origin を差し替える
gh repo create <name> --private --source=. --remote=origin --push

# 既にリポジトリがあるなら URL を差し替える
git remote set-url origin <URL>
```

テンプレート本体をそのまま開発している場合はこのままでよいが、
**その場合もユーザーの明示の確認を取る**（黙って進めない）。

## ⑦ ラベルの作成

ループが動くのに必要な 3 つを作る。**これが無いと待ち行列も
エスカレーションもエラーを出さずに機能しない。**

⑥でリモートの確認が取れていること。ホストに `gh` があり認証済みならホストで実行する。

```bash
gh label create loop:ready      --color 0E8A16 --description "ゲート通過済み。次の firing で着手する" --force
gh label create needs-human     --color D93F0B --description "人間の判断が要る。ループは触らない"      --force
gh label create loop:auto-merge --color 1D76DB --description "L3 で自動 merge を許可する（人間が付ける）" --force
```

ホストに `gh` が無い、または未認証の場合はこの場では実行せず、**⑨で
`gh auth login` を済ませたあと**にコンテナ経由で実行する（コンテナ内の
`gh` は⑨より前は未認証なので、ここで叩いても失敗する）:

```bash
docker compose -f docker/compose.yml exec loop bash -lc '
gh label create loop:ready      --color 0E8A16 --description "ゲート通過済み。次の firing で着手する" --force
gh label create needs-human     --color D93F0B --description "人間の判断が要る。ループは触らない"      --force
gh label create loop:auto-merge --color 1D76DB --description "L3 で自動 merge を許可する（人間が付ける）" --force
'
```

`--force` を付けているので何度実行しても安全。

## ⑧ ビルドと起動

**必ずリポジトリのルートから実行する。** `docker/compose.yml` は `${PWD}` で
ホストと同じ絶対パスにマウントするため、`docker/` の中から叩くとマウント先がズレる。

```bash
docker compose -f docker/compose.yml up -d --build
```

## ⑨ 認証（ユーザーの手作業）

ここだけは人間がブラウザで認可する必要がある。コマンドを提示して、
**終わったら教えてもらう**。勝手に次へ進まない。

```bash
docker compose -f docker/compose.yml exec loop claude
docker compose -f docker/compose.yml exec loop gh auth login
```

認証情報は名前付き volume に保存されるので、コンテナを作り直さない限り
2 回目以降は不要だと伝える。

**⑦でラベル作成を先送りしていた場合**（ホストに `gh` が無い、または
未認証だった場合）は、ここで `gh auth login` が終わった直後に、⑦に示した
コンテナ経由のコマンドでラベルを作る。忘れると、待ち行列（`loop:ready`）も
エスカレーション（`needs-human`）もエラーを出さないまま機能しない状態の
まま、セットアップが完了したことになってしまう。

## ⑩ 健全性チェック

```
.loop/bin/loop-doctor
```

全項目の合否を見せて終わる。NG があれば直し方を示す。
`claude 認証` は非対話では確認できないため常に SKIP になる（失敗ではない）。

最後に次の一歩を 1 行で伝える: **「次は `/loop-mtg` です（頻度は
`loop-mtg` のスキル説明のとおり）」**。

`maturity` が `L1` の間、ループは判定と報告だけを行い dispatch しない。
数回の firing を `loops/STATE.md` で観察して納得したら、`.loop/config.toml` の
`maturity` を `"L2"` に上げる — と伝えて終わる。

## 禁止

- 承認なしに `docker/Dockerfile` を書き換えること
- `.loop/config.toml` を丸ごと上書きすること
- `[project]` を設定して `extra_tools` を空のまま先に進むこと
- `origin` がどこを指しているかの確認を取らずに `gh` の書き込みや push をすること
- 認証が終わったことを確認せずに⑩へ進むこと
- 失敗を黙って飛ばして「完了しました」と報告すること
