import Foundation

public struct LocalFileInfo: Equatable, Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }

    public var kind: Kind
    public var size: UInt64
    public var modified: Date?

    public init(kind: Kind, size: UInt64, modified: Date? = nil) {
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

public protocol LocalReader: AnyObject {
    /// `nil` at the end of the file.
    func read(upTo count: Int) throws -> Data?
    func close()
}

public protocol LocalWriter: AnyObject {
    func write(_ data: Data) throws
    func close() throws
}

public struct LocalEntry: Sendable, Equatable {
    public var url: URL
    /// The name exactly as the disk stores it.
    public var name: [UInt8]

    public init(url: URL, name: [UInt8]) {
        self.url = url
        self.name = name
    }
}

/// The Mac side of a transfer. The live implementation uses the disk; demo mode uses a simulated one that never touches it.
///
/// Foundation hands out file names in decomposed Unicode (NFD) whatever the disk stores, and writes them the same way.
/// To never rewrite a name silently, the exact bytes are read with `readdir` and written with `rename` and `mkdir`.
public protocol LocalFiles: Sendable {
    /// Does not follow symlinks. `nil` when nothing is there.
    func info(_ url: URL) -> LocalFileInfo?
    /// The name of an existing item, byte for byte as stored.
    func exactName(of url: URL) -> [UInt8]
    func entries(of directory: URL) throws -> [LocalEntry]
    func reader(_ url: URL, offset: UInt64) throws -> any LocalReader
    /// `offset` nil creates or truncates; otherwise the file is cut at `offset` and writing continues from there.
    func writer(_ url: URL, offset: UInt64?) throws -> any LocalWriter
    /// `exactName` gives the bytes to store for the last component; `nil` lets the system choose.
    func createDirectory(_ url: URL, exactName: [UInt8]?) throws
    func createSymlink(at url: URL, target: String) throws
    func move(_ source: URL, to destination: URL, exactName: [UInt8]?) throws
    /// Only for partial files Navette created itself.
    func removePartial(_ url: URL) throws
    /// For the user's files: they go to the Trash, never away for good.
    func trash(_ url: URL) throws
}

public struct DiskFiles: LocalFiles {
    private let trashItem: @Sendable (URL) throws -> Void

    /// Tests pass their own `trash` so nothing lands in the real Trash.
    public init(trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        trashItem = trash
    }

    public func info(_ url: URL) -> LocalFileInfo? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let kind: LocalFileInfo.Kind
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: kind = .file
        case .typeDirectory: kind = .directory
        case .typeSymbolicLink: kind = .symlink
        default: kind = .other
        }
        return LocalFileInfo(kind: kind, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modified: attributes[.modificationDate] as? Date)
    }

    public func entries(of directory: URL) throws -> [LocalEntry] {
        guard let stream = opendir(directory.path) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        defer { closedir(stream) }
        var entries = [LocalEntry]()
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name: [UInt8] = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            if name == [UInt8(ascii: ".")] || name == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
            entries.append(LocalEntry(url: directory.appendingPathComponent(String(decoding: name, as: UTF8.self)), name: name))
        }
        return entries
    }

    public func exactName(of url: URL) -> [UInt8] {
        let key = NameComparison.key(url.lastPathComponent)
        let stored = try? entries(of: url.deletingLastPathComponent()).first { NameComparison.key($0.name) == key }
        return stored?.name ?? Array(url.lastPathComponent.utf8)
    }

    /// The path of `url` with its last component spelled with exact bytes, as a C string.
    /// Only when those bytes are the same name as the URL's, up to Unicode normalization.
    private func exactPath(_ url: URL, _ name: [UInt8]) -> [CChar]? {
        guard let text = String(bytes: name, encoding: .utf8), TransferPlanner.isSafeName(text),
              NameComparison.sameName(text, url.lastPathComponent) else { return nil }
        return Array(url.deletingLastPathComponent().path.utf8CString.dropLast()) + [CChar(bitPattern: UInt8(ascii: "/"))] + name.map(CChar.init(bitPattern:)) + [0]
    }

    public func reader(_ url: URL, offset: UInt64) throws -> any LocalReader {
        let handle = try FileHandle(forReadingFrom: url)
        try handle.seek(toOffset: offset)
        return Reader(handle: handle)
    }

    public func writer(_ url: URL, offset: UInt64?) throws -> any LocalWriter {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: offset ?? 0)
        try handle.seekToEnd()
        return Writer(handle: handle)
    }

    public func createDirectory(_ url: URL, exactName: [UInt8]?) throws {
        if info(url) == nil, let exactName, let path = exactPath(url, exactName) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(path, 0o755) == 0 || errno == EEXIST { return }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func createSymlink(at url: URL, target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    public func move(_ source: URL, to destination: URL, exactName: [UInt8]?) throws {
        if let exactName, let path = exactPath(destination, exactName) {
            guard rename(source.path, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func removePartial(_ url: URL) throws {
        precondition(url.lastPathComponent.hasSuffix(TransferNames.partialSuffix), "only Navette's own partial files are removed directly")
        try FileManager.default.removeItem(at: url)
    }

    public func trash(_ url: URL) throws {
        try trashItem(url)
    }

    private final class Reader: LocalReader {
        let handle: FileHandle
        init(handle: FileHandle) { self.handle = handle }
        func read(upTo count: Int) throws -> Data? {
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return nil }
            return data
        }
        func close() { try? handle.close() }
    }

    private final class Writer: LocalWriter {
        let handle: FileHandle
        init(handle: FileHandle) { self.handle = handle }
        func write(_ data: Data) throws { try handle.write(contentsOf: data) }
        func close() throws { try handle.close() }
    }
}

/// A Mac that only exists in memory: files have a size and no content. Used by demo mode and by tests with huge files.
public final class SimulatedFiles: LocalFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: LocalFileInfo] = [:]
    private var links: [String: String] = [:]
    private var _trashed: [URL] = []

    public init() {}

    public var trashed: [URL] { lock.withLock { _trashed } }
    public var paths: [String] { lock.withLock { files.keys.sorted() } }

    public func add(_ url: URL, size: UInt64, modified: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        lock.withLock {
            var parent = url.deletingLastPathComponent()
            while parent.path != "/", files[parent.path] == nil {
                files[parent.path] = LocalFileInfo(kind: .directory, size: 0)
                parent = parent.deletingLastPathComponent()
            }
            files[url.path] = LocalFileInfo(kind: .file, size: size, modified: modified)
        }
    }

    public func info(_ url: URL) -> LocalFileInfo? {
        lock.withLock { files[url.path] }
    }

    public func entries(of directory: URL) throws -> [LocalEntry] {
        lock.withLock {
            files.keys.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == directory.path }.sorted()
                .map { LocalEntry(url: URL(fileURLWithPath: $0), name: Array(URL(fileURLWithPath: $0).lastPathComponent.utf8)) }
        }
    }

    public func exactName(of url: URL) -> [UInt8] {
        Array(url.lastPathComponent.utf8)
    }

    public func reader(_ url: URL, offset: UInt64) throws -> any LocalReader {
        guard let info = info(url), info.kind == .file else { throw CocoaError(.fileNoSuchFile) }
        return Reader(remaining: info.size - min(offset, info.size))
    }

    public func writer(_ url: URL, offset: UInt64?) throws -> any LocalWriter {
        lock.withLock {
            let existing = files[url.path]?.size ?? 0
            files[url.path] = LocalFileInfo(kind: .file, size: min(existing, offset ?? 0), modified: Date())
        }
        return Writer(files: self, path: url.path)
    }

    public func createDirectory(_ url: URL, exactName: [UInt8]?) throws {
        lock.withLock { if files[url.path] == nil { files[url.path] = LocalFileInfo(kind: .directory, size: 0) } }
    }

    public func createSymlink(at url: URL, target: String) throws {
        lock.withLock {
            files[url.path] = LocalFileInfo(kind: .symlink, size: 0)
            links[url.path] = target
        }
    }

    public func move(_ source: URL, to destination: URL, exactName: [UInt8]?) throws {
        try lock.withLock {
            guard let info = files.removeValue(forKey: source.path) else { throw CocoaError(.fileNoSuchFile) }
            files[destination.path] = info
        }
    }

    public func removePartial(_ url: URL) throws {
        lock.withLock { files[url.path] = nil }
    }

    public func trash(_ url: URL) throws {
        lock.withLock {
            files[url.path] = nil
            _trashed.append(url)
        }
    }

    private final class Reader: LocalReader {
        var remaining: UInt64
        init(remaining: UInt64) { self.remaining = remaining }
        func read(upTo count: Int) throws -> Data? {
            guard remaining > 0 else { return nil }
            let length = Int(min(UInt64(count), remaining))
            remaining -= UInt64(length)
            return Data(count: length)
        }
        func close() {}
    }

    private final class Writer: LocalWriter {
        let files: SimulatedFiles
        let path: String
        init(files: SimulatedFiles, path: String) {
            self.files = files
            self.path = path
        }
        func write(_ data: Data) throws {
            files.lock.withLock { files.files[path]?.size += UInt64(data.count) }
        }
        func close() throws {}
    }
}
