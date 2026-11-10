import XCTest
@testable import NavetteCore

final class WebDAVTests: XCTestCase {
    func testParsesAnApacheListing() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
        <D:href>/files/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype><lp1:getlastmodified>Tue, 10 Nov 2026 10:00:00 GMT</lp1:getlastmodified></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>/files/report%20final.pdf</D:href>
        <D:propstat><D:prop><lp1:resourcetype/><lp1:getcontentlength>8388608</lp1:getcontentlength><lp1:getlastmodified>Mon, 09 Nov 2026 08:30:00 GMT</lp1:getlastmodified></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>/files/photos/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        </D:multistatus>
        """
        let items = try WebDAVParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.map(\.path.display), ["/files", "/files/report final.pdf", "/files/photos"])
        XCTAssertEqual(items.map(\.kind), [.directory, .file, .directory])
        XCTAssertEqual(items[1].size, 8_388_608)
        XCTAssertEqual(items[1].modified, WebDAVParser.date("Mon, 09 Nov 2026 08:30:00 GMT"))
        XCTAssertNotNil(items[1].modified)
        XCTAssertNil(items[2].size)
    }

    func testParsesANextcloudListingWithMissingProperties() throws {
        // Nextcloud answers with full URLs or paths, lowercase prefixes, and a 404 propstat for what an item lacks.
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
         <d:response>
          <d:href>https://cloud.example.org/remote.php/dav/files/romain/Documents/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Tue, 10 Nov 2026 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>/remote.php/dav/files/romain/Documents/caf%C3%A9%20%26%20th%C3%A9.txt</d:href>
          <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
         </d:response>
        </d:multistatus>
        """
        let items = try WebDAVParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.map(\.path.display), ["/remote.php/dav/files/romain/Documents", "/remote.php/dav/files/romain/Documents/café & thé.txt"])
        XCTAssertEqual(items[0].kind, .directory)
        XCTAssertEqual(items[1].size, 42)
        XCTAssertEqual(items[1].path.nameBytes, Array("café & thé.txt".utf8))
    }

    func testInvalidXMLIsAnError() {
        XCTAssertThrowsError(try WebDAVParser.parse(Data("<html><body>Login".utf8)))
    }

    func testPathsSurviveURLEncoding() {
        for name in HostileNames.all + [HostileNames.nfd] {
            let path = RemotePath("/base dir").appending(name)
            let encoded = WebDAVParser.encode(path)
            XCTAssertNil(encoded.unicodeScalars.first { !$0.isASCII || $0 == " " || $0 == "?" || $0 == "#" || $0 == "\n" }, name)
            XCTAssertEqual(WebDAVParser.pathBytes(fromHref: encoded), path.bytes, name)
        }
        XCTAssertEqual(WebDAVParser.encode(RemotePath("/a b/é")), "/a%20b/%C3%A9")
        let latin1 = RemotePath.root.appending([0x63, 0xE9])
        XCTAssertEqual(WebDAVParser.pathBytes(fromHref: WebDAVParser.encode(latin1)), latin1.bytes, "bytes that are not UTF-8 survive too")
        XCTAssertEqual(WebDAVParser.pathBytes(fromHref: "http://host:8080"), Array("/".utf8))
        XCTAssertEqual(WebDAVParser.pathBytes(fromHref: "/a%2Fb?x=1"), Array("/a/b".utf8))
    }

    func testDates() {
        XCTAssertEqual(WebDAVParser.date("Thu, 01 Jan 1970 00:01:40 GMT"), Date(timeIntervalSince1970: 100))
        XCTAssertNil(WebDAVParser.date("yesterday"))
    }

    func testStatusMapping() {
        let path = RemotePath("/a/b")
        XCTAssertEqual(WebDAVFileSystem.error(status: 404, method: "GET", path: path), .notFound("/a/b"))
        XCTAssertEqual(WebDAVFileSystem.error(status: 403, method: "PUT", path: path), .permissionDenied("/a/b"))
        XCTAssertEqual(WebDAVFileSystem.error(status: 405, method: "MKCOL", path: path), .alreadyExists("/a/b"))
        XCTAssertEqual(WebDAVFileSystem.error(status: 409, method: "PUT", path: path), .notFound("/a"))
        XCTAssertEqual(WebDAVFileSystem.error(status: 412, method: "MOVE", path: path), .alreadyExists("/a/b"))
        XCTAssertEqual(WebDAVFileSystem.error(status: 401, method: "GET", path: path), .authenticationFailed("HTTP 401"))
        XCTAssertEqual(WebDAVFileSystem.error(status: 500, method: "GET", path: path), .server("HTTP 500: /a/b"))
    }
}
