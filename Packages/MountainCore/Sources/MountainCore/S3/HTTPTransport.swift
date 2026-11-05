import Foundation

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

public struct URLSessionS3Transport: S3HTTPTransport {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 7_200
    session = URLSession(
      configuration: configuration, delegate: DenyS3RedirectDelegate(), delegateQueue: nil)
  }

  public func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
    var native = URLRequest(url: request.url)
    native.httpMethod = request.method
    for (name, value) in request.headers { native.setValue(value, forHTTPHeaderField: name) }
    let result: (Data, URLResponse)
    switch request.body {
    case .none:
      result = try await session.data(for: native)
    case .data(let data):
      result = try await session.upload(for: native, from: data)
    case .file(let url, _):
      result = try await session.upload(for: native, fromFile: url)
    }
    guard let response = result.1 as? HTTPURLResponse else {
      throw S3Failure(status: 0, code: "InvalidHTTPResponse")
    }
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      if let name = name as? String { headers[name] = String(describing: value) }
    }
    return S3HTTPResponse(status: response.statusCode, headers: headers, body: result.0)
  }
}
