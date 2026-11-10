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

// MARK: - The askpass helper, end to end

extension IntegrationTests {
    private final class Responder: AskpassResponder, @unchecked Sendable {
        private let lock = NSLock()
        private var seen = [AskpassPrompt]()
        var passphrase: String? = "integration passphrase"
        var trustHost = true

        var prompts: [AskpassPrompt] { lock.withLock { seen } }

        func respond(to prompt: AskpassPrompt) async -> String? {
            lock.withLock { seen.append(prompt) }
            switch prompt {
            case .hostKey: return trustHost ? "yes" : "no"
            case .passphrase: return passphrase
            default: return nil
            }
        }
        func noticeBegan(_ message: String, id: UUID) {}
        func noticeEnded(id: UUID) {}
    }

    private func lockedConnection(_ server: AskpassServer, _ responder: Responder, runtime: URL, control: Bool = false) throws -> SSHConnection {
        guard let directory = environment["NAVETTE_IT_SFTP_DIR"], let port = environment["NAVETTE_IT_SFTP_PORT"].flatMap(Int.init),
              let helper = environment["NAVETTE_IT_ASKPASS_HELPER"] else {
            throw XCTSkip("Run `make build` then `make integration` to test the askpass helper.")
        }
        let token = server.register(responder)
        return SSHConnection(
            host: "127.0.0.1", port: port,
            controlPath: control ? runtime.appendingPathComponent("%C").path : nil,
            environment: server.environment(token: token, helperPath: helper),
            extraOptions: [
                "-F", "none", "-oUserKnownHostsFile=\(runtime.path)/known_hosts", "-oIdentityFile=\(directory)/locked_key",
                "-oIdentitiesOnly=yes", "-oIdentityAgent=none",
            ])
    }

    func testAskpassHelperAnswersTheHostKeyAndThePassphrase() async throws {
        let runtime = try shortTemporaryDirectory()
        let server = try AskpassServer(directory: runtime)
        defer { server.stop() }
        let responder = Responder()
        let fs = try await SFTPFileSystem.connect(try lockedConnection(server, responder, runtime: runtime))
        let home = try await fs.home()
        XCTAssertFalse(home.isRoot)
        await fs.disconnect()

        let prompts = responder.prompts
        XCTAssertEqual(prompts.count, 2)
        guard case .hostKey(let host, let keyType, let fingerprint) = prompts[0] else { return XCTFail("Expected a host key prompt, got \(prompts[0])") }
        XCTAssertTrue(host.contains("127.0.0.1"))
        XCTAssertEqual(keyType, "ED25519")
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        guard case .passphrase = prompts[1] else { return XCTFail("Expected a passphrase prompt, got \(prompts[1])") }
        let saved = try String(contentsOf: runtime.appendingPathComponent("known_hosts"), encoding: .utf8)
        XCTAssertTrue(saved.contains("127.0.0.1"), "ssh itself saved the trusted key")
    }

    func testRefusingTheHostKeyCancelsAndSavesNothing() async throws {
        let runtime = try shortTemporaryDirectory()
        let server = try AskpassServer(directory: runtime)
        defer { server.stop() }
        let responder = Responder()
        responder.trustHost = false
        do {
            _ = try await SFTPFileSystem.connect(try lockedConnection(server, responder, runtime: runtime))
            XCTFail("Expected a failure")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(responder.prompts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("known_hosts").path))
    }

    func testAWrongPassphraseIsAskedAgainThenRefused() async throws {
        let runtime = try shortTemporaryDirectory()
        let server = try AskpassServer(directory: runtime)
        defer { server.stop() }
        let responder = Responder()
        responder.passphrase = "wrong"
        do {
            _ = try await SFTPFileSystem.connect(try lockedConnection(server, responder, runtime: runtime))
            XCTFail("Expected a failure")
        } catch let error as RemoteError {
            guard case .authenticationFailed = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertEqual(responder.prompts.count, 4, "the host key, then the passphrase three times")
    }

    func testTheControlSocketOpensASecondChannelWithoutAskingAgain() async throws {
        let runtime = try shortTemporaryDirectory()
        let server = try AskpassServer(directory: runtime)
        defer { server.stop() }
        let responder = Responder()
        let first = try await SFTPFileSystem.connect(try lockedConnection(server, responder, runtime: runtime, control: true))
        XCTAssertEqual(responder.prompts.count, 2)
        let second = try await SFTPFileSystem.connect(try lockedConnection(server, responder, runtime: runtime, control: true))
        _ = try await second.home()
        XCTAssertEqual(responder.prompts.count, 2, "the second channel reused the login")
        await second.disconnect()
        await first.disconnect()
    }
}
