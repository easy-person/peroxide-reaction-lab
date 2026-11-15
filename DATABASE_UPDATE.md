# SQLエディタを使わずに「クラスを削除」を有効にする

初回だけ、Supabase管理用アクセストークンをGitHubに登録します。教員・生徒のログインパスワードは不要です。ブラウザー用の公開キーでは管理設定を変更できません。

1. https://supabase.com/dashboard/account/tokens を開き、**Generate new token** で管理用トークンを作成します。名前は `peroxide-database-setup` などにします。期限の選択肢があれば短い期限を選びます。
2. https://github.com/easy-person/peroxide-reaction-lab/settings/secrets/actions を開き、**New repository secret** を押します。
3. Nameを `SUPABASE_ACCESS_TOKEN`、Secretを作成したトークンにして保存します。**トークンはチャットやソースコードに貼り付けないでください。**
4. GitHubの **Actions → データベースの機能を更新 → Run workflow** を実行します。ブランチは `main` を選びます。
5. 緑のチェックが付けば初期設定は完了です。教員画面を再読み込みし、誤作成したクラスの **クラスを削除** を押します。
6. 今回の設定が終わったらGitHubの `SUPABASE_ACCESS_TOKEN` シークレットを削除し、Supabaseの管理用トークンも失効できます。日常のクラスの削除には不要です。

## 削除の範囲

- 作成した教員だけが、自分のクラスを削除できます。
- クラスと保存済みの実験記録をまとめて削除できます。
- 削除するとクラスは一覧から消え、以前のリンクも使えなくなります。
- 記録を残す場合は「クラス専用リンクを削除」でリンクのみを無効にします。
- 「クラスを削除」は取り消せません。必要なら削除前に教員画面からCSVを保存してください。

ワークフローは今回の機能追加用SQLだけを実行します。初期テーブルを作成する `supabase/schema.sql` は再実行しません。
