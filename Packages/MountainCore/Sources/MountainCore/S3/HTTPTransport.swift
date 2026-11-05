import Foundation
import Synchronization

public enum S3RequestBody: Sendable {
  case none
  case data(Data)
  case file(URL, Int64)

  var contentLength: Int64 {
    switch self {
    case .none: 0
    case .data(let data): Int64(data.count)
    case .file(_, let size): size
    }
  }
}

public struct S3HTTPRequest: Sendable {
  public let url: URL
  public let method: String
  public let headers: [String: String]
  public let body: S3RequestBody

  public init(url: URL, method: String, headers: [String: String], body: S3RequestBody = .none) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

public struct S3HTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String], body: Data = Data()) {
    self.status = status
    self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    self.body = body
  }
}

public protocol S3HTTPTransport: Sendable {
  func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse
  func download(
    _ request: S3HTTPRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> S3HTTPResponse
}

extension S3HTTPTransport {
  /// Buffers through `send`; network transports stream the body to disk instead.
  /// Only a 2xx body reaches `file`; other bodies stay in the response for error decoding.
  public func download(
    _ request: S3HTTPRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> S3HTTPResponse {
    let response = try await send(request)
    guard (200...299).contains(response.status) else { return response }
    try response.body.write(to: file, options: .atomic)
    progress(Int64(response.body.count))
    return S3HTTPResponse(status: response.status, headers: response.headers)
  }
}

private final class DenyS3RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private final class S3DownloadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  private let report: @Sendable (Int64) -> Void
  private let observation = Mutex<NSKeyValueObservation?>(nil)

  init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

  // Observes the byte count itself: async download APIs need not forward didWriteData.
  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    let report = report
    let observed = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
      report(task.countOfBytesReceived)
    }
    observation.withLock { $0 = observed }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    observation.withLock {
      $0?.invalidate()
      $0 = nil
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public struct URLSessionS3Transport: S3HTTPTransport {
  private let session: URLSession
  private let downloadSession: URLSession

  public init() { self.init(configuration: .ephemeral) }

  init(configuration: URLSessionConfiguration) {
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 7_200
    session = URLSession(
      configuration: configuration, delegate: DenyS3RedirectDelegate(), delegateQueue: nil)
    // A whole object can take far longer than one part; the idle timeout still catches stalls.
    configuration.timeoutIntervalForResource = 7 * 86_400
    downloadSession = URLSession(
      configuration: configuration, delegate: DenyS3RedirectDelegate(), delegateQueue: nil)
  }

  var requestConfiguration: URLSessionConfiguration { session.configuration }
  var downloadConfiguration: URLSessionConfiguration { downloadSession.configuration }

  public func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
    let native = Self.native(request)
    let result: (Data, URLResponse)
    switch request.body {
    case .none:
      result = try await session.data(for: native)
    case .data(let data):
      result = try await session.upload(for: native, from: data)
    case .file(let url, _):
      result = try await session.upload(for: native, fromFile: url)
    }
    let response = try Self.http(result.1)
    return S3HTTPResponse(
      status: response.statusCode, headers: Self.headers(response), body: result.0)
  }

  public func download(
    _ request: S3HTTPRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> S3HTTPResponse {
    let (location, result) = try await downloadSession.download(
      for: Self.native(request), delegate: S3DownloadDelegate(progress))
    defer { try? FileManager.default.removeItem(at: location) }
    let response = try Self.http(result)
    guard (200...299).contains(response.statusCode) else {
      let handle = try FileHandle(forReadingFrom: location)
      defer { try? handle.close() }
      let body = try handle.read(upToCount: 8 * 1_048_576 + 1) ?? Data()
      return S3HTTPResponse(
        status: response.statusCode, headers: Self.headers(response), body: body)
    }
    try? FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: location, to: file)
    return S3HTTPResponse(status: response.statusCode, headers: Self.headers(response))
  }

  private static func native(_ request: S3HTTPRequest) -> URLRequest {
    var native = URLRequest(url: request.url)
    native.httpMethod = request.method
    for (name, value) in request.headers { native.setValue(value, forHTTPHeaderField: name) }
    return native
  }

  private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
      throw S3Failure(status: 0, code: "InvalidHTTPResponse")
    }
    return response
  }

  private static func headers(_ response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      if let name = name as? String { headers[name] = String(describing: value) }
    }
    return headers
  }
}
