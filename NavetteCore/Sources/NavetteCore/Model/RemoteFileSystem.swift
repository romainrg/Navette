import Foundation

/// What a protocol or a server can do. Views hide what is not available.
public struct Capabilities: Hashable, Sendable {
    public var permissions = false
    public var symlinks = false
    /// `rename(overwrite: true)` replaces the target in one step.
    public var atomicReplace = false
    public var resumeUpload = false
    public var resumeDownload = false
    public var ownership = false

    public init(
        permissions: Bool = false, symlinks: Bool = false, atomicReplace: Bool = false,
        resumeUpload: Bool = false, resumeDownload: Bool = false, ownership: Bool = false
    ) {
        self.permissions = permissions
        self.symlinks = symlinks
        self.atomicReplace = atomicReplace
        self.resumeUpload = resumeUpload
        self.resumeDownload = resumeDownload
        self.ownership = ownership
    }

    public static let full = Capabilities(
        permissions: true, symlinks: true, atomicReplace: true, resumeUpload: true, resumeDownload: true, ownership: true)
}

public enum RemoteError: Error, Equatable, Sendable {
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case directoryNotEmpty(String)
    case unsupported(String)
    case connectionLost(String)
    case authenticationFailed(String)
    case hostKeyChanged(HostKeyChange)
    case untrustedCertificate(CertificateSummary)
    case unreachable(String)
    case cancelled
    /// A message from the server or from `ssh`, shown as is.
    case server(String)
    case protocolViolation(String)
}

public struct HostKeyChange: Equatable, Sendable {
    public var host: String
    public var keyType: String?
    public var fingerprint: String?
    public var knownHostsFile: String?
    public var knownHostsLine: Int?

    public init(host: String, keyType: String? = nil, fingerprint: String? = nil, knownHostsFile: String? = nil, knownHostsLine: Int? = nil) {
        self.host = host
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.knownHostsFile = knownHostsFile
        self.knownHostsLine = knownHostsLine
    }
}

public struct CertificateSummary: Equatable, Sendable {
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    /// Lowercase hexadecimal SHA-256 of the DER certificate.
    public var sha256: String
    public var reason: String

    public init(subject: String, issuer: String, notBefore: Date? = nil, notAfter: Date? = nil, sha256: String, reason: String) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.sha256 = sha256
        self.reason = reason
    }
}

public protocol RemoteReader: Sendable {
    /// The next chunk, or `nil` at the end of the file.
    func next() async throws -> Data?
    func close() async
}

public protocol RemoteWriter: Sendable {
    func write(_ data: Data) async throws
    /// Flushes and closes. The data is only guaranteed to be on the server once this returns.
    func close() async throws
    /// Closes without caring about pending data, after an error or a cancellation.
    func abort() async
}

/// One connection to a server. Implementations are safe to call from several tasks.
public protocol RemoteFileSystem: Sendable {
    var capabilities: Capabilities { get }

    /// The folder the server puts the user in after login.
    func home() async throws -> RemotePath
    /// The entries of a folder, without `.` and `..`. Symlinks are reported as symlinks.
    func list(_ path: RemotePath) async throws -> [RemoteItem]
    /// Does not follow symlinks.
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func read(_ path: RemotePath, offset: UInt64) async throws -> any RemoteReader
    /// `offset` nil truncates or creates the file; otherwise writing continues from there.
    func write(_ path: RemotePath, offset: UInt64?) async throws -> any RemoteWriter
    /// Same, when the caller knows how many bytes will follow. Protocols that announce a length use it.
    func write(_ path: RemotePath, offset: UInt64?, size: UInt64?) async throws -> any RemoteWriter
    func makeDirectory(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath, overwrite: Bool) async throws
    func removeFile(_ path: RemotePath) async throws
    /// Fails with `directoryNotEmpty` when something is left inside.
    func removeDirectory(_ path: RemotePath) async throws
    func setPermissions(_ permissions: UInt16, of path: RemotePath) async throws
    func disconnect() async
}

extension RemoteFileSystem {
    public func write(_ path: RemotePath, offset: UInt64?, size: UInt64?) async throws -> any RemoteWriter {
        try await write(path, offset: offset)
    }

    /// `nil` when the path does not exist.
    public func statIfExists(_ path: RemotePath) async throws -> RemoteItem? {
        do {
            return try await stat(path)
        } catch RemoteError.notFound {
            return nil
        }
    }
}
