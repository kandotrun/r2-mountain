# S3 Mountain フェーズ2：Finder マウント 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** R2 バケットを File Provider で Finder に表示し、閲覧、ダウンロード、アップロード、フォルダ作成、名前変更・移動、削除を Finder から行えるようにする。

**Architecture:** ホストアプリが設定と資格情報を App Group と共有 Keychain に書き、ドメインを登録する。
拡張機能は Apple の API と MountainCore の橋渡しだけを行う。
識別子の対応表、S3 の操作、再開できるアップロードは MountainCore に置き、`swift test` で TDD する。

**Tech Stack:** Swift 6、FileProvider（NSFileProviderReplicatedExtension）、SQLite3（システム同梱）、Swift Testing、XcodeGen、just

契約（型と関数のシグネチャ）は[設計書](../specs/2026-11-05-s3-mountain-phase2-finder-mount-design.md)の「公開 API」を正とする。

---

## ファイル構成

| パス | 責務 |
| --- | --- |
| `Packages/MountainCore/Sources/MountainCore/Mount/ItemRecord.swift` | 項目の値型 |
| `Packages/MountainCore/Sources/MountainCore/Mount/ItemStore.swift` | SQLite の対応表と変更履歴 |
| `Packages/MountainCore/Sources/MountainCore/Mount/MountStore.swift` | `S3MountStore` プロトコルと `S3ListedObject` |
| `Packages/MountainCore/Sources/MountainCore/S3/S3Client+Mount.swift` | `S3Client` の準拠（ダウンロード、コピー、削除、全件一覧、上書き PUT） |
| `Packages/MountainCore/Sources/MountainCore/Mount/ExactUploader.swift` | キーを変えない再開可能なアップロード |
| `Packages/MountainCore/Sources/MountainCore/Mount/MountOperations.swift` | フォルダ作成、移動、削除 |
| `Shared/SharedConfiguration.swift` | App Group の接続先、Info.plist のグループ名 |
| `Shared/SharedCredentials.swift` | 共有 Keychain のシークレット |
| `App/FileProviderDomains.swift` | ドメインの登録、削除、状態、Finder で開く、通知 |
| `FileProvider/FileProviderExtension.swift` | replicated extension 本体 |
| `FileProvider/FileProviderItem.swift` | `ItemRecord` から `NSFileProviderItem` |
| `FileProvider/Enumerators.swift` | フォルダと working set の列挙 |
| `FileProvider/MountService.swift` | 拡張機能内の依存の組み立てと、エラーの対応 |

## タスク A1：ItemStore（並列）

**Files:** `Mount/ItemRecord.swift`、`Mount/ItemStore.swift`、`Tests/MountainCoreTests/ItemStoreTests.swift`、必要なら `Package.swift`（`linkedLibrary("sqlite3")`）

- [ ] 次のテストを先に書き、失敗を確認する。
  - ルートは `rootID`、キー `""`、名前はバケット名で、作成直後から存在する。
  - `reconcile` は新しいキーに UUID を割り当て、2回目の同じ一覧では同じ識別子を返す。
  - 一覧から消えた子は削除され、フォルダなら子孫も消え、変更履歴に削除として残る。
  - ETag が変わったファイルは更新として履歴に残る。変わらなければ履歴は増えない。
  - NFC と NFD のキーは別の項目になる。
  - `move` はフォルダの子孫のキーの接頭辞を書き換え、識別子は変えない。
  - `remove` は子孫ごと削除する。
  - `changes(after:limit:)` は連番の順に返し、`hasMore` と `last` が正しい。
  - ファイルに保存したストアを開き直しても、識別子、`generation`、履歴が残る。
- [ ] SQLite（`import SQLite3`）で実装する。キーは BLOB で保存する。
- [ ] `swift test --package-path Packages/MountainCore` と `just lint` を通す。

## タスク A2：S3 の操作、ExactUploader、MountOperations（並列）

**Files:** `Mount/MountStore.swift`、`S3/S3Client+Mount.swift`、`S3/HTTPTransport.swift`（ファイルへのダウンロード）、`Mount/ExactUploader.swift`、`Mount/MountOperations.swift`、テストは `MountS3Tests.swift`、`ExactUploaderTests.swift`、`MountOperationsTests.swift`、`MountTestSupport.swift`

- [ ] S3 の要求の形をテストで固定する（記録用の偽トランスポート）。
  - `download` は GET でファイルに書き、サイズと ETag を返す。404 は `MountError.notFound`。
  - `put(overwrite: false)` は `If-None-Match: *`、`true` なら付けない。`completeMultipart` も同じ。412 は `MountError.alreadyExists`。
  - `copyObject` は `x-amz-copy-source: /<bucket>/<パーセント符号化したキー>` を送り、XML の ETag を返す。
  - `uploadPartCopy` は `x-amz-copy-source-range: bytes=a-b` を送る。
  - `deleteObjects` は `POST ?delete`、XML 本文、`Content-MD5` を送り、1001件以上は拒否する。応答の `<Error>` は失敗として投げる。
  - `listAll` は区切りなしで全ページをたどる。
  - `deleteObject` は 204 と 404 を成功とする。
