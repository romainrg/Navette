import Foundation

public enum BookmarkColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
}

/// A saved server. It never holds a secret: passwords live in the credential store.
public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var `protocol`: ServerProtocol
    public var host: String
    public var port: Int?
    public var user: String?
    public var path: String?
    public var color: BookmarkColor?
    /// SHA-256 of a TLS certificate the user chose to trust for this server.
    public var trustedCertificateSHA256: String?

    public init(
        id: UUID = UUID(), name: String = "", protocol: ServerProtocol = .sftp, host: String = "", port: Int? = nil,
        user: String? = nil, path: String? = nil, color: BookmarkColor? = nil, trustedCertificateSHA256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocol = `protocol`
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.color = color
        self.trustedCertificateSHA256 = trustedCertificateSHA256
    }

    public var displayName: String { name.isEmpty ? host : name }
    public var effectivePort: Int { port ?? `protocol`.defaultPort }

    /// "sftp://user@host:2222/path", without any secret.
    public var urlString: String {
        var text = `protocol`.scheme + "://"
        if let user, !user.isEmpty {
            text += (user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user) + "@"
        }
        text += host.contains(":") ? "[\(host)]" : host
        if let port, port != `protocol`.defaultPort { text += ":\(port)" }
        if let path, !path.isEmpty {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            text += encoded.hasPrefix("/") ? encoded : "/" + encoded
        }
        return text
    }

    /// The key of this server's password in the credential store.
    public var credentialKey: String {
        "\(`protocol`.rawValue)://\(user ?? "")@\(host.lowercased()):\(effectivePort)"
    }
}

public struct BookmarkFolder: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var children: [BookmarkNode]

    public init(id: UUID = UUID(), name: String, children: [BookmarkNode] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}

public enum BookmarkNode: Identifiable, Hashable, Sendable {
    case bookmark(Bookmark)
    case folder(BookmarkFolder)

    public var id: UUID {
        switch self {
        case .bookmark(let bookmark): bookmark.id
        case .folder(let folder): folder.id
        }
    }

    public var name: String {
        switch self {
        case .bookmark(let bookmark): bookmark.displayName
        case .folder(let folder): folder.name
        }
    }

    /// For `OutlineGroup`: `nil` for a bookmark, the children for a folder.
    public var children: [BookmarkNode]? {
        if case .folder(let folder) = self { return folder.children }
        return nil
    }
}

extension BookmarkNode: Codable {
    private enum CodingKeys: String, CodingKey { case type, id, name, children }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "folder":
            self = .folder(BookmarkFolder(
                id: try container.decode(UUID.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                children: try container.decodeIfPresent([BookmarkNode].self, forKey: .children) ?? []))
        default:
            self = .bookmark(try Bookmark(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bookmark(let bookmark):
            try container.encode("bookmark", forKey: .type)
            try bookmark.encode(to: encoder)
        case .folder(let folder):
            try container.encode("folder", forKey: .type)
            try container.encode(folder.id, forKey: .id)
            try container.encode(folder.name, forKey: .name)
            try container.encode(folder.children, forKey: .children)
        }
    }
}

public struct RecentConnection: Codable, Hashable, Sendable, Identifiable {
    public var bookmark: Bookmark
    public var date: Date

    public var id: UUID { bookmark.id }

    public init(bookmark: Bookmark, date: Date) {
        self.bookmark = bookmark
        self.date = date
    }
}

/// Everything the bookmark file holds.
public struct BookmarkLibrary: Codable, Hashable, Sendable {
    public static let maximumRecents = 10

    public var version = 1
    public var nodes: [BookmarkNode] = []
    public var recents: [RecentConnection] = []

    public init(nodes: [BookmarkNode] = [], recents: [RecentConnection] = []) {
        self.nodes = nodes
        self.recents = recents
    }

    public var allBookmarks: [Bookmark] {
        func collect(_ nodes: [BookmarkNode]) -> [Bookmark] {
            nodes.flatMap { node -> [Bookmark] in
                switch node {
                case .bookmark(let bookmark): [bookmark]
                case .folder(let folder): collect(folder.children)
                }
            }
        }
        return collect(nodes)
    }

