import FileProvider
import MountainCore
import UniformTypeIdentifiers

/// Bridges File Provider calls to MountainCore. Logic lives in the core package.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable
{
  private let service: Result<MountService, any Error>

  required init(domain: NSFileProviderDomain) {
    let domain = Unchecked(domain)
    service = Result { try MountService(domain: domain) }
    super.init()
  }

  func invalidate() {}

  private func mount() throws -> MountService { try service.get() }

  private static var cancelled: NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
  }

  /// Cancelling the returned progress stops the work and answers once with NSUserCancelledError.
  private func perform(
    _ progress: Progress, once: Once, onCancel: @escaping @Sendable () -> Void,
    work: @escaping @Sendable () async -> Void
  ) -> Progress {
    let task = Task { await work() }
    progress.cancellationHandler = {
      task.cancel()
      once.run(onCancel)
    }
    return progress
  }

  // MARK: Items

  func item(
    for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let reply = Unchecked(completionHandler)
    let once = Once()
    let progress = Progress(totalUnitCount: 1)
    return perform(
      progress, once: once, onCancel: { reply.value(nil, Self.cancelled) },
      work: {
        do {
          let record = try await self.mount().record(identifier)
          once.run { reply.value(FileProviderItem(record), nil) }
        } catch {
          once.run { reply.value(nil, MountService.fileProviderError(error)) }
        }
        progress.completedUnitCount = 1
      })
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
  ) throws -> any NSFileProviderEnumerator {
    let service: MountService
    do { service = try mount() } catch { throw MountService.fileProviderError(error) }
    if containerItemIdentifier == .workingSet { return WorkingSetEnumerator(service: service) }
    if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
    return FolderEnumerator(service: service, folder: containerItemIdentifier)
  }

  // MARK: Download

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let reply = Unchecked(completionHandler)
    let once = Once()
    let progress = Progress(totalUnitCount: 100)
    return perform(
      progress, once: once, onCancel: { reply.value(nil, nil, Self.cancelled) },
      work: {
        do {
          let service = try self.mount()
          let record = try await service.record(itemIdentifier)
          guard !record.isFolder else { throw MountError.notFound }
          let total = max(1, record.size ?? 1)
          progress.totalUnitCount = total
          let destination = try await service.temporaryFile()
          let metadata = try await service.current().client.download(
            key: record.key, to: destination
          ) {
            progress.completedUnitCount = min(total, $0)
          }
          // Only the content facts change, and only if nothing moved or replaced the item meanwhile.
          var latest = await service.store.record(id: record.id) ?? record
          if latest.key.utf8.elementsEqual(record.key.utf8),
            latest.eTag != metadata.eTag || latest.size != metadata.size
          {
            latest.eTag = metadata.eTag
            latest.size = metadata.size
            if let date = metadata.lastModified { latest.modified = date }
            try? await service.store.upsert(latest)
          }
          once.run { reply.value(destination, FileProviderItem(latest), nil) }
        } catch {
          once.run { reply.value(nil, nil, MountService.fileProviderError(error)) }
        }
      })
  }

  // MARK: Create

  func createItem(
    basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
  ) -> Progress {
    let reply = Unchecked(completionHandler)
    let template = Unchecked(itemTemplate)
    let once = Once()
    let progress = Progress(totalUnitCount: max(1, itemTemplate.documentSize??.int64Value ?? 1))
    let mayExist = options.contains(.mayAlreadyExist)
    return perform(
      progress, once: once, onCancel: { reply.value(nil, [], false, Self.cancelled) },
      work: {
        do {
          let service = try self.mount()
          if template.value.contentType?.conforms(to: .symbolicLink) == true {
            throw MountService.permanentlyUnsupported
          }
          let waited = try await service.record(template.value.parentItemIdentifier)
          await service.waitUntilFree(waited.key)
          // The parent may have been moved while we waited.
          let parent = try await service.record(template.value.parentItemIdentifier)
          guard parent.isFolder else { throw MountError.notFound }
          let name = try Self.remoteName(template.value.filename)
          // Packages such as .app bundles are directories too.
          let isFolder = template.value.contentType?.conforms(to: .directory) == true
          let key = parent.key + name + (isFolder ? "/" : "")
          let existing = await service.store.record(key: key)
          let remote = try await service.current()
          let record: ItemRecord
          if isFolder {
            try await remote.operations.createFolder(key: key)
            record =
              existing
              ?? ItemRecord(
                id: UUID().uuidString, key: key, parentID: parent.id, name: name, isFolder: true)
          } else if mayExist, url == nil {
            // Reimport of a dataless file: only an object R2 already holds can match it.
            guard let existing else {
              once.run { reply.value(nil, [], false, nil) }
              return
            }
            record = existing
          } else if mayExist, let existing, let url, Self.fileSize(url) == existing.size {
            // Reimport of content that matches what R2 holds.
            record = existing
          } else {
            let file: URL
            if let url { file = url } else { file = try await Self.emptyFile(service: service) }
            let uploaded: UploadedObject
            do {
              uploaded = try await remote.uploader.upload(
                file: file, key: key, journalID: template.value.itemIdentifier.rawValue,
                overwrite: mayExist && existing != nil
              ) { progress.completedUnitCount = $0 }
            } catch MountError.alreadyExists {
              throw await service.collision(at: key, in: parent)
            }
            record = ItemRecord(
              id: existing?.id ?? UUID().uuidString, key: key, parentID: parent.id, name: name,
              // A local date would look like a remote change to the next listing and drop the
              // ETag, so the server's own date is used.
              isFolder: false, size: uploaded.size, eTag: uploaded.eTag,
              modified: await service.serverDate(for: key))
          }
          try await service.store.upsert(record)
          await service.touch(parent.id)
          once.run { reply.value(FileProviderItem(record), [], false, nil) }
          if isFolder {
            // The system never lists folders it created itself; list once so later refreshes
            // pick up changes made on R2 inside it.
            _ = try? await service.listChildren(of: record)
          } else {
            service.evictSoon(NSFileProviderItemIdentifier(recordID: record.id))
          }
        } catch {
          once.run { reply.value(nil, [], false, MountService.fileProviderError(error)) }
        }
      })
  }

  // MARK: Modify

  func modifyItem(
    _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields, contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
  ) -> Progress {
    let reply = Unchecked(completionHandler)
    let item = Unchecked(item)
    let once = Once()
    let progress = Progress(totalUnitCount: 100)
    let contentVersion = version.contentVersion.map { String(format: "%02x", $0) }.joined()
    return perform(
      progress, once: once, onCancel: { reply.value(nil, [], false, Self.cancelled) },
      work: {
        do {
          let service = try self.mount()
          let waited = try await service.record(item.value.itemIdentifier)
          guard waited.id != ItemRecord.rootID, item.value.parentItemIdentifier != .trashContainer
          else {
            throw MountService.permanentlyUnsupported
          }
          await service.waitUntilFree(waited.key)
          var record = try await service.record(item.value.itemIdentifier)
          if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            record = try await Self.move(
              record, to: item.value, service: service, progress: progress)
          }
          var uploaded = false
          if changedFields.contains(.contents), !record.isFolder, let newContents {
            progress.totalUnitCount = max(1, Self.fileSize(newContents) ?? 1)
            let result = try await service.current().uploader.upload(
              file: newContents, key: record.key, journalID: "\(record.id)-\(contentVersion)",
              overwrite: true
            ) { progress.completedUnitCount = $0 }
            record.size = result.size
            record.eTag = result.eTag
            record.modified = await service.serverDate(for: record.key)
            try await service.store.upsert(record)
            uploaded = true
          }
          await service.touch(record.parentID)
          // Dates, tags and other local metadata are not stored on R2.
          once.run { reply.value(FileProviderItem(record), [], false, nil) }
          if uploaded { service.evictSoon(item.value.itemIdentifier) }
        } catch {
          once.run { reply.value(nil, [], false, MountService.fileProviderError(error)) }
        }
      })
  }

  /// R2 has no rename: objects are copied to the new key, then the originals are deleted.
  /// A target that already exists, here or on R2, is refused instead of merged.
  private static func move(
    _ record: ItemRecord, to item: NSFileProviderItem, service: MountService, progress: Progress
  ) async throws -> ItemRecord {
    let waited = try await service.record(item.parentItemIdentifier)
    await service.waitUntilFree(waited.key)
    let parent = try await service.record(item.parentItemIdentifier)
    guard parent.isFolder else { throw MountError.notFound }
    let name = try remoteName(item.filename)
    let key = parent.key + name + (record.isFolder ? "/" : "")
    guard !key.utf8.elementsEqual(record.key.utf8) else { return record }
    if record.isFolder, key.utf8.starts(with: record.key.utf8) {
      throw MountService.permanentlyUnsupported
    }
    let remote = try await service.current()
    if !(await service.isResumingMove(id: record.id, from: record.key, to: key)) {
      if let holder = await service.store.record(key: key), holder.id != record.id {
        throw MountService.Collision(holder: holder)
      }
      if try await exists(key: key, folder: record.isFolder, client: remote.client) {
        throw await service.collision(at: key, in: parent)
      }
      try await service.beginMove(id: record.id, from: record.key, to: key)
    }
    let prefixes = record.isFolder ? [record.key, key] : []
    await service.lock(prefixes)
    var newETag: String?
    do {
      if record.isFolder {
        try await remote.operations.moveFolder(from: record.key, to: key) { done, total in
          progress.totalUnitCount = Int64(max(1, total))
          progress.completedUnitCount = Int64(done)
        }
      } else {
        newETag = try await remote.operations.moveObject(
          from: record.key, to: key, size: record.size ?? 0)
      }
      try await service.store.move(id: record.id, toKey: key, parentID: parent.id, name: name)
    } catch {
      await service.unlock(prefixes)
      throw error
    }
    await service.unlock(prefixes)
    await service.endMove(id: record.id)
    guard var moved = await service.store.record(id: record.id) else { throw MountError.notFound }
    if !record.isFolder {
      // The copy has its own date; keeping it lets later listings keep the ETag.
      moved.eTag = newETag ?? moved.eTag
      moved.modified = await service.serverDate(for: key) ?? moved.modified
      try await service.store.upsert(moved)
    }
    await service.touch(parent.id)
    return moved
  }

  private static func exists(key: String, folder: Bool, client: S3Client) async throws -> Bool {
    if try await client.head(key: key) != nil { return true }
    guard folder, let path = FolderPath(prefix: key) else { return false }
    let listing = try await client.listFolder(path, pageLimit: 1)
    return !listing.folders.isEmpty || !listing.files.isEmpty
  }

  // MARK: Delete

  func deleteItem(
    identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping ((any Error)?) -> Void
  ) -> Progress {
    let reply = Unchecked(completionHandler)
    let once = Once()
    let recursive = options.contains(.recursive)
    let progress = Progress(totalUnitCount: 1)
    return perform(
      progress, once: once, onCancel: { reply.value(Self.cancelled) },
      work: {
        do {
          let service = try self.mount()
          guard let waited = await service.store.record(id: identifier.recordID) else {
            once.run { reply.value(nil) }
            return
          }
          guard waited.id != ItemRecord.rootID else { throw MountService.permanentlyUnsupported }
          await service.waitUntilFree(waited.key)
          guard let record = await service.store.record(id: waited.id) else {
            once.run { reply.value(nil) }
            return
          }
          let remote = try await service.current()
          if record.isFolder {
            await service.lock([record.key])
            do {
              try await Self.deleteFolder(
                record, recursive: recursive, service: service, remote: remote)
              try await service.store.remove(id: record.id)
            } catch {
              await service.unlock([record.key])
              throw error
            }
            await service.unlock([record.key])
          } else {
            try await remote.operations.deleteObject(key: record.key)
            try await service.store.remove(id: record.id)
          }
          progress.completedUnitCount = 1
          once.run { reply.value(nil) }
        } catch {
          once.run { reply.value(MountService.fileProviderError(error)) }
        }
      })
  }

  /// Deletes only what Finder could have shown. Anything new on R2 sends the folder back with its
  /// contents instead of being removed unseen.
  private static func deleteFolder(
    _ record: ItemRecord, recursive: Bool, service: MountService, remote: MountService.Remote
  ) async throws {
    let known = await service.knownDescendants(of: record)
    if !recursive {
      // The system believes the folder is empty; R2 is the source of truth.
      if !(try await service.listChildren(of: record)).isEmpty {
        service.signalWorkingSet()
        throw NSFileProviderError(.directoryNotEmpty)
      }
    } else {
      let objects = try await remote.client.listAll(prefix: record.key)
      // Objects inside folders that were never opened are part of what the user deleted;
      // objects missing from a folder Finder did list are new since then.
      let unseenParents = Set(
        objects.compactMap { object -> String? in
          guard !known.keys.contains(Data(object.key.utf8)) else { return nil }
          let parent = parentPrefix(of: object.key)
          return known.listedFolders.contains(Data(parent.utf8)) ? parent : nil
        })
      if !unseenParents.isEmpty {
        for prefix in unseenParents {
          if let folder = await service.store.record(key: prefix) {
            _ = try? await service.listChildren(of: folder)
          }
        }
        service.signalWorkingSet()
        throw NSFileProviderError(.directoryNotEmpty)
      }
    }
    try await remote.operations.deleteFolder(prefix: record.key)
  }

  // MARK: Helpers

  /// Finder names become key components: NFC like phase 1 uploads, never containing "/".
  private static func remoteName(_ filename: String) throws -> String {
    let name = filename.precomposedStringWithCanonicalMapping
    guard !name.isEmpty, name != ".", name != "..", !name.unicodeScalars.contains("/") else {
      throw MountError.invalidName
    }
    return name
  }

  /// "a/b/c.txt" -> "a/b/", "a/b/" -> "a/", "c.txt" -> "".
  private static func parentPrefix(of key: String) -> String {
    var scalars = Array(key.unicodeScalars)
    if scalars.last == "/" { scalars.removeLast() }
    guard let slash = scalars.lastIndex(of: "/") else { return "" }
    var parent = String.UnicodeScalarView()
    parent.append(contentsOf: scalars[...slash])
    return String(parent)
  }

  private static func fileSize(_ url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }

  private static func emptyFile(service: MountService) async throws -> URL {
    let file = try await service.temporaryFile()
    try Data().write(to: file)
    return file
  }
}
