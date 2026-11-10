import AppKit
import NavetteCore
import SwiftUI

/// Every service the app uses, in a live and a demo variant. Demo mode never reads or writes the real disk,
/// the Keychain or the network.
struct AppEnvironment {
    let isDemo: Bool
    let bookmarks: BookmarkStore
    let credentials: any CredentialStore
    let files: any LocalFiles
    let engine: TransferEngine
    let connector: any ServerConnecting
    let defaults: UserDefaults?
    let defaultDownloadFolder: URL
    var reveal: @MainActor (URL) -> Void
    var copy: @MainActor (String) -> Void

    @MainActor
    static func live() -> AppEnvironment {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Navette", isDirectory: true)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let credentials = KeychainCredentialStore()
        let files = DiskFiles()
        return AppEnvironment(
            isDemo: false,
            bookmarks: BookmarkStore(url: support.appendingPathComponent("bookmarks.json")),
            credentials: credentials,
            files: files,
            engine: TransferEngine(files: files),
            connector: LiveConnector(credentials: credentials),
            defaults: .standard,
            defaultDownloadFolder: downloads,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            copy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString($0, forType: .string)
            })
    }

    @MainActor
    static func demo() -> AppEnvironment {
        let files = SimulatedFiles()
        return AppEnvironment(
            isDemo: true,
            bookmarks: BookmarkStore(url: nil, initial: DemoData.library),
            credentials: InMemoryCredentialStore(),
            files: files,
            engine: TransferEngine(files: files),
            connector: DemoConnector(),
            defaults: nil,
            defaultDownloadFolder: URL(fileURLWithPath: "/Users/demo/Downloads", isDirectory: true),
            reveal: { _ in },
            copy: { _ in })
    }

    @MainActor
    static func current() -> AppEnvironment {
        CommandLine.arguments.contains("--demo") ? demo() : live()
    }
}
