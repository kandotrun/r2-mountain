import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var finishing = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--show-window") || arguments.contains("--setup-file")
      || UploadViewModel.shared.settings.accountID.isEmpty
    {
      ApplicationWindows.shared.showMain()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    ApplicationWindows.shared.showMain()
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !finishing else { return .terminateLater }
    let model = UploadViewModel.shared
    if model.hasWorkToFinish {
      let alert = NSAlert()
      alert.messageText = "転送を止めて終了しますか？"
      alert.informativeText = "進捗を保存し、次回の起動時に続きから再開します。"
      alert.addButton(withTitle: "保存して終了")
      alert.addButton(withTitle: "転送を続ける")
      alert.alertStyle = .informational
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }
    finishing = true
    Task {
      await model.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
