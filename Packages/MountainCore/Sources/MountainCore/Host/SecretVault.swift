import Foundation

/// A place that keeps the R2 secret of one access key.
public protocol SecretVault: Sendable {
  func secret(accountID: String, accessKeyID: String) throws -> String?
  func delete(accountID: String, accessKeyID: String) throws
}

public protocol WritableSecretVault: SecretVault {
  func save(_ secret: String, accountID: String, accessKeyID: String) throws
}

/// Keeps the secret in the primary vault and moves copies left in the legacy one over.
public struct MigratingSecretStore<Primary: WritableSecretVault, Legacy: SecretVault>: Sendable {
  private let primary: Primary
  private let legacy: Legacy

  public init(primary: Primary, legacy: Legacy) {
    self.primary = primary
    self.legacy = legacy
  }

  /// Falls back to the legacy copy so the app keeps working when the primary vault is unavailable.
  public func secret(accountID: String, accessKeyID: String) throws -> String? {
    do {
      if let value = try primary.secret(accountID: accountID, accessKeyID: accessKeyID) {
        return value
      }
    } catch {
      if let value = try? legacy.secret(accountID: accountID, accessKeyID: accessKeyID) {
        return value
      }
      throw error
    }
    return try legacy.secret(accountID: accountID, accessKeyID: accessKeyID)
  }

  public func save(_ secret: String, accountID: String, accessKeyID: String) throws {
    try primary.save(secret, accountID: accountID, accessKeyID: accessKeyID)
    try? legacy.delete(accountID: accountID, accessKeyID: accessKeyID)
  }

  public func delete(accountID: String, accessKeyID: String) throws {
    var failure: (any Error)?
    do { try primary.delete(accountID: accountID, accessKeyID: accessKeyID) } catch {
      failure = error
    }
    do { try legacy.delete(accountID: accountID, accessKeyID: accessKeyID) } catch {
      failure = failure ?? error
    }
    if let failure { throw failure }
  }

  /// Returns whether a legacy copy existed. It is deleted only once the primary vault holds a secret,
  /// and a secret already in the primary vault is newer, so it is kept.
  @discardableResult
  public func migrate(accountID: String, accessKeyID: String) throws -> Bool {
    guard let old = try legacy.secret(accountID: accountID, accessKeyID: accessKeyID) else {
      return false
    }
    if try primary.secret(accountID: accountID, accessKeyID: accessKeyID) == nil {
      try primary.save(old, accountID: accountID, accessKeyID: accessKeyID)
    }
    try legacy.delete(accountID: accountID, accessKeyID: accessKeyID)
    return true
  }
}
