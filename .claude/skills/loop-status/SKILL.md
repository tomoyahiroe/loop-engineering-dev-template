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
