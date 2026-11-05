import CryptoKit
import FileProvider
import Foundation
import MountainCore
import os

let mountLog = Logger(subsystem: "run.kan.s3mountain.FileProvider", category: "mount")

/// Everything the extension needs, assembled from the host app's shared settings.
/// The item store lives as long as the extension; the S3 side is rebuilt when settings change.
actor MountService {
  struct Remote {
    let configuration: SharedConfiguration
    let secret: String
    let client: S3Client
    let uploader: ExactUploader
    let operations: MountOperations
  }

  /// A move that started; a retry with the same source and target resumes it instead of
  /// treating the half-copied target as someone else's item.
  private struct MoveIntent: Codable, Equatable {
    let from: String
    let to: String
  }

  // File Provider hands the domain to one extension instance; it is only read afterwards.
  private nonisolated let domainBox: Unchecked<NSFileProviderDomain>
  nonisolated var domain: NSFileProviderDomain { domainBox.value }
  let store: ItemStore
  private let stateDirectory: URL
  private var remote: Remote?
  private var lastRefresh = Date.distantPast
  private var refreshCursor = 0
  private var touchedFolders: [String] = []
  private var busyPrefixes: [String: Int] = [:]
  private var prefixWaiters: [CheckedContinuation<Void, Never>] = []

  init(domain: Unchecked<NSFileProviderDomain>) throws {
    domainBox = domain
    let bucket = domain.value.identifier.rawValue
    // The sandbox can write to the App Group container; File Provider's own state directory
    // is not writable for this extension on macOS 27.
    let configuration = SharedConfiguration.load().flatMap { $0.bucket == bucket ? $0 : nil }
    let state =
      configuration?.stateURL
      ?? SharedConfiguration.containerURL?.appendingPathComponent(
        "Mount/\(bucket)", isDirectory: true)
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "R2Mountain", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    stateDirectory = state
    store = try ItemStore(url: state.appendingPathComponent("items.sqlite"), bucket: bucket)
  }

  /// The S3 side for the current settings; fails with `notConfigured` until the app is set up.
  /// The secret is read every time so a corrected key works without restarting the extension.
  func current() throws -> Remote {
    guard let configuration = SharedConfiguration.load(),
      configuration.bucket == domain.identifier.rawValue,
      let secret = try SharedCredentials.secret(
        accountID: configuration.accountID, accessKeyID: configuration.accessKeyID),
      !secret.isEmpty
    else { throw MountError.notConfigured }
    if let remote, remote.configuration == configuration, remote.secret == secret { return remote }
    let client = S3Client(
      configuration: R2Configuration(
        accountID: configuration.accountID, bucket: configuration.bucket,
        jurisdiction: R2Configuration.Jurisdiction(rawValue: configuration.jurisdiction)
          ?? .standard),
      credentials: S3Credentials(accessKeyID: configuration.accessKeyID, secretAccessKey: secret))
    let built = Remote(
      configuration: configuration, secret: secret, client: client,
      uploader: ExactUploader(
        store: client,
        journalDirectory: stateDirectory.appendingPathComponent("uploads", isDirectory: true)),
      operations: MountOperations(store: client))
    remote = built
    return built
  }

  func record(_ identifier: NSFileProviderItemIdentifier) async throws -> ItemRecord {
    guard let record = await store.record(id: identifier.recordID) else {
      throw MountError.notFound
    }
    return record
  }

  // MARK: Listing and refresh

  /// Lists a folder on R2 and reconciles it with the store, keeping identifiers stable.
  func listChildren(of folder: ItemRecord) async throws -> [ItemRecord] {
    guard folder.isFolder else { throw MountError.notFound }
    let path: FolderPath
    if folder.id == ItemRecord.rootID {
      path = .root
    } else if let parsed = FolderPath(prefix: folder.key) {
      path = parsed
    } else {
      throw MountError.invalidName
    }
    // Writes that land while the listing is in flight must not be undone by it.
    let listedAfter = await store.latestChange
    let listing = try await current().client.listFolder(path, pageLimit: 50)
    return try await store.reconcile(
      folderID: folder.id, listing: listing, listedAfter: listedAfter)
  }

  /// Folders people just worked with are refreshed first.
  func touch(_ folderID: String) {
    touchedFolders.removeAll { $0 == folderID }
    touchedFolders.insert(folderID, at: 0)
    if touchedFolders.count > 8 { touchedFolders.removeLast() }
  }

  /// Materialized folders are never listed again by the system, so remote changes reach Finder
  /// only through these refreshes. Each pass takes the root, recently touched folders and the
  /// next slice of every known folder, so no folder is left out for good.
  func refreshFolders() async {
    guard Date().timeIntervalSince(lastRefresh) > 5 else { return }
    lastRefresh = Date()
    let known = await store.recentlyListedFolders(limit: 100_000)
      .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    var batch: [ItemRecord] = []
    func add(_ record: ItemRecord) {
      if !batch.contains(where: { $0.id == record.id }) { batch.append(record) }
    }
    if let root = await store.record(id: ItemRecord.rootID) { add(root) }
    for id in touchedFolders {
      if let folder = await store.record(id: id), folder.isFolder { add(folder) }
    }
    if !known.isEmpty {
      let slice = min(15, known.count)
      for offset in 0..<slice { add(known[(refreshCursor + offset) % known.count]) }
      refreshCursor = (refreshCursor + slice) % known.count
    }
    for folder in batch {
      do {
        _ = try await listChildren(of: folder)
      } catch {
        mountLog.notice(
          "refresh \(folder.key, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
      }
    }
    mountLog.info("refreshed \(batch.count) of \(known.count) folders")
  }

  /// Keys the store knows below a folder, and the folders whose contents it has listed.
  func knownDescendants(of folder: ItemRecord) async -> (keys: Set<Data>, listedFolders: Set<Data>)
  {
    let listed = Set(await store.recentlyListedFolders(limit: 100_000).map { Data($0.key.utf8) })
    var keys: Set<Data> = [Data(folder.key.utf8)]
    var pending = [folder.id]
    while let id = pending.popLast() {
      for child in await store.children(of: id) {
        keys.insert(Data(child.key.utf8))
        if child.isFolder { pending.append(child.id) }
      }
    }
    return (keys, listed)
  }

  // MARK: Prefix locks

  /// Folder moves and deletes hold their prefixes; other changes under them wait, so an upload
  /// never lands at a key that is being moved away or deleted.
  func lock(_ prefixes: [String]) async {
    while prefixes.contains(where: isBusy) {
      await withCheckedContinuation { prefixWaiters.append($0) }
    }
    for prefix in prefixes { busyPrefixes[prefix, default: 0] += 1 }
  }

  func unlock(_ prefixes: [String]) {
    for prefix in prefixes {
      busyPrefixes[prefix, default: 1] -= 1
      if busyPrefixes[prefix] == 0 { busyPrefixes[prefix] = nil }
    }
    let waiters = prefixWaiters
    prefixWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  func waitUntilFree(_ key: String) async {
    while isBusy(key) {
      await withCheckedContinuation { prefixWaiters.append($0) }
    }
  }

  private func isBusy(_ key: String) -> Bool {
    busyPrefixes.keys.contains { key.utf8.starts(with: $0.utf8) || $0.utf8.starts(with: key.utf8) }
  }

  // MARK: Move intents

  private var intentsURL: URL { stateDirectory.appendingPathComponent("moves.json") }

  private func intents() -> [String: MoveIntent] {
    (try? JSONDecoder().decode([String: MoveIntent].self, from: Data(contentsOf: intentsURL)))
      ?? [:]
  }

  func isResumingMove(id: String, from: String, to: String) -> Bool {
    intents()[id] == MoveIntent(from: from, to: to)
  }

  func beginMove(id: String, from: String, to: String) throws {
    var all = intents()
    all[id] = MoveIntent(from: from, to: to)
    try JSONEncoder().encode(all).write(to: intentsURL, options: .atomic)
  }

  func endMove(id: String) {
    var all = intents()
    all[id] = nil
    try? JSONEncoder().encode(all).write(to: intentsURL, options: .atomic)
  }

  // MARK: Files and signals

  func temporaryFile() throws -> URL {
    let directory =
      try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
      ?? FileManager.default.temporaryDirectory
    return directory.appendingPathComponent(UUID().uuidString)
  }

  /// The server's LastModified for a fresh upload or copy; listings keep the ETag when it matches.
  func serverDate(for key: String) async -> Date? {
    try? await current().client.head(key: key)?.lastModified
  }

  nonisolated func signalWorkingSet() {
    NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
  }

  /// The system may still be settling the new item, so eviction retries a few times.
  nonisolated func evictSoon(_ identifier: NSFileProviderItemIdentifier) {
    let domain = domainBox
    Task.detached {
      for delay in [3, 10, 30, 90] {
        try? await Task.sleep(for: .seconds(delay))
        do {
          try await NSFileProviderManager(for: domain.value)?.evictItem(identifier: identifier)
          return
        } catch {
          mountLog.notice(
            "evict \(identifier.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)"
          )
        }
      }
    }
  }

  // MARK: Errors

  /// The existing item a create or move ran into. File Provider only renames the local item
  /// ("name 2") when the error names the item it collided with.
  struct Collision: Error {
    let holder: ItemRecord
  }

  /// Finds the item at `key`, listing the parent first when only R2 knows it.
  func collision(at key: String, in parent: ItemRecord) async -> any Error {
    if let holder = await store.record(key: key) { return Collision(holder: holder) }
    _ = try? await listChildren(of: parent)
    if let holder = await store.record(key: key) { return Collision(holder: holder) }
    return MountError.alreadyExists
  }

  /// Maps failures to the error domains File Provider understands.
  static func fileProviderError(_ error: any Error) -> NSError {
    if let error = error as NSError?, error.domain == NSFileProviderErrorDomain { return error }
    switch error {
    case let collision as Collision:
      return NSError.fileProviderErrorForCollision(with: FileProviderItem(collision.holder))
    case MountError.alreadyExists:
      return NSFileProviderError(.filenameCollision) as NSError
    case MountError.notFound:
      return NSFileProviderError(.noSuchItem) as NSError
    case MountError.notConfigured:
      return NSFileProviderError(.notAuthenticated) as NSError
    case MountError.invalidName:
      // Permanent: retrying the same name can never succeed.
      return NSFileProviderError(.cannotSynchronize) as NSError
    case let failure as S3Failure where failure.isAuthentication:
      return NSFileProviderError(.notAuthenticated) as NSError
    case let failure as S3Failure where failure.status == 404:
      return NSFileProviderError(.noSuchItem) as NSError
    case let failure as S3Failure where failure.isRetryable:
      return NSFileProviderError(.serverUnreachable) as NSError
    case is URLError:
      return NSFileProviderError(.serverUnreachable) as NSError
    case is CancellationError:
      return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    default:
      return NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: error, NSLocalizedDescriptionKey: "\(error)"])
    }
  }

  /// For things R2 Mountain never syncs (symbolic links, changes to the bucket itself).
  static var permanentlyUnsupported: NSError { NSFileProviderError(.cannotSynchronize) as NSError }
}

extension NSFileProviderItemIdentifier {
  var recordID: String { self == .rootContainer ? ItemRecord.rootID : rawValue }

  init(recordID: String) {
    self = recordID == ItemRecord.rootID ? .rootContainer : NSFileProviderItemIdentifier(recordID)
  }
}

/// Version components are limited to 128 bytes; keys can be up to 1024.
func versionDigest(_ text: String) -> Data {
  Data(SHA256.hash(data: Data(text.utf8)))
}

/// Carries Objective-C callbacks and observers into Swift concurrency; File Provider
/// allows calling them from any thread.
struct Unchecked<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// File Provider completion handlers must run exactly once, also when the system cancels.
final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func run(_ body: () -> Void) {
    lock.lock()
    let first = !done
    done = true
    lock.unlock()
    if first { body() }
  }
}
