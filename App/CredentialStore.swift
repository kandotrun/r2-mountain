import Foundation
import MountainCore
import Security
import os

/// Keeps the secret in the Keychain group shared with the File Provider extension.
struct CredentialStore {
  private let store = MigratingSecretStore(primary: SharedVault(), legacy: LoginKeychainVault())

  func secret(accountID: String, accessKeyID: String) throws -> String? {
    try store.secret(accountID: accountID, accessKeyID: accessKeyID)
  }

  func save(_ secret: String, accountID: String, accessKeyID: String) throws {
    try store.save(secret, accountID: accountID, accessKeyID: accessKeyID)
  }

  func delete(accountID: String, accessKeyID: String) throws {
    try store.delete(accountID: accountID, accessKeyID: accessKeyID)
  }

  /// Earlier versions kept the secret in the login keychain, which the extension cannot read.
  func migrateLegacySecret(accountID: String, accessKeyID: String) {
    guard !accountID.isEmpty, !accessKeyID.isEmpty else { return }
    do {
      if try store.migrate(accountID: accountID, accessKeyID: accessKeyID) {
        Logger.credentials.info("Moved the R2 secret to the shared keychain group")
      }
    } catch {
      Logger.credentials.error(
        "Keeping the login keychain secret: \(String(describing: error), privacy: .public)")
    }
  }
}

private struct SharedVault: WritableSecretVault {
  func secret(accountID: String, accessKeyID: String) throws -> String? {
    try mapped { try SharedCredentials.secret(accountID: accountID, accessKeyID: accessKeyID) }
  }

  func save(_ secret: String, accountID: String, accessKeyID: String) throws {
    try mapped {
      try SharedCredentials.save(secret, accountID: accountID, accessKeyID: accessKeyID)
    }
  }

  func delete(accountID: String, accessKeyID: String) throws {
    try mapped { try SharedCredentials.delete(accountID: accountID, accessKeyID: accessKeyID) }
  }

  private func mapped<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let failure as SharedCredentials.Failure {
      throw CredentialError(status: failure.status)
    }
  }
}

/// Where earlier versions kept the secret; it is only read and deleted now.
private struct LoginKeychainVault: SecretVault {
  private static let service = "run.kan.s3mountain"

  func secret(accountID: String, accessKeyID: String) throws -> String? {
    var query = identity(accountID: accountID, accessKeyID: accessKeyID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw CredentialError(status: status) }
    return value
  }

  func delete(accountID: String, accessKeyID: String) throws {
    let status = SecItemDelete(
      identity(accountID: accountID, accessKeyID: accessKeyID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialError(status: status)
    }
  }

  private func identity(accountID: String, accessKeyID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: "r2.secret.\(accountID).\(accessKeyID)",
      kSecAttrSynchronizable as String: false,
    ]
  }
}

struct CredentialError: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    "Keychain にアクセスできません（\(status)）。Mac のロックを解除して、もう一度お試しください。"
  }
}

extension Logger {
  fileprivate static let credentials = Logger(
    subsystem: "run.kan.s3mountain", category: "credentials")
}
