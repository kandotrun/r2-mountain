import Foundation

public struct RecentFolders: Sendable, Equatable, Codable {
  public private(set) var items: [FolderPath]
  public let limit: Int

  public init(items: [FolderPath] = [], limit: Int = 6) {
    self.limit = max(1, limit)
    var seen = Set<FolderPath>()
    self.items = Array(items.filter { seen.insert($0).inserted }.prefix(self.limit))
  }

  public mutating func record(_ path: FolderPath) {
    items.removeAll { $0 == path }
    items.insert(path, at: 0)
    if items.count > limit { items.removeLast(items.count - limit) }
  }

  private enum CodingKeys: String, CodingKey { case items, limit }

  /// Stored items that no longer validate are dropped instead of discarding the whole list.
  private struct StoredPath: Decodable {
    let path: FolderPath?
    init(from decoder: any Decoder) throws { path = try? FolderPath(from: decoder) }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let stored = try container.decodeIfPresent([StoredPath].self, forKey: .items) ?? []
    self.init(
      items: stored.compactMap(\.path),
      limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 6)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
    try container.encode(limit, forKey: .limit)
  }
}
