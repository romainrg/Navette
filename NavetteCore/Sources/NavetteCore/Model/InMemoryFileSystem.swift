import Foundation

/// A server that lives in memory, for tests and for demo mode. It never touches the network or the disk.
public final class InMemoryFileSystem: RemoteFileSystem, @unchecked Sendable {
    public struct Faults: Sendable {
        /// Added to every operation, and to every chunk of a transfer.
        public var latency: Duration?
        /// Reads of this path fail once this many bytes were delivered.
        public var failReadAfter: [RemotePath: UInt64] = [:]
        /// Writes to this path fail once this many bytes were accepted.
        public var failWriteAfter: [RemotePath: UInt64] = [:]
        /// Operations on these paths fail with `permissionDenied`.
        public var denied: Set<RemotePath> = []
        public var disconnected = false

        public init() {}
    }

    private struct Node {
        var kind: RemoteItem.Kind
        var data = Data()
        /// Used instead of `data` when `storesContent` is false.
        var size: UInt64 = 0
        var modified: Date
        var permissions: UInt16
        var linkTarget: String?
    }

    private let lock = NSLock()
    private var nodes: [RemotePath: Node] = [:]
    private var _faults = Faults()
    private var _log: [String] = []
    private let homePath: RemotePath
    private let clock: @Sendable () -> Date

    public let capabilities: Capabilities
    public let chunkSize: Int
    /// False keeps only sizes, so tests can move files larger than memory.
    public let storesContent: Bool
    public let owner: String

    public init(
        capabilities: Capabilities = .full, home: RemotePath = .root, chunkSize: Int = 64 * 1024,
        storesContent: Bool = true, owner: String = "demo", clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capabilities = capabilities
        self.homePath = home
        self.chunkSize = chunkSize
        self.storesContent = storesContent
        self.owner = owner
        self.clock = clock
        nodes[.root] = Node(kind: .directory, modified: clock(), permissions: 0o755)
        for ancestor in home.ancestors where nodes[ancestor] == nil {
            nodes[ancestor] = Node(kind: .directory, modified: clock(), permissions: 0o755)
        }
    }

    // MARK: - Test and demo setup

    public var faults: Faults {
        get { lock.withLock { _faults } }
        set { lock.withLock { _faults = newValue } }
    }

    /// The operations performed so far ("list /a", "remove /a/b"...).
    public var log: [String] { lock.withLock { _log } }

    @discardableResult
    public func addDirectory(_ path: RemotePath, permissions: UInt16 = 0o755, modified: Date? = nil) -> Self {
        lock.withLock {
            for ancestor in path.ancestors where nodes[ancestor] == nil {
                nodes[ancestor] = Node(kind: .directory, modified: modified ?? clock(), permissions: permissions)
            }
        }
        return self
    }

    @discardableResult
    public func addFile(_ path: RemotePath, data: Data = Data(), size: UInt64? = nil, permissions: UInt16 = 0o644, modified: Date? = nil) -> Self {
        addDirectory(path.parent)
        lock.withLock {
            nodes[path] = Node(
                kind: .file, data: storesContent ? data : Data(), size: size ?? UInt64(data.count),
                modified: modified ?? clock(), permissions: permissions)
        }
        return self
    }

    @discardableResult
    public func addSymlink(_ path: RemotePath, target: String) -> Self {
        addDirectory(path.parent)
        lock.withLock {
            nodes[path] = Node(kind: .symlink, modified: clock(), permissions: 0o777, linkTarget: target)
        }
        return self
    }

    public func contents(of path: RemotePath) -> Data? {
        lock.withLock { nodes[path].flatMap { $0.kind == .file ? $0.data : nil } }
    }

    public func exists(_ path: RemotePath) -> Bool {
        lock.withLock { nodes[path] != nil }
    }

    public var allPaths: [RemotePath] {
        lock.withLock { nodes.keys.filter { !$0.isRoot }.sorted { $0.display < $1.display } }
    }

