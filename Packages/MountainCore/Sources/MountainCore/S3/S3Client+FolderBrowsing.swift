import Foundation

extension S3Client: S3FolderBrowsing {
  public func listFolder(_ path: FolderPath, pageLimit: Int) async throws -> FolderListing {
    var token: String?
    var folders: [RemoteEntry] = []
    var folderKeys = Set<[UInt8]>()
    var files: [RemoteEntry] = []
    for _ in 0..<max(1, pageLimit) {
      var query = [("list-type", "2"), ("delimiter", "/"), ("max-keys", "1000")]
      if !path.isRoot { query.append(("prefix", path.prefix)) }
      if let token { query.append(("continuation-token", token)) }
      let response = try await perform(method: "GET", query: query)
      let page = try ListObjectsPage(
        document(response, expectedRoot: "ListBucketResult"), prefix: path.prefix,
        status: response.status)
      files += page.files
      folders += page.folders.filter { folderKeys.insert(Array($0.key.utf8)).inserted }
      guard let next = page.nextToken else {
        return FolderListing(path: path, folders: folders, files: files, isTruncated: false)
      }
      guard next != token else {
        throw S3Failure(status: response.status, code: "InvalidListPagination")
      }
      token = next
    }
    return FolderListing(path: path, folders: folders, files: files, isTruncated: true)
  }

  public func createFolder(_ path: FolderPath) async throws {
    guard !path.isRoot else { throw S3Failure(status: 0, code: "InvalidFolder") }
    do {
      _ = try await perform(
        method: "PUT", key: path.prefix,
        headers: [
          "content-type": "application/x-directory", "content-md5": "1B2M2Y8AsgTpgAmY7PhCfg==",
          "if-none-match": "*",
        ], body: .data(Data()))
    } catch let failure as S3Failure where failure.status == 412 {
      // The folder marker already exists.
    }
  }
}

private struct ListObjectsPage {
  var folders: [RemoteEntry] = []
  var files: [RemoteEntry] = []
  let nextToken: String?

  init(_ root: S3XMLNode, prefix: String, status: Int) throws {
    for node in root.children where node.name == "Contents" {
      guard let key = node.child("Key")?.text, !key.isEmpty else {
        throw S3Failure(status: status, code: "InvalidListing")
      }
      guard let name = Self.name(of: key, in: prefix, isFolder: false) else { continue }
      guard let size = node.value("Size").flatMap({ Int64($0) }), size >= 0,
        let modified = node.value("LastModified").flatMap(Self.date)
      else { throw S3Failure(status: status, code: "InvalidListing") }
      files.append(
        RemoteEntry(key: key, name: name, kind: .file, size: size, lastModified: modified))
    }
    for node in root.children where node.name == "CommonPrefixes" {
      guard let key = node.child("Prefix")?.text,
        let name = Self.name(of: key, in: prefix, isFolder: true),
        FolderPath(prefix: key) != nil
      else { continue }
      folders.append(RemoteEntry(key: key, name: name, kind: .folder, size: nil, lastModified: nil))
    }
    switch root.value("IsTruncated") {
    case "false": nextToken = nil
    case "true":
      guard let next = root.value("NextContinuationToken"), !next.isEmpty else {
        throw S3Failure(status: status, code: "InvalidListPagination")
      }
      nextToken = next
    default: throw S3Failure(status: status, code: "InvalidListPagination")
    }
  }

  /// Compares bytes so canonically equivalent but distinct S3 keys are never conflated.
  private static func name(of key: String, in prefix: String, isFolder: Bool) -> String? {
    let slash = UInt8(ascii: "/")
    guard key.utf8.starts(with: prefix.utf8) else { return nil }
    var rest = key.utf8.dropFirst(prefix.utf8.count)
    if isFolder {
      guard rest.last == slash else { return nil }
      rest = rest.dropLast()
    }
    guard !rest.isEmpty, !rest.contains(slash) else { return nil }
    return String(rest)
  }

  private static func date(_ text: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(text)
  }
}
