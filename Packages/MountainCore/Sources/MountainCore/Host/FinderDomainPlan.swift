/// A File Provider domain the system has registered for this app.
public struct FinderDomainState: Equatable, Sendable {
  public var id: String
  /// False when the user turned the domain off in System Settings.
  public var userEnabled: Bool

  public init(id: String, userEnabled: Bool) {
    self.id = id
    self.userEnabled = userEnabled
  }
}

/// The domain changes that make Finder show exactly the configured bucket, or nothing.
public struct FinderDomainPlan: Equatable, Sendable {
  public var remove: [String]
  public var add: String?

  public init(remove: [String], add: String?) {
    self.remove = remove
    self.add = add
  }

  /// `replacing` drops a registered domain of the same name that lists another bucket,
  /// such as one in another account or jurisdiction.
  public init(registered: [String], bucket: String, enabled: Bool, replacing: Bool = false) {
    let wanted = enabled && !bucket.isEmpty ? bucket : nil
    let kept = replacing ? nil : wanted
    remove = registered.filter { $0 != kept }
    add = wanted.flatMap { kept != nil && registered.contains($0) ? nil : $0 }
  }

  public var isEmpty: Bool { remove.isEmpty && add == nil }
}

public enum FinderStatus: Equatable, Sendable {
  case off, enabling
  case on(userEnabled: Bool)
  case failed(String)

  public init(enabled: Bool, bucket: String, registered: [FinderDomainState]) {
    guard enabled, !bucket.isEmpty else {
      self = .off
      return
    }
    if let domain = registered.first(where: { $0.id == bucket }) {
      self = .on(userEnabled: domain.userEnabled)
    } else {
      self = .failed("Finder に登録されていません。オフにしてから、もう一度オンにしてください。")
    }
  }

  public var isAvailableInFinder: Bool { self == .on(userEnabled: true) }
}
