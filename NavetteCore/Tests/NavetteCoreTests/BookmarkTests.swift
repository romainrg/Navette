import XCTest
@testable import NavetteCore

final class BookmarkTests: XCTestCase {
    // MARK: - URLs

    func testParsesFullSFTPURL() throws {
        let parsed = try XCTUnwrap(ConnectionURL.parse("sftp://deploy@staging.example.org:2222/var/www"))
        XCTAssertEqual(parsed.bookmark.protocol, .sftp)
        XCTAssertEqual(parsed.bookmark.host, "staging.example.org")
        XCTAssertEqual(parsed.bookmark.port, 2222)
        XCTAssertEqual(parsed.bookmark.user, "deploy")
        XCTAssertEqual(parsed.bookmark.path, "/var/www")
        XCTAssertNil(parsed.password)
        XCTAssertEqual(parsed.bookmark.urlString, "sftp://deploy@staging.example.org:2222/var/www")
    }

    func testPasswordIsExtractedAndNeverKept() throws {
        let parsed = try XCTUnwrap(ConnectionURL.parse("ftps://bob:s3cr%40t@ftp.example.org/pub"))
        XCTAssertEqual(parsed.password, "s3cr@t")
        XCTAssertEqual(parsed.bookmark.protocol, .ftps)
        XCTAssertNil(parsed.bookmark.port)
        XCTAssertFalse(parsed.bookmark.urlString.contains("s3cr"))
        let json = String(decoding: try JSONEncoder().encode(parsed.bookmark), as: UTF8.self)
        XCTAssertFalse(json.contains("s3cr"))
    }

    func testSchemes() {
        XCTAssertEqual(ConnectionURL.parse("https://cloud.example.org/remote.php/dav/files/me")?.bookmark.protocol, .webdavs)
        XCTAssertEqual(ConnectionURL.parse("dav://nas.local:8080/")?.bookmark.protocol, .webdav)
        XCTAssertEqual(ConnectionURL.parse("dav://nas.local:8080/")?.bookmark.port, 8080)
        XCTAssertNil(ConnectionURL.parse("dav://nas.local:8080/")?.bookmark.path)
        XCTAssertEqual(ConnectionURL.parse("ssh://host")?.bookmark.protocol, .sftp)
        XCTAssertEqual(ConnectionURL.parse("ftp://host:21")?.bookmark.port, nil)
        XCTAssertNil(ConnectionURL.parse("gopher://host"))
        XCTAssertNil(ConnectionURL.parse(""))
    }

    func testScpStyleAndBareHost() {
        XCTAssertEqual(ConnectionURL.parse("myserver")?.bookmark.host, "myserver")
        XCTAssertEqual(ConnectionURL.parse("myserver")?.bookmark.protocol, .sftp)
        let scp = ConnectionURL.parse("me@host.example.org:projects/site")
        XCTAssertEqual(scp?.bookmark.user, "me")
        XCTAssertEqual(scp?.bookmark.host, "host.example.org")
        XCTAssertEqual(scp?.bookmark.path, "projects/site")
        XCTAssertEqual(ConnectionURL.parse("host:2200")?.bookmark.port, 2200)
        XCTAssertEqual(ConnectionURL.parse("sftp://[2001:db8::1]:2222/x")?.bookmark.host, "2001:db8::1")
    }

    func testHostsThatLookLikeOptionsAreRejected() {
        XCTAssertNil(ConnectionURL.parse("-oProxyCommand=id"))
        XCTAssertNil(ConnectionURL.parse("sftp://-oProxyCommand=id/"))
        XCTAssertNil(ConnectionURL.parse("user@-host"))
        XCTAssertFalse(ConnectionURL.isValidHost("host name"))
        XCTAssertFalse(ConnectionURL.isValidHost("host;id"))
        XCTAssertFalse(ConnectionURL.isValidHost("$(id)"))
        XCTAssertTrue(ConnectionURL.isValidHost("my_alias-2.example.org"))
        XCTAssertTrue(ConnectionURL.isValidHost("bücher.example"))
        XCTAssertFalse(ConnectionURL.isValidUser("-oFoo"))
        XCTAssertTrue(ConnectionURL.isValidUser("deploy"))
    }

    func testCredentialKeyDependsOnServerIdentity() {
        let a = Bookmark(protocol: .sftp, host: "Example.org", user: "me")
        var b = a
        b.id = UUID()
        b.name = "Other name"
        XCTAssertEqual(a.credentialKey, b.credentialKey)
        b.port = 2222
        XCTAssertNotEqual(a.credentialKey, b.credentialKey)
        XCTAssertEqual(a.credentialKey, "sftp://me@example.org:22")
    }

