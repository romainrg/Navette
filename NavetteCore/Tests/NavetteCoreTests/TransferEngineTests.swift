import XCTest
@testable import NavetteCore

final class TransferEngineTests: XCTestCase {
    private final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls = [URL]()
        var trashed: [URL] { lock.withLock { urls } }
        func trash(_ url: URL) throws {
            lock.withLock { urls.append(url) }
            try FileManager.default.removeItem(at: url)
        }
    }

    private var home: URL!
    private var trash: TrashLog!
    private var fs: InMemoryFileSystem!

    override func setUpWithError() throws {
        home = try temporaryDirectory()
        trash = TrashLog()
        fs = InMemoryFileSystem(chunkSize: 16 * 1024)
        fs.addDirectory(RemotePath("/dest"))
    }

    private func makeEngine(policy: ConflictPolicy = .overwrite, maxConcurrent: Int = 2, chunkSize: Int = 16 * 1024, files: (any LocalFiles)? = nil) -> TransferEngine {
        let trash = trash!
        return TransferEngine(files: files ?? DiskFiles(trash: { try trash.trash($0) }), maxConcurrent: maxConcurrent, policy: policy, chunkSize: chunkSize)
    }

    private func run(_ engine: TransferEngine, _ items: [TransferItem], on server: (any RemoteFileSystem)? = nil) async {
        let target = server ?? fs!
        await engine.enqueue(items, serverKey: "server", serverName: "Server", connect: { target })
        await engine.waitUntilIdle()
    }

    private func state(_ engine: TransferEngine, _ item: TransferItem) async -> TransferState? {
        await engine.snapshots().first { $0.id == item.id }?.state
    }

    private func payload(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }

    /// Creates a file whose name on disk is exactly `name`. Foundation would decompose it, so this goes through `open`.
    private func localFile(_ name: String, _ data: Data) throws -> URL {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let leaf = name.split(separator: "/").last.map(String.init) ?? name
        let path = url.deletingLastPathComponent().path + "/" + leaf
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        return url
    }

    private func upload(_ url: URL, to path: String = "/dest", group: UUID? = nil) -> TransferItem {
        TransferItem(direction: .upload, local: url, remote: RemotePath(path).appending(DiskFiles().exactName(of: url)), group: group)
    }

    /// The names in a local folder, byte for byte.
    private func storedNames(in directory: URL) throws -> [[UInt8]] {
        try DiskFiles().entries(of: directory).map(\.name)
    }

    private func download(_ path: String, group: UUID? = nil) -> TransferItem {
        let remote = RemotePath(path)
        return TransferItem(direction: .download, local: home.appendingPathComponent("downloads").appendingPathComponent(remote.name), remote: remote, group: group)
    }

    private var partials: [String] { fs.allPaths.map(\.display).filter { $0.hasSuffix(TransferNames.partialSuffix) } }

    private func localPartials() -> [String] {
        let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent).filter { $0.hasSuffix(TransferNames.partialSuffix) }
    }

    /// Waits for a condition on the queue, failing the test after two seconds.
    private func wait(_ engine: TransferEngine, until condition: ([TransferSnapshot]) -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition(await engine.snapshots()) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition never became true", file: file, line: line)
    }

    // MARK: - Uploads

    func testUploadGoesThroughAPartialFileThenARename() async throws {
        let data = payload(300_000)
        let item = upload(try localFile("a.bin", data))
        let engine = makeEngine()
        await run(engine, [item])

        let result = await state(engine, item)
        XCTAssertEqual(result, .finished)
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.bin")), data)
        XCTAssertEqual(partials, [])
        let log = fs.log
        let write = try XCTUnwrap(log.firstIndex(of: "write /dest/.a.bin.navette-part"))
        let rename = try XCTUnwrap(log.firstIndex(of: "rename /dest/.a.bin.navette-part"))
        XCTAssertLessThan(write, rename)
        XCTAssertFalse(log.contains("write /dest/a.bin"), "the target is never written directly")
        let snapshot = await engine.snapshots().first
        XCTAssertEqual(snapshot?.bytesDone, 300_000)
        XCTAssertEqual(snapshot?.fraction, 1)
    }

    func testHostileNamesTravelUnchanged() async throws {
        let engine = makeEngine()
        var items = [TransferItem]()
        for name in HostileNames.all {
            items.append(upload(try localFile("names/" + name, Data(name.utf8))))
        }
        await run(engine, items)
        for name in HostileNames.all {
            XCTAssertEqual(fs.contents(of: RemotePath("/dest").appending(name)), Data(name.utf8), name)
        }
        let remoteNames = try await fs.list(RemotePath("/dest")).map(\.path.nameBytes)
        XCTAssertEqual(Set(remoteNames), Set(HostileNames.all.map { Array($0.utf8) }))
        XCTAssertEqual(partials, [])
    }

    func testEmptyFiles() async throws {
        let engine = makeEngine()
        let up = upload(try localFile("empty.txt", Data()))
        fs.addFile(RemotePath("/dest/remote-empty.txt"))
        let down = download("/dest/remote-empty.txt")
        await run(engine, [up, down])
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/empty.txt")), Data())
        XCTAssertEqual(try Data(contentsOf: down.local), Data())
        let states = await engine.snapshots().map(\.state)
        XCTAssertEqual(states, [.finished, .finished])
        XCTAssertEqual(partials + localPartials(), [])
    }

    func testUploadCreatesMissingFolders() async throws {
        let engine = makeEngine()
        let item = upload(try localFile("a.txt", payload(10)), to: "/new/deep/folder")
        await run(engine, [item])
        XCTAssertEqual(fs.contents(of: RemotePath("/new/deep/folder/a.txt")), payload(10))
    }

    func testDirectoryAndSymlinkItems() async throws {
        let engine = makeEngine()
        fs.addFile(RemotePath("/dest/target.txt"), data: payload(5))
        let localDirectory = home.appendingPathComponent("downloads/tree/sub")
        let link = home.appendingPathComponent("downloads/tree/link")
        await run(engine, [
            TransferItem(direction: .upload, kind: .directory, local: home, remote: RemotePath("/dest/made/nested")),
            TransferItem(direction: .download, kind: .directory, local: localDirectory, remote: RemotePath("/dest")),
            TransferItem(direction: .download, kind: .symlink(target: "sub"), local: link, remote: RemotePath("/dest/x")),
        ])
        let made = try await fs.stat(RemotePath("/dest/made/nested"))
        XCTAssertEqual(made.kind, .directory)
        XCTAssertEqual(DiskFiles().info(localDirectory)?.kind, .directory)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "sub")
    }

    // MARK: - Conflicts

    func testConflictPolicies() async throws {
        let old = payload(1_000, seed: 9)
        let new = payload(5_000)

        for policy in [ConflictPolicy.skip, .overwrite, .rename, .resume] {
            fs.addFile(RemotePath("/dest/a.txt"), data: policy == .resume ? new.prefix(1_200) : old)
            let item = upload(try localFile("a.txt", new))
            let engine = makeEngine(policy: policy)
            await run(engine, [item])
            let result = await state(engine, item)
            switch policy {
            case .skip:
                XCTAssertEqual(result, .skipped)
                XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.txt")), old)
            case .overwrite:
                XCTAssertEqual(result, .finished)
                XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.txt")), new)
            case .rename:
                XCTAssertEqual(result, .finished)
                XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.txt")), old, "the existing file is untouched")
                XCTAssertEqual(fs.contents(of: RemotePath("/dest/a 2.txt")), new)
            case .resume:
                XCTAssertEqual(result, .finished)
                XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.txt")), new, "the missing tail was appended")
            case .ask:
                break
            }
            XCTAssertEqual(partials, [], "\(policy)")
            try await fs.removeFile(RemotePath("/dest/a.txt"))
        }
    }

    func testRenamePicksTheNextFreeNumber() async throws {
        fs.addFile(RemotePath("/dest/report.pdf")).addFile(RemotePath("/dest/report 2.pdf"))
        let engine = makeEngine(policy: .rename)
        await run(engine, [upload(try localFile("report.pdf", payload(3)))])
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/report 3.pdf")), payload(3))
        XCTAssertEqual(TransferNames.numbered(".bashrc", 2), ".bashrc 2")
        XCTAssertEqual(TransferNames.numbered("archive.tar.gz", 2), "archive.tar 2.gz")
        XCTAssertEqual(TransferNames.numbered("README", 4), "README 4")
    }

    func testAskingWithoutAHandlerNeverDestroysAnything() async throws {
        fs.addFile(RemotePath("/dest/a.txt"), data: payload(10, seed: 9))
        let item = upload(try localFile("a.txt", payload(20)))
        let engine = makeEngine(policy: .ask)
        await run(engine, [item])
        let result = await state(engine, item)
        XCTAssertEqual(result, .skipped)
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.txt")), payload(10, seed: 9))
    }

    func testApplyToAllAsksOnlyOncePerGroup() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var conflicts = [TransferConflict]()
        }
        let counter = Counter()
        let group = UUID()
        var items = [TransferItem]()
        for name in ["a.txt", "b.txt", "c.txt"] {
            fs.addFile(RemotePath("/dest/\(name)"), data: payload(10, seed: 9))
            items.append(upload(try localFile(name, payload(20)), group: group))
        }
        let engine = makeEngine(policy: .ask)
        await engine.setConflictHandler { conflict in
            counter.lock.withLock { counter.conflicts.append(conflict) }
            return ConflictAnswer(.overwrite, applyToAll: true)
        }
        await run(engine, items)
        XCTAssertEqual(counter.conflicts.count, 1)
        XCTAssertEqual(counter.conflicts.first?.existingSize, 10)
        XCTAssertEqual(counter.conflicts.first?.incomingSize, 20)
        XCTAssertEqual(counter.conflicts.first?.canResume, true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            XCTAssertEqual(fs.contents(of: RemotePath("/dest/\(name)")), payload(20))
        }
    }

    func testCancelAnswerLeavesEverythingInPlace() async throws {
        fs.addFile(RemotePath("/dest/a.txt"), data: payload(10, seed: 9))
        let item = upload(try localFile("a.txt", payload(20)))
        let engine = makeEngine(policy: .ask)
        await engine.setConflictHandler { _ in ConflictAnswer(.cancel) }
        await run(engine, [item])
        let result = await state(engine, item)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.txt")), payload(10, seed: 9))
    }

    func testAFolderInTheWayIsAnError() async throws {
        fs.addDirectory(RemotePath("/dest/a.txt"))
        let item = upload(try localFile("a.txt", payload(20)))
        let engine = makeEngine()
        await run(engine, [item])
        let result = await state(engine, item)
        XCTAssertEqual(result, .failed(.alreadyExists("/dest/a.txt")))
    }

    // MARK: - Interruption, resume, cancel

    func testInterruptedUploadResumesFromItsPartialFile() async throws {
        let data = payload(300_000)
        let item = upload(try localFile("a.bin", data))
        let partial = RemotePath("/dest/.a.bin.navette-part")
        fs.faults.failWriteAfter[partial] = 100_000
        let engine = makeEngine()
        await run(engine, [item])
        var result = await state(engine, item)
        XCTAssertEqual(result, .failed(.connectionLost("Write failed")))
        XCTAssertEqual(fs.contents(of: partial)?.count, 100_000, "the partial file is kept for the retry")
        XCTAssertNil(fs.contents(of: RemotePath("/dest/a.bin")), "the target was never touched")

        // A restart from zero would need 300 000 bytes and hit this limit; a resume needs 200 000.
        fs.faults.failWriteAfter[partial] = 250_000
        await engine.resume(item.id)
        await engine.waitUntilIdle()
        result = await state(engine, item)
        XCTAssertEqual(result, .finished)
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.bin")), data)
        XCTAssertEqual(partials, [])
    }

    func testResumeStartsOverWhenTheSourceChanged() async throws {
        let item = upload(try localFile("a.bin", payload(300_000)))
        let partial = RemotePath("/dest/.a.bin.navette-part")
        fs.faults.failWriteAfter[partial] = 100_000
        let engine = makeEngine()
        await run(engine, [item])

        let changed = payload(300_000, seed: 42)
        try changed.write(to: item.local)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: item.local.path)
        fs.faults = .init()
        await engine.resume(item.id)
        await engine.waitUntilIdle()
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.bin")), changed, "no byte of the stale partial file survives")
    }

    func testCancelLeavesNoPartialFile() async throws {
        fs.faults.latency = .milliseconds(5)
        let item = upload(try localFile("a.bin", payload(400_000)))
        let engine = makeEngine()
        await engine.enqueue([item], serverKey: "server", serverName: "Server", connect: { [fs] in fs! })
        await wait(engine) { $0.first?.bytesDone ?? 0 > 0 }
        await engine.cancel(item.id)
        await wait(engine) { $0.first?.state == .cancelled }
        XCTAssertEqual(partials, [])
        XCTAssertNil(fs.contents(of: RemotePath("/dest/a.bin")))
    }

    func testPauseKeepsThePartialFileAndResumeFinishes() async throws {
        fs.faults.latency = .milliseconds(5)
        let data = payload(400_000)
        let item = upload(try localFile("a.bin", data))
        let engine = makeEngine()
        await engine.enqueue([item], serverKey: "server", serverName: "Server", connect: { [fs] in fs! })
        await wait(engine) { $0.first?.bytesDone ?? 0 > 0 }
        await engine.pause(item.id)
        await wait(engine) { $0.first?.state == .paused }
        let kept = fs.contents(of: RemotePath("/dest/.a.bin.navette-part"))?.count ?? 0
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, data.count)

        fs.faults = .init()
        await engine.resume(item.id)
        await engine.waitUntilIdle()
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.bin")), data)
        XCTAssertEqual(partials, [])
    }

    func testRemovingAFailedTransferCleansItsPartialFile() async throws {
        let item = upload(try localFile("a.bin", payload(300_000)))
        fs.faults.failWriteAfter[RemotePath("/dest/.a.bin.navette-part")] = 100_000
        let engine = makeEngine()
        await run(engine, [item])
        XCTAssertEqual(partials.count, 1)
        fs.faults = .init()
        await engine.remove([item.id])
        XCTAssertEqual(partials, [])
        let remaining = await engine.snapshots()
        XCTAssertEqual(remaining, [])
    }

    func testFailuresCarryTheServerError() async throws {
        let item = upload(try localFile("a.txt", payload(10)))
        fs.faults.denied = [RemotePath("/dest/.a.txt.navette-part")]
        let engine = makeEngine()
        await run(engine, [item])
        let result = await state(engine, item)
        XCTAssertEqual(result, .failed(.permissionDenied("/dest/.a.txt.navette-part")))
    }

    // MARK: - Downloads

    func testDownloadGoesThroughAPartialFile() async throws {
        let data = payload(300_000)
        fs.addFile(RemotePath("/dest/a.bin"), data: data)
        let item = download("/dest/a.bin")
        let engine = makeEngine()
        await run(engine, [item])
        XCTAssertEqual(try Data(contentsOf: item.local), data)
        XCTAssertEqual(localPartials(), [])
        XCTAssertEqual(trash.trashed, [])
    }

    func testAReplacedLocalFileGoesToTheTrash() async throws {
        fs.addFile(RemotePath("/dest/a.bin"), data: payload(1_000))
        let item = download("/dest/a.bin")
        try FileManager.default.createDirectory(at: item.local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload(50, seed: 9).write(to: item.local)
        let engine = makeEngine(policy: .overwrite)
        await run(engine, [item])
        XCTAssertEqual(trash.trashed.map(\.lastPathComponent), ["a.bin"])
        XCTAssertEqual(try Data(contentsOf: item.local), payload(1_000))
    }

    func testInterruptedDownloadResumesAndCancelRemovesThePartialFile() async throws {
        let data = payload(300_000)
        let path = RemotePath("/dest/a.bin")
        fs.addFile(path, data: data)
        let item = download("/dest/a.bin")
        fs.faults.failReadAfter[path] = 120_000
        let engine = makeEngine()
        await run(engine, [item])
        let result = await state(engine, item)
        XCTAssertEqual(result, .failed(.connectionLost("Read failed")))
        XCTAssertEqual(localPartials(), ["a.bin.navette-part"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.local.path))

        // A restart from zero would hit the limit again; a resume only needs the remaining 180 000 bytes.
        fs.faults.failReadAfter[path] = 200_000
        await engine.resume(item.id)
        await engine.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: item.local), data)
        XCTAssertEqual(localPartials(), [])

        let second = download("/dest/a.bin")
        try FileManager.default.removeItem(at: item.local)
        fs.faults.failReadAfter[path] = 50_000
        await run(engine, [second])
        XCTAssertEqual(localPartials(), ["a.bin.navette-part"])
        await engine.cancel(second.id)
        XCTAssertEqual(localPartials(), [])
        XCTAssertEqual(trash.trashed, [], "Navette's own partial files are removed, not trashed")
    }

    func testDownloadConflictResumeAppendsTheMissingTail() async throws {
        let data = payload(10_000)
        fs.addFile(RemotePath("/dest/a.bin"), data: data)
        let item = download("/dest/a.bin")
        try FileManager.default.createDirectory(at: item.local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(4_000).write(to: item.local)
        let engine = makeEngine(policy: .resume)
        await run(engine, [item])
        XCTAssertEqual(try Data(contentsOf: item.local), data)
        XCTAssertEqual(trash.trashed, [])
    }

    // MARK: - Size, limits

    func testFilesLargerThanFourGigabytes() async throws {
        let size: UInt64 = (5 << 30) + 123
        let chunk = 8 << 20
        let big = InMemoryFileSystem(chunkSize: chunk, storesContent: false)
        big.addDirectory(RemotePath("/dest"))
        let mac = SimulatedFiles()
        let local = URL(fileURLWithPath: "/Users/demo/big.img")
        mac.add(local, size: size)

        let engine = makeEngine(chunkSize: chunk, files: mac)
        let up = TransferItem(direction: .upload, local: local, remote: RemotePath("/dest/big.img"))
        await run(engine, [up], on: big)
        let uploaded = try await big.stat(RemotePath("/dest/big.img")).size
        XCTAssertEqual(uploaded, size)

        let back = URL(fileURLWithPath: "/Users/demo/Downloads/big.img")
        let down = TransferItem(direction: .download, local: back, remote: RemotePath("/dest/big.img"))
        await run(engine, [down], on: big)
        XCTAssertEqual(mac.info(back)?.size, size)
        let states = await engine.snapshots().map(\.state)
        XCTAssertEqual(states, [.finished, .finished])
        XCTAssertFalse(mac.paths.contains { $0.hasSuffix(TransferNames.partialSuffix) })
    }

    func testSparseFileOnDiskLargerThanFourGigabytes() async throws {
        let size: UInt64 = (4 << 30) + 4096
        let url = home.appendingPathComponent("sparse.img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()

        let chunk = 16 << 20
        let big = InMemoryFileSystem(chunkSize: chunk, storesContent: false)
        big.addDirectory(RemotePath("/dest"))
        let engine = makeEngine(chunkSize: chunk)
        await run(engine, [upload(url)], on: big)
        let uploaded = try await big.stat(RemotePath("/dest/sparse.img")).size
        XCTAssertEqual(uploaded, size)
    }

    func testConcurrencyLimitPerServer() async throws {
        final class Peak: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
        }
        let peak = Peak()
        fs.faults.latency = .milliseconds(3)
        var items = [TransferItem]()
        for index in 0..<6 { items.append(upload(try localFile("f\(index).bin", payload(40_000)))) }
        let engine = makeEngine(maxConcurrent: 2)
        await engine.setChangeHandler { snapshots in
            let running = snapshots.filter { $0.state == .running }.count
            peak.lock.withLock { peak.value = max(peak.value, running) }
        }
        await run(engine, items)
        XCTAssertEqual(peak.value, 2)
        let states = await engine.snapshots().map(\.state)
        XCTAssertEqual(states, Array(repeating: .finished, count: 6))
    }

    func testRateLimit() async throws {
        let item = upload(try localFile("a.bin", payload(300_000)))
        let engine = makeEngine(chunkSize: 50_000)
        await engine.setRateLimit(bytesPerSecond: 200_000)
        let start = ContinuousClock.now
        await run(engine, [item])
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThan(elapsed, .milliseconds(1_000), "300 kB at 200 kB/s cannot take less than a second")
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/a.bin"))?.count, 300_000)
    }

    func testPartialNames() {
        XCTAssertEqual(TransferNames.remotePartial(for: RemotePath("/a/b.txt")).display, "/a/.b.txt.navette-part")
        let long = String(repeating: "x", count: 250)
        let partial = TransferNames.remotePartial(for: RemotePath("/a").appending(long))
        XCTAssertLessThanOrEqual(partial.nameBytes.count, 255)
        XCTAssertTrue(partial.name.hasSuffix(TransferNames.partialSuffix))
        XCTAssertEqual(partial.parent.display, "/a")
        XCTAssertEqual(TransferNames.localPartial(for: URL(fileURLWithPath: "/tmp/a.txt")).lastPathComponent, "a.txt.navette-part")
    }
}

