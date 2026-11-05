import Foundation

@testable import MountainCore

let itemDate = Date(timeIntervalSince1970: 1_793_786_400.25)

func entryName(_ key: String) -> String {
  String(key.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
}

func folderEntry(_ key: String) -> RemoteEntry {
  RemoteEntry(key: key, name: entryName(key), kind: .folder, size: nil, lastModified: nil)
}

func fileEntry(_ key: String, size: Int64 = 1, modified: Date = itemDate) -> RemoteEntry {
  RemoteEntry(key: key, name: entryName(key), kind: .file, size: size, lastModified: modified)
}

func folderListing(_ prefix: String, _ entries: [RemoteEntry], truncated: Bool = false)
  -> FolderListing
{
  FolderListing(
    path: FolderPath(prefix: prefix)!, folders: entries.filter { $0.kind == .folder },
    files: entries.filter { $0.kind == .file }, isTruncated: truncated)
}

func makeItemStore(bucket: String = "drive") throws -> ItemStore {
  try ItemStore(url: nil, bucket: bucket)
}

extension ItemStore {
  /// Reconciles the folder stored at `prefix`.
  @discardableResult
  func list(_ prefix: String, _ entries: [RemoteEntry], truncated: Bool = false) throws
    -> [ItemRecord]
  {
    guard let folder = record(key: prefix) else { throw ItemStoreError.notFound(prefix) }
    return try reconcile(
      folderID: folder.id, listing: folderListing(prefix, entries, truncated: truncated))
  }

  func id(_ key: String) -> String? { record(key: key)?.id }

  func ids(_ keys: [String]) throws -> [String] {
    try keys.map { key in
      guard let id = record(key: key)?.id else { throw ItemStoreError.notFound(key) }
      return id
    }
  }
}

func keyBytes(_ records: [ItemRecord]) -> [[UInt8]] { records.map { Array($0.key.utf8) } }

/// The system's copy of the tree, built from change batches alone. Deleting a folder also drops
/// whatever the copy still holds inside it, as File Provider does.
struct ItemReplica {
  private(set) var items: [String: ItemRecord]

  init(_ records: [ItemRecord]) {
    items = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  var records: [ItemRecord] {
    items.values.sorted { Array($0.key.utf8).lexicographicallyPrecedes($1.key.utf8) }
  }

  /// Keys of items sharing a parent and a name with an earlier one.
  var collisions: [String] {
    var names = Set<[UInt8]>()
    return records.filter { item in
      item.id != ItemRecord.rootID
        && !names.insert(Array("\(item.parentID)/\(item.name)".utf8)).inserted
    }.map(\.key)
  }

  var orphans: [String] {
    records.filter { $0.id != ItemRecord.rootID && items[$0.parentID] == nil }.map(\.key)
  }

  mutating func apply(_ batch: ChangeBatch) {
    for record in batch.updated { items[record.id] = record }
    for id in batch.deletedIDs { drop(id) }
  }

  private mutating func drop(_ id: String) {
    items[id] = nil
    for child in items.values.filter({ $0.parentID == id && $0.id != id }) { drop(child.id) }
  }
}

/// Every state a replica passes through while catching up from `anchor` in batches of `limit`.
func replayStates(of store: ItemStore, from replica: ItemReplica, after anchor: Int64, limit: Int)
  async -> [ItemReplica]
{
  var replica = replica
  var anchor = anchor
  var states: [ItemReplica] = []
  while true {
    let batch = await store.changes(after: anchor, limit: limit)
    replica.apply(batch)
    states.append(replica)
    anchor = batch.last
    if !batch.hasMore { return states }
  }
}
