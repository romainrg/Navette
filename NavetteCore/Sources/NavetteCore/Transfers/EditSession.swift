import Foundation

/// What is known about a remote file at one moment: enough to notice that someone else changed it.
public struct RemoteVersion: Equatable, Sendable {
    public var size: UInt64?
    public var modified: Date?

    public init(size: UInt64?, modified: Date?) {
        self.size = size
        self.modified = modified
    }

    public init(_ item: RemoteItem) {
        self.init(size: item.size, modified: item.modified)
    }
}

/// A remote file opened in a local editor ("Open With"). Each save of the local copy is sent back,
/// unless the remote file changed in the meantime: then the user decides.
public struct EditSession: Sendable, Equatable {
    public enum Decision: Equatable, Sendable {
        /// The local copy is what was last synced, or it is momentarily missing (editors save through a rename).
        case nothing
        case upload
        /// The remote file is not the one that was downloaded or last uploaded any more.
        case askBecauseRemoteChanged
    }

    public let remote: RemotePath
    public let local: URL
    public private(set) var knownRemote: RemoteVersion
    public private(set) var syncedLocal: LocalFileInfo?
    /// A save that has not reached the server.
    public private(set) var hasUnsentChanges = false

    public init(remote: RemotePath, local: URL, remoteVersion: RemoteVersion, localInfo: LocalFileInfo?) {
        self.remote = remote
        self.local = local
        knownRemote = remoteVersion
        syncedLocal = localInfo
    }

    public mutating func decide(local: LocalFileInfo?, remote: RemoteVersion?) -> Decision {
        guard let local, local.kind == .file, local != syncedLocal else { return .nothing }
        hasUnsentChanges = true
        return remote == knownRemote ? .upload : .askBecauseRemoteChanged
    }

    public mutating func didUpload(local: LocalFileInfo?, remote: RemoteVersion) {
        syncedLocal = local
        knownRemote = remote
        hasUnsentChanges = false
    }
}

/// Calls back when something changes in a folder. Editors save by writing a new file and renaming it over
/// the old one, so watching the file itself would miss the save.
public final class FolderWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    public init?(url: URL, queue: DispatchQueue = .global(qos: .utility), onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    public func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
