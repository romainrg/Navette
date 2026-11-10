import NavetteCore
import SwiftUI

/// New bookmark, edit bookmark. The fields adapt to the protocol; for SSH, the values `~/.ssh/config` resolves are shown.
struct ConnectionSheet: View {
    let model: AppModel
    @State private var editor: BookmarkEditor
    @State private var portText: String
    @State private var resolved: ResolvedSSHConfig?
    @State private var test: TestState = .idle
    @Environment(\.dismiss) private var dismiss

    enum TestState: Equatable {
        case idle, running, success
        case failure(String)
    }

    init(model: AppModel, editor: BookmarkEditor, resolved: ResolvedSSHConfig? = nil, test: TestState = .idle) {
        self.model = model
        _editor = State(initialValue: editor)
        _portText = State(initialValue: editor.bookmark.port.map(String.init) ?? "")
        _resolved = State(initialValue: resolved)
        _test = State(initialValue: test)
    }

    private var bookmark: Bookmark { editor.bookmark }
    private var isValid: Bool { ConnectionURL.isValidHost(bookmark.host.trimmingCharacters(in: .whitespaces)) && (portText.isEmpty || Int(portText).map { (1...65535).contains($0) } == true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProtocolIcon(proto: bookmark.protocol, size: 44, glows: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.isNew ? "New Bookmark" : "Edit Bookmark").font(.system(size: 20, weight: .bold)).kerning(-0.3)
                    Text(isValid ? bookmark.urlString : String(localized: "Enter a server address")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            ProtocolPicker(selection: $editor.bookmark.protocol)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Optional", text: $editor.bookmark.name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Server")
                    HStack(spacing: 8) {
                        TextField(bookmark.protocol == .sftp ? String(localized: "Host name or SSH alias") : String(localized: "Host name"), text: $editor.bookmark.host)
                            .textFieldStyle(.roundedBorder)
                        Text("Port")
                        TextField(String(bookmark.protocol.defaultPort), text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .onChange(of: portText) { _, value in editor.bookmark.port = Int(value) }
                    }
                }
                GridRow {
                    Text("User")
                    TextField(bookmark.protocol == .sftp ? String(localized: "From your SSH configuration") : String(localized: "User name"), text: userBinding)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(bookmark.protocol == .sftp ? String(localized: "Only if the server asks for one") : String(localized: "Password"), text: $editor.password)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Save in the Keychain", isOn: $editor.savePassword).font(.callout).disabled(editor.password.isEmpty)
                    }
                }
                GridRow {
                    Text("Folder")
                    TextField(bookmark.protocol == .webdav || bookmark.protocol == .webdavs ? String("/remote.php/dav/files/user") : String(localized: "Home folder"), text: pathBinding)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Color")
                    HStack(spacing: 8) {
                        colorDot(nil)
                        ForEach(BookmarkColor.allCases, id: \.rawValue) { colorDot($0) }
                    }
                }
            }

