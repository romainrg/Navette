import Foundation

/// Everything needed to open one SFTP channel through the system `ssh`.
public struct SSHConnection: Sendable {
    public var host: String
    public var user: String?
    public var port: Int?
    /// Share one authenticated connection between channels through a private control socket.
    public var controlPath: String?
    /// Added to the process environment: the askpass variables in production.
    public var environment: [String: String] = [:]
    /// Only tests use this, to point `ssh` at a temporary configuration.
    public var extraOptions: [String] = []

    public init(host: String, user: String? = nil, port: Int? = nil, controlPath: String? = nil, environment: [String: String] = [:], extraOptions: [String] = []) {
        self.host = host
        self.user = user
        self.port = port
        self.controlPath = controlPath
        self.environment = environment
        self.extraOptions = extraOptions
    }
}

public final class SFTPFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let client: SFTPClient
    /// Requests kept in flight during a transfer. With OpenSSH's 255 KiB chunks this bounds memory to about 4 MiB per file.
    private let window = 16

    public let capabilities: Capabilities

    public init(client: SFTPClient) {
        self.client = client
        capabilities = Capabilities(
            permissions: true, symlinks: true, atomicReplace: client.supports("posix-rename@openssh.com"),
            resumeUpload: true, resumeDownload: true, ownership: true)
    }

    public static func connect(_ connection: SSHConnection) async throws -> SFTPFileSystem {
        let arguments = try SSHCommand.sftpArguments(
            host: connection.host, user: connection.user, port: connection.port,
            controlPath: connection.controlPath, extraOptions: connection.extraOptions)
        var environment = ProcessInfo.processInfo.environment
        environment.merge(connection.environment) { _, new in new }
        let transport = SSHTransport(arguments: arguments, environment: environment, host: connection.host)
        let client = SFTPClient(transport: transport)
        do {
            try await client.start()
        } catch {
            transport.close()
            throw error
        }
        return SFTPFileSystem(client: client)
    }

    public func disconnect() async {
        client.close()
    }

    // MARK: - Metadata

    public func home() async throws -> RemotePath {
        let reply = try await client.request(SFTPType.realpath) { $0.string(".") }
        var reader = try client.expect(SFTPType.name, reply, path: ".")
        guard try reader.u32() >= 1 else { throw RemoteError.protocolViolation("Empty REALPATH reply") }
        return RemotePath(bytes: try reader.string())
    }

    public func list(_ path: RemotePath) async throws -> [RemoteItem] {
        let opened = try await client.request(SFTPType.opendir) { $0.string(path.bytes) }
        var reader = try client.expect(SFTPType.handle, opened, path: path.display)
        let handle = try reader.string()
        var items = [RemoteItem]()
        do {
            while true {
                let reply = try await client.request(SFTPType.readdir) { $0.string(handle) }
                if reply.type == SFTPType.status {
                    let status = try SFTPClient.status(reply)
                    if status.code == SFTPStatus.eof { break }
                    throw RemoteError.sftpStatus(code: status.code, message: status.message, path: path.display)
                }
                var names = try client.expect(SFTPType.name, reply, path: path.display)
                for _ in 0..<(try names.u32()) {
                    let name = try names.string()
                    let longName = try names.string()
                    let attributes = try SFTPAttributes(from: &names)
                    if name == [UInt8(ascii: ".")] || name == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
                    items.append(attributes.item(path: path.appending(name), longName: longName))
                }
            }
        } catch {
            _ = try? await client.request(SFTPType.close) { $0.string(handle) }
            throw error
        }
        _ = try? await client.request(SFTPType.close) { $0.string(handle) }

        let links = items.indices.filter { items[$0].kind == .symlink }
        if !links.isEmpty {
            let targets = await withTaskGroup(of: (Int, String?).self) { group -> [Int: String] in
                for index in links {
                    let linkPath = items[index].path
                    group.addTask { (index, try? await self.readLink(linkPath)) }
                }
                var found: [Int: String] = [:]
                for await (index, target) in group { found[index] = target }
                return found
            }
            for (index, target) in targets { items[index].linkTarget = target }
        }
        return items
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        let reply = try await client.request(SFTPType.lstat) { $0.string(path.bytes) }
        var reader = try client.expect(SFTPType.attrs, reply, path: path.display)
        var item = try SFTPAttributes(from: &reader).item(path: path)
        if item.kind == .symlink { item.linkTarget = try? await readLink(path) }
        return item
    }

    private func readLink(_ path: RemotePath) async throws -> String {
        let reply = try await client.request(SFTPType.readlink) { $0.string(path.bytes) }
        var reader = try client.expect(SFTPType.name, reply, path: path.display)
        guard try reader.u32() >= 1 else { throw RemoteError.protocolViolation("Empty READLINK reply") }
        return String(decoding: try reader.string(), as: UTF8.self)
    }

    // MARK: - Changes

    public func makeDirectory(_ path: RemotePath) async throws {
        let reply = try await client.request(SFTPType.mkdir) {
            $0.string(path.bytes)
            SFTPAttributes().encode(to: &$0)
        }
        do {
            try client.expectOK(reply, path: path.display)
        } catch RemoteError.server(let message) {
            if try await statIfExists(path) != nil { throw RemoteError.alreadyExists(path.display) }
            throw RemoteError.server(message)
        }
    }

    public func rename(_ source: RemotePath, to destination: RemotePath, overwrite: Bool) async throws {
        if overwrite {
            if capabilities.atomicReplace {
                let reply = try await client.request(SFTPType.extended) {
                    $0.string("posix-rename@openssh.com")
                    $0.string(source.bytes)
                    $0.string(destination.bytes)
                }
                try client.expectOK(reply, path: source.display)
                return
            }
            if let existing = try await statIfExists(destination), existing.kind != .directory {
                try await removeFile(destination)
            }
        }
        let reply = try await client.request(SFTPType.rename) {
            $0.string(source.bytes)
            $0.string(destination.bytes)
        }
        do {
            try client.expectOK(reply, path: source.display)
        } catch RemoteError.server(let message) {
            if try await statIfExists(destination) != nil { throw RemoteError.alreadyExists(destination.display) }
            throw RemoteError.server(message)
        }
    }

    public func removeFile(_ path: RemotePath) async throws {
        let reply = try await client.request(SFTPType.remove) { $0.string(path.bytes) }
        try client.expectOK(reply, path: path.display)
    }

    public func removeDirectory(_ path: RemotePath) async throws {
        let reply = try await client.request(SFTPType.rmdir) { $0.string(path.bytes) }
        do {
            try client.expectOK(reply, path: path.display)
        } catch RemoteError.server(let message) {
            if let entries = try? await list(path), !entries.isEmpty { throw RemoteError.directoryNotEmpty(path.display) }
            throw RemoteError.server(message)
        }
    }

    public func setPermissions(_ permissions: UInt16, of path: RemotePath) async throws {
        let reply = try await client.request(SFTPType.setstat) {
            $0.string(path.bytes)
            SFTPAttributes(permissions: UInt32(permissions & 0o7777)).encode(to: &$0)
        }
        try client.expectOK(reply, path: path.display)
    }

    // MARK: - Transfers

    private func open(_ path: RemotePath, flags: UInt32) async throws -> [UInt8] {
        let reply = try await client.request(SFTPType.open) {
            $0.string(path.bytes)
            $0.u32(flags)
            SFTPAttributes().encode(to: &$0)
        }
        var reader = try client.expect(SFTPType.handle, reply, path: path.display)
        return try reader.string()
    }

    public func read(_ path: RemotePath, offset: UInt64) async throws -> any RemoteReader {
        let handle = try await open(path, flags: SFTPOpenFlags.read)
        return Reader(client: client, handle: handle, path: path.display, offset: offset, window: window)
    }

    public func write(_ path: RemotePath, offset: UInt64?) async throws -> any RemoteWriter {
        var flags = SFTPOpenFlags.write | SFTPOpenFlags.create
        if offset == nil { flags |= SFTPOpenFlags.truncate }
        let handle = try await open(path, flags: flags)
        return Writer(client: client, handle: handle, path: path.display, offset: offset ?? 0, window: window)
    }

    /// Reads ahead with several READ requests in flight and hands the chunks back in order.
    private final class Reader: RemoteReader, @unchecked Sendable {
        private struct Pending {
            var offset: UInt64
            var length: Int
            var task: Task<Data?, Error>
        }

        private let client: SFTPClient
        private let handle: [UInt8]
        private let path: String
        private let window: Int
        private var nextOffset: UInt64
        private var inFlight: [Pending] = []
        private var finished = false

        init(client: SFTPClient, handle: [UInt8], path: String, offset: UInt64, window: Int) {
            self.client = client
            self.handle = handle
            self.path = path
            self.nextOffset = offset
            self.window = window
        }

        private func chunk(at offset: UInt64, length: Int) async throws -> Data? {
            let reply = try await client.request(SFTPType.read) { [handle] in
                $0.string(handle)
                $0.u64(offset)
                $0.u32(UInt32(length))
            }
            if reply.type == SFTPType.status, try SFTPClient.status(reply).code == SFTPStatus.eof { return nil }
            var reader = try client.expect(SFTPType.data, reply, path: path)
            return try reader.data()
        }

        func next() async throws -> Data? {
            guard !finished else { return nil }
            let length = client.limits.readLength
            while inFlight.count < window {
                let offset = nextOffset
                inFlight.append(Pending(offset: offset, length: length, task: Task { try await self.chunk(at: offset, length: length) }))
                nextOffset += UInt64(length)
            }
            let head = inFlight.removeFirst()
            guard var data = try await head.task.value else {
                finish()
                return nil
            }
            // A server may answer with less than asked before the end of the file: fill the gap in order.
            while data.count < head.length {
                guard let more = try await chunk(at: head.offset + UInt64(data.count), length: head.length - data.count) else {
                    finish()
                    break
                }
                data.append(more)
            }
            return data.isEmpty ? nil : data
        }

        private func finish() {
            finished = true
            inFlight.forEach { $0.task.cancel() }
            inFlight.removeAll()
        }

        func close() async {
            finish()
            _ = try? await client.request(SFTPType.close) { [handle] in $0.string(handle) }
        }
    }

    /// Sends WRITE requests without waiting for each reply, up to a window.
    private final class Writer: RemoteWriter, @unchecked Sendable {
        private let client: SFTPClient
        private let handle: [UInt8]
        private let path: String
        private let window: Int
        private var offset: UInt64
        private var inFlight: [Task<Void, Error>] = []

        init(client: SFTPClient, handle: [UInt8], path: String, offset: UInt64, window: Int) {
            self.client = client
            self.handle = handle
            self.path = path
            self.offset = offset
            self.window = window
        }

        func write(_ data: Data) async throws {
            let length = client.limits.writeLength
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + length, data.endIndex)
                let piece = data.subdata(in: start..<end)
                let at = offset
                if inFlight.count >= window { try await inFlight.removeFirst().value }
                inFlight.append(Task { [client, handle, path] in
                    let reply = try await client.request(SFTPType.write) {
                        $0.string(handle)
                        $0.u64(at)
                        $0.string(piece)
                    }
                    try client.expectOK(reply, path: path)
                })
                offset += UInt64(piece.count)
                start = end
            }
        }

        func close() async throws {
            do {
                for task in inFlight { try await task.value }
                inFlight.removeAll()
                if client.supports("fsync@openssh.com") {
                    _ = try? await client.request(SFTPType.extended) { [handle] in
                        $0.string("fsync@openssh.com")
                        $0.string(handle)
                    }
                }
            } catch {
                await abort()
                throw error
            }
            let reply = try await client.request(SFTPType.close) { [handle] in $0.string(handle) }
            try client.expectOK(reply, path: path)
        }

        func abort() async {
            inFlight.forEach { $0.cancel() }
            inFlight.removeAll()
            _ = try? await client.request(SFTPType.close) { [handle] in $0.string(handle) }
        }
    }
}
