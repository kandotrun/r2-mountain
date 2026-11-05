import CryptoKit
import Foundation

extension S3Client: S3MountStore {
  public func download(
    key: String, to file: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> S3ObjectMetadata {
    try validate(key: key)
    let response: S3HTTPResponse
    do {
      // URLSession decodes any Content-Encoding, so ask for the bytes as stored.
      response = try await perform(
        method: "GET", key: key, query: [("response-content-encoding", "identity")],
        download: (file, progress))
    } catch let failure as S3Failure where failure.status == 404 {
      throw MountError.notFound
    }
    do {
      let written = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
      guard let size = written?.int64Value, let eTag = response.headers["etag"], !eTag.isEmpty
      else { throw S3Failure(status: response.status, code: "MissingObjectMetadata") }
      // A server that ignored the override sent an encoded length for the decoded bytes.
      let encoding = response.headers["content-encoding"]?.lowercased() ?? "identity"
      if encoding == "identity",
        let expected = response.headers["content-length"].flatMap({ Int64($0) }), expected != size
      {
        throw S3Failure(status: response.status, code: "IncompleteDownload")
      }
      return S3ObjectMetadata(
        size: size, eTag: eTag, jobID: response.headers["x-amz-meta-s3-mountain-job-id"])
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }

  public func put(key: String, file: URL, size: Int64, contentMD5: String, overwrite: Bool)
    async throws -> String
  {
    try validate(key: key)
    try validate(file: file, size: size, contentMD5: contentMD5)
    var headers = ["content-md5": contentMD5, "content-type": "application/octet-stream"]
    if !overwrite { headers["if-none-match"] = "*" }
    do {
      let response = try await perform(
        method: "PUT", key: key, headers: headers, body: .file(file, size))
      return try eTag(response)
    } catch let failure as S3Failure where !overwrite && failure.isConflict {
      // 409 is a create-only write that lost a race still in progress.
      throw MountError.alreadyExists
    }
  }

  public func createMultipart(key: String) async throws -> String {
    try validate(key: key)
    return try await initiateMultipart(key: key, metadata: [:])
  }

  public func completeMultipart(
    key: String, uploadID: String, parts: [S3CompletedPart], overwrite: Bool
  ) async throws -> String {
    do {
      return try await finishMultipart(
        key: key, uploadID: uploadID, parts: parts, createOnly: !overwrite)
    } catch let failure as S3Failure where !overwrite && failure.isConflict {
      throw MountError.alreadyExists
    }
  }

  public func copyObject(from source: String, to destination: String) async throws -> String {
    try validate(key: source)
    try validate(key: destination)
    let response = try await perform(
      method: "PUT", key: destination, headers: ["x-amz-copy-source": copySource(source)],
      body: .data(Data()))
    return try xmlETag(document(response, expectedRoot: "CopyObjectResult"), response)
  }

  public func uploadPartCopy(
    key: String, uploadID: String, number: Int, source: String, range: ClosedRange<Int64>
  ) async throws -> String {
    try validate(key: key)
    try validate(key: source)
    guard (1...10_000).contains(number), !uploadID.isEmpty, range.lowerBound >= 0 else {
      throw S3Failure(status: 0, code: "InvalidPart")
    }
    let response = try await perform(
      method: "PUT", key: key, query: [("partNumber", String(number)), ("uploadId", uploadID)],
      headers: [
        "x-amz-copy-source": copySource(source),
        "x-amz-copy-source-range": "bytes=\(range.lowerBound)-\(range.upperBound)",
      ], body: .data(Data()))
    return try xmlETag(document(response, expectedRoot: "CopyPartResult"), response)
  }

  public func deleteObject(key: String) async throws {
    try validate(key: key)
    _ = try await perform(method: "DELETE", key: key, allowNotFound: true)
  }

  public func deleteObjects(keys: [String]) async throws {
    guard (1...1_000).contains(keys.count) else {
      throw S3Failure(status: 0, code: "InvalidDeleteBatch")
    }
    for key in keys { try validate(key: key) }
    // XML parsers turn a raw CR into LF, which would name a different key.
    let objects = keys.map {
      "<Object><Key>"
        + S3XML.escape($0).replacingOccurrences(of: "\r", with: "&#13;") + "</Key></Object>"
    }
    let body = Data(("<Delete><Quiet>true</Quiet>" + objects.joined() + "</Delete>").utf8)
    let response = try await perform(
      method: "POST", query: [("delete", "")],
      headers: [
        "content-md5": Data(Insecure.MD5.hash(data: body)).base64EncodedString(),
        "content-type": "application/xml",
      ], body: .data(body))
    let root = try document(response, expectedRoot: "DeleteResult")
    if let error = root.children.first(where: { $0.name == "Error" }) {
      throw S3Failure(status: response.status, code: error.value("Code") ?? "DeleteFailed")
    }
  }

  public func listAll(prefix: String) async throws -> [S3ListedObject] {
    var token: String?
    var tokens = Set<String>()
    var keys = Set<[UInt8]>()
    var objects: [S3ListedObject] = []
    while true {
      var query = [("list-type", "2"), ("max-keys", "1000")]
      if !prefix.isEmpty { query.append(("prefix", prefix)) }
      if let token { query.append(("continuation-token", token)) }
      let response = try await perform(method: "GET", query: query)
      let root = try document(response, expectedRoot: "ListBucketResult")
      for node in root.children where node.name == "Contents" {
        guard let key = node.child("Key")?.text, !key.isEmpty, key.utf8.starts(with: prefix.utf8),
          let size = node.value("Size").flatMap({ Int64($0) }), size >= 0
        else { throw S3Failure(status: response.status, code: "InvalidListing") }
        if keys.insert(Array(key.utf8)).inserted {
          objects.append(S3ListedObject(key: key, size: size))
        }
      }
      switch root.value("IsTruncated") {
      case "false": return objects
      case "true":
        guard let next = root.value("NextContinuationToken"), !next.isEmpty,
          tokens.insert(next).inserted
        else { throw S3Failure(status: response.status, code: "InvalidListPagination") }
        token = next
      default: throw S3Failure(status: response.status, code: "InvalidListPagination")
      }
    }
  }

  /// An empty key would address the bucket itself.
  private func validate(key: String) throws {
    guard !key.isEmpty, key.utf8.count <= 1024 else { throw MountError.invalidName }
  }

  private func copySource(_ key: String) -> String {
    "/" + SigV4Signer.uriEncode(configuration.bucket) + "/"
      + SigV4Signer.uriEncode(key, preserveSlash: true)
  }

  private func xmlETag(_ root: S3XMLNode, _ response: S3HTTPResponse) throws -> String {
    guard let value = root.value("ETag"), !value.isEmpty else {
      throw S3Failure(status: response.status, code: "MissingETag")
    }
    return value
  }
}
