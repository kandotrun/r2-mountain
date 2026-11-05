import Foundation
import Testing

@testable import MountainCore

private let referenceDate = Date(timeIntervalSince1970: 1_793_786_400)

private func listing(
  truncated: Bool = false, token: String? = nil, contents: [(String, String, String)] = [],
  prefixes: [String] = []
) -> S3HTTPResponse {
  let files = contents.map {
    "<Contents><Key>\(S3XML.escape($0.0))</Key><LastModified>\($0.2)</LastModified>"
      + "<ETag>&quot;e&quot;</ETag><Size>\($0.1)</Size><StorageClass>STANDARD</StorageClass></Contents>"
  }.joined()
  let folders = prefixes.map {
    "<CommonPrefixes><Prefix>\(S3XML.escape($0))</Prefix></CommonPrefixes>"
  }
  .joined()
  let next = token.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
  return s3Response(
    xml:
      "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>drive</Name>"
      + "<Prefix></Prefix><Delimiter>/</Delimiter><MaxKeys>1000</MaxKeys>"
      + "<IsTruncated>\(truncated)</IsTruncated>\(next)\(files)\(folders)</ListBucketResult>")
}

@Suite struct RemoteEntryTests {
  @Test func folderEntriesExposeTheirPath() {
    let folder = RemoteEntry(key: "a/b/", name: "b", kind: .folder, size: nil, lastModified: nil)
    #expect(folder.id == "a/b/")
    #expect(folder.folderPath == FolderPath(prefix: "a/b/"))
    let file = RemoteEntry(key: "a/b", name: "b", kind: .file, size: 1, lastModified: nil)
    #expect(file.folderPath == nil)
  }

  @Test func equalityComparesKeyBytes() {
    let composed = RemoteEntry(
      key: "Caf\u{E9}/", name: "Caf\u{E9}", kind: .folder, size: nil, lastModified: nil)
    let decomposed = RemoteEntry(
      key: "Cafe\u{301}/", name: "Cafe\u{301}", kind: .folder, size: nil, lastModified: nil)
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed, composed]).count == 2)
    #expect(composed.folderPath != decomposed.folderPath)
  }

  @Test func listingSortsLikeFinder() {
    let entries = ["folder10", "Folder2", "folder1"].map {
      RemoteEntry(key: $0 + "/", name: $0, kind: .folder, size: nil, lastModified: nil)
    }
    let files = ["b10.txt", "b9.txt"].map {
      RemoteEntry(key: $0, name: $0, kind: .file, size: 0, lastModified: nil)
    }
    let value = FolderListing(path: .root, folders: entries, files: files, isTruncated: false)
    #expect(value.folders.map(\.name) == ["folder1", "Folder2", "folder10"])
    #expect(value.files.map(\.name) == ["b9.txt", "b10.txt"])
  }
}

@Suite("Folder browsing over ListObjectsV2")
struct FolderBrowsingTests {
  @Test("Root listing uses delimiter without prefix or encoding-type")
  func rootRequest() async throws {
    let transport = RecordingS3Transport([listing()])
    let result = try await makeS3Client(transport).listFolder(.root, pageLimit: 5)
    #expect(result == FolderListing(path: .root, folders: [], files: [], isTruncated: false))
    let request = try #require(await transport.requests().first)
    #expect(request.method == "GET")
    #expect(request.url.path == "/drive")
    #expect(queryItems(request) == ["list-type": "2", "delimiter": "/", "max-keys": "1000"])
    #expect(request.headers["authorization"] != nil)
  }

