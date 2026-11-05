import CryptoKit
import Foundation

public struct UploadedObject: Sendable, Equatable {
  public let eTag: String
  public let size: Int64

  public init(eTag: String, size: Int64) {
    self.eTag = eTag
    self.size = size
  }
}

struct ExactUploadJournal: Codable, Sendable {
  var version = 1
  let key: String
  let size: Int64
  let modified: Date
  let partSize: Int64
  let uploadID: String
  var parts: [S3CompletedPart]
}

struct PartLayout: Sendable {
  let size: Int64
  let partSize: Int64
  var count: Int { Int((size + partSize - 1) / partSize) }

  func offset(_ number: Int) -> Int64 { Int64(number - 1) * partSize }
  func length(_ number: Int) -> Int64 { min(partSize, size - offset(number)) }
}

struct FileDigest: Sendable {
  let hex: String
  let base64: String

  static func md5(_ file: URL, offset: Int64, length: Int64) throws -> FileDigest {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    var digest = Insecure.MD5()
    var remaining = length
    while remaining > 0 {
      try Task.checkCancellation()
      guard let data = try handle.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty
      else { throw UploadError.sourceChanged }
      digest.update(data: data)
      remaining -= Int64(data.count)
    }
    let value = Data(digest.finalize())
    return FileDigest(
      hex: value.map { String(format: "%02x", $0) }.joined(), base64: value.base64EncodedString())
  }
}

