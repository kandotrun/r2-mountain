import Foundation
import Testing

@testable import MountainCore

private let start = Date(timeIntervalSince1970: 1_793_786_400)

private func bytes(_ count: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

private func uploading(size: Int64, completed: Int64, startingBytes: Int64 = 0) -> UploadJob {
  var job = makeJob(.uploading, size: size, completedBytes: completed)
  job.attemptStartedAt = start
  job.attemptStartingBytes = startingBytes
  return job
}

struct StateRow: Sendable, CustomTestStringConvertible {
  let state: UploadState
  let status: String
  let symbol: String
  let tone: TransferTone
  let pause: Bool
  let resume: Bool
  let cancel: Bool
  var testDescription: String { state.rawValue }
}

private let stateRows: [StateRow] = [
  StateRow(
    state: .queued, status: "順番待ち", symbol: "clock", tone: .neutral, pause: true, resume: false,
    cancel: true),
  StateRow(
    state: .uploading, status: "アップロード中", symbol: "arrow.up.circle", tone: .active, pause: true,
    resume: false, cancel: true),
  StateRow(
    state: .putPending, status: "送信中", symbol: "arrow.up.circle", tone: .active, pause: false,
    resume: false, cancel: true),
  StateRow(
    state: .completing, status: "完了を確認中", symbol: "arrow.triangle.2.circlepath", tone: .active,
    pause: false, resume: false, cancel: true),
  StateRow(
    state: .reconciling, status: "送信結果を確認中", symbol: "arrow.triangle.2.circlepath",
    tone: .active, pause: false, resume: true, cancel: true),
  StateRow(
    state: .paused, status: "一時停止", symbol: "pause.circle", tone: .neutral, pause: false,
    resume: true, cancel: true),
  StateRow(
    state: .waitingForNetwork, status: "ネットワーク待ち", symbol: "wifi.exclamationmark",
    tone: .attention, pause: false, resume: true, cancel: true),
  StateRow(
    state: .needsCredentials, status: "認証の確認が必要", symbol: "key", tone: .attention, pause: false,
    resume: true, cancel: true),
  StateRow(
    state: .failed, status: "転送を確認してください", symbol: "exclamationmark.triangle", tone: .attention,
    pause: false, resume: true, cancel: true),
  StateRow(
    state: .cancelling, status: "キャンセル処理中", symbol: "xmark.circle", tone: .neutral, pause: false,
    resume: false, cancel: false),
  StateRow(
    state: .cancelled, status: "キャンセル済み", symbol: "xmark.circle", tone: .neutral, pause: false,
    resume: false, cancel: false),
  StateRow(
    state: .completed, status: "完了", symbol: "checkmark.circle.fill", tone: .success, pause: false,
    resume: false, cancel: false),
]

@Suite struct UploadJobRateTests {
  @Test func rateIsMeasuredAgainstGivenTime() {
    let job = uploading(size: 1_000, completed: 110, startingBytes: 10)
    #expect(job.bytesPerSecond(at: start.addingTimeInterval(10)) == 10)
    #expect(job.estimatedSecondsRemaining(at: start.addingTimeInterval(10)) == 89)
    #expect(job.bytesPerSecond(at: start) == 0)
    #expect(job.estimatedSecondsRemaining(at: start) == nil)
    #expect(makeJob(.uploading).bytesPerSecond(at: start) == 0)
  }

  @Test func wallClockRateStillWorks() {
    var job = uploading(size: 1_000, completed: 100)
    job.attemptStartedAt = Date().addingTimeInterval(-10)
    #expect((9...10).contains(job.bytesPerSecond))
    #expect(job.estimatedSecondsRemaining != nil)
  }
}

@Suite struct TransferPresentationTests {
  @Test(arguments: stateRows)
  func stateMapping(_ row: StateRow) {
    let presentation = TransferPresentation(
      job: makeJob(row.state, size: 100, completedBytes: 25), now: start)
    #expect(presentation.statusText == row.status)
    #expect(presentation.symbolName == row.symbol)
    #expect(presentation.tone == row.tone)
    #expect(presentation.canPause == row.pause)
    #expect(presentation.canResume == row.resume)
    #expect(presentation.canCancel == row.cancel)
    switch row.state {
    case .cancelled, .cancelling: #expect(presentation.progress == nil)
    case .completed: #expect(presentation.progress == 1)
    default: #expect(presentation.progress == 0.25)
    }
  }

  @Test func describesFileAndDestination() {
    var job = makeJob(.failed, relativePath: "素材/2026/clip.mov", key: "backup/素材/2026/clip 2.mov")
    job.errorMessage = "接続を待っています。"
    let presentation = TransferPresentation(job: job, now: start)
    #expect(presentation.title == "clip.mov")
    #expect(presentation.destination == "backup/素材/2026/clip 2.mov")
    #expect(presentation.errorText == "接続を待っています。")
    let unnamed = makeJob(relativePath: "")
    #expect(TransferPresentation(job: unnamed).title == unnamed.sourceURL.lastPathComponent)
    #expect(TransferPresentation(job: makeJob()).errorText == nil)
  }

  @Test func bytesShowCompletedOverTotalUntilDone() {
    #expect(
      TransferPresentation(job: makeJob(.paused, size: 5_000_000, completedBytes: 1_000_000))
        .bytesText == "\(bytes(1_000_000)) / \(bytes(5_000_000))")
    #expect(
      TransferPresentation(job: makeJob(.completed, size: 5_000_000, completedBytes: 5_000_000))
        .bytesText == bytes(5_000_000))
  }

  @Test func rateAndRemainingTimeWhileUploading() {
    let minutes = TransferPresentation(
      job: uploading(size: 10_000_000, completed: 1_000_000), now: start.addingTimeInterval(10))
    #expect(minutes.rateText == "\(bytes(100_000))/秒")
    #expect(minutes.remainingText == "残り約 1分")
    let seconds = TransferPresentation(
      job: uploading(size: 1_292, completed: 1_000), now: start.addingTimeInterval(100))
    #expect(seconds.rateText == "\(bytes(10))/秒")
    #expect(seconds.remainingText == "残り約 30秒")
    let hours = TransferPresentation(
      job: uploading(size: 3_671_000, completed: 10_000), now: start.addingTimeInterval(10))
    #expect(hours.remainingText == "残り約 1時間1分")
    let finishing = TransferPresentation(
      job: uploading(size: 100, completed: 100), now: start.addingTimeInterval(1))
    #expect(finishing.remainingText == "残り約 0秒")
  }

  @Test func rateIsHiddenWhenUnknownOrNotUploading() {
    let notStarted = TransferPresentation(job: makeJob(.uploading, size: 100), now: start)
    #expect(notStarted.rateText == nil)
    #expect(notStarted.remainingText == nil)
    let justStarted = TransferPresentation(
      job: uploading(size: 100, completed: 0), now: start.addingTimeInterval(5))
    #expect(justStarted.rateText == nil)
    #expect(justStarted.remainingText == nil)
    var paused = uploading(size: 100, completed: 50)
    paused.state = .paused
    let pausedPresentation = TransferPresentation(job: paused, now: start.addingTimeInterval(5))
    #expect(pausedPresentation.rateText == nil)
    #expect(pausedPresentation.remainingText == nil)
  }
}

