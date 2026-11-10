import Foundation

/// An absolute path on a server, kept as the raw bytes the server sent.
/// SFTP v3 and FTP guarantee no encoding, so names are never decoded and re-encoded on their way back.
public struct RemotePath: Hashable, Sendable, CustomStringConvertible {
    private static let slash = UInt8(ascii: "/")

    public let bytes: [UInt8]

    public static let root = RemotePath(bytes: [slash])

    public init(bytes: [UInt8]) {
        var out: [UInt8] = [Self.slash]
        for byte in bytes {
            if byte == Self.slash, out.last == Self.slash { continue }
            out.append(byte)
        }
        if out.count > 1, out.last == Self.slash { out.removeLast() }
        self.bytes = out
    }

    public init(_ string: String) {
        self.init(bytes: Array(string.utf8))
    }

    public var isRoot: Bool { bytes.count == 1 }

    /// For display only: invalid UTF-8 is replaced, so this may not round-trip.
    public var display: String { String(decoding: bytes, as: UTF8.self) }
    public var description: String { display }

    public var components: [[UInt8]] {
        bytes.split(separator: Self.slash).map(Array.init)
    }

    public var nameBytes: [UInt8] { components.last ?? [] }
    public var name: String { isRoot ? "/" : String(decoding: nameBytes, as: UTF8.self) }

    public var parent: RemotePath {
        guard let index = bytes.lastIndex(of: Self.slash), index > 0 else { return .root }
        return RemotePath(bytes: Array(bytes[..<index]))
    }

    public func appending(_ name: [UInt8]) -> RemotePath {
        RemotePath(bytes: bytes + [Self.slash] + name)
    }

    public func appending(_ name: String) -> RemotePath {
        appending(Array(name.utf8))
    }

    /// Every ancestor from the root down to this path, inclusive.
    public var ancestors: [RemotePath] {
        var result = [RemotePath.root]
        var current = RemotePath.root
        for component in components {
            current = current.appending(component)
            result.append(current)
        }
        return result
    }

    public func isDescendant(of other: RemotePath) -> Bool {
        if other.isRoot { return !isRoot }
        return bytes.count > other.bytes.count
            && bytes.starts(with: other.bytes)
            && bytes[other.bytes.count] == Self.slash
    }

    /// Resolves `.` and `..` in a path typed by the user, against a base folder.
    public static func resolve(_ input: String, relativeTo base: RemotePath) -> RemotePath {
        let start: [[UInt8]] = input.hasPrefix("/") ? [] : base.components
        var stack = start
        for part in input.utf8.split(separator: slash) {
            if part.elementsEqual(".".utf8) { continue }
            if part.elementsEqual("..".utf8) { _ = stack.popLast(); continue }
            stack.append(Array(part))
        }
        return stack.reduce(RemotePath.root) { $0.appending($1) }
    }
}

/// Name comparison that ignores the Unicode normalization form (macOS tends to NFD, Linux to NFC).
/// Only used to compare and sort: the bytes sent to a server are always the original ones.
public enum NameComparison {
    public static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    public static func key(_ bytes: [UInt8]) -> String {
        key(String(decoding: bytes, as: UTF8.self))
    }

    public static func sameName(_ a: String, _ b: String) -> Bool {
        key(a) == key(b)
    }

    public static func ascending(_ a: String, _ b: String) -> Bool {
        key(a).localizedStandardCompare(key(b)) == .orderedAscending
    }
}
