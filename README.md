# R2 Mountain

Cloudflare R2 専用の macOS アプリです。
バケットを Finder に表示し、大きなファイルも途中から再開できるアップロードで快適に送れます。
R2 の S3 互換 API を使いますが、接続先は R2 に絞って作っています（他の S3 互換ストレージは対象外です）。

## できること

### Finder から

- バケットが Finder のサイドバーの「場所」に「R2 Mountain」として表示されます
- ファイルは開いたときにダウンロードされ、アップロードしたファイルは完了後に Mac から自動で解放されます
- ドラッグでアップロード、新規フォルダ、名前変更、別のフォルダへの移動、削除（確認つきで R2 からも削除）

### アプリのウィンドウとメニューバーから

- 保存先のフォルダを一覧から選んでアップロード（戻る・進む、パスバー、最近の保存先）
- フォルダの行にドロップするとそのフォルダへ、それ以外の場所なら表示中のフォルダへアップロード
- 新規フォルダの作成
- 転送状況（進捗、速度、残り時間）の表示と、完了・失敗の通知

### 転送

- 64 MiB 以上はマルチパートで送信し、中断しても続きから再開
- アプリからのアップロードでは、同じ名前があると「名前 2.ext」に自動でリネームして上書きを防止

## 必要なもの

- macOS 26 以降（開発と検証は macOS 27.2 で実施）
- Xcode 27 / Swift 6、[just](https://github.com/casey/just)、[XcodeGen](https://github.com/yonaskolb/XcodeGen)
- R2 の API トークン（アクセスキー ID とシークレットアクセスキー）
- Finder 連携の署名には、Apple Developer Program の開発チーム（`project.yml` の `DEVELOPMENT_TEAM`）

## ビルドと起動

```sh
just test          # MountainCore の単体テスト（認証情報は不要）
just lint          # swift format による静的検査
just build-signed  # 開発用署名でビルド（初回はこの Mac をデバイス登録します）
just run           # ビルドして起動
```

Debug ビルドは File Provider の Testing Mode を使うため、システム設定で拡張機能をオンにする操作は不要です。

## 使い方

1. メニューバーの山のアイコンから「接続設定…」を開き、アカウント ID、バケット、アクセスキー ID、シークレットを保存します。
   シークレットは Keychain に保存されます。
2. Finder で使うときは、接続設定の「Finder に表示」をオンにします。
   Finder のサイドバーの「場所」に表示され、ほかのフォルダと同じように操作できます。
3. アプリのウィンドウから送るときは、保存先のフォルダを開いてファイルやフォルダをドロップします。
   メニューバーからは「ファイルを選択…」で送れます。

ウィンドウの一覧では Return または ⌘↓ でフォルダを開き、⌘↑ で上の階層、⌘[ と ⌘] で戻る・進む、⇧⌘N で新規フォルダ、⌘O でアップロードです。
Finder での削除は「すぐに削除」（⌥⌘⌫ または右クリック）で行い、確認のあと R2 からも削除されます。

## 構成

| パス | 内容 |
| --- | --- |
| `Packages/MountainCore` | R2 用の S3 クライアント（SigV4）、アップロードエンジン、Finder 用の項目の対応表と操作、表示用の文言。UI に依存せず `swift test` で検証 |
| `App` | SwiftUI と AppKit の UI。メニューバー、メインウィンドウ、設定、Finder 連携の管理 |
| `FileProvider` | Finder 連携の File Provider 拡張（Apple の API と MountainCore の橋渡し） |
| `Shared` | アプリと拡張で共有する接続先と資格情報 |
| `scripts` | 実 R2 での契約検証ツール（開発用） |

## ドキュメント

- [フェーズ1仕様書](docs/superpowers/specs/2026-11-04-s3-mountain-phase1-design.md) / [実装計画](docs/superpowers/plans/2026-11-04-s3-mountain-phase1-implementation.md)
- [フェーズ2（Finder マウント）仕様書](docs/superpowers/specs/2026-11-05-s3-mountain-phase2-finder-mount-design.md) / [実装計画](docs/superpowers/plans/2026-11-05-s3-mountain-phase2-finder-mount.md)
- [実 R2 の検証手順](docs/r2-integration-testing.md)
- [検証記録](docs/validation.md)

アプリ名は「S3 Mountain」から「R2 Mountain」に変わりました。
保存済みの設定と資格情報を引き継ぐため、Bundle ID（`run.kan.s3mountain`）などの内部の識別子は変えていません。
