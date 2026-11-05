import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import MountainCore

func md5Hex(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func contentMD5(_ data: Data) -> String {
  Data(Insecure.MD5.hash(data: data)).base64EncodedString()
}

func patternData(_ count: Int, seed: Int = 0) -> Data {
  Data((0..<count).map { UInt8(($0 + seed) % 251) })
}

func requestBody(_ request: S3HTTPRequest) -> Data? {
  guard case .data(let data) = request.body else { return nil }
  return data
}

let gibibyte: Int64 = 1_073_741_824

/// An in-memory S3 that records every call and can inject failures.
actor FakeMountStore: S3MountStore {
  struct Object: Equatable {
    var data: Data?
    var size: Int64
    var eTag: String
  }
  struct Upload {
    let key: String
    var parts: [Int: Object] = [:]
  }

  private var objects: [[UInt8]: Object] = [:]
  private var uploads: [String: Upload] = [:]
  private var calls: [String] = []
  private var partFailures: [Int: Int] = [:]
  private var partDelays: [Int: Duration] = [:]
  private var failingCopies: Set<[UInt8]> = []
  private var copyDelay: Duration?
  private var replacement: (key: [UInt8], object: Object)?
  private var heldParts: Set<Int> = []
  private var holders: [CheckedContinuation<Void, Never>] = []
  private var completionFailures = 0
  private var racing = false
  private var racerData: Data?
  private var cancelsAtCompletion = false
  private var activeParts = 0
  private(set) var peakParts = 0
  private(set) var overwriteFlags: [Bool] = []
  private var nextUpload = 0

  func seed(_ key: String, data: Data) {
    objects[Array(key.utf8)] = Object(
      data: data, size: Int64(data.count), eTag: quoted(md5Hex(data)))
  }
  func seed(_ key: String, size: Int64, eTag: String = "\"seed\"") {
    objects[Array(key.utf8)] = Object(data: nil, size: size, eTag: eTag)
  }
  func failPart(_ number: Int, times: Int = 1) { partFailures[number] = times }
  func delayPart(_ number: Int, by delay: Duration) { partDelays[number] = delay }
  func delayParts(by delay: Duration, count: Int) {
    for number in 1...count { partDelays[number] = delay }
  }
  func failCopy(to key: String) { failingCopies.insert(Array(key.utf8)) }
  func allowCopies() { failingCopies.removeAll() }
  func delayPartCopies(by delay: Duration) { copyDelay = delay }
  /// Another client replaces `key` as soon as the first ranged copy starts.
  func replaceDuringPartCopy(_ key: String, size: Int64, eTag: String) {
    replacement = (Array(key.utf8), Object(data: nil, size: size, eTag: eTag))
  }
  /// Blocks the part until `releaseHeldParts`.
  func holdPart(_ number: Int) { heldParts.insert(number) }
  func releaseHeldParts() {
    heldParts.removeAll()
    for holder in holders { holder.resume() }
    holders.removeAll()
  }
  func heldCount() -> Int { holders.count }
  /// Another call completes at the key just before this completion; nil means the same bytes.
  func raceCompletion(with data: Data? = nil) {
    racing = true
    racerData = data
  }
  /// The caller's task is cancelled while its completion is refused.
  func cancelAtCompletion() { cancelsAtCompletion = true }
  func loseCompletionResponse() { completionFailures = 1 }
  func forgetUploads() { uploads.removeAll() }
  func clearLog() { calls.removeAll() }

  func log() -> [String] { calls }
  func object(_ key: String) -> Object? { objects[Array(key.utf8)] }
  func keys() -> [String] {
    objects.keys.map { String(decoding: $0, as: UTF8.self) }.sorted {
      Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }
  }
  func uploadIDs() -> [String] { Array(uploads.keys) }
  func remoteParts(_ uploadID: String) -> [Int] { uploads[uploadID]?.parts.keys.sorted() ?? [] }

  func listFolder(_ path: FolderPath, pageLimit: Int) async throws -> FolderListing {
    FolderListing(path: path, folders: [], files: [], isTruncated: false)
  }

  func createFolder(_ path: FolderPath) async throws {
    calls.append("createFolder \(path.prefix)")
    if objects[Array(path.prefix.utf8)] == nil { seed(path.prefix, data: Data()) }
  }

  func head(key: String) async throws -> S3ObjectMetadata? {
    calls.append("head \(key)")
    return objects[Array(key.utf8)].map { S3ObjectMetadata(size: $0.size, eTag: $0.eTag) }
  }

  func download(key: String, to file: URL, progress: @escaping @Sendable (Int64) -> Void)
    async throws -> S3ObjectMetadata
  {
    calls.append("download \(key)")
    guard let object = objects[Array(key.utf8)], let data = object.data else {
      throw MountError.notFound
    }
    try data.write(to: file)
    progress(object.size)
    return S3ObjectMetadata(size: object.size, eTag: object.eTag)
  }

  func put(key: String, file: URL, size: Int64, contentMD5 md5: String, overwrite: Bool)
    async throws -> String
  {
    calls.append("put \(key)")
    overwriteFlags.append(overwrite)
    let data = try Data(contentsOf: file)
    #expect(Int64(data.count) == size)
    #expect(contentMD5(data) == md5)
    if !overwrite, objects[Array(key.utf8)] != nil { throw MountError.alreadyExists }
    seed(key, data: data)
    return quoted(md5Hex(data))
  }

  func createMultipart(key: String) async throws -> String {
    calls.append("createMultipart \(key)")
    nextUpload += 1
    let id = "upload-\(nextUpload)"
    uploads[id] = Upload(key: key)
    return id
  }

  func uploadPart(
    key: String, uploadID: String, number: Int, file: URL, size: Int64, contentMD5 md5: String
  ) async throws -> String {
    calls.append("uploadPart \(number)")
    activeParts += 1
    peakParts = max(peakParts, activeParts)
    defer { activeParts -= 1 }
    let data = try Data(contentsOf: file)
    #expect(Int64(data.count) == size)
    #expect(contentMD5(data) == md5)
    if let delay = partDelays.removeValue(forKey: number) { try await Task.sleep(for: delay) }
    if heldParts.contains(number) { await withCheckedContinuation { holders.append($0) } }
    if let remaining = partFailures[number], remaining > 0 {
      partFailures[number] = remaining - 1
      throw URLError(.networkConnectionLost)
    }
    guard var upload = uploads[uploadID], upload.key.utf8.elementsEqual(key.utf8) else {
      throw S3Failure(status: 404, code: "NoSuchUpload")
    }
    let eTag = quoted(md5Hex(data))
    upload.parts[number] = Object(data: data, size: size, eTag: eTag)
    uploads[uploadID] = upload
    return eTag
  }

  func listParts(key: String, uploadID: String) async throws -> [S3RemotePart] {
    calls.append("listParts \(uploadID)")
    guard let upload = uploads[uploadID] else { throw S3Failure(status: 404, code: "NoSuchUpload") }
    return upload.parts.keys.sorted().map {
      S3RemotePart(number: $0, size: upload.parts[$0]!.size, eTag: upload.parts[$0]!.eTag)
    }
  }

  func completeMultipart(
    key: String, uploadID: String, parts: [S3CompletedPart], overwrite: Bool
  ) async throws -> String {
    calls.append("complete \(parts.map(\.number).map(String.init).joined(separator: ","))")
    overwriteFlags.append(overwrite)
    guard let upload = uploads[uploadID], upload.key.utf8.elementsEqual(key.utf8) else {
      throw S3Failure(status: 404, code: "NoSuchUpload")
    }
    var data = Data()
    var size: Int64 = 0
    for part in parts {
      guard let stored = upload.parts[part.number], stored.eTag == part.eTag else {
        throw S3Failure(status: 400, code: "InvalidPart")
      }
      if let bytes = stored.data { data.append(bytes) }
      size += stored.size
    }
    let eTag: String
    if parts.allSatisfy({ !$0.md5Hex.isEmpty }) {
      eTag = quoted(PartSource.multipartETag(parts))
    } else {
      eTag = quoted("copy-\(parts.count)")
    }
    let assembled = Object(
      data: upload.parts.values.allSatisfy { $0.data != nil } ? data : nil, size: size, eTag: eTag)
    if !overwrite, racing {
      racing = false
      if let racerData { seed(key, data: racerData) } else { objects[Array(key.utf8)] = assembled }
    }
    if !overwrite, objects[Array(key.utf8)] != nil {
      if cancelsAtCompletion { withUnsafeCurrentTask { $0?.cancel() } }
      throw MountError.alreadyExists
    }
    objects[Array(key.utf8)] = assembled
    uploads.removeValue(forKey: uploadID)
    if completionFailures > 0 {
      completionFailures -= 1
      throw URLError(.networkConnectionLost)
    }
    return eTag
  }

  func abortMultipart(key: String, uploadID: String) async throws {
    // Like the signed client, a cancelled caller sends nothing.
    try Task.checkCancellation()
    calls.append("abort \(uploadID)")
    guard let upload = uploads[uploadID], upload.key.utf8.elementsEqual(key.utf8) else {
      throw S3Failure(status: 404, code: "NoSuchUpload")
    }
    uploads.removeValue(forKey: uploadID)
  }

  func copyObject(from source: String, to destination: String) async throws -> String {
    calls.append("copy \(source) -> \(destination)")
    if failingCopies.contains(Array(destination.utf8)) {
      throw S3Failure(status: 500, code: "InternalError")
    }
    guard let object = objects[Array(source.utf8)] else {
      throw S3Failure(status: 404, code: "NoSuchKey")
    }
    // Like R2, a whole-object copy keeps the bytes and so the ETag.
    objects[Array(destination.utf8)] = object
    return object.eTag
  }

  func uploadPartCopy(
    key: String, uploadID: String, number: Int, source: String, range: ClosedRange<Int64>
  ) async throws -> String {
    calls.append("partCopy \(number) \(range.lowerBound)-\(range.upperBound)")
    if let replacement {
      self.replacement = nil
      objects[replacement.key] = replacement.object
    }
    if let copyDelay { try await Task.sleep(for: copyDelay) }
    if failingCopies.contains(Array(key.utf8)), number == 2 {
      throw S3Failure(status: 500, code: "InternalError")
    }
    guard let object = objects[Array(source.utf8)], range.upperBound < object.size else {
      throw S3Failure(status: 400, code: "InvalidRange")
    }
    guard var upload = uploads[uploadID] else { throw S3Failure(status: 404, code: "NoSuchUpload") }
    let eTag = quoted("part-\(number)")
    upload.parts[number] = Object(
      data: nil, size: range.upperBound - range.lowerBound + 1, eTag: eTag)
    uploads[uploadID] = upload
    return eTag
  }

  func deleteObject(key: String) async throws {
    calls.append("delete \(key)")
    objects.removeValue(forKey: Array(key.utf8))
  }

  func deleteObjects(keys: [String]) async throws {
    calls.append("deleteObjects \(keys.count)")
    #expect((1...1_000).contains(keys.count))
    for key in keys { objects.removeValue(forKey: Array(key.utf8)) }
  }

  func listAll(prefix: String) async throws -> [S3ListedObject] {
    calls.append("listAll \(prefix)")
    return objects.filter { $0.key.starts(with: Array(prefix.utf8)) }
      .sorted { $0.key.lexicographicallyPrecedes($1.key) }
      .map { S3ListedObject(key: String(decoding: $0.key, as: UTF8.self), size: $0.value.size) }
  }

  private func quoted(_ value: String) -> String { "\"\(value)\"" }
}

/// Collects progress callbacks from any thread.
final class ProgressLog<Value: Sendable>: Sendable {
  private let storage = Mutex<[Value]>([])
  var values: [Value] { storage.withLock { $0 } }
  func record(_ value: Value) { storage.withLock { $0.append(value) } }
}

struct MountWorkspace {
  let root: URL
  let journal: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mount-tests-" + UUID().uuidString)
    journal = root.appendingPathComponent("journals", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func file(_ data: Data, name: String = "素材.bin") throws -> URL {
    let url = root.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  func journals() -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: journal.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.map { journal.appendingPathComponent($0) }
  }

  func partFiles() -> [String] {
    let parts = journal.appendingPathComponent("parts")
    return (try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? []
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

func isMonotonic(_ values: [Int64]) -> Bool {
  zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
}

/// Serves canned HTTP responses inside URLSession, so the real transport runs without a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
  }

  private static let stubs = Mutex<[String: Stub]>([:])

  /// A URL on a reserved host; the default path is unique to this stub.
  @discardableResult
  static func register(_ stub: Stub, path: String = "/drive/" + UUID().uuidString) -> URL {
    stubs.withLock { $0[path] = stub }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "stub.s3-mountain.test"
    components.path = path
    return components.url!
  }

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return configuration
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let stub = Self.stubs.withLock({ $0[url.path] }),
      let response = HTTPURLResponse(
        url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
