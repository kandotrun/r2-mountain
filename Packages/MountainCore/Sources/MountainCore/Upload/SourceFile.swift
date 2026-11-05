import CryptoKit
import Foundation

public struct SourceIdentity: Codable, Sendable, Equatable {
  public let size: Int64
  public let modifiedAt: Date
  public let inode: UInt64
  public let device: UInt64

  public static func read(_ url: URL) throws -> SourceIdentity {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber,
      let date = attributes[.modificationDate] as? Date,
      let inode = attributes[.systemFileNumber] as? NSNumber,
      let device = attributes[.systemNumber] as? NSNumber
    else { throw UploadError.unsupportedSource }
    return SourceIdentity(
      size: size.int64Value, modifiedAt: date,
      inode: inode.uint64Value, device: device.uint64Value)
  }

  func verify(_ url: URL) throws {
    guard (try? Self.read(url)) == self else { throw UploadError.sourceChanged }
  }
}

struct ImportedSource: Sendable {
  let url: URL
  let relativePath: String
  let identity: SourceIdentity
}

enum SourceImporter {
  static func collect(_ urls: [URL]) throws -> (sources: [ImportedSource], skipped: [String]) {
    var sources: [ImportedSource] = []
    var skipped: [String] = []
    for originalURL in urls {
      let selectedURL = originalURL.standardizedFileURL
      let values = try selectedURL.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
      ])
      guard values.isSymbolicLink != true else {
        skipped.append(selectedURL.lastPathComponent)
        continue
      }
      let url = selectedURL.resolvingSymlinksInPath()
      if values.isDirectory == true {
        var traversalError: (any Error)?
        guard
          let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, error in
              traversalError = error
              return false
            })
        else { throw UploadError.unsupportedSource }
        for case let child as URL in enumerator {
          let properties = try child.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
          ])
          let name = child.lastPathComponent
          if properties.isSymbolicLink == true || name == ".DS_Store" || name.hasPrefix("._") {
            enumerator.skipDescendants()
            skipped.append(name)
            continue
          }
          if properties.isDirectory == true { continue }
          guard properties.isRegularFile == true else {
            skipped.append(name)
            continue
          }
          let canonicalChild = child.resolvingSymlinksInPath()
          let parentComponents = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .pathComponents
          let childComponents = canonicalChild.pathComponents
          guard Array(childComponents.prefix(parentComponents.count)) == parentComponents
          else { throw UploadError.invalidPath }
          let relative = childComponents.dropFirst(parentComponents.count).joined(separator: "/")
          sources.append(
            ImportedSource(
              url: canonicalChild, relativePath: relative,
              identity: try SourceIdentity.read(canonicalChild)))
        }
        if let traversalError { throw traversalError }
      } else if values.isRegularFile == true {
        sources.append(
          ImportedSource(
            url: url, relativePath: url.lastPathComponent,
            identity: try SourceIdentity.read(url)))
      } else {
        skipped.append(url.lastPathComponent)
      }
    }
    return (sources.sorted { $0.relativePath < $1.relativePath }, skipped)
  }
}

struct PreparedPart: Sendable {
  let url: URL
  let size: Int64
  let md5Hex: String
  let contentMD5: String
  func remove() { try? FileManager.default.removeItem(at: url) }
}

enum PartSource {
  static func prepare(
    source: URL, identity: SourceIdentity, offset: Int64,
    length: Int64, directory: URL
  ) throws -> PreparedPart {
    try Task.checkCancellation()
    try identity.verify(source)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = directory.appendingPathComponent(UUID().uuidString + ".part")
    guard
      FileManager.default.createFile(
        atPath: destination.path, contents: nil,
        attributes: [.posixPermissions: 0o600])
    else { throw UploadError.localStorage }
    do {
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      try input.seek(toOffset: UInt64(offset))
      var remaining = length
      var digest = Insecure.MD5()
      while remaining > 0 {
        try Task.checkCancellation()
        let count = Int(min(remaining, 1_048_576))
        guard let data = try input.read(upToCount: count), !data.isEmpty else {
          throw UploadError.sourceChanged
        }
        try output.write(contentsOf: data)
        digest.update(data: data)
        remaining -= Int64(data.count)
      }
      try output.synchronize()
      try identity.verify(source)
      let md5 = Data(digest.finalize())
      return PreparedPart(
        url: destination, size: length,
        md5Hex: md5.map { String(format: "%02x", $0) }.joined(),
        contentMD5: md5.base64EncodedString())
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  static func multipartETag(_ parts: [S3CompletedPart]) -> String {
    var data = Data()
    for part in parts.sorted(by: { $0.number < $1.number }) {
      let value = Array(part.md5Hex.utf8)
      for index in stride(from: 0, to: value.count - 1, by: 2) {
        if let byte = UInt8(String(bytes: value[index...index + 1], encoding: .utf8)!, radix: 16) {
          data.append(byte)
        }
      }
    }
    let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return digest + "-\(parts.count)"
  }
}

func normalizedETag(_ value: String) -> String {
  value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
}
