import AppKit
import UniformTypeIdentifiers

@MainActor
enum SourceImporter {
  static func chooseFiles(destinationName: String) -> [URL] {
    let panel = NSOpenPanel()
    panel.title = "アップロードするファイルやフォルダを選択"
    panel.message = "「\(destinationName)」にアップロードします。"
    panel.prompt = "アップロード"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = false
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.urls : []
  }

  /// Resolves every dropped file URL before calling back once, so one drop becomes one batch.
  static func accept(
    _ providers: [NSItemProvider],
    receive: @escaping @MainActor ([URL]) -> Void
  ) -> Bool {
    let supported = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    guard !supported.isEmpty else { return false }
    Task { @MainActor in
      var urls: [URL] = []
      for provider in supported {
        if let url = await fileURL(from: provider) { urls.append(url) }
      }
      receive(urls)
    }
    return true
  }

  private static func fileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
        let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        continuation.resume(returning: url?.isFileURL == true ? url : nil)
      }
    }
  }
}
