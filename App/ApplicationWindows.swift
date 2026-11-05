import AppKit
import SwiftUI

@MainActor
final class ApplicationWindows: NSObject, NSWindowDelegate {
  static let shared = ApplicationWindows()

  private var mainWindow: NSWindow?
  private var settingsWindow: NSWindow?

  func showMain(revealingTransfers: Bool = false) {
    if revealingTransfers { UserDefaults.standard.set(true, forKey: "window.showsTransfers") }
    if mainWindow == nil {
      let hosting = NSHostingController(
        rootView: MainWindowView(model: .shared, browser: .shared))
      hosting.sceneBridgingOptions = [.title, .toolbars]
      let window = NSWindow(contentViewController: hosting)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.toolbarStyle = .unified
      window.identifier = NSUserInterfaceItemIdentifier("main")
      window.isReleasedWhenClosed = false
      window.tabbingMode = .disallowed
      window.minSize = NSSize(width: 760, height: 480)
      window.setContentSize(NSSize(width: 1_000, height: 640))
      window.delegate = self
      if !window.setFrameUsingName("S3MountainMain") { window.center() }
      window.setFrameAutosaveName("S3MountainMain")
      #if DEBUG
        // UI checks drop files onto the window without stealing focus from other apps.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-floating") {
          window.level = .floating
        }
      #endif
      mainWindow = window
    }
    present(mainWindow)
  }

  func showSettings() {
    if settingsWindow == nil {
      let hosting = NSHostingController(rootView: SettingsView(model: .shared))
      let window = NSWindow(contentViewController: hosting)
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.title = "接続設定"
      window.identifier = NSUserInterfaceItemIdentifier("connection-settings")
      window.isReleasedWhenClosed = false
      window.tabbingMode = .disallowed
      window.delegate = self
      window.center()
      settingsWindow = window
    }
    present(settingsWindow)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow else { return }
    let otherNormalWindow = NSApp.windows.contains {
      $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
    }
    if !otherNormalWindow { NSApp.setActivationPolicy(.accessory) }
  }

  private func present(_ window: NSWindow?) {
    guard let window else { return }
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
