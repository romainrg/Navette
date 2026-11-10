import XCTest
@testable import NavetteCore

final class FTPTests: XCTestCase {
    private let directory = RemotePath("/pub")
    private let now = Date(timeIntervalSince1970: 1_794_300_000) // 10 November 2026

    // MARK: - Replies

    func testSingleAndMultiLineReplies() throws {
        var parser = FTPReplyParser()
        let stream = "220 Welcome\r\n211-Features:\r\n MLST type*;size*;modify*;\r\n UTF8\r\n REST STREAM\r\n211 End\r\n230 Login successful.\r\n"
        let replies = try parser.append(Data(stream.utf8))
        XCTAssertEqual(replies.map(\.code), [220, 211, 230])
        XCTAssertEqual(replies[0].text, "Welcome")
        XCTAssertEqual(replies[1].lines.count, 5)
        XCTAssertTrue(replies[2].isCompletion)
        XCTAssertEqual(FTPListParser.features(replies[1]), ["MLST TYPE*;SIZE*;MODIFY*;", "MLST", "UTF8", "REST STREAM", "REST"])
    }

    func testRepliesSplitAcrossPackets() throws {
        var parser = FTPReplyParser()
        var replies = [FTPReply]()
        for byte in Data("150 Here comes the listing.\r\n226 Directory send OK.\r\n".utf8) {
            replies += try parser.append(Data([byte]))
        }
        XCTAssertEqual(replies.map(\.code), [150, 226])
        XCTAssertTrue(replies[0].isPreliminary)
    }

