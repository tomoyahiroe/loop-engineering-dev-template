// Issue 本文の「構造」だけを検証する純関数群。
// 「受け入れ基準が本当に観察可能か」といった妥当性は検証しない（MTG で人間が見る）。

export function splitSections(body) {
  const sections = new Map();
  let current = null;
  for (const line of body.split(/\r?\n/)) {
    const m = /^##\s+(.+?)\s*$/.exec(line);
    if (m) {
      current = `## ${m[1]}`;
      sections.set(current, []);
      continue;
    }
    if (current) sections.get(current).push(line);
  }
  return sections;
}

function depBodyOf(sections) {
  const raw = (sections.get('## 依存') || []).join('\n').trim();
  return raw.replace(/^依存\s*[:：]\s*/, '').trim();
}

export function extractDepRefs(body) {
  const dep = depBodyOf(splitSections(body));
  if (dep === '' || dep === 'なし') return [];
  return [...dep.matchAll(/#(\d+)/g)].map((m) => m[1]);
}

export function checkIssue({ body, config, depStates = {} }) {
  const v = [];
  const sections = splitSections(body);

  for (const s of config.gate.required_sections) {
    if (!sections.has(s)) v.push(`必須セクションがない: ${s}`);
  }

  const acLines = sections.get('## 受け入れ基準') || [];
  const items = acLines
    .filter((l) => /^\s*-\s\[[ xX]\]/.test(l))
    .map((l) => l.replace(/^\s*-\s\[[ xX]\]\s*/, '').trim());

  if (items.length === 0) {
    v.push('受け入れ基準にチェックボックス（- [ ]）が 1 つもない');
  }
  for (const it of items) {
    if (!/`[^`]+`/.test(it) && !/^手動\s*[:：]/.test(it)) {
      v.push(`受け入れ基準に検証コマンドがない（コマンドで検証できないものは「手動:」で始める）: ${it}`);
    }
  }
  if (items.length > config.gate.max_acceptance_criteria) {
    v.push(`受け入れ基準が多すぎる（粒度超過）: ${items.length} > ${config.gate.max_acceptance_criteria}`);
  }

  const dep = depBodyOf(sections);
  if (sections.has('## 依存')) {
    if (dep === '') {
      v.push('依存が空。「なし」または #N を書く');
    } else if (dep !== 'なし') {
      const refs = [...dep.matchAll(/#(\d+)/g)].map((m) => m[1]);
      if (refs.length === 0) {
        v.push(`依存の書式が不正（「なし」または #N）: ${dep}`);
      }
      for (const r of refs) {
        const st = depStates[r];
        if (st !== 'CLOSED') {
          v.push(`依存 #${r} が未 close (state=${st || 'unknown'})`);
        }
      }
    }
  }

  const plan = (sections.get('## 実装方針') || []).join('\n');
  const paths = [...plan.matchAll(/`([^`]+)`/g)]
    .map((m) => m[1])
    .filter((t) => t.includes('/') || t.includes('.'));
  if (paths.length === 0) {
    v.push('実装方針に触るファイル/ディレクトリのパスがない（`path/to/file` の形で書く）');
  }
  if (paths.length > config.gate.max_files_touched) {
    v.push(`触るパスが多すぎる（粒度超過。分割する）: ${paths.length} > ${config.gate.max_files_touched}`);
  }

  return { ok: v.length === 0, violations: v };
}