            if bookmark.protocol == .webdav || bookmark.protocol == .webdavs {
                HStack(spacing: 8) {
                    Text("Presets").font(.callout).foregroundStyle(.secondary)
                    Button(String("Nextcloud")) { editor.bookmark.path = "/remote.php/dav/files/\(bookmark.user ?? "")" }
                    Button(String("ownCloud")) { editor.bookmark.path = "/remote.php/dav/files/\(bookmark.user ?? "")" }
                }
                .buttonStyle(.soft)
                .controlSize(.small)
            }
            if !bookmark.protocol.isEncrypted {
                Label("This protocol is not encrypted: the password and the files travel in clear.", systemImage: "lock.open.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if bookmark.protocol == .sftp, let resolved {
                ResolvedConfigView(config: resolved)
            }
            testResult

            HStack {
                Button("Test") { runTest() }.buttonStyle(.soft).disabled(!isValid || test == .running)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                Button("Save") { model.commit(editor, connect: false) }.buttonStyle(.soft).disabled(!isValid)
                Button("Connect") { model.commit(editor, connect: true) }
                    .buttonStyle(.gradient)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 540)
        .task(id: "\(bookmark.protocol.rawValue)|\(bookmark.host)|\(bookmark.user ?? "")|\(portText)") {
            guard bookmark.protocol == .sftp, isValid else {
                resolved = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            resolved = await model.env.connector.resolveSSH(bookmark)
        }
        .sheet(item: promptBinding) { request in
            PromptSheet(request: request) { model.prompts.resolve($0) }.interactiveDismissDisabled()
        }
    }

    private var promptBinding: Binding<PromptCenter.Request?> {
        Binding(get: { model.prompts.current }, set: { _ in })
    }

    private var userBinding: Binding<String> {
        Binding(get: { editor.bookmark.user ?? "" }, set: { editor.bookmark.user = $0.isEmpty ? nil : $0 })
    }

    private var pathBinding: Binding<String> {
        Binding(get: { editor.bookmark.path ?? "" }, set: { editor.bookmark.path = $0.isEmpty ? nil : $0 })
    }

    private func colorDot(_ color: BookmarkColor?) -> some View {
        Button { editor.bookmark.color = color } label: {
            Circle()
                .fill(color?.color ?? Color.clear)
                .overlay(Circle().strokeBorder(color == nil ? Theme.softStroke : Color.clear))
                .overlay { if color == nil { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary) } }
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(bookmark.color == color ? 0.7 : 0), lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.map { Text($0.rawValue) } ?? Text("No color"))
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing the connection…").font(.callout)
            }
        case .success:
            Label("The connection works.", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func runTest() {
        test = .running
        let bookmark = bookmark
        let password = editor.password.isEmpty ? nil : editor.password
        Task {
            do {
                let fs = try await model.env.connector.connect(to: bookmark, password: password, prompts: model.prompts)
                _ = try await fs.home()
                await fs.disconnect()
                test = .success
            } catch let error as RemoteError {
                test = .failure(error.message)
            } catch {
                test = .failure(error.localizedDescription)
            }
        }
    }
}

/// The protocols as tiles, the selected one outlined with its gradient.
private struct ProtocolPicker: View {
    @Binding var selection: ServerProtocol

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ServerProtocol.allCases) { proto in
                tile(proto)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protocol")
    }

    private func tile(_ proto: ServerProtocol) -> some View {
        let isSelected = proto == selection
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { selection = proto } label: {
            VStack(spacing: 5) {
                ProtocolIcon(proto: proto, size: 24, glows: isSelected)
                Text(verbatim: proto.displayName)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(isSelected ? Theme.softFill : Color.clear, in: shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(proto.tint.gradient, lineWidth: 1.5)
                } else {
                    shape.strokeBorder(Theme.softStroke)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What `ssh` will really use for this host, once `~/.ssh/config` is applied: the route, then the identity.
struct ResolvedConfigView: View {
    let config: ResolvedSSHConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Resolved by your SSH configuration", systemImage: "terminal").font(.callout.weight(.semibold))
            if let host = config.hostName {
                route(to: host)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if config.hostName == nil, let jump = config.proxyJump { line("Jump host", jump) }
                if let user = config.user { line("User", user) }
                let keys = config.existingIdentityFiles()
                if !keys.isEmpty { line("Keys", keys.joined(separator: ", ")) }
                if let agent = config.identityAgent { line("Agent", agent) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    /// This Mac, the jump host if there is one, then the server.
    private func route(to host: String) -> some View {
        HStack(spacing: 0) {
            stop(Text("This Mac"))
            link(Color(hex: 0x2DD4BF), Color(hex: 0x818CF8))
            if let jump = config.proxyJump {
                stop(Text(verbatim: jump))
                link(Color(hex: 0x818CF8), Color(hex: 0xF472B6))
            }
            Text(verbatim: config.port.map { "\(host):\($0)" } ?? host)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.selection, in: Capsule())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func stop(_ text: Text) -> some View {
        text
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Theme.softFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.softStroke))
    }

    private func link(_ start: Color, _ end: Color) -> some View {
        LinearGradient(colors: [start, end], startPoint: .leading, endPoint: .trailing)
            .frame(minWidth: 12, maxWidth: .infinity)
            .frame(height: 2)
            .accessibilityHidden(true)
    }

    private func line(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
