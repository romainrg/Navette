import AppKit
import NavetteCore
import Observation
import UniformTypeIdentifiers

/// Quick Look and "Open With" for one tab: remote files are copied to a private cache folder, and a copy
/// opened in an editor is sent back each time it is saved.
@MainActor @Observable
final class EditCoordinator {
    struct RemoteChange: Identifiable {
        let id = UUID()
        let path: RemotePath
    }

    struct LargePreview: Identifiable {
        let id = UUID()
        let item: RemoteItem
    }

    /// Files larger than this are only previewed after a confirmation.
    static let previewLimit: UInt64 = 50 << 20

    /// Shown in the status bar: "Uploaded “index.html” at 14:02".
    private(set) var status: String?
    var remoteChange: RemoteChange?
    var largePreview: LargePreview?

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let connection: () throws -> any RemoteFileSystem
    @ObservationIgnored private let report: (String, String) -> Void
    @ObservationIgnored private let engine: TransferEngine
    @ObservationIgnored private let cache: URL
    @ObservationIgnored private var sessions: [RemotePath: EditSession] = [:]
    @ObservationIgnored private var watchers: [RemotePath: FolderWatcher] = [:]
    @ObservationIgnored private var pending: [RemotePath: Task<Void, Never>] = [:]

    init(env: AppEnvironment, tab: UUID, connection: @escaping () throws -> any RemoteFileSystem, report: @escaping (String, String) -> Void) {
        self.env = env
        self.connection = connection
        self.report = report
        engine = TransferEngine(files: env.files, policy: .overwrite)
        cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.romainrg.Navette", isDirectory: true)
            .appendingPathComponent(tab.uuidString, isDirectory: true)
    }

    private var isUnavailable: Bool {
        if env.isDemo {
            report(String(localized: "Not available in demo mode"), String(localized: "Demo mode never writes to the disk, so it cannot preview or edit files."))
        }
        return env.isDemo
    }

    // MARK: - Local copies

    private func run(_ item: TransferItem) async throws {
        let fs = try connection()
        await engine.enqueue([item], serverKey: "edit", serverName: "", connect: { fs })
        while true {
            switch await engine.snapshots().first(where: { $0.id == item.id })?.state {
            case .finished, .skipped:
                await engine.remove([item.id])
                return
            case .failed(let error):
                await engine.remove([item.id])
                throw error
            case .cancelled, .none:
                throw RemoteError.cancelled
            default:
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Downloads a file into its own cache folder and returns the local copy.
    private func fetch(_ item: RemoteItem) async throws -> URL {
        guard TransferPlanner.isSafeName(item.name) else { throw RemoteError.server(item.name) }
        let folder = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(item.name)
        try await run(TransferItem(direction: .download, local: local, remote: item.path))
        return local
    }

    private func fail(_ title: String, _ error: Error) {
        report(title, (error as? RemoteError)?.message ?? error.localizedDescription)
    }

    // MARK: - Quick Look

    func quickLook(_ item: RemoteItem, confirmed: Bool = false) {
        guard item.kind != .directory, !isUnavailable else { return }
        if !confirmed, (item.size ?? 0) > Self.previewLimit {
            largePreview = LargePreview(item: item)
            return
        }
        status = String(localized: "Downloading “\(item.name)” for the preview…")
        Task {
            do {
                let local = try await fetch(item)
                status = nil
                QuickLook.shared.preview(local)
            } catch {
                status = nil
                fail(String(localized: "The preview could not be shown."), error)
            }
        }
    }

    // MARK: - Open With

    /// Applications able to open this kind of file, the default one first.
    func applications(for item: RemoteItem) -> [URL] {
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: type) {
            apps.removeAll { $0 == preferred }
            apps.insert(preferred, at: 0)
        }
        return Array(apps.prefix(12))
    }

    /// Opens a remote file in a local application and sends it back at each save.
    func open(_ item: RemoteItem, with application: URL) {
        guard item.kind != .directory, !isUnavailable else { return }
        if let existing = sessions[item.path] {
            launch(existing.local, with: application)
            return
        }
        status = String(localized: "Downloading “\(item.name)” to edit it…")
        Task {
            do {
                let fs = try connection()
                let version = RemoteVersion(try await fs.stat(item.path))
                let local = try await fetch(item)
                let path = item.path
                sessions[path] = EditSession(remote: path, local: local, remoteVersion: version, localInfo: env.files.info(local))
                watchers[path] = FolderWatcher(url: local.deletingLastPathComponent()) { [weak self] in
                    Task { @MainActor [weak self] in self?.folderChanged(path) }
                }
                status = String(localized: "Editing “\(item.name)”: each save is sent to the server.")
                launch(local, with: application)
            } catch {
                status = nil
                fail(String(localized: "The file could not be opened."), error)
            }
        }
    }

    private func launch(_ file: URL, with application: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Several events arrive for one save: wait for them to settle.
    private func folderChanged(_ path: RemotePath) {
        pending[path]?.cancel()
        pending[path] = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await sync(path, force: false)
        }
    }

    private func sync(_ path: RemotePath, force: Bool) async {
        guard var session = sessions[path], let fs = try? connection() else { return }
        let local = env.files.info(session.local)
        let remote = (try? await fs.statIfExists(path)).flatMap { $0 }.map(RemoteVersion.init)
        let decision = session.decide(local: local, remote: remote)
        sessions[path] = session
        switch decision {
        case .nothing:
            return
        case .askBecauseRemoteChanged where !force:
            remoteChange = RemoteChange(path: path)
            return
        case .upload, .askBecauseRemoteChanged:
            do {
                try await run(TransferItem(direction: .upload, local: session.local, remote: path))
                let uploaded = RemoteVersion(try await fs.stat(path))
                session.didUpload(local: local, remote: uploaded)
                sessions[path] = session
                status = String(localized: "Uploaded “\(path.name)” at \(Date().formatted(date: .omitted, time: .shortened))")
            } catch {
                fail(String(localized: "“\(path.name)” could not be sent back. Your changes are still in the editor."), error)
            }
        }
    }

    /// The answer to "the file changed on the server": replace it with the local copy, or keep the server's.
    func resolveRemoteChange(overwrite: Bool) {
        guard let change = remoteChange else { return }
        remoteChange = nil
        if overwrite { Task { await sync(change.path, force: true) } }
    }

    // MARK: - Cleanup

    /// Called when the tab closes. A copy with changes that never reached the server goes to the Trash
    /// instead of disappearing; everything else in the cache is removed.
    func closeAll() {
        guard !env.isDemo else { return }
        pending.values.forEach { $0.cancel() }
        watchers.values.forEach { $0.cancel() }
        for session in sessions.values where session.hasUnsentChanges {
            try? env.files.trash(session.local)
        }
        sessions.removeAll()
        watchers.removeAll()
        QuickLook.shared.close()
        try? FileManager.default.removeItem(at: cache)
    }
}
