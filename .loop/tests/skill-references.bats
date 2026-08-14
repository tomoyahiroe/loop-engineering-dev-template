#!/usr/bin/env bats
# スキル（散文）が参照しているコマンド・パス・設定キーが、
# 実際のコードに存在することを機械的に照合する。
#
# P1 では、プロンプトが許可リスト外のコマンドを指示していた件と、
# /loop-status の集計式が firing とズレていた件を、どちらもテストが
# 捕まえられなかった。散文はテストされないという構造的な穴を塞ぐ。

load helpers

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

skill_files() {
  find "$REPO/.claude/skills" -name SKILL.md
}

@test "全スキルのフロントマターに name と description があり、name がディレクトリ名と一致する" {
  while IFS= read -r f; do
    dir="$(basename "$(dirname "$f")")"
    run node -e '
      const fs=require("fs");
      const [file,dir]=process.argv.slice(1);
      const t=fs.readFileSync(file,"utf8");
      const m=/^---\n([\s\S]*?)\n---/.exec(t);
      if(!m) throw new Error(dir+": フロントマターがない");
      if(!/^description:\s*\S/m.test(m[1])) throw new Error(dir+": description がない");
      const n=/^name:\s*(.+)$/m.exec(m[1]);
      if(!n) throw new Error(dir+": name がない");
      if(n[1].trim()!==dir) throw new Error(dir+": name 不一致 "+n[1].trim());
    ' "$f" "$dir"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done < <(skill_files)
}

@test "スキルが参照する .loop/bin のコマンドがすべて実在し、実行可能である" {
  MISSING=""
  while IFS= read -r cmd; do
    [ -x "$REPO/$cmd" ] || MISSING="$MISSING $cmd"
  done < <(skill_files | xargs grep -ohE '\.loop/bin/[a-z-]+' | sort -u)
  [ -z "$MISSING" ] || { echo "実在しない、または実行権限がない:$MISSING"; false; }
}

@test "スキルが参照する loop-config のキーがすべて defaults.toml に存在する" {
  MISSING=""
  while IFS= read -r key; do
    "$REPO/.loop/bin/loop-config" get "$key" >/dev/null 2>&1 || MISSING="$MISSING $key"
  done < <(skill_files | xargs grep -ohE 'loop-config get [a-z_.]+' | awk '{print $3}' | sort -u)
  [ -z "$MISSING" ] || { echo "defaults.toml に無いキー:$MISSING"; false; }
}

@test "スキルが参照する loops/ のパスが .gitignore と矛盾しない" {
  # スキルが「読め」と言っているファイルが gitignore されていたら、
  # クローン直後には存在せず、指示が空振りする
  BAD=""
  while IFS= read -r p; do
    case "$p" in
      *"*"*) continue ;;  # glob は対象外
    esac
    if git -C "$REPO" check-ignore -q "$p" 2>/dev/null; then BAD="$BAD $p"; fi
  done < <(skill_files | xargs grep -ohE 'loops/[A-Za-z0-9_./-]+' | sort -u)
  [ -z "$BAD" ] || { echo "gitignore されているのにスキルが参照:$BAD"; false; }
}

@test "スキルが dispatch 数を自分で集計していない" {
  # P1 で実際にズレた箇所。firing は .retry.md を除外するが、
  # /loop-status がそれを数えていた（3 対 2 の食い違い）。213 件のテストが
  # 1 件も捕まえられなかった。散文の集計式はテストできないため、集計は
  # コントロールプレーンの実装に一本化した（設計書 2026-08-12 の決定 7）。
  #
  # 以前はここで「スキルの式が firing の式と一致するか」を照合していたが、
  # 集計そのものをスキルから無くしたので、規則を「書き戻さないこと」に
  # 反転させる。firing と API 側の一致は control-plane.bats が実データで見る
  local offenders
  offenders="$(skill_files | xargs grep -l 'loops/runs' 2>/dev/null \
    | xargs grep -l 'maker' 2>/dev/null \
    | xargs grep -lE 'wc[[:space:]]*-l' 2>/dev/null || true)"
  [ -z "$offenders" ] || {
    echo "スキルが dispatch 数を自分で数えている: $offenders"
    echo "集計は .loop/lib/control-plane.mjs の countDispatchedToday に一本化すること"
    false
  }
}

