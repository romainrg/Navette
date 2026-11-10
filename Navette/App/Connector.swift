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
    /// What this session already knows about a server, so a second connection does not ask again. Never written to disk.
    private var sessionSecrets: [String: String] = [:]
    private var sessionTrust: [String: String] = [:]

    init(credentials: any CredentialStore) {
        self.credentials = credentials
    }

    func connect(to bookmark: Bookmark, password: String?, prompts: PromptCenter) async throws -> any RemoteFileSystem {
        switch bookmark.protocol {
        case .sftp:
            return try await connectSFTP(bookmark, password: password, prompts: prompts)
        case .ftp, .ftps:
            return try await connectWithPassword(bookmark, password: password, prompts: prompts) { secret, trusted in
                try await FTPFileSystem.connect(Self.ftpConnection(bookmark, password: secret, trusted: trusted))
            }
        case .webdav, .webdavs:
            return try await connectWithPassword(bookmark, password: password, prompts: prompts) { secret, trusted in
                guard let url = URL(string: "\(bookmark.protocol.scheme)://\(bookmark.host.contains(":") ? "[\(bookmark.host)]" : bookmark.host):\(bookmark.effectivePort)") else {
                    throw RemoteError.server("Invalid host name")
                }
                let fs = WebDAVFileSystem(connection: WebDAVConnection(baseURL: url, user: bookmark.user, password: secret, trustedCertificateSHA256: trusted))
                // The first request is where a wrong password or an untrusted certificate shows up.
                do {
                    _ = try await fs.stat(RemotePath(bookmark.path ?? "/"))
                } catch let error as RemoteError {
                    switch error {
                    case .authenticationFailed, .untrustedCertificate, .unreachable, .connectionLost:
                        await fs.disconnect()
                        throw error
                    default: break
                    }
                }
                return fs
            }
        }
    }

    func transferConnection(for bookmark: Bookmark, primary: any RemoteFileSystem, prompts: PromptCenter) async -> any RemoteFileSystem {
        switch bookmark.protocol {
        case .sftp:
            guard lock.withLock({ shared.contains(bookmark.credentialKey) }) else { return primary }
            return (try? await connectSFTP(bookmark, password: nil, prompts: prompts)) ?? primary
        case .ftp, .ftps:
            // FTP does one thing at a time per connection: a second login keeps browsing responsive during transfers.
            let (secret, trusted) = lock.withLock { (sessionSecrets[bookmark.credentialKey], sessionTrust[bookmark.credentialKey]) }
            return (try? await FTPFileSystem.connect(Self.ftpConnection(bookmark, password: secret, trusted: trusted ?? bookmark.trustedCertificateSHA256))) ?? primary
        case .webdav, .webdavs:
            return primary
        }
    }

    private static func ftpConnection(_ bookmark: Bookmark, password: String?, trusted: String?) -> FTPConnection {
        let anonymous = bookmark.user?.isEmpty != false
        let security: FTPConnection.Security = bookmark.protocol == .ftp ? .none : (bookmark.effectivePort == 990 ? .implicitTLS : .explicitTLS)
        return FTPConnection(
            host: bookmark.host, port: bookmark.effectivePort, user: anonymous ? "anonymous" : bookmark.user!,
            password: password ?? (anonymous ? "anonymous@" : ""), security: security, trustedCertificateSHA256: trusted)
    }

    /// Password protocols: tries what is known, then asks. A password is saved only once it has worked,
    /// and a certificate the system does not trust is shown before anything is sent.
    private func connectWithPassword(
        _ bookmark: Bookmark, password: String?, prompts: PromptCenter,
        open: (_ password: String?, _ trustedCertificate: String?) async throws -> any RemoteFileSystem
    ) async throws -> any RemoteFileSystem {
        var secret = password ?? credentials.secret(for: bookmark.credentialKey)
        var trusted = bookmark.trustedCertificateSHA256 ?? lock.withLock { sessionTrust[bookmark.credentialKey] }
        var toSave: String?
        var asked = false
        for _ in 0..<5 {
            do {
                let fs = try await open(secret, trusted)
                if let toSave { try? credentials.setSecret(toSave, for: bookmark.credentialKey) }
                lock.withLock {
                    sessionSecrets[bookmark.credentialKey] = secret
                    sessionTrust[bookmark.credentialKey] = trusted
                }
                return fs
            } catch RemoteError.authenticationFailed {
                let account = "\(bookmark.user ?? "anonymous")@\(bookmark.host)"
                guard let answer = await prompts.ask(server: bookmark.displayName, prompt: .password(account: account), isRetry: asked) else {
                    throw RemoteError.cancelled
                }
                asked = true
                secret = answer.text
                toSave = answer.remember ? answer.text : nil
            } catch RemoteError.untrustedCertificate(let certificate) {
                guard await prompts.askToTrust(certificate, for: bookmark) else { throw RemoteError.cancelled }
                trusted = certificate.sha256
            }
        }
        throw RemoteError.authenticationFailed("")
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
