import Foundation

public struct MultipartPlan: Sendable, Equatable {
  public static let maximumObjectSize: Int64 = 5 * 1_099_511_627_776 - 5 * 1_073_741_824
  public static let maximumPartSize: Int64 = 5 * 1_073_741_824 - 5 * 1_048_576
  public let size: Int64
  public let partSize: Int64
  public let partCount: Int
  public let usesMultipart: Bool

  public init(size: Int64) throws {
    guard size >= 0, size <= Self.maximumObjectSize else { throw UploadError.invalidSize }
    self.size = size
    usesMultipart = size >= 64 * 1_048_576
    let required = size / 10_000 + (size % 10_000 == 0 ? 0 : 1)
    let base = max(64 * 1_048_576, required)
    partSize = ((base + 1_048_575) / 1_048_576) * 1_048_576
    guard partSize <= Self.maximumPartSize else { throw UploadError.invalidSize }
    partCount = size == 0 ? 0 : Int(size / partSize + (size % partSize == 0 ? 0 : 1))
  }
}

public enum ObjectKey {
  /// Keeps the destination folder's bytes as listed and stores local names as NFC.
  public static func make(prefix: String, relativePath: String) throws -> String {
    let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.contains("."), !parts.contains(".."), !prefix.contains("\0"),
      !relativePath.contains("\0"), !relativePath.isEmpty
    else { throw UploadError.invalidPath }
    let folder = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let name = relativePath.precomposedStringWithCanonicalMapping
    let key = folder.isEmpty ? name : folder + "/" + name
    guard key.utf8.count <= 1024 else { throw UploadError.invalidPath }
    return key
  }

  /// Adds " 2", " 3"... before the extension without re-normalizing any part of the key.
  public static func suffixed(_ key: String, ordinal: Int) -> String {
    guard ordinal > 1 else { return key }
    let scalars = key.unicodeScalars
    let nameStart =
      scalars.lastIndex(of: "/").map { scalars.index(after: $0) } ?? scalars.startIndex
    let parent = String(scalars[..<nameStart])
    let name = scalars[nameStart...]
    if let dot = name.lastIndex(of: "."), dot != name.startIndex,
      name.index(after: dot) != name.endIndex
    {
      return parent + String(name[..<dot]) + " \(ordinal)."
        + String(name[name.index(after: dot)...])
    }
    return parent + String(name) + " \(ordinal)"
  }
}
