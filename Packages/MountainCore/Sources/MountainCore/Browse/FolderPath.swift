import Foundation

public enum FolderNameError: Error, Equatable, Sendable, LocalizedError {
  case empty, containsSlash, reserved, invalidCharacters, tooLong

  public var errorDescription: String? {
    switch self {
    case .empty: "フォルダ名を入力してください。"
    case .containsSlash: "フォルダ名に「/」は使えません。"
    case .reserved: "「.」や「..」はフォルダ名に使えません。"
    case .invalidCharacters: "フォルダ名に制御文字は使えません。"
    case .tooLong: "フォルダのパスが長すぎます（1024バイトまで）。"
    }
  }
}

public enum FolderName {
  static let maximumPrefixBytes = 1024

  public static func validate(_ raw: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    try check(name)
    return name
  }

  /// The rules alone, without trimming or normalizing: stored S3 names must keep their bytes.
  static func check(_ name: String) throws {
    guard !name.isEmpty else { throw FolderNameError.empty }
    // Scalars, not Characters: "/" followed by a combining mark is still an S3 delimiter.
    guard !name.unicodeScalars.contains("/") else { throw FolderNameError.containsSlash }
    guard name != ".", name != ".." else { throw FolderNameError.reserved }
    guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else { throw FolderNameError.invalidCharacters }
    guard name.utf8.count + 1 <= maximumPrefixBytes else { throw FolderNameError.tooLong }
  }
}

public struct FolderPath: Hashable, Sendable, Codable, CustomStringConvertible {
  public static let root = FolderPath(validated: [])
  public let components: [String]

  private init(validated components: [String]) { self.components = components }

  public init(components: [String]) throws {
    let validated = try components.map(FolderName.validate)
    guard Self.prefixLength(validated) <= FolderName.maximumPrefixBytes else {
      throw FolderNameError.tooLong
    }
    self.init(validated: validated)
  }

  /// Keeps stored names byte-exact (padding, NFD) so the path still addresses the same S3 prefix.
  public init?(prefix: String) {
    let parts = prefix.unicodeScalars.split(separator: "/").map(String.init)
    guard parts.allSatisfy({ (try? FolderName.check($0)) != nil }),
      Self.prefixLength(parts) <= FolderName.maximumPrefixBytes
    else { return nil }
    self.init(validated: parts)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let path = FolderPath(prefix: try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid folder prefix")
    }
    self = path
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(prefix)
  }

  /// Byte-exact: canonically equivalent names are still different S3 prefixes.
  public static func == (lhs: FolderPath, rhs: FolderPath) -> Bool {
    lhs.prefix.utf8.elementsEqual(rhs.prefix.utf8)
  }

  public func hash(into hasher: inout Hasher) { hasher.combine(Array(prefix.utf8)) }

  public var prefix: String { components.isEmpty ? "" : components.joined(separator: "/") + "/" }
  public var isRoot: Bool { components.isEmpty }
  public var name: String? { components.last }
  public var parent: FolderPath? {
    isRoot ? nil : FolderPath(validated: Array(components.dropLast()))
  }
  public var lineage: [FolderPath] {
    (0...components.count).map { FolderPath(validated: Array(components.prefix($0))) }
  }
  public var description: String { prefix }

  public func appending(_ name: String) throws -> FolderPath {
    let next = components + [try FolderName.validate(name)]
    guard Self.prefixLength(next) <= FolderName.maximumPrefixBytes else {
      throw FolderNameError.tooLong
    }
    return FolderPath(validated: next)
  }

  private static func prefixLength(_ components: [String]) -> Int {
    components.reduce(0) { $0 + $1.utf8.count + 1 }
  }
}
