import AppKit
import MountainCore
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
  @ObservedObject var model: UploadViewModel
  @ObservedObject var browser: BrowserModel
  @AppStorage("window.showsTransfers") private var showsTransfers = true
  @State private var showsNewFolder = false

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model, browser: browser)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
    } detail: {
      Group {
        if model.isConfigured {
          FolderBrowserView(model: model, browser: browser)
        } else {
          ContentUnavailableView {
            Label("R2 に接続されていません", systemImage: "externaldrive.badge.xmark")
          } description: {
            Text("アカウント ID、アクセスキー、バケットを設定すると、フォルダを選んでアップロードできます。")
          } actions: {
            Button("接続を設定…") { ApplicationWindows.shared.showSettings() }
              .buttonStyle(.glassProminent)
              .controlSize(.large)
          }
        }
      }
      .navigationTitle(
        browser.isConnected ? browser.displayName(of: browser.current) : "S3 Mountain"
      )
      .navigationSubtitle(
        browser.isConnected && !browser.current.isRoot
          ? browser.displayPath(of: browser.current) : ""
      )
    }
    .inspector(isPresented: $showsTransfers) {
      TransfersPanel(model: model)
        .inspectorColumnWidth(min: 290, ideal: 330, max: 440)
    }
    .toolbar { toolbar }
    .frame(minWidth: 760, minHeight: 480)
    .onChange(of: model.jobs.count) { previous, count in
      if count > previous { showsTransfers = true }
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button(action: browser.goBack) { Label("戻る", systemImage: "chevron.backward") }
        .help("戻る")
        .disabled(!browser.history.canGoBack)
        .keyboardShortcut("[", modifiers: .command)
      Button(action: browser.goForward) { Label("進む", systemImage: "chevron.forward") }
        .help("進む")
        .disabled(!browser.history.canGoForward)
        .keyboardShortcut("]", modifiers: .command)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: browser.reload) { Label("再読み込み", systemImage: "arrow.clockwise") }
        .help("再読み込み")
        .disabled(!browser.isConnected)
        .keyboardShortcut("r", modifiers: .command)
      Button {
        showsNewFolder = true
      } label: {
        Label("新規フォルダ", systemImage: "folder.badge.plus")
      }
      .help("このフォルダに新規フォルダを作成")
      .disabled(!browser.isConnected)
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .popover(isPresented: $showsNewFolder, arrowEdge: .bottom) {
        NewFolderForm(browser: browser) { showsNewFolder = false }
      }
      Button {
        model.chooseFiles()
      } label: {
        Label("アップロード", systemImage: "icloud.and.arrow.up")
      }
      .help("ファイルを選んでこのフォルダにアップロード")
      .disabled(!model.isConfigured)
      .keyboardShortcut("o", modifiers: .command)
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      Button {
        showsTransfers.toggle()
      } label: {
        TransfersToolbarLabel(summary: model.summary)
      }
      .help(showsTransfers ? "転送状況を隠す" : "転送状況を表示")
    }
  }
}

private struct TransfersToolbarLabel: View {
  let summary: TransferSummary

  var body: some View {
    if summary.activeCount > 0, let progress = summary.overallProgress {
      Label {
        Text("転送状況")
      } icon: {
        ZStack {
          Circle().stroke(.quaternary, lineWidth: 2.5)
          Circle().trim(from: 0, to: progress)
            .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
        }
        .frame(width: 16, height: 16)
      }
    } else if summary.attentionCount > 0 {
      Label("転送状況", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
        .symbolRenderingMode(.multicolor)
    } else {
      Label("転送状況", systemImage: "arrow.up.circle")
    }
  }
}

// MARK: - Sidebar

private struct SidebarView: View {
  @ObservedObject var model: UploadViewModel
  @ObservedObject var browser: BrowserModel

