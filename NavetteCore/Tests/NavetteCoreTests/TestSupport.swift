import Foundation
import XCTest
@testable import NavetteCore

/// Names that must travel through every layer unchanged.
enum HostileNames {
    static let nfc = "caf\u{e9}.txt"
    static let nfd = "cafe\u{301}.txt"
    static let all: [String] = [
        "with space.txt", "quote\"double.txt", "quote'single.txt", "back\\slash.txt", "-rf", "--option=value",
        "$(echo x)", "`id`", "semi;colon", "🚀 rocket.txt", nfc, "star*.txt", "question?.txt", "tab\there", "new\nline",
        ".hidden", "percent%20.txt",
    ]
}

extension XCTestCase {
    /// A fresh temporary folder, removed when the test ends.
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navette-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

func readAll(_ fs: any RemoteFileSystem, _ path: RemotePath, offset: UInt64 = 0) async throws -> Data {
    let reader = try await fs.read(path, offset: offset)
    var data = Data()
    while let chunk = try await reader.next() { data.append(chunk) }
    await reader.close()
    return data
}

func writeAll(_ fs: any RemoteFileSystem, _ path: RemotePath, _ data: Data, offset: UInt64? = nil) async throws {
    let writer = try await fs.write(path, offset: offset)
    try await writer.write(data)
    try await writer.close()
}

func assertThrows<T>(_ expected: (RemoteError) -> Bool, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("Expected an error", file: file, line: line)
    } catch let error as RemoteError {
        XCTAssertTrue(expected(error), "Unexpected error \(error)", file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}

/// The behavior every driver must share. Run against the in-memory driver here and against real servers by the integration tests.
enum DriverContract {
    static func run(_ fs: any RemoteFileSystem, in base: RemotePath, file: StaticString = #filePath, line: UInt = #line) async throws {
        let caps = fs.capabilities

        // Folders and hostile names
        let dir = base.appending("contract dir")
        try await fs.makeDirectory(dir)
        await assertThrows({ if case .alreadyExists = $0 { true } else { false } }, file: file, line: line) { try await fs.makeDirectory(dir) }
        for name in HostileNames.all {
            try await writeAll(fs, dir.appending(name), Data(name.utf8))
        }
        let listed = try await fs.list(dir)
        XCTAssertEqual(Set(listed.map(\.path.nameBytes)), Set(HostileNames.all.map { Array($0.utf8) }), "names must round-trip byte for byte", file: file, line: line)
        XCTAssertTrue(listed.allSatisfy { $0.kind == .file }, file: file, line: line)
        for name in HostileNames.all {
            let data = try await readAll(fs, dir.appending(name))
            XCTAssertEqual(data, Data(name.utf8), file: file, line: line)
        }

        // Stat, sizes, offsets
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let target = dir.appending("data.bin")
        try await writeAll(fs, target, payload)
        let info = try await fs.stat(target)
        XCTAssertEqual(info.size, UInt64(payload.count), file: file, line: line)
        XCTAssertEqual(info.kind, .file, file: file, line: line)
        let all = try await readAll(fs, target)
        XCTAssertEqual(all, payload, file: file, line: line)
        if caps.resumeDownload {
            let tail = try await readAll(fs, target, offset: 150_000)
            XCTAssertEqual(tail, payload.suffix(50_000), file: file, line: line)
        }
        if caps.resumeUpload {
            try await writeAll(fs, target, payload.prefix(100_000))
            try await writeAll(fs, target, payload.suffix(100_000), offset: 100_000)
            let resumed = try await readAll(fs, target)
            XCTAssertEqual(resumed, payload, file: file, line: line)
        }
        try await writeAll(fs, dir.appending("empty"), Data())
        let empty = try await fs.stat(dir.appending("empty"))
        XCTAssertEqual(empty.size, 0, file: file, line: line)

        // Missing things
        await assertThrows({ if case .notFound = $0 { true } else { false } }, file: file, line: line) { try await fs.stat(dir.appending("missing")) }
        let missing = try await fs.statIfExists(dir.appending("missing"))
        XCTAssertNil(missing, file: file, line: line)

        // Rename
        let renamed = dir.appending("renamed.bin")
        try await fs.rename(target, to: renamed, overwrite: false)
        let gone = try await fs.statIfExists(target)
        XCTAssertNil(gone, file: file, line: line)
        try await writeAll(fs, target, Data("new".utf8))
        await assertThrows({ if case .alreadyExists = $0 { true } else { false } }, file: file, line: line) {
            try await fs.rename(target, to: renamed, overwrite: false)
        }
        try await fs.rename(target, to: renamed, overwrite: true)
        let replaced = try await readAll(fs, renamed)
        XCTAssertEqual(replaced, Data("new".utf8), file: file, line: line)

        // Permissions
        if caps.permissions {
            try await fs.setPermissions(0o600, of: renamed)
            let changed = try await fs.stat(renamed)
            XCTAssertEqual(changed.permissions.map { $0 & 0o777 }, 0o600, file: file, line: line)
        }

        // Removal
        await assertThrows({ if case .directoryNotEmpty = $0 { true } else { false } }, file: file, line: line) { try await fs.removeDirectory(dir) }
        for item in try await fs.list(dir) { try await fs.removeFile(item.path) }
        try await fs.removeDirectory(dir)
        let removed = try await fs.statIfExists(dir)
        XCTAssertNil(removed, file: file, line: line)
    }
}
