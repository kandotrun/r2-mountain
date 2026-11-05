import Foundation

public enum UploadState: String, Codable, Sendable {
  case queued, uploading, putPending, completing, reconciling, paused
  case waitingForNetwork, needsCredentials, failed, cancelling, cancelled, completed

  /// Terminal states that "clear finished" may forget.
  var isFinished: Bool { self == .completed || self == .cancelled }
  var needsAttention: Bool { [.failed, .needsCredentials, .waitingForNetwork].contains(self) }
}

public enum UploadError: Error, Sendable, LocalizedError, Equatable {
  case invalidSize, invalidPath, sourceChanged, unsupportedSource, localStorage, unsupportedJournal

  public var errorDescription: String? {
    switch self {
    case .invalidSize: "ファイルのサイズがR2の制限を超えています。"
    case .invalidPath: "宛先には . や .. を使えません。"
    case .sourceChanged: "元のファイルが変更または移動されました。もう一度ファイルを選択してください。"
    case .unsupportedSource: "通常のファイルを選択してください。リンクや特殊ファイルは転送できません。"
    case .localStorage: "転送記録を保存できません。ディスクの空き容量とアクセス権を確認してください。"
    case .unsupportedJournal: "新しいバージョンの転送記録があります。アプリを更新してください。"
    }
  }
}

public struct UploadJob: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let createdAt: Date
  public let sourceURL: URL
  public let relativePath: String
  public var key: String
  public let size: Int64
  public var completedBytes: Int64
  public var state: UploadState
  public var errorMessage: String?
  public let configuration: R2Configuration
  public var partSize: Int64
  public var uploadID: String?
  public var completedParts: [S3CompletedPart]
  public var expectedETag: String?
  public var pendingOperation: PendingOperation?
  public var cancellationRequested: Bool
  public var nameOrdinal: Int
  public let originalKey: String
  public let sourceIdentity: SourceIdentity
  public var attemptStartedAt: Date?
  public var attemptStartingBytes: Int64
  public var skippedItems: [String]

  public enum PendingOperation: String, Codable, Sendable { case put, complete }
  public var progress: Double {
    if state == .completed { return 1 }
    return size > 0 ? min(1, max(0, Double(completedBytes) / Double(size))) : 0
  }
  public var bytesPerSecond: Double { bytesPerSecond(at: Date()) }
  public var estimatedSecondsRemaining: Double? { estimatedSecondsRemaining(at: Date()) }

  public func bytesPerSecond(at now: Date) -> Double {
    guard let attemptStartedAt else { return 0 }
    let elapsed = now.timeIntervalSince(attemptStartedAt)
    return elapsed > 0 ? max(0, Double(completedBytes - attemptStartingBytes) / elapsed) : 0
  }

  public func estimatedSecondsRemaining(at now: Date) -> Double? {
    let speed = bytesPerSecond(at: now)
    return speed > 0 ? Double(max(0, size - completedBytes)) / speed : nil
  }

  init(
    sourceURL: URL, relativePath: String, key: String, configuration: R2Configuration,
    identity: SourceIdentity, partSize: Int64, skippedItems: [String] = []
  ) {
    id = UUID()
    createdAt = Date()
    self.sourceURL = sourceURL
    self.relativePath = relativePath
    self.key = key
    originalKey = key
    size = identity.size
    completedBytes = 0
    state = .queued
    self.configuration = configuration
    self.sourceIdentity = identity
    self.partSize = partSize
    completedParts = []
    cancellationRequested = false
    nameOrdinal = 1
    attemptStartingBytes = 0
    self.skippedItems = skippedItems
  }
}

public struct UploadEngineOptions: Sendable {
  public var multipartThreshold: Int64
  public var minimumPartSize: Int64
  public var maximumAttempts: Int
  public var retryBaseDelay: TimeInterval
  public var automaticRetryDelay: TimeInterval

  public init(
    multipartThreshold: Int64 = 64 * 1_048_576,
    minimumPartSize: Int64 = 64 * 1_048_576,
    maximumAttempts: Int = 4, retryBaseDelay: TimeInterval = 1,
    automaticRetryDelay: TimeInterval = 30
  ) {
    self.multipartThreshold = max(1, multipartThreshold)
    self.minimumPartSize = max(1, minimumPartSize)
    self.maximumAttempts = max(1, maximumAttempts)
    self.retryBaseDelay = max(0, retryBaseDelay)
    self.automaticRetryDelay = max(0, automaticRetryDelay)
  }
}
