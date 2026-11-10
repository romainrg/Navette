import NavetteCore
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        switch model.phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(model.bookmark.displayName)…").foregroundStyle(.secondary)
            }
        case .failed(let error):
            ConnectionFailureView(bookmark: model.bookmark, error: error) { model.connect() }
        case .connected:
            connected
        }
    }

    private var connected: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                BrowserToolbar(model: model)
                BrowserHeader(model: model)
                table
                StatusBar(model: model)
            }
            if model.inspectorVisible {
                Rectangle().fill(Theme.divider).frame(width: 1)
                InspectorView(model: model).frame(width: 290)
            }
        }
        .sheet(item: $model.textPrompt) { prompt in
            TextPromptSheet(prompt: prompt, model: model)
        }
        .sheet(isPresented: deletionBinding) {
            DeletionSheet(model: model)
        }
        .alert(model.notice?.title ?? "", isPresented: noticeBinding) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice?.message ?? "")
        }
        .alert("“\(model.editor.remoteChange?.path.name ?? "")” changed on the server", isPresented: remoteChangeBinding) {
            Button("Replace with My Version", role: .destructive) { model.editor.resolveRemoteChange(overwrite: true) }
            Button("Keep the Server's Version", role: .cancel) { model.editor.resolveRemoteChange(overwrite: false) }
        } message: {
            Text("Someone or something modified this file since you opened it. Replacing it cannot be undone. Your changes stay in the editor either way.")
        }
        .alert("Preview this large file?", isPresented: largePreviewBinding) {
            Button("Download and Preview") {
                if let item = model.editor.largePreview?.item { model.editor.quickLook(item, confirmed: true) }
                model.editor.largePreview = nil
            }
            Button("Cancel", role: .cancel) { model.editor.largePreview = nil }
        } message: {
            Text("“\(model.editor.largePreview?.item.name ?? "")” is \(Format.bytes(model.editor.largePreview?.item.size ?? 0)). It has to be downloaded first.")
        }
    }

    private var remoteChangeBinding: Binding<Bool> {
        Binding(get: { model.editor.remoteChange != nil }, set: { if !$0 { model.editor.resolveRemoteChange(overwrite: false) } })
    }

    private var largePreviewBinding: Binding<Bool> {
        Binding(get: { model.editor.largePreview != nil }, set: { if !$0 { model.editor.largePreview = nil } })
    }

    private var table: some View {
        FileTableView(
            items: model.visibleItems, selection: model.selection, sortKey: model.sortKey, ascending: model.ascending,
            showsPermissions: model.capabilities.permissions, showsOwner: model.capabilities.ownership, model: model
        )
        .overlay {
            if let error = model.listError {
                ContentUnavailableView {
                    Label("This folder cannot be shown", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try Again") { model.reload() }.buttonStyle(.soft)
                }
                .background(.background.opacity(0.9))
            } else if model.visibleItems.isEmpty, !model.isLoading {
                if model.filter.isEmpty {
                    ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text("Drop files here to upload them."))
                } else {
                    ContentUnavailableView.search(text: model.filter)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { model.deletion != nil }, set: { if !$0 { model.cancelDeletion() } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }
}

// MARK: - Toolbar

private struct BrowserToolbar: View {
    @Bindable var model: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            ToolbarGroup {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help("Back").accessibilityLabel("Back")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).help("Forward").accessibilityLabel("Forward")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.path.isRoot).help("Enclosing Folder").accessibilityLabel("Enclosing Folder")
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload").accessibilityLabel("Reload")
            }
            ToolbarGroup {
                Button { model.textPrompt = .newFolder } label: { Image(systemName: "folder.badge.plus") }
                    .help("New Folder…").accessibilityLabel("New Folder…")
                Button { model.download(model.selectedItems) } label: { Image(systemName: "square.and.arrow.down") }
                    .disabled(model.selection.isEmpty).help("Download").accessibilityLabel("Download")
                Button { model.requestDeletion() } label: { Image(systemName: "trash") }
                    .disabled(model.selection.isEmpty).help("Delete…").accessibilityLabel("Delete…")
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $model.filter).textFieldStyle(.plain).frame(width: 150)
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.softStroke))
            ToolbarGroup {
                Button { model.showHidden.toggle() } label: { Image(systemName: model.showHidden ? "eye" : "eye.slash") }
                    .buttonStyle(.toolbarIcon(isOn: model.showHidden))
                    .help("Show or Hide Hidden Files").accessibilityLabel("Show or Hide Hidden Files")
                Button { model.inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.toolbarIcon(isOn: model.inspectorVisible))
                    .help("Get Info").accessibilityLabel("Get Info")
            }
        }
        .buttonStyle(.toolbarIcon)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

