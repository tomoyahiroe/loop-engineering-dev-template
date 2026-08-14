---
name: loop-status
description: Loop に積まれているタスクの現在地を一覧する読み取り専用スキル。loop:ready の待ち行列、open PR と Verifier 判定、in-flight worktree、本日の dispatch 残数、次の firing をまとめて表示。「/loop-status」「ループの状況」「今何が積まれてる?」が合図
---

# /loop-status — Loop の現在地

**読み取り専用。** ラベル操作・commit・ファイル書き込みは一切しない
（現状把握と決定は `/loop-mtg` の仕事）。

## 集め方

**集計は自分でしない。** コントロールプレーンの API を叩いて、その値を
そのまま出す。

```bash
PORT="$(.loop/bin/loop-config get ui.port)"
curl -s --max-time 5 "http://127.0.0.1:$PORT/api/status"
curl -s --max-time 5 "http://127.0.0.1:$PORT/api/events?limit=10"
curl -s --max-time 5 "http://127.0.0.1:$PORT/api/issues"
```

**この分担は意図的です。** P1 では、このスキルが「`loops/runs` を数える式」を
散文で持っていて、`firing` 側の式とズレた（`.retry.md` を除外し忘れ、
3 対 2 の食い違い）。213 件のテストが 1 件も捕まえなかった。散文の集計式は
テストできないので、集計は実装に一本化してある。**ここに集計式を書き戻さない
こと。**

API から取れないものだけ、直接見る:

- **in-flight worktree**: `git worktree list` の `-issue-<N>`
  （Maker 作業中、または残骸）
- **プレビュー**: `.loop/bin/preview status`

## API が応答しないとき

コンテナが動いていない可能性が高い。**その事実こそが最も重要な報告**なので、
取り繕って別の手段で数字を集めない。

1. 「コントロールプレーンに接続できない。ループが動いていない可能性がある」
   と最初に伝える
2. `/loop-doctor` を案内する（原因の切り分けはあちらの仕事）
3. 待ち行列だけは GitHub から直接見せてよい:
   `gh issue list --label loop:ready --state open --json number,title`

本日の dispatch 数・予算・次の firing は**この経路では出さない**。
`firing` と同じ数え方をこのスキルに書き戻すことになり、P1 と同じズレが
再発するため。

## 出力フォーマット

```
## Loop の現在地（HH:MM 時点）
| 順 | Issue | タイトル | 状態 |

要人間: （あれば列挙、なければ「なし」）
本日 dispatch: X/N（open PR Y/M）
次の firing: HH:MM（あと N 分）
直近の firing: （events の先頭 3 件を 1 行ずつ）
プレビュー: （status の 1 行）
```

待ち行列は API の `ready` の順（番号の昇順）で出す。これが実行順
（dispatch は 1 firing 1 件）。表は 1 画面に収める。タイトルは 40 字で切る。
音声読み上げはしない（即答性優先）。

画面で見たい場合は `http://127.0.0.1:<ui.port>` を案内する。

「どれくらい動いているか」「遅い発火はどれか」を聞かれたら、この場で集計せず
`.loop/bin/loop-uptime` を案内する（日別の発火数・稼働時間・長時間発火の一覧を出す）。
