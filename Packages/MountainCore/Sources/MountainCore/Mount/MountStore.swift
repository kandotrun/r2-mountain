import Foundation

public protocol S3MountStore: S3FolderBrowsing {
  func head(key: String) async throws -> S3ObjectMetadata?
  func download(
    key: String, to file: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> S3ObjectMetadata
  func put(key: String, file: URL, size: Int64, contentMD5: String, overwrite: Bool)
    async throws -> String
  func createMultipart(key: String) async throws -> String
  func uploadPart(
    key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5: String
  ) async throws -> String
  func listParts(key: String, uploadID: String) async throws -> [S3RemotePart]
  func completeMultipart(
    key: String, uploadID: String, parts: [S3CompletedPart], overwrite: Bool
  ) async throws -> String
  func abortMultipart(key: String, uploadID: String) async throws
  func copyObject(from source: String, to destination: String) async throws -> String
  func uploadPartCopy(
    key: String, uploadID: String, number: Int, source: String, range: ClosedRange<Int64>
  ) async throws -> String
  func deleteObject(key: String) async throws
  /// At most 1000 keys.
  func deleteObjects(keys: [String]) async throws
  /// Every key under the prefix, without a delimiter, across all pages.
  func listAll(prefix: String) async throws -> [S3ListedObject]
}

public struct S3ListedObject: Sendable, Equatable {
  public let key: String
  public let size: Int64

  public init(key: String, size: Int64) {
    self.key = key
    self.size = size
  }

  /// Byte-exact: canonically equivalent keys are still different S3 objects.
  public static func == (lhs: S3ListedObject, rhs: S3ListedObject) -> Bool {
    lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.size == rhs.size
  }
}
