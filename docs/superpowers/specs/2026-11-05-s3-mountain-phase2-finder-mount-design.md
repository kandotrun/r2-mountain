# S3 Mountain フェーズ2：Finder マウント 設計

作成日：2026-11-05

## 目的

R2 の1バケットを Finder の「場所」に表示し、閲覧、ダウンロード、アップロード、新規フォルダ、名前変更・移動、削除を Finder から行えるようにする。
フェーズ1のメニューバーとウィンドウはそのまま残す。

## 決定事項

| 項目 | 決定 |
| --- | --- |
| 方式 | File Provider の replicated extension（`com.apple.fileprovider-nonui`） |
| 名前変更・移動 | 対応する。R2 には名前変更がないため、コピーしてから元を削除する |
| アップロード後のローカルコピー | 完了後に自動で解放（evict）する。開くと再ダウンロード |
| 削除 | Finder の「すぐに削除」確認のうえ R2 からも削除。ゴミ箱は使わない（`supportsSyncingTrash = false`、`allowsTrashing` なし） |
| 編集して保存 | 上書きアップロードで反映する。競合は後勝ち（個人利用の1台前提） |
| 有効化 | Debug 署名（個人チーム）では Testing Mode の `alwaysEnabled` を使い、システム設定での手動有効化を不要にする |

スパイク（2026-11-05）で、自動プロビジョニング（デバイス登録を含む）、App Group、Keychain 共有、Testing Mode、拡張機能の登録、Finder 表示を確認した。
ルート項目のファイル名が空だとシステムが拡張機能を強制終了するため、ルートにもバケット名を付ける。

## 構成

```text
S3 Mountain.app（ホストアプリ、サンドボックスなし）
├─ 設定と資格情報を App Group と共有 Keychain に書く
├─ ドメインの登録・削除、Finder で開く、定期的に変更を通知（signalEnumerator）
└─ PlugIns/S3MountainFileProvider.appex（サンドボックスあり）
     ├─ FileProviderExtension: Apple の API と MountainCore の橋渡しだけ
     └─ MountainCore: ItemStore, MountOperations, ExactUploader（純粋なロジック、TDD）
```

| 識別子 | 値 |
| --- | --- |
| 拡張機能の Bundle ID | `run.kan.s3mountain.FileProvider` |
| App Group | `$(TeamIdentifierPrefix)run.kan.s3mountain` |
| 共有 Keychain グループ | `$(AppIdentifierPrefix)run.kan.s3mountain.shared` |
| ドメイン ID と表示名 | バケット名 |
| 置き場所 | `~/Library/CloudStorage/S3Mountain-<バケット>` |

App Group と Keychain グループの実際の値は、両ターゲットの Info.plist の `S3MountainAppGroup` と `S3MountainKeychainGroup` から読む。

## 項目の識別子

File Provider は、名前変更・移動の前後で項目の識別子が変わらないことを要求する。
S3 のキーは名前変更で変わるため、キーとは別に UUID の識別子を持ち、`ItemStore`（SQLite）で対応付ける。

- ルートはキー `""`、識別子は `NSFileProviderItemIdentifier.rootContainer`。
- フォルダのキーは末尾が `/`。
- キーはバイト列として保存し、NFC と NFD の綴りを区別する。
- 一覧で初めて見たキーには新しい UUID を割り当てる。
- 名前変更・移動では、同じ識別子のままキーを更新する。フォルダは子孫のキーの接頭辞も書き換える。

## 動作

| 操作 | 拡張機能での処理 |
| --- | --- |
| フォルダを開く | `ListObjectsV2`（区切り `/`）で一覧し、`ItemStore` と照合して返す |
| ファイルを開く・コピー | `fetchContents` で GET をファイルへ直接ダウンロード |
| ファイルを追加 | `createItem` で `ExactUploader` が送信。64 MiB 以上はマルチパート。完了後に evict |
| 同名のファイルを追加 | 作成時は `If-None-Match: *`。既にあれば `filenameCollision` を返し、Finder が名前を変える |
| 新規フォルダ | マーカー `name/` を PUT（既にあれば既存を返す） |
| 名前変更・移動 | ファイルは CopyObject（5 GiB 超は UploadPartCopy）してから元を削除。フォルダは配下を全てコピーしてから削除 |
| 内容の変更 | 上書きアップロード |
| 削除 | ファイルは DeleteObject。フォルダは配下を DeleteObjects（1000件ずつ）で削除 |
| 他の手段での変更 | ホストアプリが90秒ごとに working set を通知し、拡張機能が最近開いたフォルダを再一覧して差分を返す |

### 長いアップロード

`createItem` の完了ハンドラはアップロードが終わるまで保持し、`Progress` を更新し続ける。
システムが中断して同じテンプレート識別子で再実行したときは、ジャーナルの upload ID を使い、`ListParts` の ETag とローカルのパートの MD5 が一致するパートだけを再利用する。

### 変更の通知

`ItemStore` は変更履歴（連番）を持つ。
同期アンカーは「ストアの世代 UUID と連番」で、ストアを作り直したときは `syncAnchorExpired` を返す。
working set の `enumerateItems` は、ストアにある全項目を返す。

## 公開 API（MountainCore に追加する契約）

