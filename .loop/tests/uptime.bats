#!/usr/bin/env bats
# Loop 稼働集計のテスト。
#
# この機能の目的は表を作ることではなく、「1 発火に何分かかっているか」を
# 見えるようにすること。したがって重点は 3 つ:
#   1. 計測前の期間を 0m00s と混同しない（mmm-loops が実際に踏んだ）
#   2. KINDS の全要素が集計の分類に載っている（増えた分が黙って落ちない）
#   3. 完全に読み取り専用

load helpers

setup() {
  TMP="$(mktemp -d)"
  make_test_repo "$TMP"
  UP="$LOOP_REAL_DIR/lib/uptime.mjs"
}

teardown() { cleanup_test_repo; rm -rf "$TMP"; }

# uptime.mjs の関数を 1 つ呼んで結果を出す
u() { node -e "$2" "$UP"; }

# --- 分類の網羅（最重要） ---------------------------------------------------

@test "KINDS の全要素が OUTCOME_BUCKETS に載っている" {
  # 載っていない kind は「結末不明」に落ちて数字が狂う。値域を増やしたら
  # 分類も更新する、を機械的に守る
  run node -e '
    import(process.argv[1]).then((m) => {
      process.stdout.write(m.missingOutcomeKinds().join(","));
    })' "$UP"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "分類に無い kind: $output"; false; }
}

# --- 表示幅（日本語で罫線がズレない） ---------------------------------------

@test "全角を 2 桁、半角を 1 桁として数える" {
  run node -e '
    import(process.argv[1]).then((m) => {
      process.stdout.write([
        m.width("abc"), m.width("日付"), m.width("発火 3"), m.width(""),
      ].join(","));
    })' "$UP"
  [ "$output" = "3,4,6,0" ]
}

@test "罫線の各行の表示幅が揃う" {
  run node -e '
    import(process.argv[1]).then((m) => {
      const t = m.table(["日付", "発火"], [["08-12", "3"], ["合計", "12"]], ["left", "right"]);
      const ws = t.split("\n").map(m.width);
      process.stdout.write(new Set(ws).size === 1 ? "ok" : "ズレ: " + ws.join(","));
    })' "$UP"
  [ "$output" = "ok" ]
}

# --- 時間の整形 -------------------------------------------------------------

@test "所要時間を h/m/s で整形する" {
  run node -e '
    import(process.argv[1]).then((m) => {
      process.stdout.write([
        m.formatDuration(1800), m.formatDuration(893000),
        m.formatDuration(31560000), m.formatDuration(null),
      ].join("|"));
    })' "$UP"
  [ "$output" = "2s|14m53s|8h46m|–" ]
}

@test "閾値の指定を解釈する" {
  run node -e '
    import(process.argv[1]).then((m) => {
      process.stdout.write([
        m.parseThreshold("30m"), m.parseThreshold("2h"),
        m.parseThreshold("90"), m.parseThreshold("なんとか"),
      ].join(","));
    })' "$UP"
  [ "$output" = "1800000,7200000,90000," ]
}

# --- tick への畳み込み ------------------------------------------------------

@test "start から finish までを 1 tick にまとめる" {
  run node -e '
    import(process.argv[1]).then((m) => {
      const t = m.foldTicks([
        { ts: "2026-08-12T01:00:00+09:00", kind: "start" },
        { ts: "2026-08-12T01:00:01+09:00", kind: "dispatch", issue: 7 },
        { ts: "2026-08-12T01:00:02+09:00", kind: "finish", duration_ms: 1800, rc: 0, outcome: "dispatch" },
      ]);
      process.stdout.write(`${t.length}:${t[0].outcome}:${t[0].duration_ms}`);
    })' "$UP"
  [ "$output" = "1:dispatch:1800" ]
}

@test "finish の無い tick を落とさない（ハングの検出に要る）" {
  run node -e '
    import(process.argv[1]).then((m) => {
      const t = m.foldTicks([
        { ts: "2026-08-12T01:00:00+09:00", kind: "start" },
        { ts: "2026-08-12T03:00:00+09:00", kind: "start" },
        { ts: "2026-08-12T03:00:02+09:00", kind: "finish", duration_ms: 100, rc: 0, outcome: "idle" },
      ]);
      process.stdout.write(`${t.length}:${t[0].finish === null}`);
    })' "$UP"
  [ "$output" = "2:true" ]
}

@test "start 導入前の判断イベントも 1 tick として数える" {
  # 捨てると計測前の期間が表から丸ごと消え、「その頃は動いていなかった」
  # ように見えてしまう
  run node -e '
    import(process.argv[1]).then((m) => {
      const t = m.foldTicks([
        { ts: "2026-08-10T01:00:00+09:00", kind: "idle" },
        { ts: "2026-08-10T03:00:00+09:00", kind: "dispatch", issue: 1 },
      ]);
      process.stdout.write(`${t.length}:${t[0].duration_ms}:${t[1].outcome}`);
    })' "$UP"
  [ "$output" = "2:null:dispatch" ]
}

