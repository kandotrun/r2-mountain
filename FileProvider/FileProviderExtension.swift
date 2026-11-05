import FileProvider
import UniformTypeIdentifiers

/// Spike: proves signing, registration and Finder presentation before the real adapter.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
  private let domain: NSFileProviderDomain

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    super.init()
  }

  func invalidate() {}

  func item(
    for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    switch identifier {
    case .rootContainer: completionHandler(SpikeItem.root, nil)
    case SpikeItem.hello.itemIdentifier: completionHandler(SpikeItem.hello, nil)
    default: completionHandler(nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier))
    }
    return Progress()
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try Data("hello from S3 Mountain\n".utf8).write(to: url)
      completionHandler(url, SpikeItem.hello, nil)
    } catch {
      completionHandler(nil, nil, error)
    }
    return Progress()
  }

  func createItem(
    basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
  ) -> Progress {
    completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
    return Progress()
  }

  func modifyItem(
    _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields, contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
  ) -> Progress {
    completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
    return Progress()
  }

  func deleteItem(
    identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping ((any Error)?) -> Void
  ) -> Progress {
    completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
    return Progress()
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
  ) throws -> any NSFileProviderEnumerator {
    SpikeEnumerator(container: containerItemIdentifier)
  }
}

final class SpikeItem: NSObject, NSFileProviderItem, @unchecked Sendable {
  static let root = SpikeItem(id: .rootContainer, name: "drive", folder: true)
  static let hello = SpikeItem(id: NSFileProviderItemIdentifier("hello"), name: "hello.txt", folder: false)

  let itemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let isFolder: Bool

  init(id: NSFileProviderItemIdentifier, name: String, folder: Bool) {
    itemIdentifier = id
    filename = name
    isFolder = folder
  }

  var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
  var contentType: UTType { isFolder ? .folder : .plainText }
  var capabilities: NSFileProviderItemCapabilities {
    isFolder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
  }
  var documentSize: NSNumber? { isFolder ? nil : 23 }
  var itemVersion: NSFileProviderItemVersion {
    NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
  }
}

final class SpikeEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
  private let container: NSFileProviderItemIdentifier
  init(container: NSFileProviderItemIdentifier) { self.container = container }
  func invalidate() {}

  func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    if container == .rootContainer || container == .workingSet { observer.didEnumerate([SpikeItem.hello]) }
    observer.finishEnumerating(upTo: nil)
  }

  func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
  }
}
