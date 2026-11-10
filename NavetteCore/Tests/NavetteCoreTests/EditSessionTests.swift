import XCTest
@testable import NavetteCore

final class EditSessionTests: XCTestCase {
    private let remote = RemoteVersion(size: 100, modified: Date(timeIntervalSince1970: 1_000))
    private let downloaded = LocalFileInfo(kind: .file, size: 100, modified: Date(timeIntervalSince1970: 2_000))

    private func session() -> EditSession {
        EditSession(remote: RemotePath("/srv/a.txt"), local: URL(fileURLWithPath: "/tmp/a.txt"), remoteVersion: remote, localInfo: downloaded)
    }

    func testAnUntouchedCopyIsNotSent() {
        var session = session()
        XCTAssertEqual(session.decide(local: downloaded, remote: remote), .nothing)
        XCTAssertFalse(session.hasUnsentChanges)
    }

    func testASaveIsSentWhenTheServerCopyIsUnchanged() {
        var session = session()
        let saved = LocalFileInfo(kind: .file, size: 120, modified: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(session.decide(local: saved, remote: remote), .upload)
        XCTAssertTrue(session.hasUnsentChanges)

        let uploaded = RemoteVersion(size: 120, modified: Date(timeIntervalSince1970: 3_005))
        session.didUpload(local: saved, remote: uploaded)
        XCTAssertFalse(session.hasUnsentChanges)
        XCTAssertEqual(session.decide(local: saved, remote: uploaded), .nothing, "the same save is not sent twice")

        let again = LocalFileInfo(kind: .file, size: 120, modified: Date(timeIntervalSince1970: 4_000))
        XCTAssertEqual(session.decide(local: again, remote: uploaded), .upload, "a save with the same size is still a save")
    }

    func testTheUserDecidesWhenTheServerCopyChanged() {
        var session = session()
        let saved = LocalFileInfo(kind: .file, size: 120, modified: Date(timeIntervalSince1970: 3_000))
        let changedElsewhere = RemoteVersion(size: 140, modified: Date(timeIntervalSince1970: 2_900))
        XCTAssertEqual(session.decide(local: saved, remote: changedElsewhere), .askBecauseRemoteChanged)
        XCTAssertEqual(session.decide(local: saved, remote: nil), .askBecauseRemoteChanged, "the remote file was deleted")
        XCTAssertTrue(session.hasUnsentChanges)
    }

    func testAMissingLocalFileDuringAnAtomicSaveIsIgnored() {
        var session = session()
        XCTAssertEqual(session.decide(local: nil, remote: remote), .nothing)
        XCTAssertEqual(session.decide(local: LocalFileInfo(kind: .directory, size: 0), remote: remote), .nothing)
        XCTAssertFalse(session.hasUnsentChanges)
    }

    func testFolderWatcherSeesASaveThroughRename() throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("a.txt")
        try Data("one".utf8).write(to: file)
        let changed = expectation(description: "the folder changed")
        changed.assertForOverFulfill = false
        let watcher = try XCTUnwrap(FolderWatcher(url: folder) { changed.fulfill() })
        // What editors do: write a sibling, then rename it over the file.
        try Data("two".utf8).write(to: file, options: .atomic)
        wait(for: [changed], timeout: 5)
        watcher.cancel()
        XCTAssertNil(FolderWatcher(url: folder.appendingPathComponent("missing")) {})
    }
}
