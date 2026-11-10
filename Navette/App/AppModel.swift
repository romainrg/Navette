import Foundation
import NavetteCore
import Observation

/// What the connection sheet edits.
struct BookmarkEditor: Identifiable {
    let id = UUID()
    var bookmark: Bookmark
    var password = ""
    var savePassword = true
    /// A bookmark that is not in the library yet.
    var isNew: Bool
    /// Where a new bookmark goes.
    var folder: UUID?
}

/// The window's state: bookmarks, open tabs, prompts and transfers.
@MainActor @Observable
final class AppModel {
    let env: AppEnvironment
    let settings: AppSettings
    let prompts: PromptCenter
    let transfers: TransfersModel

    private(set) var library: BookmarkLibrary
    private(set) var tabs: [BrowserModel] = []
    var selectedTab: BrowserModel.ID?
    var editor: BookmarkEditor?
    var newFolderParent: FolderRequest?
    var quickConnectError = false

    struct FolderRequest: Identifiable {
        let id = UUID()
        var parent: UUID?
    }

    init(env: AppEnvironment, prompts: PromptCenter? = nil, transfers: TransfersModel? = nil) {
        self.env = env
        settings = AppSettings(defaults: env.defaults, downloadFolder: env.defaultDownloadFolder)
        self.prompts = prompts ?? PromptCenter()
        self.transfers = transfers ?? TransfersModel(engine: env.engine)
        library = env.bookmarks.library
        self.transfers.onFinished = { [weak self] item in
            self?.tabs.forEach { $0.transferFinished(item) }
        }
        self.prompts.onCertificateTrusted = { [weak self] bookmark, sha256 in
            guard let self, var saved = self.library.bookmark(bookmark.id) else { return }
            saved.trustedCertificateSHA256 = sha256
            self.save { $0.update(saved) }
        }
        applyTransferSettings()
    }

    var currentTab: BrowserModel? { tabs.first { $0.id == selectedTab } }

    func applyTransferSettings() {
        let (policy, concurrent, limit) = (settings.conflictPolicy, settings.maxConcurrentTransfers, settings.rateLimitKB)
        let engine = env.engine
        Task {
            await engine.setPolicy(policy)
            await engine.setMaxConcurrent(concurrent)
            await engine.setRateLimit(bytesPerSecond: limit > 0 ? limit * 1_000 : nil)
        }
    }

    // MARK: - Tabs

    @discardableResult
    func connect(_ bookmark: Bookmark, password: String? = nil) -> BrowserModel {
        let tab = BrowserModel(bookmark: bookmark, env: env, prompts: prompts, transfers: transfers, settings: settings)
        tab.onConnected = { [weak self] bookmark in self?.noteConnection(bookmark) }
        tabs.append(tab)
        selectedTab = tab.id
        tab.connect(password: password)
        return tab
    }

    /// For screenshot scenes: shows a tab that is already connected.
    func adopt(_ tab: BrowserModel) {
        tabs.append(tab)
        selectedTab = tab.id
    }

    func close(_ tab: BrowserModel) {
        tab.disconnect()
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTab == tab.id {
            selectedTab = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func showWelcome() {
        selectedTab = nil
    }

    /// Quick Connect: opens a tab straight from a pasted URL. A password in the URL is used once and never stored.
    func quickConnect(_ text: String) -> Bool {
        guard let parsed = ConnectionURL.parse(text) else {
            quickConnectError = true
            return false
        }
        quickConnectError = false
        connect(parsed.bookmark, password: parsed.password)
        return true
    }

    // MARK: - Bookmarks

    private func save(_ change: (inout BookmarkLibrary) -> Void) {
        change(&library)
        try? env.bookmarks.save(library)
    }

    private func noteConnection(_ bookmark: Bookmark) {
        save { $0.noteConnection(to: bookmark, at: env.isDemo ? DemoData.now : Date()) }
    }

    func newBookmark(in folder: UUID? = nil, from text: String = "") {
        let parsed = ConnectionURL.parse(text)
        var editor = BookmarkEditor(bookmark: parsed?.bookmark ?? Bookmark(), isNew: true, folder: folder)
        editor.password = parsed?.password ?? ""
        self.editor = editor
    }

    func edit(_ bookmark: Bookmark) {
        var editor = BookmarkEditor(bookmark: bookmark, isNew: library.bookmark(bookmark.id) == nil, folder: nil)
        editor.password = ""
        self.editor = editor
    }

    /// Saves the sheet's bookmark and, when asked, its password in the Keychain.
    func commit(_ editor: BookmarkEditor, connect: Bool) {
        var bookmark = editor.bookmark
        bookmark.host = bookmark.host.trimmingCharacters(in: .whitespaces)
        if bookmark.user?.isEmpty == true { bookmark.user = nil }
        if bookmark.path?.isEmpty == true { bookmark.path = nil }
        save { library in
            if !library.update(bookmark) { library.add(.bookmark(bookmark), to: editor.folder) }
        }
        if !editor.password.isEmpty, editor.savePassword {
            try? env.credentials.setSecret(editor.password, for: bookmark.credentialKey)
        }
        self.editor = nil
        if connect { self.connect(bookmark, password: editor.password.isEmpty ? nil : editor.password) }
    }

    func addFolder(named name: String, in parent: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        save { $0.add(.folder(BookmarkFolder(name: trimmed)), to: parent) }
    }

    func duplicate(_ bookmark: Bookmark) {
        var copy = bookmark
        copy.id = UUID()
        copy.name = String(localized: "\(bookmark.displayName) copy")
        save { $0.add(.bookmark(copy)) }
    }

    /// Removes a bookmark or a folder. Saved passwords of removed bookmarks are forgotten too.
    func remove(_ node: BookmarkNode) {
        let removed = BookmarkLibrary(nodes: [node]).allBookmarks
        save { $0.remove(node.id) }
        let remaining = Set(library.allBookmarks.map(\.credentialKey))
        for bookmark in removed where !remaining.contains(bookmark.credentialKey) {
            try? env.credentials.setSecret(nil, for: bookmark.credentialKey)
        }
    }

    func move(_ id: UUID, to folder: UUID?) {
        save { $0.move(id, to: folder) }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        save { $0.rename(id, to: trimmed) }
    }

    var folders: [BookmarkFolder] {
        func collect(_ nodes: [BookmarkNode]) -> [BookmarkFolder] {
            nodes.flatMap { node -> [BookmarkFolder] in
                if case .folder(let folder) = node { return [folder] + collect(folder.children) }
                return []
            }
        }
        return collect(library.nodes)
    }
}