@test "プロンプトが指示する gh コマンドが、その role の許可リストに含まれている" {
  # P1 の F1 と同じ形。prompts/<role>.md が呼ぶ gh のサブコマンドが
  # agents.claude.tools_<role> に無ければ、実 provider 下で静かに失敗する
  BAD=""
  for role in maker verifier fixer; do
    P="$REPO/.loop/prompts/$role.md"
    [ -f "$P" ] || continue
    ALLOW="$("$REPO/.loop/bin/loop-config" get "agents.claude.tools_$role" 2>/dev/null)"
    while IFS= read -r c; do
      printf '%s' "$ALLOW" | grep -q "Bash($c" || BAD="$BAD [$role: $c]"
    done < <(grep -ohE 'gh [a-z]+ [a-z]+' "$P" | sort -u)
  done
  [ -z "$BAD" ] || { echo "許可リスト外のコマンドを指示:$BAD"; false; }
}

# --- entrypoint（散文ではないが、同じ「参照先が実在するか」の照合） --------

@test "entrypoint が起動するコマンドが実在し、実行可能である" {
  # entrypoint.sh は bats から直接動かせない（コンテナ前提）ため、
  # 参照している実行ファイルが実在することだけでも機械的に守る。
  # ここがズレると、コンテナを起動して初めて気づくことになる
  local refs r
  refs="$(grep -oE '\$LOOP_DIR/bin/[a-z-]+' "$REPO/docker/entrypoint.sh" \
          | sed 's|\$LOOP_DIR/bin/||' | sort -u)"
  [ -n "$refs" ] || { echo "entrypoint.sh から \$LOOP_DIR/bin の参照を抽出できない"; false; }

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ -x "$REPO/.loop/bin/$r" ] \
      || { echo "entrypoint.sh が参照する .loop/bin/$r が無いか実行可能でない"; false; }
  done <<< "$refs"
}

@test "entrypoint が読む loop-config のキーが defaults.toml に存在する" {
  local keys k
  keys="$(grep -oE 'loop-config" get [a-z_.]+' "$REPO/docker/entrypoint.sh" \
          | sed 's/.*get //' | sort -u)"
  [ -n "$keys" ] || { echo "entrypoint.sh から loop-config のキーを抽出できない"; false; }

  while IFS= read -r k; do
    [ -n "$k" ] || continue
    run "$REPO/.loop/bin/loop-config" get "$k"
    [ "$status" -eq 0 ] || { echo "entrypoint.sh が読む $k が設定に無い"; false; }
  done <<< "$keys"
}

@test "loop-setup が compose のプロジェクト名を決める手順を含む" {
  # 抜けていると、セットアップ直後の /loop-doctor がいきなり NG を出す。
  # さらに 2 つ目のループを立てたときに互いのコンテナを奪い合う
  run grep -c "compose-env" "$REPO/.claude/skills/loop-setup/SKILL.md"
  [ "$output" -ge 1 ]
}

@test "compose が Claude の設定ホームを認証 volume の中に向けている" {
  # 既定では ~/.claude.json だけが volume の外に残り、コンテナを作り直す
  # たびに消える。Maker/Verifier の実行ログに毎回ノイズが混ざる
  local mountpoint
  mountpoint="$(grep -oE 'loop-claude-auth:[^ ]+' "$REPO/docker/compose.yml" | head -1 | cut -d: -f2)"
  [ -n "$mountpoint" ] || { echo "compose.yml から認証 volume のマウント先を取れない"; false; }

  run grep -c "CLAUDE_CONFIG_DIR=$mountpoint" "$REPO/docker/compose.yml"
  [ "$output" -eq 1 ] || {
    echo "CLAUDE_CONFIG_DIR が認証 volume のマウント先 ($mountpoint) を指していない"
    false
  }
}
