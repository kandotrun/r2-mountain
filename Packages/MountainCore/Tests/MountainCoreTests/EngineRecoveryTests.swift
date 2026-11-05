import CryptoKit
import Foundation
import Testing

@testable import MountainCore

private actor EngineFakeS3: S3ObjectStore {
  struct Object {
    let data: Data
    let jobID: String
    let eTag: String
  }
  struct Upload {
    let key: String
    let jobID: String
    var parts: [Int: Data] = [:]
  }
  var objects: [String: Object] = [:]
  var uploads: [String: Upload] = [:]
  var putCount = 0
  var abortCount = 0
  var completedPartNumbers: [Int] = []
  var activeParts = 0
  var peakParts = 0
  var dropPutResponse = false
  var hideWrittenObjects = false
  var failPutWithoutWriting = false
  var slowParts = false
  var partFailures = 0
  var collideAtCompletion = false
  var putAuthenticationFailures = 0
  var headAuthenticationFailures = 0
  var blockJournalOnHead: URL?

  func configure(
    dropPut: Bool = false, hide: Bool = false, failPut: Bool = false,
    slow: Bool = false, failures: Int = 0, collide: Bool = false, authFailures: Int = 0
  ) {
    dropPutResponse = dropPut
    hideWrittenObjects = hide
    failPutWithoutWriting = failPut
    slowParts = slow
    partFailures = failures
    collideAtCompletion = collide
    putAuthenticationFailures = authFailures
  }
  func revealObjects() { hideWrittenObjects = false }
  func rejectNextHead() { headAuthenticationFailures = 1 }
  func blockJournalAfterWrite(_ directory: URL) { blockJournalOnHead = directory }
  func seed(key: String, data: Data) {
    objects[key] = Object(data: data, jobID: "other", eTag: md5(data))
  }
  func uploadedNumbers() -> [Int] { completedPartNumbers }
  func counts() -> (puts: Int, aborts: Int, peak: Int) { (putCount, abortCount, peakParts) }
  func objectData(_ key: String) -> Data? { objects[key]?.data }
  func testConnection() async throws {}
  func head(key: String) async throws -> S3ObjectMetadata? {
    guard let value = objects[key], !hideWrittenObjects else { return nil }
    if headAuthenticationFailures > 0 {
      headAuthenticationFailures -= 1
      throw S3Failure(status: 403, code: "AccessDenied")
    }
    if let directory = blockJournalOnHead {
      blockJournalOnHead = nil
      try FileManager.default.moveItem(
        at: directory, to: directory.appendingPathExtension("backup"))
      try Data("storage unavailable".utf8).write(to: directory)
    }
    return S3ObjectMetadata(
      size: Int64(value.data.count), eTag: "\"\(value.eTag)\"", jobID: value.jobID)
  }
  func put(key: String, file: URL, size: Int64, contentMD5: String, jobID: String) async throws
    -> String
  {
    putCount += 1
    if putAuthenticationFailures > 0 {
      putAuthenticationFailures -= 1
      throw S3Failure(status: 403, code: "AccessDenied")
    }
    if failPutWithoutWriting { throw URLError(.networkConnectionLost) }
    guard objects[key] == nil else { throw S3Failure(status: 412, code: "PreconditionFailed") }
    let data = try Data(contentsOf: file)
    #expect(data.count == size)
    #expect(Data(Insecure.MD5.hash(data: data)).base64EncodedString() == contentMD5)
    let eTag = md5(data)
    objects[key] = Object(data: data, jobID: jobID, eTag: eTag)
    if dropPutResponse {
      dropPutResponse = false
      throw URLError(.networkConnectionLost)
    }
    return "\"\(eTag)\""
  }
  func createMultipart(key: String, jobID: String) async throws -> String {
    let id = UUID().uuidString
    uploads[id] = Upload(key: key, jobID: jobID)
    return id
  }
  func uploadPart(
    key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5: String
  ) async throws -> String {
    activeParts += 1
    peakParts = max(peakParts, activeParts)
    defer { activeParts -= 1 }
    if slowParts {
      try await Task.sleep(for: .milliseconds(number == 1 ? 15 : 120))
    }
    if partFailures > 0 {
      partFailures -= 1
      throw URLError(.networkConnectionLost)
    }
    guard var upload = uploads[uploadID], upload.key == key else {
      throw S3Failure(status: 404, code: "NoSuchUpload")
    }
    let data = try Data(contentsOf: file)
    #expect(data.count == size)
    #expect(Data(Insecure.MD5.hash(data: data)).base64EncodedString() == contentMD5)
    upload.parts[number] = data
    uploads[uploadID] = upload
    completedPartNumbers.append(number)
    return "\"\(md5(data))\""
  }
  func listParts(key: String, uploadID: String) async throws -> [S3RemotePart] {
    guard let upload = uploads[uploadID] else { throw S3Failure(status: 404, code: "NoSuchUpload") }
    return upload.parts.map {
      S3RemotePart(number: $0.key, size: Int64($0.value.count), eTag: "\"\(md5($0.value))\"")
    }
  }
  func completeMultipart(key: String, uploadID: String, parts: [S3CompletedPart]) async throws
    -> String
  {
    if collideAtCompletion {
      collideAtCompletion = false
      objects[key] = Object(
        data: Data("sentinel".utf8), jobID: "other", eTag: md5(Data("sentinel".utf8)))
    }
    guard objects[key] == nil else { throw S3Failure(status: 412, code: "PreconditionFailed") }
    guard let upload = uploads[uploadID] else { throw S3Failure(status: 404, code: "NoSuchUpload") }
    var data = Data()
    for part in parts.sorted(by: { $0.number < $1.number }) {
      guard let value = upload.parts[part.number] else {
        throw S3Failure(status: 400, code: "InvalidPart")
      }
      data.append(value)
    }
    let eTag = PartSource.multipartETag(parts)
    objects[key] = Object(data: data, jobID: upload.jobID, eTag: eTag)
    uploads.removeValue(forKey: uploadID)
    return "\"\(eTag)\""
  }
  func abortMultipart(key: String, uploadID: String) async throws {
    abortCount += 1
    uploads.removeValue(forKey: uploadID)
  }
}

