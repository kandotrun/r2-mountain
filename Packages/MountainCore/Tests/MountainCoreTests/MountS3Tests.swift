import Foundation
import Testing

@testable import MountainCore

private func listAllPage(
  truncated: Bool = false, token: String? = nil, contents: [(String, Int64)]
) -> S3HTTPResponse {
  let entries = contents.map {
    "<Contents><Key>\(S3XML.escape($0.0))</Key><LastModified>2026-11-05T00:00:00.000Z</LastModified>"
      + "<ETag>&quot;e&quot;</ETag><Size>\($0.1)</Size></Contents>"
  }.joined()
  let next = token.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
  return s3Response(
    xml:
      "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>drive</Name>"
      + "<IsTruncated>\(truncated)</IsTruncated>\(next)\(entries)</ListBucketResult>")
}

private func signedHeaders(_ request: S3HTTPRequest) -> [String] {
  guard let authorization = request.headers["authorization"],
    let range = authorization.range(of: "SignedHeaders=")
  else { return [] }
  let rest = authorization[range.upperBound...]
  return rest.prefix { $0 != "," }.split(separator: ";").map(String.init)
}

@Suite("S3 mount operations over the signed client")
struct MountS3Tests {
  @Test("Download streams a GET body into the file and returns its size and ETag")
  func download() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let body = patternData(300)
    let transport = RecordingS3Transport([
      S3HTTPResponse(
        status: 200,
        headers: [
          "Content-Length": "300", "ETag": "\"abc\"", "X-Amz-Meta-S3-Mountain-Job-ID": "job-1",
        ], body: body)
    ])
    let destination = workspace.root.appendingPathComponent("download.bin")
    let progress = ProgressLog<Int64>()
    let metadata = try await makeS3Client(transport).download(
      key: "写真/a b+.jpg", to: destination, progress: progress.record)
    #expect(metadata == S3ObjectMetadata(size: 300, eTag: "\"abc\"", jobID: "job-1"))
    #expect(try Data(contentsOf: destination) == body)
    #expect(progress.values.last == 300)
    let request = try #require(await transport.requests().first)
    #expect(request.method == "GET")
    #expect(request.url.path(percentEncoded: true) == "/drive/%E5%86%99%E7%9C%9F/a%20b%2B.jpg")
    #expect(request.headers["content-length"] == nil)
    #expect(request.headers["authorization"] != nil)
  }

  @Test("A missing download is notFound and leaves no file")
  func downloadMissing() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let transport = RecordingS3Transport([
      s3Response(404, xml: "<Error><Code>NoSuchKey</Code></Error>")
    ])
    let destination = workspace.root.appendingPathComponent("missing.bin")
    await #expect(throws: MountError.notFound) {
      _ = try await makeS3Client(transport).download(key: "x", to: destination) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("Download errors still decode the S3 XML code")
  func downloadForbidden() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let transport = RecordingS3Transport([
      s3Response(403, xml: "<Error><Code>AccessDenied</Code></Error>")
    ])
    let destination = workspace.root.appendingPathComponent("denied.bin")
    await #expect(throws: S3Failure(status: 403, code: "AccessDenied")) {
      _ = try await makeS3Client(transport).download(key: "x", to: destination) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("A body shorter than Content-Length is rejected")
  func truncatedDownload() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let transport = RecordingS3Transport([
      S3HTTPResponse(
        status: 200, headers: ["Content-Length": "10", "ETag": "\"e\""], body: Data("abc".utf8))
    ])
    let destination = workspace.root.appendingPathComponent("short.bin")
    await #expect(throws: S3Failure(status: 200, code: "IncompleteDownload")) {
      _ = try await makeS3Client(transport).download(key: "x", to: destination) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("Downloads ask for the stored bytes and check their length")
  func downloadStoredBytes() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let transport = RecordingS3Transport([
      S3HTTPResponse(
        status: 200,
        headers: ["Content-Length": "10", "Content-Encoding": "identity", "ETag": "\"e\""],
        body: Data("abc".utf8)),
      S3HTTPResponse(
        status: 200,
        headers: ["Content-Length": "10", "Content-Encoding": "gzip", "ETag": "\"e\""],
        body: Data("decoded".utf8)),
    ])
    let client = makeS3Client(transport)
    let destination = workspace.root.appendingPathComponent("stored.bin")
    await #expect(throws: S3Failure(status: 200, code: "IncompleteDownload")) {
      _ = try await client.download(key: "x.tar.gz", to: destination) { _ in }
    }
    // A server that ignores the override still sent the encoded length; the bytes on disk count.
    let decoded = try await client.download(key: "x.tar.gz", to: destination) { _ in }
    #expect(decoded.size == 7)
    let requests = await transport.requests()
    #expect(requests.allSatisfy { queryItems($0) == ["response-content-encoding": "identity"] })
  }

  @Test("Create-only PUT sends If-None-Match and maps 412 to alreadyExists")
  func createOnlyPut() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(Data("abc".utf8))
    let transport = RecordingS3Transport([
      s3Response(headers: ["ETag": "\"900150983cd24fb0d6963f7d28e17f72\""]),
      s3Response(412, xml: "<Error><Code>PreconditionFailed</Code></Error>"),
    ])
    let client = makeS3Client(transport)
    let eTag = try await client.put(
      key: "a/b.txt", file: file, size: 3, contentMD5: "kAFQmDzST7DWlj99KOF/cg==",
      overwrite: false)
    #expect(eTag == "\"900150983cd24fb0d6963f7d28e17f72\"")
    await #expect(throws: MountError.alreadyExists) {
      _ = try await client.put(
        key: "a/b.txt", file: file, size: 3, contentMD5: "kAFQmDzST7DWlj99KOF/cg==",
        overwrite: false)
    }
    let request = try #require(await transport.requests().first)
    #expect(request.method == "PUT")
    #expect(request.headers["if-none-match"] == "*")
    #expect(request.headers["content-md5"] == "kAFQmDzST7DWlj99KOF/cg==")
    #expect(request.headers["content-length"] == "3")
    #expect(request.headers["x-amz-meta-s3-mountain-job-id"] == nil)
    #expect(signedHeaders(request).contains("if-none-match"))
  }

  @Test("Overwriting PUT sends no condition")
  func overwritePut() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(Data("abc".utf8))
    let transport = RecordingS3Transport([s3Response(headers: ["ETag": "\"e\""])])
    _ = try await makeS3Client(transport).put(
      key: "a.txt", file: file, size: 3, contentMD5: "kAFQmDzST7DWlj99KOF/cg==", overwrite: true)
    let request = try #require(await transport.requests().first)
    #expect(request.headers["if-none-match"] == nil)
    #expect(request.headers["if-match"] == nil)
  }

  @Test("A 409 on a create-only write is alreadyExists; an overwrite keeps the failure")
  func createOnlyConflict() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let file = try workspace.file(Data("abc".utf8))
    let conflict = s3Response(409, xml: "<Error><Code>ConditionalRequestConflict</Code></Error>")
    let transport = RecordingS3Transport([conflict, conflict, conflict])
    let client = makeS3Client(transport)
    let md5 = "kAFQmDzST7DWlj99KOF/cg=="
    let parts = [S3CompletedPart(number: 1, size: 3, eTag: "\"a\"", md5Hex: "a")]
    await #expect(throws: MountError.alreadyExists) {
      _ = try await client.put(key: "a", file: file, size: 3, contentMD5: md5, overwrite: false)
    }
    await #expect(throws: MountError.alreadyExists) {
      _ = try await client.completeMultipart(
        key: "a", uploadID: "u", parts: parts, overwrite: false)
    }
    await #expect(throws: S3Failure(status: 409, code: "ConditionalRequestConflict")) {
      _ = try await client.put(key: "a", file: file, size: 3, contentMD5: md5, overwrite: true)
    }
  }

  @Test("Multipart creation without a job carries no application metadata")
  func createMultipartWithoutJob() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>"
      )
    ])
    #expect(try await makeS3Client(transport).createMultipart(key: "big.bin") == "u-1")
    let request = try #require(await transport.requests().first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString.hasSuffix("/drive/big.bin?uploads="))
    #expect(request.headers["x-amz-meta-s3-mountain-job-id"] == nil)
    #expect(request.headers["content-length"] == "0")
  }

  @Test("Completion is create-only unless overwriting, and 412 is alreadyExists")
  func completeConditions() async throws {
    let done =
      "<CompleteMultipartUploadResult><ETag>&quot;d-1&quot;</ETag></CompleteMultipartUploadResult>"
    let transport = RecordingS3Transport([
      s3Response(xml: done), s3Response(xml: done),
      s3Response(412, xml: "<Error><Code>PreconditionFailed</Code></Error>"),
    ])
    let client = makeS3Client(transport)
    let parts = [
      S3CompletedPart(number: 2, size: 1, eTag: "\"b\"", md5Hex: "b"),
      S3CompletedPart(number: 1, size: 3, eTag: "\"a\"", md5Hex: "a"),
    ]
    #expect(
      try await client.completeMultipart(
        key: "x", uploadID: "u", parts: parts, overwrite: false) == "\"d-1\"")
    _ = try await client.completeMultipart(key: "x", uploadID: "u", parts: parts, overwrite: true)
    await #expect(throws: MountError.alreadyExists) {
      _ = try await client.completeMultipart(
        key: "x", uploadID: "u", parts: parts, overwrite: false)
    }
    let requests = await transport.requests()
    #expect(requests[0].headers["if-none-match"] == "*")
    #expect(requests[1].headers["if-none-match"] == nil)
    #expect(queryItems(requests[1]) == ["uploadId": "u"])
    let body = String(decoding: try #require(requestBody(requests[1])), as: UTF8.self)
    #expect(
      body
        == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>&quot;a&quot;</ETag></Part>"
        + "<Part><PartNumber>2</PartNumber><ETag>&quot;b&quot;</ETag></Part></CompleteMultipartUpload>"
    )
  }

  @Test("CopyObject encodes the source per segment and returns the XML ETag")
  func copyObject() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<CopyObjectResult><LastModified>2026-11-05T00:00:00.000Z</LastModified><ETag>&quot;c1&quot;</ETag></CopyObjectResult>"
      )
    ])
    let source = "写真/a b+%&?.jpg"
    let eTag = try await makeS3Client(transport).copyObject(from: source, to: "新/a b.jpg")
    #expect(eTag == "\"c1\"")
    let request = try #require(await transport.requests().first)
    #expect(request.method == "PUT")
    #expect(request.url.absoluteString.hasSuffix("/drive/%E6%96%B0/a%20b.jpg"))
    #expect(
      request.headers["x-amz-copy-source"]
        == "/drive/%E5%86%99%E7%9C%9F/a%20b%2B%25%26%3F.jpg")
    #expect(request.headers["content-length"] == "0")
    #expect(request.headers["if-none-match"] == nil)
    #expect(signedHeaders(request).contains("x-amz-copy-source"))
  }

  @Test("A copy that reports an error inside a 200 response fails")
  func copyEmbeddedError() async throws {
    let transport = RecordingS3Transport([
      s3Response(xml: "<Error><Code>InternalError</Code></Error>")
    ])
    await #expect(throws: S3Failure(status: 200, code: "InternalError")) {
      _ = try await makeS3Client(transport).copyObject(from: "a", to: "b")
    }
  }

  @Test("UploadPartCopy sends the source and an inclusive byte range")
  func uploadPartCopy() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<CopyPartResult><LastModified>2026-11-05T00:00:00.000Z</LastModified><ETag>&quot;p2&quot;</ETag></CopyPartResult>"
      )
    ])
    let eTag = try await makeS3Client(transport).uploadPartCopy(
      key: "dest/big.mov", uploadID: "u+1", number: 2, source: "src/big 1.mov",
      range: gibibyte...(2 * gibibyte - 1))
    #expect(eTag == "\"p2\"")
    let request = try #require(await transport.requests().first)
    #expect(request.method == "PUT")
    #expect(queryItems(request) == ["partNumber": "2", "uploadId": "u+1"])
    #expect(request.headers["x-amz-copy-source"] == "/drive/src/big%201.mov")
    #expect(request.headers["x-amz-copy-source-range"] == "bytes=1073741824-2147483647")
    #expect(signedHeaders(request).contains("x-amz-copy-source-range"))
  }

  @Test("DeleteObject treats 204 and 404 as success")
  func deleteObject() async throws {
    let transport = RecordingS3Transport([
      s3Response(204), s3Response(404, xml: "<Error><Code>NoSuchKey</Code></Error>"),
      s3Response(403, xml: "<Error><Code>AccessDenied</Code></Error>"),
    ])
    let client = makeS3Client(transport)
    try await client.deleteObject(key: "a/b.txt")
    try await client.deleteObject(key: "a/b.txt")
    await #expect(throws: S3Failure(status: 403, code: "AccessDenied")) {
      try await client.deleteObject(key: "a/b.txt")
    }
    let request = try #require(await transport.requests().first)
    #expect(request.method == "DELETE")
    #expect(request.url.absoluteString.hasSuffix("/drive/a/b.txt"))
  }

  @Test("Empty keys never address the bucket itself")
  func emptyKeysRejected() async throws {
    let transport = RecordingS3Transport([])
    let client = makeS3Client(transport)
    await #expect(throws: MountError.invalidName) { try await client.deleteObject(key: "") }
    await #expect(throws: MountError.invalidName) {
      _ = try await client.copyObject(from: "", to: "b")
    }
    await #expect(throws: MountError.invalidName) {
      _ = try await client.copyObject(from: "a", to: "")
    }
    #expect(await transport.requests().isEmpty)
  }

  @Test("DeleteObjects posts quiet escaped XML with Content-MD5")
  func deleteObjects() async throws {
    let transport = RecordingS3Transport([
      s3Response(xml: "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>")
    ])
    try await makeS3Client(transport).deleteObjects(keys: ["a/", "a/<&>.txt", "a/x\ry"])
    let request = try #require(await transport.requests().first)
    #expect(request.method == "POST")
    #expect(request.url.path == "/drive")
    #expect(request.url.query == "delete=")
    let body = try #require(requestBody(request))
    #expect(
      String(decoding: body, as: UTF8.self)
        == "<Delete><Quiet>true</Quiet><Object><Key>a/</Key></Object>"
        + "<Object><Key>a/&lt;&amp;&gt;.txt</Key></Object>"
        + "<Object><Key>a/x&#13;y</Key></Object></Delete>")
    #expect(request.headers["content-md5"] == contentMD5(body))
    #expect(request.headers["content-type"] == "application/xml")
    #expect(request.headers["content-length"] == String(body.count))
    #expect(signedHeaders(request).contains("content-md5"))
  }

  @Test("DeleteObjects rejects empty and oversized batches before sending")
  func deleteObjectsLimits() async throws {
    let transport = RecordingS3Transport([])
    let client = makeS3Client(transport)
    await #expect(throws: S3Failure(status: 0, code: "InvalidDeleteBatch")) {
      try await client.deleteObjects(keys: [])
    }
    await #expect(throws: S3Failure(status: 0, code: "InvalidDeleteBatch")) {
      try await client.deleteObjects(keys: (0...1_000).map { "k\($0)" })
    }
    await #expect(throws: MountError.invalidName) {
      try await client.deleteObjects(keys: ["a", ""])
    }
    #expect(await transport.requests().isEmpty)
  }

  @Test("DeleteObjects accepts exactly 1000 keys")
  func deleteObjectsMaximum() async throws {
    let transport = RecordingS3Transport([s3Response(xml: "<DeleteResult/>")])
    try await makeS3Client(transport).deleteObjects(keys: (0..<1_000).map { "k\($0)" })
    let request = try #require(await transport.requests().first)
    let body = try #require(requestBody(request))
    #expect(
      String(decoding: body, as: UTF8.self).components(separatedBy: "<Object>").count == 1_001)
  }

  @Test("Per-key errors in DeleteResult fail the batch")
  func deleteObjectsErrors() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<DeleteResult><Deleted><Key>a</Key></Deleted><Error><Key>b</Key><Code>AccessDenied</Code>"
          + "<Message>no</Message></Error></DeleteResult>")
    ])
    await #expect(throws: S3Failure(status: 200, code: "AccessDenied")) {
      try await makeS3Client(transport).deleteObjects(keys: ["a", "b"])
    }
  }

  @Test("listAll lists without a delimiter and follows every continuation token")
  func listAllPagination() async throws {
    let transport = RecordingS3Transport([
      listAllPage(truncated: true, token: "t+1", contents: [("p/", 0), ("p/a/b.txt", 5)]),
      listAllPage(truncated: true, token: "t2", contents: [("p/a/b.txt", 5), ("p/c", 7)]),
      listAllPage(contents: [("p/Cafe\u{301}", 1), ("p/Caf\u{E9}", 2)]),
    ])
    let objects = try await makeS3Client(transport).listAll(prefix: "p/")
    #expect(
      objects == [
        S3ListedObject(key: "p/", size: 0), S3ListedObject(key: "p/a/b.txt", size: 5),
        S3ListedObject(key: "p/c", size: 7), S3ListedObject(key: "p/Cafe\u{301}", size: 1),
        S3ListedObject(key: "p/Caf\u{E9}", size: 2),
      ])
    let requests = await transport.requests()
    #expect(requests.count == 3)
    #expect(queryItems(requests[0]) == ["list-type": "2", "prefix": "p/", "max-keys": "1000"])
    #expect(queryItems(requests[1])["continuation-token"] == "t+1")
    #expect(queryItems(requests[2])["continuation-token"] == "t2")
    #expect(requests.allSatisfy { queryItems($0)["delimiter"] == nil })
  }

  @Test("listAll of the whole bucket sends no prefix")
  func listAllRoot() async throws {
    let transport = RecordingS3Transport([listAllPage(contents: [("a", 1)])])
    #expect(
      try await makeS3Client(transport).listAll(prefix: "") == [S3ListedObject(key: "a", size: 1)])
    let request = try #require(await transport.requests().first)
    #expect(queryItems(request) == ["list-type": "2", "max-keys": "1000"])
  }

  @Test("listAll rejects keys outside the prefix and repeated tokens")
  func listAllValidation() async throws {
    let outside = RecordingS3Transport([listAllPage(contents: [("q/a", 1)])])
    await #expect(throws: S3Failure(status: 200, code: "InvalidListing")) {
      _ = try await makeS3Client(outside).listAll(prefix: "p/")
    }
    let looping = RecordingS3Transport([
      listAllPage(truncated: true, token: "t", contents: [("p/a", 1)]),
      listAllPage(truncated: true, token: "t", contents: [("p/b", 1)]),
    ])
    await #expect(throws: S3Failure(status: 200, code: "InvalidListPagination")) {
      _ = try await makeS3Client(looping).listAll(prefix: "p/")
    }
  }
}

