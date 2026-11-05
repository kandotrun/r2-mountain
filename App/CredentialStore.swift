import Foundation
import Security

struct CredentialStore {
  static let service = "run.kan.s3mountain"

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

  func save(_ secret: String, accountID: String, accessKeyID: String) throws {
    let query = identity(accountID: accountID, accessKeyID: accessKeyID)
    let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var newItem = query
      newItem[kSecValueData as String] = Data(secret.utf8)
      newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(newItem as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw CredentialError(status: status) }
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
