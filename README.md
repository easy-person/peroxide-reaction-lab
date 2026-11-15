# 過酸化水素の分解速度ラボ

生徒の測定記録を班ごとに保存し、濃度変化を表示する学習教材です。教員はメールアドレス・パスワードでログインし、保存履歴と速度定数を解析します。

共有保存・教員管理にはSupabaseを使用します。現在のプロジェクト用の公開接続情報は設定済みです。別のプロジェクトで利用する場合は [SETUP.md](SETUP.md) に従って初期設定してください。

## 公開先

- 生徒用：https://easy-person.github.io/peroxide-reaction-lab/ （教員が作成した班専用リンクから利用）
- 教員用：https://easy-person.github.io/peroxide-reaction-lab/admin.html

GitHub Pagesが画面を公開し、Supabaseが保存・認証・計算を担当します。`main` に変更を保存すると、既存のGitHub Actionsが `dist` を公開します。

## 構成

- `dist/index.html` / `student.js`：生徒の記録・保存・濃度グラフ
- `dist/admin.html` / `admin.js`：教員ログイン、班作成、提出履歴、速度定数解析、CSV
- `dist/api.js` / `config.js`：Supabase接続。公開キーのみを使用
- `supabase/schema.sql`：保存テーブル、アクセス制御、濃度・速度定数のサーバー計算
- `tests/`：計算・SQLアクセス制御・画面処理のテスト

0分の初期行と測定用の5行から開始し、測定温度は一定と仮定します。生徒の画面には濃度変化だけを表示し、速度定数は認証済みの教員にだけ返します。班は専用リンク（再発行可能）で識別します。

## 開発時の確認

Node.js 22以降で実行します。

```sh
npm ci
npm test
```

SQLテストはPGlite（PostgreSQL）を使い、Supabase相当の匿名・認証ロールで権限を確認します。Supabaseへの実接続確認とは別です。
