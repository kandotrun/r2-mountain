import Foundation
import SQLite3

public struct ChangeBatch: Sendable, Equatable {
  public let updated: [ItemRecord]
  public let deletedIDs: [String]
  public let last: Int64
  public let hasMore: Bool

  public init(updated: [ItemRecord], deletedIDs: [String], last: Int64, hasMore: Bool) {
    self.updated = updated
    self.deletedIDs = deletedIDs
    self.last = last
    self.hasMore = hasMore
  }
}

enum ItemStoreError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
  case sqlite(code: Int32, message: String)
  case notFound(String)
  case immutableRoot
  case invalidRecord(String)
  case listingMismatch(folder: String, listing: String)

  var description: String {
    switch self {
    case .sqlite(let code, let message): "SQLite error \(code): \(message)"
    case .notFound(let item): "No item \(item)"
    case .immutableRoot: "The root item cannot be moved or removed"
    case .invalidRecord(let reason): "Invalid item: \(reason)"
    case .listingMismatch(let folder, let listing):
      "A listing of \"\(listing)\" cannot reconcile folder \"\(folder)\""
    }
  }

  var errorDescription: String? {
    switch self {
    case .sqlite(let code, _): "項目の記録を読み書きできません（SQLite \(code)）。"
    case .notFound: "項目が見つかりません。"
    case .immutableRoot: "バケットの最上位は移動も削除もできません。"
    case .invalidRecord: "項目の名前か場所が正しくありません。"
    case .listingMismatch: "フォルダの一覧が項目と一致しません。"
    }
  }
}

