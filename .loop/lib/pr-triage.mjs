// gh pr list の JSON を標準入力で受け、対象 PR を <pr>\t<issue> の形で列挙する。
// --mode needs-fix   : reviewDecision = CHANGES_REQUESTED の loop PR
// --mode auto-merge  : reviewDecision = APPROVED かつ指定ラベルを持つ loop PR (--label で指定)
//
// headRefName が loop/issue-<N> の形でない PR（人間が手で作った PR 等）は
// 対象外にする。firing 側はここで漏れなく issue 番号を得られる前提で
// dispatch-fixer / needs-human ラベル付けを行うため、issue 番号が取れない
// PR を紛れ込ませない
const argv = process.argv.slice(2);
const get = (name, def) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : def;
};
const mode = get('--mode', 'needs-fix');
const label = get('--label', 'loop:auto-merge');

let s = '';
process.stdin.on('data', (d) => { s += d; });
process.stdin.on('end', () => {
  let rows = [];
  try { rows = JSON.parse(s); } catch { process.exit(0); }
  if (!Array.isArray(rows)) process.exit(0);
  for (const p of rows) {
    const ref = String(p.headRefName || '');
    const m = /^loop\/issue-(\d+)$/.exec(ref);
    if (!m) continue;
    const labels = (p.labels || []).map((l) => l.name);
    const ok =
      mode === 'needs-fix'
        ? p.reviewDecision === 'CHANGES_REQUESTED'
        : p.reviewDecision === 'APPROVED' && labels.includes(label);
    if (ok) process.stdout.write(`${p.number}\t${m[1]}\n`);
  }
});