@Suite struct TransferSummaryTests {
  @Test func emptyQueue() {
    let summary = TransferSummary(jobs: [])
    #expect(summary.totalCount == 0)
    #expect(summary.overallProgress == nil)
    #expect(summary.headline == "転送はありません")
    #expect(!summary.hasFinished)
  }

  @Test func attentionTakesPriorityAndProgressIsByteWeighted() {
    let summary = TransferSummary(jobs: [
      makeJob(.uploading, size: 100, completedBytes: 50),
      makeJob(.completed, size: 100, completedBytes: 100),
      makeJob(.failed, size: 200),
      makeJob(.cancelled, size: 1_000, completedBytes: 900),
      makeJob(.cancelling, size: 1_000, completedBytes: 900),
      makeJob(.paused, size: 0),
    ])
    #expect(summary.totalCount == 6)
    #expect(summary.activeCount == 2)
    #expect(summary.completedCount == 1)
    #expect(summary.attentionCount == 1)
    #expect(summary.pausedCount == 1)
    #expect(summary.overallProgress == 0.375)
    #expect(summary.headline == "1件の確認が必要")
    #expect(summary.hasFinished)
  }

  @Test func countsEveryActiveState() {
    let states: [UploadState] = [
      .queued, .uploading, .putPending, .completing, .reconciling, .cancelling,
    ]
    let summary = TransferSummary(jobs: states.map { makeJob($0) })
    #expect(summary.activeCount == 6)
    #expect(summary.attentionCount == 0)
    #expect(summary.headline == "6件をアップロード中")
    #expect(!summary.hasFinished)
    let attention = TransferSummary(jobs: [
      makeJob(.waitingForNetwork), makeJob(.needsCredentials), makeJob(.failed), makeJob(.queued),
    ])
    #expect(attention.attentionCount == 3)
    #expect(attention.headline == "3件の確認が必要")
  }

  @Test func pausedAndFinishedHeadlines() {
    let paused = TransferSummary(jobs: [makeJob(.paused), makeJob(.paused), makeJob(.completed)])
    #expect(paused.pausedCount == 2)
    #expect(paused.headline == "2件が一時停止中")
    let done = TransferSummary(jobs: [
      makeJob(.completed, size: 10, completedBytes: 10), makeJob(.cancelled),
    ])
    #expect(done.headline == "すべて完了")
    let cancelledOnly = TransferSummary(jobs: [makeJob(.cancelled), makeJob(.cancelled)])
    #expect(cancelledOnly.headline == "キャンセルしました")
    #expect(done.overallProgress == 1)
    #expect(done.hasFinished)
  }

  @Test func progressIsUnknownWithoutMeasurableBytes() {
    #expect(TransferSummary(jobs: [makeJob(.cancelled, size: 100)]).overallProgress == nil)
    #expect(TransferSummary(jobs: [makeJob(.completed, size: 0)]).overallProgress == nil)
    #expect(
      TransferSummary(jobs: [makeJob(.uploading, size: 100, completedBytes: 500)]).overallProgress
        == 1)
  }
}
