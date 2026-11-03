# PhotoVaultの開発方針

- 今後の改修はこのPhotoVaultリポジトリで行う。Desktopにある受領元の2フォルダは変更しない。
- 共通ソースを維持し、共有スキームPhotoVault-Release-／PhotoVault-Personal-で切り替える。
- Bundle IDは両方ともcom.sugawarayuken.Album。
- Releaseは有料プランと広告あり。Personalはプレミアム常時開放、課金処理・広告なし。
- 再インストール後はPersonal由来のPIN／パスワード照合によるiCloud復元を両版で維持する。
- 完了報告には、今回の変更に対応したコピー可能なコミットコメントをコードブロックで出力する。ファイル名ごとに以下の形式を使う。

```text
【編集したファイル名】
・編集内容
・編集内容
```

- 無関係な生成物・個人設定は追加しない。必要なソース、アイコン元データ、StoreKit設定、依存関係ロックファイルは保持する。