- [ ] `ExactUploader` をテストで固定する（障害を注入できる偽ストア）。
  - 64 MiB 未満は1回の PUT、以上はマルチパートで、キーを変えない。
  - 途中で失敗したあと同じ `journalID` で再実行すると、`ListParts` の ETag とローカルの MD5 が一致するパートは送らない。
  - ファイルのサイズが変わっていたら、古い upload を中止してやり直す。
  - `overwrite: false` で既存なら `alreadyExists`。完了後にジャーナルを消す。
  - 進捗は送信済みバイト数を単調に増やす。
- [ ] `MountOperations` をテストで固定する。
  - `createFolder` は `name/` を PUT し、412 は成功扱い。
  - `moveObject` は 5 GiB 以下なら CopyObject、超えるなら UploadPartCopy のマルチパートでコピーしてから元を削除する。元がなく移動先がある再実行は成功する。
  - `moveFolder` は配下の全キーを新しい接頭辞にコピーし（移動先に既にあるものは省く）、元を 1000 件ずつ削除する。
  - `deleteFolder` は配下とマーカーを削除する。
- [ ] `swift test` と `just lint` を通す。

## タスク A3：ホストアプリの統合（並列）

**Files:** `Shared/*.swift`、`App/FileProviderDomains.swift`、`App/CredentialStore.swift`、`App/UploadViewModel.swift`、`App/SettingsView.swift`、`App/MenuBarPanel.swift`、`App/MainWindowView.swift`、`App/AppDelegate.swift`、`project.yml`

- [ ] `project.yml` で `Shared` を両ターゲットのソースに加え、両方の Info.plist に `S3MountainAppGroup` と `S3MountainKeychainGroup` を入れる（ホストも `info:` で生成する）。
- [ ] `SharedConfiguration` が接続先を App Group の UserDefaults に読み書きする。設定の保存と起動時に書く。
- [ ] `SharedCredentials` がシークレットを共有 Keychain グループ（`kSecUseDataProtectionKeychain`）に保存する。`CredentialStore` は起動時に以前のログインキーチェーンの項目を移す。
- [ ] `FileProviderDomains` が、ドメインの登録（Debug では `testingModes = [.alwaysEnabled]`、`supportsSyncingTrash = false`）、削除、状態、Finder で開く、`signalEnumerator(for: .workingSet)` を提供する。
- [ ] 設定画面に「Finder」セクション、メニューバーのメニューとサイドバーに「Finder で開く」を加える。バケットを変えたらドメインを入れ替える。起動中は90秒ごとと、アップロード完了時に通知する。
- [ ] スパイクの `--spike-register-domain` を削除する。
- [ ] `just build-signed` と `just lint` を通す。

## タスク B：拡張機能の本実装（A1、A2 のあと）

**Files:** `FileProvider/*.swift`

- [ ] `MountService` が App Group の接続先と共有 Keychain のシークレットから `S3Client`、`ItemStore`（App Group の中の `Mount/<バケット>/items.sqlite`）、`ExactUploader`、`MountOperations` を組み立てる。未設定なら `notAuthenticated`。
- [ ] `FileProviderItem` は設計書の能力（capabilities）とバージョン（内容は ETag、メタデータはキー）を返す。ルートの名前はバケット名。
- [ ] フォルダの列挙は `listFolder` と `reconcile`。working set の列挙は全項目、変更の列挙は最近開いたフォルダを再一覧してから `changes(after:)` を返す。アンカーは世代と連番。
- [ ] `fetchContents`、`createItem`（フォルダ、ファイル、`mayAlreadyExist`）、`modifyItem`（名前変更・移動、内容）、`deleteItem`（再帰）を実装し、アップロード完了後に evict を予約する。
- [ ] エラーは設計書の表のとおりに変換する。
- [ ] `just build-signed` と `just lint` を通す。

## タスク C：レビューと実機確認

- [ ] 観点別の独立レビュー（正しさと並行処理、File Provider の規約、R2 の意味論）と反証を行い、確定した指摘を直す。
- [ ] 実機で、Finder の AppleScript を使って次を確認し、R2 側を rclone で照合する：一覧、ダウンロード、アップロードと evict、同名、新規フォルダ、名前変更、別フォルダへの移動、フォルダの移動、削除、他の手段での変更の反映。
- [ ] `docs/validation.md` と README を更新し、コミットして `main` にマージ、プッシュする。