    // MARK: - Library

    private func sample() -> (BookmarkLibrary, folder: UUID, inner: Bookmark, top: Bookmark) {
        let inner = Bookmark(name: "Staging", protocol: .sftp, host: "staging.example.org", port: 2222, user: "deploy", path: "/var/www", color: .blue)
        let top = Bookmark(name: "NAS", protocol: .webdavs, host: "nas.example.org")
        let folder = BookmarkFolder(name: "Work", children: [.bookmark(inner)])
        return (BookmarkLibrary(nodes: [.folder(folder), .bookmark(top)]), folder.id, inner, top)
    }

    func testTreeOperations() {
        var (library, folder, inner, top) = sample()
        XCTAssertEqual(library.allBookmarks.map(\.name), ["Staging", "NAS"])

        var edited = inner
        edited.name = "Staging 2"
        XCTAssertTrue(library.update(edited))
        XCTAssertEqual(library.bookmark(inner.id)?.name, "Staging 2")

        XCTAssertTrue(library.move(top.id, to: folder, at: 0))
        XCTAssertEqual(library.nodes.count, 1)
        XCTAssertEqual(library.allBookmarks.map(\.name), ["NAS", "Staging 2"])

        XCTAssertFalse(library.move(folder, to: folder), "a folder cannot contain itself")
        let nested = BookmarkFolder(name: "Nested")
        library.add(.folder(nested), to: folder)
        XCTAssertFalse(library.move(folder, to: nested.id), "nor move into its own descendant")

        XCTAssertTrue(library.move(top.id, to: nil))
        XCTAssertEqual(library.nodes.map(\.name), ["Work", "NAS"])
        XCTAssertTrue(library.rename(folder, to: "Clients"))
        XCTAssertEqual(library.nodes.first?.name, "Clients")

        XCTAssertNotNil(library.remove(folder))
        XCTAssertEqual(library.allBookmarks.map(\.name), ["NAS"])
        XCTAssertNil(library.remove(UUID()))
    }

    func testRecentsAreDeduplicatedAndCapped() {
        var library = BookmarkLibrary()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<15 {
            library.noteConnection(to: Bookmark(host: "host\(index)"), at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(library.recents.count, BookmarkLibrary.maximumRecents)
        XCTAssertEqual(library.recents.first?.bookmark.host, "host14")
        library.noteConnection(to: Bookmark(host: "host10"), at: start.addingTimeInterval(100))
        XCTAssertEqual(library.recents.count, BookmarkLibrary.maximumRecents)
        XCTAssertEqual(library.recents.first?.bookmark.host, "host10")
        XCTAssertEqual(library.recents.filter { $0.bookmark.host == "host10" }.count, 1)
    }

    func testStoreRoundTripAndFileFormat() throws {
        let url = try temporaryDirectory().appendingPathComponent("nested/bookmarks.json")
        var (library, _, inner, _) = sample()
        library.noteConnection(to: inner, at: Date(timeIntervalSince1970: 1_800_000_000))
        try BookmarkStore(url: url).save(library)

        XCTAssertEqual(BookmarkStore(url: url).library, library)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["type"] as? String, "folder")
        let child = try XCTUnwrap((nodes[0]["children"] as? [[String: Any]])?.first)
        XCTAssertEqual(child["type"] as? String, "bookmark")
        XCTAssertEqual(child["protocol"] as? String, "sftp")
        XCTAssertEqual(child["port"] as? Int, 2222)
        XCTAssertEqual(child["color"] as? String, "blue")
        let recent = try XCTUnwrap((json["recents"] as? [[String: Any]])?.first)
        XCTAssertEqual(recent["date"] as? String, "2027-01-15T08:00:00Z")
    }

    func testStoreSurvivesMissingOrCorruptFile() throws {
        let url = try temporaryDirectory().appendingPathComponent("bookmarks.json")
        XCTAssertEqual(BookmarkStore(url: url).library, BookmarkLibrary())
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(BookmarkStore(url: url).library, BookmarkLibrary())
    }

    func testInMemoryStoreNeverWrites() throws {
        let store = BookmarkStore(url: nil)
        try store.save(sample().0)
        XCTAssertEqual(store.library.allBookmarks.count, 2)
    }

    func testInMemoryCredentialStore() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(store.secret(for: "k"))
        try store.setSecret("v", for: "k")
        XCTAssertEqual(store.secret(for: "k"), "v")
        try store.setSecret(nil, for: "k")
        XCTAssertNil(store.secret(for: "k"))
    }
}
