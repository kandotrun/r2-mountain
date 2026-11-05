import AppKit
import MountainCore
import SwiftUI

struct MenuBarPanel: View {
  @ObservedObject var model: UploadViewModel
  @ObservedObject var browser: BrowserModel
  @ObservedObject var finder: FileProviderDomains
  @State private var dropTargeted = false
  @State private var creatingFolder = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if model.isConfigured {
        DestinationMenu(browser: browser) { creatingFolder = true }
        if creatingFolder {
          InlineNewFolder(browser: browser) { creatingFolder = false }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        uploadCard
        if !model.jobs.isEmpty { recentTransfers }
      } else {
        setupPrompt
      }
      MessageBanners(model: model).padding(.horizontal, -14)
    }
    .padding(16)
    .frame(width: 360)
    .animation(.smooth(duration: 0.2), value: creatingFolder)
    .onAppear(perform: browser.loadIfNeeded)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "mountain.2.fill")
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("R2 Mountain").font(.headline)
        Text(model.isConfigured ? model.summary.headline : "未接続")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        Button("ウィンドウを開く", systemImage: "macwindow") { ApplicationWindows.shared.showMain() }
        if finder.status.isAvailableInFinder {
          Button("Finder で開く", systemImage: "finder") {
            Task {
              do { try await finder.openInFinder() } catch {
                model.errorMessage = UploadViewModel.userMessage(for: error)
              }
            }
          }
        }
        Button("接続設定…", systemImage: "gearshape") { ApplicationWindows.shared.showSettings() }
        Divider()
        Button("R2 Mountain を終了", systemImage: "power") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 18, height: 18)
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .fixedSize()
      .accessibilityLabel("メニュー")
    }
  }

  /// The panel closes when a drag starts elsewhere, so choosing files is the main path here;
  /// drops still work when they can reach the panel.
  private var uploadCard: some View {
    VStack(spacing: 12) {
      Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "icloud.and.arrow.up")
        .font(.system(size: 30))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
      VStack(spacing: 3) {
        Text(dropTargeted ? "離すとアップロード" : "アップロード")
          .font(.headline)
        Text("「\(browser.displayName(of: browser.current))」に送ります")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      HStack(spacing: 8) {
        Button("ファイルを選択…") { model.chooseFiles() }
          .buttonStyle(.glassProminent)
          .keyboardShortcut("o", modifiers: .command)
        Button("ウィンドウにドロップ") { ApplicationWindows.shared.showMain() }
          .buttonStyle(.glass)
          .help("ウィンドウを開いて、ファイルやフォルダをドロップします")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .padding(.horizontal, 12)
    .glassEffect(
      dropTargeted ? .regular.tint(.accentColor.opacity(0.35)) : .regular,
      in: .rect(cornerRadius: 20)
    )
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      model.acceptDrop(providers, to: browser.current)
    }
    .animation(.smooth(duration: 0.2), value: dropTargeted)
  }

  private var recentTransfers: some View {
    let jobs = Array(TransferOrdering.sorted(model.jobs).prefix(3))
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("転送").font(.headline)
        Spacer()
        Button("すべて表示") { ApplicationWindows.shared.showMain(revealingTransfers: true) }
          .buttonStyle(.borderless)
          .font(.callout)
      }
      ForEach(jobs) { job in
        TransferRow(job: job, model: model, compact: true)
        if job.id != jobs.last?.id { Divider() }
      }
    }
  }

  private var setupPrompt: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("R2 を接続しましょう").font(.title3.weight(.semibold))
      Text("アカウント ID、アクセスキー、バケットを設定すると、ここからアップロードできます。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("接続を設定…") { ApplicationWindows.shared.showSettings() }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
  }
}

/// Shows where uploads go and offers quick ways to change it.
private struct DestinationMenu: View {
  private static let folderLimit = 25
  @ObservedObject var browser: BrowserModel
  var onNewFolder: () -> Void

  var body: some View {
    Menu {
      let parents = browser.current.lineage.dropLast().reversed()
      if !parents.isEmpty {
        Section("上の階層") {
          ForEach(Array(parents), id: \.self) { path in
            folderButton(path)
          }
        }
      }
      if let folders = browser.listing?.folders, !folders.isEmpty {
        Section("この中のフォルダ") {
          ForEach(folders.prefix(Self.folderLimit), id: \.self) { entry in
            if let path = entry.folderPath { folderButton(path) }
          }
          if folders.count > Self.folderLimit || browser.listing?.isTruncated == true {
            Button("ほかのフォルダをウィンドウで選ぶ…") { ApplicationWindows.shared.showMain() }
          }
        }
      }
      let recents = browser.recents.items.filter { $0 != browser.current }
      if !recents.isEmpty {
        Section("最近の保存先") {
          ForEach(recents, id: \.self) { path in
            Button(browser.displayPath(of: path), systemImage: "clock") { browser.open(path) }
          }
        }
      }
      Divider()
      Button("新規フォルダ…", systemImage: "folder.badge.plus", action: onNewFolder)
      Button("ウィンドウで選ぶ…", systemImage: "macwindow") { ApplicationWindows.shared.showMain() }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: browser.current.isRoot ? "externaldrive.fill" : "folder.fill")
          .font(.title3)
          .foregroundStyle(.tint)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text("保存先")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(browser.displayPath(of: browser.current))
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.head)
        }
        Spacer(minLength: 6)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    .help(browser.displayPath(of: browser.current))
  }

  private func folderButton(_ path: FolderPath) -> some View {
    Button(
      browser.displayName(of: path),
      systemImage: path.isRoot ? "externaldrive" : "folder"
    ) { browser.open(path) }
  }
}

private struct InlineNewFolder: View {
  @ObservedObject var browser: BrowserModel
  var onDone: () -> Void
  @State private var name = ""
  @State private var errorText: String?
  @State private var creating = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        TextField("新しいフォルダの名前", text: $name)
          .textFieldStyle(.roundedBorder)
          .focused($focused)
          .onSubmit(create)
          .onExitCommand(perform: onDone)
          .onChange(of: name) { errorText = nil }
        Button(action: create) {
          if creating { ProgressView().controlSize(.small) } else { Text("作成") }
        }
        .buttonStyle(.glassProminent)
        .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button(action: onDone) { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
          .accessibilityLabel("キャンセル")
      }
      if let errorText {
        Text(errorText).font(.callout).foregroundStyle(.red)
      } else {
        Text("「\(browser.displayName(of: browser.current))」の中に作成します。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
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