  var body: some View {
    List(selection: selection) {
      if browser.isConnected {
        Section("バケット") {
          SidebarFolderRow(
            title: browser.bucketName, systemImage: "externaldrive", path: .root)
        }
        let recents = browser.recents.items.filter { !$0.isRoot }
        if !recents.isEmpty {
          Section("最近の保存先") {
            ForEach(recents, id: \.self) { path in
              SidebarFolderRow(
                title: browser.displayName(of: path), systemImage: "folder", path: path,
                subtitle: path.parent.map(browser.displayPath(of:))
              )
              .help(browser.displayPath(of: path))
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Button {
          ApplicationWindows.shared.showSettings()
        } label: {
          Label("接続設定", systemImage: "gearshape")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(",", modifiers: .command)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  private var selection: Binding<FolderPath?> {
    Binding(
      get: { browser.current },
      set: { path in if let path { browser.open(path) } }
    )
  }
}

private struct SidebarFolderRow: View {
  let title: String
  let systemImage: String
  let path: FolderPath
  var subtitle: String?

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1)
        if let subtitle {
          // Same-named folders in different places stay distinguishable.
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.head)
        }
      }
    } icon: {
      Image(systemName: systemImage).foregroundStyle(.secondary)
    }
    .tag(path)
  }
}

// MARK: - Folder browser

private struct FolderBrowserView: View {
  @ObservedObject var model: UploadViewModel
  @ObservedObject var browser: BrowserModel
  @State private var dropTargeted = false

  var body: some View {
    content
      .safeAreaInset(edge: .bottom, spacing: 0) {
        PathBar(browser: browser).padding(.horizontal, 14).padding(.bottom, 12)
      }
      .safeAreaInset(edge: .top, spacing: 0) { MessageBanners(model: model) }
      .overlay { if dropTargeted { DropOverlay(title: browser.displayName(of: browser.current)) } }
      // The table handles its own drops; this covers empty, loading and error states.
      .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
        model.acceptDrop(providers, to: browser.current)
      }
      .animation(.smooth(duration: 0.2), value: dropTargeted)
  }

  @ViewBuilder private var content: some View {
    if let listing = browser.listing {
      if listing.folders.isEmpty && listing.files.isEmpty {
        emptyFolder
      } else {
        FolderTableView(
          listing: listing,
          sortOrder: browser.sortOrder,
          onSortChange: { browser.sortOrder = $0 },
          onOpen: browser.open,
          onGoUp: browser.goUp,
          onUpload: { urls, destination in model.enqueue(urls, to: destination) },
          onChooseFiles: { destination in model.chooseFiles(to: destination) }
        )
      }
    } else {
      switch browser.state {
      case .failed(let message):
        ContentUnavailableView {
          Label("フォルダを読み込めません", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("再読み込み", action: browser.reload).buttonStyle(.glass)
        }
      default:
        ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var emptyFolder: some View {
    ContentUnavailableView {
      Label("このフォルダは空です", systemImage: "folder")
    } description: {
      Text("ファイルやフォルダをここにドロップすると、「\(browser.displayName(of: browser.current))」にアップロードします。")
    } actions: {
      Button("ファイルを選択…") { model.chooseFiles() }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
  }
}

private struct PathBar: View {
  @ObservedObject var browser: BrowserModel

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Array(browser.current.lineage.enumerated()), id: \.element) { index, path in
        if index > 0 {
          Image(systemName: "chevron.forward")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        Button {
          browser.open(path)
        } label: {
          Label(
            browser.displayName(of: path),
            systemImage: path.isRoot ? "externaldrive.fill" : "folder.fill"
          )
          .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(path == browser.current ? .primary : .secondary)
      }
      Spacer(minLength: 12)
      if let listing = browser.listing {
        Text(itemCount(listing))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
      }
    }
    .font(.callout)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .glassEffect(.regular, in: .capsule)
  }

  private func itemCount(_ listing: FolderListing) -> String {
    var parts: [String] = []
    if !listing.folders.isEmpty { parts.append("フォルダ \(listing.folders.count)") }
    if !listing.files.isEmpty { parts.append("ファイル \(listing.files.count)") }
    if parts.isEmpty { return "空のフォルダ" }
    return parts.joined(separator: "・") + (listing.isTruncated ? "（一部のみ表示）" : "")
  }
}

private struct DropOverlay: View {
  let title: String

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
        .background(
          Color.accentColor.opacity(0.06),
          in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(10)
      VStack(spacing: 10) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 44, weight: .regular))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.tint)
        Text("ドロップしてアップロード")
          .font(.title3.weight(.semibold))
        Text("保存先：\(title)")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 36)
      .padding(.vertical, 26)
      .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
    .allowsHitTesting(false)
    .transition(.opacity)
  }
}

struct NewFolderForm: View {
  @ObservedObject var browser: BrowserModel
  var onDone: () -> Void
  @State private var name = ""
  @State private var errorText: String?
  @State private var creating = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("新規フォルダ").font(.headline)
      Text("「\(browser.displayName(of: browser.current))」の中に作成して開きます。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("フォルダ名", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit(create)
        .onChange(of: name) { errorText = nil }
      if let errorText {
        Label(errorText, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("キャンセル", role: .cancel, action: onDone)
          .keyboardShortcut(.cancelAction)
        Button(action: create) {
          if creating { ProgressView().controlSize(.small) } else { Text("作成") }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(18)
    .frame(width: 320)
    .onAppear { focused = true }
  }

  private func create() {
    guard !creating else { return }
    creating = true
    Task {
      do {
        try await browser.createFolder(named: name)
        onDone()
      } catch {
        errorText =
          (error as? LocalizedError)?.errorDescription ?? UploadViewModel.userMessage(for: error)
      }
      creating = false
    }
  }
}

struct MessageBanners: View {
  @ObservedObject var model: UploadViewModel

  var body: some View {
    VStack(spacing: 8) {
      if let error = model.errorMessage {
        banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
          model.errorMessage = nil
        }
      }
      if !model.importWarnings.isEmpty {
        let more = model.importWarnings.count > 2 ? "\nほか \(model.importWarnings.count - 2) 件" : ""
        banner(
          text: "追加できなかった項目があります\n"
            + model.importWarnings.prefix(2).joined(separator: "\n") + more,
          systemImage: "info.circle.fill", tint: .secondary, dismiss: model.dismissImportWarnings)
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, model.errorMessage == nil && model.importWarnings.isEmpty ? 0 : 10)
  }

  private func banner(
    text: String, systemImage: String, tint: Color, dismiss: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: systemImage).foregroundStyle(tint)
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: dismiss) { Image(systemName: "xmark") }
        .buttonStyle(.borderless)
        .accessibilityLabel("閉じる")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .rect(cornerRadius: 14))
  }
}

@MainActor
enum FileIcons {
  private static var cache: [String: NSImage] = [:]

  static func icon(for entry: RemoteEntry) -> NSImage {
    entry.kind == .folder ? icon(for: .folder) : icon(forName: entry.name)
  }

  static func icon(forName name: String) -> NSImage {
    let ext = (name as NSString).pathExtension.lowercased()
    return icon(for: UTType(filenameExtension: ext) ?? .data)
  }

  private static func icon(for type: UTType) -> NSImage {
    if let cached = cache[type.identifier] { return cached }
    let image = NSWorkspace.shared.icon(for: type)
    cache[type.identifier] = image
    return image
  }
}
