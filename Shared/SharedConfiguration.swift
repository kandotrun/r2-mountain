import Foundation

/// The connection the host app shares with the File Provider extension through the App Group.
struct SharedConfiguration: Codable, Equatable, Sendable {
  private static let key = "mount.configuration"

  var accountID: String
  var bucket: String
  /// `"standard"` or `"eu"`.
  var jurisdiction: String
  var accessKeyID: String

  static var appGroup: String {
    Bundle.main.object(forInfoDictionaryKey: "R2MountainAppGroup") as! String
  }

  static var keychainGroup: String {
    Bundle.main.object(forInfoDictionaryKey: "R2MountainKeychainGroup") as! String
  }

  static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  /// Where the extension keeps the item map and upload journals for this exact connection, so a
  /// bucket with the same name in another account never reuses them.
  var stateURL: URL? {
    Self.containerURL?.appendingPathComponent(
      "Mount/\(accountID)-\(jurisdiction)-\(bucket)", isDirectory: true)
  }

  /// Drops the extension's state once its domain is gone.
  static func removeState(bucket: String) {
    guard let mount = containerURL?.appendingPathComponent("Mount", isDirectory: true),
      let names = try? FileManager.default.contentsOfDirectory(atPath: mount.path)
    else { return }
    for name in names where name == bucket || name.hasSuffix("-\(bucket)") {
      try? FileManager.default.removeItem(at: mount.appendingPathComponent(name))
    }
  }

  static func load() -> SharedConfiguration? {
    guard let data = defaults?.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(SharedConfiguration.self, from: data)
  }

  func save() {
    guard let data = try? JSONEncoder().encode(self) else { return }
    Self.defaults?.set(data, forKey: Self.key)
  }

  static func clear() {
    defaults?.removeObject(forKey: key)
  }

  private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
}