    public func bookmark(_ id: UUID) -> Bookmark? {
        allBookmarks.first { $0.id == id }
    }

    /// Appends to a folder, or to the top level when `folder` is nil or unknown.
    public mutating func add(_ node: BookmarkNode, to folder: UUID? = nil) {
        if let folder, Self.mutate(&nodes, folder, { if case .folder(var f) = $0 { f.children.append(node); $0 = .folder(f) } }) {
            return
        }
        nodes.append(node)
    }

    /// Replaces the bookmark with the same identifier, wherever it is.
    @discardableResult
    public mutating func update(_ bookmark: Bookmark) -> Bool {
        Self.mutate(&nodes, bookmark.id) { $0 = .bookmark(bookmark) }
    }

    @discardableResult
    public mutating func rename(_ id: UUID, to name: String) -> Bool {
        Self.mutate(&nodes, id) { node in
            switch node {
            case .bookmark(var bookmark): bookmark.name = name; node = .bookmark(bookmark)
            case .folder(var folder): folder.name = name; node = .folder(folder)
            }
        }
    }

    /// Removes a bookmark, or a folder with everything inside. Returns what was removed.
    @discardableResult
    public mutating func remove(_ id: UUID) -> BookmarkNode? {
        Self.remove(&nodes, id)
    }

    /// Moves a node into a folder (or to the top level). A folder cannot move into itself or its descendants.
    @discardableResult
    public mutating func move(_ id: UUID, to folder: UUID?, at index: Int? = nil) -> Bool {
        if let folder {
            if folder == id { return false }
            if let moving = Self.find(nodes, id), case .folder(let f) = moving, Self.find(f.children, folder) != nil { return false }
            guard case .folder? = Self.find(nodes, folder) else { return false }
        }
        guard let node = Self.remove(&nodes, id) else { return false }
        if let folder {
            Self.mutate(&nodes, folder) { target in
                if case .folder(var f) = target {
                    f.children.insert(node, at: min(max(index ?? f.children.count, 0), f.children.count))
                    target = .folder(f)
                }
            }
        } else {
            nodes.insert(node, at: min(max(index ?? nodes.count, 0), nodes.count))
        }
        return true
    }

    public mutating func noteConnection(to bookmark: Bookmark, at date: Date) {
        recents.removeAll { $0.bookmark.id == bookmark.id || $0.bookmark.urlString == bookmark.urlString }
        recents.insert(RecentConnection(bookmark: bookmark, date: date), at: 0)
        if recents.count > Self.maximumRecents { recents.removeLast(recents.count - Self.maximumRecents) }
    }

    // MARK: - Tree helpers

    private static func find(_ nodes: [BookmarkNode], _ id: UUID) -> BookmarkNode? {
        for node in nodes {
            if node.id == id { return node }
            if case .folder(let folder) = node, let found = find(folder.children, id) { return found }
        }
        return nil
    }

    @discardableResult
    private static func mutate(_ nodes: inout [BookmarkNode], _ id: UUID, _ change: (inout BookmarkNode) -> Void) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                change(&nodes[index])
                return true
            }
            if case .folder(var folder) = nodes[index], mutate(&folder.children, id, change) {
                nodes[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    private static func remove(_ nodes: inout [BookmarkNode], _ id: UUID) -> BookmarkNode? {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            return nodes.remove(at: index)
        }
        for index in nodes.indices {
            if case .folder(var folder) = nodes[index], let removed = remove(&folder.children, id) {
                nodes[index] = .folder(folder)
                return removed
            }
        }
        return nil
    }
}

/// Reads and writes the bookmark file. A nil URL keeps everything in memory (demo mode, tests).
public final class BookmarkStore: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var current: BookmarkLibrary

    public init(url: URL?, initial: BookmarkLibrary = BookmarkLibrary()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let library = try? Self.decoder.decode(BookmarkLibrary.self, from: data) {
            current = library
        } else {
            current = initial
        }
    }

    public var library: BookmarkLibrary { lock.withLock { current } }

    public func save(_ library: BookmarkLibrary) throws {
        lock.withLock { current = library }
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(library).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
