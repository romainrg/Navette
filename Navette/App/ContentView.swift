import NavetteCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TabBar(model: model)
                Rectangle().fill(Theme.divider).frame(height: 1)
                Group {
                    if let tab = model.currentTab {
                        BrowserView(model: tab).id(tab.id)
                    } else {
                        WelcomeView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.transfers.drawerVisible {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    TransfersDrawer(model: model.transfers, reveal: model.env.reveal)
                        .frame(height: 200)
                }
            }
            .background(Theme.ground)
            .overlay(alignment: .top) { NoticeBanner(prompts: model.prompts) }
        }
        .sheet(item: $model.editor) { editor in
            ConnectionSheet(model: model, editor: editor)
        }
        .sheet(item: promptBinding) { request in
            PromptSheet(request: request) { model.prompts.resolve($0) }
                .interactiveDismissDisabled()
        }
        .sheet(item: conflictBinding) { request in
            ConflictSheet(conflict: request.conflict) { model.transfers.answer($0) }
                .interactiveDismissDisabled()
        }
    }

    /// The connection sheet shows prompts itself while it is open (a window presents one sheet at a time).
    private var promptBinding: Binding<PromptCenter.Request?> {
        Binding(get: { model.editor == nil ? model.prompts.current : nil }, set: { _ in })
    }

    private var conflictBinding: Binding<TransfersModel.ConflictRequest?> {
        Binding(get: { model.editor == nil && model.prompts.current == nil ? model.transfers.conflict : nil }, set: { _ in })
    }
}

/// "Touch your security key" and other messages `ssh` shows while it waits.
struct NoticeBanner: View {
    let prompts: PromptCenter

    var body: some View {
        if let message = prompts.notices.values.sorted().first {
            Label(message, systemImage: "key.radiowaves.forward")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .themeCard()
                .padding(.top, 52)
        }
    }
}

// MARK: - Tabs

struct TabBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab, isSelected: tab.id == model.selectedTab, select: { model.selectedTab = tab.id }, close: { model.close(tab) })
                    }
                    Button { model.showWelcome() } label: { Image(systemName: "plus") }
                        .buttonStyle(.toolbarIcon)
                        .help("New Tab")
                        .accessibilityLabel("New Tab")
                }
            }
            Spacer(minLength: 8)
            Button { model.transfers.drawerVisible.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                    if model.transfers.activeCount > 0 {
                        Text(model.transfers.activeCount, format: .number).monospacedDigit()
                    }
                }
            }
            .buttonStyle(.soft)
            .controlSize(.small)
            .help("Show or Hide Transfers")
            .accessibilityLabel("Transfers")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.barFill)
    }
}

private struct TabChip: View {
    let tab: BrowserModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 7) {
            ProtocolIcon(proto: tab.bookmark.protocol, size: 18)
            Text(tab.bookmark.displayName).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(1)
            if tab.phase == .connecting {
                ProgressView().controlSize(.mini)
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(isSelected ? Theme.softFill : Color.clear, in: shape)
        .overlay(shape.strokeBorder(isSelected ? tab.bookmark.protocol.tint.end.opacity(0.55) : Theme.softStroke))
        .contentShape(shape)
        .onTapGesture(perform: select)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let model: AppModel
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Connect to a server").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Paste an address, or pick a bookmark in the sidebar.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(String("sftp://user@server:22/path"), text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                        .focused($fieldFocused)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .buttonStyle(.gradient)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if model.quickConnectError {
                    Label("This address is not valid. Examples: sftp://user@host, ftps://host, https://cloud.example.org/dav", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("SFTP uses your SSH configuration, keys and agent.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("New Bookmark…") { model.newBookmark(from: text) }.buttonStyle(.soft).controlSize(.small)
                }
            }
            .padding(18)
            .themeCard()
            .frame(maxWidth: 560)

            if !model.library.recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent connections").font(.headline)
                    ForEach(model.library.recents.prefix(4)) { recent in
                        Button { model.connect(recent.bookmark) } label: {
                            HStack(spacing: 10) {
                                ProtocolIcon(proto: recent.bookmark.protocol, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recent.bookmark.displayName).font(.system(size: 13, weight: .semibold))
                                    Text(recent.bookmark.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(Format.date(recent.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themeCard()
                    }
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        if model.quickConnect(text) { text = "" }
    }
}
