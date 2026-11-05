import FileProvider
import MountainCore
import UniformTypeIdentifiers

/// A bucket object or folder as Finder sees it.
final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
  let record: ItemRecord

  init(_ record: ItemRecord) {
    self.record = record
  }

  var itemIdentifier: NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(recordID: record.id)
  }

  var parentItemIdentifier: NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(recordID: record.parentID)
  }

  // The system rejects items without a name, the root included.
  var filename: String { record.name.isEmpty ? record.key : record.name }

  var contentType: UTType {
    if record.isFolder { return .folder }
    return UTType(filenameExtension: (record.name as NSString).pathExtension) ?? .data
  }

  var capabilities: NSFileProviderItemCapabilities {
    if record.id == ItemRecord.rootID { return [.allowsContentEnumerating, .allowsAddingSubItems] }
    // No trashing: deleting asks once and removes the object from R2.
    if record.isFolder {
      return [
        .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting,
        .allowsDeleting,
      ]
    }
    // Eviction still requires the "allows evicting" bit on macOS 27 (NSFileProviderErrorNonEvictable
    // otherwise), although the symbol is marked deprecated; set it by value to avoid the warning.
    let allowsEvicting = NSFileProviderItemCapabilities(rawValue: 1 << 6)
    return [
      .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting,
      allowsEvicting,
    ]
  }

  var documentSize: NSNumber? { record.size.map { NSNumber(value: $0) } }
  var contentModificationDate: Date? { record.modified }
  var creationDate: Date? { record.modified }

  /// Folders and items without a known date answer "no date" so Finder shows "--"
  /// instead of 1970.
  override func responds(to selector: Selector!) -> Bool {
    if record.modified == nil,
      selector == #selector(getter: NSFileProviderItemProtocol.contentModificationDate)
        || selector == #selector(getter: NSFileProviderItemProtocol.creationDate)
    {
      return false
    }
    return super.responds(to: selector)
  }

  /// Content follows the ETag, or size and date when a listing gave no ETag. Metadata follows
  /// the key, which changes on rename and move.
  var itemVersion: NSFileProviderItemVersion {
    let content =
      record.isFolder
      ? "folder"
      : record.eTag ?? "\(record.size ?? -1)@\(record.modified?.timeIntervalSince1970 ?? 0)"
    return NSFileProviderItemVersion(
      contentVersion: Data(content.utf8), metadataVersion: versionDigest(record.key))
  }
}
