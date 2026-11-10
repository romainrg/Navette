import Foundation

public struct TransferPlan: Sendable, Equatable {
    public var items: [TransferItem] = []
    /// What was left out, for the summary shown to the user: symlinks that leave the selection, unreadable folders, unsafe names.
    public var skipped: [String] = []

    public init() {}

    public var totalSize: UInt64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    public var fileCount: Int { items.filter { $0.kind == .file }.count }
}

/// Expands a selection into the list of transfers to queue. Symlinks are never followed in either direction.
public enum TransferPlanner {
    public static func uploads(of urls: [URL], to directory: RemotePath, files: any LocalFiles, group: UUID = UUID()) throws -> TransferPlan {
        var plan = TransferPlan()
        func add(_ url: URL, name: [UInt8], into parent: RemotePath) throws {
            // The name is passed on exactly as the disk stores it, whatever its Unicode normalization form.
            let remote = parent.appending(name)
            guard let info = files.info(url) else { return }
            switch info.kind {
            case .file:
                plan.items.append(TransferItem(direction: .upload, local: url, remote: remote, size: info.size, group: group))
            case .directory:
                plan.items.append(TransferItem(direction: .upload, kind: .directory, local: url, remote: remote, group: group))
                let children = try files.entries(of: url).sorted { NameComparison.ascending($0.url.lastPathComponent, $1.url.lastPathComponent) }
                for child in children {
                    try add(child.url, name: child.name, into: remote)
                }
            case .symlink, .other:
                plan.skipped.append(url.path)
            }
        }
        for url in urls { try add(url, name: files.exactName(of: url), into: directory) }
        return plan
    }

    public static func downloads(of selection: [RemoteItem], on fs: any RemoteFileSystem, to directory: URL, group: UUID = UUID()) async throws -> TransferPlan {
        var plan = TransferPlan()
        let roots = selection.map(\.path)
        for root in selection {
            let tree = try await RemoteEnumerator.enumerate([root], on: fs)
            plan.skipped.append(contentsOf: tree.unreadable.map(\.display))
            let base = root.path.parent
            for item in tree.items {
                guard let local = localURL(for: item.path, under: base, in: directory) else {
                    plan.skipped.append(item.path.display)
                    continue
                }
                switch item.kind {
                case .file:
                    plan.items.append(TransferItem(direction: .download, local: local, remote: item.path, size: item.size, group: group))
                case .directory:
                    plan.items.append(TransferItem(direction: .download, kind: .directory, local: local, remote: item.path, group: group))
                case .symlink:
                    // A link selected on its own is downloaded as what it points to. Inside a folder, it is
                    // recreated only when it is relative and stays inside the selection.
                    if item.path == root.path {
                        plan.items.append(TransferItem(direction: .download, local: local, remote: item.path, group: group))
                    } else if let target = item.linkTarget, !target.hasPrefix("/"),
                              case let resolved = RemotePath.resolve(target, relativeTo: item.path.parent),
                              roots.contains(where: { resolved == $0 || resolved.isDescendant(of: $0) }) {
                        plan.items.append(TransferItem(direction: .download, kind: .symlink(target: target), local: local, remote: item.path, group: group))
                    } else {
                        plan.skipped.append(item.path.display)
                    }
                case .other:
                    plan.skipped.append(item.path.display)
                }
            }
        }
        return plan
    }

    /// Maps a remote path to a local one under `directory`. Returns `nil` for a name that could escape it
    /// (a hostile server can send `..` or a name with a slash).
    static func localURL(for path: RemotePath, under base: RemotePath, in directory: URL) -> URL? {
        guard path.isDescendant(of: base) || base.isRoot else { return nil }
        var url = directory
        for component in path.components.dropFirst(base.components.count) {
            let name = String(decoding: component, as: UTF8.self)
            guard isSafeName(name) else { return nil }
            url.appendPathComponent(name)
        }
        return url
    }

    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