@Suite("URLSession transport downloads")
struct URLSessionDownloadTests {
  private let transport = URLSessionS3Transport(configuration: StubURLProtocol.configuration())

  private func client() -> S3Client {
    S3Client(
      configuration: R2Configuration(accountID: String(repeating: "a", count: 32), bucket: "drive"),
      credentials: S3Credentials(accessKeyID: "test-access", secretAccessKey: "test-secret"),
      transport: transport)
  }

  @Test("A 2xx body streams into the file with rising progress")
  func streamsBody() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let chunks = (0..<4).map { patternData(65_536, seed: $0) }
    let url = StubURLProtocol.register(
      .init(headers: ["Content-Length": "262144", "ETag": "\"e\""], chunks: chunks))
    let destination = workspace.root.appendingPathComponent("body.bin")
    try Data("stale".utf8).write(to: destination)
    let progress = ProgressLog<Int64>()
    let response = try await transport.download(
      S3HTTPRequest(url: url, method: "GET", headers: [:]), to: destination,
      progress: progress.record)
    #expect(response.status == 200)
    #expect(response.headers["etag"] == "\"e\"")
    #expect(response.body.isEmpty)
    #expect(try Data(contentsOf: destination) == chunks.reduce(Data(), +))
    #expect(!progress.values.isEmpty)
    #expect(isMonotonic(progress.values))
    #expect(progress.values.last == 262_144)
  }

  @Test("The signed client downloads through URLSession and checks the length")
  func clientDownload() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let key = UUID().uuidString
    let body = patternData(1_000)
    StubURLProtocol.register(
      .init(headers: ["Content-Length": "1000", "ETag": "\"abc\""], chunks: [body]),
      path: "/drive/" + key)
    let destination = workspace.root.appendingPathComponent("client.bin")
    let metadata = try await client().download(key: key, to: destination) { _ in }
    #expect(metadata == S3ObjectMetadata(size: 1_000, eTag: "\"abc\""))
    #expect(try Data(contentsOf: destination) == body)
  }

  @Test("An error status keeps its XML body for decoding and writes no file")
  func errorBody() async throws {
    let workspace = try MountWorkspace()
    defer { workspace.remove() }
    let denied = UUID().uuidString
    let missing = UUID().uuidString
    StubURLProtocol.register(
      .init(status: 403, chunks: [Data("<Error><Code>AccessDenied</Code></Error>".utf8)]),
      path: "/drive/" + denied)
    StubURLProtocol.register(
      .init(status: 404, chunks: [Data("<Error><Code>NoSuchKey</Code></Error>".utf8)]),
      path: "/drive/" + missing)
    let destination = workspace.root.appendingPathComponent("denied.bin")
    await #expect(throws: S3Failure(status: 403, code: "AccessDenied")) {
      _ = try await client().download(key: denied, to: destination) { _ in }
    }
    await #expect(throws: MountError.notFound) {
      _ = try await client().download(key: missing, to: destination) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("Whole-object downloads are not bound by the per-part resource timeout")
  func downloadTimeouts() {
    let transport = URLSessionS3Transport()
    #expect(transport.downloadConfiguration.timeoutIntervalForResource >= 7 * 86_400)
    #expect(transport.downloadConfiguration.timeoutIntervalForRequest == 120)
    #expect(transport.requestConfiguration.timeoutIntervalForResource == 7_200)
    #expect(transport.requestConfiguration.timeoutIntervalForRequest == 120)
  }
}
