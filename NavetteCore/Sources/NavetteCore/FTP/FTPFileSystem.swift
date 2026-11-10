import Foundation

public struct FTPConnection: Sendable {
    public enum Security: Sendable {
        case none
        /// `AUTH TLS` on the standard port, then `PBSZ 0` and `PROT P`.
        case explicitTLS
        /// TLS from the first byte, traditionally on port 990.
        case implicitTLS
    }

    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var security: Security
    /// SHA-256 of a certificate the user chose to trust although the system does not.
    public var trustedCertificateSHA256: String?

    public init(host: String, port: Int = 21, user: String = "anonymous", password: String = "", security: Security = .none, trustedCertificateSHA256: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.security = security
        self.trustedCertificateSHA256 = trustedCertificateSHA256
    }
}

/// FTP and FTPS on Network.framework. One control connection, used for one command or one transfer at a time;
/// passive data connections (`EPSV`, then `PASV`); `MLSD` when the server has it, `LIST` otherwise.
public final class FTPFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let connection: FTPConnection
    private let queue = DispatchQueue(label: "io.github.romainrg.Navette.ftp")
    private let trust: FTPTrust?
    private let control: FTPStream
    private let gate = AsyncGate()
    private var parser = FTPReplyParser()
    private var replies = [FTPReply]()
    private var features: Set<String> = []
    private var homePath: RemotePath = .root
    private var useEPSV = true
    /// `LIST -a` shows hidden files where plain `LIST` hides them; servers that do not know it get plain `LIST`.
    private var listCommand = "LIST -a"
    private let stateLock = NSLock()
    private var sawUnixListing = false

    private init(connection: FTPConnection) {
        self.connection = connection
        switch connection.security {
        case .none:
            trust = nil
            control = FTPStream(host: connection.host, port: connection.port, security: .plain, queue: queue)
        case .explicitTLS:
            let trust = FTPTrust(serverName: connection.host, trustedSHA256: connection.trustedCertificateSHA256)
            self.trust = trust
            control = FTPStream(host: connection.host, port: connection.port, security: .authTLS(trust), queue: queue)
        case .implicitTLS:
            let trust = FTPTrust(serverName: connection.host, trustedSHA256: connection.trustedCertificateSHA256)
            self.trust = trust
            control = FTPStream(host: connection.host, port: connection.port, security: .tls(trust), queue: queue)
        }
    }

    public var capabilities: Capabilities {
        let unix = stateLock.withLock { sawUnixListing }
        return Capabilities(
            permissions: unix, symlinks: false, atomicReplace: true, resumeUpload: true,
            resumeDownload: features.contains("REST"), ownership: unix)
    }

    // MARK: - Session

    public static func connect(_ connection: FTPConnection) async throws -> FTPFileSystem {
        let fs = FTPFileSystem(connection: connection)
        do {
            try await fs.logIn()
        } catch {
            fs.control.cancel()
            throw error
        }
        return fs
    }

    private func logIn() async throws {
        try await control.start()
        // With explicit TLS, the greeting and AUTH TLS were handled before the connection became ready.
        if case .explicitTLS = connection.security {} else {
            let greeting = try await readReply()
            guard greeting.code == 220 else { throw RemoteError.server(greeting.text) }
        }
        var reply = try await command("USER \(connection.user)")
        if reply.code == 331 { reply = try await command("PASS \(connection.password)", secret: true) }
        guard reply.code == 230 || reply.code == 202 else {
            throw reply.code == 530 || reply.code == 332 || reply.code == 331 ? RemoteError.authenticationFailed(reply.text) : RemoteError.server(reply.text)
        }
        if trust != nil {
            _ = try await command("PBSZ 0")
            let protection = try await command("PROT P")
            guard protection.isCompletion else { throw RemoteError.unsupported("The server refuses to encrypt file transfers (PROT P).") }
        }
        let feat = try await command("FEAT")
        if feat.code == 211 { features = FTPListParser.features(feat) }
        if features.contains("UTF8") { _ = try await command("OPTS UTF8 ON") }
        let type = try await command("TYPE I")
        guard type.isCompletion else { throw RemoteError.server(type.text) }
        let pwd = try await command("PWD")
        if pwd.code == 257, let line = pwd.lines.first, let path = FTPListParser.parsePWD(line) { homePath = path }
    }

    public func disconnect() async {
        await gate.acquire()
        _ = try? await command("QUIT")
        control.cancel()
        gate.release()
    }

    // MARK: - Control connection

    private func sendLine(_ bytes: [UInt8]) async throws {
        // A line protocol cannot carry these bytes inside a path.
        guard !bytes.contains(UInt8(ascii: "\r")), !bytes.contains(UInt8(ascii: "\n")) else {
            throw RemoteError.unsupported("FTP cannot handle a name that contains a line break.")
        }
        try await control.send(Data(bytes + [UInt8(ascii: "\r"), UInt8(ascii: "\n")]))
    }

    private func readReply() async throws -> FTPReply {
        while replies.isEmpty {
            guard let data = try await control.receive() else { throw RemoteError.connectionLost("The server closed the connection.") }
            replies += try parser.append(data)
        }
        let reply = replies.removeFirst()
        if reply.code == 421 { throw RemoteError.connectionLost(reply.text) }
        return reply
    }

    /// Sends a command and returns its first reply (which is preliminary for transfers).
    @discardableResult
    private func command(_ text: String, path: RemotePath? = nil, secret: Bool = false) async throws -> FTPReply {
        var bytes = Array(text.utf8)
        if let path { bytes += [UInt8(ascii: " ")] + path.bytes }
        try await sendLine(bytes)
        return try await readReply()
    }

    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        await gate.acquire()
        defer { gate.release() }
        return try await body()
    }

    static func error(_ reply: FTPReply, path: RemotePath) -> RemoteError {
        let text = reply.text
        let lower = text.lowercased()
        switch reply.code {
        case 530, 532: return .authenticationFailed(text)
        case 522 where lower.contains("reuse"):
            return .unsupported("This server requires TLS session reuse on data connections, which Navette cannot do yet. The server setting is require_ssl_reuse (vsftpd) or \"Require TLS session resumption\" (FileZilla Server).")
        case 550, 553, 450, 451, 452:
            if lower.contains("no such") || lower.contains("not found") || lower.contains("doesn't exist") || lower.contains("does not exist") { return .notFound(path.display) }
            if lower.contains("permission") || lower.contains("denied") || lower.contains("not allowed") { return .permissionDenied(path.display) }
            if lower.contains("exist") { return .alreadyExists(path.display) }
            if lower.contains("not empty") { return .directoryNotEmpty(path.display) }
            return .server("\(text): \(path.display)")
        default:
            return .server("\(text): \(path.display)")
        }
    }

    // MARK: - Data connections

    private func openDataStream() async throws -> FTPStream {
        var port: Int?
        if useEPSV {
            let reply = try await command("EPSV")
            port = reply.code == 229 ? FTPListParser.parseEPSV(reply.text) : nil
            if port == nil { useEPSV = false }
        }
        if port == nil {
            let reply = try await command("PASV")
            guard reply.code == 227, let parsed = FTPListParser.parsePASV(reply.text) else { throw RemoteError.server(reply.text) }
            port = parsed
        }
        // Always the server's own address: the one in a PASV reply is often wrong behind NAT, and could point elsewhere.
        return FTPStream(host: connection.host, port: port!, security: trust.map { .tls($0) } ?? .plain, queue: queue)
    }

    /// Sends a transfer command and opens its data connection. Returns once the server announced the transfer.
    private func beginTransfer(_ verb: String, path: RemotePath?, errorPath: RemotePath) async throws -> FTPStream {
        let data = try await openDataStream()
        var bytes = Array(verb.utf8)
        if let path { bytes += [UInt8(ascii: " ")] + path.bytes }
        try await sendLine(bytes)
        do {
            try await data.start()
        } catch {
            // The server may have refused the command instead of accepting the connection.
            if let reply = try? await readReply(), !reply.isPreliminary { throw Self.error(reply, path: errorPath) }
            throw error
        }
        let reply = try await readReply()
        guard reply.isPreliminary else {
            data.cancel()
            throw Self.error(reply, path: errorPath)
        }
        return data
    }

    private func endTransfer(path: RemotePath) async throws {
        let reply = try await readReply()
        guard reply.isCompletion else { throw Self.error(reply, path: path) }
    }

    // MARK: - Metadata

    public func home() async throws -> RemotePath { homePath }

    public func list(_ path: RemotePath) async throws -> [RemoteItem] {
        try await locked { try await listUnlocked(path) }
    }

    private func listUnlocked(_ path: RemotePath) async throws -> [RemoteItem] {
        let useMLSD = features.contains("MLSD") || features.contains("MLST")
        if !useMLSD {
            // LIST takes no reliable path argument (spaces, options): go there first.
            let cwd = try await command("CWD", path: path)
            guard cwd.isCompletion else { throw Self.error(cwd, path: path) }
        }
        let data: FTPStream
        if useMLSD {
            data = try await beginTransfer("MLSD", path: path, errorPath: path)
        } else {
            do {
                data = try await beginTransfer(listCommand, path: nil, errorPath: path)
            } catch RemoteError.server where listCommand != "LIST" {
                listCommand = "LIST"
                data = try await beginTransfer(listCommand, path: nil, errorPath: path)
            }
        }
        var bytes = Data()
        do {
            while let chunk = try await data.receive() { bytes.append(chunk) }
        } catch {
            data.cancel()
            _ = try? await readReply()
            throw error
        }
        data.cancel()
        try await endTransfer(path: path)
        if useMLSD {
            let items = FTPListParser.parseMLSD(bytes, directory: path)
            if items.contains(where: { $0.permissions != nil }) { stateLock.withLock { sawUnixListing = true } }
            return items
        }
        let items = FTPListParser.parseLIST(bytes, directory: path)
        if items.contains(where: { $0.permissions != nil }) { stateLock.withLock { sawUnixListing = true } }
        return items
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        if path.isRoot { return RemoteItem(path: .root, kind: .directory) }
        return try await locked {
            if features.contains("MLST") {
                let reply = try await command("MLST", path: path)
                guard reply.code == 250 else { throw Self.error(reply, path: path) }
                for line in reply.lines.dropFirst() {
                    let trimmed = Array(line.drop { $0 == UInt8(ascii: " ") })
                    if var item = FTPListParser.parseFacts(trimmed, directory: path.parent) {
                        item.path = path
                        return item
                    }
                }
                throw RemoteError.notFound(path.display)
            }
            // Without MLST: SIZE answers for a file, CWD succeeds for a folder. Listing the parent would be
            // slow in a large folder and misses entries the server hides.
            let size = try await command("SIZE", path: path)
            if size.code == 213, let bytes = UInt64(size.text.trimmingCharacters(in: .whitespaces)) {
                let modified = try await command("MDTM", path: path)
                return RemoteItem(
                    path: path, kind: .file, size: bytes,
                    modified: modified.code == 213 ? FTPListParser.timestamp(modified.text.trimmingCharacters(in: .whitespaces)) : nil)
            }
            let cwd = try await command("CWD", path: path)
            if cwd.isCompletion { return RemoteItem(path: path, kind: .directory) }
            if let item = try await listUnlocked(path.parent).first(where: { $0.path == path }) { return item }
            throw RemoteError.notFound(path.display)
        }
    }

    // MARK: - Changes

    public func makeDirectory(_ path: RemotePath) async throws {
        let reply = try await locked { try await command("MKD", path: path) }
        guard reply.isCompletion else {
            if try await statIfExists(path) != nil { throw RemoteError.alreadyExists(path.display) }
            throw Self.error(reply, path: path)
        }
    }

    public func rename(_ source: RemotePath, to destination: RemotePath, overwrite: Bool) async throws {
        let existing = try await statIfExists(destination)
        if !overwrite, existing != nil { throw RemoteError.alreadyExists(destination.display) }
        try await locked {
            func attempt() async throws -> FTPReply {
                let from = try await command("RNFR", path: source)
                guard from.isIntermediate else { throw Self.error(from, path: source) }
                return try await command("RNTO", path: destination)
            }
            var reply = try await attempt()
            if !reply.isCompletion, overwrite, let existing, existing.kind != .directory {
                // Some servers refuse to rename over an existing file.
                let deleted = try await command("DELE", path: destination)
                guard deleted.isCompletion else { throw Self.error(deleted, path: destination) }
                reply = try await attempt()
            }
            guard reply.isCompletion else { throw Self.error(reply, path: destination) }
        }
    }

    public func removeFile(_ path: RemotePath) async throws {
        let reply = try await locked { try await command("DELE", path: path) }
        guard reply.isCompletion else {
            if try await statIfExists(path) == nil { throw RemoteError.notFound(path.display) }
            throw Self.error(reply, path: path)
        }
    }

    public func removeDirectory(_ path: RemotePath) async throws {
        let reply = try await locked { try await command("RMD", path: path) }
        guard reply.isCompletion else {
            if let entries = try? await list(path), !entries.isEmpty { throw RemoteError.directoryNotEmpty(path.display) }
            throw Self.error(reply, path: path)
        }
    }

    public func setPermissions(_ permissions: UInt16, of path: RemotePath) async throws {
        let reply = try await locked { try await command("SITE CHMOD \(String(permissions & 0o7777, radix: 8))", path: path) }
        guard reply.isCompletion else {
            throw reply.code == 500 || reply.code == 502 || reply.code == 504 ? RemoteError.unsupported("SITE CHMOD") : Self.error(reply, path: path)
        }
    }

    // MARK: - Transfers

    public func read(_ path: RemotePath, offset: UInt64) async throws -> any RemoteReader {
        await gate.acquire()
        do {
            if offset > 0 {
                let rest = try await command("REST \(offset)")
                guard rest.isIntermediate else { throw RemoteError.unsupported("Resuming a download") }
            }
            let data = try await beginTransfer("RETR", path: path, errorPath: path)
            return Download(fs: self, data: data, path: path)
        } catch {
            gate.release()
            throw error
        }
    }

    public func write(_ path: RemotePath, offset: UInt64?) async throws -> any RemoteWriter {
        await gate.acquire()
        do {
            let data = try await beginTransfer((offset ?? 0) > 0 ? "APPE" : "STOR", path: path, errorPath: path)
            return Upload(fs: self, data: data, path: path)
        } catch {
            gate.release()
            throw error
        }
    }

    /// A download or an upload in progress. It holds the control connection until it is over.
    private class Transfer: @unchecked Sendable {
        let fs: FTPFileSystem
        let data: FTPStream
        let path: RemotePath
        private let lock = NSLock()
        private var released = false

        init(fs: FTPFileSystem, data: FTPStream, path: RemotePath) {
            self.fs = fs
            self.data = data
            self.path = path
        }

        func release() {
            let first = lock.withLock { () -> Bool in
                defer { released = true }
                return !released
            }
            if first { fs.gate.release() }
        }

        var isReleased: Bool { lock.withLock { released } }

        /// Stops the transfer: closing the data connection makes the server answer on the control connection.
        func abort() async {
            guard !isReleased else { return }
            data.cancel()
            _ = try? await fs.readReply()
            release()
        }
    }

    private final class Download: Transfer, RemoteReader, @unchecked Sendable {
        private var reachedEnd = false

        func next() async throws -> Data? {
            guard !reachedEnd, !isReleased else { return nil }
            do {
                while true {
                    guard let chunk = try await data.receive() else { break }
                    if !chunk.isEmpty { return chunk }
                }
                reachedEnd = true
                data.cancel()
                try await fs.endTransfer(path: path)
                release()
                return nil
            } catch {
                await abort()
                throw error
            }
        }

        func close() async {
            await abort()
        }
    }

    private final class Upload: Transfer, RemoteWriter, @unchecked Sendable {
        func write(_ chunk: Data) async throws {
            do {
                try await data.send(chunk)
            } catch {
                // The server usually says why on the control connection.
                data.cancel()
                let reply = try? await fs.readReply()
                release()
                if let reply, !reply.isCompletion { throw FTPFileSystem.error(reply, path: path) }
                throw error
            }
        }

        func close() async throws {
            guard !isReleased else { return }
            do {
                // Say that nothing more is coming, wait for the server to confirm it has everything, and only then
                // close. Closing first can reset the connection while the server is still reading, which loses the
                // tail of the file (and, under TLS, makes some servers abort the whole session).
                if data.isEncrypted {
                    // Network.framework has no half-close under TLS: the orderly close of the connection
                    // (close_notify, then FIN) is what marks the end of the file.
                    data.cancel()
                    try await fs.endTransfer(path: path)
                } else {
                    // In clear, half-close and keep the connection until the server confirms.
                    try await data.finishSending()
                    try await fs.endTransfer(path: path)
                    data.cancel()
                }
                release()
            } catch {
                data.cancel()
                release()
                throw error
            }
        }
    }
}

/// Lets one task at a time use the control connection; the others wait in order.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            let free = lock.withLock { () -> Bool in
                if busy {
                    waiters.append(continuation)
                    return false
                }
                busy = true
                return true
            }
            if free { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                busy = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
