import Foundation
import Network

final class NetworkObserver: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "run.kan.s3mountain.network")

  init(onConnectionAvailable: @escaping @Sendable () -> Void) {
    monitor.pathUpdateHandler = { path in
      if path.status == .satisfied { onConnectionAvailable() }
    }
    monitor.start(queue: queue)
  }

  deinit { monitor.cancel() }
}
