import AppKit
import Combine
import Foundation
import MountainCore

struct SavedR2Settings: Equatable {
  var accountID: String
  var accessKeyID: String
  var bucket: String
  var jurisdiction: R2Configuration.Jurisdiction

  var configuration: R2Configuration {
    R2Configuration(accountID: accountID, bucket: bucket, jurisdiction: jurisdiction)
  }

  static func load() -> Self {
    let defaults = UserDefaults.standard
    return Self(
      accountID: defaults.string(forKey: "r2.accountID") ?? "",
      accessKeyID: defaults.string(forKey: "r2.accessKeyID") ?? "",
      bucket: defaults.string(forKey: "r2.bucket") ?? "",
      jurisdiction: R2Configuration.Jurisdiction(
        rawValue: defaults.string(forKey: "r2.jurisdiction") ?? "standard"
      ) ?? .standard
    )
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(accountID, forKey: "r2.accountID")
    defaults.set(accessKeyID, forKey: "r2.accessKeyID")
    defaults.set(bucket, forKey: "r2.bucket")
    defaults.set(jurisdiction.rawValue, forKey: "r2.jurisdiction")
  }
}

@MainActor
final class UploadViewModel: ObservableObject {
  static let shared = UploadViewModel()

  @Published private(set) var settings = SavedR2Settings.load()
  @Published private(set) var jobs: [UploadJob] = []
  @Published private(set) var isConfigured = false
  @Published private(set) var hasSavedSecret = false
  @Published private(set) var isTestingConnection = false
  @Published private(set) var connectionMessage: String?
  @Published private(set) var connectionSucceeded = false
  @Published private(set) var importWarnings: [String] = []
  @Published var errorMessage: String?

  private let credentials = CredentialStore()
  private let sleep = SleepAssertion()
  private let notifications = NotificationService()
  private var engine: UploadEngine?
  private var subscription: Task<Void, Never>?
  private var network: NetworkObserver?
  private var instanceLock: ApplicationInstanceLock?
  private var previousStates: [UUID: UploadState] = [:]
  private var hasReceivedSnapshot = false

