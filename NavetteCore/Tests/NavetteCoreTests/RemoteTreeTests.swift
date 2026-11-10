import XCTest
@testable import NavetteCore

final class RemoteTreeTests: XCTestCase {
    /// /site with two files and a subfolder, a symlink that leaves the selection, and /other that must never be touched.
    private func makeServer() -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        fs.addFile(RemotePath("/site/index.html"), data: Data(count: 100))
        fs.addFile(RemotePath("/site/assets/app.js"), data: Data(count: 300))
        fs.addFile(RemotePath("/site/assets/img/logo.png"), data: Data(count: 1000))
        fs.addDirectory(RemotePath("/site/empty"))
        fs.addSymlink(RemotePath("/site/outside"), target: "/other")
        fs.addSymlink(RemotePath("/site/assets/inside"), target: "app.js")
        fs.addFile(RemotePath("/other/precious.txt"), data: Data(count: 5))
        return fs
    }

    private func root(_ fs: InMemoryFileSystem, _ path: String) async throws -> RemoteItem {
        try await fs.stat(RemotePath(path))
    }

    func testEnumerationNeverFollowsSymlinks() async throws {
        let fs = makeServer()
        let tree = try await RemoteEnumerator.enumerate([try await root(fs, "/site")], on: fs)
        XCTAssertEqual(tree.items.map(\.path.display), [
            "/site", "/site/assets", "/site/assets/app.js", "/site/assets/img", "/site/assets/img/logo.png",
            "/site/assets/inside", "/site/empty", "/site/index.html", "/site/outside",
        ])
        XCTAssertEqual(tree.totalSize, 1400)
        XCTAssertEqual(tree.directoryCount, 4)
        XCTAssertEqual(tree.fileCount, 5)
        XCTAssertFalse(fs.log.contains("list /other"), "the target of a symlink is never listed")
    }

    func testUnreadableFoldersAreReportedAndTheRestIsReturned() async throws {
        let fs = makeServer()
        fs.faults.denied = [RemotePath("/site/assets")]
        let tree = try await RemoteEnumerator.enumerate([try await root(fs, "/site/index.html"), RemoteItem(path: RemotePath("/site/assets"), kind: .directory), try await root(fs, "/site/empty")], on: fs)
        XCTAssertEqual(tree.unreadable, [RemotePath("/site/assets")])
        XCTAssertEqual(tree.items.map(\.name), ["index.html", "assets", "empty"])
    }

    func testEnumerationStopsOnConnectionLoss() async throws {
        let fs = makeServer()
        let site = try await root(fs, "/site")
        fs.faults.disconnected = true
        await assertThrows({ if case .connectionLost = $0 { true } else { false } }) {
            try await RemoteEnumerator.enumerate([site], on: fs)
        }
    }

    func testDeletionRemovesExactlyTheTree() async throws {
        let fs = makeServer()
        let tree = try await RemoteEnumerator.enumerate([try await root(fs, "/site")], on: fs)
        let report = await RemoteDeleter.delete(tree, on: fs)
        XCTAssertEqual(report.deleted, 9)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(fs.allPaths.map(\.display), ["/other", "/other/precious.txt"], "the symlink was removed, not its target")
    }

    func testDeletionLeavesWhatAppearedAfterTheListing() async throws {
        let fs = makeServer()
        let tree = try await RemoteEnumerator.enumerate([try await root(fs, "/site")], on: fs)
        fs.addFile(RemotePath("/site/assets/new-upload.txt"), data: Data(count: 1))
        let report = await RemoteDeleter.delete(tree, on: fs)
        XCTAssertEqual(report.failures.map(\.path.display), ["/site/assets", "/site"])
        XCTAssertEqual(report.failures.first?.error, .directoryNotEmpty("/site/assets"))
        XCTAssertTrue(fs.exists(RemotePath("/site/assets/new-upload.txt")), "an item nobody saw is never deleted")
    }

    func testDeletionToleratesItemsAlreadyGone() async throws {
        let fs = makeServer()
        let tree = try await RemoteEnumerator.enumerate([try await root(fs, "/site/assets")], on: fs)
        try await fs.removeFile(RemotePath("/site/assets/app.js"))
        let report = await RemoteDeleter.delete(tree, on: fs)
        XCTAssertEqual(report.failures, [])
        XCTAssertFalse(fs.exists(RemotePath("/site/assets")))
    }

    func testRecursivePermissionsSkipSymlinksAndAdaptFolders() async throws {
        let fs = makeServer()
        let tree = try await RemoteEnumerator.enumerate([try await root(fs, "/site/assets")], on: fs)
        let failures = await PermissionChanger.apply(PermissionSet(bits: 0o640), to: tree, on: fs)
        XCTAssertEqual(failures, [])
        let file = try await fs.stat(RemotePath("/site/assets/app.js"))
        XCTAssertEqual(file.permissions, 0o640)
        let folder = try await fs.stat(RemotePath("/site/assets/img"))
        XCTAssertEqual(folder.permissions, 0o750)
        XCTAssertFalse(fs.log.contains("chmod /site/assets/inside"))
    }

    // MARK: - Planning

    func testUploadPlanSkipsSymlinksAndKeepsNames() throws {
        let home = try temporaryDirectory()
        let folder = home.appendingPathComponent("My Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub/empty"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appendingPathComponent("a.txt"))
        try Data(count: 20).write(to: folder.appendingPathComponent("sub/\(HostileNames.nfd)"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        let plan = try TransferPlanner.uploads(of: [folder], to: RemotePath("/var/www"), files: DiskFiles())
        XCTAssertEqual(plan.items.map(\.remote.display), [
            "/var/www/My Project", "/var/www/My Project/a.txt", "/var/www/My Project/sub",
            "/var/www/My Project/sub/\(HostileNames.nfd)", "/var/www/My Project/sub/empty",
        ])
        XCTAssertEqual(plan.items.map(\.kind), [.directory, .file, .directory, .file, .directory])
        XCTAssertEqual(plan.totalSize, 30)
        XCTAssertEqual(plan.skipped.map { URL(fileURLWithPath: $0).lastPathComponent }, ["link"])
        XCTAssertEqual(Set(plan.items.map(\.group)).count, 1)
        // The decomposed name stays decomposed: it is never rewritten on its way to the server.
        XCTAssertEqual(plan.items[3].remote.nameBytes, Array(HostileNames.nfd.utf8))
    }

    func testDownloadPlanRecreatesOnlyLinksThatStayInside() async throws {
        let fs = makeServer()
        let destination = URL(fileURLWithPath: "/Users/demo/Downloads")
        let plan = try await TransferPlanner.downloads(of: [try await root(fs, "/site")], on: fs, to: destination)
        XCTAssertEqual(plan.items.map(\.local.path), [
            "/Users/demo/Downloads/site", "/Users/demo/Downloads/site/assets", "/Users/demo/Downloads/site/assets/app.js",
            "/Users/demo/Downloads/site/assets/img", "/Users/demo/Downloads/site/assets/img/logo.png",
            "/Users/demo/Downloads/site/assets/inside", "/Users/demo/Downloads/site/empty", "/Users/demo/Downloads/site/index.html",
        ])
        XCTAssertEqual(plan.items.first { $0.local.lastPathComponent == "inside" }?.kind, .symlink(target: "app.js"))
        XCTAssertEqual(plan.skipped, ["/site/outside"])
        XCTAssertEqual(plan.totalSize, 1400)
    }

    func testDownloadingALinkOnItsOwnFetchesItsTarget() async throws {
        let fs = makeServer()
        let plan = try await TransferPlanner.downloads(of: [try await root(fs, "/site/assets/inside")], on: fs, to: URL(fileURLWithPath: "/dl"))
        XCTAssertEqual(plan.items.map(\.kind), [.file])
        XCTAssertEqual(plan.items.first?.local.path, "/dl/inside")
    }

    func testHostileServerNamesCannotEscapeTheDestination() {
        let directory = URL(fileURLWithPath: "/Users/demo/Downloads")
        let base = RemotePath("/srv")
        XCTAssertEqual(TransferPlanner.localURL(for: RemotePath("/srv/a/b.txt"), under: base, in: directory)?.path, "/Users/demo/Downloads/a/b.txt")
        XCTAssertNil(TransferPlanner.localURL(for: RemotePath("/srv/../../.ssh/authorized_keys"), under: base, in: directory))
        XCTAssertNil(TransferPlanner.localURL(for: RemotePath("/srv/a/../b"), under: base, in: directory))
        XCTAssertNil(TransferPlanner.localURL(for: RemotePath("/elsewhere/x"), under: base, in: directory))
        XCTAssertFalse(TransferPlanner.isSafeName(".."))
        XCTAssertFalse(TransferPlanner.isSafeName("a/b"))
        XCTAssertTrue(TransferPlanner.isSafeName("..hidden"))
    }
}
