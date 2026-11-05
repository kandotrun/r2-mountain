import FileProvider
import Foundation

/// Registers the bucket as a File Provider domain so it appears in Finder.
@MainActor
enum FileProviderDomains {
  static func register(bucket: String, testing: Bool) async throws {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(rawValue: bucket), displayName: bucket)
    domain.supportsSyncingTrash = false
    #if DEBUG
      if testing { domain.testingModes = [.alwaysEnabled] }
    #endif
    try await NSFileProviderManager.add(domain)
  }

  static func domains() async throws -> [NSFileProviderDomain] {
    try await NSFileProviderManager.domains()
  }
}
