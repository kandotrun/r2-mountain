import Foundation

public struct RemoteEntry: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable { case folder, file }

  public let key: String
  public let name: String
  public let kind: Kind
  public let size: Int64?
  public let lastModified: Date?

  public init(key: String, name: String, kind: Kind, size: Int64?, lastModified: Date?) {
    self.key = key
    self.name = name
    self.kind = kind
    self.size = size
    self.lastModified = lastModified
  }

  public var id: String { key }
  public var folderPath: FolderPath? { kind == .folder ? FolderPath(prefix: key) : nil }

  /// Byte-exact: canonically equivalent keys are still different S3 objects.
  public static func == (lhs: RemoteEntry, rhs: RemoteEntry) -> Bool {
    lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8)
      && lhs.kind == rhs.kind && lhs.size == rhs.size && lhs.lastModified == rhs.lastModified
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(Array(key.utf8))
    hasher.combine(kind)
    hasher.combine(size)
    hasher.combine(lastModified)
  }
}

public struct FolderListing: Sendable, Equatable {
  public let path: FolderPath
  public let folders: [RemoteEntry]
  public let files: [RemoteEntry]
  public let isTruncated: Bool

  public init(path: FolderPath, folders: [RemoteEntry], files: [RemoteEntry], isTruncated: Bool) {
    self.path = path
    self.folders = folders.sorted(by: Self.finderOrder)
    self.files = files.sorted(by: Self.finderOrder)
    self.isTruncated = isTruncated
  }

  private static func finderOrder(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> Bool {
    switch lhs.name.localizedStandardCompare(rhs.name) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: Array(lhs.key.utf8).lexicographicallyPrecedes(rhs.key.utf8)
    }
  }
}

extension FolderListing {
  /// The listed folder a typed path refers to: an exact byte match first, then a canonically
  /// equivalent name such as an NFD folder written by another Mac tool.
  public func existingFolder(matching path: FolderPath) -> FolderPath? {
    let exact = folders.first { $0.key.utf8.elementsEqual(path.prefix.utf8) }
    return (exact ?? folders.first { $0.key == path.prefix })?.folderPath
  }
}

public protocol S3FolderBrowsing: Sendable {
  func listFolder(_ path: FolderPath, pageLimit: Int) async throws -> FolderListing
  func createFolder(_ path: FolderPath) async throws
}
