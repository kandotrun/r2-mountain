# S3 Mountain フェーズ1実装計画

作成日：2026-11-04（Asia/Tokyo）

対象は[フェーズ1設計](../specs/2026-11-04-s3-mountain-phase1-design.md)で承認されたメニューバー版である。
最初の検証対象は標準管轄の `drive` バケットとする。
Account ID と credentials は実行時にだけ渡し、文書や fixture に含めない。
この文書内のファイルとコマンドは、これから作成する実装の計画であり、実装済みの機能を表していない。
作業場所は `/Users/kan/UGREEN-NAS/DEVELOP/kandotrun/s3-mountain`、作業ブランチは `feat/phase1-uploader` とする。

## 1. 実装の進め方

通信契約、永続化、転送エンジン、画面の順に積み上げる。
各段階で、対象の失敗条件を表すテストを先に追加し、失敗を確認してから実装する。
テストの成功後に責務を整理し、次の段階へ進む。

マルチパート完了時の競合保護は最初の実 R2 検証で判定する。
ローカルで成功する偽 S3 を作るだけでは、R2 が条件付き完了を実装している証拠にならない。
未対応なら、大容量アップロードを利用可能にする前に保存先方式を解決する。
この判定を待つ間も、署名、分割、ジャーナル、UI の独立した作業は進められる。

### 作業開始時の確認

```sh
git status --short --branch
git branch --show-current
git remote -v
swift --version
xcodebuild -version
xcodegen --version
just --version
```

2026-11-04の読取りでは、Swift 6.4、Xcode 27.1、XcodeGen 2.46.0、just 1.59.0 を利用できた。
Homebrew のツールが見つからない場合は、既存の `/opt/homebrew/bin` を PATH に追加して確認する。
署名設定を再読取りし、個人チームを使う。
他プロジェクトの署名やチェックアウトを変更しない。

## 2. パッケージとビルドの土台

作成するファイル：

- `Packages/MountainCore/Package.swift`
- `Packages/MountainCore/Sources/MountainCore/S3/HTTPTransport.swift`
- `Packages/MountainCore/Tests/MountainCoreTests/HTTPTransportTests.swift`
- `App/S3MountainApp.swift`
- `project.yml`
- `justfile`
- `.gitignore`

Swift tools version は6.0、対象 OS は macOS 26、ライブラリ名は `MountainCore` とする。
アプリは SwiftUI の `MenuBarExtra` と設定画面を持つ macOS application target にし、ローカル Swift package を参照する。
XcodeGen の `project.yml` を唯一のプロジェクト定義とし、生成物を手で編集しない。
Bundle ID、チーム、Hardened Runtime、App Sandbox 無効、メニューバー常駐の設定を明記する。

`HTTPTransport` はリクエストと固定長の本文、応答ステータス、ヘッダー、本文を受け渡す `Sendable` な境界にする。
本文はメモリ内データと一時ファイルを扱い、ファイル URL の有効期間を呼出し側が管理する。
テスト用 transport は要求を記録し、決められた応答やエラーを返す。
時刻と待機も差し替え可能にし、テストで実時間の長い待機を発生させない。

この段階で `just generate`、`just test`、`just lint`、`just build` を作る。
`test` は SwiftPM の単体テスト、`lint` は `swift format lint --strict --recursive`、`build` は Xcode の macOS application build を呼ぶ。
生成プロジェクトとビルド生成物の扱いは `.gitignore` に揃える。

完了条件は、空の成功テストではなく、偽 transport に渡した本文とヘッダーが正しく記録されるテスト、および最小のメニューバーアプリのビルドが通ることとする。
署名付きビルドは後段で別に検証する。

## 3. キー、分割、本文の固定

作成するファイル：

- `Sources/MountainCore/Upload/ObjectKey.swift`
- `Sources/MountainCore/Upload/MultipartPlan.swift`
- `Sources/MountainCore/Upload/SourceFile.swift`
- `Sources/MountainCore/Upload/PartSource.swift`
- それぞれに対応する `Tests/MountainCoreTests/*Tests.swift`

上記の `Sources` と `Tests` は、以降も `Packages/MountainCore/` からの相対パスである。

まず、0バイト、64 MiBの境界、その前後、50 GiB、10,000パートの境界、R2上限超過の分割テストを書く。
整数の切上げと乗算のオーバーフローも確認する。
10,000パートちょうどの計画は実データを確保せず、サイズ値だけで検証する。
R2 の定数には仕様書で参照した脚注の厳密値と確認日を残す。

