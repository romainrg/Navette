import NavetteCore
import SwiftUI

struct ScreenshotScene {
    let name: String
    let size: CGSize
    let make: @MainActor () -> AnyView
}

/// Every screen of the app, built from demo data. `make screenshots` renders them in light, dark and French.
enum ScreenshotScenes {
    private static let window = CGSize(width: 1100, height: 720)

    @MainActor
    static var all: [ScreenshotScene] {
        [
            ScreenshotScene(name: "welcome", size: window) {
                AnyView(ContentView(model: AppModel(env: .demo())))
            },
            ScreenshotScene(name: "browser", size: window) {
                AnyView(ContentView(model: browsing()))
            },
            ScreenshotScene(name: "browser-inspector", size: window) {
                AnyView(ContentView(model: browsing { tab in
                    tab.selection = [tab.path.appending("deploy.sh")]
                    tab.inspectorVisible = true
                }))
            },
            ScreenshotScene(name: "browser-filter", size: window) {
                AnyView(ContentView(model: browsing { tab in
                    tab.showHidden = true
                    tab.filter = "html"
                }))
            },
            ScreenshotScene(name: "transfers", size: window) {
                let env = AppEnvironment.demo()
                let transfers = TransfersModel(engine: env.engine, preview: DemoData.transfers)
                return AnyView(ContentView(model: browsing(AppModel(env: env, transfers: transfers)) { tab in
                    tab.selection = [tab.path.appending("backup-2026-11-09.tar.gz")]
                }))
            },
            ScreenshotScene(name: "connection-failed", size: window) {
                let model = AppModel(env: .demo())
                return AnyView(sheet(ConnectionFailureView(bookmark: DemoData.production, error: .unreachable("ssh: connect to host www.example.org port 22: Operation timed out")) {}, model))
            },
            ScreenshotScene(name: "host-key-changed", size: window) {
                let change = HostKeyChange(
                    host: "www.example.org", keyType: "ED25519", fingerprint: "SHA256:KFrPEakk+y2tO+LkWONAIisPSUAsFuQlo4soX/FTOc4",
                    knownHostsFile: "/Users/demo/.ssh/known_hosts", knownHostsLine: 12)
                return AnyView(sheet(ConnectionFailureView(bookmark: DemoData.production, error: .hostKeyChanged(change)) {}, AppModel(env: .demo())))
            },
            ScreenshotScene(name: "connection-sftp", size: CGSize(width: 540, height: 720)) {
                let model = AppModel(env: .demo())
                let editor = BookmarkEditor(bookmark: DemoData.staging, isNew: false)
                return AnyView(ConnectionSheet(model: model, editor: editor, resolved: DemoData.resolvedConfig(for: DemoData.staging), test: .success))
            },
            ScreenshotScene(name: "connection-ftp", size: CGSize(width: 540, height: 640)) {
                let bookmark = Bookmark(name: "Old server", protocol: .ftp, host: "ftp.example.net", user: "backup")
                return AnyView(ConnectionSheet(model: AppModel(env: .demo()), editor: BookmarkEditor(bookmark: bookmark, isNew: true)))
            },
            ScreenshotScene(name: "connection-webdav", size: CGSize(width: 540, height: 660)) {
                AnyView(ConnectionSheet(model: AppModel(env: .demo()), editor: BookmarkEditor(bookmark: DemoData.nextcloud, isNew: false)))
            },
            prompt("prompt-host-key", .hostKey(host: "staging.example.org (10.0.12.34)", keyType: "ED25519", fingerprint: "SHA256:KFrPEakk+y2tO+LkWONAIisPSUAsFuQlo4soX/FTOc4"), height: 360),
            prompt("prompt-password", .password(account: "deploy@staging.example.org"), retry: true, height: 280),
            prompt("prompt-passphrase", .passphrase(keyPath: "/Users/demo/.ssh/id_ed25519"), height: 250),
            prompt("prompt-code", .oneTimeCode(message: "(deploy@staging.example.org) Verification code:"), height: 220),
            ScreenshotScene(name: "prompt-certificate", size: CGSize(width: 460, height: 440)) {
                let certificate = CertificateSummary(
                    subject: "ftp.example.net", issuer: "ftp.example.net", notAfter: DemoData.now.addingTimeInterval(200 * 86_400),
                    sha256: "d3ffe41d953cd2f85a6287b7e466a7811cfa8c9cbf21b2035afcc2c203c545f7", reason: "The certificate is self-signed.")
                let request = PromptCenter.Request(server: "Archive", prompt: .confirm(message: ""), isRetry: false, certificate: certificate)
                return AnyView(PromptSheet(request: request) { _ in })
            },
            ScreenshotScene(name: "conflict", size: CGSize(width: 540, height: 350)) {
                AnyView(ConflictSheet(conflict: DemoData.conflict) { _ in })
            },
            ScreenshotScene(name: "deletion", size: CGSize(width: 520, height: 500)) {
                let server = DemoData.makeServer(for: DemoData.staging)
                let home = RemotePath("/var/www/site")
                let names = ["assets", "assets/app.css", "assets/app.js", "assets/fonts", "assets/fonts/Inter.woff2", "assets/img", "assets/img/hero.jpg", "assets/img/logo.svg", "logs", "logs/access.log", "logs/error.log", "database.sql"]
                let items = names.map { name -> RemoteItem in
                    let path = home.appending(name)
                    let isFile = name.contains(".")
                    return RemoteItem(path: RemotePath(path.display), kind: isFile ? .file : .directory, size: isFile ? sizes[name] : nil)
                }
                _ = server
                return AnyView(
                    VStack(alignment: .leading, spacing: 14) {
                        DeletionSummary(tree: RemoteTree(items: items), base: home)
                        HStack {
                            Spacer()
                            Button("Cancel") {}.buttonStyle(.soft)
                            Button("Delete Permanently") {}
                                .buttonStyle(GradientButtonStyle(
                                    fill: LinearGradient(colors: [Color(hex: 0xF43F5E), Color(hex: 0xBE123C)], startPoint: .top, endPoint: .bottom),
                                    shadow: Color(hex: 0xBE123C)))
                        }
                    }
                    .padding(20))
            },
            ScreenshotScene(name: "settings", size: CGSize(width: 520, height: 470)) {
                AnyView(SettingsView(model: AppModel(env: .demo())))
            },
        ]
    }

