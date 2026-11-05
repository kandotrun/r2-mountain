import Foundation

/// Order for transfer lists: running work, things that need a decision, waiting, paused,
/// then finished items with the newest first.
public enum TransferOrdering {
  public static func sorted(_ jobs: [UploadJob]) -> [UploadJob] {
    jobs.enumerated().sorted { lhs, rhs in
      let left = rank(lhs.element.state)
      let right = rank(rhs.element.state)
      if left != right { return left < right }
      return left >= rank(.completed) ? lhs.offset > rhs.offset : lhs.offset < rhs.offset
    }.map(\.element)
  }

  private static func rank(_ state: UploadState) -> Int {
    switch state {
    case .uploading, .putPending, .completing, .reconciling: 0
    case .failed, .needsCredentials, .waitingForNetwork: 1
    case .queued, .cancelling: 2
    case .paused: 3
    case .completed: 4
    case .cancelled: 5
    }
  }
}
