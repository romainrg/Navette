import Foundation
import NavetteCore

/// Sample bookmarks, servers and transfers for `--demo` and the screenshot scenes. Everything is in memory.
enum DemoData {
    /// A fixed "now", so screenshots do not change from one day to the next.
    static let now = Date(timeIntervalSince1970: 1_794_300_000)

    private static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    static let staging = Bookmark(id: id(1), name: "Staging", protocol: .sftp, host: "staging.example.org", port: 2222, user: "deploy", path: "/var/www/site", color: .blue)
    static let production = Bookmark(id: id(2), name: "Production", protocol: .sftp, host: "www.example.org", user: "deploy", path: "/var/www/site", color: .red)
    static let nextcloud = Bookmark(id: id(3), name: "Nextcloud", protocol: .webdavs, host: "cloud.example.org", user: "romain", path: "/remote.php/dav/files/romain", color: .purple)
    static let nas = Bookmark(id: id(4), name: "NAS", protocol: .sftp, host: "nas.local", user: "admin", color: .green)
    static let archive = Bookmark(id: id(5), name: "Archive", protocol: .ftps, host: "ftp.example.net", user: "backup", color: .orange)

    static var library: BookmarkLibrary {
        BookmarkLibrary(
            nodes: [
                .folder(BookmarkFolder(id: id(10), name: "Work", children: [.bookmark(staging), .bookmark(production)])),
                .folder(BookmarkFolder(id: id(11), name: "Home", children: [.bookmark(nas), .bookmark(nextcloud)])),
                .bookmark(archive),
            ],
            recents: [
                RecentConnection(bookmark: staging, date: now.addingTimeInterval(-1_800)),
                RecentConnection(bookmark: nas, date: now.addingTimeInterval(-90_000)),
            ])
    }

    static func resolvedConfig(for bookmark: Bookmark) -> ResolvedSSHConfig {
        var config = ResolvedSSHConfig()
        config.hostName = bookmark.host == "staging.example.org" ? "10.0.12.34" : bookmark.host
        config.user = bookmark.user ?? "deploy"
        config.port = bookmark.port ?? 22
        config.identityFiles = ["~/.ssh/id_ed25519"]
        config.proxyJump = bookmark.host == "staging.example.org" ? "bastion.example.org" : nil
        return config
    }

    private static let megabyte: UInt64 = 1 << 20

    static func makeServer(for bookmark: Bookmark) -> InMemoryFileSystem {
        let home = RemotePath(bookmark.path ?? "/home/\(bookmark.user ?? "demo")")
        let capabilities: Capabilities = bookmark.protocol == .sftp ? .full : Capabilities(resumeDownload: true)
        let server = InMemoryFileSystem(capabilities: capabilities, home: home, chunkSize: 256 * 1024, storesContent: false, owner: bookmark.user ?? "demo", clock: { now })

        func file(_ path: String, _ size: UInt64, days: Double, permissions: UInt16 = 0o644) {
            server.addFile(home.appending(path), size: size, permissions: permissions, modified: now.addingTimeInterval(-days * 86_400))
        }
        func folder(_ path: String, days: Double) {
            server.addDirectory(home.appending(path), modified: now.addingTimeInterval(-days * 86_400))
        }

        folder("assets", days: 2)
        folder("assets/fonts", days: 40)
        folder("assets/img", days: 2)
        folder("config", days: 12)
        folder("logs", days: 0.1)
        folder("uploads", days: 1)
        folder("vendor", days: 30)
        file("index.html", 4_812, days: 2)
        file("about.html", 6_120, days: 9)
        file("contact.html", 3_904, days: 9)
        file("robots.txt", 68, days: 120)
        file("sitemap.xml", 18_430, days: 2)
        file("favicon.ico", 15_086, days: 300)
        file(".htaccess", 1_204, days: 60)
        file(".env", 512, days: 12, permissions: 0o600)
        file("deploy.sh", 2_048, days: 12, permissions: 0o755)
        file("composer.json", 1_822, days: 30)
        file("README.md", 3_300, days: 45)
        file("Présentation été 2026.pdf", 8 * megabyte + 412_000, days: 5)
        file("backup-2026-11-09.tar.gz", 412 * megabyte, days: 1)
        file("database.sql", 96 * megabyte, days: 1)
        file("assets/app.css", 48_212, days: 2)
        file("assets/app.js", 312_880, days: 2)
        file("assets/img/hero.jpg", 2 * megabyte, days: 2)
        file("assets/img/logo.svg", 9_120, days: 200)
        file("assets/fonts/Inter.woff2", 98_340, days: 40)
        file("config/nginx.conf", 2_890, days: 12)
        file("config/php.ini", 71_204, days: 80)
        file("logs/access.log", 54 * megabyte, days: 0.02)
        file("logs/error.log", 180_400, days: 0.1)
        file("uploads/photo-001.heic", 3 * megabyte, days: 1)
        file("uploads/photo-002.heic", 3 * megabyte + 120_000, days: 1)
        server.addSymlink(home.appending("current"), target: "releases/2026-11-09")
        server.faults.latency = .milliseconds(15)
        return server
    }

    /// Rows for the transfers drawer scene.
    static var transfers: [TransferSnapshot] {
        func item(_ direction: TransferItem.Direction, _ name: String, _ number: Int) -> TransferItem {
            TransferItem(
                id: id(100 + number), direction: direction, local: URL(fileURLWithPath: "/Users/demo/Downloads/\(name)"),
                remote: RemotePath("/var/www/site/\(name)"))
        }
        return [
            TransferSnapshot(item: item(.download, "backup-2026-11-09.tar.gz", 1), state: .running, bytesDone: 268 * megabyte, bytesTotal: 412 * megabyte, bytesPerSecond: 23.4 * 1_048_576, serverName: "Staging"),
            TransferSnapshot(item: item(.upload, "Présentation été 2026.pdf", 2), state: .running, bytesDone: 3 * megabyte, bytesTotal: 8 * megabyte + 412_000, bytesPerSecond: 4.1 * 1_048_576, serverName: "Staging"),
            TransferSnapshot(item: item(.download, "database.sql", 3), state: .paused, bytesDone: 31 * megabyte, bytesTotal: 96 * megabyte, serverName: "Staging"),
            TransferSnapshot(item: item(.upload, "hero.jpg", 4), state: .failed(.connectionLost("Broken pipe")), bytesDone: megabyte, bytesTotal: 2 * megabyte, serverName: "NAS"),
            TransferSnapshot(item: item(.upload, "app.css", 5), state: .finished, bytesDone: 48_212, bytesTotal: 48_212, serverName: "Staging"),
            TransferSnapshot(item: item(.upload, "app.js", 6), state: .queued, bytesDone: 0, bytesTotal: 312_880, serverName: "Staging"),
        ]
    }

    static var conflict: TransferConflict {
        TransferConflict(
            item: TransferItem(id: id(200), direction: .upload, local: URL(fileURLWithPath: "/Users/demo/Sites/index.html"), remote: RemotePath("/var/www/site/index.html"), group: id(201)),
            existingSize: 4_812, existingModified: now.addingTimeInterval(-2 * 86_400),
            incomingSize: 5_240, incomingModified: now.addingTimeInterval(-600), canResume: true)
    }
}
