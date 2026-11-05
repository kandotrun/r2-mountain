import Foundation
import Testing

@testable import MountainCore

/// Restored jobs in these states never start, so any S3 call is a test failure.
private struct UnusedS3Store: S3ObjectStore {
  private func unexpected() -> S3Failure {
    Issue.record("Unexpected S3 call")
    return S3Failure(status: 0, code: "UnexpectedCall")
  }
  func testConnection() async throws { throw unexpected() }
  func head(key: String) async throws -> S3ObjectMetadata? { throw unexpected() }
  func put(key: String, file: URL, size: Int64, contentMD5: String, jobID: String) async throws
    -> String
  { throw unexpected() }
  func createMultipart(key: String, jobID: String) async throws -> String { throw unexpected() }
  func uploadPart(
    key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5: String
  ) async throws -> String { throw unexpected() }
  func listParts(key: String, uploadID: String) async throws -> [S3RemotePart] {
    throw unexpected()
  }
  func completeMultipart(key: String, uploadID: String, parts: [S3CompletedPart]) async throws
    -> String
  { throw unexpected() }
  func abortMultipart(key: String, uploadID: String) async throws { throw unexpected() }
}

private struct SeededEngine {
  let directory: URL
  let jobs: [UploadJob]

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clear-finished-" + UUID().uuidString)
    let other = R2Configuration(accountID: String(repeating: "1", count: 32), bucket: "other")
    jobs = [
      makeJob(.completed, completedBytes: 100), makeJob(.paused, completedBytes: 40),
      makeJob(.cancelled), makeJob(.failed), makeJob(.completed, configuration: other),
      makeJob(.needsCredentials),
    ]
    let store = JournalStore(directory: directory)
    for job in jobs { try store.save(job) }
  }

  func engine() -> UploadEngine {
    UploadEngine(
      configuration: testConfiguration, client: UnusedS3Store(), journalDirectory: directory,
      options: UploadEngineOptions(automaticRetryDelay: 0))
  }

  var unfinishedIDs: Set<UUID> {
    Set(jobs.filter { ![.completed, .cancelled].contains($0.state) }.map(\.id))
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct ClearFinishedTests {
  @Test func removesFinishedJobsFromMemoryAndDiskOnly() async throws {
    let seeded = try SeededEngine()
    defer { seeded.remove() }
    let engine = seeded.engine()
    try await engine.restore()
    let before = await engine.currentJobs()
    #expect(before.count == 6)
    await engine.clearFinished()
    let after = await engine.currentJobs()
    #expect(Set(after.map(\.id)) == seeded.unfinishedIDs)
    #expect(after == before.filter { ![.completed, .cancelled].contains($0.state) })
    #expect(
      journalFiles(seeded.directory) == Set(seeded.unfinishedIDs.map { $0.uuidString + ".json" }))
    let reopened = seeded.engine()
    try await reopened.restore()
    #expect(Set(await reopened.currentJobs().map(\.id)) == seeded.unfinishedIDs)
  }

  @Test func emitsSnapshotAfterClearing() async throws {
    let seeded = try SeededEngine()
    defer { seeded.remove() }
    let engine = seeded.engine()
    try await engine.restore()
    var snapshots = await engine.snapshots().makeAsyncIterator()
    #expect(await snapshots.next()?.count == 6)
    await engine.clearFinished()
    #expect((await snapshots.next()).map { Set($0.map(\.id)) } == seeded.unfinishedIDs)
  }

  @Test func keepsJobsWhoseJournalCannotBeDeleted() async throws {
    let seeded = try SeededEngine()
    defer { seeded.remove() }
    let engine = seeded.engine()
    try await engine.restore()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: seeded.directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: seeded.directory.path)
    }
    let before = await engine.currentJobs()
    await engine.clearFinished()
    let kept = await engine.currentJobs()
    #expect(kept.map(\.id) == before.map(\.id))
    #expect(journalFiles(seeded.directory).count == 6)
    for (job, original) in zip(kept, before) {
      if original.state.isFinished {
        #expect(job.state == original.state)
        #expect(job.errorMessage == "転送記録を削除できませんでした。アクセス権を確認して、もう一度消去してください。")
      } else {
        #expect(job == original)
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: seeded.directory.path)
    await engine.clearFinished()
    #expect(Set(await engine.currentJobs().map(\.id)) == seeded.unfinishedIDs)
  }
}
