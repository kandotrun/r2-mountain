import Foundation

public enum TransferTone: Sendable, Equatable { case neutral, active, success, attention }

public struct TransferPresentation: Sendable, Equatable {
  public let title: String
  public let destination: String
  public let statusText: String
  public let symbolName: String
  public let tone: TransferTone
  public let progress: Double?
  public let bytesText: String
  public let rateText: String?
  public let remainingText: String?
  public let errorText: String?
  public let canPause: Bool
  public let canResume: Bool
  public let canCancel: Bool

  public init(job: UploadJob, now: Date = Date()) {
    let state = job.state
    let name =
      job.relativePath.isEmpty
      ? "" : URL(filePath: job.relativePath, directoryHint: .notDirectory).lastPathComponent
    title = name.isEmpty ? job.sourceURL.lastPathComponent : name
    destination = job.key
    (statusText, symbolName, tone) = Self.appearance(of: state)
    progress = [.cancelled, .cancelling].contains(state) ? nil : job.progress
    bytesText =
      state == .completed
      ? Self.bytes(job.size) : "\(Self.bytes(job.completedBytes)) / \(Self.bytes(job.size))"
    let rate = state == .uploading ? min(job.bytesPerSecond(at: now), 1e15) : 0
    rateText = rate > 0 ? "\(Self.bytes(Int64(rate)))/秒" : nil
    remainingText =
      state == .uploading ? job.estimatedSecondsRemaining(at: now).flatMap(Self.remaining) : nil
    errorText = job.errorMessage
    canPause = [.queued, .uploading].contains(state)
    canResume = [.paused, .waitingForNetwork, .needsCredentials, .failed, .reconciling].contains(
      state)
    canCancel = ![.completed, .cancelled, .cancelling].contains(state)
  }

  private static func appearance(of state: UploadState) -> (String, String, TransferTone) {
    switch state {
    case .queued: ("順番待ち", "clock", .neutral)
    case .uploading: ("アップロード中", "arrow.up.circle", .active)
    case .putPending: ("送信中", "arrow.up.circle", .active)
    case .completing: ("完了を確認中", "arrow.triangle.2.circlepath", .active)
    case .reconciling: ("送信結果を確認中", "arrow.triangle.2.circlepath", .active)
    case .paused: ("一時停止", "pause.circle", .neutral)
    case .waitingForNetwork: ("ネットワーク待ち", "wifi.exclamationmark", .attention)
    case .needsCredentials: ("認証の確認が必要", "key", .attention)
    case .failed: ("転送を確認してください", "exclamationmark.triangle", .attention)
    case .cancelling: ("キャンセル処理中", "xmark.circle", .neutral)
    case .cancelled: ("キャンセル済み", "xmark.circle", .neutral)
    case .completed: ("完了", "checkmark.circle.fill", .success)
    }
  }

  static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }

  static func remaining(_ seconds: Double) -> String? {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
    let value = Int(seconds.rounded(.up))
    if value >= 3_600 { return "残り約 \(value / 3_600)時間\((value % 3_600) / 60)分" }
    if value >= 60 { return "残り約 \(value / 60)分" }
    return "残り約 \(value)秒"
  }
}

public struct TransferSummary: Sendable, Equatable {
  public let totalCount: Int
  public let activeCount: Int
  public let completedCount: Int
  public let attentionCount: Int
  public let pausedCount: Int
  public let overallProgress: Double?
  public let headline: String
  public let hasFinished: Bool

  public init(jobs: [UploadJob], now: Date = Date()) {
    totalCount = jobs.count
    activeCount = jobs.count {
      [.queued, .uploading, .putPending, .completing, .reconciling, .cancelling].contains($0.state)
    }
    completedCount = jobs.count { $0.state == .completed }
    attentionCount = jobs.count { $0.state.needsAttention }
    pausedCount = jobs.count { $0.state == .paused }
    hasFinished = jobs.contains { $0.state.isFinished }
    let measured = jobs.filter { ![.cancelled, .cancelling].contains($0.state) }
    let total = measured.reduce(Int64(0)) { $0 + max(0, $1.size) }
    let done = measured.reduce(Int64(0)) { sum, job in
      let size = max(0, job.size)
      return sum + (job.state == .completed ? size : min(max(0, job.completedBytes), size))
    }
    overallProgress = total > 0 ? Double(done) / Double(total) : nil
    headline =
      if attentionCount > 0 {
        "\(attentionCount)件の確認が必要"
      } else if activeCount > 0 {
        "\(activeCount)件をアップロード中"
      } else if pausedCount > 0 {
        "\(pausedCount)件が一時停止中"
      } else if completedCount > 0 {
        "すべて完了"
      } else if totalCount > 0 {
        "キャンセルしました"
      } else {
        "転送はありません"
      }
  }
}
