import Foundation
import Testing

@testable import MountainCore

@Suite("Item store maps S3 keys to stable identifiers")
struct ItemStoreTests {
  @Test("The root exists from the start and is named after the bucket")
  func rootExists() async throws {
    let store = try makeItemStore(bucket: "drive")
    let root = ItemRecord(
      id: ItemRecord.rootID, key: "", parentID: ItemRecord.rootID, name: "drive", isFolder: true)
    #expect(await store.record(id: ItemRecord.rootID) == root)
    #expect(await store.record(key: "") == root)
    #expect(await store.children(of: ItemRecord.rootID).isEmpty)
    #expect(await store.allRecords() == [root])
    #expect(await store.latestChange == 0)
    #expect(UUID(uuidString: await store.generation) != nil)
    #expect(await store.generation != (try makeItemStore()).generation)
  }

  @Test("Reconciling assigns UUIDs once and returns the same identifiers again")
  func stableIdentifiers() async throws {
    let store = try makeItemStore()
    let entries = [folderEntry("photos/"), fileEntry("readme.txt", size: 12)]
    let first = try await store.list("", entries)
    #expect(Set(first.map(\.key)) == ["photos/", "readme.txt"])
    #expect(first.allSatisfy { UUID(uuidString: $0.id) != nil && $0.parentID == ItemRecord.rootID })
    let photos = try #require(first.first { $0.key == "photos/" })
    #expect(photos.isFolder && photos.name == "photos" && photos.size == nil)
    let readme = try #require(first.first { $0.key == "readme.txt" })
    #expect(!readme.isFolder && readme.size == 12 && readme.modified == itemDate)
    let logged = await store.latestChange
    let second = try await store.list("", entries)
    #expect(Set(second.map(\.id)) == Set(first.map(\.id)))
    #expect(await store.latestChange == logged)
    #expect(await store.changes(after: 0, limit: 10).updated.count == 2)
  }

