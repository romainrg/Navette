import Foundation
import NavetteCore

/// Opens connections for bookmarks. The live implementation talks to real servers; the demo one never touches the network.
protocol ServerConnecting: Sendable {
    /// `password` is one the user just typed (Quick Connect URL, connection sheet); saved ones come from the credential store.
    func connect(to bookmark: Bookmark, password: String?, prompts: PromptCenter) async throws -> any RemoteFileSystem
    /// A connection for transfers, so browsing stays responsive. Returns `primary` when a second one would ask the user again.
    func transferConnection(for bookmark: Bookmark, primary: any RemoteFileSystem, prompts: PromptCenter) async -> any RemoteFileSystem
    func resolveSSH(_ bookmark: Bookmark) async -> ResolvedSSHConfig?
}

final class LiveConnector: ServerConnecting, @unchecked Sendable {
    private let credentials: any CredentialStore
    private let lock = NSLock()
    private var askpass: AskpassServer?
    /// Servers whose `ssh` connection is shared through a control socket: more channels cost no new login.
    private var shared: Set<String> = []

    init(credentials: any CredentialStore) {
        self.credentials = credentials
    }

    func connect(to bookmark: Bookmark, password: String?, prompts: PromptCenter) async throws -> any RemoteFileSystem {
        switch bookmark.protocol {
        case .sftp:
            return try await connectSFTP(bookmark, password: password, prompts: prompts)
        case .ftp, .ftps, .webdav, .webdavs:
            throw RemoteError.unsupported(bookmark.protocol.displayName)
        }
    }

    func transferConnection(for bookmark: Bookmark, primary: any RemoteFileSystem, prompts: PromptCenter) async -> any RemoteFileSystem {
        guard bookmark.protocol == .sftp, lock.withLock({ shared.contains(bookmark.credentialKey) }) else { return primary }
        return (try? await connectSFTP(bookmark, password: nil, prompts: prompts)) ?? primary
    }

    func resolveSSH(_ bookmark: Bookmark) async -> ResolvedSSHConfig? {
        await SSHConfigResolver.resolve(host: bookmark.host, user: bookmark.user, port: bookmark.port)
    }

    // MARK: - SFTP through the system ssh

    private var helperPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "navette-askpass")?.path
    }

    private func askpassServer(in directory: URL) -> AskpassServer? {
        lock.withLock {
            if askpass == nil { askpass = try? AskpassServer(directory: directory) }
            return askpass
        }
    }

    private func connectSFTP(_ bookmark: Bookmark, password: String?, prompts: PromptCenter) async throws -> any RemoteFileSystem {
        var connection = SSHConnection(host: bookmark.host, user: bookmark.user, port: bookmark.port)
        var cleanup: () -> Void = {}
        if let runtime = RuntimeDirectory.url() {
            // Share one login between the browsing and transfer channels, unless the user already set that up.
            let config = await SSHConfigResolver.resolve(host: bookmark.host, user: bookmark.user, port: bookmark.port)
            if let config {
                if !config.usesControlMaster { connection.controlPath = runtime.appendingPathComponent("%C").path }
                _ = lock.withLock { shared.insert(bookmark.credentialKey) }
            }
            if let server = askpassServer(in: runtime), let helperPath {
                let responder = SSHPromptResponder(bookmark: bookmark, initialPassword: password, credentials: credentials, prompts: prompts)
                let token = server.register(responder)
                connection.environment = server.environment(token: token, helperPath: helperPath)
                cleanup = { server.unregister(token) }
            }
        }
        defer { cleanup() }
        return try await SFTPFileSystem.connect(connection)
    }
}

/// Demo mode: every bookmark opens an in-memory server filled with sample files.
final class DemoConnector: ServerConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: InMemoryFileSystem] = [:]

    func connect(to bookmark: Bookmark, password: String?, prompts: PromptCenter) async throws -> any RemoteFileSystem {
        try? await Task.sleep(for: .milliseconds(150))
        return server(for: bookmark)
    }

    func transferConnection(for bookmark: Bookmark, primary: any RemoteFileSystem, prompts: PromptCenter) async -> any RemoteFileSystem {
        primary
    }

    func resolveSSH(_ bookmark: Bookmark) async -> ResolvedSSHConfig? {
        guard bookmark.protocol == .sftp else { return nil }
        return DemoData.resolvedConfig(for: bookmark)
    }

    func server(for bookmark: Bookmark) -> InMemoryFileSystem {
        lock.withLock {
            if let existing = servers[bookmark.host] { return existing }
            let server = DemoData.makeServer(for: bookmark)
            servers[bookmark.host] = server
            return server
        }
    }
}
