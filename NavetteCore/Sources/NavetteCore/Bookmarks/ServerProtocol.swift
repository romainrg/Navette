import Foundation

public enum ServerProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    case sftp, ftp, ftps, webdav, webdavs

    public var id: String { rawValue }

    public var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp, .ftps: 21
        case .webdav: 80
        case .webdavs: 443
        }
    }

    public var isEncrypted: Bool {
        switch self {
        case .sftp, .ftps, .webdavs: true
        case .ftp, .webdav: false
        }
    }

    /// The scheme Navette writes in URLs it shows or copies.
    public var scheme: String {
        switch self {
        case .sftp: "sftp"
        case .ftp: "ftp"
        case .ftps: "ftps"
        case .webdav: "http"
        case .webdavs: "https"
        }
    }

    /// Every scheme accepted when the user pastes a URL.
    public init?(scheme: String) {
        switch scheme.lowercased() {
        case "sftp", "ssh", "scp": self = .sftp
        case "ftp": self = .ftp
        case "ftps", "ftpes": self = .ftps
        case "http", "dav", "webdav": self = .webdav
        case "https", "davs", "webdavs": self = .webdavs
        default: return nil
        }
    }

    /// SSH resolves the user, port and keys from `~/.ssh/config`; the others need them from the bookmark.
    public var usesSSHConfig: Bool { self == .sftp }
}