  @Test("Children that vanish are deleted with all their descendants")
  func vanishedChildren() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), fileEntry("keep.txt")])
    try await store.list("a/", [folderEntry("a/b/"), fileEntry("a/x")])
    try await store.list("a/b/", [fileEntry("a/b/y")])
    let removed = try await store.ids(["a/", "a/b/", "a/x", "a/b/y"])
    let before = await store.latestChange
    let children = try await store.list("", [fileEntry("keep.txt")])
    #expect(children.map(\.key) == ["keep.txt"])
    for id in removed { #expect(await store.record(id: id) == nil) }
    let batch = await store.changes(after: before, limit: 10)
    #expect(Set(batch.deletedIDs) == Set(removed))
    #expect(batch.updated.isEmpty)
  }

  @Test("A truncated listing cannot prove absence, so nothing is deleted")
  func truncatedListingKeepsChildren() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("a.txt"), fileEntry("b.txt")])
    let before = await store.latestChange
    let children = try await store.list("", [fileEntry("c.txt")], truncated: true)
    #expect(children.map(\.key) == ["a.txt", "b.txt", "c.txt"])
    let batch = await store.changes(after: before, limit: 10)
    #expect(batch.deletedIDs.isEmpty)
    #expect(batch.updated.map(\.key) == ["c.txt"])
  }

  @Test("A known eTag survives listings that only add or refine the modification date")
  func eTagSurvivesDateRefinement() async throws {
    let store = try makeItemStore()
    func file(_ key: String, eTag: String, modified: Date?) -> ItemRecord {
      ItemRecord(
        id: UUID().uuidString, key: key, parentID: ItemRecord.rootID, name: key, isFolder: false,
        size: 5, eTag: eTag, modified: modified)
    }
    let wholeSecond = Date(
      timeIntervalSinceReferenceDate: itemDate.timeIntervalSinceReferenceDate.rounded(.down))
    try await store.upsert(file("uploaded.txt", eTag: "\"u\"", modified: nil))
    try await store.upsert(file("headed.txt", eTag: "\"h\"", modified: wholeSecond))
    try await store.upsert(file("stale.txt", eTag: "\"s\"", modified: itemDate))
    let before = await store.latestChange
    let rewritten = itemDate.addingTimeInterval(1)
    try await store.list(
      "",
      [
        fileEntry("uploaded.txt", size: 5), fileEntry("headed.txt", size: 5),
        fileEntry("stale.txt", size: 5, modified: rewritten),
      ])
    #expect(await store.record(key: "uploaded.txt")?.eTag == "\"u\"")
    #expect(await store.record(key: "uploaded.txt")?.modified == itemDate)
    #expect(await store.record(key: "headed.txt")?.eTag == "\"h\"")
    #expect(await store.record(key: "headed.txt")?.modified == itemDate)
    #expect(await store.record(key: "stale.txt")?.eTag == nil)
    let batch = await store.changes(after: before, limit: 10)
    #expect(Set(batch.updated.map(\.key)) == ["uploaded.txt", "headed.txt", "stale.txt"])
    try await store.list(
      "",
      [
        fileEntry("uploaded.txt", size: 5, modified: rewritten), fileEntry("headed.txt", size: 5),
        fileEntry("stale.txt", size: 5, modified: rewritten),
      ])
    #expect(await store.record(key: "uploaded.txt")?.eTag == nil)
    #expect(await store.record(key: "headed.txt")?.eTag == "\"h\"")
  }

  @Test("A listing requested before local writes neither undoes nor revives them")
  func staleListingKeepsLocalWrites() async throws {
    let store = try makeItemStore()
    try await store.list(
      "",
      [
        fileEntry("a.txt"), fileEntry("gone.txt"), fileEntry("old.txt"), fileEntry("remote.txt"),
        folderEntry("f/"),
      ])
    try await store.list("f/", [])
    let mark = await store.latestChange
    let renamed = try #require(await store.id("a.txt"))
    try await store.move(id: renamed, toKey: "b.txt", parentID: ItemRecord.rootID, name: "b.txt")
    try await store.remove(id: try #require(await store.id("gone.txt")))
    var overwritten = try #require(await store.record(key: "old.txt"))
    overwritten.size = 9
    overwritten.eTag = "\"new\""
    try await store.upsert(overwritten)
    let created = ItemRecord(
      id: UUID().uuidString, key: "new.txt", parentID: ItemRecord.rootID, name: "new.txt",
      isFolder: false, size: 2, eTag: "\"c\"")
    try await store.upsert(created)
    let folder = try #require(await store.id("f/"))
    let inside = ItemRecord(
      id: UUID().uuidString, key: "f/in.txt", parentID: folder, name: "in.txt", isFolder: false,
      size: 1, eTag: "\"i\"")
    try await store.upsert(inside)
    let remote = try #require(await store.id("remote.txt"))
    let before = await store.latestChange
    let stale = folderListing(
      "", [fileEntry("a.txt"), fileEntry("gone.txt"), fileEntry("old.txt")])
    let children = try await store.reconcile(
      folderID: ItemRecord.rootID, listing: stale, listedAfter: mark)
    #expect(children.map(\.key) == ["b.txt", "f/", "new.txt", "old.txt"])
    #expect(await store.record(id: renamed)?.key == "b.txt")
    #expect(await store.record(key: "a.txt") == nil)
    #expect(await store.record(key: "gone.txt") == nil)
    #expect(await store.record(key: "old.txt") == overwritten)
    #expect(await store.record(key: "new.txt") == created)
    #expect(await store.record(key: "f/in.txt") == inside)
    let batch = await store.changes(after: before, limit: 10)
    #expect(batch.deletedIDs == [remote] && batch.updated.isEmpty)
  }

  @Test("Changed files are logged as updates and unchanged ones are not")
  func changedFilesAreLogged() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("a.txt", size: 1), fileEntry("b.txt", size: 1)])
    let id = try #require(await store.id("a.txt"))
    var tagged = try #require(await store.record(id: id))
    tagged.eTag = "\"v1\""
    try await store.upsert(tagged)
    let before = await store.latestChange
    try await store.list("", [fileEntry("a.txt", size: 1), fileEntry("b.txt", size: 1)])
    #expect(await store.latestChange == before)
    #expect(await store.record(id: id)?.eTag == "\"v1\"")
    let later = itemDate.addingTimeInterval(60)
    try await store.list("", [fileEntry("a.txt", size: 2, modified: later), fileEntry("b.txt")])
    let batch = await store.changes(after: before, limit: 10)
    #expect(batch.updated.map(\.id) == [id])
    #expect(batch.updated.first?.size == 2 && batch.updated.first?.modified == later)
    #expect(batch.updated.first?.eTag == nil)
  }

  @Test("Upsert logs changed records, skips identical ones and keeps eTags")
  func upsertLogsChanges() async throws {
    let store = try makeItemStore()
    let file = ItemRecord(
      id: UUID().uuidString, key: "new.txt", parentID: ItemRecord.rootID, name: "new.txt",
      isFolder: false, size: 3, eTag: "\"e1\"", modified: itemDate)
    try await store.upsert(file)
    #expect(await store.record(key: "new.txt") == file)
    #expect(await store.latestChange == 1)
    try await store.upsert(file)
    #expect(await store.latestChange == 1)
    var edited = file
    edited.eTag = "\"e2\""
    try await store.upsert(edited)
    #expect(await store.changes(after: 1, limit: 10).updated == [edited])
  }

  @Test("NFC and NFD spellings are different items")
  func normalizationFormsStayDistinct() async throws {
    let store = try makeItemStore()
    let composed = "Caf\u{E9}.txt"
    let decomposed = "Cafe\u{301}.txt"
    let children = try await store.list("", [fileEntry(composed), fileEntry(decomposed)])
    #expect(children.count == 2)
    let nfc = try #require(await store.record(key: composed))
    let nfd = try #require(await store.record(key: decomposed))
    #expect(nfc.id != nfd.id)
    #expect(Array(nfc.key.utf8) == Array(composed.utf8))
    #expect(Array(nfd.key.utf8) == Array(decomposed.utf8))
    #expect(nfc != nfd)
    let again = try await store.list("", [fileEntry(decomposed)])
    #expect(again.map(\.id) == [nfd.id])
    #expect(await store.record(key: composed) == nil)
  }

  @Test("Moving a folder rewrites descendant key prefixes and keeps identifiers")
  func moveFolder() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), folderEntry("dest/")])
    try await store.list("a/", [folderEntry("a/b/"), fileEntry("a/x")])
    try await store.list("a/b/", [fileEntry("a/b/y")])
    let ids = try await store.ids(["a/", "a/b/", "a/x", "a/b/y"])
    let dest = try #require(await store.id("dest/"))
    let before = await store.latestChange
    let renamed = "dest/Cafe\u{301}/"
    try await store.move(id: ids[0], toKey: renamed, parentID: dest, name: "Cafe\u{301}")
    let moved = try #require(await store.record(id: ids[0]))
    #expect(Array(moved.key.utf8) == Array(renamed.utf8))
    #expect(moved.parentID == dest && moved.name == "Cafe\u{301}")
    #expect(await store.record(id: ids[1])?.key == renamed + "b/")
    #expect(await store.record(id: ids[2])?.key == renamed + "x")
    #expect(await store.record(id: ids[3])?.key == renamed + "b/y")
    #expect(await store.record(id: ids[3])?.parentID == ids[1])
    #expect(await store.record(key: "a/b/y") == nil)
    #expect(await store.children(of: dest).map(\.id) == [ids[0]])
    let batch = await store.changes(after: before, limit: 10)
    #expect(Set(batch.updated.map(\.id)) == Set(ids))
    #expect(batch.deletedIDs.isEmpty)
  }

  @Test("Moving between NFC and NFD spellings is a real change")
  func moveChangesNormalization() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("Caf\u{E9}.txt")])
    let id = try #require(await store.id("Caf\u{E9}.txt"))
    try await store.move(
      id: id, toKey: "Cafe\u{301}.txt", parentID: ItemRecord.rootID, name: "Cafe\u{301}.txt")
    #expect(await store.record(key: "Caf\u{E9}.txt") == nil)
    #expect(await store.record(key: "Cafe\u{301}.txt")?.id == id)
    #expect(await store.latestChange == 2)
  }

  @Test("Moving onto an existing key replaces that item")
  func moveReplacesDestination() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), folderEntry("b/")])
    try await store.list("a/", [fileEntry("a/same"), fileEntry("a/only-a")])
    try await store.list("b/", [fileEntry("b/same"), fileEntry("b/only-b")])
    let a = try #require(await store.id("a/"))
    let replacedFolder = try #require(await store.id("b/"))
    let replacedFile = try #require(await store.id("b/same"))
    let onlyB = try #require(await store.id("b/only-b"))
    let movedFile = try #require(await store.id("a/same"))
    let before = await store.latestChange
    try await store.move(id: a, toKey: "b/", parentID: ItemRecord.rootID, name: "b")
    #expect(await store.record(key: "b/")?.id == a)
    #expect(await store.record(key: "b/same")?.id == movedFile)
    #expect(await store.record(key: "b/only-b")?.parentID == a)
    #expect(Set(await store.children(of: a).map(\.key)) == ["b/same", "b/only-a", "b/only-b"])
    let batch = await store.changes(after: before, limit: 20)
    #expect(Set(batch.deletedIDs) == [replacedFolder, replacedFile])
    #expect(batch.updated.contains { $0.id == onlyB })
  }

  @Test("Every batch of a replacing move leaves the system a consistent tree")
  func replacingMoveIsConsistentInEveryBatch() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), folderEntry("b/")])
    try await store.list("a/", [folderEntry("a/s/"), fileEntry("a/same"), fileEntry("a/only-a")])
    try await store.list("a/s/", [fileEntry("a/s/x")])
    try await store.list("b/", [folderEntry("b/s/"), fileEntry("b/same"), fileEntry("b/only-b")])
    try await store.list("b/s/", [fileEntry("b/s/y")])
    let replica = ItemReplica(await store.allRecords())
    let before = await store.latestChange
    let a = try #require(await store.id("a/"))
    try await store.move(id: a, toKey: "b/", parentID: ItemRecord.rootID, name: "b")
    #expect(await store.children(of: a).map(\.key) == ["b/only-a", "b/only-b", "b/s/", "b/same"])
    #expect(await store.children(of: try #require(await store.id("b/s/"))).count == 2)
    let final = await store.allRecords()
    let start = ItemReplica(final.filter { $0.id == ItemRecord.rootID })
    for limit in 1...4 {
      for (replica, anchor) in [(replica, before), (start, 0)] {
        let states = await replayStates(of: store, from: replica, after: anchor, limit: limit)
        for state in states {
          #expect(state.collisions.isEmpty, "limit \(limit) after \(anchor)")
          #expect(state.orphans.isEmpty, "limit \(limit) after \(anchor)")
        }
        #expect(states.last?.records == final, "limit \(limit) after \(anchor)")
      }
    }
  }

  @Test("Moves that break the tree are rejected")
  func invalidMoves() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), fileEntry("f")])
    try await store.list("a/", [folderEntry("a/b/")])
    let a = try #require(await store.id("a/"))
    let b = try #require(await store.id("a/b/"))
    let f = try #require(await store.id("f"))
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: a, toKey: "a/b/a/", parentID: b, name: "a")
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: f, toKey: "x/f", parentID: ItemRecord.rootID, name: "f")
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: a, toKey: "c", parentID: ItemRecord.rootID, name: "c")
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: "missing", toKey: "m", parentID: ItemRecord.rootID, name: "m")
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: f, toKey: "g", parentID: ItemRecord.rootID, name: "h")
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(
        id: f, toKey: "Cafe\u{301}", parentID: ItemRecord.rootID, name: "Caf\u{E9}")
    }
    #expect(await store.record(id: a)?.key == "a/")
    #expect(await store.record(id: f)?.key == "f")
  }

  @Test("A folder cannot take over the key of a folder that contains it")
  func moveOntoAncestorIsRejected() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("c/")])
    try await store.list("c/", [folderEntry("c/a/")])
    try await store.list("c/a/", [folderEntry("c/a/a/"), fileEntry("c/a/Caf\u{E9}")])
    try await store.list("c/a/a/", [folderEntry("c/a/a/b/")])
    let c = try #require(await store.id("c/"))
    let inner = try #require(await store.record(key: "c/a/a/"))
    let deep = try #require(await store.record(key: "c/a/a/b/"))
    let records = await store.allRecords()
    let before = await store.latestChange
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: inner.id, toKey: "c/a/", parentID: c, name: "a")
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: deep.id, toKey: "c/", parentID: ItemRecord.rootID, name: "c")
    }
    var lifted = inner
    lifted.key = "c/a/"
    lifted.parentID = c
    await #expect(throws: ItemStoreError.self) { try await store.upsert(lifted) }
    #expect(await store.allRecords() == records)
    #expect(await store.latestChange == before)
  }

  @Test("Removing deletes descendants and logs each deletion")
  func removeRecursively() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), folderEntry("ab/")])
    try await store.list("a/", [folderEntry("a/b/"), fileEntry("a/x")])
    try await store.list("a/b/", [fileEntry("a/b/y")])
    let ids = try await store.ids(["a/", "a/b/", "a/x", "a/b/y"])
    let before = await store.latestChange
    try await store.remove(id: ids[0])
    for id in ids { #expect(await store.record(id: id) == nil) }
    #expect(await store.allRecords().map(\.key) == ["", "ab/"])
    #expect(Set(await store.changes(after: before, limit: 10).deletedIDs) == Set(ids))
    await #expect(throws: ItemStoreError.self) { try await store.remove(id: ids[0]) }
  }

  @Test("The root can be neither removed nor moved")
  func rootIsProtected() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/")])
    let a = try #require(await store.id("a/"))
    await #expect(throws: ItemStoreError.self) { try await store.remove(id: ItemRecord.rootID) }
    await #expect(throws: ItemStoreError.self) {
      try await store.move(id: ItemRecord.rootID, toKey: "a/r/", parentID: a, name: "r")
    }
    #expect(await store.record(id: ItemRecord.rootID)?.key == "")
  }

  @Test("Upsert rejects records that do not fit the tree")
  func upsertValidates() async throws {
    let store = try makeItemStore()
    func file(_ key: String, parent: String = ItemRecord.rootID, folder: Bool = false)
      -> ItemRecord
    {
      ItemRecord(
        id: UUID().uuidString, key: key, parentID: parent, name: entryName(key), isFolder: folder)
    }
    var renamed = file("a.txt")
    renamed.name = "zzz.txt"
    var normalized = file("Cafe\u{301}/", folder: true)
    normalized.name = "Caf\u{E9}"
    for invalid in [
      file("x", parent: "missing"), file("folder", folder: true), file("file/"), file(""),
      ItemRecord(
        id: ItemRecord.rootID, key: "r/", parentID: ItemRecord.rootID, name: "r", isFolder: true),
      renamed, normalized,
    ] {
      await #expect(throws: ItemStoreError.self) { try await store.upsert(invalid) }
    }
    #expect(await store.latestChange == 0)
  }

  @Test("Upserting a key held by another identifier replaces the old item")
  func upsertReplacesKeyHolder() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("dup.txt")])
    let old = try #require(await store.id("dup.txt"))
    let fresh = ItemRecord(
      id: UUID().uuidString, key: "dup.txt", parentID: ItemRecord.rootID, name: "dup.txt",
      isFolder: false, size: 5, eTag: "\"n\"", modified: itemDate)
    let before = await store.latestChange
    try await store.upsert(fresh)
    #expect(await store.record(key: "dup.txt") == fresh)
    #expect(await store.record(id: old) == nil)
    let batch = await store.changes(after: before, limit: 10)
    #expect(batch.deletedIDs == [old] && batch.updated == [fresh])
  }

  @Test("Reconciling needs an existing folder that matches the listing")
  func reconcileValidatesFolder() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), fileEntry("f")])
    let a = try #require(await store.id("a/"))
    let f = try #require(await store.id("f"))
    await #expect(throws: ItemStoreError.self) {
      try await store.reconcile(folderID: a, listing: folderListing("b/", []))
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.reconcile(folderID: f, listing: folderListing("", []))
    }
    await #expect(throws: ItemStoreError.self) {
      try await store.reconcile(folderID: "missing", listing: folderListing("", []))
    }
  }

  @Test("Recently listed folders come most recent first")
  func recentlyListed() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), folderEntry("b/")])
    try await store.list("a/", [])
    try await store.list("b/", [])
    #expect(await store.recentlyListedFolders(limit: 5).map(\.key) == ["b/", "a/", ""])
    try await store.list("a/", [])
    #expect(await store.recentlyListedFolders(limit: 2).map(\.key) == ["a/", "b/"])
    try await store.list("", [folderEntry("a/")])
    #expect(await store.recentlyListedFolders(limit: 5).map(\.key) == ["", "a/"])
  }

  @Test("Recently listed folders follow moves and forget folders that are gone")
  func recentlyListedFollowsTree() async throws {
    let store = try makeItemStore()
    try await store.list("", [folderEntry("a/"), folderEntry("b/"), folderEntry("c/")])
    try await store.list("a/", [])
    try await store.list("b/", [folderEntry("b/in/")])
    try await store.list("b/in/", [])
    try await store.list("c/", [])
    let a = try #require(await store.id("a/"))
    try await store.move(id: a, toKey: "z/", parentID: ItemRecord.rootID, name: "z")
    try await store.remove(id: try #require(await store.id("b/")))
    #expect(await store.recentlyListedFolders(limit: 10).map(\.key) == ["c/", "z/", ""])
    try await store.list("", [folderEntry("z/")])
    #expect(await store.recentlyListedFolders(limit: 10).map(\.id) == [ItemRecord.rootID, a])
  }

  @Test("Store errors read as Japanese messages")
  func errorsAreLocalized() async throws {
    let store = try makeItemStore()
    let missing = await #expect(throws: ItemStoreError.self) { try await store.remove(id: "x") }
    #expect(missing?.localizedDescription == "項目が見つかりません。")
    let root = await #expect(throws: ItemStoreError.self) {
      try await store.remove(id: ItemRecord.rootID)
    }
    #expect(root?.localizedDescription == "バケットの最上位は移動も削除もできません。")
  }
}

