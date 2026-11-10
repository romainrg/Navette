import XCTest
@testable import NavetteCore

/// Runs against the local development servers started by `make integration` (scripts/integration.sh).
/// Skipped everywhere else, including `make test` and CI.
final class IntegrationTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func sftp() async throws -> (fs: SFTPFileSystem, base: RemotePath) {
        guard let directory = environment["NAVETTE_IT_SFTP_DIR"], let port = environment["NAVETTE_IT_SFTP_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Run `make integration` to start the local SFTP server.")
        }
        let connection = SSHConnection(
            host: "127.0.0.1", port: port,
            extraOptions: [
                "-F", "none", "-oUserKnownHostsFile=\(directory)/known_hosts", "-oIdentityFile=\(directory)/client_key",
                "-oIdentitiesOnly=yes", "-oIdentityAgent=none", "-oBatchMode=yes",
            ])
        let fs = try await SFTPFileSystem.connect(connection)
        let base = RemotePath(directory).appending("root").appending("run-\(UUID().uuidString)")
        try await fs.makeDirectory(base)
        return (fs, base)
    }

    func testSFTPDriverContract() async throws {
        let (fs, base) = try await sftp()
        try await DriverContract.run(fs, in: base)
        try await fs.removeDirectory(base)
        await fs.disconnect()
    }

    func testSFTPHomeSymlinksAndOwners() async throws {
        let (fs, base) = try await sftp()
        let home = try await fs.home()
        XCTAssertEqual(home.display, FileManager.default.homeDirectoryForCurrentUser.path)

        try await writeAll(fs, base.appending("target.txt"), Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: base.appending("link").display, withDestinationPath: "target.txt")
        let items = try await fs.list(base)
        let link = try XCTUnwrap(items.first { $0.name == "link" })
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertEqual(link.linkTarget, "target.txt")
        let file = try XCTUnwrap(items.first { $0.name == "target.txt" })
        XCTAssertEqual(file.owner, NSUserName())
        XCTAssertNotNil(file.modified)
        try await fs.removeFile(base.appending("link"))
        try await fs.removeFile(base.appending("target.txt"))
        try await fs.removeDirectory(base)
        await fs.disconnect()
    }

    func testSFTPLargeFileRoundTripIsPipelinedAndExact() async throws {
        let (fs, base) = try await sftp()
        // 40 MiB of non-repeating data: enough for several windows of pipelined requests.
        var payload = Data(count: 40 << 20)
        payload.withUnsafeMutableBytes { raw in
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in stride(from: 0, to: raw.count, by: 8) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                raw.storeBytes(of: state, toByteOffset: index, as: UInt64.self)
            }
        }
        let path = base.appending("large.bin")
        let writer = try await fs.write(path, offset: nil)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 1_000_003, payload.count)
            try await writer.write(payload.subdata(in: offset..<end))
            offset = end
        }
        try await writer.close()
        let size = try await fs.stat(path).size
        XCTAssertEqual(size, UInt64(payload.count))
        let back = try await readAll(fs, path)
        XCTAssertEqual(back, payload)
        let tail = try await readAll(fs, path, offset: UInt64(payload.count - 12_345))
        XCTAssertEqual(tail, payload.suffix(12_345))
        try await fs.removeFile(path)
        try await fs.removeDirectory(base)
        await fs.disconnect()
    }

    func testSFTPFailuresAreExplained() async throws {
        guard let directory = environment["NAVETTE_IT_SFTP_DIR"] else { throw XCTSkip("Run `make integration`.") }
        let options = ["-F", "none", "-oUserKnownHostsFile=\(directory)/known_hosts", "-oBatchMode=yes", "-oConnectTimeout=3"]
        do {
            _ = try await SFTPFileSystem.connect(SSHConnection(host: "127.0.0.1", port: 1, extraOptions: options))
            XCTFail("Expected a failure")
        } catch RemoteError.unreachable(let message) {
            XCTAssertTrue(message.contains("Connection refused"), message)
        }
    }

    func testSSHConfigResolverRunsTheSystemSSH() async throws {
        guard environment["NAVETTE_IT_SFTP_DIR"] != nil else { throw XCTSkip("Run `make integration`.") }
        let config = await SSHConfigResolver.resolve(host: "example.org", user: "someone", port: 2200, extraOptions: ["-F", "none"])
        XCTAssertEqual(config?.hostName, "example.org")
        XCTAssertEqual(config?.user, "someone")
        XCTAssertEqual(config?.port, 2200)
    }
}
