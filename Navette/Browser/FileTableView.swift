import AppKit
import NavetteCore
import SwiftUI
import UniformTypeIdentifiers

/// The file list. An `NSTableView` because it stays fluid with tens of thousands of rows and because
/// dragging to Finder needs file promises.
struct FileTableView: NSViewRepresentable {
    let items: [RemoteItem]
    let selection: Set<RemotePath>
    let sortKey: BrowserModel.SortKey
    let ascending: Bool
    let showsPermissions: Bool
    let showsOwner: Bool
    let model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.style = .inset
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 160 : 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.keyHandler = context.coordinator
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    enum Column: String, CaseIterable {
        case name, size, modified, kind, permissions, owner

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .modified: String(localized: "Modified")
            case .kind: String(localized: "Kind")
            case .permissions: String(localized: "Permissions")
            case .owner: String(localized: "Owner")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 280
            case .size: 80
            case .modified: 140
            case .kind: 130
            case .permissions: 90
            case .owner: 90
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate, FileTableKeyHandler {
        let model: BrowserModel
        weak var table: FileTable?
        private var items: [RemoteItem] = []
        private var isSyncing = false
        private let promiseQueue = OperationQueue()

        init(model: BrowserModel) {
            self.model = model
        }

        func apply(_ view: FileTableView) {
            guard let table else { return }
            isSyncing = true
            defer { isSyncing = false }
            table.tableColumn(withIdentifier: .init(Column.permissions.rawValue))?.isHidden = !view.showsPermissions
            table.tableColumn(withIdentifier: .init(Column.owner.rawValue))?.isHidden = !view.showsOwner
            if items != view.items {
                items = view.items
                table.reloadData()
            }
            let rows = IndexSet(items.indices.filter { view.selection.contains(items[$0].path) })
            if table.selectedRowIndexes != rows { table.selectRowIndexes(rows, byExtendingSelection: false) }
            let descriptor = table.sortDescriptors.first
            if descriptor?.key != view.sortKey.rawValue || descriptor?.ascending != view.ascending {
                table.sortDescriptors = [NSSortDescriptor(key: view.sortKey.rawValue, ascending: view.ascending)]
            }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), items.indices.contains(row) else { return nil }
            let item = items[row]
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView) ?? makeCell(column)
            cell.textField?.stringValue = text(for: item, column)
            cell.textField?.textColor = column == .name ? .labelColor : .secondaryLabelColor
            cell.textField?.alphaValue = item.isHidden ? 0.6 : 1
            cell.imageView?.image = column == .name ? FileIcons.icon(for: item) : nil
            return cell
        }

        private func text(for item: RemoteItem, _ column: Column) -> String {
            switch column {
            case .name: item.name
            case .size: item.kind == .directory ? "--" : item.size.map(Format.bytes) ?? "--"
            case .modified: item.modified.map(Format.shortDate) ?? "--"
            case .kind: Format.kind(of: item)
            case .permissions: item.permissions.map { PermissionSet(bits: $0).symbolic } ?? "--"
            case .owner: item.owner ?? "--"
            }
        }

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier(column.rawValue)
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
            text.font = column == .size || column == .permissions ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            text.alignment = column == .size ? .right : .natural
            cell.addSubview(text)
            cell.textField = text
            var constraints = [
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ]
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                constraints += [
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ]
            } else {
                constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }

        // MARK: Selection and sorting

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].path : nil })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(BrowserModel.SortKey.init(rawValue:)) else { return }
            model.sortKey = key
            model.ascending = descriptor.ascending
        }

        @objc func doubleClicked() {
            guard let table, items.indices.contains(table.clickedRow) else { return }
            model.open(items[table.clickedRow])
        }

        // MARK: Keyboard

        func handle(_ event: NSEvent) -> Bool {
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 36 where !command: // Return
                if let item = model.singleSelection { model.textPrompt = .rename(item) }
                return true
            case 49 where !command: // Space
                if let item = model.singleSelection { model.editor.quickLook(item) }
                return true
            case 125 where command: // ⌘↓
                if let item = model.singleSelection { model.open(item) }
                return true
            case 126 where command: // ⌘↑
                model.goUp()
                return true
            default:
                return false
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row = table.clickedRow
            if items.indices.contains(row), !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            let selected = model.selectedItems
            func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let item = ClosureMenuItem(title: title, action: action)
                item.isEnabled = enabled
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            if let single = model.singleSelection {
                add(String(localized: "Open")) { [model] in model.open(single) }
                if single.kind != .directory {
                    add(String(localized: "Quick Look")) { [model] in model.editor.quickLook(single) }
                    let openWith = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    for application in model.editor.applications(for: single) {
                        let name = FileManager.default.displayName(atPath: application.path)
                        let entry = ClosureMenuItem(title: name) { [model] in model.editor.open(single, with: application) }
                        let icon = NSWorkspace.shared.icon(forFile: application.path)
                        icon.size = NSSize(width: 16, height: 16)
                        entry.image = icon
                        submenu.addItem(entry)
                    }
                    if !submenu.items.isEmpty { submenu.addItem(.separator()) }
                    submenu.addItem(ClosureMenuItem(title: String(localized: "Other…")) { [model] in
                        let panel = NSOpenPanel()
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.allowedContentTypes = [.application]
                        panel.prompt = String(localized: "Open")
                        if panel.runModal() == .OK, let application = panel.url { model.editor.open(single, with: application) }
                    })
                    openWith.submenu = submenu
                    menu.addItem(openWith)
                }
            }
            if !selected.isEmpty {
                add(String(localized: "Download")) { [model] in model.download(selected) }
                add(String(localized: "Download to…")) { [model] in
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = String(localized: "Download")
                    if panel.runModal() == .OK, let url = panel.url { model.download(selected, to: url) }
                }
                menu.addItem(.separator())
            }
            if let single = model.singleSelection {
                add(String(localized: "Rename…")) { [model] in model.textPrompt = .rename(single) }
                add(String(localized: "Copy URL")) { [model] in model.copyURL(of: single) }
                add(String(localized: "Get Info")) { [model] in model.inspectorVisible = true }
            }
            if !selected.isEmpty {
                add(String(localized: "Delete…")) { [model] in model.requestDeletion() }
                menu.addItem(.separator())
            }
            add(String(localized: "New Folder…")) { [model] in model.textPrompt = .newFolder }
            add(String(localized: "Upload…")) { [model] in NavetteCommands.chooseUploads(for: model) }
            add(String(localized: "Reload")) { [model] in model.reload() }
        }

        // MARK: Drag to Finder (file promises)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = item
            return provider
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? RemoteItem)?.name ?? "download"
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let item = filePromiseProvider.userInfo as? RemoteItem else {
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            Task { @MainActor in
                do {
                    try await self.model.deliverPromise(of: item, to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        // MARK: Drop from Finder

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Drags that started in this list are for Finder, not for the list itself.
            if info.draggingSource as? NSTableView === tableView { return [] }
            if dropOperation == .on, items.indices.contains(row), items[row].isDirectory {
                return .copy
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            let target = items.indices.contains(row) && items[row].isDirectory ? items[row].path : nil
            model.upload(urls, into: target)
            return true
        }
    }
}

@MainActor
protocol FileTableKeyHandler: AnyObject {
    /// Returns true when the key was used.
    func handle(_ event: NSEvent) -> Bool
}

final class FileTable: NSTableView {
    weak var keyHandler: FileTableKeyHandler?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.handle(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
