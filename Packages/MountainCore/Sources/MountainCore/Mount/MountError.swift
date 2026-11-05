import Foundation

public enum MountError: Error, Equatable, Sendable {
  case alreadyExists, notFound, notConfigured, invalidName
}

extension MountError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .alreadyExists: "同じ名前の項目が既にあります。"
    case .notFound: "項目が見つかりません。"
    case .notConfigured: "接続先が設定されていません。S3 Mountain の設定を確認してください。"
    case .invalidName: "この名前は使えません。"
    }
  }
}