キーのテストは、日本語の NFD と NFC、空白、`+`、`%`、拡張子なし、複数のドット、同名の連番、キュー内の衝突を含める。
URL のエンコードとキー生成を混ぜない。
フォルダ入力は階層を保持し、シンボリックリンクを追わず、空フォルダと macOS の補助ファイルの規則を適用する。

`PartSource` は必要な範囲だけ読み、一時ファイルと MD5、長さを返す。
一時ファイルの解放は通信タスクの終了後に行う。
短い読取り、元ファイルの変更、読取り権限、空き容量不足を注入して検証する。
通常のファイル読取りをメインスレッド上で実行しない。

完了条件は、50 GiBの計画が64 MiBの800パートになり、実際の小さなファイルから範囲を切り出した内容と MD5 が一致することとする。

## 4. SigV4 と S3 通信

作成するファイル：

- `Sources/MountainCore/S3/SigV4Signer.swift`
- `Sources/MountainCore/S3/R2Configuration.swift`
- `Sources/MountainCore/S3/S3Client.swift`
- `Sources/MountainCore/S3/S3XML.swift`
- `Sources/MountainCore/S3/S3Error.swift`
- `Tests/MountainCoreTests/SigV4SignerTests.swift`
- `Tests/MountainCoreTests/S3ClientTests.swift`
- `Tests/MountainCoreTests/Fixtures/`（公開サンプルと合成した XML）

AWS の公開された署名例を fixture にし、canonical request、string to sign、署名結果を検証する。
テスト用の公開キー以外の認証情報を fixture に入れない。
`host`、`x-amz-date`、`x-amz-content-sha256`、`Content-MD5`、独自メタデータ、条件付きヘッダーの変更が署名へ反映されることを確認する。
実際の送信 URL と canonical URI が一致するよう、同じエンコード結果から作る。

接続設定は標準とEUのホストを生成し、region は `auto` とする。
ホストへのリダイレクトは拒否し、任意の URL を設定値として受け付けない。
Keychain を通信層に直結せず、解決済みの credentials を呼出し側から渡す。

API は接続テスト、HEAD、条件付き PUT、マルチパート作成、パート送信、全パート列挙、条件付き完了、中止の順に実装する。
`ListParts` と `ListObjectsV2` はそれぞれのページング方式を扱う。
XML では namespace、空要素、引用符つき ETag、エスケープ、欠けた必須項目、外部エンティティ、200内のエラーをテストする。

ローカル受信サーバーを使う transport テストも追加し、URLSession が送った長さと本文、MD5、署名ヘッダーを確認する。
メモリ上の request の検査だけで、実際の送信形式の検証を終えない。

完了条件は、公開署名例、各 API の成功と失敗、固定長本文、ページング、レスポンス解析のテストが通ることとする。

## 5. 実 R2 の契約検証

作成するファイル：

- `Tests/R2IntegrationTests/R2ContractTests.swift`
- `Tests/R2IntegrationTests/R2TestEnvironment.swift`
- `scripts/test-r2.sh`
- `docs/r2-integration-testing.md`

SwiftPM に実 R2 用のテストターゲットを追加する。
通常の `just test` は単体テストだけを起動する。
`just test-r2` は明示的な opt-in と必須の環境変数を検査してから実 R2 テストだけを起動する。
変数が足りないときは、実行していないことを明示して終了する。
`set -x` を使わず、Secret、Authorization、署名済み URL を出力しない。

必要な変数は `S3_MOUNTAIN_R2_ACCOUNT_ID`、`S3_MOUNTAIN_R2_ACCESS_KEY_ID`、`S3_MOUNTAIN_R2_SECRET_ACCESS_KEY`、`S3_MOUNTAIN_R2_BUCKET`、`S3_MOUNTAIN_R2_JURISDICTION` と、明示的な `S3_MOUNTAIN_R2_TEST=1` とする。
認証情報は管理された Secret の受渡し手段を使い、チャット、Git、シェル履歴へ保存しない。

各実行で `s3-mountain-tests/<UUID>/` を作り、次の順で検証する。

1. 小さい合成ファイルを条件付き PUT し、同じキーへの2回目が412になることを確認する。
2. 空のキーへの条件付きマルチパート完了が成功し、内容が一致する正の対照を確認する。その後、sentinel を置いたキーへの同じ形式の要求が事前条件エラーで拒否され、sentinel の内容が変わらないことを確認する。
3. 空の同じキーへの有効な条件付き完了を競合させ、ちょうど1件が成功し、残りが競合によって拒否され、最終内容が勝者の内容と一致することを確認する。全件が400などで失敗する場合は不合格とする。
4. `UNSIGNED-PAYLOAD`、`Content-MD5`、独自メタデータ、`ListParts` の実応答がローカル契約と一致することを確認する。
5. 150 MiBの合成ファイルを送信し、認証付きダウンロードの SHA-256 を元ファイルと比較する。
6. この実行で作ったキーと upload ID だけを片付け、片付け失敗は対象を秘密情報なしで記録する。

