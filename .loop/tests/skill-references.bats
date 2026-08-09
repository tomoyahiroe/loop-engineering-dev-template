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

@test "スキルが数える dispatch 数の式が firing の N_TODAY と一致する" {
  # P1 で実際にズレた箇所。firing は .retry.md を除外するが、
  # /loop-status がそれを数えていた（3 対 2 の食い違い）
  FIRING_EXPR="$(grep -oE 'ls "?loops/runs/[^|]*\| *grep -v[^|]*\| *wc -l' "$REPO/.loop/bin/firing" | head -1)"
  [ -n "$FIRING_EXPR" ]
  # スキル側に maker のログを数える式があるなら、.retry.md の除外を含むこと
  while IFS= read -r line; do
    [[ "$line" == *"retry"* ]] || { echo "retry 除外を含まない集計式: $line"; false; }
  done < <(skill_files | xargs grep -ohE 'ls loops/runs/[^`]*maker[^`]*wc -l' || true)
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
