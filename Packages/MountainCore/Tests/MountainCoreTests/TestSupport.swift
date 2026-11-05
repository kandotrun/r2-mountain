import Foundation
import Testing

@testable import MountainCore

actor RecordingS3Transport: S3HTTPTransport {
  private var responses: [S3HTTPResponse]
  private var captured: [S3HTTPRequest] = []

  init(_ responses: [S3HTTPResponse]) { self.responses = responses }

  func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
    captured.append(request)
    guard !responses.isEmpty else { throw S3Failure(status: 0, code: "UnexpectedRequest") }
    return responses.removeFirst()
  }

  func requests() -> [S3HTTPRequest] { captured }
}

func s3Response(_ status: Int = 200, headers: [String: String] = [:], xml: String = "")
  -> S3HTTPResponse
{
  S3HTTPResponse(status: status, headers: headers, body: Data(xml.utf8))
}

func makeS3Client(_ transport: RecordingS3Transport) -> S3Client {
  S3Client(
    configuration: R2Configuration(accountID: String(repeating: "a", count: 32), bucket: "drive"),
    credentials: S3Credentials(accessKeyID: "test-access", secretAccessKey: "test-secret"),
    transport: transport,
    dateProvider: { Date(timeIntervalSince1970: 1_794_000_000) }
  )
}

func queryItems(_ request: S3HTTPRequest) -> [String: String] {
  let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
  return items.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
}

let testConfiguration = R2Configuration(
  accountID: String(repeating: "0", count: 32), bucket: "test-bucket")

func makeJob(
  _ state: UploadState = .queued, size: Int64 = 100, completedBytes: Int64 = 0,
  relativePath: String = "素材/clip.mov", key: String = "backup/素材/clip.mov",
  configuration: R2Configuration = testConfiguration
) -> UploadJob {
  var job = UploadJob(
    sourceURL: URL(fileURLWithPath: "/tmp/source-" + UUID().uuidString),
    relativePath: relativePath, key: key, configuration: configuration,
    identity: SourceIdentity(
      size: size, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), inode: 1, device: 1),
    partSize: 64 * 1_048_576)
  job.state = state
  job.completedBytes = completedBytes
  return job
}

func journalFiles(_ directory: URL) -> Set<String> {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
  return Set(names.filter { $0.hasSuffix(".json") })
}
