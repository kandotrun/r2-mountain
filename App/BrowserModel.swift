import Foundation
import MountainCore

@MainActor
final class BrowserModel: ObservableObject {
  static let shared = BrowserModel()

  enum LoadState: Equatable {
    case idle, loading
    case loaded(FolderListing)
    case failed(String)
  }

  struct SortOrder: Equatable {
    var key: String
    var ascending: Bool
  }

  @Published private(set) var history: BrowserHistory
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var recents: RecentFolders
  @Published private(set) var bucketName = ""
  @Published private(set) var isConnected = false
  @Published var sortOrder: SortOrder {
    didSet {
      UserDefaults.standard.set(sortOrder.key, forKey: Keys.sortKey)
      UserDefaults.standard.set(sortOrder.ascending, forKey: Keys.sortAscending)
    }
  }

  private var client: (any S3FolderBrowsing)?
  private var cache: [FolderPath: FolderListing] = [:]
  private var loadTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?

  private init() {
    let defaults = UserDefaults.standard
    history = BrowserHistory(
      current: FolderPath(prefix: defaults.string(forKey: Keys.location) ?? "") ?? .root)
    recents =
      defaults.data(forKey: Keys.recents).flatMap {
        try? JSONDecoder().decode(RecentFolders.self, from: $0)
      } ?? RecentFolders()
    sortOrder = SortOrder(
      key: defaults.string(forKey: Keys.sortKey) ?? "name",
      ascending: defaults.object(forKey: Keys.sortAscending) as? Bool ?? true)
  }

  var current: FolderPath { history.current }

  var listing: FolderListing? {
    if case .loaded(let listing) = state, listing.path == current { return listing }
    return cache[current]
  }

  /// Folder names shown to people: the bucket stands in for the root.
  func displayName(of path: FolderPath) -> String { path.name ?? bucketName }

  func displayPath(of path: FolderPath) -> String {
    path.lineage.map(displayName(of:)).joined(separator: " › ")
  }

  func connect(client: any S3FolderBrowsing, bucket: String) {
    let defaults = UserDefaults.standard
    // Locations only make sense inside the bucket they were saved for.
    if defaults.string(forKey: Keys.bucket) != bucket {
      history = BrowserHistory()
      recents = RecentFolders()
      persist()
      persistRecents()
      defaults.set(bucket, forKey: Keys.bucket)
    }
    self.client = client
    bucketName = bucket
    isConnected = true
    cache = [:]
    load(current, showSpinner: true)
  }

  func disconnect() {
    loadTask?.cancel()
    refreshTask?.cancel()
    client = nil
    isConnected = false
    cache = [:]
    state = .idle
  }

  func open(_ path: FolderPath) {
    guard path != current else { return }
    history.visit(path)
    locationDidChange()
  }

  func goBack() {
    if history.goBack() != nil { locationDidChange() }
  }

  func goForward() {
    if history.goForward() != nil { locationDidChange() }
  }

  func goUp() {
    if let parent = current.parent { open(parent) }
  }

  func reload() {
    load(current, showSpinner: listing == nil, reportsFailure: true)
  }

  func loadIfNeeded() {
    guard isConnected, listing == nil, state != .loading else { return }
    load(current, showSpinner: true)
  }

  /// Creates the folder under the current location and opens it, so the next drop lands there.
  /// A folder that already exists under the same name is opened instead.
  func createFolder(named rawName: String) async throws {
    guard let client else { throw BrowserError.notConnected }
    let parent = current
    let path = try parent.appending(rawName)
    if let existing = listing?.existingFolder(matching: path) {
      open(existing)
      return
    }
    try await client.createFolder(path)
    cache[parent] = nil
    open(path)
  }

  func recordDestination(_ path: FolderPath) {
    recents.record(path)
    persistRecents()
  }

  /// Uploaded keys make cached listings stale; refresh the visible folder shortly after.
  func objectsDidChange(keys: [String]) {
    guard !keys.isEmpty else { return }
    let visible = current
    cache = cache.filter { path, _ in
      path == visible || !keys.contains { $0.utf8.starts(with: path.prefix.utf8) }
    }
    guard keys.contains(where: { $0.utf8.starts(with: visible.prefix.utf8) }) else { return }
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled, let self, self.current == visible else { return }
      self.load(visible, showSpinner: false)
    }
  }

  private func locationDidChange() {
    persist()
    if let cached = cache[current] {
      state = .loaded(cached)
      load(current, showSpinner: false)
    } else {
      load(current, showSpinner: true)
    }
  }

  private func load(_ path: FolderPath, showSpinner: Bool, reportsFailure: Bool = false) {
    guard let client else {
      state = .idle
      return
    }
    loadTask?.cancel()
    if showSpinner { state = .loading }
    loadTask = Task { [weak self] in
      do {
        let result = try await client.listFolder(path, pageLimit: 10)
        guard !Task.isCancelled, let self else { return }
        self.cache[path] = result
        if self.current == path { self.state = .loaded(result) }
      } catch {
        guard !Task.isCancelled, let self, self.current == path else { return }
        let message = UploadViewModel.userMessage(for: error)
        if showSpinner || self.cache[path] == nil {
          self.state = .failed(message)
        } else if reportsFailure {
          UploadViewModel.shared.errorMessage = "フォルダを更新できませんでした。\(message)"
        }
      }
    }
  }

  private func persist() {
    UserDefaults.standard.set(current.prefix, forKey: Keys.location)
  }

  private func persistRecents() {
    if let data = try? JSONEncoder().encode(recents) {
      UserDefaults.standard.set(data, forKey: Keys.recents)
    }
  }

  private enum Keys {
    static let location = "upload.prefix"
    static let recents = "upload.recentFolders"
    static let bucket = "upload.locationBucket"
    static let sortKey = "browser.sortKey"
    static let sortAscending = "browser.sortAscending"
  }
}

enum BrowserError: LocalizedError {
  case notConnected

  var errorDescription: String? {
    switch self {
    case .notConnected: "先に接続設定で R2 のバケットを保存してください。"
    }
  }
}