片付け用の `DeleteObject` とダウンロード用の `GetObject` は、この段階ではテストハーネスに限定してよい。
テストが落ちた場合も、バケット全体やテストプレフィックスの外を削除しない。
条件付き完了が不明な結果になった場合も、既存 sentinel の内容を必ず再取得する。

条件付き完了が未対応なら、互換性の判定と実応答を文書に残す。
利用可能判定を保留し、承認済みの同名保護を満たす代替設計を先に解決する。
認証情報が未提供の場合はこの段階を「未実行」とし、ローカルの独立作業へ進む。

## 6. ジャーナルと復元

作成するファイル：

- `Sources/MountainCore/Upload/UploadJob.swift`
- `Sources/MountainCore/Persistence/UploadJournal.swift`
- `Sources/MountainCore/Persistence/JournalStore.swift`
- `Tests/MountainCoreTests/JournalStoreTests.swift`
- `Tests/MountainCoreTests/Support/FailingJournalStore.swift`

最初にジョブ、完了済みパート、接続プロファイル参照、元ファイル識別情報、状態の Codable モデルを定義する。
upload ID 未取得、転送途中、完了照合待ち、中止待ちを区別し、復元時に必要な情報を落とさない。
モデルの初回保存後に通信を始める。
単一 PUT と完了要求は、固定キー、ジョブID、期待サイズ、期待 MD5 または ETag と、`putPending` または `completing` の送信意図を保存してから送る。
その状態で復元した項目は、新しいキーを割り当てる前に結果を照合する。

保存層は、一時ファイル、権限設定、原子的な置換、索引の更新を担当する。
索引だけが古い場合でも、個別ジャーナルから未完了項目を回収できるようにする。
書込み失敗、置換前の終了、破損 JSON、将来バージョン、索引から外れたファイルを fixture で検証する。
JSON の構造を検査し、credentials と署名情報が含まれないことも確認する。

完了条件は、プロセスが途中で消えた状態を模したディレクトリから、再開対象とユーザー停止対象、中止対象を区別して復元できることとする。

## 7. 転送エンジンと障害からの回復

作成するファイル：

- `Sources/MountainCore/Upload/UploadEngine.swift`
- `Sources/MountainCore/Upload/UploadSnapshot.swift`
- `Sources/MountainCore/Upload/RetryPolicy.swift`
- `Sources/MountainCore/Upload/ResumeReconciler.swift`
- `Tests/MountainCoreTests/UploadEngineTests.swift`
- `Tests/MountainCoreTests/RecoveryTests.swift`
- `Tests/MountainCoreTests/Support/FakeS3Store.swift`
- `Tests/MountainCoreTests/Support/TestClock.swift`

S3 操作の protocol を境界とし、エンジンは実クライアントと偽 S3 を同じ手順で呼べるようにする。
公開操作は投入、一時停止、再開、キャンセル、終了準備、スナップショット購読に絞る。
進捗イベントは間引き、UI の描画頻度に通信処理を依存させない。

最初のテストは1ファイルの送信と4本以内の並列数、ファイル間の直列処理を確認する。
その後、次の障害を1つずつ追加する。

| 注入する状況 | 期待する結果 |
| --- | --- |
| パート送信中にネットワーク断 | 有限の再試行後に待機し、回復後に再開する |
| 429、`Retry-After`、連続5xx | 指定時刻より早く再送せず、到達性が変わらなくても再試行できる |
| パート成功後にジャーナル保存失敗 | 次の処理を止め、再開時に R2 と再照合する |
| ローカル記録だけ、R2だけ、異なる ETag | 信頼できる一致パートだけを再利用する |
| 1,001以上のパートの列挙 | 全ページを照合し、マーカー異常で停止する |
| 期限切れ upload ID | 完了オブジェクトを先に調べ、確認後に再作成する |
| PUT または完了要求の応答喪失 | `reconciling` へ移り、同じジョブIDとサイズ、ETagで成功を回収する |
| 単一 PUT 成功直後、完了保存前に強制終了 | 永続化済みの送信意図から自分の完了を回収し、412で別名に再送しない |
| 全パート送信後に別の書込みが同じキーを取得 | 元オブジェクトを保持し、旧 upload ID の片付け後に次の連番キーへ再転送する |
| 応答喪失後に一時的な HEAD 404 | すぐ別名で二重転送せず、未確定の記録を保持する |
| 200の本文がエラーまたは途中で切れる | 完了にしない |
| 元ファイルの変更または消失 | 完了を送らず、理由を表示する |
| 認証失敗または時刻ずれ | 認証待ちと、回数を制限した時刻補正を区別する |
| 一時停止と成功応答が競合 | タスク終了後に成功分を保存し、新しい要求を始めない |
| オフライン中のキャンセル | 中止待ちを保存し、次回に既知の upload ID だけを中止する |
| 完了送信後のキャンセル | 結果を照合し、完成済みオブジェクトを自動削除しない |

