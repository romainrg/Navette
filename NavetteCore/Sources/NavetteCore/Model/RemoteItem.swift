import Foundation

public struct RemoteItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case file, directory, symlink, other
    }

    public var path: RemotePath
    public var kind: Kind
    public var size: UInt64?
    public var modified: Date?
    /// The twelve permission bits (`0o7777`), when the protocol provides them.
    public var permissions: UInt16?
    public var owner: String?
    public var group: String?
    public var linkTarget: String?

    public init(
        path: RemotePath, kind: Kind, size: UInt64? = nil, modified: Date? = nil, permissions: UInt16? = nil,
        owner: String? = nil, group: String? = nil, linkTarget: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.linkTarget = linkTarget
    }

    public var id: RemotePath { path }
    public var name: String { path.name }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { path.nameBytes.first == UInt8(ascii: ".") }
}

/// Unix permission bits with the conversions the inspector needs.
public struct PermissionSet: Hashable, Sendable {
    public var bits: UInt16

    public init(bits: UInt16) {
        self.bits = bits & 0o7777
    }

    /// Accepts three or four octal digits ("644", "0755").
    public init?(octal: String) {
        let trimmed = octal.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), let value = UInt16(trimmed, radix: 8) else { return nil }
        self.init(bits: value)
    }

    public var octal: String {
        let text = String(bits, radix: 8)
        return String(repeating: "0", count: max(0, 3 - text.count)) + text
    }

    /// "rwxr-xr-x"
    public var symbolic: String {
        let flags: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(flags.map { bits & $0.0 != 0 ? $0.1 : "-" })
    }

    public enum Scope: Int, CaseIterable, Sendable { case owner = 6, group = 3, others = 0 }
    public enum Access: UInt16, CaseIterable, Sendable { case read = 4, write = 2, execute = 1 }

    public func allows(_ access: Access, for scope: Scope) -> Bool {
        bits & (access.rawValue << UInt16(scope.rawValue)) != 0
    }

    public mutating func set(_ access: Access, for scope: Scope, to allowed: Bool) {
        let mask = access.rawValue << UInt16(scope.rawValue)
        bits = allowed ? bits | mask : bits & ~mask
    }

    /// For a recursive change: folders keep or gain the search bit wherever they are readable.
    public func adaptedForDirectory() -> PermissionSet {
        var copy = self
        for scope in Scope.allCases where copy.allows(.read, for: scope) {
            copy.set(.execute, for: scope, to: true)
        }
        return copy
    }
}
