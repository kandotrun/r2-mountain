# S3 Mountain

Cloudflare R2 に大容量ファイルを送る macOS アプリの開発リポジトリです。
メニューバー版で途中再開できるアップロードを作り、その後に Finder 連携を追加します。

現在は設計と実装計画を用意した段階です。
アプリ本体、ビルド手順、実 R2 での転送はまだ実装、検証していません。

- [フェーズ1仕様書](docs/superpowers/specs/2026-11-04-s3-mountain-phase1-design.md)
- [フェーズ1実装計画](docs/superpowers/plans/2026-11-04-s3-mountain-phase1-implementation.md)
- [検証記録](docs/validation.md)

フェーズ1は macOS 26以降、自分の Mac、R2 の1バケットを対象にします。
認証情報はコードに置かず、アプリの Secret は Keychain に保存する設計です。
指定された `drive` バケットへの読み取り接続は確認できています。
アプリからの大容量転送と Finder 連携は、これから実装して検証します。
