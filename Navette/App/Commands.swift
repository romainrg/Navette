import AppKit
import SwiftUI

/// The menu bar: every browser action has a menu item and a shortcut.
struct NavetteCommands: Commands {
    let model: AppModel

    private var tab: BrowserModel? {
        guard let tab = model.currentTab, tab.phase == .connected else { return nil }
        return tab
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { model.showWelcome() }.keyboardShortcut("t")
            Button("Quick Connect") { model.showWelcome() }.keyboardShortcut("k")
            Button("New Bookmark…") { model.newBookmark() }.keyboardShortcut("b")
            Button("Close Tab") { model.currentTab.map(model.close) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.currentTab == nil)
            Divider()
            Button("New Folder…") { tab?.textPrompt = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Button("Upload…") { tab.map(Self.chooseUploads) }
                .keyboardShortcut("u")
                .disabled(tab == nil)
            Button("Download") { tab.map { $0.download($0.selectedItems) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(tab?.selection.isEmpty != false)
            Button("Rename…") { if let tab, let item = tab.singleSelection { tab.textPrompt = .rename(item) } }
                .disabled(tab?.singleSelection == nil)
            Button("Delete…") { tab?.requestDeletion() }
                .keyboardShortcut(.delete)
                .disabled(tab?.selection.isEmpty != false)
            Button("Get Info") { tab?.inspectorVisible.toggle() }
                .keyboardShortcut("i")
                .disabled(tab == nil)
        }
        CommandMenu("Go") {
            Button("Back") { tab?.goBack() }.keyboardShortcut("[").disabled(tab?.canGoBack != true)
            Button("Forward") { tab?.goForward() }.keyboardShortcut("]").disabled(tab?.canGoForward != true)
            Button("Enclosing Folder") { tab?.goUp() }.keyboardShortcut(.upArrow).disabled(tab == nil)
            Button("Go to Folder…") { tab?.textPrompt = .goToPath }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Divider()
            Button("Reload") { tab?.reload() }.keyboardShortcut("r").disabled(tab == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Show or Hide Hidden Files") { tab?.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Button("Show or Hide Transfers") { model.transfers.drawerVisible.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }

    /// The system's open panel: files and folders, several at once.
    static func chooseUploads(for tab: BrowserModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        if panel.runModal() == .OK { tab.upload(panel.urls) }
    }
}