private func md5(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct EngineWorkspace {
  let root: URL
  let source: URL
  let journal: URL
  init(bytes: Int) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "engine-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    source = root.appendingPathComponent("素材.mov")
    journal = root.appendingPathComponent("journals")
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: source)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private let engineConfiguration = R2Configuration(
  accountID: String(repeating: "0", count: 32), bucket: "test-bucket")
private let tinyOptions = UploadEngineOptions(
  multipartThreshold: 32, minimumPartSize: 16,
  maximumAttempts: 1, retryBaseDelay: 0, automaticRetryDelay: 0)

private func eventually(_ predicate: () async -> Bool) async throws {
  for _ in 0..<300 {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for engine state")
}

@Suite struct EngineRecoveryTests {
  @Test func completeMultipartHasBoundedConcurrencyAndCorrectContent() async throws {
    let workspace = try EngineWorkspace(bytes: 160)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(slow: true)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "backup")
    try await eventually { await engine.currentJobs().first?.state == .completed }
    let jobs = await engine.currentJobs()
    #expect(jobs.count == 1)
    #expect(jobs[0].completedParts.count == 10)
    #expect(await client.counts().peak == 4)
    #expect(await client.objectData(jobs[0].key) == (try Data(contentsOf: workspace.source)))
    await engine.prepareForTermination()
  }

  @Test func restartReusesPersistedPartsAndKeepsUserPause() async throws {
    let workspace = try EngineWorkspace(bytes: 160)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(slow: true)
    let first = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await first.restore()
    try await first.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await client.uploadedNumbers().contains(1) }
    let id = try #require(await first.currentJobs().first?.id)
    await first.pause(id: id)
    await first.prepareForTermination()
    let persisted = try #require(await first.currentJobs().first)
    #expect(persisted.state == .paused)
    #expect(persisted.completedParts.contains { $0.number == 1 })
    let second = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await second.restore()
    #expect(await second.currentJobs().first?.state == .paused)
    await second.resume(id: id)
    try await eventually { await second.currentJobs().first?.state == .completed }
    let successful = await client.uploadedNumbers()
    #expect(successful.filter { $0 == 1 }.count == 1)
    #expect(Set(successful).count == 10)
    await second.prepareForTermination()
  }

  @Test func crashedPutIsRecoveredWithoutDuplicateSuffix() async throws {
    let workspace = try EngineWorkspace(bytes: 7)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(dropPut: true, hide: true)
    let first = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await first.restore()
    try await first.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await first.currentJobs().first?.state == .reconciling }
    await first.prepareForTermination()
    await client.revealObjects()
    let second = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await second.restore()
    try await eventually { await second.currentJobs().first?.state == .completed }
    #expect(await client.counts().puts == 1)
    #expect(await second.currentJobs().first?.key == workspace.source.lastPathComponent)
    await second.prepareForTermination()
  }

  @Test func unknownPutAndHead404RetryOnlySameKeyWithoutSuffix() async throws {
    let workspace = try EngineWorkspace(bytes: 7)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(failPut: true)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await engine.currentJobs().first?.state == .reconciling }
    await engine.resumeWaiting()
    try await eventually { await engine.currentJobs().first?.state == .reconciling }
    #expect(await client.counts().puts == 2)
    #expect(await engine.currentJobs().first?.key == workspace.source.lastPathComponent)
    await engine.prepareForTermination()
  }

  @Test func rejectedAuthenticationCanResumeAfterCredentialsAreFixed() async throws {
    let workspace = try EngineWorkspace(bytes: 7)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(authFailures: 1)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await engine.currentJobs().first?.state == .needsCredentials }
    let pending = try #require(await engine.currentJobs().first)
    #expect(pending.pendingOperation == nil)
    await engine.resume(id: pending.id)
    try await eventually { await engine.currentJobs().first?.state == .completed }
    #expect(await client.counts().puts == 2)
    await engine.prepareForTermination()
  }

  @Test func authenticationFailureDuringReconciliationKeepsPendingIntent() async throws {
    let workspace = try EngineWorkspace(bytes: 7)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(dropPut: true, hide: true)
    let first = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await first.restore()
    try await first.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await first.currentJobs().first?.state == .reconciling }
    await first.prepareForTermination()
    await client.revealObjects()
    await client.rejectNextHead()
    let second = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await second.restore()
    try await eventually { await second.currentJobs().first?.state == .needsCredentials }
    let pending = try #require(await second.currentJobs().first)
    #expect(pending.pendingOperation == .put)
    await second.resume(id: pending.id)
    try await eventually { await second.currentJobs().first?.state == .completed }
    #expect(await client.counts().puts == 1)
    #expect(await second.currentJobs().first?.key == workspace.source.lastPathComponent)
    await second.prepareForTermination()
  }

  @Test func finalJournalFailurePreservesIntentAndDoesNotDuplicateUpload() async throws {
    let workspace = try EngineWorkspace(bytes: 7)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.blockJournalAfterWrite(workspace.journal)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await engine.currentJobs().first?.state == .reconciling }
    let pending = try #require(await engine.currentJobs().first)
    #expect(pending.pendingOperation == .put)
    try FileManager.default.removeItem(at: workspace.journal)
    try FileManager.default.moveItem(
      at: workspace.journal.appendingPathExtension("backup"), to: workspace.journal)
    await engine.resume(id: pending.id)
    try await eventually { await engine.currentJobs().first?.state == .completed }
    #expect(await client.counts().puts == 1)
    #expect(await engine.currentJobs().first?.key == workspace.source.lastPathComponent)
    await engine.prepareForTermination()
  }

  @Test func changedSourceNeverPublishesMultipart() async throws {
    let workspace = try EngineWorkspace(bytes: 160)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(slow: true)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await client.uploadedNumbers().contains(1) }
    try Data(repeating: 0, count: 200).write(to: workspace.source)
    try await eventually { await engine.currentJobs().first?.state == .failed }
    #expect(await client.objectData(workspace.source.lastPathComponent) == nil)
    #expect(await client.counts().aborts == 1)
    await engine.prepareForTermination()
  }

  @Test func completionCollisionPreservesOtherObjectAndUsesNextName() async throws {
    let workspace = try EngineWorkspace(bytes: 48)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(collide: true)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await engine.currentJobs().first?.state == .completed }
    #expect(await client.objectData("素材.mov") == Data("sentinel".utf8))
    #expect(await client.objectData("素材 2.mov") == (try Data(contentsOf: workspace.source)))
    #expect(await client.counts().aborts == 1)
    await engine.prepareForTermination()
  }

  @Test func transientPartFailureCanResumeWithoutReachabilityChange() async throws {
    let workspace = try EngineWorkspace(bytes: 80)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(failures: 1)
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await engine.currentJobs().first?.state == .waitingForNetwork }
    await engine.resumeWaiting()
    try await eventually { await engine.currentJobs().first?.state == .completed }
    await engine.prepareForTermination()
  }

  @Test func clearFinishedForgetsCompletedUploadWithoutDisturbingActiveOne() async throws {
    let workspace = try EngineWorkspace(bytes: 7)
    defer { workspace.remove() }
    let large = workspace.root.appendingPathComponent("large.bin")
    try Data((0..<160).map { UInt8($0) }).write(to: large)
    let client = EngineFakeS3()
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await engine.currentJobs().first?.state == .completed }
    await client.configure(slow: true)
    try await engine.enqueue(urls: [large], prefix: "")
    try await eventually { await client.uploadedNumbers().contains(1) }
    let active = try #require(await engine.currentJobs().last)
    await engine.clearFinished()
    #expect(await engine.currentJobs().map(\.id) == [active.id])
    #expect(journalFiles(workspace.journal) == [active.id.uuidString + ".json"])
    try await eventually { await engine.currentJobs().first?.state == .completed }
    #expect(await client.objectData("large.bin") == (try Data(contentsOf: large)))
    await engine.prepareForTermination()
  }

  @Test func cancelOnlyAbortsThisJobsMultipart() async throws {
    let workspace = try EngineWorkspace(bytes: 160)
    defer { workspace.remove() }
    let client = EngineFakeS3()
    await client.configure(slow: true)
    let unrelated = try await client.createMultipart(key: "other", jobID: "other")
    let engine = UploadEngine(
      configuration: engineConfiguration, client: client,
      journalDirectory: workspace.journal, options: tinyOptions)
    try await engine.restore()
    try await engine.enqueue(urls: [workspace.source], prefix: "")
    try await eventually { await client.uploadedNumbers().contains(1) }
    let id = try #require(await engine.currentJobs().first?.id)
    await engine.cancel(id: id)
    try await eventually { await engine.currentJobs().first?.state == .cancelled }
    #expect(await client.counts().aborts == 1)
    #expect(try await client.listParts(key: "other", uploadID: unrelated).isEmpty)
    await engine.prepareForTermination()
  }
}
