import Foundation
import Testing

@testable import MountainCore

/// 16-byte parts above 32 bytes keep multipart cases small.
private func tinyUploader(
  _ store: FakeMountStore, _ workspace: MountWorkspace, concurrency: Int = 4
) -> ExactUploader {
  ExactUploader(
    store: store, journalDirectory: workspace.journal, partConcurrency: concurrency,
    multipartThreshold: 32, partSize: 16)
}

private func uploadedParts(_ log: [String]) -> [Int] {
  log.compactMap { $0.hasPrefix("uploadPart ") ? Int($0.dropFirst(11)) : nil }
}

private func expectedETag(_ data: Data, partSize: Int = 16) -> String {
  let parts = stride(from: 0, to: data.count, by: partSize).enumerated().map {
    let chunk = data[$0.element..<min($0.element + partSize, data.count)]
    return S3CompletedPart(
      number: $0.offset + 1, size: Int64(chunk.count), eTag: "", md5Hex: md5Hex(Data(chunk)))
  }
  return "\"\(PartSource.multipartETag(parts))\""
}

private let allParts = (1...10).map(String.init).joined(separator: ",")

@Suite("Exact-key resumable uploads")
struct ExactUploaderTests {
  @Test("Files below the threshold are one create-only PUT")
  func singlePut() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(31)
    let store = FakeMountStore()
    let progress = ProgressLog<Int64>()
    let result = try await tinyUploader(store, workspace).upload(
      file: try workspace.file(data), key: "a/素材.bin", journalID: "j", overwrite: false,
      progress: progress.record)
    #expect(result == UploadedObject(eTag: "\"\(md5Hex(data))\"", size: 31))
    #expect(await store.log() == ["put a/素材.bin"])
    #expect(await store.overwriteFlags == [false])
    #expect(await store.object("a/素材.bin")?.data == data)
    #expect(progress.values.last == 31)
    #expect(workspace.journals().isEmpty)
  }

  @Test("The production threshold is 64 MiB")
  func productionThreshold() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let below = try workspace.file(Data(count: 64 * 1_048_576 - 1), name: "below.bin")
    let at = try workspace.file(Data(count: 64 * 1_048_576), name: "at.bin")
    let store = FakeMountStore()
    let uploader = ExactUploader(store: store, journalDirectory: workspace.journal)
    _ = try await uploader.upload(
      file: below, key: "below.bin", journalID: "below", overwrite: true
    ) { _ in }
    let result = try await uploader.upload(
      file: at, key: "at.bin", journalID: "at", overwrite: true
    ) { _ in }
    #expect(result.size == 64 * 1_048_576)
    #expect(
      await store.log() == [
        "put below.bin", "createMultipart at.bin", "uploadPart 1", "complete 1",
      ])
  }

  @Test("Multipart keeps the key bytes, bounds concurrency and assembles the file")
  func multipart() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let key = "dir/Cafe\u{301}.bin"
    let store = FakeMountStore()
    await store.delayParts(by: .milliseconds(30), count: 10)
    let progress = ProgressLog<Int64>()
    let result = try await tinyUploader(store, workspace).upload(
      file: try workspace.file(data), key: key, journalID: "item/1", overwrite: false,
      progress: progress.record)
    #expect(result == UploadedObject(eTag: expectedETag(data), size: 160))
    #expect(await store.object(key)?.data == data)
    #expect(await store.keys() == [key])
    #expect(await store.peakParts == 4)
    let log = await store.log()
    #expect(log.first == "head \(key)")
    #expect(log[1] == "createMultipart \(key)")
    #expect(Set(uploadedParts(log)) == Set(1...10))
    #expect(log.last == "complete \(allParts)")
    #expect(await store.overwriteFlags == [false])
    #expect(isMonotonic(progress.values))
    #expect(progress.values.last == 160)
    #expect(workspace.journals().isEmpty)
    #expect(workspace.partFiles().isEmpty)
  }

  @Test("A failed part leaves a journal; the retry sends only the missing parts")
  func resumeAfterFailure() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let file = try workspace.file(data)
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: false
      ) { _ in }
    }
    let journal = try #require(workspace.journals().first)
    let saved = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
    #expect(saved["key"] as? String == "big.bin")
    #expect(saved["size"] as? Int == 160)
    #expect(saved["partSize"] as? Int == 16)
    #expect(saved["uploadID"] as? String == "upload-1")
    #expect(saved["modified"] != nil)
    let parts = try #require(saved["parts"] as? [[String: Any]])
    #expect(parts.compactMap { $0["number"] as? Int } == [1, 2])
    #expect(parts.first?["md5Hex"] as? String == md5Hex(data.prefix(16)))
    #expect(parts.first?["eTag"] as? String == "\"\(md5Hex(data.prefix(16)))\"")
    #expect(workspace.partFiles().isEmpty)

    await store.clearLog()
    let progress = ProgressLog<Int64>()
    let result = try await uploader.upload(
      file: file, key: "big.bin", journalID: "j", overwrite: false, progress: progress.record)
    #expect(result == UploadedObject(eTag: expectedETag(data), size: 160))
    let log = await store.log()
    #expect(log.first == "listParts upload-1")
    #expect(!log.contains { $0.hasPrefix("createMultipart") })
    #expect(uploadedParts(log) == Array(3...10))
    #expect(log.last == "complete \(allParts)")
    #expect(await store.object("big.bin")?.data == data)
    #expect(progress.values.first == 32)
    #expect(isMonotonic(progress.values))
    #expect(progress.values.last == 160)
    #expect(workspace.journals().isEmpty)
  }

  @Test("Remote parts are reused only when they match the file's current bytes")
  func resumeRechecksContent() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(patternData(160))
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: true
      ) { _ in }
    }
    var changed = patternData(160)
    changed[0] = 0xFF
    try changed.write(to: file)
    await store.clearLog()
    _ = try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
      _ in
    }
    #expect(uploadedParts(await store.log()) == [1] + Array(3...10))
    #expect(await store.object("big.bin")?.data == changed)
  }

  @Test("A size change aborts the old upload and starts over")
  func sizeChangeRestarts() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(patternData(160))
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: true
      ) { _ in }
    }
    let grown = patternData(176, seed: 7)
    try grown.write(to: file)
    await store.clearLog()
    _ = try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
      _ in
    }
    let log = await store.log()
    #expect(Array(log.prefix(2)) == ["abort upload-1", "createMultipart big.bin"])
    #expect(uploadedParts(log) == Array(1...11))
    #expect(await store.object("big.bin")?.data == grown)
    #expect(await store.uploadIDs().isEmpty)
  }

  @Test("A different key for the same journal aborts the old upload at its own key")
  func keyChangeRestarts() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let file = try workspace.file(data)
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "old.bin", journalID: "j", overwrite: true
      ) { _ in }
    }
    await store.clearLog()
    _ = try await uploader.upload(file: file, key: "new.bin", journalID: "j", overwrite: true) {
      _ in
    }
    #expect(Array(await store.log().prefix(2)) == ["abort upload-1", "createMultipart new.bin"])
    #expect(await store.uploadIDs().isEmpty)
    #expect(await store.keys() == ["new.bin"])
  }

  @Test("A vanished upload is started fresh, and failed aborts of it are ignored")
  func vanishedUpload() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let file = try workspace.file(data)
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: true
      ) { _ in }
    }
    await store.forgetUploads()
    await store.clearLog()
    _ = try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
      _ in
    }
    let log = await store.log()
    #expect(
      Array(log.prefix(3)) == ["listParts upload-1", "head big.bin", "createMultipart big.bin"])
    #expect(uploadedParts(log) == Array(1...10))
    #expect(await store.object("big.bin")?.data == data)

    await store.failPart(3)
    try patternData(176).write(to: file)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "k", overwrite: true
      ) { _ in }
    }
    await store.forgetUploads()
    try patternData(192).write(to: file)
    _ = try await uploader.upload(file: file, key: "big.bin", journalID: "k", overwrite: true) {
      _ in
    }
    #expect(await store.object("big.bin")?.data == patternData(192))
  }

  @Test("Create-only multipart refuses an existing object before sending anything")
  func existingBeforeStart() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let store = FakeMountStore()
    await store.seed("big.bin", data: Data("other".utf8))
    await #expect(throws: MountError.alreadyExists) {
      _ = try await tinyUploader(store, workspace).upload(
        file: try workspace.file(patternData(160)), key: "big.bin", journalID: "j",
        overwrite: false
      ) { _ in }
    }
    #expect(await store.log() == ["head big.bin"])
    #expect(workspace.journals().isEmpty)
  }

  @Test("An identical multipart object already at the key is the result without resending")
  func identicalBeforeStart() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let file = try workspace.file(data)
    let store = FakeMountStore()
    _ = try await tinyUploader(store, workspace).upload(
      file: file, key: "big.bin", journalID: "first", overwrite: false
    ) { _ in }
    await store.clearLog()
    let result = try await tinyUploader(store, workspace).upload(
      file: file, key: "big.bin", journalID: "second", overwrite: false
    ) { _ in }
    #expect(result == UploadedObject(eTag: expectedETag(data), size: 160))
    #expect(await store.log() == ["head big.bin"])
  }

  @Test("A file that shrank below the threshold drops its multipart upload")
  func shrankBelowThreshold() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(patternData(160))
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "a.bin", journalID: "j", overwrite: true
      ) { _ in }
    }
    try patternData(8).write(to: file)
    await store.clearLog()
    _ = try await uploader.upload(file: file, key: "a.bin", journalID: "j", overwrite: true) {
      _ in
    }
    #expect(await store.log() == ["abort upload-1", "put a.bin"])
    #expect(await store.object("a.bin")?.data == patternData(8))
    #expect(workspace.journals().isEmpty)
  }

  @Test("An empty file is a single empty PUT")
  func emptyFile() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let store = FakeMountStore()
    let result = try await tinyUploader(store, workspace).upload(
      file: try workspace.file(Data()), key: "empty", journalID: "j", overwrite: false
    ) { _ in }
    #expect(result == UploadedObject(eTag: "\"d41d8cd98f00b204e9800998ecf8427e\"", size: 0))
    #expect(await store.object("empty")?.data == Data())
  }

  @Test("A conflict at completion aborts the upload and removes the journal")
  func conflictAtCompletion() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(patternData(160))
    let store = FakeMountStore()
    await store.failPart(3)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: false
      ) { _ in }
    }
    await store.seed("big.bin", data: Data("other".utf8))
    await #expect(throws: MountError.alreadyExists) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: false
      ) { _ in }
    }
    #expect(await store.log().contains("abort upload-1"))
    #expect(await store.uploadIDs().isEmpty)
    #expect(await store.object("big.bin")?.data == Data("other".utf8))
    #expect(workspace.journals().isEmpty)
  }

  @Test("A completion refused because the same bytes landed first returns that object")
  func identicalAtCompletion() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let store = FakeMountStore()
    await store.raceCompletion()
    let result = try await tinyUploader(store, workspace).upload(
      file: try workspace.file(data), key: "big.bin", journalID: "j", overwrite: false
    ) { _ in }
    #expect(result == UploadedObject(eTag: expectedETag(data), size: 160))
    #expect(await store.log().contains("abort upload-1"))
    #expect(await store.uploadIDs().isEmpty)
    #expect(workspace.journals().isEmpty)
  }

  @Test("A completion conflict aborts the upload even while the call is being cancelled")
  func cancelledConflictAborts() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let store = FakeMountStore()
    await store.raceCompletion(with: Data("other".utf8))
    await store.cancelAtCompletion()
    await #expect(throws: (any Error).self) {
      _ = try await tinyUploader(store, workspace).upload(
        file: try workspace.file(patternData(160)), key: "big.bin", journalID: "j",
        overwrite: false
      ) { _ in }
    }
    #expect(await store.log().contains("abort upload-1"))
    #expect(await store.uploadIDs().isEmpty)
    #expect(await store.object("big.bin")?.data == Data("other".utf8))
  }

  @Test("A create-only PUT conflict with different bytes is alreadyExists")
  func singlePutConflict() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let store = FakeMountStore()
    await store.seed("a.txt", data: Data("other".utf8))
    await #expect(throws: MountError.alreadyExists) {
      _ = try await tinyUploader(store, workspace).upload(
        file: try workspace.file(Data("mine".utf8)), key: "a.txt", journalID: "j",
        overwrite: false
      ) { _ in }
    }
    #expect(await store.object("a.txt")?.data == Data("other".utf8))
  }

  @Test("A create-only PUT whose identical bytes are already there succeeds")
  func singlePutReplay() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = Data("mine".utf8)
    let store = FakeMountStore()
    await store.seed("a.txt", data: data)
    let result = try await tinyUploader(store, workspace).upload(
      file: try workspace.file(data), key: "a.txt", journalID: "j", overwrite: false
    ) { _ in }
    #expect(result == UploadedObject(eTag: "\"\(md5Hex(data))\"", size: 4))
  }

  @Test("A lost completion response is recognised from the journal on retry")
  func lostCompletion() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let file = try workspace.file(data)
    let store = FakeMountStore()
    await store.loseCompletionResponse()
    let uploader = tinyUploader(store, workspace)
    await #expect(throws: URLError.self) {
      _ = try await uploader.upload(
        file: file, key: "big.bin", journalID: "j", overwrite: false
      ) { _ in }
    }
    #expect(workspace.journals().count == 1)
    await store.clearLog()
    let progress = ProgressLog<Int64>()
    let result = try await uploader.upload(
      file: file, key: "big.bin", journalID: "j", overwrite: false, progress: progress.record)
    #expect(result == UploadedObject(eTag: expectedETag(data), size: 160))
    #expect(await store.log() == ["listParts upload-1", "head big.bin"])
    #expect(progress.values.last == 160)
    #expect(workspace.journals().isEmpty)
  }

  @Test("Overwriting completes over an existing object without a condition")
  func overwriteMultipart() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let store = FakeMountStore()
    await store.seed("big.bin", data: Data("old".utf8))
    _ = try await tinyUploader(store, workspace).upload(
      file: try workspace.file(data), key: "big.bin", journalID: "j", overwrite: true
    ) { _ in }
    #expect(await store.object("big.bin")?.data == data)
    #expect(await store.overwriteFlags == [true])
    #expect(await !store.log().contains("head big.bin"))
  }

  @Test("Cancellation keeps the journal so the next call resumes")
  func cancellationKeepsJournal() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let data = patternData(160)
    let file = try workspace.file(data)
    let store = FakeMountStore()
    await store.delayPart(2, by: .seconds(30))
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    let task = Task {
      try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
        _ in
      }
    }
    for _ in 0..<500 where await !store.log().contains("uploadPart 2") {
      try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(workspace.journals().count == 1)
    #expect(await store.uploadIDs() == ["upload-1"])
    await store.clearLog()
    _ = try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
      _ in
    }
    #expect(uploadedParts(await store.log()) == Array(2...10))
    #expect(await store.object("big.bin")?.data == data)
  }

  @Test("Calls for the same journal run one after another")
  func sameJournalIsSerialized() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(patternData(160))
    let store = FakeMountStore()
    await store.delayPart(1, by: .milliseconds(100))
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    async let first = uploader.upload(
      file: file, key: "big.bin", journalID: "j", overwrite: true
    ) { _ in }
    async let second = uploader.upload(
      file: file, key: "big.bin", journalID: "j", overwrite: true
    ) { _ in }
    _ = try await (first, second)
    let log = await store.log()
    let creations = log.indices.filter { log[$0].hasPrefix("createMultipart") }
    let completions = log.indices.filter { log[$0].hasPrefix("complete") }
    #expect(creations.count == 2)
    #expect(completions.count == 2)
    #expect(completions[0] < creations[1])
  }

  @Test("A cancelled call waiting on the same journal returns without waiting for the first")
  func cancelledWaiter() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(patternData(160))
    let store = FakeMountStore()
    await store.holdPart(1)
    let uploader = tinyUploader(store, workspace, concurrency: 1)
    let first = Task {
      try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
        _ in
      }
    }
    for _ in 0..<500 where await store.heldCount() == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    let second = Task {
      try await uploader.upload(file: file, key: "big.bin", journalID: "j", overwrite: true) {
        _ in
      }
    }
    for _ in 0..<500 where await uploader.waitingCount("j") == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    // Without prompt cancellation the second call only returns after this release.
    let watchdog = Task {
      try await Task.sleep(for: .seconds(5))
      await store.releaseHeldParts()
    }
    second.cancel()
    await #expect(throws: CancellationError.self) { _ = try await second.value }
    #expect(await store.heldCount() == 1)
    #expect(await uploader.waitingCount("j") == 0)
    watchdog.cancel()
    await store.releaseHeldParts()
    _ = try await first.value
    #expect(await store.log().filter { $0.hasPrefix("createMultipart") }.count == 1)
  }
}