public actor ExactUploader {
  private let store: any S3MountStore
  private let journalDirectory: URL
  private let partDirectory: URL
  private let partConcurrency: Int
  private let multipartThreshold: Int64
  private let partSizeOverride: Int64?
  private var busy: Set<String> = []
  private var waiters: [String: [UUID: CheckedContinuation<Void, any Error>]] = [:]

  public init(store: any S3MountStore, journalDirectory: URL, partConcurrency: Int = 4) {
    self.init(
      store: store, journalDirectory: journalDirectory, partConcurrency: partConcurrency,
      multipartThreshold: 64 * 1_048_576, partSize: nil)
  }

  init(
    store: any S3MountStore, journalDirectory: URL, partConcurrency: Int,
    multipartThreshold: Int64, partSize: Int64?
  ) {
    self.store = store
    self.journalDirectory = journalDirectory
    partDirectory = journalDirectory.appendingPathComponent("parts", isDirectory: true)
    self.partConcurrency = max(1, partConcurrency)
    self.multipartThreshold = multipartThreshold
    partSizeOverride = partSize
    // Only one process owns this directory, so leftover parts are from a crash.
    try? FileManager.default.removeItem(at: partDirectory)
  }

  /// Sends the file to exactly this key. When `overwrite` is false the write is create-only.
  /// Calls sharing a journal ID run one at a time; a failed or cancelled call leaves its journal
  /// so the next call resumes the same multipart upload.
  public func upload(
    file: URL, key: String, journalID: String, overwrite: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> UploadedObject {
    guard !key.isEmpty else { throw MountError.invalidName }
    try await acquire(journalID)
    defer { release(journalID) }
    let identity = try SourceIdentity.read(file)
    let journalURL = journalURL(for: journalID)
    let previous = loadJournal(journalURL)
    guard identity.size >= multipartThreshold else {
      if let previous { try await discard(previous, at: journalURL) }
      return try await uploadSingle(
        file: file, size: identity.size, key: key, overwrite: overwrite, progress: progress)
    }
    let layout = PartLayout(
      size: identity.size,
      partSize: try partSizeOverride ?? MultipartPlan(size: identity.size).partSize)
    guard layout.count <= 10_000 else { throw UploadError.invalidSize }
    var journal: ExactUploadJournal
    switch try await begin(
      previous: previous, file: file, key: key, layout: layout, identity: identity,
      overwrite: overwrite, journalURL: journalURL)
    {
    case .finished(let object):
      progress(layout.size)
      return object
    case .upload(let started): journal = started
    }
    let uploadID = journal.uploadID
    var sent = journal.parts.reduce(0) { $0 + $1.size }
    progress(sent)
    let done = Set(journal.parts.map(\.number))
    let store = store
    let partDirectory = partDirectory
    try await forEachConcurrently(
      (1...layout.count).filter { !done.contains($0) }, limit: partConcurrency
    ) { number in
      let prepared = try PartSource.prepare(
        source: file, identity: identity, offset: layout.offset(number),
        length: layout.length(number), directory: partDirectory)
      defer { prepared.remove() }
      let eTag = try await store.uploadPart(
        key: key, uploadID: uploadID, number: number, file: prepared.url, size: prepared.size,
        contentMD5: prepared.contentMD5)
      return S3CompletedPart(
        number: number, size: prepared.size, eTag: eTag, md5Hex: prepared.md5Hex)
    } onEach: { part in
      journal.parts.append(part)
      try save(journal, to: journalURL)
      sent += part.size
      progress(sent)
    }
    try identity.verify(file)
    let parts = journal.parts.sorted { $0.number < $1.number }
    guard parts.count == layout.count else { throw S3Failure(status: 0, code: "MissingParts") }
    do {
      let eTag = try await store.completeMultipart(
        key: key, uploadID: uploadID, parts: parts, overwrite: overwrite)
      try removeJournal(journalURL)
      return UploadedObject(eTag: eTag, size: layout.size)
    } catch MountError.alreadyExists {
      await uncancelled { [store] in try? await store.abortMultipart(key: key, uploadID: uploadID) }
      try removeJournal(journalURL)
      let current = try await store.head(key: key)
      if let done = try await sameObject(current, file: file, layout: layout, parts: parts) {
        return done
      }
      throw MountError.alreadyExists
    }
  }

  private enum Beginning {
    case upload(ExactUploadJournal)
    case finished(UploadedObject)
  }

  /// Resumes the journal's upload when it still fits this file, otherwise starts over.
  private func begin(
    previous: ExactUploadJournal?, file: URL, key: String, layout: PartLayout,
    identity: SourceIdentity, overwrite: Bool, journalURL: URL
  ) async throws -> Beginning {
    var checked = false
    if let previous {
      if previous.key.utf8.elementsEqual(key.utf8), previous.size == layout.size,
        previous.partSize == layout.partSize
      {
        do {
          var resumed = previous
          resumed.parts = try await matching(
            store.listParts(key: key, uploadID: previous.uploadID), file: file, layout: layout)
          try save(resumed, to: journalURL)
          return .upload(resumed)
        } catch let failure as S3Failure where failure.isMissingUpload {
          try removeJournal(journalURL)
        }
        // The upload may be gone because it completed and only the response was lost.
        if let done = try await settled(key: key, file: file, layout: layout, overwrite: overwrite)
        {
          return .finished(done)
        }
        checked = true
      } else {
        try await discard(previous, at: journalURL)
      }
    }
    if !checked, !overwrite,
      let done = try await settled(key: key, file: file, layout: layout, overwrite: false)
    {
      return .finished(done)
    }
    let started = ExactUploadJournal(
      key: key, size: layout.size, modified: identity.modifiedAt, partSize: layout.partSize,
      uploadID: try await store.createMultipart(key: key), parts: [])
    try save(started, to: journalURL)
    return .upload(started)
  }

  /// This file's own earlier result counts as done; any other object blocks a create-only upload.
  private func settled(key: String, file: URL, layout: PartLayout, overwrite: Bool) async throws
    -> UploadedObject?
  {
    let current = try await store.head(key: key)
    if let done = try await sameObject(current, file: file, layout: layout, parts: nil) {
      return done
    }
    if !overwrite, current != nil { throw MountError.alreadyExists }
    return nil
  }

  private func uploadSingle(
    file: URL, size: Int64, key: String, overwrite: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> UploadedObject {
    let whole = PartLayout(size: size, partSize: max(1, size))
    let digests = try await Self.digests(of: file, layout: whole, numbers: [1], limit: 1)
    guard let digest = digests[1] else { throw UploadError.sourceChanged }
    do {
      let eTag = try await store.put(
        key: key, file: file, size: size, contentMD5: digest.base64, overwrite: overwrite)
      progress(size)
      return UploadedObject(eTag: eTag, size: size)
    } catch MountError.alreadyExists {
      // Identical bytes already at the key are this upload, e.g. after a lost response.
      guard let existing = try await store.head(key: key), existing.size == size,
        normalizedETag(existing.eTag) == digest.hex
      else { throw MountError.alreadyExists }
      progress(size)
      return UploadedObject(eTag: existing.eTag, size: size)
    }
  }

  /// Remote parts whose ETag is the MD5 of the file's bytes at that position now.
  private func matching(_ remote: [S3RemotePart], file: URL, layout: PartLayout) async throws
    -> [S3CompletedPart]
  {
    let candidates = remote.filter {
      (1...layout.count).contains($0.number) && $0.size == layout.length($0.number)
    }
    let digests = try await Self.digests(
      of: file, layout: layout, numbers: candidates.map(\.number), limit: partConcurrency)
    return candidates.compactMap { part in
      guard let digest = digests[part.number], normalizedETag(part.eTag) == digest.hex else {
        return nil
      }
      return S3CompletedPart(
        number: part.number, size: part.size, eTag: part.eTag, md5Hex: digest.hex)
    }
  }

  /// The existing object when it is exactly this file sent with this part layout.
  private func sameObject(
    _ existing: S3ObjectMetadata?, file: URL, layout: PartLayout, parts known: [S3CompletedPart]?
  ) async throws -> UploadedObject? {
    guard let existing, existing.size == layout.size,
      normalizedETag(existing.eTag).hasSuffix("-\(layout.count)")
    else { return nil }
    var parts = known ?? []
    if known == nil {
      let digests = try await Self.digests(
        of: file, layout: layout, numbers: Array(1...layout.count), limit: partConcurrency)
      parts = digests.map {
        S3CompletedPart(
          number: $0.key, size: layout.length($0.key), eTag: "", md5Hex: $0.value.hex)
      }
    }
    guard normalizedETag(existing.eTag) == PartSource.multipartETag(parts) else { return nil }
    return UploadedObject(eTag: existing.eTag, size: layout.size)
  }

  private static func digests(of file: URL, layout: PartLayout, numbers: [Int], limit: Int)
    async throws -> [Int: FileDigest]
  {
    var result: [Int: FileDigest] = [:]
    try await forEachConcurrently(numbers, limit: limit) { number in
      (
        number,
        try FileDigest.md5(file, offset: layout.offset(number), length: layout.length(number))
      )
    } onEach: {
      result[$0.0] = $0.1
    }
    return result
  }

  private func discard(_ journal: ExactUploadJournal, at url: URL) async throws {
    do {
      try await store.abortMultipart(key: journal.key, uploadID: journal.uploadID)
    } catch let failure as S3Failure where failure.isMissingUpload {
      // Already gone.
    }
    try removeJournal(url)
  }

  /// Hashed so any identifier, slashes included, is one safe file name.
  private func journalURL(for journalID: String) -> URL {
    let name = SHA256.hash(data: Data(journalID.utf8)).map { String(format: "%02x", $0) }.joined()
    return journalDirectory.appendingPathComponent(name + ".json")
  }

  private func loadJournal(_ url: URL) -> ExactUploadJournal? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let journal = try? JSONDecoder().decode(ExactUploadJournal.self, from: data),
      journal.version == 1
    else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return journal
  }

  private func save(_ journal: ExactUploadJournal, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: journalDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(journal).write(
        to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    } catch { throw UploadError.localStorage }
  }

  private func removeJournal(_ url: URL) throws {
    do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError
      where error.code == .fileNoSuchFile
    {
      // Already absent.
    } catch { throw UploadError.localStorage }
  }

  /// A cancelled caller stops waiting at once instead of when the running call ends.
  private func acquire(_ journalID: String) async throws {
    while busy.contains(journalID) {
      let ticket = UUID()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiters[journalID, default: [:]][ticket] = continuation
          }
        }
      } onCancel: {
        Task { await self.stopWaiting(journalID, ticket) }
      }
    }
    try Task.checkCancellation()
    busy.insert(journalID)
  }

  private func stopWaiting(_ journalID: String, _ ticket: UUID) {
    waiters[journalID]?.removeValue(forKey: ticket)?.resume(throwing: CancellationError())
  }

  func waitingCount(_ journalID: String) -> Int { waiters[journalID]?.count ?? 0 }

  private func release(_ journalID: String) {
    busy.remove(journalID)
    for waiter in waiters.removeValue(forKey: journalID)?.values ?? [:].values { waiter.resume() }
  }
}
