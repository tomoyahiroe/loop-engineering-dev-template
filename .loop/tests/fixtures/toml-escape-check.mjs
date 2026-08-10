// detect-project.mjs の toToml() が生成する文字列が smol-toml で
// 正しく読み戻せることを確認する単体チェック。
//
// detectProject() 自身は test/lint/preview を固定パターン
// （"pnpm test" 等）でしか生成しないため、bin/detect-project 経由の
// bats テストではバックスラッシュや制御文字を含む値を一切踏めない。
// toToml() は汎用シリアライザとして export されているので、ここでは
// lib を直接 import して壊れた TOML を生成しないことを確認する。
import { parse } from 'smol-toml';
import { toToml } from '../../lib/detect-project.mjs';

// 入れ子の引用符をエスケープしたシェルコマンドを想定した値。
// 実際の文字は: sh -c "echo \"hi\""（\ は本物の 1 文字）
const trickyTest = 'sh -c "echo \\"hi\\""';
// 制御文字（タブ・改行）も混ぜる
const trickyLint = 'printf "a\tb\nc"';

const toml = toToml({
  test: trickyTest,
  lint: trickyLint,
  preview: '',
  extraTools: ['Bash(sh:*)'],
  source: 'test',
});

let parsed;
try {
  parsed = parse(toml);
} catch (err) {
  console.error('FAIL: 生成した TOML が smol-toml でパースできない');
  console.error(err.message);
  console.error('--- 生成された TOML ---');
  console.error(toml);
  process.exit(1);
}

const okTest = parsed.project && parsed.project.test === trickyTest;
const okLint = parsed.project && parsed.project.lint === trickyLint;

if (!okTest || !okLint) {
  console.error('FAIL: パース後の値が元の値と一致しない');
  console.error({ expectedTest: trickyTest, gotTest: parsed.project && parsed.project.test });
  console.error({ expectedLint: trickyLint, gotLint: parsed.project && parsed.project.lint });
  process.exit(1);
}

process.stdout.write('OK\n');