```swift
// Mount/ItemRecord.swift
public struct ItemRecord: Sendable, Equatable, Codable {
  public static let rootID = "root"
  public let id: String              // ルートは rootID、それ以外は UUID 文字列
  public var key: String             // ルートは ""、フォルダは末尾 "/"
  public var parentID: String        // ルートは自分自身
  public var name: String            // ルートはバケット名
  public var isFolder: Bool
  public var size: Int64?            // ファイルのみ
  public var eTag: String?           // ファイルのみ
  public var modified: Date?         // ファイルのみ
}

// Mount/ItemStore.swift（SQLite、actor）
public actor ItemStore {
  public init(url: URL?, bucket: String) throws   // url が nil ならメモリ上
  public var generation: String { get }            // ストア作成時の UUID
  public func record(id: String) -> ItemRecord?
  public func record(key: String) -> ItemRecord?   // バイト一致
  public func children(of id: String) -> [ItemRecord]
  /// 一覧結果と照合し、新しいキーに UUID を割り当て、消えた子（フォルダは子孫ごと）を削除し、変更履歴に記録する。
  public func reconcile(folderID: String, listing: FolderListing) throws -> [ItemRecord]
  public func upsert(_ record: ItemRecord) throws               // 作成・内容変更の結果
  public func move(id: String, toKey: String, parentID: String, name: String) throws  // 子孫のキーも更新
  public func remove(id: String) throws                          // 子孫ごと
  public func allRecords() -> [ItemRecord]
  public func recentlyListedFolders(limit: Int) -> [ItemRecord]
  public var latestChange: Int64 { get }
  public func changes(after: Int64, limit: Int) -> ChangeBatch
}
public struct ChangeBatch: Sendable, Equatable {
  public let updated: [ItemRecord]
  public let deletedIDs: [String]
  public let last: Int64
  public let hasMore: Bool
}

// Mount/MountStore.swift（S3Client が準拠）
public protocol S3MountStore: S3FolderBrowsing {
  func head(key: String) async throws -> S3ObjectMetadata?
  func download(key: String, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> S3ObjectMetadata
  func put(key: String, file: URL, size: Int64, contentMD5: String, overwrite: Bool) async throws -> String
  func createMultipart(key: String) async throws -> String
  func uploadPart(key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5: String) async throws -> String
  func listParts(key: String, uploadID: String) async throws -> [S3RemotePart]
  func completeMultipart(key: String, uploadID: String, parts: [S3CompletedPart], overwrite: Bool) async throws -> String
  func abortMultipart(key: String, uploadID: String) async throws
  func copyObject(from source: String, to destination: String) async throws -> String
  func uploadPartCopy(key: String, uploadID: String, number: Int, source: String, range: ClosedRange<Int64>) async throws -> String
  func deleteObject(key: String) async throws
  func deleteObjects(keys: [String]) async throws               // 1000件以下
  func listAll(prefix: String) async throws -> [S3ListedObject] // 区切りなし、全ページ
}
public struct S3ListedObject: Sendable, Equatable { public let key: String; public let size: Int64 }

// Mount/ExactUploader.swift（actor）
public actor ExactUploader {
  public init(store: any S3MountStore, journalDirectory: URL, partConcurrency: Int = 4)
  /// キーをそのまま使って送る。overwrite が false なら作成のみ（既存なら MountError.alreadyExists）。
  public func upload(file: URL, key: String, journalID: String, overwrite: Bool,
                     progress: @escaping @Sendable (Int64) -> Void) async throws -> UploadedObject
}
public struct UploadedObject: Sendable, Equatable { public let eTag: String; public let size: Int64 }

// Mount/MountOperations.swift（actor）
public actor MountOperations {
  public init(store: any S3MountStore)
  public func createFolder(key: String) async throws            // 既存は成功扱い
  public func moveObject(from: String, to: String, size: Int64) async throws -> String  // 新しい ETag
  public func moveFolder(from: String, to: String, progress: @escaping @Sendable (Int, Int) -> Void) async throws
  public func deleteObject(key: String) async throws
  public func deleteFolder(prefix: String) async throws
}
public enum MountError: Error, Equatable, Sendable {
  case alreadyExists, notFound, notConfigured, invalidName
}
```

移動は再実行に耐えるようにする。
元がなく移動先がある場合は完了扱いにし、フォルダの移動では移動先に既にあるキーのコピーを省く。

## エラーの対応

| 原因 | File Provider へのエラー |
| --- | --- |
| 認証（401/403）、未設定 | `NSFileProviderError.notAuthenticated` |
| 通信失敗、429、5xx | `NSFileProviderError.serverUnreachable` |
| `MountError.alreadyExists` | `filenameCollision` |
| `MountError.notFound`、404 | `noSuchItem` |
| その他 | Cocoa のエラーとして返す（`NSUnderlyingErrorKey` 付き） |

## ホストアプリ

- 設定を保存すると、App Group の UserDefaults に接続先（アカウント ID、バケット、管轄、アクセスキー ID）を書く。
- シークレットは共有 Keychain グループに保存し、以前のログインキーチェーンの項目は起動時に移す。
- 設定画面に「Finder」セクションを追加する。「Finder に表示」の切り替え、状態の表示、「Finder で開く」。
- メニューバーのメニューとウィンドウのサイドバーに「Finder で開く」を追加する。
- バケットを変えたら古いドメインを削除し、新しいバケットで登録し直す。
- アプリの起動中は90秒ごと、メニューバー版からのアップロードが終わったときにも working set を通知する。

## テスト

- MountainCore は TDD で進める。`ItemStore` はメモリ上の SQLite で検証する。S3 の操作は記録用の偽トランスポートで、ヘッダー、コピー元の符号化、DeleteObjects の XML と Content-MD5 を検査する。アップロードの再開は、障害を注入できる偽ストアで検証する。
- 拡張機能は薄く保ち、実機で確認する。シェルは TCC により `~/Library/CloudStorage` を読めないため、Finder の AppleScript で、コピー、名前変更、移動、削除を行い、R2 側は rclone で確かめる。
- テストデータは `s3-mountain-tests/` の下だけに作り、作ったものを削除する。

## 対象外

- 複数バケット、複数アカウント
- 共有リンク、公開 URL
- 同時編集の競合解決（後勝ち）
- サーバー側の検索
