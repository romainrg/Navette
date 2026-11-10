import Foundation
import NavetteCore
import Observation

/// One tab: a connection to a server and the folder being browsed.
@MainActor @Observable
final class BrowserModel: Identifiable {
    enum Phase: Equatable {
        case connecting
        case connected
        case failed(RemoteError)
    }

    enum SortKey: String, CaseIterable {
        case name, size, modified, kind, permissions, owner
    }

    /// The steps of a remote deletion: nothing is deleted before the user has seen the list.
    enum Deletion: Equatable {
        case counting
        case ready(RemoteTree)
        case deleting(done: Int, total: Int)
    }

    enum TextPrompt: Identifiable {
        case newFolder
        case rename(RemoteItem)
        case goToPath

        var id: String {
            switch self {
            case .newFolder: "newFolder"
            case .rename(let item): "rename:\(item.path.display)"
            case .goToPath: "goToPath"
            }
        }
    }

    struct Notice: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    nonisolated let id = UUID()
    let bookmark: Bookmark

    private(set) var phase: Phase = .connecting
    private(set) var path: RemotePath = .root
    private(set) var items: [RemoteItem] = [] { didSet { refreshVisible() } }
    private(set) var visibleItems: [RemoteItem] = []
    private(set) var isLoading = false
    private(set) var listError: RemoteError?
    private(set) var capabilities = Capabilities()
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    var selection: Set<RemotePath> = []
    var sortKey: SortKey = .name { didSet { refreshVisible() } }
    var ascending = true { didSet { refreshVisible() } }
    var filter = "" { didSet { refreshVisible() } }
    var showHidden: Bool { didSet { refreshVisible() } }
    var inspectorVisible = false
    var deletion: Deletion?
    var textPrompt: TextPrompt?
    var notice: Notice?

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let prompts: PromptCenter
    @ObservationIgnored private let transfers: TransfersModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var fs: (any RemoteFileSystem)?
    @ObservationIgnored private var transferFS: (any RemoteFileSystem)?
    @ObservationIgnored private var backStack: [RemotePath] = []
    @ObservationIgnored private var forwardStack: [RemotePath] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored var onConnected: ((Bookmark) -> Void)?
    /// Quick Look and "Open With" for this tab.
    @ObservationIgnored lazy var editor = EditCoordinator(
        env: env, tab: id,
        connection: { [weak self] in
            guard let self else { throw RemoteError.cancelled }
            return try self.connection()
        },
        report: { [weak self] title, message in self?.notice = Notice(title: title, message: message) })

    init(bookmark: Bookmark, env: AppEnvironment, prompts: PromptCenter, transfers: TransfersModel, settings: AppSettings) {
        self.bookmark = bookmark
        self.env = env
        self.prompts = prompts
        self.transfers = transfers
        self.settings = settings
        showHidden = settings.showHiddenFiles
    }

    /// For screenshot scenes and previews: a tab already connected and listed.
    convenience init(
        bookmark: Bookmark, env: AppEnvironment, prompts: PromptCenter, transfers: TransfersModel, settings: AppSettings,
        connectedTo fs: any RemoteFileSystem, path: RemotePath, items: [RemoteItem]
    ) {
        self.init(bookmark: bookmark, env: env, prompts: prompts, transfers: transfers, settings: settings)
        self.fs = fs
        self.capabilities = fs.capabilities
        self.path = path
        self.items = items
        self.phase = .connected
    }

    var selectedItems: [RemoteItem] { visibleItems.filter { selection.contains($0.path) } }
    var singleSelection: RemoteItem? { selection.count == 1 ? items.first { $0.path == selection.first } : nil }

    // MARK: - Connection

    func connect(password: String? = nil) {
        phase = .connecting
        Task {
            do {
                let fs = try await env.connector.connect(to: bookmark, password: password, prompts: prompts)
                self.fs = fs
                capabilities = fs.capabilities
                let home = try await fs.home()
                let start = bookmark.path.map { RemotePath.resolve($0, relativeTo: home) } ?? home
                phase = .connected
                onConnected?(bookmark)
                await load(start, record: false)
                if listError != nil, start != home { await load(home, record: false) }
            } catch let error as RemoteError {
                phase = .failed(error)
            } catch {
                phase = .failed(.server(error.localizedDescription))
            }
        }
    }

    func disconnect() {
        reloadTask?.cancel()
        editor.closeAll()
        let connections = [fs, transferFS].compactMap { $0 }
        fs = nil
        transferFS = nil
        Task { for connection in connections { await connection.disconnect() } }
    }

