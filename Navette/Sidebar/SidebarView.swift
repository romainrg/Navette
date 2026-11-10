import NavetteCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var collapsed: Set<UUID> = []
    @State private var renaming: RenameRequest?
    @State private var removing: BookmarkNode?
    @State private var folderName = ""

    struct RenameRequest: Identifiable {
        let id: UUID
        var name: String
    }

    var body: some View {
        List {
            Section("Bookmarks") {
                if model.library.nodes.isEmpty {
                    Text("No bookmarks yet").foregroundStyle(.secondary)
                }
                NodeRows(nodes: model.library.nodes, sidebar: self)
            }
            if !model.library.recents.isEmpty {
                Section("Recent") {
                    ForEach(model.library.recents) { recent in
                        BookmarkRow(bookmark: recent.bookmark)
                            .onTapGesture(count: 2) { model.connect(recent.bookmark) }
                            .contextMenu {
                                Button("Connect") { model.connect(recent.bookmark) }
                                Button("Save as Bookmark…") { model.edit(recent.bookmark) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Button { model.newBookmark() } label: { Label("Bookmark", systemImage: "plus") }
                    .help("New Bookmark…")
                Button { model.newFolderParent = .init(parent: nil) } label: { Label("Folder", systemImage: "folder.badge.plus") }
                    .help("New Folder…")
                Spacer()
            }
            .buttonStyle(.soft)
            .controlSize(.small)
            .padding(10)
        }
        .alert("New Folder", isPresented: folderBinding) {
            TextField("Name", text: $folderName)
            Button("Create") {
                model.addFolder(named: folderName, in: model.newFolderParent?.parent)
                folderName = ""
                model.newFolderParent = nil
            }
            Button("Cancel", role: .cancel) {
                folderName = ""
                model.newFolderParent = nil
            }
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("Name", text: Binding(get: { renaming?.name ?? "" }, set: { renaming?.name = $0 }))
            Button("Rename") {
                if let renaming { model.rename(renaming.id, to: renaming.name) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?", isPresented: removeBinding, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let removing { model.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The bookmarks inside and their saved passwords are removed from Navette. Nothing changes on the servers.")
        }
    }

    private var folderBinding: Binding<Bool> {
        Binding(get: { model.newFolderParent != nil }, set: { if !$0 { model.newFolderParent = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    // MARK: - Rows

    private struct NodeRows: View {
        let nodes: [BookmarkNode]
        let sidebar: SidebarView

        var body: some View {
            ForEach(nodes) { node in
                switch node {
                case .bookmark(let bookmark):
                    BookmarkRow(bookmark: bookmark)
                        .onTapGesture(count: 2) { sidebar.model.connect(bookmark) }
                        .contextMenu { sidebar.bookmarkMenu(bookmark, node: node) }
                case .folder(let folder):
                    DisclosureGroup(isExpanded: sidebar.expansion(of: folder.id)) {
                        NodeRows(nodes: folder.children, sidebar: sidebar)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .contextMenu { sidebar.folderMenu(folder, node: node) }
                    }
                }
            }
        }
    }

    private func expansion(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            })
    }

    @ViewBuilder
    private func bookmarkMenu(_ bookmark: Bookmark, node: BookmarkNode) -> some View {
        Button("Connect") { model.connect(bookmark) }
        Button("Edit…") { model.edit(bookmark) }
        Button("Duplicate") { model.duplicate(bookmark) }
        Menu("Move to") {
            Button("Top Level") { model.move(bookmark.id, to: nil) }
            ForEach(model.folders) { folder in
                Button(folder.name) { model.move(bookmark.id, to: folder.id) }
            }
        }
        Divider()
        Button("Remove…", role: .destructive) { removing = node }
    }

    @ViewBuilder
    private func folderMenu(_ folder: BookmarkFolder, node: BookmarkNode) -> some View {
        Button("New Bookmark…") { model.newBookmark(in: folder.id) }
        Button("New Folder…") { model.newFolderParent = .init(parent: folder.id) }
        Button("Rename…") { renaming = RenameRequest(id: folder.id, name: folder.name) }
        Divider()
        Button("Remove…", role: .destructive) { removing = node }
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 8) {
            ProtocolIcon(proto: bookmark.protocol, size: 20)
            Text(bookmark.displayName).lineLimit(1)
            Spacer(minLength: 4)
            if let color = bookmark.color {
                Circle().fill(color.color).frame(width: 8, height: 8).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .help(bookmark.urlString)
    }
}