  private var supportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("S3Mountain", isDirectory: true)
  }

  var hasPendingJobs: Bool {
    jobs.contains { $0.state != .completed && $0.state != .cancelled }
  }

  var hasRunningTransfers: Bool {
    jobs.contains { [.uploading, .putPending, .completing].contains($0.state) }
  }

  var summary: TransferSummary { TransferSummary(jobs: jobs) }

  var hasWorkToFinish: Bool {
    jobs.contains {
      [.queued, .uploading, .putPending, .completing, .reconciling, .cancelling].contains($0.state)
    }
  }

  private init() {
    do {
      instanceLock = try ApplicationInstanceLock(directory: supportDirectory)
    } catch {
      errorMessage = "S3 Mountain はすでに起動しています。メニューバーの山のアイコンを開いてください。"
      Task { NSApp.terminate(nil) }
      return
    }
    do {
      if let imported = try StartupSetupImporter.consumeIfRequested(
        journalDirectory: supportDirectory.appendingPathComponent("Uploads", isDirectory: true)
      ) {
        settings = imported
        connectionMessage = "接続設定を保存しました。ファイルを選んで転送を始められます。"
      }
    } catch {
      errorMessage = Self.userMessage(for: error)
    }
    network = NetworkObserver { [weak self] in
      Task { @MainActor in await self?.engine?.resumeWaiting() }
    }
    Task { await configureEngine() }
  }

  func chooseFiles(to destination: FolderPath? = nil) {
    let target = destination ?? BrowserModel.shared.current
    let urls = SourceImporter.chooseFiles(
      destinationName: BrowserModel.shared.displayName(of: target))
    if !urls.isEmpty { enqueue(urls, to: target) }
  }

  func acceptDrop(_ providers: [NSItemProvider], to destination: FolderPath? = nil) -> Bool {
    guard isConfigured else {
      errorMessage = "先に接続設定で R2 のバケットを保存してください。"
      return false
    }
    let target = destination ?? BrowserModel.shared.current
    return SourceImporter.accept(providers) { [weak self] urls in
      if urls.isEmpty {
        self?.errorMessage = "ファイルの場所を取得できません。ファイル選択から追加してください。"
      } else {
        self?.enqueue(urls, to: target)
      }
    }
  }

  func enqueue(_ urls: [URL], to destination: FolderPath? = nil) {
    guard let engine else {
      errorMessage = "先に接続設定で R2 のバケットを保存してください。"
      return
    }
    let target = destination ?? BrowserModel.shared.current
    Task {
      do {
        try await engine.enqueue(urls: urls, prefix: target.prefix)
        BrowserModel.shared.recordDestination(target)
        importWarnings = await engine.importWarnings
        await notifications.requestPermissionIfUndetermined()
      } catch { errorMessage = Self.userMessage(for: error) }
    }
  }

  func dismissImportWarnings() { importWarnings = [] }

  func clearFinished() { Task { await engine?.clearFinished() } }

  func revealSource(_ job: UploadJob) {
    NSWorkspace.shared.activateFileViewerSelecting([job.sourceURL])
  }

  /// Jobs from an earlier connection point at another bucket and cannot be shown here.
  func canShowDestination(_ job: UploadJob) -> Bool {
    isConfigured && job.configuration == settings.configuration
  }

  /// Opens the folder that contains the uploaded object in the browser.
  func showDestination(_ job: UploadJob) {
    guard canShowDestination(job) else { return }
    let folder = job.key.split(separator: "/", omittingEmptySubsequences: false).dropLast()
      .joined(separator: "/")
    BrowserModel.shared.open(FolderPath(prefix: folder) ?? .root)
    ApplicationWindows.shared.showMain()
  }

  func pause(_ job: UploadJob) { Task { await engine?.pause(id: job.id) } }
  func resume(_ job: UploadJob) { Task { await engine?.resume(id: job.id) } }
  func cancel(_ job: UploadJob) { Task { await engine?.cancel(id: job.id) } }

  func copyKey(_ job: UploadJob) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(job.key, forType: .string)
  }

  func clearConnectionResult() {
    connectionMessage = nil
    connectionSucceeded = false
  }

  func testConnection(settings candidate: SavedR2Settings, secret: String) async {
    guard !isTestingConnection else { return }
    isTestingConnection = true
    connectionMessage = nil
    connectionSucceeded = false
    defer { isTestingConnection = false }
    do {
      let resolved = try resolveCredentials(settings: candidate, secret: secret)
      let client = S3Client(configuration: candidate.configuration, credentials: resolved)
      try await client.testConnection()
      connectionSucceeded = true
      connectionMessage = "\(candidate.bucket) に接続できました。"
    } catch {
      connectionMessage = Self.userMessage(for: error)
    }
  }

  func saveSettings(_ candidate: SavedR2Settings, secret: String) async throws {
    try candidate.configuration.validate()
    if hasPendingJobs && candidate.configuration != settings.configuration {
      throw SettingsError.pendingDestination
    }
    if hasRunningTransfers { throw SettingsError.transferring }
    _ = try resolveCredentials(settings: candidate, secret: secret)
    if !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try credentials.save(
        secret.trimmingCharacters(in: .whitespacesAndNewlines),
        accountID: candidate.accountID,
        accessKeyID: candidate.accessKeyID
      )
    }
    await engine?.prepareForTermination()
    settings = candidate
    candidate.save()
    await configureEngine()
  }

  func deleteSavedSecret() async throws {
    guard !hasPendingJobs else { throw SettingsError.pendingCredentials }
    await engine?.prepareForTermination()
    subscription?.cancel()
    engine = nil
    try credentials.delete(accountID: settings.accountID, accessKeyID: settings.accessKeyID)
    BrowserModel.shared.disconnect()
    hasSavedSecret = false
    isConfigured = false
    connectionMessage = nil
    connectionSucceeded = false
  }

  func enableNotifications() async -> Bool {
    await notifications.requestPermission()
  }

  func prepareForTermination() async {
    await engine?.prepareForTermination()
    sleep.setActive(false)
    subscription?.cancel()
  }

  private func configureEngine() async {
    subscription?.cancel()
    engine = nil
    isConfigured = false
    hasSavedSecret = false
    guard instanceLock != nil else { return }
    do {
      guard !settings.accountID.isEmpty, !settings.accessKeyID.isEmpty, !settings.bucket.isEmpty
      else {
        return
      }
      let resolved = try resolveCredentials(settings: settings, secret: "")
      hasSavedSecret = true
      let client = S3Client(configuration: settings.configuration, credentials: resolved)
      // Browsing gets its own connection pool so listings never queue behind part uploads.
      let browsingClient = S3Client(configuration: settings.configuration, credentials: resolved)
      let newEngine = UploadEngine(
        configuration: settings.configuration,
        client: client,
        journalDirectory: supportDirectory.appendingPathComponent("Uploads", isDirectory: true)
      )
      engine = newEngine
      isConfigured = true
      BrowserModel.shared.connect(client: browsingClient, bucket: settings.bucket)
      hasReceivedSnapshot = false
      previousStates = [:]
      subscription = Task { [weak self] in
        let stream = await newEngine.snapshots()
        do {
          try await newEngine.restore()
          self?.importWarnings = await newEngine.importWarnings
        } catch { self?.errorMessage = Self.userMessage(for: error) }
        for await snapshot in stream {
          guard !Task.isCancelled else { return }
          self?.receive(snapshot)
        }
      }
    } catch {
      errorMessage = Self.userMessage(for: error)
    }
  }

  private func resolveCredentials(settings candidate: SavedR2Settings, secret: String) throws
    -> S3Credentials
  {
    try candidate.configuration.validate()
    let accessID = candidate.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard accessID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
      accessID.caseInsensitiveCompare(candidate.accountID) != .orderedSame
    else { throw SettingsError.invalidAccessKey }
    let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved =
      typed.isEmpty
      ? try credentials.secret(accountID: candidate.accountID, accessKeyID: accessID)
      : typed
    guard let resolved, !resolved.isEmpty else { throw SettingsError.missingSecret }
    return S3Credentials(accessKeyID: accessID, secretAccessKey: resolved)
  }

  private func receive(_ snapshot: [UploadJob]) {
    jobs = snapshot
    sleep.setActive(hasRunningTransfers)
    if hasReceivedSnapshot {
      var uploadedKeys: [String] = []
      for job in snapshot where previousStates[job.id] != job.state {
        if job.state == .completed || job.state == .failed || job.state == .needsCredentials {
          Task { await notifications.notify(job) }
        }
        if job.state == .completed { uploadedKeys.append(job.key) }
      }
      BrowserModel.shared.objectsDidChange(keys: uploadedKeys)
    }
    hasReceivedSnapshot = true
    previousStates = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.state) })
  }

  static func userMessage(for error: Error) -> String {
    if let failure = error as? S3Failure {
      if failure.code == "InvalidConfiguration" {
        return "アカウント ID とバケット名を確認してください。"
      }
      if failure.isAuthentication {
        return "認証できません。アクセスキー ID、シークレット、バケットの権限を確認してください。"
      }
      if failure.status == 404 { return "バケットまたは保存先が見つかりません。接続先を確認してください。" }
      if failure.isRetryable { return "R2 が応答できません。少し待って、もう一度接続してください。" }
      return "R2 への接続を確認してください（\(failure.code)、\(failure.status)）。"
    }
    if error is URLError { return "ネットワークに接続できません。回線を確認して、もう一度お試しください。" }
    return error.localizedDescription
  }
}

private enum SettingsError: LocalizedError {
  case pendingDestination, pendingCredentials, transferring, invalidAccessKey, missingSecret

  var errorDescription: String? {
    switch self {
    case .pendingDestination:
      "未完了の転送があります。完了するかキャンセルしてから、接続先を変更してください。"
    case .pendingCredentials:
      "未完了の転送があります。完了するかキャンセルしてから、シークレットを削除してください。"
    case .transferring:
      "転送を一時停止してから、接続設定を保存してください。"
    case .invalidAccessKey:
      "R2 のアクセスキー ID を入力してください。アカウント ID と API トークンは別の項目です。"
    case .missingSecret:
      "シークレットアクセスキーを入力してください。"
    }
  }
}