強制終了テストは、同じ永続ディレクトリと偽 S3 を使ってエンジンのインスタンスを作り直す。
前のメモリ状態を引き継がなくても、仕様の再開手順を満たすことを確認する。
これに加えて、後段で実アプリのプロセスを終了する検証も行う。

## 8. macOS 画面とシステム連携

作成するファイル：

- `App/UploadViewModel.swift`
- `App/MenuBarView.swift`
- `App/SettingsView.swift`
- `App/CredentialStore.swift`
- `App/SourceImporter.swift`
- `App/NetworkObserver.swift`
- `App/SleepAssertion.swift`
- `App/NotificationService.swift`
- `App/AppDelegate.swift`

`@MainActor` の view model から actor のエンジンを呼び、画面にスナップショットを表示する。
ドロップと選択ダイアログは同じ投入処理へ渡す。
ディレクトリ走査中も画面を操作でき、投入できなかった項目を一覧で知らせる。

設定の保存では Keychain を使い、既存 Secret を空欄保存で消さない。
明示的な削除操作と、Secret を保った他設定の変更を区別する。
接続プロファイルの識別子はキューが参照できる形で保持し、認証情報の更新と保存先変更を混同しない。

NWPathMonitor は到達性の変化をエンジンへ通知する。
スリープ抑止の取得と解放は転送状態に連動させ、通知権限の拒否はエラー停止の原因にしない。
終了要求は AppKit の非同期終了応答を使い、ジャーナル保存完了までプロセスを残す。
アプリの単一起動も確認する。

画面で確認する項目は、初回設定、Secret の保持、接続テスト、ドロップ、フォルダ、プレフィックス、一時停止、再開、キャンセル、キーのコピー、通知拒否、終了確認とする。
VoiceOver のラベルとキーボード操作も確認する。
UI の見た目をそのまま写す単体テストは追加せず、入力変換と状態の表示判断にテストを絞る。

## 9. ビルド、継続検証、ローカル利用

作成または更新するファイル：

- `.github/workflows/ci.yml`
- `justfile`
- `README.md`
- `docs/validation.md`

CI は対応する macOS SDK を備えた runner を選び、SwiftPM 単体テスト、format、XcodeGen、署名なしアプリビルドを実行する。
利用できる runner の Xcode を実装時に確認し、未確認のバージョンを固定しない。
CI に個人の R2 キーや Apple の署名用秘密情報を渡さない。
実 R2 テストは通常の PR CI に含めない。

ローカルの実行順序は、実装した `justfile` で次に揃える。

```sh
just generate
just test
just lint
just build
just build-signed
just test-r2
```

`build-signed` は選択した個人チームでビルドし、署名検査とアプリ起動までを確認する。
チームや Bundle ID の問題を署名の無効化で回避して成功扱いにしない。
インストールする場合は、既存アプリの有無を調べてから検証済みの `.app` を配置する。
README には実際に通った操作手順とアプリの場所だけを載せる。

`docs/validation.md` には、環境、コミット、コマンドと結果、未実行の項目を記録する。
数十GBの転送ではピークメモリ、一時ファイル容量、経過時間、再開前後の送信量、最終 SHA-256 を記録する。
実データをアップロードする前に、合成ファイルと専用プレフィックスで確認する。
検証用ファイルやログを不要に Git に入れない。

## 10. 作業の分担と引渡し条件

複数人または複数エージェントで実装する場合は、土台と公開型を決めてから、S3、永続化とエンジン、App の責任範囲を分ける。
それぞれの所有ファイルを明示し、他の作業者の変更を戻さない。
共有型の変更は利用側へ伝え、依存するビルドとテストを揃えてから統合する。
責務の重なるファイルは同時に編集しない。

実装の完了には、仕様書の利用可能条件と実 R2 の競合保護の解決が必要である。
結果は「ローカル単体テスト」「アプリビルド」「署名と起動」「GUI」「実 R2」に分けて引き渡す。
未実行の項目は明記し、Finder マウントはフェーズ2として別に扱う。

コミットは仕様と実装を分け、意図したファイルだけを stage する。
既存の Git 署名設定を維持する。
署名エラーが起きた場合は stage を保持して原因を調べ、無断で署名を無効にしない。