// MARK: - Unicode normalization

extension TransferEngineTests {
    func testUploadKeepsTheNormalizationFormStoredOnDisk() async throws {
        let composed = try localFile("composed/" + HostileNames.nfc, Data("c".utf8))
        let decomposed = try localFile("decomposed/" + HostileNames.nfd, Data("d".utf8))
        XCTAssertEqual(DiskFiles().exactName(of: composed), Array(HostileNames.nfc.utf8), "the disk keeps what was written, Foundation hides it")
        XCTAssertEqual(DiskFiles().exactName(of: decomposed), Array(HostileNames.nfd.utf8))

        let plan = try TransferPlanner.uploads(of: [composed.deletingLastPathComponent(), decomposed.deletingLastPathComponent()], to: RemotePath("/dest"), files: DiskFiles())
        let engine = makeEngine()
        await run(engine, plan.items)
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/composed").appending(HostileNames.nfc)), Data("c".utf8))
        XCTAssertEqual(fs.contents(of: RemotePath("/dest/decomposed").appending(HostileNames.nfd)), Data("d".utf8))
        XCTAssertNil(fs.contents(of: RemotePath("/dest/composed").appending(HostileNames.nfd)), "no name was rewritten on its way to the server")
    }

    func testUploadRecognizesTheSameNameInAnotherNormalizationForm() async throws {
        // The server has the composed spelling; the Mac sends the decomposed one.
        fs.addFile(RemotePath("/dest").appending(HostileNames.nfc), data: Data("old".utf8))
        let item = upload(try localFile(HostileNames.nfd, Data("new".utf8)))
        XCTAssertEqual(item.remote.nameBytes, Array(HostileNames.nfd.utf8))

        let skipping = makeEngine(policy: .skip)
        await run(skipping, [item])
        let skipped = await state(skipping, item)
        XCTAssertEqual(skipped, .skipped, "it is a conflict, not a new file")

        let overwriting = makeEngine(policy: .overwrite)
        await run(overwriting, [item])
        let names = try await fs.list(RemotePath("/dest")).map(\.path.nameBytes)
        XCTAssertEqual(names, [Array(HostileNames.nfc.utf8)], "no twin was created and the server's spelling was kept")
        XCTAssertEqual(fs.contents(of: RemotePath("/dest").appending(HostileNames.nfc)), Data("new".utf8))
    }

    func testDownloadKeepsTheServersSpelling() async throws {
        fs.addFile(RemotePath("/dest/composed").appending(HostileNames.nfc), data: Data("c".utf8))
        fs.addFile(RemotePath("/dest/decomposed").appending(HostileNames.nfd), data: Data("d".utf8))
        fs.addDirectory(RemotePath("/dest").appending("dossier-" + HostileNames.nfc))
        let destination = home.appendingPathComponent("downloads")
        let roots = try await fs.list(RemotePath("/dest"))
        let plan = try await TransferPlanner.downloads(of: roots, on: fs, to: destination)
        let engine = makeEngine()
        await run(engine, plan.items)

        XCTAssertEqual(try storedNames(in: destination.appendingPathComponent("composed")), [Array(HostileNames.nfc.utf8)])
        XCTAssertEqual(try storedNames(in: destination.appendingPathComponent("decomposed")), [Array(HostileNames.nfd.utf8)])
        XCTAssertTrue(try storedNames(in: destination).contains(Array(("dossier-" + HostileNames.nfc).utf8)))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("composed/" + HostileNames.nfc)), Data("c".utf8))
    }
}
