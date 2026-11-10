import Foundation

/// A selection and everything under it, as seen at one moment. Destructive actions act on exactly this list.
public struct RemoteTree: Sendable, Equatable {
    /// Parents come before their children.
    public var items: [RemoteItem] = []
    /// Folders whose content could not be listed.
    public var unreadable: [RemotePath] = []

    public init(items: [RemoteItem] = [], unreadable: [RemotePath] = []) {
        self.items = items
        self.unreadable = unreadable
    }

    public var directoryCount: Int { items.filter(\.isDirectory).count }
    public var fileCount: Int { items.count - directoryCount }
    public var totalSize: UInt64 { items.reduce(0) { $0 + ($1.kind == .file ? $1.size ?? 0 : 0) } }
}

public enum RemoteEnumerator {
    /// Lists the selection recursively. Symlinks are listed and never followed, so nothing outside the selection is reached.
    /// An unreadable folder is recorded and the rest is still returned.
    public static func enumerate(
        _ roots: [RemoteItem], on fs: any RemoteFileSystem, progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> RemoteTree {
        var tree = RemoteTree()
        var stack = Array(roots.reversed())
        while let item = stack.popLast() {
            try Task.checkCancellation()
            tree.items.append(item)
            progress?(tree.items.count)
            guard item.kind == .directory else { continue }
            do {
                let children = try await fs.list(item.path).sorted { NameComparison.ascending($0.name, $1.name) }
                stack.append(contentsOf: children.reversed())
            } catch let error as RemoteError {
                switch error {
                case .connectionLost, .cancelled, .authenticationFailed, .unreachable: throw error
                default: tree.unreadable.append(item.path)
                }
            }
        }
        return tree
    }
}

public struct RemoteFailure: Sendable, Equatable {
    public var path: RemotePath
    public var error: RemoteError

    public init(path: RemotePath, error: RemoteError) {
        self.path = path
        self.error = error
    }
}

public struct DeletionReport: Sendable, Equatable {
    public var deleted = 0
    public var failures: [RemoteFailure] = []

    public init() {}
}

public enum RemoteDeleter {
    /// Deletes exactly the items of the tree, children first. A folder that received new content meanwhile
    /// is left in place and reported; an item that already vanished is not an error.
    public static func delete(
        _ tree: RemoteTree, on fs: any RemoteFileSystem, progress: (@Sendable (Int) -> Void)? = nil
    ) async -> DeletionReport {
        var report = DeletionReport()
        for item in tree.items.reversed() {
            if Task.isCancelled { break }
            do {
                if item.kind == .directory {
                    try await fs.removeDirectory(item.path)
                } else {
                    try await fs.removeFile(item.path)
                }
                report.deleted += 1
            } catch RemoteError.notFound {
                report.deleted += 1
            } catch let error as RemoteError {
                report.failures.append(RemoteFailure(path: item.path, error: error))
                if case .connectionLost = error { break }
            } catch {
                report.failures.append(RemoteFailure(path: item.path, error: .server(error.localizedDescription)))
            }
            progress?(report.deleted)
        }
        return report
    }
}

public enum PermissionChanger {
    /// Applies permissions to every item of the tree. Symlinks are skipped: changing them would reach their target.
    /// With `adaptDirectories`, folders keep the search bit wherever they are readable.
    public static func apply(
        _ permissions: PermissionSet, to tree: RemoteTree, on fs: any RemoteFileSystem, adaptDirectories: Bool = true
    ) async -> [RemoteFailure] {
        var failures = [RemoteFailure]()
        for item in tree.items where item.kind == .file || item.kind == .directory {
            if Task.isCancelled { break }
            let bits = item.isDirectory && adaptDirectories ? permissions.adaptedForDirectory().bits : permissions.bits
            do {
                try await fs.setPermissions(bits, of: item.path)
            } catch let error as RemoteError {
                failures.append(RemoteFailure(path: item.path, error: error))
                if case .connectionLost = error { break }
            } catch {
                failures.append(RemoteFailure(path: item.path, error: .server(error.localizedDescription)))
            }
        }
        return failures
    }
}
