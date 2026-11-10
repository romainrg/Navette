import XCTest
@testable import NavetteCore

final class RemotePathTests: XCTestCase {
    func testNormalizesSlashes() {
        XCTAssertEqual(RemotePath("/a//b/").bytes, Array("/a/b".utf8))
        XCTAssertEqual(RemotePath("a/b").display, "/a/b")
        XCTAssertEqual(RemotePath(""), .root)
        XCTAssertEqual(RemotePath("///"), .root)
    }

    func testParentNameAndAppending() {
        let path = RemotePath("/var/www/site")
        XCTAssertEqual(path.name, "site")
        XCTAssertEqual(path.parent, RemotePath("/var/www"))
        XCTAssertEqual(RemotePath("/var").parent, .root)
        XCTAssertEqual(RemotePath.root.parent, .root)
        XCTAssertEqual(RemotePath.root.appending("a").display, "/a")
        XCTAssertEqual(path.ancestors.map(\.display), ["/", "/var", "/var/www", "/var/www/site"])
    }

    func testDescendants() {
        XCTAssertTrue(RemotePath("/a/b").isDescendant(of: RemotePath("/a")))
        XCTAssertFalse(RemotePath("/ab").isDescendant(of: RemotePath("/a")))
        XCTAssertFalse(RemotePath("/a").isDescendant(of: RemotePath("/a")))
        XCTAssertTrue(RemotePath("/a").isDescendant(of: .root))
    }

    func testHostileNamesAreKeptByteForByte() {
        for name in HostileNames.all {
            let path = RemotePath("/base").appending(name)
            XCTAssertEqual(path.nameBytes, Array(name.utf8), name)
            XCTAssertEqual(path.parent, RemotePath("/base"), name)
        }
    }

    func testInvalidUTF8RoundTrips() {
        let latin1: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        let path = RemotePath.root.appending(latin1)
        XCTAssertEqual(path.nameBytes, latin1)
        XCTAssertEqual(path.name, "caf\u{FFFD}")
    }

    func testNormalizationIsOnlyForComparison() {
        let nfc = RemotePath.root.appending(HostileNames.nfc)
        let nfd = RemotePath.root.appending(HostileNames.nfd)
        XCTAssertNotEqual(nfc, nfd, "different bytes are different paths")
        XCTAssertNotEqual(nfc.nameBytes, nfd.nameBytes)
        XCTAssertTrue(NameComparison.sameName(nfc.name, nfd.name))
        XCTAssertEqual(NameComparison.key(nfd.nameBytes), NameComparison.key(nfc.nameBytes))
    }

    func testSortingIsNaturalAndNormalized() {
        let names = ["file10", "file2", HostileNames.nfd, "Banana", "apple"]
        XCTAssertEqual(names.sorted(by: NameComparison.ascending), ["apple", "Banana", HostileNames.nfd, "file2", "file10"])
    }

    func testResolveTypedPaths() {
        let base = RemotePath("/home/me")
        XCTAssertEqual(RemotePath.resolve("docs/../pics/./a", relativeTo: base).display, "/home/me/pics/a")
        XCTAssertEqual(RemotePath.resolve("/etc/../../x", relativeTo: base).display, "/x")
        XCTAssertEqual(RemotePath.resolve("..", relativeTo: base).display, "/home")
    }

    func testPermissionSet() {
        let set = PermissionSet(bits: 0o754)
        XCTAssertEqual(set.octal, "754")
        XCTAssertEqual(set.symbolic, "rwxr-xr--")
        XCTAssertTrue(set.allows(.write, for: .owner))
        XCTAssertFalse(set.allows(.write, for: .group))
        XCTAssertEqual(PermissionSet(octal: "0644")?.bits, 0o644)
        XCTAssertEqual(PermissionSet(octal: "7")?.bits, nil)
        XCTAssertNil(PermissionSet(octal: "9z9"))
        var changed = PermissionSet(bits: 0o600)
        changed.set(.read, for: .others, to: true)
        XCTAssertEqual(changed.octal, "604")
        XCTAssertEqual(changed.adaptedForDirectory().octal, "705")
        XCTAssertEqual(PermissionSet(bits: 0o7).octal, "007")
    }
}
