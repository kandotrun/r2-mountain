import Foundation
import Testing

@testable import MountainCore

@Suite("Transfer list ordering")
struct TransferOrderingTests {
  @Test("Running work comes first, then problems, waiting, paused and finished items")
  func groupsByUrgency() {
    let jobs = [
      makeJob(.completed, key: "done"),
      makeJob(.paused, key: "paused"),
      makeJob(.queued, key: "queued"),
      makeJob(.cancelled, key: "cancelled"),
      makeJob(.failed, key: "failed"),
      makeJob(.uploading, key: "uploading"),
    ]
    #expect(
      TransferOrdering.sorted(jobs).map(\.key) == [
        "uploading", "failed", "queued", "paused", "done", "cancelled",
      ])
  }

  @Test("Unfinished jobs keep upload order; finished jobs show the newest first")
  func ordersWithinGroups() {
    let jobs = [
      makeJob(.completed, key: "done-1"),
      makeJob(.queued, key: "queued-1"),
      makeJob(.completed, key: "done-2"),
      makeJob(.queued, key: "queued-2"),
    ]
    #expect(
      TransferOrdering.sorted(jobs).map(\.key) == ["queued-1", "queued-2", "done-2", "done-1"])
  }

  @Test("Every state has a place in the ordering")
  func coversEveryState() {
    let states: [UploadState] = [
      .queued, .uploading, .putPending, .completing, .reconciling, .paused, .waitingForNetwork,
      .needsCredentials, .failed, .cancelling, .cancelled, .completed,
    ]
    let jobs = states.map { makeJob($0, key: $0.rawValue) }
    #expect(TransferOrdering.sorted(jobs).count == states.count)
    #expect(TransferOrdering.sorted(jobs).first?.state == .uploading)
    #expect(TransferOrdering.sorted(jobs).last?.state == .cancelled)
  }
}