@Suite("Item store change log")
struct ItemStoreChangeTests {
  @Test("Changes come in sequence order with paging")
  func paging() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("1"), fileEntry("2"), fileEntry("3")])
    #expect(await store.latestChange == 3)
    let first = await store.changes(after: 0, limit: 2)
    #expect(first.updated.map(\.key) == ["1", "2"])
    #expect(first.last == 2 && first.hasMore)
    let second = await store.changes(after: first.last, limit: 2)
    #expect(second.updated.map(\.key) == ["3"])
    #expect(second.last == 3 && !second.hasMore)
    let empty = await store.changes(after: 3, limit: 2)
    #expect(empty == ChangeBatch(updated: [], deletedIDs: [], last: 3, hasMore: false))
  }

  @Test("Updates are deduplicated to the latest state and later deletions win")
  func deduplication() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("a", size: 1), fileEntry("b")])
    try await store.list("", [fileEntry("a", size: 2), fileEntry("b")])
    let a = try #require(await store.id("a"))
    let b = try #require(await store.id("b"))
    let all = await store.changes(after: 0, limit: 10)
    #expect(all.updated.map(\.key) == ["b", "a"])
    #expect(all.updated.last?.size == 2)
    try await store.remove(id: b)
    let afterDelete = await store.changes(after: 0, limit: 10)
    #expect(afterDelete.updated.map(\.id) == [a])
    #expect(afterDelete.deletedIDs == [b])
    #expect(afterDelete.last == 4)
    let window = await store.changes(after: 0, limit: 2)
    #expect(window.updated.map(\.id) == [a])
    #expect(window.deletedIDs.isEmpty && window.hasMore && window.last == 2)
  }

  @Test("Deletions are reported in sequence order")
  func deletionOrder() async throws {
    let store = try makeItemStore()
    try await store.list("", [fileEntry("a"), fileEntry("b"), fileEntry("c")])
    let ids = try await store.ids(["c", "a", "b"])
    for id in ids { try await store.remove(id: id) }
    #expect(await store.changes(after: 3, limit: 10).deletedIDs == ids)
  }
}

@Suite("Item store persistence")
struct ItemStorePersistenceTests {
  @Test("Reopening a store file keeps identifiers, generation and history")
  func reopen() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Mount/drive/items.sqlite")
    let first = try ItemStore(url: url, bucket: "drive")
    try await first.list("", [folderEntry("a/"), fileEntry("Cafe\u{301}.txt")])
    try await first.list("a/", [fileEntry("a/x")])
    let records = await first.allRecords()
    let generation = await first.generation
    let history = await first.changes(after: 0, limit: 100)
    let reopened = try ItemStore(url: url, bucket: "drive")
    #expect(await reopened.allRecords() == records)
    #expect(keyBytes(await reopened.allRecords()) == keyBytes(records))
    #expect(await reopened.generation == generation)
    #expect(await reopened.changes(after: 0, limit: 100) == history)
    #expect(await reopened.latestChange == 3)
    #expect(await reopened.recentlyListedFolders(limit: 5).map(\.key) == ["a/", ""])
    let renamed = try ItemStore(url: url, bucket: "other")
    #expect(await renamed.record(id: ItemRecord.rootID)?.name == "other")
    #expect(await renamed.generation == generation)
  }
}
