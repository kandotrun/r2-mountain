import AppKit
import MountainCore
import SwiftUI

/// Finder-style list backed by NSTableView, so a drop can target either a folder row
/// or the whole folder that is being shown.
struct FolderTableView: NSViewRepresentable {
  let listing: FolderListing
  var sortOrder: BrowserModel.SortOrder
  var onSortChange: (BrowserModel.SortOrder) -> Void
  var onOpen: (FolderPath) -> Void
  var onGoUp: () -> Void
  var onUpload: ([URL], FolderPath) -> Void
  var onChooseFiles: (FolderPath) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let table = PillTableView()
    table.style = .inset
    table.allowsMultipleSelection = true
    table.allowsColumnReordering = false
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.rowSizeStyle = .custom
    table.rowHeight = 28
    table.backgroundColor = .clear
    for column in Column.allCases {
      let tableColumn = NSTableColumn(identifier: column.identifier)
      tableColumn.title = column.title
      tableColumn.width = column.width
      tableColumn.minWidth = column.minWidth
      tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
      if column != .name {
        tableColumn.resizingMask = .userResizingMask
        tableColumn.headerCell.alignment = column == .size ? .right : .left
      }
      table.addTableColumn(tableColumn)
    }
    let sortKey = Column(rawValue: sortOrder.key)?.rawValue ?? Column.name.rawValue
    table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: sortOrder.ascending)]
    table.onOpenSelection = { [weak coordinator = context.coordinator] in
      coordinator?.openSelection()
    }
    table.onGoUp = { [weak coordinator = context.coordinator] in coordinator?.parent.onGoUp() }
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.openClickedRow(_:))
    table.registerForDraggedTypes([.fileURL])
    let menu = NSMenu()
    menu.delegate = context.coordinator
    table.menu = menu

    let scrollView = NSScrollView()
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    context.coordinator.table = table
    context.coordinator.apply(listing)
    DispatchQueue.main.async {
      table.sizeToFit()
      // Like Finder, the file list owns the keyboard (also after it is rebuilt for a new
      // folder), unless someone is typing into a text field.
      if let window = table.window, !(window.firstResponder is NSText) {
        window.makeFirstResponder(table)
      }
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.apply(listing)
  }

  enum Column: String, CaseIterable {
    case name, size, date

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    var title: String {
      switch self {
      case .name: "名前"
      case .size: "サイズ"
      case .date: "アップロード日時"
      }
    }
    var width: CGFloat {
      switch self {
      case .name: 240
      case .size: 84
      case .date: 180
      }
    }
    var minWidth: CGFloat {
      switch self {
      case .name: 160
      case .size: 70
      case .date: 140
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var parent: FolderTableView
    weak var table: NSTableView?
    private var listing: FolderListing?
    private var rows: [RemoteEntry] = []

    init(_ parent: FolderTableView) { self.parent = parent }

    func apply(_ newListing: FolderListing) {
      guard newListing != listing else { return }
      let samePath = newListing.path == listing?.path
      let selected = samePath ? selectedKeys() : []
      listing = newListing
      rows = sorted(newListing)
      table?.reloadData()
      if samePath {
        let indexes = IndexSet(rows.indices.filter { selected.contains(Data(rows[$0].key.utf8)) })
        table?.selectRowIndexes(indexes, byExtendingSelection: false)
      } else {
        table?.deselectAll(nil)
        table?.scrollRowToVisible(0)
      }
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
      _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
      if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
        parent.onSortChange(BrowserModel.SortOrder(key: key, ascending: descriptor.ascending))
      }
      guard let listing else { return }
      let selected = selectedKeys()
      rows = sorted(listing)
      tableView.reloadData()
      tableView.selectRowIndexes(
        IndexSet(rows.indices.filter { selected.contains(Data(rows[$0].key.utf8)) }),
        byExtendingSelection: false)
    }

    private func sorted(_ listing: FolderListing) -> [RemoteEntry] {
      let descriptor = table?.sortDescriptors.first
      let column = descriptor.flatMap { Column(rawValue: $0.key ?? "") } ?? .name
      let ascending = descriptor?.ascending ?? true
      func ordered(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        entries.sorted { lhs, rhs in
          let result: ComparisonResult =
            switch column {
            case .name: lhs.name.localizedStandardCompare(rhs.name)
            case .size: compare(lhs.size ?? -1, rhs.size ?? -1)
            case .date:
              compare(lhs.lastModified ?? .distantPast, rhs.lastModified ?? .distantPast)
            }
          let resolved =
            result == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : result
          return ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
      }
      return ordered(listing.folders) + ordered(listing.files)
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
      lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    private func selectedKeys() -> Set<Data> {
      guard let table else { return [] }
      return Set(
        table.selectedRowIndexes.compactMap {
          rows.indices.contains($0) ? Data(rows[$0].key.utf8) : nil
        })
    }

    // MARK: Cells

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
        rows.indices.contains(row)
      else { return nil }
      let entry = rows[row]
      let cell =
        tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView
        ?? makeCell(for: column)
      switch column {
      case .name:
        cell.textField?.stringValue = entry.name
        cell.imageView?.image = FileIcons.icon(for: entry)
        cell.toolTip = entry.key
      case .size:
        cell.textField?.stringValue =
          entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
      case .date:
        cell.textField?.stringValue =
          entry.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
      }
      return cell
    }

    private func makeCell(for column: Column) -> NSTableCellView {
      let cell = NSTableCellView()
      cell.identifier = column.identifier
      let text = NSTextField(labelWithString: "")
      text.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
      text.translatesAutoresizingMaskIntoConstraints = false
      if column == .name {
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
      } else {
        text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.alignment = column == .size ? .right : .left
      }
      cell.addSubview(text)
      cell.textField = text
      var constraints = [
        text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      ]
      if column == .name {
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(image)
        cell.imageView = image
        constraints += [
          image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
          image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          image.widthAnchor.constraint(equalToConstant: 18),
          image.heightAnchor.constraint(equalToConstant: 18),
          text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
        ]
      } else {
        constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
      }
      NSLayoutConstraint.activate(constraints)
      return cell
    }

    // MARK: Actions

    func openSelection() {
      guard let table, table.selectedRowIndexes.count == 1,
        rows.indices.contains(table.selectedRow),
        let folder = rows[table.selectedRow].folderPath
      else { return }
      parent.onOpen(folder)
    }

    @objc func openClickedRow(_ sender: NSTableView) {
      let row = sender.clickedRow
      guard rows.indices.contains(row), let folder = rows[row].folderPath else { return }
      parent.onOpen(folder)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      guard let table else { return }
      let clicked = table.clickedRow
      let targets: [RemoteEntry]
      if rows.indices.contains(clicked) {
        targets =
          table.selectedRowIndexes.contains(clicked)
          ? table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
          : [rows[clicked]]
      } else {
        // Opened from the keyboard or VoiceOver: act on the selection.
        targets = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
      }
      if targets.count == 1, let folder = targets[0].folderPath {
        menu.addItem(item("開く") { [weak self] in self?.parent.onOpen(folder) })
        menu.addItem(item("このフォルダにアップロード…") { [weak self] in self?.parent.onChooseFiles(folder) })
        menu.addItem(.separator())
      }
      if !targets.isEmpty {
        let keys = targets.map(\.key)
        menu.addItem(
          item(keys.count == 1 ? "キーをコピー" : "\(keys.count)件のキーをコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(keys.joined(separator: "\n"), forType: .string)
          })
      } else if let path = listing?.path {
        menu.addItem(item("ここにアップロード…") { [weak self] in self?.parent.onChooseFiles(path) })
      }
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
      let item = NSMenuItem(
        title: title, action: #selector(ClosureMenuTarget.runAction), keyEquivalent: "")
      let target = ClosureMenuTarget(action)
      item.target = target
      item.representedObject = target
      return item
    }

    // MARK: Drop

    func tableView(
      _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
      proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
      guard !fileURLs(info).isEmpty, listing != nil else { return [] }
      if dropOperation == .on, rows.indices.contains(row), rows[row].kind == .folder {
        return .copy
      }
      // Anything else uploads into the folder on screen, highlighted as a whole like Finder.
      tableView.setDropRow(-1, dropOperation: .on)
      return .copy
    }

    func tableView(
      _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
      dropOperation: NSTableView.DropOperation
    ) -> Bool {
      let urls = fileURLs(info)
      guard !urls.isEmpty, let listing else { return false }
      let destination =
        dropOperation == .on && rows.indices.contains(row)
        ? rows[row].folderPath ?? listing.path : listing.path
      parent.onUpload(urls, destination)
      return true
    }

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
      (info.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
  }
}

/// Draws Finder's rounded alternating row bands, including the empty space below the rows.
private final class PillTableView: NSTableView {
  var onOpenSelection: (() -> Void)?
  var onGoUp: (() -> Void)?

  /// Finder keys: Return or Command-Down opens the selected folder, Command-Up goes up.
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.numericPad, .function])
    switch (event.specialKey, modifiers) {
    case (.carriageReturn, []), (.enter, []), (.downArrow, .command):
      onOpenSelection?()
    case (.upArrow, .command):
      onGoUp?()
    default:
      super.keyDown(with: event)
    }
  }

  override func drawBackground(inClipRect clipRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    clipRect.fill()
    let pitch = rowHeight + intercellSpacing.height
    guard pitch > 0 else { return }
    let first = max(0, Int(floor(clipRect.minY / pitch)))
    let last = Int(ceil(clipRect.maxY / pitch))
    NSColor.alternatingContentBackgroundColors[1].setFill()
    for row in first...max(first, last) where row % 2 == 1 {
      let band = NSRect(x: 0, y: CGFloat(row) * pitch, width: bounds.width, height: pitch)
        .insetBy(dx: 10, dy: 0)
      NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
    }
  }
}

private final class ClosureMenuTarget: NSObject {
  private let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func runAction() { action() }
}