# --- (計測前) の扱い --------------------------------------------------------

@test "計測データが無い先頭の期間を (計測前) としてまとめる" {
  run node -e '
    import(process.argv[1]).then((m) => {
      const rows = [
        { key: "2026-08-10", fired: 2, skip: 0, failed: 0, dispatch: 0, idle: 2, unknown: 0, duration_ms: 0, measured: 0 },
        { key: "2026-08-11", fired: 3, skip: 0, failed: 0, dispatch: 0, idle: 3, unknown: 0, duration_ms: 0, measured: 0 },
        { key: "2026-08-12", fired: 4, skip: 0, failed: 0, dispatch: 1, idle: 3, unknown: 0, duration_ms: 5000, measured: 4 },
      ];
      const { prefix, rest } = m.foldMeasuringPrefix(rows);
      process.stdout.write(`${prefix.key}|${prefix.fired}|${rest.length}`);
    })' "$UP"
  [ "$output" = "08-10〜08-11|5|1" ]
}

@test "全期間に計測データがあれば (計測前) の行を作らない" {
  run node -e '
    import(process.argv[1]).then((m) => {
      const rows = [{ key: "2026-08-12", fired: 1, skip: 0, failed: 0, dispatch: 0, idle: 1, unknown: 0, duration_ms: 10, measured: 1 }];
      const { prefix, rest } = m.foldMeasuringPrefix(rows);
      process.stdout.write(`${prefix}|${rest.length}`);
    })' "$UP"
  [ "$output" = "null|1" ]
}

# --- 閾値と未発火 -----------------------------------------------------------

@test "閾値を超えた発火だけを長い順に返す" {
  run node -e '
    import(process.argv[1]).then((m) => {
      const t = [
        { start: "a", duration_ms: 1000 },
        { start: "b", duration_ms: 8340000 },
        { start: "c", duration_ms: 1680000 },
      ];
      process.stdout.write(m.overThreshold(t, 1800000).map((x) => x.start).join(","));
    })' "$UP"
  [ "$output" = "b" ]
}

@test "発火するはずのスロットに start が無ければ未発火として拾う" {
  # ロック衝突は firing の中では記録できない（supercronic が起動しないため）
  run node -e '
    import(process.argv[1]).then((m) => {
      const t = [{ start: "2026-08-12T01:00:00+09:00" }, { start: "2026-08-12T05:00:00+09:00" }];
      const out = m.missingSlots(t, [1, 3, 5], "2026-08-12T01:00:00+09:00", "2026-08-12T05:00:00+09:00");
      process.stdout.write(out.join(","));
    })' "$UP"
  [ "$output" = "2026-08-12T03" ]
}

# --- CLI --------------------------------------------------------------------

seed_events() {
  cat > "$REPO_ROOT/loops/events.jsonl" <<'JSON'
{"ts":"2026-08-10T01:00:00+09:00","kind":"idle"}
{"ts":"2026-08-12T01:00:00+09:00","kind":"start"}
{"ts":"2026-08-12T01:00:01+09:00","kind":"dispatch","issue":7}
{"ts":"2026-08-12T01:28:00+09:00","kind":"finish","duration_ms":1680000,"rc":0,"outcome":"dispatch"}
JSON
}

@test "3 つの表を出す" {
  seed_events
  run "$LOOP_REAL_DIR/bin/loop-uptime" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"稼働"* ]]
  [[ "$output" == *"稼働時間の内訳"* ]]
  [[ "$output" == *"を超えた発火"* ]]
  [[ "$output" == *"(計測前)"* ]]
}

@test "--plain はタブ区切りで罫線を描かない" {
  seed_events
  run "$LOOP_REAL_DIR/bin/loop-uptime" --all --plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"┌"* ]]
  [[ "$output" == *$'\t'* ]]
}

@test "完全に読み取り専用（実行してもファイルが変わらない）" {
  seed_events
  local before after
  before="$(find "$REPO_ROOT/loops" -type f -exec shasum {} \; | shasum)"
  run "$LOOP_REAL_DIR/bin/loop-uptime" --all
  [ "$status" -eq 0 ]
  after="$(find "$REPO_ROOT/loops" -type f -exec shasum {} \; | shasum)"
  [ "$before" = "$after" ] || { echo "loops/ の中身が変わった"; false; }
}

@test "events.jsonl が無ければ理由を言って 1 で終わる" {
  run "$LOOP_REAL_DIR/bin/loop-uptime" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"ありません"* ]]
}

@test "対象月に記録が無ければ --all を案内する" {
  seed_events
  run "$LOOP_REAL_DIR/bin/loop-uptime" --month 2020-01
  [ "$status" -eq 1 ]
  [[ "$output" == *"--all"* ]]
}
