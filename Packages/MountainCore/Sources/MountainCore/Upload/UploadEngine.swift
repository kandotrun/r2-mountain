import Foundation

public actor UploadEngine {
  private let configuration: R2Configuration
  private let client: any S3ObjectStore
  private let store: JournalStore
  private let temporaryDirectory: URL
  private let options: UploadEngineOptions
  private var jobs: [UploadJob] = []
  private var subscribers: [UUID: AsyncStream<[UploadJob]>.Continuation] = [:]
  private var activeID: UUID?
  private var activeTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var terminating = false
  public private(set) var importWarnings: [String] = []

  public init(
    configuration: R2Configuration, client: any S3ObjectStore,
    journalDirectory: URL, options: UploadEngineOptions = .init()
  ) {
    self.configuration = configuration
    self.client = client
    store = JournalStore(directory: journalDirectory)
    temporaryDirectory = journalDirectory.appendingPathComponent("parts", isDirectory: true)
    self.options = options
  }

  public func snapshots() -> AsyncStream<[UploadJob]> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      subscribers[id] = continuation
      continuation.yield(jobs)
      continuation.onTermination = { @Sendable _ in Task { await self.removeSubscriber(id) } }
    }
  }

  public func currentJobs() -> [UploadJob] { jobs }

  public func restore() async throws {
    guard activeTask == nil else { return }
    try configuration.validate()
    let restored = try store.load()
    importWarnings = restored.warnings
    jobs = restored.jobs.map { original in
      var job = original
      job.attemptStartedAt = nil
      guard job.size >= 0, job.size <= MultipartPlan.maximumObjectSize,
        job.partSize > 0, job.partSize <= MultipartPlan.maximumPartSize,
        job.size == job.sourceIdentity.size,
        Set(job.completedParts.map(\.number)).count == job.completedParts.count,
        job.completedParts.allSatisfy({
          $0.number > 0 && $0.number <= 10_000 && $0.size > 0
            && $0.md5Hex.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
        })
      else {
        job.state = .failed
        job.errorMessage = "転送記録の値が正しくありません。元ファイルをもう一度選択してください。"
        return job
      }
      guard job.configuration == configuration else {
        if job.state != .completed && job.state != .cancelled {
          job.state = .failed
          job.errorMessage = "この転送は別の接続設定で作られました。元の接続設定で再開してください。"
        }
        return job
      }
      if ![.paused, .completed, .cancelled, .failed, .needsCredentials].contains(job.state) {
        job.state = job.cancellationRequested ? .cancelling : .queued
      }
      return job
    }
    // Only one process owns this directory. Old part files are disposable snapshots.
    try? FileManager.default.removeItem(at: temporaryDirectory)
    emit()
    startNextIfNeeded()
  }

  public func enqueue(urls: [URL], prefix: String) async throws {
    try configuration.validate()
    _ = try ObjectKey.make(prefix: prefix, relativePath: "validation")
    let imported = try await Task.detached(priority: .utility) { try SourceImporter.collect(urls) }
      .value
    importWarnings = imported.skipped.map { "転送対象外: \($0)" }
    var additions: [UploadJob] = []
    var reserved = Set(jobs.filter { $0.state != .cancelled }.map(\.key))
    for source in imported.sources {
      let plan = try MultipartPlan(size: source.identity.size)
      let original = try ObjectKey.make(prefix: prefix, relativePath: source.relativePath)
      var key = original
      var ordinal = 1
      while reserved.contains(key) {
        ordinal += 1
        key = ObjectKey.suffixed(original, ordinal: ordinal)
      }
      var job = UploadJob(
        sourceURL: source.url, relativePath: source.relativePath, key: original,
        configuration: configuration, identity: source.identity,
        partSize: max(
          options.minimumPartSize,
          plan.partSize == 64 * 1_048_576
            ? options.minimumPartSize : plan.partSize),
        skippedItems: imported.skipped)
      job.key = key
      job.nameOrdinal = ordinal
      try store.save(job)
      additions.append(job)
      reserved.insert(key)
    }
    jobs.append(contentsOf: additions)
    emit()
    startNextIfNeeded()
  }

  public func pause(id: UUID) async {
    guard let index = jobIndex(id),
      ![.completed, .cancelled, .cancelling].contains(jobs[index].state)
    else { return }
    jobs[index].state = .paused
    saveBestEffort(id)
    emit()
    if activeID == id, let task = activeTask {
      task.cancel()
      await task.value
    }
  }

  public func resume(id: UUID) async {
    guard var index = jobIndex(id), ![.completed, .cancelled].contains(jobs[index].state),
      jobs[index].configuration == configuration
    else { return }
    if activeID == id, let task = activeTask {
      guard
        [.paused, .failed, .waitingForNetwork, .reconciling, .needsCredentials].contains(
          jobs[index].state)
      else { return }
      await task.value
      guard let updated = jobIndex(id) else { return }
      index = updated
    }
    jobs[index].state = jobs[index].cancellationRequested ? .cancelling : .queued
    jobs[index].errorMessage = nil
    saveBestEffort(id)
    emit()
    startNextIfNeeded()
  }

  public func cancel(id: UUID) async {
    guard let index = jobIndex(id), ![.completed, .cancelled].contains(jobs[index].state) else {
      return
    }
    jobs[index].cancellationRequested = true
    jobs[index].state = .cancelling
    saveBestEffort(id)
    emit()
    if activeID == id, let task = activeTask {
      task.cancel()
      await task.value
    }
    startNextIfNeeded()
  }

  public func resumeWaiting() async {
    guard !terminating else { return }
    for index in jobs.indices where [.waitingForNetwork, .reconciling].contains(jobs[index].state) {
      jobs[index].state = jobs[index].cancellationRequested ? .cancelling : .queued
      saveBestEffort(jobs[index].id)
    }
    emit()
    startNextIfNeeded()
  }

  public func clearFinished() async {
    var removed = Set<UUID>()
    for index in jobs.indices where jobs[index].state.isFinished {
      do {
        try store.delete(jobs[index].id)
        removed.insert(jobs[index].id)
      } catch {
        // A journal that cannot be deleted would reappear on restore, so keep it visible.
        jobs[index].errorMessage = "転送記録を削除できませんでした。アクセス権を確認して、もう一度消去してください。"
      }
    }
    jobs.removeAll { removed.contains($0.id) }
    emit()
  }

  public func prepareForTermination() async {
    terminating = true
    retryTask?.cancel()
    retryTask = nil
    if let id = activeID, let index = jobIndex(id),
      ![.completed, .cancelled, .paused].contains(jobs[index].state)
    {
      jobs[index].state = jobs[index].cancellationRequested ? .cancelling : .queued
      saveBestEffort(id)
    }
    if let task = activeTask {
      task.cancel()
      await task.value
    }
    emit()
  }

  private func jobIndex(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
  private func job(_ id: UUID) throws -> UploadJob {
    guard let index = jobIndex(id) else { throw CancellationError() }
    return jobs[index]
  }
  private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
  private func emit() { for continuation in subscribers.values { continuation.yield(jobs) } }
  private func persist(_ id: UUID) throws {
    try store.save(try job(id))
    emit()
  }
  private func saveBestEffort(_ id: UUID) {
    do { try store.save(try job(id)) } catch {
      if let index = jobIndex(id) {
        jobs[index].errorMessage = UploadError.localStorage.localizedDescription
      }
    }
  }

  private func startNextIfNeeded() {
    guard activeTask == nil, !terminating else { return }
    guard
      let next = jobs.first(where: {
        $0.configuration == configuration && ($0.state == .queued || $0.state == .cancelling)
      })
    else {
      scheduleRetryIfNeeded()
      return
    }
    activeID = next.id
    activeTask = Task {
      await self.execute(next.id)
      self.finished(next.id)
    }
  }

  private func finished(_ id: UUID) {
    guard activeID == id else { return }
    activeTask = nil
    activeID = nil
    emit()
    startNextIfNeeded()
  }

  private func scheduleRetryIfNeeded() {
    guard retryTask == nil, options.automaticRetryDelay > 0,
      jobs.contains(where: { [.waitingForNetwork, .reconciling].contains($0.state) })
    else { return }
    let delay = options.automaticRetryDelay
    retryTask = Task {
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      self.retryTask = nil
      await self.resumeWaiting()
    }
  }

  private func execute(_ id: UUID) async {
    do {
      var current = try job(id)
      if current.pendingOperation != nil {
        if try await reconcilePending(id) { return }
        // An unknown server-side write must not be blindly repeated or renamed.
        return
      }
      if current.cancellationRequested {
        try await cancelKnownUpload(id)
        return
      }
      try current.sourceIdentity.verify(current.sourceURL)
      if let index = jobIndex(id) {
        jobs[index].state = .uploading
        jobs[index].attemptStartedAt = Date()
        jobs[index].attemptStartingBytes = jobs[index].completedBytes
        jobs[index].errorMessage = nil
      }
      try persist(id)
      for _ in 0..<10_000 {
        try ensureRunning(id)
        current = try job(id)
        if current.uploadID == nil { try await selectAvailableKey(id) }
        do {
          if current.size < options.multipartThreshold {
            try await uploadSingle(id)
          } else {
            try await uploadMultipart(id)
          }
          return
        } catch let error as S3Failure where error.isConflict {
          try ensureRunning(id)
          if try await acceptCompletedObject(id) { return }
          let existing = try job(id)
          if let uploadID = existing.uploadID {
            try await retry(options: options) {
              try await self.client.abortMultipart(key: existing.key, uploadID: uploadID)
            }
          }
          guard let index = jobIndex(id) else { return }
          jobs[index].uploadID = nil
          jobs[index].completedParts = []
          jobs[index].completedBytes = 0
          jobs[index].pendingOperation = nil
          jobs[index].expectedETag = nil
          jobs[index].nameOrdinal += 1
          jobs[index].key = ObjectKey.suffixed(
            jobs[index].originalKey, ordinal: jobs[index].nameOrdinal)
          jobs[index].state = .uploading
          try persist(id)
        }
      }
      throw S3Failure(status: 0, code: "TooManyNameConflicts")
    } catch {
      await handleFailure(error, id: id)
    }
  }

  private func ensureRunning(_ id: UUID) throws {
    try Task.checkCancellation()
    let current = try job(id)
    guard !terminating, !current.cancellationRequested,
      ![.paused, .cancelled, .completed].contains(current.state)
    else { throw CancellationError() }
  }

  private func selectAvailableKey(_ id: UUID) async throws {
    while true {
      try ensureRunning(id)
      let current = try job(id)
      guard current.key.utf8.count <= 1024 else { throw UploadError.invalidPath }
      let reserved = jobs.contains {
        $0.id != id && $0.key == current.key && $0.state != .cancelled
      }
      if !reserved {
        let existing = try await retry(options: options) {
          try await self.client.head(key: current.key)
        }
        if existing == nil { return }
      }
      guard let index = jobIndex(id) else { throw CancellationError() }
      jobs[index].nameOrdinal += 1
      jobs[index].key = ObjectKey.suffixed(current.originalKey, ordinal: jobs[index].nameOrdinal)
      try persist(id)
    }
  }

  private func preparePart(_ current: UploadJob, offset: Int64, length: Int64) async throws
    -> PreparedPart
  {
    let directory = temporaryDirectory
    let task = Task.detached(priority: .utility) {
      try PartSource.prepare(
        source: current.sourceURL, identity: current.sourceIdentity,
        offset: offset, length: length, directory: directory)
    }
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }

  private func uploadSingle(_ id: UUID, isReplay: Bool = false) async throws {
    let current = try job(id)
    let part = try await preparePart(current, offset: 0, length: current.size)
    defer { part.remove() }
    try ensureRunning(id)
    guard let index = jobIndex(id) else { return }
    jobs[index].expectedETag = part.md5Hex
    jobs[index].pendingOperation = .put
    jobs[index].state = .putPending
    try persist(id)
    let result: String
    do {
      result = try await client.put(
        key: current.key, file: part.url, size: part.size,
        contentMD5: part.contentMD5, jobID: id.uuidString)
    } catch {
      if !isReplay { try clearDefinitivelyRejectedWrite(error, id: id) }
      throw error
    }
    guard normalizedETag(result) == part.md5Hex else {
      throw S3Failure(status: 0, code: "ChecksumMismatch")
    }
    if try await acceptCompletedObject(id) { return }
    setReconciling(id)
  }

  private func uploadMultipart(_ id: UUID, recreationCount: Int = 0) async throws {
    var current = try job(id)
    if current.uploadID == nil {
      let creationKey = current.key
      let uploadID = try await retry(options: options) {
        try await self.client.createMultipart(key: creationKey, jobID: id.uuidString)
      }
      guard let index = jobIndex(id) else { return }
      jobs[index].uploadID = uploadID
      try persist(id)
    }
    current = try job(id)
    guard let uploadID = current.uploadID else {
      throw S3Failure(status: 0, code: "MissingUploadID")
    }
    let remote: [S3RemotePart]
    let listingKey = current.key
    do {
      remote = try await retry(options: options) {
        try await self.client.listParts(key: listingKey, uploadID: uploadID)
      }
    } catch let error as S3Failure where error.isMissingUpload {
      if try await acceptCompletedObject(id) { return }
      guard recreationCount < 1 else { throw URLError(.networkConnectionLost) }
      guard let index = jobIndex(id) else { return }
      jobs[index].uploadID = nil
      jobs[index].completedParts = []
      jobs[index].completedBytes = 0
      try persist(id)
      return try await uploadMultipart(id, recreationCount: recreationCount + 1)
    }
    let byNumber = Dictionary(
      remote.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    guard let index = jobIndex(id) else { return }
    jobs[index].completedParts = current.completedParts.filter { local in
      guard let other = byNumber[local.number] else { return false }
      return local.size == other.size && normalizedETag(local.eTag) == normalizedETag(other.eTag)
        && normalizedETag(local.eTag) == local.md5Hex
    }
    jobs[index].completedBytes = jobs[index].completedParts.reduce(0) { $0 + $1.size }
    try persist(id)
    current = try job(id)
    let count = Int(
      current.size / current.partSize + (current.size % current.partSize == 0 ? 0 : 1))
    guard count <= 10_000 else { throw UploadError.invalidSize }
    let done = Set(current.completedParts.map(\.number))
    let missing = (1...count).filter { !done.contains($0) }
    let immutable = current
    let client = client
    let directory = temporaryDirectory
    let options = options
    try await withThrowingTaskGroup(of: Void.self) { group in
      var iterator = missing.makeIterator()
      func add(_ number: Int) {
        group.addTask {
          let offset = Int64(number - 1) * immutable.partSize
          let length = min(immutable.partSize, immutable.size - offset)
          let prepared = try PartSource.prepare(
            source: immutable.sourceURL,
            identity: immutable.sourceIdentity,
            offset: offset, length: length, directory: directory)
          defer { prepared.remove() }
          let eTag = try await retry(options: options) {
            try await client.uploadPart(
              key: immutable.key, uploadID: uploadID,
              number: number, file: prepared.url,
              size: length, contentMD5: prepared.contentMD5)
          }
          guard normalizedETag(eTag) == prepared.md5Hex else {
            throw S3Failure(status: 0, code: "ChecksumMismatch")
          }
          try await self.recordPart(
            S3CompletedPart(
              number: number, size: length, eTag: eTag,
              md5Hex: prepared.md5Hex), id: id)
        }
      }
      for _ in 0..<4 { if let number = iterator.next() { add(number) } }
      while try await group.next() != nil {
        try ensureRunning(id)
        if let number = iterator.next() { add(number) }
      }
    }
    try ensureRunning(id)
    current = try job(id)
    try current.sourceIdentity.verify(current.sourceURL)
    guard current.completedParts.count == count else {
      throw S3Failure(status: 0, code: "MissingParts")
    }
    let expected = PartSource.multipartETag(current.completedParts)
    guard let index = jobIndex(id) else { return }
    jobs[index].expectedETag = expected
    jobs[index].pendingOperation = .complete
    jobs[index].state = .completing
    try persist(id)
    let eTag: String
    do {
      eTag = try await client.completeMultipart(
        key: current.key, uploadID: uploadID,
        parts: current.completedParts.sorted { $0.number < $1.number })
    } catch {
      try clearDefinitivelyRejectedWrite(error, id: id)
      throw error
    }
    guard normalizedETag(eTag) == expected else {
      throw S3Failure(status: 0, code: "ChecksumMismatch")
    }
    if try await acceptCompletedObject(id) { return }
    setReconciling(id)
  }

  private func recordPart(_ part: S3CompletedPart, id: UUID) throws {
    guard let index = jobIndex(id) else { return }
    jobs[index].completedParts.removeAll { $0.number == part.number }
    jobs[index].completedParts.append(part)
    jobs[index].completedBytes = jobs[index].completedParts.reduce(0) { $0 + $1.size }
    try persist(id)
  }

  private func acceptCompletedObject(_ id: UUID) async throws -> Bool {
    let current = try job(id)
    guard let expected = current.expectedETag else { return false }
    let metadata = try await client.head(key: current.key)
    guard let metadata else { return false }
    guard metadata.jobID == id.uuidString, metadata.size == current.size,
      normalizedETag(metadata.eTag) == normalizedETag(expected)
    else { return false }
    guard let index = jobIndex(id) else { return false }
    var completed = jobs[index]
    completed.completedBytes = current.size
    completed.state = .completed
    completed.errorMessage = nil
    completed.pendingOperation = nil
    completed.uploadID = nil
    // Preserve the pending intent in memory as well as on disk if final persistence fails.
    try store.save(completed)
    jobs[index] = completed
    emit()
    return true
  }

  private func reconcilePending(_ id: UUID) async throws -> Bool {
    if try await acceptCompletedObject(id) { return true }
    let current = try job(id)
    guard !current.cancellationRequested else {
      setReconciling(id)
      return false
    }
    try ensureRunning(id)
    switch current.pendingOperation {
    case .put:
      // A conditional retry at exactly the same key cannot create a second object.
      // Recreate the fixed body only when the source still matches its original identity.
      try current.sourceIdentity.verify(current.sourceURL)
      try await uploadSingle(id, isReplay: true)
      return (try job(id)).state == .completed
    case .complete:
      guard let uploadID = current.uploadID else {
        setReconciling(id)
        return false
      }
      do {
        let eTag = try await client.completeMultipart(
          key: current.key, uploadID: uploadID,
          parts: current.completedParts.sorted { $0.number < $1.number })
        guard let expected = current.expectedETag,
          normalizedETag(eTag) == normalizedETag(expected)
        else {
          throw S3Failure(status: 0, code: "ChecksumMismatch")
        }
        if try await acceptCompletedObject(id) { return true }
      } catch let error as S3Failure where error.isMissingUpload || error.isConflict {
        if try await acceptCompletedObject(id) { return true }
      }
    case nil: break
    }
    setReconciling(id)
    return false
  }

  private func setReconciling(_ id: UUID) {
    guard let index = jobIndex(id) else { return }
    if jobs[index].state != .paused {
      jobs[index].state = .reconciling
      jobs[index].errorMessage = "保存結果を確認しています。確認できるまで同じファイルを再送しません。"
    }
    saveBestEffort(id)
    emit()
  }

  private func clearDefinitivelyRejectedWrite(_ error: any Error, id: UUID) throws {
    guard let failure = error as? S3Failure, (400..<500).contains(failure.status),
      !failure.isConflict, !failure.isMissingUpload,
      failure.status != 408, failure.status != 429,
      let index = jobIndex(id)
    else { return }
    jobs[index].pendingOperation = nil
    try persist(id)
  }

  private func cancelKnownUpload(_ id: UUID) async throws {
    let current = try job(id)
    if current.pendingOperation != nil {
      _ = try await reconcilePending(id)
      return
    }
    if let uploadID = current.uploadID {
      do { try await client.abortMultipart(key: current.key, uploadID: uploadID) } catch let error
        as S3Failure where error.isMissingUpload
      {
        // Already absent.
      }
    }
    guard let index = jobIndex(id) else { return }
    jobs[index].state = .cancelled
    jobs[index].uploadID = nil
    jobs[index].errorMessage = nil
    try persist(id)
  }

  private func handleFailure(_ error: any Error, id: UUID) async {
    guard let index = jobIndex(id) else { return }
    if terminating || jobs[index].state == .paused {
      saveBestEffort(id)
      return
    }
    if jobs[index].pendingOperation != nil {
      if let failure = error as? S3Failure, failure.isAuthentication {
        jobs[index].state = .needsCredentials
        jobs[index].errorMessage = "認証情報とバケットへのアクセス権を確認してください。"
      } else if let failure = error as? S3Failure,
        (400..<500).contains(failure.status), !failure.isConflict,
        !failure.isMissingUpload, failure.status != 408, failure.status != 429
      {
        jobs[index].state = .failed
        jobs[index].errorMessage = failure.localizedDescription
      } else {
        // Both a dropped response and a cancellation can race a successful server write.
        do { if try await acceptCompletedObject(id) { return } } catch {}
        setReconciling(id)
        return
      }
    } else if let failure = error as? S3Failure, failure.isAuthentication {
      jobs[index].state = .needsCredentials
      jobs[index].errorMessage = "認証情報とバケットへのアクセス権を確認してください。"
    } else if jobs[index].cancellationRequested {
      if error is CancellationError {
        jobs[index].state = .cancelling
        jobs[index].errorMessage = nil
      } else if isTransient(error) {
        jobs[index].state = .waitingForNetwork
        jobs[index].errorMessage = "接続が戻ったらアップロードの中止を完了します。"
      } else {
        jobs[index].state = .failed
        jobs[index].errorMessage = error.localizedDescription
      }
    } else if isTransient(error) || error is CancellationError {
      jobs[index].state = .waitingForNetwork
      jobs[index].errorMessage = "接続を待っています。自動または手動で再開できます。"
    } else {
      jobs[index].state = .failed
      jobs[index].errorMessage =
        (error as? UploadError)?.localizedDescription ?? error.localizedDescription
      if error as? UploadError == .sourceChanged, let uploadID = jobs[index].uploadID {
        let key = jobs[index].key
        try? await client.abortMultipart(key: key, uploadID: uploadID)
      }
    }
    saveBestEffort(id)
    emit()
  }
}

private func isTransient(_ error: any Error) -> Bool {
  if let failure = error as? S3Failure { return failure.isRetryable }
  if let failure = error as? URLError {
    return [
      .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
      .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
      .dataNotAllowed,
    ].contains(failure.code)
  }
  return false
}

private func retry<T: Sendable>(
  options: UploadEngineOptions,
  operation: @Sendable () async throws -> T
) async throws -> T {
  for attempt in 0..<options.maximumAttempts {
    try Task.checkCancellation()
    do { return try await operation() } catch {
      guard isTransient(error), attempt + 1 < options.maximumAttempts else { throw error }
      let serverDelay = (error as? S3Failure)?.retryAfter ?? 0
      let exponential = min(30, options.retryBaseDelay * pow(2, Double(attempt)))
      let jitter = options.retryBaseDelay > 0 ? Double.random(in: 0...0.25) : 0
      let delay = max(serverDelay, exponential + jitter)
      try await Task.sleep(for: .seconds(delay))
    }
  }
  throw URLError(.timedOut)
}
