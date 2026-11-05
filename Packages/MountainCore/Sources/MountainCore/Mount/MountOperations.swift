import Foundation

public actor MountOperations {
  static let singleCopyLimit: Int64 = 5 * 1_073_741_824
  static let copyPartSize: Int64 = 1_073_741_824
  static let deleteBatch = 1_000
  static let concurrency = 4
  static let maximumKeyLength = 1_024
  private let store: any S3MountStore

  public init(store: any S3MountStore) { self.store = store }

  /// An existing marker counts as success.
  public func createFolder(key: String) async throws {
    guard let path = Self.folder(key) else { throw MountError.invalidName }
    try await store.createFolder(path)
  }

  /// Copies, then deletes the source. A replay after the source is gone reports the destination.
  /// Over 5 GiB the copy is rebuilt from parts and gets the default content type, not the
  /// source's headers or user metadata.
  public func moveObject(from source: String, to destination: String, size: Int64) async throws
    -> String
  {
    guard Self.isFile(source), Self.isFile(destination) else { throw MountError.invalidName }
    guard let current = try await store.head(key: source) else {
      if let moved = try await store.head(key: destination) { return moved.eTag }
      throw MountError.notFound
    }
    if source.utf8.elementsEqual(destination.utf8) { return current.eTag }
    // The live object wins over the caller's snapshot.
    let eTag = try await Self.copy(
      store, from: source, to: destination, size: current.size, current: current)
    try await store.deleteObject(key: source)
    return eTag
  }

  /// Copies every key under `source` (marker included), then deletes the sources.
  /// A key already at the destination is copied again unless it is the same object.
  public func moveFolder(
    from source: String, to destination: String,
    progress: @escaping @Sendable (Int, Int) -> Void
  ) async throws {
    guard Self.folder(source) != nil, Self.folder(destination) != nil,
      !destination.utf8.starts(with: source.utf8)
    else { throw MountError.invalidName }
    let sources = try await store.listAll(prefix: source)
    let present = Dictionary(
      try await store.listAll(prefix: destination).map { (Array($0.key.utf8), $0.size) },
      uniquingKeysWith: { first, _ in first })
    guard !sources.isEmpty || !present.isEmpty else { throw MountError.notFound }
    let moves = sources.map { object in
      (
        object,
        destination
          + String(decoding: object.key.utf8.dropFirst(source.utf8.count), as: UTF8.self)
      )
    }
    // Checked up front so an impossible key leaves no partial copies behind.
    guard moves.allSatisfy({ $0.1.utf8.count <= Self.maximumKeyLength }) else {
      throw MountError.invalidName
    }
    let store = store
    let total = sources.count
    var done = 0
    progress(0, total)
    try await forEachConcurrently(moves, limit: Self.concurrency) { move in
      let (object, target) = move
      var current: S3ObjectMetadata?
      if present[Array(target.utf8)] == object.size {
        // Only this move's own earlier copy is skipped; anything else is overwritten.
        current = try await store.head(key: object.key)
        if let current, let existing = try await store.head(key: target),
          Self.same(current, existing)
        {
          return
        }
      }
      _ = try await Self.copy(
        store, from: object.key, to: target, size: object.size, current: current)
    } onEach: {
      done += 1
      progress(done, total)
    }
    try await deleteAll(sources.map(\.key))
  }

  public func deleteObject(key: String) async throws {
    guard !key.isEmpty else { throw MountError.invalidName }
    try await store.deleteObject(key: key)
  }

  /// Deletes every key under the prefix, the marker included.
  public func deleteFolder(prefix: String) async throws {
    guard Self.folder(prefix) != nil else { throw MountError.invalidName }
    try await deleteAll(try await store.listAll(prefix: prefix).map(\.key))
  }

  private func deleteAll(_ keys: [String]) async throws {
    for start in stride(from: 0, to: keys.count, by: Self.deleteBatch) {
      try await store.deleteObjects(
        keys: Array(keys[start..<min(start + Self.deleteBatch, keys.count)]))
    }
  }

  /// CopyObject is atomic; a ranged copy is checked against the source it started from.
  private static func copy(
    _ store: any S3MountStore, from source: String, to destination: String, size: Int64,
    current known: S3ObjectMetadata?
  ) async throws -> String {
    guard size > singleCopyLimit else {
      return try await store.copyObject(from: source, to: destination)
    }
    var original = known
    if original == nil { original = try await store.head(key: source) }
    guard let original else { throw MountError.notFound }
    let size = original.size
    let uploadID = try await store.createMultipart(key: destination)
    do {
      let count = Int((size + copyPartSize - 1) / copyPartSize)
      var parts: [S3CompletedPart] = []
      try await forEachConcurrently(Array(1...count), limit: concurrency) { number in
        let lower = Int64(number - 1) * copyPartSize
        let upper = min(lower + copyPartSize, size) - 1
        let eTag = try await store.uploadPartCopy(
          key: destination, uploadID: uploadID, number: number, source: source,
          range: lower...upper)
        return S3CompletedPart(number: number, size: upper - lower + 1, eTag: eTag, md5Hex: "")
      } onEach: {
        parts.append($0)
      }
      // A source replaced meanwhile would leave parts of two versions, or a truncated one.
      guard let after = try await store.head(key: source), same(original, after) else {
        throw S3Failure(status: 412, code: "PreconditionFailed")
      }
      return try await store.completeMultipart(
        key: destination, uploadID: uploadID, parts: parts.sorted { $0.number < $1.number },
        overwrite: true)
    } catch {
      await uncancelled { try? await store.abortMultipart(key: destination, uploadID: uploadID) }
      throw error
    }
  }

  private static func same(_ lhs: S3ObjectMetadata, _ rhs: S3ObjectMetadata) -> Bool {
    lhs.size == rhs.size && normalizedETag(lhs.eTag) == normalizedETag(rhs.eTag)
  }

  /// The folder a marker key names, only when the key spells it byte for byte.
  private static func folder(_ key: String) -> FolderPath? {
    guard let path = FolderPath(prefix: key), !path.isRoot,
      path.prefix.utf8.elementsEqual(key.utf8)
    else { return nil }
    return path
  }

  private static func isFile(_ key: String) -> Bool {
    !key.isEmpty && key.utf8.last != UInt8(ascii: "/")
  }
}

/// Runs `body` to the end even when the caller is cancelled, as cleanup requests must.
func uncancelled(_ body: @escaping @Sendable () async -> Void) async {
  await Task { await body() }.value
}

/// Runs `body` with at most `limit` items in flight and hands results back as they finish.
func forEachConcurrently<Item: Sendable, Output: Sendable>(
  _ items: [Item], limit: Int, isolation: isolated (any Actor)? = #isolation,
  _ body: @escaping @Sendable (Item) async throws -> Output,
  onEach: (Output) throws -> Void
) async throws {
  try await withThrowingTaskGroup(of: Output.self) { group in
    var pending = items.makeIterator()
    for _ in 0..<max(1, limit) {
      guard let item = pending.next() else { break }
      group.addTask { try await body(item) }
    }
    while let output = try await group.next() {
      try onEach(output)
      if let item = pending.next() { group.addTask { try await body(item) } }
    }
  }
}