    private func connection() throws -> any RemoteFileSystem {
        guard let fs else { throw RemoteError.connectionLost("") }
        return fs
    }

    private func transferConnection() async throws -> any RemoteFileSystem {
        if let transferFS { return transferFS }
        let primary = try connection()
        let second = await env.connector.transferConnection(for: bookmark, primary: primary, prompts: prompts)
        transferFS = second
        return second
    }

    // MARK: - Navigation

    private func load(_ target: RemotePath, record: Bool) async {
        guard let fs else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let listed = try await fs.list(target)
            guard generation == loadGeneration else { return }
            if record, target != path {
                backStack.append(path)
                forwardStack.removeAll()
            }
            let keptSelection = target == path ? selection : []
            path = target
            items = listed
            capabilities = fs.capabilities
            selection = keptSelection.intersection(Set(listed.map(\.path)))
            listError = nil
            canGoBack = !backStack.isEmpty
            canGoForward = !forwardStack.isEmpty
        } catch let error as RemoteError {
            guard generation == loadGeneration else { return }
            listError = error
            if case .connectionLost = error { phase = .failed(error) }
        } catch {
            listError = .server(error.localizedDescription)
        }
    }

    func navigate(to target: RemotePath) {
        Task { await load(target, record: true) }
    }

    func reload() {
        Task { await load(path, record: false) }
    }

    func goUp() {
        guard !path.isRoot else { return }
        navigate(to: path.parent)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        Task { await load(previous, record: false) }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        Task { await load(next, record: false) }
    }

    /// Double-click: enter a folder, download a file. A symlink is entered when it points to a folder.
    func open(_ item: RemoteItem) {
        switch item.kind {
        case .directory:
            navigate(to: item.path)
        case .symlink:
            Task {
                if let fs, (try? await fs.list(item.path)) != nil {
                    await load(item.path, record: true)
                } else {
                    download([item])
                }
            }
        case .file, .other:
            download([item])
        }
    }

    private func refreshVisible() {
        let needle = NameComparison.key(filter).lowercased()
        var result = items.filter { item in
            (showHidden || !item.isHidden) && (needle.isEmpty || NameComparison.key(item.name).lowercased().contains(needle))
        }
        let ascending = ascending
        let key = sortKey
        result.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let ordered: Bool?
            switch key {
            case .name: ordered = nil
            case .size: ordered = (a.size ?? 0) == (b.size ?? 0) ? nil : (a.size ?? 0) < (b.size ?? 0)
            case .modified:
                let (x, y) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
                ordered = x == y ? nil : x < y
            case .kind:
                let (x, y) = (Format.kind(of: a), Format.kind(of: b))
                ordered = x == y ? nil : x.localizedStandardCompare(y) == .orderedAscending
            case .permissions: ordered = (a.permissions ?? 0) == (b.permissions ?? 0) ? nil : (a.permissions ?? 0) < (b.permissions ?? 0)
            case .owner: ordered = (a.owner ?? "") == (b.owner ?? "") ? nil : (a.owner ?? "") < (b.owner ?? "")
            }
            let byName = NameComparison.ascending(a.name, b.name)
            return ascending ? (ordered ?? byName) : !(ordered ?? byName)
        }
        visibleItems = result
    }

    // MARK: - Changes

    private func perform(_ title: String, _ action: @escaping (any RemoteFileSystem) async throws -> Void) {
        Task {
            do {
                try await action(try connection())
            } catch let error as RemoteError {
                notice = Notice(title: title, message: error.message)
            } catch {
                notice = Notice(title: title, message: error.localizedDescription)
            }
            await load(path, record: false)
        }
    }

    func isValidName(_ name: String) -> Bool {
        TransferPlanner.isSafeName(name)
    }

    func makeFolder(named name: String) {
        guard isValidName(name) else { return }
        let target = path.appending(name)
        perform(String(localized: "The folder could not be created.")) { fs in
            try await fs.makeDirectory(target)
        }
    }

    /// Renaming never replaces an existing item.
    func rename(_ item: RemoteItem, to name: String) {
        guard isValidName(name), name != item.name else { return }
        let target = item.path.parent.appending(name)
        perform(String(localized: "The item could not be renamed.")) { fs in
            try await fs.rename(item.path, to: target, overwrite: false)
        }
    }

    func go(toTypedPath text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        navigate(to: RemotePath.resolve(trimmed, relativeTo: path))
    }

    func setPermissions(_ permissions: PermissionSet, of item: RemoteItem, recursive: Bool) {
        perform(String(localized: "The permissions could not be changed.")) { fs in
            guard recursive, item.isDirectory else {
                try await fs.setPermissions(permissions.bits, of: item.path)
                return
            }
            let tree = try await RemoteEnumerator.enumerate([item], on: fs)
            let failures = await PermissionChanger.apply(permissions, to: tree, on: fs)
            if let first = failures.first { throw first.error }
        }
    }

    // MARK: - Deletion

    /// Lists everything the selection contains, then waits for the user's confirmation.
    func requestDeletion() {
        let selected = selectedItems
        guard !selected.isEmpty, deletion == nil else { return }
        deletion = .counting
        Task {
            do {
                let tree = try await RemoteEnumerator.enumerate(selected, on: try connection())
                if deletion == .counting { deletion = .ready(tree) }
            } catch let error as RemoteError {
                deletion = nil
                notice = Notice(title: String(localized: "The selection could not be listed."), message: error.message)
            } catch {
                deletion = nil
            }
        }
    }

    func cancelDeletion() {
        if case .deleting = deletion { return }
        deletion = nil
    }

    func confirmDeletion() {
        guard case .ready(let tree) = deletion, let fs else { return }
        deletion = .deleting(done: 0, total: tree.items.count)
        Task {
            let report = await RemoteDeleter.delete(tree, on: fs) { done in
                Task { @MainActor in
                    if case .deleting(_, let total) = self.deletion { self.deletion = .deleting(done: done, total: total) }
                }
            }
            deletion = nil
            if let first = report.failures.first {
                notice = Notice(
                    title: String(localized: "\(report.failures.count) items could not be deleted."),
                    message: first.error.message)
            }
            await load(path, record: false)
        }
    }

    // MARK: - Transfers

    private var connectForTransfers: TransferEngine.Connect {
        { [weak self] in
            guard let self else { throw RemoteError.cancelled }
            return try await self.transferConnection()
        }
    }

    private func enqueue(_ plan: TransferPlan) {
        transfers.enqueue(plan.items, serverKey: id.uuidString, serverName: bookmark.displayName, connect: connectForTransfers)
        if !plan.skipped.isEmpty {
            notice = Notice(
                title: String(localized: "\(plan.skipped.count) items were left out."),
                message: String(localized: "Symbolic links that point outside the selection and unreadable folders are not transferred:\n\(plan.skipped.prefix(8).joined(separator: "\n"))"))
        }
    }

    func download(_ selected: [RemoteItem], to directory: URL? = nil) {
        guard !selected.isEmpty else { return }
        Task {
            do {
                enqueue(try await TransferPlanner.downloads(of: selected, on: try connection(), to: directory ?? settings.downloadFolder))
            } catch let error as RemoteError {
                notice = Notice(title: String(localized: "The download could not start."), message: error.message)
            } catch {}
        }
    }

    func upload(_ urls: [URL], into directory: RemotePath? = nil) {
        guard !urls.isEmpty, phase == .connected else { return }
        do {
            enqueue(try TransferPlanner.uploads(of: urls, to: directory ?? path, files: env.files))
        } catch {
            notice = Notice(title: String(localized: "The upload could not start."), message: error.localizedDescription)
        }
    }

    /// For a drag to Finder: downloads into the folder Finder chose and returns when the files are there.
    func deliverPromise(of item: RemoteItem, to url: URL) async throws {
        var plan = try await TransferPlanner.downloads(of: [item], on: try connection(), to: url.deletingLastPathComponent())
        if item.kind != .directory, plan.items.count == 1 { plan.items[0].local = url }
        transfers.enqueue(plan.items, serverKey: id.uuidString, serverName: bookmark.displayName, connect: connectForTransfers)
        if let failure = await transfers.waitForCompletion(of: Set(plan.items.map(\.id))) { throw failure }
    }

    /// Refreshes the listing shortly after an upload lands in the folder on screen.
    func transferFinished(_ item: TransferItem) {
        guard item.direction == .upload, item.remote.parent == path || item.remote.isDescendant(of: path) else { return }
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await load(path, record: false)
        }
    }

    // MARK: - Misc

    func url(of item: RemoteItem) -> String {
        var root = bookmark
        root.path = nil
        let encoded = item.path.display.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.path.display
        return root.urlString + encoded
    }

    func copyURL(of item: RemoteItem) {
        env.copy(url(of: item))
    }
}
