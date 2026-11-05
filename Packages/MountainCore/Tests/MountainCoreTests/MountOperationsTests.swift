import Foundation
import Testing

@testable import MountainCore

@Suite("Folder creation, moves and deletes")
struct MountOperationsTests {
  @Test("createFolder PUTs a create-only marker and accepts an existing one")
  func createFolder() async throws {
    let transport = RecordingS3Transport([
      s3Response(headers: ["ETag": "\"d41d8cd98f00b204e9800998ecf8427e\""]),
      s3Response(412, xml: "<Error><Code>PreconditionFailed</Code></Error>"),
    ])
    let operations = MountOperations(store: makeS3Client(transport))
    try await operations.createFolder(key: "写真/Cafe\u{301}/")
    try await operations.createFolder(key: "写真/Cafe\u{301}/")
    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests[0].method == "PUT")
    #expect(requests[0].url.absoluteString.hasSuffix("/drive/%E5%86%99%E7%9C%9F/Cafe%CC%81/"))
    #expect(requests[0].headers["if-none-match"] == "*")
    #expect(requests[0].headers["content-length"] == "0")
  }

  @Test("createFolder rejects keys that are not one folder marker")
  func createFolderValidation() async throws {
    let store = FakeMountStore()
    let operations = MountOperations(store: store)
    for key in ["", "/", "a", "a//", "/a/", "a/./", "a\u{1}/"] {
      await #expect(throws: MountError.invalidName) { try await operations.createFolder(key: key) }
    }
    #expect(await store.log().isEmpty)
  }

  @Test("Files up to 5 GiB move with one CopyObject and then delete the source")
  func moveSmallObject() async throws {
    let store = FakeMountStore()
    await store.seed("a/x.mov", size: 5 * gibibyte, eTag: "\"src\"")
    let eTag = try await MountOperations(store: store).moveObject(
      from: "a/x.mov", to: "b/y.mov", size: 5 * gibibyte)
    #expect(eTag == "\"src\"")
    #expect(
      await store.log() == ["head a/x.mov", "copy a/x.mov -> b/y.mov", "delete a/x.mov"])
    #expect(await store.keys() == ["b/y.mov"])
  }

  @Test("Files over 5 GiB move with 1 GiB UploadPartCopy parts")
  func moveLargeObject() async throws {
    let store = FakeMountStore()
    let size = 5 * gibibyte + 10
    await store.seed("a/big.mov", size: size)
    let eTag = try await MountOperations(store: store).moveObject(
      from: "a/big.mov", to: "b/big.mov", size: size)
    #expect(eTag == "\"copy-6\"")
    let log = await store.log()
    #expect(Array(log.prefix(2)) == ["head a/big.mov", "createMultipart b/big.mov"])
    let copies = log.filter { $0.hasPrefix("partCopy") }.sorted()
    #expect(
      copies == (0..<5).map {
        "partCopy \($0 + 1) \(Int64($0) * gibibyte)-\(Int64($0 + 1) * gibibyte - 1)"
      }
        + ["partCopy 6 \(5 * gibibyte)-\(size - 1)"])
    #expect(Array(log.suffix(2)) == ["complete 1,2,3,4,5,6", "delete a/big.mov"])
    #expect(await store.overwriteFlags == [true])
    #expect(await store.object("b/big.mov")?.size == size)
    #expect(await store.object("a/big.mov") == nil)
  }

  @Test("A failed part copy aborts the upload and keeps the source")
  func moveLargeObjectFailure() async throws {
    let store = FakeMountStore()
    let size = 6 * gibibyte
    await store.seed("a/big.mov", size: size)
    await store.failCopy(to: "b/big.mov")
    await #expect(throws: S3Failure(status: 500, code: "InternalError")) {
      _ = try await MountOperations(store: store).moveObject(
        from: "a/big.mov", to: "b/big.mov", size: size)
    }
    let log = await store.log()
    #expect(log.contains("abort upload-1"))
    #expect(!log.contains { $0.hasPrefix("delete") || $0.hasPrefix("complete") })
    #expect(await store.keys() == ["a/big.mov"])
    #expect(await store.uploadIDs().isEmpty)
  }

  @Test("A large file replaced during its ranged copy is neither completed nor deleted")
  func moveLargeObjectSourceReplaced() async throws {
    let store = FakeMountStore()
    await store.seed("a/big.mov", size: 6 * gibibyte, eTag: "\"v1\"")
    await store.replaceDuringPartCopy("a/big.mov", size: 7 * gibibyte, eTag: "\"v2\"")
    await #expect(throws: S3Failure(status: 412, code: "PreconditionFailed")) {
      _ = try await MountOperations(store: store).moveObject(
        from: "a/big.mov", to: "b/big.mov", size: 6 * gibibyte)
    }
    let log = await store.log()
    #expect(log.contains("abort upload-1"))
    #expect(!log.contains { $0.hasPrefix("complete") || $0.hasPrefix("delete") })
    #expect(await store.object("a/big.mov")?.eTag == "\"v2\"")
    #expect(await store.object("b/big.mov") == nil)
    #expect(await store.uploadIDs().isEmpty)
  }

  @Test("Cancelling a large move still aborts its multipart upload")
  func moveLargeObjectCancelled() async throws {
    let store = FakeMountStore()
    await store.seed("a/big.mov", size: 6 * gibibyte)
    await store.delayPartCopies(by: .seconds(30))
    let operations = MountOperations(store: store)
    let task = Task {
      try await operations.moveObject(from: "a/big.mov", to: "b/big.mov", size: 6 * gibibyte)
    }
    for _ in 0..<500 where await !store.log().contains(where: { $0.hasPrefix("partCopy") }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await store.log().contains("abort upload-1"))
    #expect(await store.uploadIDs().isEmpty)
    #expect(await store.keys() == ["a/big.mov"])
  }

  @Test("The live size decides how a file is copied")
  func moveUsesLiveSize() async throws {
    let store = FakeMountStore()
    await store.seed("a/big.mov", size: 6 * gibibyte)
    _ = try await MountOperations(store: store).moveObject(
      from: "a/big.mov", to: "b/big.mov", size: 1)
    #expect(await store.object("b/big.mov")?.size == 6 * gibibyte)
    #expect(await store.log().contains("createMultipart b/big.mov"))
  }

  @Test("A replayed move whose source is gone returns the destination ETag")
  func moveReplay() async throws {
    let store = FakeMountStore()
    await store.seed("b/y.mov", size: 3, eTag: "\"moved\"")
    let operations = MountOperations(store: store)
    #expect(try await operations.moveObject(from: "a/x.mov", to: "b/y.mov", size: 3) == "\"moved\"")
    #expect(await store.log() == ["head a/x.mov", "head b/y.mov"])
    await #expect(throws: MountError.notFound) {
      _ = try await operations.moveObject(from: "a/none", to: "b/none", size: 3)
    }
  }

  @Test("Moving a file onto itself changes nothing")
  func moveOntoItself() async throws {
    let store = FakeMountStore()
    await store.seed("a/x", size: 3, eTag: "\"same\"")
    #expect(
      try await MountOperations(store: store).moveObject(from: "a/x", to: "a/x", size: 3)
        == "\"same\"")
    #expect(await store.keys() == ["a/x"])
    #expect(await store.log() == ["head a/x"])
  }

  @Test("NFC and NFD names are different files")
  func moveBetweenNormalizations() async throws {
    let store = FakeMountStore()
    await store.seed("Caf\u{E9}", size: 1)
    _ = try await MountOperations(store: store).moveObject(
      from: "Caf\u{E9}", to: "Cafe\u{301}", size: 1)
    #expect(await store.keys() == ["Cafe\u{301}"])
  }

  @Test("File moves reject folder and empty keys")
  func moveObjectValidation() async throws {
    let store = FakeMountStore()
    let operations = MountOperations(store: store)
    for (source, destination) in [("", "b"), ("a", ""), ("a/", "b"), ("a", "b/")] {
      await #expect(throws: MountError.invalidName) {
        _ = try await operations.moveObject(from: source, to: destination, size: 1)
      }
    }
    #expect(await store.log().isEmpty)
  }

  @Test("Folder moves copy everything first, then delete sources in batches of 1000")
  func moveFolder() async throws {
    let store = FakeMountStore()
    await store.seed("src/", size: 0)
    for index in 0..<2_499 { await store.seed("src/f\(index)", size: 1) }
    await store.seed("src/sub/Cafe\u{301}", size: 2)
    await store.seed("srcx/keep", size: 1)
    await store.seed("dst/f1", size: 1)
    await store.seed("dst/f2", size: 9)
    let progress = ProgressLog<Int>()
    let totals = ProgressLog<Int>()
    try await MountOperations(store: store).moveFolder(from: "src/", to: "dst/") {
      progress.record($0)
      totals.record($1)
    }
    let log = await store.log()
    let copies = log.filter { $0.hasPrefix("copy ") }
    #expect(copies.count == 2_500)
    #expect(copies.contains("copy src/ -> dst/"))
    #expect(copies.contains("copy src/sub/Cafe\u{301} -> dst/sub/Cafe\u{301}"))
    #expect(copies.contains("copy src/f2 -> dst/f2"))
    #expect(!copies.contains("copy src/f1 -> dst/f1"))
    let lastCopy = try #require(log.lastIndex { $0.hasPrefix("copy ") })
    let firstDelete = try #require(log.firstIndex { $0.hasPrefix("deleteObjects") })
    #expect(lastCopy < firstDelete)
    #expect(
      log.filter { $0.hasPrefix("deleteObjects") } == [
        "deleteObjects 1000", "deleteObjects 1000", "deleteObjects 501",
      ])
    let keys = await store.keys()
    #expect(!keys.contains { $0.hasPrefix("src/") })
    #expect(keys.contains("srcx/keep"))
    #expect(keys.contains("dst/"))
    #expect(keys.filter { $0.hasPrefix("dst/") }.count == 2_501)
    #expect(Set(totals.values) == [2_501])
    #expect(progress.values.first == 0)
    #expect(progress.values.last == 2_501)
    #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 })
  }

  @Test("Large files inside a moved folder use multipart copies")
  func moveFolderWithLargeFile() async throws {
    let store = FakeMountStore()
    await store.seed("src/big", size: 6 * gibibyte)
    try await MountOperations(store: store).moveFolder(from: "src/", to: "dst/") { _, _ in }
    #expect(await store.object("dst/big")?.size == 6 * gibibyte)
    #expect(await store.log().contains("createMultipart dst/big"))
    #expect(await store.keys() == ["dst/big"])
  }

  @Test("A large file replaced during a folder move keeps every source")
  func moveFolderSourceReplaced() async throws {
    let store = FakeMountStore()
    await store.seed("src/big", size: 6 * gibibyte, eTag: "\"v1\"")
    await store.replaceDuringPartCopy("src/big", size: 6 * gibibyte, eTag: "\"v2\"")
    await #expect(throws: S3Failure(status: 412, code: "PreconditionFailed")) {
      try await MountOperations(store: store).moveFolder(from: "src/", to: "dst/") { _, _ in }
    }
    #expect(!(await store.log()).contains { $0.hasPrefix("complete") || $0.hasPrefix("delete") })
    #expect(await store.keys() == ["src/big"])
  }

  @Test("A same-size stranger at the destination is overwritten, not taken for the copy")
  func moveFolderSameSizeStranger() async throws {
    let store = FakeMountStore()
    await store.seed("src/notes.txt", data: Data("AAAA".utf8))
    await store.seed("dst/notes.txt", data: Data("BBBB".utf8))
    try await MountOperations(store: store).moveFolder(from: "src/", to: "dst/") { _, _ in }
    #expect(await store.object("dst/notes.txt")?.data == Data("AAAA".utf8))
    #expect(await store.keys() == ["dst/notes.txt"])
  }

  @Test("A retried folder move copies only what the first attempt missed")
  func moveFolderRetry() async throws {
    let store = FakeMountStore()
    await store.seed("src/a", data: Data("A".utf8))
    await store.seed("src/b", data: Data("B".utf8))
    await store.failCopy(to: "dst/b")
    let operations = MountOperations(store: store)
    await #expect(throws: S3Failure.self) {
      try await operations.moveFolder(from: "src/", to: "dst/") { _, _ in }
    }
    #expect(await store.object("dst/a")?.data == Data("A".utf8))
    await store.allowCopies()
    await store.clearLog()
    try await operations.moveFolder(from: "src/", to: "dst/") { _, _ in }
    #expect(await store.log().filter { $0.hasPrefix("copy ") } == ["copy src/b -> dst/b"])
    #expect(await store.keys() == ["dst/a", "dst/b"])
    #expect(await store.object("dst/b")?.data == Data("B".utf8))
  }

  @Test("A folder move whose new keys would exceed 1024 bytes copies nothing")
  func moveFolderKeyTooLong() async throws {
    let store = FakeMountStore()
    let name = "src/" + String(repeating: "n", count: 1_020)
    await store.seed("src/a", size: 1)
    await store.seed(name, size: 1)
    let operations = MountOperations(store: store)
    await #expect(throws: MountError.invalidName) {
      try await operations.moveFolder(from: "src/", to: "longer/") { _, _ in }
    }
    #expect(!(await store.log()).contains { $0.hasPrefix("copy") || $0.hasPrefix("delete") })
    try await operations.moveFolder(from: "src/", to: "dst/") { _, _ in }
    #expect(await store.keys() == ["dst/a", "dst/" + String(repeating: "n", count: 1_020)])
  }

  @Test("A replayed folder move whose sources are gone succeeds")
  func moveFolderReplay() async throws {
    let store = FakeMountStore()
    await store.seed("dst/a", size: 1)
    let operations = MountOperations(store: store)
    try await operations.moveFolder(from: "src/", to: "dst/") { _, _ in }
    #expect(!(await store.log()).contains { $0.hasPrefix("copy") || $0.hasPrefix("delete") })
    await #expect(throws: MountError.notFound) {
      try await operations.moveFolder(from: "none/", to: "other/") { _, _ in }
    }
  }

  @Test("A failed copy deletes nothing")
  func moveFolderFailure() async throws {
    let store = FakeMountStore()
    await store.seed("src/a", size: 1)
    await store.seed("src/b", size: 1)
    await store.failCopy(to: "dst/b")
    await #expect(throws: S3Failure(status: 500, code: "InternalError")) {
      try await MountOperations(store: store).moveFolder(from: "src/", to: "dst/") { _, _ in }
    }
    #expect(!(await store.log()).contains { $0.hasPrefix("delete") })
    #expect(await store.object("src/a") != nil)
    #expect(await store.object("src/b") != nil)
  }

  @Test("Folder moves reject non-folder keys and moves into themselves")
  func moveFolderValidation() async throws {
    let store = FakeMountStore()
    let operations = MountOperations(store: store)
    for (source, destination) in [
      ("", "b/"), ("a", "b/"), ("a/", "b"), ("a/", "a/"), ("a/", "a/b/"),
    ] {
      await #expect(throws: MountError.invalidName) {
        try await operations.moveFolder(from: source, to: destination) { _, _ in }
      }
    }
    #expect(await store.log().isEmpty)
  }

  @Test("deleteObject removes exactly one key")
  func deleteObject() async throws {
    let store = FakeMountStore()
    await store.seed("a/x", size: 1)
    let operations = MountOperations(store: store)
    try await operations.deleteObject(key: "a/x")
    #expect(await store.log() == ["delete a/x"])
    await #expect(throws: MountError.invalidName) { try await operations.deleteObject(key: "") }
  }

  @Test("deleteFolder removes every descendant and the marker in batches")
  func deleteFolder() async throws {
    let store = FakeMountStore()
    await store.seed("a/", size: 0)
    for index in 0..<1_200 { await store.seed("a/b/\(index)", size: 1) }
    await store.seed("ab", size: 1)
    try await MountOperations(store: store).deleteFolder(prefix: "a/")
    #expect(await store.keys() == ["ab"])
    #expect(
      await store.log() == ["listAll a/", "deleteObjects 1000", "deleteObjects 201"])
  }

  @Test("deleteFolder never lists the whole bucket")
  func deleteFolderValidation() async throws {
    let store = FakeMountStore()
    let operations = MountOperations(store: store)
    for prefix in ["", "/", "a"] {
      await #expect(throws: MountError.invalidName) {
        try await operations.deleteFolder(prefix: prefix)
      }
    }
    #expect(await store.log().isEmpty)
  }
}