    func testMultiLineReplyWithLinesThatLookLikeCodes() throws {
        var parser = FTPReplyParser()
        let replies = try parser.append(Data("250-Listing\r\n 250 not the end\r\n123 nor this\r\n250 End\r\n".utf8))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].lines.count, 4)
    }

    func testGarbageIsRejected() {
        var parser = FTPReplyParser()
        XCTAssertThrowsError(try parser.append(Data("SSH-2.0-OpenSSH_9.6\r\n".utf8)))
    }

    func testPWDWithQuotes() {
        XCTAssertEqual(FTPListParser.parsePWD(Array("\"/home/me\" is the current directory".utf8))?.display, "/home/me")
        XCTAssertEqual(FTPListParser.parsePWD(Array("\"/a \"\"quoted\"\" dir\"".utf8))?.display, "/a \"quoted\" dir")
        XCTAssertNil(FTPListParser.parsePWD(Array("no path here".utf8)))
    }

    func testPassiveReplies() {
        XCTAssertEqual(FTPListParser.parseEPSV("Entering Extended Passive Mode (|||30039|)"), 30039)
        XCTAssertNil(FTPListParser.parseEPSV("Entering Extended Passive Mode (|||99999|)"))
        XCTAssertEqual(FTPListParser.parsePASV("Entering Passive Mode (192,168,1,2,117,48)."), 117 * 256 + 48)
        XCTAssertNil(FTPListParser.parsePASV("Entering Passive Mode"))
    }

    // MARK: - LIST, Unix

    func testUnixListing() {
        let listing = """
        total 24
        drwxr-xr-x    3 1000     1000         4096 Nov 09 09:40 assets
        -rw-r--r--    1 deploy   www-data     4812 Nov 08 09:40 index.html
        -rw-------    1 deploy   www-data      512 Jan 05  2025 .env
        lrwxrwxrwx    1 deploy   www-data       21 Nov 10 08:00 current -> releases/2026-11-09
        -rwsr-xr-t    1 root     root      8388608 Dec 25 23:59 name with  two spaces.bin
        crw-rw-rw-    1 root     wheel      3,   2 Nov 10 08:00 null
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let items = FTPListParser.parseLIST(Data(listing.utf8), directory: directory, now: now)
        XCTAssertEqual(items.map(\.name), ["assets", "index.html", ".env", "current", "name with  two spaces.bin"])
        XCTAssertEqual(items.map(\.kind), [.directory, .file, .file, .symlink, .file])
        XCTAssertEqual(items[1].size, 4812)
        XCTAssertEqual(items[1].owner, "deploy")
        XCTAssertEqual(items[1].group, "www-data")
        XCTAssertEqual(items[1].permissions, 0o644)
        XCTAssertEqual(items[2].permissions, 0o600)
        XCTAssertEqual(items[3].linkTarget, "releases/2026-11-09")
        XCTAssertEqual(items[4].permissions, 0o5755, "setuid and sticky bits")
        XCTAssertNil(items[0].size)

        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute], from: items[1].modified!), DateComponents(year: 2026, month: 11, day: 8, hour: 9, minute: 40))
        XCTAssertEqual(utc.component(.year, from: items[2].modified!), 2025)
        XCTAssertEqual(utc.component(.year, from: items[4].modified!), 2025, "a date without a year that would be in the future belongs to last year")
    }

    func testUnixListingWithoutGroupColumn() {
        let line = "-rw-r--r--   1 ftp      1234 Nov 08 09:40 report.pdf"
        let item = FTPListParser.parseLIST(Data(line.utf8), directory: directory, now: now).first
        XCTAssertEqual(item?.name, "report.pdf")
        XCTAssertEqual(item?.size, 1234)
        XCTAssertEqual(item?.owner, "ftp")
        XCTAssertNil(item?.group)
    }

    func testHostileNamesInListings() {
        let listing = "-rw-r--r-- 1 a b 1 Nov 08 09:40 ..\r\n-rw-r--r-- 1 a b 1 Nov 08 09:40 ../../etc/passwd\r\n-rw-r--r-- 1 a b 1 Nov 08 09:40 .\r\n-rw-r--r-- 1 a b 1 Nov 08 09:40 ok -> arrow.txt\r\n-rw-r--r-- 1 a b 1 Nov 08 09:40 🚀 café.txt\r\n"
        let items = FTPListParser.parseLIST(Data(listing.utf8), directory: directory, now: now)
        XCTAssertEqual(items.map(\.name), ["ok -> arrow.txt", "🚀 café.txt"], "an arrow is only a link target for symlinks")
        XCTAssertTrue(items.allSatisfy { $0.path.parent == directory })
    }

    // MARK: - LIST, DOS

    func testDOSListing() {
        let listing = "11-10-26  10:00AM       <DIR>          Program Files\r\n11-09-2026  11:59PM              1234 report final.docx\r\n01-01-99  12:05AM                 0 old.txt\r\n"
        let items = FTPListParser.parseLIST(Data(listing.utf8), directory: directory, now: now)
        XCTAssertEqual(items.map(\.name), ["Program Files", "report final.docx", "old.txt"])
        XCTAssertEqual(items.map(\.kind), [.directory, .file, .file])
        XCTAssertEqual(items[1].size, 1234)
        XCTAssertNil(items[1].permissions)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute], from: items[1].modified!), DateComponents(year: 2026, month: 11, day: 9, hour: 23, minute: 59))
        XCTAssertEqual(utc.dateComponents([.year, .hour], from: items[2].modified!), DateComponents(year: 1999, hour: 0))
    }

    // MARK: - MLSD

    func testMLSDListing() {
        let listing = """
        type=cdir;modify=20261110100000;UNIX.mode=0755; .
        type=pdir;modify=20261110100000;UNIX.mode=0755; ..
        type=dir;modify=20261109094000;UNIX.mode=0755;UNIX.owner=1000;UNIX.group=1000; assets
        type=file;size=4812;modify=20261108094000.123;UNIX.mode=0644;UNIX.ownername=deploy;UNIX.groupname=www-data; index.html
        Type=OS.unix=slink:/var/www/releases/3;size=21;modify=20261110080000; current
        type=file;size=7; name; with ; semicolons and spaces
        type=file;size=1; ../escape
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let items = FTPListParser.parseMLSD(Data(listing.utf8), directory: directory)
        XCTAssertEqual(items.map(\.name), ["assets", "index.html", "current", "name; with ; semicolons and spaces"])
        XCTAssertEqual(items.map(\.kind), [.directory, .file, .symlink, .file])
        XCTAssertEqual(items[1].size, 4812)
        XCTAssertEqual(items[1].permissions, 0o644)
        XCTAssertEqual(items[1].owner, "deploy")
        XCTAssertEqual(items[1].group, "www-data")
        XCTAssertEqual(items[0].owner, "1000")
        XCTAssertEqual(items[2].linkTarget, "/var/www/releases/3")
        XCTAssertEqual(items[1].modified, FTPListParser.timestamp("20261108094000"))
        XCTAssertEqual(FTPListParser.timestamp("19700101000140"), Date(timeIntervalSince1970: 100))
        XCTAssertNil(FTPListParser.timestamp("2026"))
    }

    func testSymbolicPermissions() {
        XCTAssertEqual(FTPListParser.permissions(fromSymbolic: Array("rwxr-xr-x".utf8)), 0o755)
        XCTAssertEqual(FTPListParser.permissions(fromSymbolic: Array("rwSr-sr-T".utf8)), 0o7654)
        XCTAssertNil(FTPListParser.permissions(fromSymbolic: Array("rwx".utf8)))
    }

    // MARK: - Errors

    func testErrorMapping() {
        let path = RemotePath("/pub/a")
        func reply(_ code: Int, _ text: String) -> FTPReply { FTPReply(code: code, lines: [Array(text.utf8)]) }
        XCTAssertEqual(FTPFileSystem.error(reply(550, "No such file or directory."), path: path), .notFound("/pub/a"))
        XCTAssertEqual(FTPFileSystem.error(reply(550, "Permission denied."), path: path), .permissionDenied("/pub/a"))
        XCTAssertEqual(FTPFileSystem.error(reply(530, "Login incorrect."), path: path), .authenticationFailed("Login incorrect."))
        XCTAssertEqual(FTPFileSystem.error(reply(550, "Create directory operation failed."), path: path), .server("Create directory operation failed.: /pub/a"))
        guard case .unsupported(let message) = FTPFileSystem.error(reply(522, "SSL connection failed: session reuse required"), path: path) else {
            return XCTFail("Expected an explanation about session reuse")
        }
        XCTAssertTrue(message.contains("require_ssl_reuse"))
    }
}
