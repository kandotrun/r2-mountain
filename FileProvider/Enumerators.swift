import FileProvider
import MountainCore

/// Sync anchors carry the store generation so a rebuilt store forces a full re-enumeration.
struct ChangeAnchor: Codable, Equatable {
  let generation: String
  let sequence: Int64

  var syncAnchor: NSFileProviderSyncAnchor {
    NSFileProviderSyncAnchor((try? JSONEncoder().encode(self)) ?? Data())
  }

  init(generation: String, sequence: Int64) {
    self.generation = generation
    self.sequence = sequence
  }

  init?(_ anchor: NSFileProviderSyncAnchor) {
    guard let decoded = try? JSONDecoder().decode(Self.self, from: anchor.rawValue) else {
      return nil
    }
    self = decoded
  }
}

/// Lists one folder from R2. In the replicated model only the working set reports changes.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
  private let service: MountService
  private let folder: NSFileProviderItemIdentifier

  init(service: MountService, folder: NSFileProviderItemIdentifier) {
    self.service = service
    self.folder = folder
  }

  func invalidate() {}

  func enumerateItems(
    for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    let observer = Unchecked(observer)
    let service = service
    let folder = folder
    Task {
      do {
        let record = try await service.record(folder)
        let children = try await service.listChildren(of: record)
        await service.touch(record.id)
        observer.value.didEnumerate(children.map(FileProviderItem.init))
        observer.value.finishEnumerating(upTo: nil)
      } catch {
        observer.value.finishEnumeratingWithError(MountService.fileProviderError(error))
      }
    }
  }

  func enumerateChanges(
    for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
  ) {
    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    let reply = Unchecked(completionHandler)
    let store = service.store
    Task {
      reply.value(
        ChangeAnchor(generation: await store.generation, sequence: await store.latestChange)
          .syncAnchor)
    }
  }
}

/// Everything the system keeps in sync, plus the change log since an anchor.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
  private let service: MountService

  init(service: MountService) {
    self.service = service
  }

  func invalidate() {}

  func enumerateItems(
    for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    let observer = Unchecked(observer)
    let store = service.store
    Task {
      let items = await store.allRecords().filter { $0.id != ItemRecord.rootID }
      for start in stride(from: 0, to: items.count, by: 200) {
        observer.value.didEnumerate(
          items[start..<min(start + 200, items.count)].map(FileProviderItem.init))
      }
      observer.value.finishEnumerating(upTo: nil)
    }
  }

  func enumerateChanges(
    for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
  ) {
    let observer = Unchecked(observer)
    let service = service
    Task {
      let store = service.store
      let generation = await store.generation
      guard let start = ChangeAnchor(anchor), start.generation == generation else {
        observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        return
      }
      await service.refreshFolders()
      let batch = await store.changes(after: start.sequence, limit: 500)
      if !batch.updated.isEmpty {
        observer.value.didUpdate(batch.updated.map(FileProviderItem.init))
      }
      if !batch.deletedIDs.isEmpty {
        observer.value.didDeleteItems(
          withIdentifiers: batch.deletedIDs.map { NSFileProviderItemIdentifier(recordID: $0) })
      }
      mountLog.info(
        "changes after \(start.sequence): \(batch.updated.count) updated, \(batch.deletedIDs.count) deleted"
      )
      let next = ChangeAnchor(generation: generation, sequence: max(start.sequence, batch.last))
      observer.value.finishEnumeratingChanges(upTo: next.syncAnchor, moreComing: batch.hasMore)
    }
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    let reply = Unchecked(completionHandler)
    let store = service.store
    Task {
      reply.value(
        ChangeAnchor(generation: await store.generation, sequence: await store.latestChange)
          .syncAnchor)
    }
  }
}
