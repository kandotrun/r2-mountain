import Foundation

public struct R2Configuration: Codable, Sendable, Equatable {
  public enum Jurisdiction: String, Codable, Sendable, CaseIterable {
    case standard, eu
  }

  public var accountID: String
  public var bucket: String
  public var jurisdiction: Jurisdiction

  public init(accountID: String, bucket: String, jurisdiction: Jurisdiction = .standard) {
    self.accountID = accountID
    self.bucket = bucket
    self.jurisdiction = jurisdiction
  }

  public var endpoint: URL {
    let suffix = jurisdiction == .eu ? ".eu" : ""
    return URL(string: "https://\(accountID)\(suffix).r2.cloudflarestorage.com")!
  }

  public func validate() throws {
    guard accountID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
      bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
      !bucket.contains("..")
    else { throw S3Failure(status: 0, code: "InvalidConfiguration") }
  }
}

public struct S3Credentials: Sendable {
  public let accessKeyID: String
  public let secretAccessKey: String

  public init(accessKeyID: String, secretAccessKey: String) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
  }
}

public struct S3ObjectMetadata: Sendable, Equatable {
  public let size: Int64
  public let eTag: String
  public let jobID: String?
  public let lastModified: Date?

  public init(size: Int64, eTag: String, jobID: String? = nil, lastModified: Date? = nil) {
    self.size = size
    self.eTag = eTag
    self.jobID = jobID
    self.lastModified = lastModified
  }
}

public struct S3CompletedPart: Codable, Sendable, Equatable {
  public let number: Int
  public let size: Int64
  public let eTag: String
  public let md5Hex: String

  public init(number: Int, size: Int64, eTag: String, md5Hex: String) {
    self.number = number
    self.size = size
    self.eTag = eTag
    self.md5Hex = md5Hex
  }
}

public struct S3RemotePart: Sendable, Equatable {
  public let number: Int
  public let size: Int64
  public let eTag: String

  public init(number: Int, size: Int64, eTag: String) {
    self.number = number
    self.size = size
    self.eTag = eTag
  }
}

public struct S3Failure: Error, Sendable, LocalizedError, Equatable {
  public let status: Int
  public let code: String
  public let retryAfter: TimeInterval?

  public init(status: Int, code: String, retryAfter: TimeInterval? = nil) {
    self.status = status
    self.code = code
    self.retryAfter = retryAfter
  }

  public var errorDescription: String? { "S3 \(code) (\(status))" }
  public var isConflict: Bool { status == 412 || status == 409 }
  public var isMissingUpload: Bool { code == "NoSuchUpload" }
  public var isAuthentication: Bool { status == 401 || status == 403 }
  public var isRetryable: Bool {
    status == 429 || (500...599).contains(status)
      || ["InternalError", "SlowDown", "RequestTimeout"].contains(code)
  }
}

public protocol S3ObjectStore: Sendable {
  func testConnection() async throws
  func head(key: String) async throws -> S3ObjectMetadata?
  func put(key: String, file: URL, size: Int64, contentMD5: String, jobID: String) async throws
    -> String
  func createMultipart(key: String, jobID: String) async throws -> String
  func uploadPart(
    key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5: String
  ) async throws -> String
  func listParts(key: String, uploadID: String) async throws -> [S3RemotePart]
  func completeMultipart(key: String, uploadID: String, parts: [S3CompletedPart]) async throws
    -> String
  func abortMultipart(key: String, uploadID: String) async throws
}
