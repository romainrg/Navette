import CryptoKit
import Foundation

public struct TransferItem: Sendable, Identifiable, Equatable {
    public enum Direction: String, Sendable { case upload, download }
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        /// Download only: recreate a symlink that points inside the selection.
        case symlink(target: String)
    }

    public let id: UUID
    public var direction: Direction
    public var kind: Kind
    public var local: URL
    public var remote: RemotePath
    public var size: UInt64?
    /// Items queued together (one drag, one folder) share a group, so "apply to all" has a scope.
    public var group: UUID?

    public init(id: UUID = UUID(), direction: Direction, kind: Kind = .file, local: URL, remote: RemotePath, size: UInt64? = nil, group: UUID? = nil) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.local = local
        self.remote = remote
        self.size = size
        self.group = group
    }

    public var name: String { direction == .upload ? local.lastPathComponent : remote.name }
}

/// What to do when the destination already exists.
public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
    case ask, overwrite, resume, rename, skip
}

public enum ConflictResolution: String, Sendable, CaseIterable {
    case overwrite, resume, rename, skip
    /// Stops this transfer and leaves the destination untouched.
    case cancel
}

public struct TransferConflict: Sendable, Equatable {
    public var item: TransferItem
    public var existingSize: UInt64?
    public var existingModified: Date?
    public var incomingSize: UInt64?
    public var incomingModified: Date?
    /// The destination is shorter than the source and the protocol can append.
    public var canResume: Bool
}

public struct ConflictAnswer: Sendable {
    public var resolution: ConflictResolution
    /// Use the same resolution for the rest of the group.
    public var applyToAll: Bool

    public init(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

public enum TransferState: Equatable, Sendable {
    case queued
    case running
    case paused
    case finished
    case skipped
    case failed(RemoteError)
    case cancelled

    public var isDone: Bool {
        switch self {
        case .finished, .skipped, .cancelled: true
        default: false
        }
    }
}

public struct TransferSnapshot: Identifiable, Sendable, Equatable {
    public var item: TransferItem
    public var state: TransferState
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var bytesPerSecond: Double
    public var serverName: String

    public var id: UUID { item.id }

    public init(item: TransferItem, state: TransferState, bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0, bytesPerSecond: Double = 0, serverName: String = "") {
        self.item = item
        self.state = state
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.serverName = serverName
    }

    public var fraction: Double {
        if state == .finished { return 1 }
        return bytesTotal == 0 ? 0 : min(1, Double(bytesDone) / Double(bytesTotal))
    }

    public var secondsRemaining: Double? {
        guard state == .running, bytesPerSecond > 1, bytesTotal > bytesDone else { return nil }
        return Double(bytesTotal - bytesDone) / bytesPerSecond
    }
}

/// How Navette names its own files.
public enum TransferNames {
    public static let partialSuffix = ".navette-part"

    /// Upload: a hidden sibling of the target. File names are limited to 255 bytes, so long names are hashed.
    public static func remotePartial(for target: RemotePath) -> RemotePath {
        let name = target.nameBytes
        if name.count + 1 + partialSuffix.utf8.count <= 255 {
            return target.parent.appending([UInt8(ascii: ".")] + name + Array(partialSuffix.utf8))
        }
        let digest = SHA256.hash(data: Data(name)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return target.parent.appending(".\(digest)\(partialSuffix)")
    }

    public static func localPartial(for target: URL) -> URL {
        let name = target.lastPathComponent
        if name.utf8.count + partialSuffix.utf8.count <= 255 {
            return target.deletingLastPathComponent().appendingPathComponent(name + partialSuffix)
        }
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return target.deletingLastPathComponent().appendingPathComponent(digest + partialSuffix)
    }

    /// "report.pdf" → "report 2.pdf", "report 3.pdf"... The extension of a dot file is left alone.
    public static func numbered(_ name: String, _ number: Int) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "\(name) \(number)" }
        return "\(name[..<dot]) \(number)\(name[dot...])"
    }
}

/// Shared by every transfer: a byte budget per second.
public actor RateLimiter {
    private var rate: Double?
    private var balance: Double = 0
    private var last = ContinuousClock.now

    public init(bytesPerSecond: Int? = nil) {
        rate = bytesPerSecond.map(Double.init)
    }

    public func setRate(bytesPerSecond: Int?) {
        rate = bytesPerSecond.map(Double.init)
        balance = 0
        last = .now
    }

    /// Waits until `count` bytes fit the budget.
    public func acquire(_ count: Int) async throws {
        guard let rate, rate > 0 else { return }
        let now = ContinuousClock.now
        let elapsed = now - last
        last = now
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        balance = min(balance + seconds * rate, rate) - Double(count)
        if balance < 0 {
            try await Task.sleep(for: .seconds(-balance / rate))
        }
    }
}
