import MountainCore
import SwiftUI

/// The menu bar icon is the only signal when the window is closed, so problems show there too.
enum MenuBarSymbol {
  static func name(for summary: TransferSummary) -> String {
    if summary.attentionCount > 0 { return "exclamationmark.icloud" }
    if summary.activeCount > 0 { return "arrow.up.circle.fill" }
    return "mountain.2"
  }
}

@main
struct R2MountainApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = UploadViewModel.shared
  @StateObject private var browser = BrowserModel.shared
  @StateObject private var finder = FileProviderDomains.shared

  var body: some Scene {
    MenuBarExtra {
      MenuBarPanel(model: model, browser: browser, finder: finder)
    } label: {
      let summary = model.summary
      Image(systemName: MenuBarSymbol.name(for: summary))
        .accessibilityLabel("R2 Mountain、\(summary.headline)")
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("接続設定…") { ApplicationWindows.shared.showSettings() }
          .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}
