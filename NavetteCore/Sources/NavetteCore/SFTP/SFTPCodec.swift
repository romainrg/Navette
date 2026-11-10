import Foundation

// SFTP version 3 wire format (draft-ietf-secsh-filexfer-02): big-endian integers, length-prefixed byte strings.

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ value: UInt8) { bytes.append(value) }

    public mutating func u32(_ value: UInt32) {
        bytes.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    public mutating func u64(_ value: UInt64) {
        u32(UInt32(value >> 32))
        u32(UInt32(value & 0xffff_ffff))
    }

    public mutating func string(_ value: [UInt8]) {
        u32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func string(_ value: String) { string(Array(value.utf8)) }

    public mutating func string(_ value: Data) {
        u32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }
}

public struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isAtEnd: Bool { offset >= bytes.count }
    public var remaining: Int { bytes.count - offset }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else { throw RemoteError.protocolViolation("Truncated SFTP packet") }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    public mutating func string() throws -> [UInt8] { Array(try take(Int(try u32()))) }
    public mutating func data() throws -> Data { Data(try take(Int(try u32()))) }
}

public enum SFTPType {
    public static let initialize: UInt8 = 1
    public static let version: UInt8 = 2
    public static let open: UInt8 = 3
    public static let close: UInt8 = 4
    public static let read: UInt8 = 5
    public static let write: UInt8 = 6
    public static let lstat: UInt8 = 7
    public static let setstat: UInt8 = 9
    public static let opendir: UInt8 = 11
    public static let readdir: UInt8 = 12
    public static let remove: UInt8 = 13
    public static let mkdir: UInt8 = 14
    public static let rmdir: UInt8 = 15
    public static let realpath: UInt8 = 16
    public static let stat: UInt8 = 17
    public static let rename: UInt8 = 18
    public static let readlink: UInt8 = 19
    public static let status: UInt8 = 101
    public static let handle: UInt8 = 102
    public static let data: UInt8 = 103
    public static let name: UInt8 = 104
    public static let attrs: UInt8 = 105
    public static let extended: UInt8 = 200
    public static let extendedReply: UInt8 = 201
}

public enum SFTPStatus {
    public static let ok: UInt32 = 0
    public static let eof: UInt32 = 1
    public static let noSuchFile: UInt32 = 2
    public static let permissionDenied: UInt32 = 3
    public static let failure: UInt32 = 4
    public static let noConnection: UInt32 = 6
    public static let connectionLost: UInt32 = 7
    public static let unsupported: UInt32 = 8
}

public enum SFTPOpenFlags {
    public static let read: UInt32 = 0x01
    public static let write: UInt32 = 0x02
    public static let create: UInt32 = 0x08
    public static let truncate: UInt32 = 0x10
}

public struct SFTPPacket: Equatable, Sendable {
    public var type: UInt8
    /// Everything after the type byte, starting with the request id (except for INIT and VERSION).
    public var payload: [UInt8]

    public init(type: UInt8, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }

    public var encoded: Data {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count + 1))
        writer.u8(type)
        return Data(writer.bytes + payload)
    }
}

/// Splits the byte stream coming from `ssh` into packets.
public struct SFTPFrameParser {
    /// Larger than anything a server may send: OpenSSH caps packets at 256 KiB.
    public static let maximumPacketLength = 4 * 1024 * 1024

    private var buffer = [UInt8]()
    private var consumed = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [SFTPPacket] {
        buffer.append(contentsOf: data)
        var packets = [SFTPPacket]()
        while buffer.count - consumed >= 4 {
            let length = buffer[consumed..<consumed + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maximumPacketLength else {
                throw RemoteError.protocolViolation("Invalid SFTP packet length \(length)")
            }
            guard buffer.count - consumed >= 4 + length else { break }
            let start = consumed + 4
            packets.append(SFTPPacket(type: buffer[start], payload: Array(buffer[start + 1..<start + length])))
            consumed = start + length
        }
        if consumed > 0 {
            buffer.removeFirst(consumed)
            consumed = 0
        }
        return packets
    }
}

public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil, accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    private static let sizeFlag: UInt32 = 0x1
    private static let ownerFlag: UInt32 = 0x2
    private static let permissionsFlag: UInt32 = 0x4
    private static let timesFlag: UInt32 = 0x8
    private static let extendedFlag: UInt32 = 0x8000_0000

    public init(from reader: inout ByteReader) throws {
        let flags = try reader.u32()
        if flags & Self.sizeFlag != 0 { size = try reader.u64() }
        if flags & Self.ownerFlag != 0 {
            uid = try reader.u32()
            gid = try reader.u32()
        }
        if flags & Self.permissionsFlag != 0 { permissions = try reader.u32() }
        if flags & Self.timesFlag != 0 {
            accessTime = try reader.u32()
            modificationTime = try reader.u32()
        }
        if flags & Self.extendedFlag != 0 {
            for _ in 0..<(try reader.u32()) {
                _ = try reader.string()
                _ = try reader.string()
            }
        }
    }

    public func encode(to writer: inout ByteWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.sizeFlag }
        if uid != nil, gid != nil { flags |= Self.ownerFlag }
        if permissions != nil { flags |= Self.permissionsFlag }
        if accessTime != nil, modificationTime != nil { flags |= Self.timesFlag }
        writer.u32(flags)
        if let size { writer.u64(size) }
        if let uid, let gid {
            writer.u32(uid)
            writer.u32(gid)
        }
        if let permissions { writer.u32(permissions) }
        if let accessTime, let modificationTime {
            writer.u32(accessTime)
            writer.u32(modificationTime)
        }
    }

    public var kind: RemoteItem.Kind {
        guard let permissions else { return .file }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default: return .other
        }
    }

    /// Builds an item from these attributes and the `ls -l` line OpenSSH sends along, used only for owner and group names.
    public func item(path: RemotePath, longName: [UInt8] = []) -> RemoteItem {
        let fields = String(decoding: longName, as: UTF8.self).split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        let named = fields.count >= 4 && fields[0].count >= 10
        return RemoteItem(
            path: path, kind: kind, size: kind == .directory ? nil : size,
            modified: modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            permissions: permissions.map { UInt16($0 & 0o7777) },
            owner: named ? String(fields[2]) : uid.map(String.init),
            group: named ? String(fields[3]) : gid.map(String.init))
    }
}

extension RemoteError {
    /// Maps an SFTP status reply to an error. `path` is only used in the message.
    static func sftpStatus(code: UInt32, message: String, path: String) -> RemoteError {
        switch code {
        case SFTPStatus.noSuchFile: .notFound(path)
        case SFTPStatus.permissionDenied: .permissionDenied(path)
        case SFTPStatus.unsupported: .unsupported(message.isEmpty ? path : message)
        case SFTPStatus.noConnection, SFTPStatus.connectionLost: .connectionLost(message)
        default: .server(message.isEmpty ? "SFTP error \(code): \(path)" : "\(message): \(path)")
        }
    }
}