/// Where the tab is: the enclosing folders, the current folder as the title, and the upload button.
private struct BrowserHeader: View {
    let model: BrowserModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                PathBar(model: model)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .kerning(-0.6)
                        .foregroundStyle(Theme.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(model.visibleItems.count) items").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            Button { NavetteCommands.chooseUploads(for: model) } label: { Label("Upload…", systemImage: "arrow.up") }
                .buttonStyle(.gradient)
                .help("Upload…")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var title: String {
        model.path.isRoot ? model.bookmark.displayName : model.path.name
    }
}

/// The folders that enclose the current one. The current folder itself is the header's title.
private struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        let ancestors = Array(model.path.ancestors.dropLast())
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ProtocolIcon(proto: model.bookmark.protocol, size: 16).padding(.trailing, 4)
                if ancestors.isEmpty {
                    Text(verbatim: model.bookmark.protocol.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(Array(ancestors.enumerated()), id: \.offset) { index, ancestor in
                    Button { model.navigate(to: ancestor) } label: {
                        Text(index == 0 ? model.bookmark.displayName : ancestor.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 20)
    }
}

private struct StatusBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isLoading { ProgressView().controlSize(.small) }
            Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let status = model.editor.status {
                Text(verbatim: "·").font(.caption).foregroundStyle(.tertiary)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !model.bookmark.protocol.isEncrypted {
                Label("Not encrypted", systemImage: "lock.open.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let selected = model.selectedItems
        if selected.isEmpty { return String(localized: "\(model.visibleItems.count) items") }
        let size = selected.reduce(UInt64(0)) { $0 + ($1.kind == .file ? $1.size ?? 0 : 0) }
        return String(localized: "\(selected.count) of \(model.visibleItems.count) selected, \(Format.bytes(size))")
    }
}

// MARK: - Sheets and states

/// New folder, rename and "go to folder": one text field and a confirmation.
private struct TextPromptSheet: View {
    let prompt: BrowserModel.TextPrompt
    let model: BrowserModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if case .goToPath = prompt {} else if !text.isEmpty, !model.isValidName(text) {
                Text("A name cannot contain a slash.").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                Button(action, action: commit).buttonStyle(.gradient).keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if case .rename(let item) = prompt { text = item.name }
            if case .goToPath = prompt { text = model.path.display }
        }
    }

    private var title: String {
        switch prompt {
        case .newFolder: String(localized: "New folder in “\(model.path.name)”")
        case .rename(let item): String(localized: "Rename “\(item.name)”")
        case .goToPath: String(localized: "Go to folder")
        }
    }

    private var placeholder: String {
        if case .goToPath = prompt { return String(localized: "Path") }
        return String(localized: "Name")
    }

    private var action: String {
        switch prompt {
        case .newFolder: String(localized: "Create")
        case .rename: String(localized: "Rename")
        case .goToPath: String(localized: "Go")
        }
    }

    private var isValid: Bool {
        if case .goToPath = prompt { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return model.isValidName(text)
    }

    private func commit() {
        guard isValid else { return }
        switch prompt {
        case .newFolder: model.makeFolder(named: text)
        case .rename(let item): model.rename(item, to: text)
        case .goToPath: model.go(toTypedPath: text)
        }
        dismiss()
    }
}

/// Why the connection failed, in plain words. A changed host key gets its own explanation and is never bypassed.
struct ConnectionFailureView: View {
    let bookmark: Bookmark
    let error: RemoteError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if case .hostKeyChanged(let change) = error {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 40)).foregroundStyle(.red)
                Text("The identity of “\(change.host)” has changed").font(.title2.bold())
                Text("The key this server presents is not the one saved on this Mac. The server may have been reinstalled, or someone may be intercepting the connection. Navette did not connect.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    if let fingerprint = change.fingerprint {
                        LabeledContent("New fingerprint") { Text(fingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                    }
                    if let file = change.knownHostsFile, let line = change.knownHostsLine {
                        LabeledContent("Saved key") { Text("\(file), line \(line)").font(.callout).textSelection(.enabled) }
                    }
                    Text("If the administrator confirms the new fingerprint, remove the old key in Terminal, then try again:").font(.callout)
                    Text(verbatim: "ssh-keygen -R \(change.host)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                .padding(14)
                .themeCard()
            } else {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Could not connect to “\(bookmark.displayName)”").font(.title2.bold())
                Text(error.message).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("Try Again", action: retry).buttonStyle(.gradient)
        }
        .frame(maxWidth: 520)
        .padding(32)
    }
}