    private static let sizes: [String: UInt64] = [
        "assets/app.css": 48_212, "assets/app.js": 312_880, "assets/fonts/Inter.woff2": 98_340, "assets/img/hero.jpg": 2 << 20,
        "assets/img/logo.svg": 9_120, "logs/access.log": 54 << 20, "logs/error.log": 180_400, "database.sql": 96 << 20,
    ]

    /// A window connected to the demo staging server. `adjust` runs once the listing is on screen.
    @MainActor
    private static func browsing(_ model: AppModel? = nil, adjust: (@MainActor (BrowserModel) -> Void)? = nil) -> AppModel {
        let model = model ?? AppModel(env: .demo())
        let tab = model.connect(DemoData.staging)
        if let adjust {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                adjust(tab)
            }
        }
        return model
    }

    /// A full-window state shown without the sidebar's tab content, on the window ground.
    @MainActor
    private static func sheet(_ content: some View, _ model: AppModel) -> some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            content.frame(maxWidth: .infinity, maxHeight: .infinity).glassPanel().padding(10).background { ThemeGround() }
        }
    }

    @MainActor
    private static func prompt(_ name: String, _ prompt: AskpassPrompt, retry: Bool = false, height: CGFloat) -> ScreenshotScene {
        ScreenshotScene(name: name, size: CGSize(width: 460, height: height)) {
            AnyView(PromptSheet(request: PromptCenter.Request(server: "Staging", prompt: prompt, isRetry: retry)) { _ in })
        }
    }
}
