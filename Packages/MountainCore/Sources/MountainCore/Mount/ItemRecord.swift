import Foundation

public struct ItemRecord: Sendable, Equatable, Codable {
  public static let rootID = "root"

  public let id: String
  public var key: String
  public var parentID: String
  public var name: String
  public var isFolder: Bool
  public var size: Int64?
  public var eTag: String?
  public var modified: Date?

  public init(
    id: String, key: String, parentID: String, name: String, isFolder: Bool,
    size: Int64? = nil, eTag: String? = nil, modified: Date? = nil
  ) {
    self.id = id
    self.key = key
    self.parentID = parentID
    self.name = name
    self.isFolder = isFolder
    self.size = size
    self.eTag = eTag
    self.modified = modified
  }

  /// Byte-exact: canonically equivalent keys and names are still different S3 objects.
  public static func == (lhs: ItemRecord, rhs: ItemRecord) -> Bool {
    lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.key.utf8.elementsEqual(rhs.key.utf8)
      && lhs.parentID.utf8.elementsEqual(rhs.parentID.utf8)
      && lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.isFolder == rhs.isFolder
      && lhs.size == rhs.size && lhs.eTag == rhs.eTag && lhs.modified == rhs.modified
  }
}
