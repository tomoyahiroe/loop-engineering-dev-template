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