  @Test("Files and folders are parsed, named relative to the folder and sorted")
  func parsesEntries() async throws {
    let transport = RecordingS3Transport([
      listing(
        contents: [
          ("写真/", "0", "2026-11-04T10:00:00.000Z"),
          ("写真/file10.mov", "10", "2026-11-04T10:00:00.500Z"),
          ("写真/file2.mov", "2", "2026-11-04T10:00:00Z"),
          ("写真/ spaced & <odd>.txt ", "0", "2026-11-04T10:00:00Z"),
        ],
        prefixes: ["写真/2026/", "写真/2025/"])
    ])
    let path = try FolderPath(components: ["写真"])
    let result = try await makeS3Client(transport).listFolder(path, pageLimit: 1)
    #expect(result.path == path)
    #expect(!result.isTruncated)
    #expect(
      result.folders == [
        RemoteEntry(key: "写真/2025/", name: "2025", kind: .folder, size: nil, lastModified: nil),
        RemoteEntry(key: "写真/2026/", name: "2026", kind: .folder, size: nil, lastModified: nil),
      ])
    #expect(
      result.folders.map(\.folderPath) == [try path.appending("2025"), try path.appending("2026")])
    #expect(result.files.map(\.name) == [" spaced & <odd>.txt ", "file2.mov", "file10.mov"])
    #expect(result.files.map(\.key)[0] == "写真/ spaced & <odd>.txt ")
    #expect(result.files.map(\.size) == [0, 2, 10])
    #expect(
      result.files.map(\.lastModified) == [
        referenceDate, referenceDate, referenceDate.addingTimeInterval(0.5),
      ])
    #expect(result.files.allSatisfy { $0.kind == .file })
    let request = try #require(await transport.requests().first)
    #expect(queryItems(request)["prefix"] == "写真/")
    #expect(request.url.absoluteString.contains("prefix=%E5%86%99%E7%9C%9F%2F"))
    #expect(queryItems(request)["encoding-type"] == nil)
  }

  @Test("Entries outside the folder or not directly inside it are ignored")
  func skipsUnrelatedEntries() async throws {
    let transport = RecordingS3Transport([
      listing(
        contents: [
          ("a/", "0", "2026-11-04T10:00:00Z"),
          ("b/x.txt", "1", "2026-11-04T10:00:00Z"),
          ("a/deep/x.txt", "1", "2026-11-04T10:00:00Z"),
          ("a/ok.txt", "1", "2026-11-04T10:00:00Z"),
        ],
        prefixes: [
          "a/", "a/../", "a/./", "a/x/y/", "b/c/", "a/no-slash", "a/ok/", "a/ok/",
        ])
    ])
    let result = try await makeS3Client(transport).listFolder(
      try FolderPath(components: ["a"]), pageLimit: 1)
    #expect(result.files.map(\.key) == ["a/ok.txt"])
    #expect(result.folders.map(\.key) == ["a/ok/"])
  }

  @Test("Stored folder names stay visible and navigable byte-for-byte")
  func keepsStoredFolderNames() async throws {
    let stored = ["Project /", "テ\u{3099}ータ/", "データ/", "Cafe\u{301}/", "Caf\u{E9}/", "ok/"]
    let transport = RecordingS3Transport([listing(prefixes: stored + ["Cafe\u{301}/"])])
    let result = try await makeS3Client(transport).listFolder(.root, pageLimit: 1)
    #expect(result.folders.count == stored.count)
    #expect(Set(result.folders.map { Array($0.key.utf8) }) == Set(stored.map { Array($0.utf8) }))
    for folder in result.folders {
      let path = try #require(folder.folderPath)
      #expect(Array(path.prefix.utf8) == Array(folder.key.utf8))
      #expect(Array((folder.name + "/").utf8) == Array(folder.key.utf8))
    }
  }

  @Test("Canonically equivalent keys stay distinct entries but share a String id")
  func canonicallyEquivalentKeys() async throws {
    let transport = RecordingS3Transport([
      listing(contents: [
        ("Caf\u{E9}.txt", "1", "2026-11-04T10:00:00Z"),
        ("Cafe\u{301}.txt", "1", "2026-11-04T10:00:00Z"),
      ])
    ])
    let files = try await makeS3Client(transport).listFolder(.root, pageLimit: 1).files
    #expect(files.count == 2)
    #expect(files[0] != files[1])
    #expect(Set(files).count == 2)
    // Contract: id is the key as a Swift String, whose equality is canonical equivalence.
    #expect(files[0].id == files[1].id)
  }

  @Test("Continuation tokens are followed and duplicate folders merged")
  func followsPages() async throws {
    let transport = RecordingS3Transport([
      listing(
        truncated: true, token: "next+/=", contents: [("one.txt", "1", "2026-11-04T10:00:00Z")],
        prefixes: ["dup/"]),
      listing(contents: [("two.txt", "2", "2026-11-04T10:00:00Z")], prefixes: ["dup/", "z/"]),
    ])
    let result = try await makeS3Client(transport).listFolder(.root, pageLimit: 3)
    #expect(result.files.map(\.key) == ["one.txt", "two.txt"])
    #expect(result.folders.map(\.key) == ["dup/", "z/"])
    #expect(!result.isTruncated)
    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(queryItems(requests[0])["continuation-token"] == nil)
    #expect(queryItems(requests[1])["continuation-token"] == "next+/=")
    #expect(requests[1].url.absoluteString.contains("continuation-token=next%2B%2F%3D"))
  }

  @Test("Continuation pages inside a folder keep the prefix")
  func followsPagesInsideFolder() async throws {
    let transport = RecordingS3Transport([
      listing(truncated: true, token: "p2", contents: [("写真/a.jpg", "1", "2026-11-04T10:00:00Z")]),
      listing(contents: [("写真/b.jpg", "2", "2026-11-04T10:00:00Z")], prefixes: ["写真/2026/"]),
    ])
    let path = try FolderPath(components: ["写真"])
    let result = try await makeS3Client(transport).listFolder(path, pageLimit: 2)
    #expect(result.files.map(\.name) == ["a.jpg", "b.jpg"])
    #expect(result.folders.map(\.name) == ["2026"])
    #expect(!result.isTruncated)
    let requests = await transport.requests()
    #expect(requests.count == 2)
    let base = ["list-type": "2", "delimiter": "/", "max-keys": "1000", "prefix": "写真/"]
    #expect(queryItems(requests[0]) == base)
    #expect(queryItems(requests[1]) == base.merging(["continuation-token": "p2"]) { $1 })
  }

  @Test("Page limit stops early and reports truncation")
  func pageLimit() async throws {
    let page = listing(
      truncated: true, token: "t1", contents: [("a.txt", "1", "2026-11-04T10:00:00Z")])
    let transport = RecordingS3Transport([page, page])
    let result = try await makeS3Client(transport).listFolder(.root, pageLimit: 0)
    #expect(result.isTruncated)
    #expect(result.files.map(\.key) == ["a.txt"])
    #expect(await transport.requests().count == 1)
  }

  @Test("Broken pagination fails instead of looping or guessing")
  func invalidPagination() async throws {
    let failure = S3Failure(status: 200, code: "InvalidListPagination")
    for response in [
      listing(truncated: true),
      listing(truncated: true, token: ""),
      s3Response(xml: "<ListBucketResult><IsTruncated>maybe</IsTruncated></ListBucketResult>"),
      s3Response(xml: "<ListBucketResult></ListBucketResult>"),
    ] {
      let transport = RecordingS3Transport([response])
      await #expect(throws: failure) {
        _ = try await makeS3Client(transport).listFolder(.root, pageLimit: 3)
      }
    }
    let repeating = RecordingS3Transport([
      listing(truncated: true, token: "same"), listing(truncated: true, token: "same"),
    ])
    await #expect(throws: failure) {
      _ = try await makeS3Client(repeating).listFolder(.root, pageLimit: 5)
    }
    #expect(await repeating.requests().count == 2)
  }

  @Test("Malformed sizes and dates are rejected")
  func invalidListing() async throws {
    let failure = S3Failure(status: 200, code: "InvalidListing")
    for entry in [
      ("a.txt", "-1", "2026-11-04T10:00:00Z"), ("a.txt", "big", "2026-11-04T10:00:00Z"),
      ("a.txt", "1", "yesterday"), ("a.txt", "1", ""),
    ] {
      let transport = RecordingS3Transport([listing(contents: [entry])])
      await #expect(throws: failure) {
        _ = try await makeS3Client(transport).listFolder(.root, pageLimit: 1)
      }
    }
    let missing = RecordingS3Transport([
      s3Response(
        xml:
          "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a</Key></Contents></ListBucketResult>"
      )
    ])
    await #expect(throws: failure) {
      _ = try await makeS3Client(missing).listFolder(.root, pageLimit: 1)
    }
  }

  @Test("S3 errors surface as failures")
  func errors() async throws {
    let embedded = RecordingS3Transport([
      s3Response(xml: "<Error><Code>InternalError</Code></Error>")
    ])
    await #expect(throws: S3Failure(status: 200, code: "InternalError")) {
      _ = try await makeS3Client(embedded).listFolder(.root, pageLimit: 1)
    }
    let denied = RecordingS3Transport([
      s3Response(403, xml: "<Error><Code>AccessDenied</Code></Error>")
    ])
    await #expect(throws: S3Failure(status: 403, code: "AccessDenied")) {
      _ = try await makeS3Client(denied).listFolder(.root, pageLimit: 1)
    }
    let unexpected = RecordingS3Transport([s3Response(xml: "<ListPartsResult/>")])
    await #expect(throws: S3Failure(status: 200, code: "UnexpectedXMLResponse")) {
      _ = try await makeS3Client(unexpected).listFolder(.root, pageLimit: 1)
    }
  }

  @Test("Folders are created as create-only empty marker objects")
  func createFolder() async throws {
    let transport = RecordingS3Transport([
      s3Response(headers: ["ETag": "\"d41d8cd98f00b204e9800998ecf8427e\""])
    ])
    try await makeS3Client(transport).createFolder(try FolderPath(components: ["写真", "2026 +%"]))
    let request = try #require(await transport.requests().first)
    #expect(request.method == "PUT")
    #expect(request.url.path(percentEncoded: false) == "/drive/写真/2026 +%/")
    #expect(request.url.absoluteString.hasSuffix("/drive/%E5%86%99%E7%9C%9F/2026%20%2B%25/"))
    #expect(request.url.query == nil)
    #expect(request.headers["content-type"] == "application/x-directory")
    #expect(request.headers["content-md5"] == "1B2M2Y8AsgTpgAmY7PhCfg==")
    #expect(request.headers["if-none-match"] == "*")
    #expect(request.headers["content-length"] == "0")
    #expect(request.headers["authorization"]?.contains("if-none-match") == true)
    guard case .data(let body) = request.body else {
      Issue.record("Expected an empty data body")
      return
    }
    #expect(body.isEmpty)
  }

  @Test("An existing folder marker counts as success")
  func createExistingFolder() async throws {
    let transport = RecordingS3Transport([
      s3Response(412, xml: "<Error><Code>PreconditionFailed</Code></Error>")
    ])
    try await makeS3Client(transport).createFolder(try FolderPath(components: ["a"]))
    #expect(await transport.requests().count == 1)
  }

  @Test("Other folder creation failures propagate and root is rejected locally")
  func createFolderFailures() async throws {
    let transport = RecordingS3Transport([
      s3Response(403, xml: "<Error><Code>AccessDenied</Code></Error>")
    ])
    await #expect(throws: S3Failure(status: 403, code: "AccessDenied")) {
      try await makeS3Client(transport).createFolder(try FolderPath(components: ["a"]))
    }
    let untouched = RecordingS3Transport([])
    await #expect(throws: S3Failure(status: 0, code: "InvalidFolder")) {
      try await makeS3Client(untouched).createFolder(.root)
    }
    #expect(await untouched.requests().isEmpty)
  }

  @Test func clientConformsToBrowsingProtocol() {
    let browser: any S3FolderBrowsing = makeS3Client(RecordingS3Transport([]))
    #expect(browser is S3Client)
  }
}
