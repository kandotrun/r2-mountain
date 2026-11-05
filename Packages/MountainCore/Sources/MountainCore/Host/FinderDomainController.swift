/// The bucket the File Provider extension lists, as the host app shares it through the App Group.
public struct FinderConnection: Codable, Equatable, Sendable {
  public var accountID: String
  public var bucket: String
  /// `"standard"` or `"eu"`.
  public var jurisdiction: String
  public var accessKeyID: String

  public init(accountID: String, bucket: String, jurisdiction: String, accessKeyID: String) {
    self.accountID = accountID
    self.bucket = bucket
    self.jurisdiction = jurisdiction
    self.accessKeyID = accessKeyID
  }

  /// A new access key still lists the same objects, so the domain and its cache can stay.
  public func listsSameBucket(as other: FinderConnection?) -> Bool {
    guard let other else { return false }
    return accountID == other.accountID && bucket == other.bucket
      && jurisdiction == other.jurisdiction
  }
}

/// What the controller keeps across launches.
public struct FinderDomainRecord: Equatable, Sendable {
  public var isEnabled: Bool
  /// The connection the registered domain was added for.
  public var connection: FinderConnection?

  public init(isEnabled: Bool = false, connection: FinderConnection? = nil) {
    self.isEnabled = isEnabled
    self.connection = connection
  }
}

/// The File Provider manager, the App Group and the preferences, as the controller uses them.
@MainActor
public protocol FinderDomainSystem: AnyObject {
  var record: FinderDomainRecord { get set }
  func domains() async throws -> [FinderDomainState]
  func addDomain(_ id: String) async throws
  /// Keeps files edited in Finder that were not uploaded yet.
  func removeDomain(_ id: String) async throws
  func signalDomain(_ id: String)
  /// Tells the extension which bucket to list; `nil` leaves it without one.
  func publish(_ connection: FinderConnection?)
}

/// Keeps Finder showing exactly the configured bucket, or nothing.
@MainActor
public final class FinderDomainController {
  public private(set) var status: FinderStatus = .off {
    didSet { if status != oldValue { onChange?() } }
  }
  public var onChange: (@MainActor () -> Void)?

  private let system: any FinderDomainSystem
  private let pollInterval: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  /// Unknown until the settings are loaded, so nothing is removed before then.
  private var connection: FinderConnection?
  private var knowsConnection = false
  /// The extension learns a new connection only once no domain lists another bucket,
  /// so an old domain never works on the new bucket.
  private var needsPublish = false
  private var queue: Task<Void, Never>?
  private var polling: Task<Void, Never>?

  /// Changes made outside Finder only reach it when the working set is signalled.
  public init(
    system: any FinderDomainSystem, pollInterval: Duration = .seconds(90),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.system = system
    self.pollInterval = pollInterval
    self.sleep = sleep
  }

  public var isEnabled: Bool { system.record.isEnabled }
  public var isPolling: Bool { polling != nil }

  /// The domain Finder shows, if any.
  public var domainID: String? {
    guard case .on = status, isEnabled, let bucket = connection?.bucket, !bucket.isEmpty else {
      return nil
    }
    return bucket
  }

  public func setEnabled(_ enabled: Bool) async {
    system.record.isEnabled = enabled
    onChange?()
    await serialized { await $0.reconcile() }
  }

  /// `nil` means the settings name no bucket the extension could list.
  public func connectionDidChange(to connection: FinderConnection?) async {
    await serialized {
      $0.connection = connection
      $0.knowsConnection = true
      $0.needsPublish = true
      await $0.reconcile()
    }
  }

  /// Also retries a change that failed earlier.
  public func refresh() async {
    await serialized { await $0.reconcile() }
  }

  /// Asks the extension to look for changes made outside Finder, such as uploads from the app.
  public func signalChanges() {
    guard let domainID else { return }
    system.signalDomain(domainID)
  }

  /// Toggling and switching buckets in quick succession must not interleave system calls.
  private func serialized(
    _ operation: @escaping @MainActor (FinderDomainController) async -> Void
  ) async {
    let previous = queue
    let task = Task {
      await previous?.value
      await operation(self)
    }
    queue = task
    await task.value
  }

  private func reconcile() async {
    guard knowsConnection else { return }
    let wanted = connection
    do {
      let registered = try await system.domains().map(\.id)
      let plan = FinderDomainPlan(
        registered: registered, bucket: wanted?.bucket ?? "", enabled: isEnabled,
        replacing: !(wanted?.listsSameBucket(as: system.record.connection) ?? false))
      for id in plan.remove { try await system.removeDomain(id) }
      let kept = registered.contains { !plan.remove.contains($0) }
      if !kept { system.record.connection = nil }
      if needsPublish {
        system.publish(wanted)
        needsPublish = false
      }
      if let added = plan.add {
        status = .enabling
        try await system.addDomain(added)
      }
      if kept || plan.add != nil { system.record.connection = wanted }
      status = FinderStatus(
        enabled: isEnabled, bucket: wanted?.bucket ?? "", registered: try await system.domains())
    } catch {
      status = .failed("Finder に表示できません。\(error.localizedDescription)")
    }
    updatePolling()
  }

  private func updatePolling() {
    guard case .on = status else {
      polling?.cancel()
      polling = nil
      return
    }
    guard polling == nil else { return }
    polling = Task { [weak self, sleep, pollInterval] in
      while true {
        do { try await sleep(pollInterval) } catch { return }
        guard !Task.isCancelled, let self else { return }
        self.signalChanges()
      }
    }
  }
}