    // MARK: - RemoteFileSystem

    public func home() async throws -> RemotePath {
        try await begin("home", homePath)
        return homePath
    }

    public func list(_ path: RemotePath) async throws -> [RemoteItem] {
        try await begin("list", path)
        return try lock.withLock {
            guard let node = nodes[path] else { throw RemoteError.notFound(path.display) }
            guard node.kind == .directory else { throw RemoteError.server("Not a directory: \(path.display)") }
            return nodes.filter { !$0.key.isRoot && $0.key.parent == path }.map { item($0.key, $0.value) }
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        try await begin("stat", path)
        return try lock.withLock {
            guard let node = nodes[path] else { throw RemoteError.notFound(path.display) }
            return item(path, node)
        }
    }

    public func read(_ path: RemotePath, offset: UInt64) async throws -> any RemoteReader {
        try await begin("read", path)
        let size: UInt64 = try lock.withLock {
            guard let node = nodes[path], node.kind == .file else { throw RemoteError.notFound(path.display) }
            return storesContent ? UInt64(node.data.count) : node.size
        }
        return Reader(fs: self, path: path, offset: min(offset, size))
    }

    public func write(_ path: RemotePath, offset: UInt64?) async throws -> any RemoteWriter {
        try await begin("write", path)
        try lock.withLock {
            guard let parent = nodes[path.parent], parent.kind == .directory else { throw RemoteError.notFound(path.parent.display) }
            if let existing = nodes[path], existing.kind == .directory { throw RemoteError.server("Is a directory: \(path.display)") }
            var node = nodes[path] ?? Node(kind: .file, modified: clock(), permissions: 0o644)
            if let offset {
                if storesContent { node.data = node.data.prefix(Int(offset)) } else { node.size = min(node.size, offset) }
            } else {
                node.data = Data()
                node.size = 0
            }
            node.modified = clock()
            nodes[path] = node
        }
        return Writer(fs: self, path: path)
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        try await begin("mkdir", path)
        try lock.withLock {
            guard nodes[path] == nil else { throw RemoteError.alreadyExists(path.display) }
            guard let parent = nodes[path.parent], parent.kind == .directory else { throw RemoteError.notFound(path.parent.display) }
            nodes[path] = Node(kind: .directory, modified: clock(), permissions: 0o755)
        }
    }

    public func rename(_ source: RemotePath, to destination: RemotePath, overwrite: Bool) async throws {
        try await begin("rename", source)
        try lock.withLock {
            guard nodes[source] != nil else { throw RemoteError.notFound(source.display) }
            guard nodes[destination.parent]?.kind == .directory else { throw RemoteError.notFound(destination.parent.display) }
            if let existing = nodes[destination] {
                guard overwrite, existing.kind != .directory else { throw RemoteError.alreadyExists(destination.display) }
            }
            let moved = nodes.filter { $0.key == source || $0.key.isDescendant(of: source) }
            for (path, node) in moved {
                nodes[path] = nil
                let suffix = Array(path.bytes.dropFirst(source.bytes.count))
                nodes[RemotePath(bytes: destination.bytes + suffix)] = node
            }
        }
    }

    public func removeFile(_ path: RemotePath) async throws {
        try await begin("remove", path)
        try lock.withLock {
            guard let node = nodes[path] else { throw RemoteError.notFound(path.display) }
            guard node.kind != .directory else { throw RemoteError.server("Is a directory: \(path.display)") }
            nodes[path] = nil
        }
    }

    public func removeDirectory(_ path: RemotePath) async throws {
        try await begin("rmdir", path)
        try lock.withLock {
            guard let node = nodes[path], node.kind == .directory else { throw RemoteError.notFound(path.display) }
            guard !nodes.keys.contains(where: { $0.isDescendant(of: path) }) else { throw RemoteError.directoryNotEmpty(path.display) }
            nodes[path] = nil
        }
    }

    public func setPermissions(_ permissions: UInt16, of path: RemotePath) async throws {
        guard capabilities.permissions else { throw RemoteError.unsupported("chmod") }
        try await begin("chmod", path)
        try lock.withLock {
            guard nodes[path] != nil else { throw RemoteError.notFound(path.display) }
            nodes[path]?.permissions = permissions & 0o7777
        }
    }

    public func disconnect() async {}

    // MARK: - Internals

    private func begin(_ operation: String, _ path: RemotePath) async throws {
        let faults = lock.withLock {
            _log.append("\(operation) \(path.display)")
            return _faults
        }
        if let latency = faults.latency { try await Task.sleep(for: latency) }
        if faults.disconnected { throw RemoteError.connectionLost("Disconnected") }
        if faults.denied.contains(path) { throw RemoteError.permissionDenied(path.display) }
    }

    private func item(_ path: RemotePath, _ node: Node) -> RemoteItem {
        RemoteItem(
            path: path, kind: node.kind,
            size: node.kind == .file ? (storesContent ? UInt64(node.data.count) : node.size) : nil,
            modified: node.modified,
            permissions: capabilities.permissions ? node.permissions : nil,
            owner: capabilities.ownership ? owner : nil,
            group: capabilities.ownership ? "staff" : nil,
            linkTarget: node.linkTarget)
    }

    private final class Reader: RemoteReader, @unchecked Sendable {
        let fs: InMemoryFileSystem
        let path: RemotePath
        var offset: UInt64
        var delivered: UInt64 = 0

        init(fs: InMemoryFileSystem, path: RemotePath, offset: UInt64) {
            self.fs = fs
            self.path = path
            self.offset = offset
        }

        func next() async throws -> Data? {
            let faults = fs.faults
            if let latency = faults.latency { try await Task.sleep(for: latency) }
            if faults.disconnected { throw RemoteError.connectionLost("Disconnected") }
            if let limit = faults.failReadAfter[path], delivered >= limit { throw RemoteError.connectionLost("Read failed") }
            let chunk: Data? = fs.lock.withLock {
                guard let node = fs.nodes[path] else { return nil }
                let size = fs.storesContent ? UInt64(node.data.count) : node.size
                guard offset < size else { return nil }
                var count = Int(min(UInt64(fs.chunkSize), size - offset))
                if let limit = faults.failReadAfter[path] { count = Int(min(UInt64(count), max(1, limit - delivered))) }
                if fs.storesContent {
                    let start = node.data.startIndex + Int(offset)
                    return node.data.subdata(in: start..<start + count)
                }
                return Data(count: count)
            }
            guard let chunk else { return nil }
            offset += UInt64(chunk.count)
            delivered += UInt64(chunk.count)
            return chunk
        }

        func close() async {}
    }

    private final class Writer: RemoteWriter, @unchecked Sendable {
        let fs: InMemoryFileSystem
        let path: RemotePath
        var accepted: UInt64 = 0

        init(fs: InMemoryFileSystem, path: RemotePath) {
            self.fs = fs
            self.path = path
        }

        func write(_ data: Data) async throws {
            let faults = fs.faults
            if let latency = faults.latency { try await Task.sleep(for: latency) }
            if faults.disconnected { throw RemoteError.connectionLost("Disconnected") }
            var data = data
            var failure: RemoteError?
            if let limit = faults.failWriteAfter[path], accepted + UInt64(data.count) > limit {
                data = data.prefix(Int(limit - min(limit, accepted)))
                failure = .connectionLost("Write failed")
            }
            fs.lock.withLock {
                guard fs.nodes[path] != nil else { return }
                if fs.storesContent { fs.nodes[path]?.data.append(data) } else { fs.nodes[path]?.size += UInt64(data.count) }
                fs.nodes[path]?.modified = fs.clock()
            }
            accepted += UInt64(data.count)
            if let failure { throw failure }
        }

        func close() async throws {
            if fs.faults.disconnected { throw RemoteError.connectionLost("Disconnected") }
        }

        func abort() async {}
    }
}