/// Maps S3 keys (stored as bytes, so NFC and NFD stay distinct) to stable identifiers and keeps
/// a sequenced change log for File Provider enumeration.
public actor ItemStore {
  private static let schema = """
    CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS items (
      id TEXT PRIMARY KEY NOT NULL, key BLOB NOT NULL UNIQUE, parent_id TEXT NOT NULL,
      name TEXT NOT NULL, is_folder INTEGER NOT NULL, size INTEGER, etag TEXT, modified REAL);
    CREATE INDEX IF NOT EXISTS items_by_parent ON items (parent_id);
    CREATE TABLE IF NOT EXISTS listings (folder_id TEXT PRIMARY KEY NOT NULL, stamp INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS changes (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL, deleted INTEGER NOT NULL,
      vacated BLOB);
    """
  private static let columns = "id, key, parent_id, name, is_folder, size, etag, modified"

  private let database: SQLiteDatabase
  private let storedGeneration: String

  public init(url: URL?, bucket: String) throws {
    if let url {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let database = try SQLiteDatabase(path: url?.path ?? ":memory:")
    if url != nil { try database.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL") }
    try database.execute(Self.schema)
    storedGeneration = try database.transaction {
      try database.run(
        "INSERT OR IGNORE INTO meta (name, value) VALUES ('generation', ?)",
        [.text(UUID().uuidString)])
      try database.run(
        "INSERT OR IGNORE INTO items (id, key, parent_id, name, is_folder) VALUES (?, ?, ?, ?, 1)",
        [.text(ItemRecord.rootID), .blob([]), .text(ItemRecord.rootID), .text(bucket)])
      var rootName = ""
      try database.query("SELECT name FROM items WHERE id = ?", [.text(ItemRecord.rootID)]) {
        rootName = $0.text(0)
      }
      if !rootName.utf8.elementsEqual(bucket.utf8) {
        try database.run(
          "UPDATE items SET name = ? WHERE id = ?", [.text(bucket), .text(ItemRecord.rootID)])
        try database.run(
          "INSERT INTO changes (item_id, deleted) VALUES (?, 0)", [.text(ItemRecord.rootID)])
      }
      var generation = ""
      try database.query("SELECT value FROM meta WHERE name = 'generation'") {
        generation = $0.text(0)
      }
      return generation
    }
    self.database = database
  }

  public var generation: String { storedGeneration }

  public func record(id: String) -> ItemRecord? { try? fetch(id: id) }

  public func record(key: String) -> ItemRecord? { try? fetch(key: key) }

  public func children(of id: String) -> [ItemRecord] { (try? childRecords(of: id)) ?? [] }

  /// Matches a listing to stored records by exact key bytes, assigns UUIDs to new keys, deletes
  /// children the listing no longer contains (unless it is truncated) and logs what changed.
  public func reconcile(folderID: String, listing: FolderListing) throws -> [ItemRecord] {
    try reconcile(folderID: folderID, listing: listing, listedAfter: .max)
  }

  /// Reconciles a listing requested when `latestChange` was `listedAfter`. Items written since
  /// are newer than the listing, so it neither changes nor deletes them, nor revives keys they left.
  public func reconcile(folderID: String, listing: FolderListing, listedAfter: Int64) throws
    -> [ItemRecord]
  {
    try database.transaction {
      guard let folder = try fetch(id: folderID), folder.isFolder else {
        throw ItemStoreError.notFound(folderID)
      }
      guard folder.key.utf8.elementsEqual(listing.path.prefix.utf8) else {
        throw ItemStoreError.listingMismatch(folder: folder.key, listing: listing.path.prefix)
      }
      let newer = try changedIDs(after: listedAfter)
      let vacated = try vacatedKeys(after: listedAfter)
      var listed = Set<String>()
      for entry in listing.folders + listing.files {
        let existing = try fetch(key: entry.key)
        if let existing, newer.contains(existing.id) {
          listed.insert(existing.id)
          continue
        }
        if existing == nil, vacated.contains(Array(entry.key.utf8)) { continue }
        var record = ItemRecord(
          id: existing?.id ?? UUID().uuidString, key: entry.key, parentID: folder.id,
          name: entry.name, isFolder: entry.kind == .folder)
        if !record.isFolder {
          record.size = entry.size
          record.modified = entry.lastModified
          if let existing, Self.isSameObject(existing, as: entry) { record.eTag = existing.eTag }
        }
        try place(record)
        listed.insert(record.id)
      }
      if !listing.isTruncated {
        for child in try childRecords(of: folder.id) where !listed.contains(child.id) {
          if try isNewer(child, in: newer) { continue }
          try delete(child)
        }
      }
      try database.run(
        "INSERT OR REPLACE INTO listings (folder_id, stamp) "
          + "VALUES (?, (SELECT COALESCE(MAX(stamp), 0) + 1 FROM listings))", [.text(folder.id)])
      return try childRecords(of: folder.id)
    }
  }

  public func upsert(_ record: ItemRecord) throws {
    try database.transaction { try place(record) }
  }

  public func move(id: String, toKey: String, parentID: String, name: String) throws {
    guard id != ItemRecord.rootID else { throw ItemStoreError.immutableRoot }
    try database.transaction {
      guard var record = try fetch(id: id) else { throw ItemStoreError.notFound(id) }
      record.key = toKey
      record.parentID = parentID
      record.name = name
      try place(record)
    }
  }

  public func remove(id: String) throws {
    guard id != ItemRecord.rootID else { throw ItemStoreError.immutableRoot }
    try database.transaction {
      guard let record = try fetch(id: id) else { throw ItemStoreError.notFound(id) }
      try delete(record)
    }
  }

  public func allRecords() -> [ItemRecord] { (try? records("ORDER BY key")) ?? [] }

  public func recentlyListedFolders(limit: Int) -> [ItemRecord] {
    let sql = "JOIN listings ON folder_id = id ORDER BY stamp DESC LIMIT ?"
    return (try? records(sql, [.integer(Int64(max(0, limit)))])) ?? []
  }

  public var latestChange: Int64 {
    (try? database.integer("SELECT COALESCE(MAX(seq), 0) FROM changes")) ?? 0
  }

  /// Updates carry each item's current state once; items deleted since are left to the
  /// deletion that follows in a later batch.
  public func changes(after: Int64, limit: Int) -> ChangeBatch {
    let empty = ChangeBatch(updated: [], deletedIDs: [], last: after, hasMore: false)
    return (try? changeBatch(after: after, limit: max(1, limit))) ?? empty
  }

  private func changeBatch(after: Int64, limit: Int) throws -> ChangeBatch {
    var events: [(sequence: Int64, id: String, deleted: Bool)] = []
    try database.query(
      "SELECT seq, item_id, deleted FROM changes WHERE seq > ? ORDER BY seq LIMIT ?",
      [.integer(after), .integer(Int64(limit))]
    ) { events.append(($0.integer(0), $0.text(1), $0.integer(2) != 0)) }
    guard let last = events.last?.sequence else {
      return ChangeBatch(updated: [], deletedIDs: [], last: after, hasMore: false)
    }
    var latest: [String: Int] = [:]
    for (index, event) in events.enumerated() { latest[event.id] = index }
    var updated: [ItemRecord] = []
    var deleted: [String] = []
    for (index, event) in events.enumerated() where latest[event.id] == index {
      if event.deleted {
        deleted.append(event.id)
      } else if let record = try fetch(id: event.id) {
        updated.append(record)
      }
    }
    let more = try database.integer(
      "SELECT EXISTS (SELECT 1 FROM changes WHERE seq > ?)", [.integer(last)])
    return ChangeBatch(updated: updated, deletedIDs: deleted, last: last, hasMore: more != 0)
  }

  /// Writes a record by id. A folder whose key changes carries its descendants' keys along
  /// (identifiers unchanged); any other item already holding one of the new keys is replaced.
  private func place(_ record: ItemRecord) throws {
    let existing = try fetch(id: record.id)
    guard existing != record else { return }
    try validate(record, existing: existing)
    var placed = [record]
    var previous: [String: ItemRecord] = [:]
    if let existing {
      previous[existing.id] = existing
      if existing.isFolder, !existing.key.utf8.elementsEqual(record.key.utf8) {
        let newPrefix = Array(record.key.utf8)
        for var descendant in try descendants(of: existing) {
          previous[descendant.id] = descendant
          descendant.key = String(
            decoding: newPrefix + descendant.key.utf8.dropFirst(existing.key.utf8.count),
            as: UTF8.self)
          placed.append(descendant)
        }
      }
    }
    guard previous[record.parentID] == nil else {
      throw ItemStoreError.invalidRecord("\(record.key) cannot be placed inside itself")
    }
    // Delete first so keys swapped within the moved subtree never collide mid-update.
    for id in previous.keys { try database.run("DELETE FROM items WHERE id = ?", [.text(id)]) }
    for item in placed {
      if let holder = try fetch(key: item.key) { try replace(holder, with: item.id) }
      try database.run(
        "INSERT INTO items (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", Self.values(item))
      let before = previous[item.id]
      guard before != item else { continue }
      let left = before.map(\.key).flatMap { $0.utf8.elementsEqual(item.key.utf8) ? nil : $0 }
      try log(item.id, vacated: left)
    }
  }

  /// Reparents the holder's children to `id`, then deletes the holder.
  private func replace(_ holder: ItemRecord, with id: String) throws {
    for child in try childRecords(of: holder.id) {
      try database.run("UPDATE items SET parent_id = ? WHERE id = ?", [.text(id), .text(child.id)])
      try log(child.id)
    }
    try deleteRow(holder)
  }

  private func delete(_ record: ItemRecord) throws {
    try deleteRow(record)
    if record.isFolder { for item in try descendants(of: record) { try deleteRow(item) } }
  }

  private func deleteRow(_ record: ItemRecord) throws {
    try database.run("DELETE FROM items WHERE id = ?", [.text(record.id)])
    try database.run("DELETE FROM listings WHERE folder_id = ?", [.text(record.id)])
    try log(record.id, deleted: true, vacated: record.key)
  }

  /// `vacated` is a key the change took the item away from, so stale listings do not revive it.
  private func log(_ id: String, deleted: Bool = false, vacated: String? = nil) throws {
    try database.run(
      "INSERT INTO changes (item_id, deleted, vacated) VALUES (?, ?, ?)",
      [.text(id), .integer(deleted ? 1 : 0), vacated.map { .blob(Array($0.utf8)) } ?? .null])
  }

  /// Listings carry no ETag, so a known one stays unless the size or a known date shows a
  /// rewrite. HEAD dates are whole seconds, and a fresh upload may not know its date yet.
  private static func isSameObject(_ known: ItemRecord, as entry: RemoteEntry) -> Bool {
    guard known.size == entry.size else { return false }
    guard let date = known.modified, let listed = entry.lastModified else { return true }
    let seconds = listed.timeIntervalSinceReferenceDate.rounded(.down)
    return date == listed || date.timeIntervalSinceReferenceDate == seconds
  }

  /// Whether the record or anything inside it changed after the listing was requested.
  private func isNewer(_ record: ItemRecord, in newer: Set<String>) throws -> Bool {
    guard !newer.isEmpty else { return false }
    return try newer.contains(record.id)
      || descendants(of: record).contains { newer.contains($0.id) }
  }

  private func changedIDs(after sequence: Int64) throws -> Set<String> {
    var ids = Set<String>()
    try database.query("SELECT item_id FROM changes WHERE seq > ?", [.integer(sequence)]) {
      ids.insert($0.text(0))
    }
    return ids
  }

  private func vacatedKeys(after sequence: Int64) throws -> Set<[UInt8]> {
    var keys = Set<[UInt8]>()
    try database.query(
      "SELECT vacated FROM changes WHERE seq > ? AND vacated IS NOT NULL", [.integer(sequence)]
    ) { keys.insert($0.bytes(0)) }
    return keys
  }

  /// Keys must follow the S3 delimiter tree: one name below the parent, folders ending in "/".
  private func validate(_ record: ItemRecord, existing: ItemRecord?) throws {
    if record.id == ItemRecord.rootID {
      guard record.key.isEmpty, record.parentID == ItemRecord.rootID, record.isFolder else {
        throw ItemStoreError.invalidRecord("the root must stay a folder with an empty key")
      }
      return
    }
    guard !record.id.isEmpty, record.parentID != record.id else {
      throw ItemStoreError.invalidRecord("\(record.key) needs its own identifier and a parent")
    }
    if let existing, existing.isFolder != record.isFolder {
      throw ItemStoreError.invalidRecord("\(record.key) cannot change between file and folder")
    }
    guard let parent = try fetch(id: record.parentID), parent.isFolder else {
      throw ItemStoreError.notFound(record.parentID)
    }
    let slash = UInt8(ascii: "/")
    guard record.key.utf8.starts(with: parent.key.utf8) else {
      throw ItemStoreError.invalidRecord("\(record.key) is not inside \(parent.key)")
    }
    var name = record.key.utf8.dropFirst(parent.key.utf8.count)
    if record.isFolder {
      guard name.last == slash else {
        throw ItemStoreError.invalidRecord("folder key \(record.key) must end with /")
      }
      name = name.dropLast()
    }
    guard !name.isEmpty, !name.contains(slash) else {
      throw ItemStoreError.invalidRecord("\(record.key) is not directly inside \(parent.key)")
    }
    guard name.elementsEqual(record.name.utf8) else {
      throw ItemStoreError.invalidRecord("\(record.name) is not the last part of \(record.key)")
    }
    // Taking over a folder that contains the item would delete the item along with it.
    if let existing, let holder = try fetch(key: record.key), holder.id != existing.id,
      holder.isFolder, existing.key.utf8.starts(with: holder.key.utf8)
    {
      throw ItemStoreError.invalidRecord("\(existing.key) cannot replace \(holder.key)")
    }
  }

  private func fetch(id: String) throws -> ItemRecord? {
    try records("WHERE id = ?", [.text(id)]).first
  }

  private func fetch(key: String) throws -> ItemRecord? {
    try records("WHERE key = ?", [.blob(Array(key.utf8))]).first
  }

  private func childRecords(of id: String) throws -> [ItemRecord] {
    try records("WHERE parent_id = ? AND id != parent_id ORDER BY key", [.text(id)])
  }

  /// Every key below a folder's prefix, found by a byte range on the key index.
  private func descendants(of folder: ItemRecord) throws -> [ItemRecord] {
    var upper = Array(folder.key.utf8)
    guard folder.isFolder, let last = upper.last, last < .max else { return [] }
    upper[upper.count - 1] = last + 1
    return try records(
      "WHERE key > ? AND key < ? ORDER BY key", [.blob(Array(folder.key.utf8)), .blob(upper)])
  }

  private func records(_ clause: String, _ values: [SQLiteValue] = []) throws -> [ItemRecord] {
    var result: [ItemRecord] = []
    try database.query("SELECT \(Self.columns) FROM items " + clause, values) { row in
      result.append(
        ItemRecord(
          id: row.text(0), key: row.text(1), parentID: row.text(2), name: row.text(3),
          isFolder: row.integer(4) != 0, size: row.isNull(5) ? nil : row.integer(5),
          eTag: row.isNull(6) ? nil : row.text(6),
          modified: row.isNull(7) ? nil : Date(timeIntervalSinceReferenceDate: row.real(7))))
    }
    return result
  }

  private static func values(_ record: ItemRecord) -> [SQLiteValue] {
    [
      .text(record.id), .blob(Array(record.key.utf8)), .text(record.parentID), .text(record.name),
      .integer(record.isFolder ? 1 : 0), record.size.map { .integer($0) } ?? .null,
      record.eTag.map { .text($0) } ?? .null,
      record.modified.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
    ]
  }
}

private enum SQLiteValue {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob([UInt8])
}

private struct SQLiteRow {
  let statement: OpaquePointer

  func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
  func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
  func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
  func text(_ column: Int32) -> String { String(decoding: bytes(column), as: UTF8.self) }

  func bytes(_ column: Int32) -> [UInt8] {
    let pointer = sqlite3_column_blob(statement, column)
    let count = Int(sqlite3_column_bytes(statement, column))
    guard let pointer, count > 0 else { return [] }
    return Array(UnsafeRawBufferPointer(start: pointer, count: count))
  }
}

private var transientDestructor: sqlite3_destructor_type {
  unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private final class SQLiteDatabase {
  private let handle: OpaquePointer

  init(path: String) throws {
    var handle: OpaquePointer?
    let status = sqlite3_open_v2(
      path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
      sqlite3_close_v2(handle)
      throw ItemStoreError.sqlite(code: status, message: message)
    }
    self.handle = handle
    sqlite3_busy_timeout(handle, 5_000)
  }

  deinit { sqlite3_close_v2(handle) }

  func execute(_ sql: String) throws { try check(sqlite3_exec(handle, sql, nil, nil, nil)) }

  func run(_ sql: String, _ values: [SQLiteValue] = []) throws { try query(sql, values) { _ in } }

  func integer(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64 {
    var value: Int64 = 0
    try query(sql, values) { value = $0.integer(0) }
    return value
  }

  func query(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
    var prepared: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &prepared, nil))
    defer { sqlite3_finalize(prepared) }
    guard let statement = prepared else { return }
    for (offset, value) in values.enumerated() {
      try check(bind(value, to: statement, at: Int32(offset + 1)))
    }
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw failure(status) }
      try row(SQLiteRow(statement: statement))
    }
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) -> Int32 {
    switch value {
    case .null: sqlite3_bind_null(statement, index)
    case .integer(let number): sqlite3_bind_int64(statement, index, number)
    case .real(let number): sqlite3_bind_double(statement, index, number)
    case .text(let text):
      text.withCString {
        sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transientDestructor)
      }
    // An empty buffer has no base address, which SQLite would bind as NULL.
    case .blob(let bytes) where bytes.isEmpty: sqlite3_bind_zeroblob(statement, index, 0)
    case .blob(let bytes):
      bytes.withUnsafeBytes {
        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transientDestructor)
      }
    }
  }

  private func check(_ status: Int32) throws {
    guard status == SQLITE_OK else { throw failure(status) }
  }

  private func failure(_ status: Int32) -> ItemStoreError {
    .sqlite(code: status, message: String(cString: sqlite3_errmsg(handle)))
  }
}
