import Foundation

public actor S3Client: S3ObjectStore {
  private let configuration: R2Configuration
  private let credentials: S3Credentials
  private let transport: any S3HTTPTransport
  private let dateProvider: @Sendable () -> Date
  private var clockOffset: TimeInterval = 0

  public init(
    configuration: R2Configuration,
    credentials: S3Credentials,
    transport: any S3HTTPTransport = URLSessionS3Transport(),
    dateProvider: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.credentials = credentials
    self.transport = transport
    self.dateProvider = dateProvider
  }

  public func testConnection() async throws {
    let response = try await perform(method: "GET", query: [("list-type", "2"), ("max-keys", "1")])
    _ = try document(response, expectedRoot: "ListBucketResult")
  }

  public func head(key: String) async throws -> S3ObjectMetadata? {
    let response = try await perform(method: "HEAD", key: key, allowNotFound: true)
    if response.status == 404 { return nil }
    guard let text = response.headers["content-length"], let size = Int64(text), size >= 0,
      let eTag = response.headers["etag"], !eTag.isEmpty
    else {
      throw S3Failure(status: response.status, code: "MissingObjectMetadata")
    }
    return S3ObjectMetadata(
      size: size, eTag: eTag, jobID: response.headers["x-amz-meta-s3-mountain-job-id"])
  }

  public func put(key: String, file: URL, size: Int64, contentMD5: String, jobID: String)
    async throws -> String
  {
    try validate(file: file, size: size, contentMD5: contentMD5)
    try validate(jobID: jobID)
    let response = try await perform(
      method: "PUT", key: key,
      headers: [
        "content-md5": contentMD5, "content-type": "application/octet-stream",
        "if-none-match": "*", "x-amz-meta-s3-mountain-job-id": jobID,
      ], body: .file(file, size))
    return try eTag(response)
  }

  public func createMultipart(key: String, jobID: String) async throws -> String {
    try validate(jobID: jobID)
    let response = try await perform(
      method: "POST", key: key, query: [("uploads", "")],
      headers: [
        "content-type": "application/octet-stream", "x-amz-meta-s3-mountain-job-id": jobID,
      ], body: .data(Data()))
    let root = try document(response, expectedRoot: "InitiateMultipartUploadResult")
    guard let uploadID = root.value("UploadId"), !uploadID.isEmpty else {
      throw S3Failure(status: response.status, code: "MissingUploadID")
    }
    return uploadID
  }

  public func uploadPart(
    key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5: String
  ) async throws -> String {
    try validate(file: file, size: size, contentMD5: contentMD5)
    guard (1...10_000).contains(number), !uploadID.isEmpty else {
      throw S3Failure(status: 0, code: "InvalidPart")
    }
    let response = try await perform(
      method: "PUT", key: key,
      query: [
        ("partNumber", String(number)), ("uploadId", uploadID),
      ], headers: ["content-md5": contentMD5, "content-type": "application/octet-stream"],
      body: .file(file, size))
    return try eTag(response)
  }

  public func listParts(key: String, uploadID: String) async throws -> [S3RemotePart] {
    guard !uploadID.isEmpty else { throw S3Failure(status: 0, code: "MissingUploadID") }
    var marker = 0
    var collected: [S3RemotePart] = []
    while true {
      let pageStartCount = collected.count
      var query = [("uploadId", uploadID), ("max-parts", "1000")]
      if marker > 0 { query.append(("part-number-marker", String(marker))) }
      let response = try await perform(method: "GET", key: key, query: query)
      let root = try document(response, expectedRoot: "ListPartsResult")
      for node in root.children where node.name == "Part" {
        guard let numberText = node.value("PartNumber"), let number = Int(numberText),
          (1...10_000).contains(number),
          let sizeText = node.value("Size"), let size = Int64(sizeText), size >= 0,
          let eTag = node.value("ETag"), !eTag.isEmpty,
          number > (collected.last?.number ?? marker)
        else {
          throw S3Failure(status: response.status, code: "InvalidPartListing")
        }
        collected.append(S3RemotePart(number: number, size: size, eTag: eTag))
      }
      guard let truncated = root.value("IsTruncated"), truncated == "true" || truncated == "false"
      else {
        throw S3Failure(status: response.status, code: "InvalidPartPagination")
      }
      if truncated == "false" { return collected }
      guard let nextText = root.value("NextPartNumberMarker"), let next = Int(nextText),
        collected.count > pageStartCount,
        next > marker, next >= (collected.last?.number ?? 0), next <= 10_000
      else {
        throw S3Failure(status: response.status, code: "InvalidPartPagination")
      }
      marker = next
    }
  }

  public func completeMultipart(key: String, uploadID: String, parts: [S3CompletedPart])
    async throws -> String
  {
    let ordered = parts.sorted { $0.number < $1.number }
    guard !uploadID.isEmpty, !ordered.isEmpty, ordered.count <= 10_000,
      Set(ordered.map(\.number)).count == ordered.count,
      ordered.allSatisfy({ (1...10_000).contains($0.number) && $0.size > 0 && !$0.eTag.isEmpty })
    else {
      throw S3Failure(status: 0, code: "InvalidCompletionParts")
    }
    let content = ordered.map {
      "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(S3XML.escape($0.eTag))</ETag></Part>"
    }.joined()
    let body = Data(("<CompleteMultipartUpload>" + content + "</CompleteMultipartUpload>").utf8)
    let response = try await perform(
      method: "POST", key: key, query: [("uploadId", uploadID)],
      headers: [
        "content-type": "application/xml", "if-none-match": "*",
      ], body: .data(body))
    let root = try document(response, expectedRoot: "CompleteMultipartUploadResult")
    guard let value = root.value("ETag"), !value.isEmpty else {
      throw S3Failure(status: response.status, code: "MissingETag")
    }
    return value
  }

  public func abortMultipart(key: String, uploadID: String) async throws {
    guard !uploadID.isEmpty else { throw S3Failure(status: 0, code: "MissingUploadID") }
    _ = try await perform(method: "DELETE", key: key, query: [("uploadId", uploadID)])
  }

  func perform(
    method: String,
    key: String? = nil,
    query: [(String, String)] = [],
    headers extraHeaders: [String: String] = [:],
    body: S3RequestBody = .none,
    allowNotFound: Bool = false
  ) async throws -> S3HTTPResponse {
    try configuration.validate()
    guard !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty,
      !credentials.accessKeyID.contains(where: { $0.isWhitespace }),
      !credentials.secretAccessKey.contains(where: { $0.isNewline })
    else {
      throw S3Failure(status: 0, code: "InvalidCredentials")
    }
    let canonicalURI =
      "/" + SigV4Signer.uriEncode(configuration.bucket)
      + (key.map { "/" + SigV4Signer.uriEncode($0, preserveSlash: true) } ?? "")
    var encodedQuery: [(name: String, value: String)] = []
    for (name, value) in query {
      encodedQuery.append((name: SigV4Signer.uriEncode(name), value: SigV4Signer.uriEncode(value)))
    }
    encodedQuery.sort {
      if $0.name == $1.name { return $0.value < $1.value }
      return $0.name < $1.name
    }
    let canonicalQuery = encodedQuery.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = canonicalURI
    if !canonicalQuery.isEmpty { components.percentEncodedQuery = canonicalQuery }
    guard let url = components.url, let host = url.host else {
      throw S3Failure(status: 0, code: "InvalidURL")
    }
    for attempt in 0...1 {
      try Task.checkCancellation()
      let now = dateProvider().addingTimeInterval(clockOffset)
      var headers = extraHeaders
      headers["host"] = host
      headers["x-amz-date"] = Self.timestamp(now)
      headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
      if method == "PUT" || method == "POST" {
        headers["content-length"] = String(body.contentLength)
      }
      let signature = SigV4Signer.sign(
        method: method, canonicalURI: canonicalURI, canonicalQuery: canonicalQuery,
        headers: headers, payloadHash: "UNSIGNED-PAYLOAD", credentials: credentials
      )
      headers["authorization"] = signature.authorization
      let response = try await transport.send(
        S3HTTPRequest(url: url, method: method, headers: headers, body: body))
      if (200...299).contains(response.status) || (allowNotFound && response.status == 404) {
        return response
      }
      let failure = failure(response)
      if attempt == 0, ["RequestTimeTooSkewed", "RequestExpired"].contains(failure.code),
        let serverText = response.headers["date"], let serverDate = Self.httpDate(serverText)
      {
        let offset = serverDate.timeIntervalSince(dateProvider())
        if abs(offset) <= 86_400 {
          clockOffset = offset
          continue
        }
      }
      throw failure
    }
    throw S3Failure(status: 0, code: "ClockSkewCorrectionFailed")
  }

  func document(_ response: S3HTTPResponse, expectedRoot: String) throws -> S3XMLNode {
    let root = try S3XML.parse(response.body, status: response.status)
    if root.name == "Error" {
      throw S3Failure(
        status: response.status, code: root.value("Code") ?? "UnknownS3Error",
        retryAfter: retryAfter(response))
    }
    guard root.name == expectedRoot else {
      throw S3Failure(status: response.status, code: "UnexpectedXMLResponse")
    }
    return root
  }

  private func failure(_ response: S3HTTPResponse) -> S3Failure {
    let root = try? S3XML.parse(response.body, status: response.status)
    return S3Failure(
      status: response.status,
      code: root?.name == "Error"
        ? (root?.value("Code") ?? "HTTP\(response.status)") : "HTTP\(response.status)",
      retryAfter: retryAfter(response)
    )
  }

  private func retryAfter(_ response: S3HTTPResponse) -> TimeInterval? {
    guard let header = response.headers["retry-after"] else { return nil }
    if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return seconds }
    if let date = Self.httpDate(header) {
      return max(0, date.timeIntervalSince(dateProvider().addingTimeInterval(clockOffset)))
    }
    return nil
  }

  private func eTag(_ response: S3HTTPResponse) throws -> String {
    guard let eTag = response.headers["etag"], !eTag.isEmpty else {
      throw S3Failure(status: response.status, code: "MissingETag")
    }
    return eTag
  }

  private func validate(file: URL, size: Int64, contentMD5: String) throws {
    guard file.isFileURL, size >= 0, Data(base64Encoded: contentMD5)?.count == 16 else {
      throw S3Failure(status: 0, code: "InvalidUploadBody")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard (attributes[.size] as? NSNumber)?.int64Value == size else {
      throw S3Failure(status: 0, code: "UploadBodyLengthChanged")
    }
  }

  private func validate(jobID: String) throws {
    guard jobID.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil else {
      throw S3Failure(status: 0, code: "InvalidJobID")
    }
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func httpDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text)
  }
}
