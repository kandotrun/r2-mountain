import Foundation
import Synchronization
import Testing

@testable import MountainCore

private struct VaultFailure: Error, Equatable {}

/// Keeps secrets in memory and fails the operations a test asks it to.
private final class MemoryVault: WritableSecretVault {
  struct Failing: OptionSet {
    let rawValue: Int
    static let read = Failing(rawValue: 1)
    static let write = Failing(rawValue: 2)
    static let delete = Failing(rawValue: 4)
  }

  private let state: Mutex<(values: [String: String], failing: Failing)>

  init(_ values: [String: String] = [:], failing: Failing = []) {
    state = Mutex((values, failing))
  }

  var values: [String: String] { state.withLock { $0.values } }

  func secret(accountID: String, accessKeyID: String) throws -> String? {
    try state.withLock {
      if $0.failing.contains(.read) { throw VaultFailure() }
      return $0.values["\(accountID):\(accessKeyID)"]
    }
  }

  func save(_ secret: String, accountID: String, accessKeyID: String) throws {
    try state.withLock {
      if $0.failing.contains(.write) { throw VaultFailure() }
      $0.values["\(accountID):\(accessKeyID)"] = secret
    }
  }

  func delete(accountID: String, accessKeyID: String) throws {
    try state.withLock {
      if $0.failing.contains(.delete) { throw VaultFailure() }
      $0.values["\(accountID):\(accessKeyID)"] = nil
    }
  }
}

@Suite struct SecretMigrationTests {
  private let id = "acct:key"

  @Test func readsSharedSecretBeforeLegacy() throws {
    let store = MigratingSecretStore(
      primary: MemoryVault([id: "shared"]), legacy: MemoryVault([id: "legacy"]))
    #expect(try store.secret(accountID: "acct", accessKeyID: "key") == "shared")
  }

  @Test func fallsBackToLegacyWhenSharedIsEmptyOrUnavailable() throws {
    let empty = MigratingSecretStore(primary: MemoryVault(), legacy: MemoryVault([id: "legacy"]))
    #expect(try empty.secret(accountID: "acct", accessKeyID: "key") == "legacy")
    let broken = MigratingSecretStore(
      primary: MemoryVault(failing: .read), legacy: MemoryVault([id: "legacy"]))
    #expect(try broken.secret(accountID: "acct", accessKeyID: "key") == "legacy")
  }

  @Test func reportsSharedFailureWhenLegacyHasNothing() {
    let store = MigratingSecretStore(primary: MemoryVault(failing: .read), legacy: MemoryVault())
    #expect(throws: VaultFailure.self) {
      try store.secret(accountID: "acct", accessKeyID: "key")
    }
  }

  @Test func returnsNilWhenNoVaultHasTheSecret() throws {
    let store = MigratingSecretStore(primary: MemoryVault(), legacy: MemoryVault())
    #expect(try store.secret(accountID: "acct", accessKeyID: "key") == nil)
  }

  @Test func migrationMovesLegacySecretThenDeletesIt() throws {
    let shared = MemoryVault()
    let legacy = MemoryVault([id: "legacy", "other:key": "kept"])
    let store = MigratingSecretStore(primary: shared, legacy: legacy)
    #expect(try store.migrate(accountID: "acct", accessKeyID: "key"))
    #expect(shared.values == [id: "legacy"])
    #expect(legacy.values == ["other:key": "kept"])
  }

  @Test func migrationKeepsLegacySecretWhenSharedWriteFails() throws {
    let legacy = MemoryVault([id: "legacy"])
    let store = MigratingSecretStore(primary: MemoryVault(failing: .write), legacy: legacy)
    #expect(throws: VaultFailure.self) {
      try store.migrate(accountID: "acct", accessKeyID: "key")
    }
    #expect(legacy.values == [id: "legacy"])
    #expect(try store.secret(accountID: "acct", accessKeyID: "key") == "legacy")
  }

  @Test func migrationKeepsLegacySecretWhenSharedVaultIsUnreadable() {
    let legacy = MemoryVault([id: "legacy"])
    let store = MigratingSecretStore(primary: MemoryVault(failing: .read), legacy: legacy)
    #expect(throws: VaultFailure.self) {
      try store.migrate(accountID: "acct", accessKeyID: "key")
    }
    #expect(legacy.values == [id: "legacy"])
  }

  @Test func migrationKeepsNewerSharedSecret() throws {
    let shared = MemoryVault([id: "newer"])
    let legacy = MemoryVault([id: "stale"])
    let store = MigratingSecretStore(primary: shared, legacy: legacy)
    #expect(try store.migrate(accountID: "acct", accessKeyID: "key"))
    #expect(shared.values == [id: "newer"])
    #expect(legacy.values.isEmpty)
  }

  @Test func migrationWithoutLegacySecretChangesNothing() throws {
    let shared = MemoryVault([id: "shared"])
    let store = MigratingSecretStore(primary: shared, legacy: MemoryVault())
    #expect(try !store.migrate(accountID: "acct", accessKeyID: "key"))
    #expect(shared.values == [id: "shared"])
  }

  @Test func saveWritesSharedAndDropsStaleLegacy() throws {
    let shared = MemoryVault()
    let legacy = MemoryVault([id: "stale"])
    let store = MigratingSecretStore(primary: shared, legacy: legacy)
    try store.save("fresh", accountID: "acct", accessKeyID: "key")
    #expect(shared.values == [id: "fresh"])
    #expect(legacy.values.isEmpty)
  }

  @Test func saveFailureLeavesLegacyUntouched() {
    let legacy = MemoryVault([id: "legacy"])
    let store = MigratingSecretStore(primary: MemoryVault(failing: .write), legacy: legacy)
    #expect(throws: VaultFailure.self) {
      try store.save("fresh", accountID: "acct", accessKeyID: "key")
    }
    #expect(legacy.values == [id: "legacy"])
  }

  @Test func saveSucceedsWhenStaleLegacyCannotBeDeleted() throws {
    let shared = MemoryVault()
    let store = MigratingSecretStore(
      primary: shared, legacy: MemoryVault([id: "stale"], failing: .delete))
    try store.save("fresh", accountID: "acct", accessKeyID: "key")
    #expect(try store.secret(accountID: "acct", accessKeyID: "key") == "fresh")
  }

  @Test func deleteRemovesBothCopiesAndReportsFailure() throws {
    let shared = MemoryVault([id: "shared"])
    let legacy = MemoryVault([id: "legacy"])
    try MigratingSecretStore(primary: shared, legacy: legacy)
      .delete(accountID: "acct", accessKeyID: "key")
    #expect(shared.values.isEmpty && legacy.values.isEmpty)

    let stuck = MemoryVault([id: "shared"], failing: .delete)
    let other = MemoryVault([id: "legacy"])
    #expect(throws: VaultFailure.self) {
      try MigratingSecretStore(primary: stuck, legacy: other)
        .delete(accountID: "acct", accessKeyID: "key")
    }
    #expect(other.values.isEmpty)
  }
}
