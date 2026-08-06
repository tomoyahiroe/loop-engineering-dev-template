## 背景
ログイン後のリダイレクト先が固定になっており、意図した画面に戻れない。

## 受け入れ基準
- [ ] `packages/web で pnpm test -- redirect` が緑
- [ ] 手動: ログイン後、直前に見ていた画面に戻る

## 実装方針
`packages/web/src/auth/redirect.ts` に戻り先の保存を追加し、
`packages/web/src/auth/LoginForm.tsx` から呼ぶ。

## スコープ外
OAuth プロバイダの追加、セッション期限の変更

## 依存
なし
