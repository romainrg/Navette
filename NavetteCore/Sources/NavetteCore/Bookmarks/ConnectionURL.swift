import Foundation

/// Turns what the user pastes in Quick Connect into a bookmark.
public enum ConnectionURL {
    public struct Parsed: Equatable, Sendable {
        public var bookmark: Bookmark
        /// A password found in the URL. It is handed to the caller and never stored in the bookmark.
        public var password: String?
    }

    /// Accepts `sftp://user@host:2222/path`, `https://cloud.example.org/remote.php/dav`, `user@host:path` and a bare host.
    public static func parse(_ input: String, id: UUID = UUID()) -> Parsed? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") || text.contains("://") else { return nil }

        if let range = text.range(of: "://") {
            guard let proto = ServerProtocol(scheme: String(text[..<range.lowerBound])) else { return nil }
            // URLComponents only knows the usual schemes' rules; parse with a neutral one.
            guard let components = URLComponents(string: "x-navette://" + text[range.upperBound...].replacingOccurrences(of: " ", with: "%20")),
                  let host = components.host, isValidHost(host) else { return nil }
            let path = components.path
            return Parsed(
                bookmark: Bookmark(
                    id: id, protocol: proto, host: stripBrackets(host),
                    port: components.port.flatMap { $0 == proto.defaultPort ? nil : $0 },
                    user: components.user.flatMap { $0.isEmpty ? nil : $0 },
                    path: path.isEmpty || path == "/" ? nil : path),
                password: components.password)
        }

        // scp style: [user@]host[:path]
        var rest = Substring(text)
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var path: String?
        if !rest.hasPrefix("["), let colon = rest.firstIndex(of: ":") {
            let tail = rest[rest.index(after: colon)...]
            rest = rest[..<colon]
            if let port = Int(tail) {
                guard isValidHost(String(rest)) else { return nil }
                return Parsed(bookmark: Bookmark(id: id, protocol: .sftp, host: String(rest), port: port == 22 ? nil : port, user: user), password: nil)
            }
            path = tail.isEmpty ? nil : String(tail)
        }
        let host = stripBrackets(String(rest))
        guard isValidHost(host) else { return nil }
        return Parsed(bookmark: Bookmark(id: id, protocol: .sftp, host: host, user: user?.isEmpty == true ? nil : user, path: path), password: nil)
    }

    /// A host name, an SSH config alias or an IP address. Never something `ssh` could read as an option.
    public static func isValidHost(_ host: String) -> Bool {
        let host = stripBrackets(host)
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) || $0.value > 127 && $0.properties.isAlphabetic }
    }

    /// A user name `ssh -l` accepts and that cannot be read as an option.
    public static func isValidUser(_ user: String) -> Bool {
        !user.isEmpty && !user.hasPrefix("-") && !user.unicodeScalars.contains { $0.value < 32 || $0 == "\u{7f}" }
    }

    private static func stripBrackets(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
}
