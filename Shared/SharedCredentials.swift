import Foundation
import Security

/// The R2 secret in the Keychain group the host app shares with the File Provider extension.
enum SharedCredentials {
  static let service = "run.kan.s3mountain.r2"

  struct Failure: Error, Equatable {
    let status: OSStatus
  }

  static func secret(accountID: String, accessKeyID: String) throws -> String? {
    var query = identity(accountID: accountID, accessKeyID: accessKeyID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw Failure(status: status) }
    return value
  }

  static func save(_ secret: String, accountID: String, accessKeyID: String) throws {
    let query = identity(accountID: accountID, accessKeyID: accessKeyID)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(secret.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  static func delete(accountID: String, accessKeyID: String) throws {
    let status = SecItemDelete(
      identity(accountID: accountID, accessKeyID: accessKeyID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }

  private static func identity(accountID: String, accessKeyID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "\(accountID):\(accessKeyID)",
      kSecAttrAccessGroup as String: SharedConfiguration.keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}
