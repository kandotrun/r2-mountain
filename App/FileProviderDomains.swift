import AppKit
import FileProvider
import Foundation
import MountainCore
import os

/// Shows the configured bucket in Finder's Locations through the File Provider extension.
private let domainLog = Logger(subsystem: "run.kan.s3mountain", category: "finder")

@MainActor
final class FileProviderDomains: ObservableObject {
  typealias Status = FinderStatus

  static let shared = FileProviderDomains()

  @Published private(set) var isEnabled: Bool
  @Published private(set) var status: Status = .off
  private let controller = FinderDomainController(system: FileProviderSystem())
  private var domainObserver: (any NSObjectProtocol)?

  private init() {
    isEnabled = controller.isEnabled
    controller.onChange = { [weak self] in
      guard let self else { return }
      isEnabled = controller.isEnabled
      status = controller.status
    }
    domainObserver = NotificationCenter.default.addObserver(
      forName: .fileProviderDomainDidChange, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in await FileProviderDomains.shared.refresh() }
    }
  }

  func setEnabled(_ enabled: Bool) async { await controller.setEnabled(enabled) }

  /// Old domains are removed before the extension is told the new connection, then the new
  /// domain is added. `nil` means the settings name no bucket.
  func bucketDidChange(to connection: FinderConnection?) async {
    await controller.connectionDidChange(to: connection)
  }

  func refresh() async { await controller.refresh() }

  func openInFinder() async throws {
    guard status.isAvailableInFinder, let id = controller.domainID,
      let manager = NSFileProviderManager(for: FileProviderSystem.domain(for: id))
    else { throw FinderError.unavailable }
    let url: URL
    do { url = try await manager.getUserVisibleURL(for: .rootContainer) } catch {
      throw FinderError.unavailable
    }
    NSWorkspace.shared.open(url)
  }

  /// Asks the extension to look for changes made outside Finder, such as uploads from this app.
  func signalChanges() { controller.signalChanges() }

  /// Items File Provider backed off from (for a missing key or no network) retry right away.
  func resolveErrors(_ code: NSFileProviderError.Code) {
    Task {
      for domain in (try? await NSFileProviderManager.domains()) ?? [] {
        NSFileProviderManager(for: domain)?.signalErrorResolved(NSFileProviderError(code)) { _ in }
      }
    }
  }
}

@MainActor
private final class FileProviderSystem: FinderDomainSystem {
  private static let enabledKey = "finder.enabled"
  private static let connectionKey = "finder.connection"

  var record: FinderDomainRecord {
    get {
      let defaults = UserDefaults.standard
      return FinderDomainRecord(
        isEnabled: defaults.bool(forKey: Self.enabledKey),
        connection: defaults.data(forKey: Self.connectionKey).flatMap {
          try? JSONDecoder().decode(FinderConnection.self, from: $0)
        })
    }
    set {
      let defaults = UserDefaults.standard
      defaults.set(newValue.isEnabled, forKey: Self.enabledKey)
      defaults.set(
        newValue.connection.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.connectionKey)
    }
  }

  func domains() async throws -> [FinderDomainState] {
    try await NSFileProviderManager.domains().map {
      FinderDomainState(id: $0.identifier.rawValue, userEnabled: $0.userEnabled)
    }
  }

  func addDomain(_ id: String) async throws {
    try await NSFileProviderManager.add(Self.domain(for: id))
  }

  func removeDomain(_ id: String) async throws {
    let registered = try await NSFileProviderManager.domains()
    guard let domain = registered.first(where: { $0.identifier.rawValue == id }) else { return }
    let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
    SharedConfiguration.removeState(bucket: id)
    revealIfNotEmpty(preserved)
  }

  func signalDomain(_ id: String) {
    NSFileProviderManager(for: Self.domain(for: id))?.signalEnumerator(for: .workingSet) { error in
      if let error {
        domainLog.notice("signal failed: \(String(describing: error), privacy: .public)")
      } else {
        domainLog.debug("signalled working set")
      }
    }
  }

  func publish(_ connection: FinderConnection?) {
    guard let connection else {
      SharedConfiguration.clear()
      return
    }
    SharedConfiguration(
      accountID: connection.accountID, bucket: connection.bucket,
      jurisdiction: connection.jurisdiction, accessKeyID: connection.accessKeyID
    ).save()
    FileProviderDomains.shared.resolveErrors(.notAuthenticated)
  }

  static func domain(for bucket: String) -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(rawValue: bucket), displayName: bucket)
    domain.supportsSyncingTrash = false
    #if DEBUG
      // Debug builds use a personal team, so skip the manual switch in System Settings.
      domain.testingModes = [.alwaysEnabled]
    #endif
    return domain
  }

  /// Files edited in Finder but not yet uploaded survive removal; show them so they are not lost.
  private func revealIfNotEmpty(_ url: URL?) {
    guard let url,
      let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
      !contents.isEmpty
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

private enum FinderError: LocalizedError {
  case unavailable

  var errorDescription: String? {
    "Finder で開けません。接続設定の「Finder」で状態を確認してください。"
  }
}
