import Foundation
import Testing

@testable import MountainCore

@Suite("S3 request and response contract")
struct S3ClientTests {
  @Test("Only HEAD 404 represents a missing key")
  func headStatusHandling() async throws {
    let transport = RecordingS3Transport([s3Response(404), s3Response(403)])
    let client = makeS3Client(transport)
    #expect(try await client.head(key: "missing") == nil)
    await #expect(throws: S3Failure(status: 403, code: "HTTP403")) {
      _ = try await client.head(key: "forbidden")
    }
  }

  @Test("HEAD preserves ETag and application metadata")
  func headMetadata() async throws {
    let transport = RecordingS3Transport([
      s3Response(headers: [
        "Content-Length": "123", "ETag": "\"abc\"", "X-Amz-Meta-S3-Mountain-Job-ID": "job-1",
      ])
    ])
    let metadata = try await makeS3Client(transport).head(key: "x")
    #expect(metadata == S3ObjectMetadata(size: 123, eTag: "\"abc\"", jobID: "job-1"))
  }

  @Test("PUT is create-only and preserves UTF8 paths without double encoding")
  func putEncodingAndHeaders() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = RecordingS3Transport([
      s3Response(headers: ["ETag": "\"900150983cd24fb0d6963f7d28e17f72\""])
    ])
    let client = makeS3Client(transport)
    let eTag = try await client.put(
      key: "日本語 +%//a.txt", file: file, size: 3, contentMD5: "kAFQmDzST7DWlj99KOF/cg==",
      jobID: "job-1")
    #expect(eTag == "\"900150983cd24fb0d6963f7d28e17f72\"")
    let request = try #require(await transport.requests().first)
    #expect(
      request.url.absoluteString.contains("/drive/%E6%97%A5%E6%9C%AC%E8%AA%9E%20%2B%25//a.txt"))
    #expect(request.headers["if-none-match"] == "*")
    #expect(request.headers["content-length"] == "3")
    #expect(request.headers["content-md5"] == "kAFQmDzST7DWlj99KOF/cg==")
    #expect(request.headers["x-amz-content-sha256"] == "UNSIGNED-PAYLOAD")
    #expect(request.headers["authorization"]?.contains("content-md5") == true)
    #expect(request.headers["authorization"]?.contains("if-none-match") == true)
    #expect(request.headers["authorization"]?.contains("x-amz-meta-s3-mountain-job-id") == true)
    #expect(request.headers["transfer-encoding"] == nil)
  }

  @Test("Initiation signs an empty query value and returns decoded UploadId")
  func initiateUpload() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<InitiateMultipartUploadResult><UploadId>a+b&amp;c=</UploadId></InitiateMultipartUploadResult>"
      )
    ])
    #expect(try await makeS3Client(transport).createMultipart(key: "x", jobID: "job-1") == "a+b&c=")
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString.hasSuffix("/drive/x?uploads="))
    #expect(request.headers["content-length"] == "0")
  }

  @Test("ListParts follows every marker and encodes upload IDs")
  func listPartsPagination() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>1</NextPartNumberMarker><Part><PartNumber>1</PartNumber><Size>3</Size><ETag>&quot;a&quot;</ETag></Part></ListPartsResult>"
      ),
      s3Response(
        xml:
          "<ListPartsResult><IsTruncated>false</IsTruncated><Part><PartNumber>2</PartNumber><Size>2</Size><ETag>&quot;b&quot;</ETag></Part></ListPartsResult>"
      ),
    ])
    let parts = try await makeS3Client(transport).listParts(key: "x", uploadID: "a+b/c%=")
    #expect(
      parts == [
        S3RemotePart(number: 1, size: 3, eTag: "\"a\""),
        S3RemotePart(number: 2, size: 2, eTag: "\"b\""),
      ])
    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests[0].url.absoluteString.contains("uploadId=a%2Bb%2Fc%25%3D"))
    #expect(requests[1].url.absoluteString.contains("part-number-marker=1"))
  }

  @Test("Nonadvancing ListParts markers fail instead of looping")
  func badListPartsMarker() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>0</NextPartNumberMarker></ListPartsResult>"
      )
    ])
    await #expect(throws: S3Failure(status: 200, code: "InvalidPartPagination")) {
      _ = try await makeS3Client(transport).listParts(key: "x", uploadID: "upload")
    }
  }

  @Test("Complete is create-only, sorted and XML escaped")
  func completeRequest() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<CompleteMultipartUploadResult><ETag>&quot;done-2&quot;</ETag></CompleteMultipartUploadResult>"
      )
    ])
    let parts = [
      S3CompletedPart(number: 2, size: 1, eTag: "\"b&x\"", md5Hex: "b"),
      S3CompletedPart(number: 1, size: 3, eTag: "\"a\"", md5Hex: "a"),
    ]
    #expect(
      try await makeS3Client(transport).completeMultipart(
        key: "x", uploadID: "upload", parts: parts) == "\"done-2\"")
    let request = try #require(await transport.requests().first)
    #expect(request.headers["if-none-match"] == "*")
    guard case .data(let data) = request.body else {
      Issue.record("Expected XML data body")
      return
    }
    let body = String(decoding: data, as: UTF8.self)
    #expect(body.contains("<PartNumber>1</PartNumber><ETag>&quot;a&quot;</ETag>"))
    #expect(body.contains("&quot;b&amp;x&quot;"))
    #expect(
      body.range(of: "<PartNumber>1")!.lowerBound < body.range(of: "<PartNumber>2")!.lowerBound)
    #expect(request.headers["content-length"] == String(data.count))
  }

  @Test("A 200 response with Error XML is a failure")
  func embeddedCompletionError() async throws {
    let transport = RecordingS3Transport([
      s3Response(xml: "<Error><Code>InternalError</Code><Message>not logged</Message></Error>")
    ])
    await #expect(throws: S3Failure(status: 200, code: "InternalError")) {
      _ = try await makeS3Client(transport).completeMultipart(
        key: "x", uploadID: "upload",
        parts: [S3CompletedPart(number: 1, size: 1, eTag: "\"a\"", md5Hex: "a")])
    }
  }

  @Test("Truncated success XML is never accepted")
  func malformedCompletionXML() async throws {
    let transport = RecordingS3Transport([
      s3Response(xml: "<CompleteMultipartUploadResult><ETag>abc</ETag>")
    ])
    await #expect(throws: S3Failure(status: 200, code: "MalformedXMLResponse")) {
      _ = try await makeS3Client(transport).completeMultipart(
        key: "x", uploadID: "upload",
        parts: [S3CompletedPart(number: 1, size: 1, eTag: "a", md5Hex: "a")])
    }
  }

  @Test("DOCTYPE and external entities are rejected")
  func unsafeXML() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<!DOCTYPE x [<!ENTITY unsafe SYSTEM 'file:///etc/hosts'>]><InitiateMultipartUploadResult><UploadId>&unsafe;</UploadId></InitiateMultipartUploadResult>"
      )
    ])
    await #expect(throws: S3Failure(status: 200, code: "UnsafeXMLResponse")) {
      _ = try await makeS3Client(transport).createMultipart(key: "x", jobID: "job-1")
    }
  }

  @Test("Connection test uses the bucket and max-keys one")
  func connectionTest() async throws {
    let transport = RecordingS3Transport([
      s3Response(xml: "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>")
    ])
    try await makeS3Client(transport).testConnection()
    let request = try #require(await transport.requests().first)
    #expect(request.url.path == "/drive")
    #expect(request.url.query == "list-type=2&max-keys=1")
  }

  @Test("Explicit clock skew retries once using the endpoint date")
  func clockSkewCorrection() async throws {
    let date = Date(timeIntervalSince1970: 1_794_000_000)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    let transport = RecordingS3Transport([
      s3Response(
        403, headers: ["Date": formatter.string(from: date.addingTimeInterval(300))],
        xml: "<Error><Code>RequestTimeTooSkewed</Code></Error>"),
      s3Response(xml: "<ListBucketResult/>"),
    ])
    try await makeS3Client(transport).testConnection()
    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests[0].headers["x-amz-date"] != requests[1].headers["x-amz-date"])
  }

  @Test("Retry-After is exposed without silently shortening server delays")
  func retryAfterHeader() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        429, headers: ["Retry-After": "172800"], xml: "<Error><Code>SlowDown</Code></Error>")
    ])
    await #expect(throws: S3Failure(status: 429, code: "SlowDown", retryAfter: 172_800)) {
      try await makeS3Client(transport).testConnection()
    }
  }

  @Test("Empty truncated pages are rejected")
  func emptyTruncatedPage() async throws {
    let transport = RecordingS3Transport([
      s3Response(
        xml:
          "<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>1</NextPartNumberMarker></ListPartsResult>"
      )
    ])
    await #expect(throws: S3Failure(status: 200, code: "InvalidPartPagination")) {
      _ = try await makeS3Client(transport).listParts(key: "x", uploadID: "upload")
    }
    #expect(await transport.requests().count == 1)
  }

  @Test("A changed body length fails before transport")
  func changedBodyLength() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = RecordingS3Transport([])
    await #expect(throws: S3Failure(status: 0, code: "UploadBodyLengthChanged")) {
      _ = try await makeS3Client(transport).put(
        key: "x", file: file, size: 4, contentMD5: "kAFQmDzST7DWlj99KOF/cg==", jobID: "job-1")
    }
    #expect(await transport.requests().isEmpty)
  }
}
