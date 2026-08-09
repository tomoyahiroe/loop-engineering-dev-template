---
name: loop-doctor
description: ハーネスの健全性を検査する読み取り専用スキル。依存の欠落・ラベル欠落・gh の認証切れ・設定の不整合・発火回数のズレ・worktree の残骸など、放っておくと静かに壊れる箇所をまとめて確認する。「/loop-doctor」「ループの調子を見て」「セットアップ壊れてない?」が合図
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
- **SKIP** — 確認できなかった（例: コンテナが動いていないので中を見られない、
  config を読めないので設定を突き合わせられない）。失敗ではない。
  **SKIP を「たぶん大丈夫」と言い換えない**

`claude 認証` は常に SKIP になる。非対話で認証の有効性を確かめる手段が
無いため（`claude --version` は認証が切れていても成功するので、
これを「認証済み」とは報告しない）。

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
| 実行環境 | ホストに Node.js 18 以上を入れる／`cd .loop && npm ci --omit=dev` で依存を入れる。**これは `config.toml` の中身とは無関係**（`.loop/node_modules` は gitignore されているので、クローン直後は必ずこの状態） |
| config 構文 | `.loop/config.toml` の TOML 構文を直す（NG 行にパーサのメッセージが 1 行だけ添えてある） |
| project/tools 対応 | `.loop/config.toml` の `[agents.claude] extra_tools` に、`[project]` の test/lint を実行できるツールを足す。ただしこの検査は `extra_tools` しか見ない（`tools_<role>` で既に許可済みなら誤警報の可能性あり）。`extra_tools` は全ロールに効くので、狭い許可で足りるなら広げない（`Bash(pnpm test:*)` のようにサブコマンドまで絞った形でよい） |
| cron 発火時刻 | `.loop/config.toml` の `[schedule] firings_per_day` を **24 を割り切る整数**にする。NG 行には実際に生成された発火時刻と、`gen-crontab` が何をどう丸めたかが出る |
| worktree 残骸 | `git worktree remove --force <path>`（残骸 1 件につき NG が 1 行出る。パスはその行のものをそのまま使う） |
| コンテナ稼働 | `docker compose -f docker/compose.yml up -d` |
| claude CLI | `docker compose -f docker/compose.yml exec loop claude` |
| gh 認証 | `docker compose -f docker/compose.yml exec loop gh auth login` |
| ラベル | `/loop-setup` を再実行する（冪等なので安全） |

SKIP の項目に「直し方」は無い。確認できなかった理由が行に書いてあるので、
それを解消してからもう一度 `loop-doctor` を実行する（`claude 認証` だけは
常に SKIP なので、気になるときは
`docker compose -f docker/compose.yml exec loop claude` を手で開いて確かめる）。

## 禁止

- 検査結果を要約しすぎて NG を埋もれさせること
- 自分で設定を直すこと（読み取り専用）
- `loop-doctor` を実行せずに「たぶん大丈夫です」と答えること
