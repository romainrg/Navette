import XCTest
@testable import NavetteCore

final class InMemoryFileSystemTests: XCTestCase {
    func testDriverContract() async throws {
        let fs = InMemoryFileSystem()
        fs.addDirectory(RemotePath("/base"))
        try await DriverContract.run(fs, in: RemotePath("/base"))
    }

    func testHomeAndListing() async throws {
        let fs = InMemoryFileSystem(home: RemotePath("/home/demo"))
        fs.addFile(RemotePath("/home/demo/a.txt"), data: Data("a".utf8))
        fs.addSymlink(RemotePath("/home/demo/link"), target: "/etc")
        let home = try await fs.home()
        XCTAssertEqual(home.display, "/home/demo")
        let items = try await fs.list(home)
        XCTAssertEqual(items.map(\.name).sorted(), ["a.txt", "link"])
        XCTAssertEqual(items.first { $0.name == "link" }?.kind, .symlink)
        XCTAssertEqual(items.first { $0.name == "link" }?.linkTarget, "/etc")
    }

    func testFaults() async throws {
        let fs = InMemoryFileSystem(chunkSize: 10)
        let path = RemotePath("/file")
        fs.addFile(path, data: Data(repeating: 1, count: 100))
        fs.faults.failReadAfter[path] = 25
        let reader = try await fs.read(path, offset: 0)
        var received = 0
        do {
            while let chunk = try await reader.next() { received += chunk.count }
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(received, 25)
        }

        fs.faults = .init()
        fs.faults.denied = [path]
        await assertThrows({ $0 == .permissionDenied("/file") }) { try await fs.stat(path) }

        fs.faults = .init()
        fs.faults.failWriteAfter[RemotePath("/out")] = 15
        let writer = try await fs.write(RemotePath("/out"), offset: nil)
        try await writer.write(Data(repeating: 2, count: 10))
        do {
            try await writer.write(Data(repeating: 2, count: 10))
            XCTFail("Expected a failure")
        } catch {}
        XCTAssertEqual(fs.contents(of: RemotePath("/out"))?.count, 15)
    }

    func testCapabilitiesHidePermissions() async throws {
        let fs = InMemoryFileSystem(capabilities: Capabilities(resumeDownload: true))
        fs.addFile(RemotePath("/a"))
        let item = try await fs.stat(RemotePath("/a"))
        XCTAssertNil(item.permissions)
        XCTAssertNil(item.owner)
        await assertThrows({ $0 == .unsupported("chmod") }) { try await fs.setPermissions(0o600, of: RemotePath("/a")) }
    }

    func testSizeOnlyModeHoldsLargeFiles() async throws {
        let fs = InMemoryFileSystem(chunkSize: 1 << 20, storesContent: false)
        let fiveGigabytes: UInt64 = 5 << 30
        fs.addFile(RemotePath("/big"), size: fiveGigabytes)
        let item = try await fs.stat(RemotePath("/big"))
        XCTAssertEqual(item.size, fiveGigabytes)
        let reader = try await fs.read(RemotePath("/big"), offset: fiveGigabytes - 10)
        let tail = try await reader.next()
        XCTAssertEqual(tail?.count, 10)
    }
}
