import XCTest
@testable import NavetteCore

final class SSHTests: XCTestCase {
    // MARK: - Arguments

    func testSFTPArguments() throws {
        XCTAssertEqual(
            try SSHCommand.sftpArguments(host: "staging"),
            ["-T", "-x", "-a", "-oClearAllForwardings=yes", "-s", "--", "staging", "sftp"])
        XCTAssertEqual(
            try SSHCommand.sftpArguments(host: "example.org", user: "deploy", port: 2222, controlPath: "/tmp/navette-501/%C"),
            ["-T", "-x", "-a", "-oClearAllForwardings=yes", "-oControlMaster=auto", "-oControlPath=/tmp/navette-501/%C",
             "-oControlPersist=60", "-l", "deploy", "-p", "2222", "-s", "--", "example.org", "sftp"])
    }

    func testTheHostAlwaysFollowsTheSeparator() throws {
        let arguments = try SSHCommand.sftpArguments(host: "h", user: "u", port: 22)
        let separator = try XCTUnwrap(arguments.firstIndex(of: "--"))
        XCTAssertEqual(arguments[separator + 1], "h")
        XCTAssertEqual(arguments.last, "sftp")
    }

    func testHostileHostsAndUsersAreRefused() {
        for host in ["-oProxyCommand=id", "", "a b", "a;b", "$(id)", "a\nb", "`id`"] {
            XCTAssertThrowsError(try SSHCommand.sftpArguments(host: host), host)
            XCTAssertThrowsError(try SSHCommand.resolveArguments(host: host), host)
        }
        XCTAssertThrowsError(try SSHCommand.sftpArguments(host: "h", user: "-oProxyCommand=id"))
        XCTAssertThrowsError(try SSHCommand.sftpArguments(host: "h", port: 70000))
        XCTAssertThrowsError(try SSHCommand.sftpArguments(host: "h", port: 0))
    }

    func testNoArgumentTouchesTrustSettings() throws {
        let arguments = try SSHCommand.sftpArguments(host: "h", user: "u", port: 22, controlPath: "/tmp/x/%C").joined(separator: " ")
        for forbidden in ["StrictHostKeyChecking", "UserKnownHostsFile", "IdentityFile", "BatchMode", "GlobalKnownHostsFile"] {
            XCTAssertFalse(arguments.contains(forbidden), forbidden)
        }
    }

    func testResolveArguments() throws {
        XCTAssertEqual(try SSHCommand.resolveArguments(host: "h", user: "u", port: 2200), ["-G", "-l", "u", "-p", "2200", "--", "h"])
    }

    // MARK: - Failures, on the output recorded by the spike

    func testChangedHostKey() {
        let stderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Someone could be eavesdropping on you right now (man-in-the-middle attack)!
        It is also possible that a host key has just been changed.
        The fingerprint for the ED25519 key sent by the remote host is
        SHA256:KFrPEakk+y2tO+LkWONAIisPSUAsFuQlo4soX/FTOc4.
        Please contact your system administrator.
        Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
        Offending ED25519 key in /Users/me/.ssh/known_hosts:12
        Host key for [127.0.0.1]:22222 has changed and you have requested strict checking.
        Host key verification failed.
        """
        XCTAssertEqual(
            SSHFailure.classify(stderr: stderr, host: "example.org"),
            .hostKeyChanged(HostKeyChange(
                host: "example.org", keyType: "ED25519", fingerprint: "SHA256:KFrPEakk+y2tO+LkWONAIisPSUAsFuQlo4soX/FTOc4",
                knownHostsFile: "/Users/me/.ssh/known_hosts", knownHostsLine: 12)))
    }

    func testOtherFailures() {
        XCTAssertEqual(SSHFailure.classify(stderr: "Host key verification failed.\n", host: "h"), .cancelled)
        XCTAssertEqual(
            SSHFailure.classify(stderr: "Warning: Permanently added 'h' (ED25519) to the list of known hosts.\nme@h: Permission denied (publickey).\n", host: "h"),
            .authenticationFailed("me@h: Permission denied (publickey)."))
        XCTAssertEqual(
            SSHFailure.classify(stderr: "ssh: connect to host 127.0.0.1 port 22229: Connection refused\n", host: "h"),
            .unreachable("ssh: connect to host 127.0.0.1 port 22229: Connection refused"))
        XCTAssertEqual(
            SSHFailure.classify(stderr: "ssh: Could not resolve hostname nope.invalid: nodename nor servname provided, or not known\n", host: "h"),
            .unreachable("ssh: Could not resolve hostname nope.invalid: nodename nor servname provided, or not known"))
        XCTAssertEqual(SSHFailure.classify(stderr: "subsystem request failed on channel 0\n", host: "h"), .unsupported("The server does not offer SFTP."))
        XCTAssertEqual(SSHFailure.classify(stderr: "", host: "h"), .connectionLost("The connection was closed."))
        XCTAssertEqual(SSHFailure.classify(stderr: "client_loop: send disconnect: Broken pipe\n", host: "h"), .connectionLost("client_loop: send disconnect: Broken pipe"))
    }

    // MARK: - ssh -G

    func testParsesResolvedConfig() {
        let output = """
        host staging
        user deploy
        hostname staging.internal.example.org
        port 2222
        addressfamily any
        controlmaster false
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/work_key
        proxyjump bastion.example.org
        identityagent ~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
        controlpersist no
        """
        let config = ResolvedSSHConfig.parse(output)
        XCTAssertEqual(config.hostName, "staging.internal.example.org")
        XCTAssertEqual(config.user, "deploy")
        XCTAssertEqual(config.port, 2222)
        XCTAssertEqual(config.identityFiles, ["~/.ssh/id_ed25519", "~/.ssh/work_key"])
        XCTAssertEqual(config.proxyJump, "bastion.example.org")
        XCTAssertEqual(config.identityAgent, "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
        XCTAssertFalse(config.usesControlMaster)

        XCTAssertTrue(ResolvedSSHConfig.parse("controlmaster auto\ncontrolpath /Users/me/.ssh/cm-%C\n").usesControlMaster)
        XCTAssertNil(ResolvedSSHConfig.parse("proxyjump none\n").proxyJump)
    }

    func testExistingIdentityFiles() throws {
        let home = try temporaryDirectory()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent(".ssh/id_ed25519"))
        var config = ResolvedSSHConfig()
        config.identityFiles = ["~/.ssh/id_rsa", "~/.ssh/id_ed25519", "/nonexistent/key"]
        XCTAssertEqual(config.existingIdentityFiles(home: home), ["~/.ssh/id_ed25519"])
    }

    // MARK: - Askpass prompts, as recorded by the spike

    func testClassifiesHostKeyPrompt() {
        let text = """
        The authenticity of host '[127.0.0.1]:22222 ([127.0.0.1]:22222)' can't be established.
        ED25519 key fingerprint is: SHA256:KFrPEakk+y2tO+LkWONAIisPSUAsFuQlo4soX/FTOc4
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        XCTAssertEqual(
            AskpassPrompt.classify(hint: "", text: text),
            .hostKey(host: "[127.0.0.1]:22222 ([127.0.0.1]:22222)", keyType: "ED25519", fingerprint: "SHA256:KFrPEakk+y2tO+LkWONAIisPSUAsFuQlo4soX/FTOc4"))
        let older = "The authenticity of host 'example.org (192.0.2.1)' can't be established.\nRSA key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no)? "
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: older), .hostKey(host: "example.org (192.0.2.1)", keyType: "RSA", fingerprint: "SHA256:abc"))
    }

    func testClassifiesSecrets() {
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "), .passphrase(keyPath: "/Users/me/.ssh/id_ed25519"))
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "deploy@example.org's password: "), .password(account: "deploy@example.org"))
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "(deploy@example.org) Password: "), .password(account: "deploy@example.org"))
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "Password:"), .password(account: ""))
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "(me@host) Verification code: "), .oneTimeCode(message: "(me@host) Verification code:"))
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "Duo two-factor login for me\nPasscode or option (1-2): "), .oneTimeCode(message: "Duo two-factor login for me\nPasscode or option (1-2):"))
        XCTAssertEqual(AskpassPrompt.classify(hint: "", text: "Something new: "), .other(message: "Something new:"))
    }

    func testClassifiesHints() {
        XCTAssertEqual(AskpassPrompt.classify(hint: "none", text: "Confirm user presence for key ED25519-SK SHA256:abc"), .notice(message: "Confirm user presence for key ED25519-SK SHA256:abc"))
        XCTAssertEqual(AskpassPrompt.classify(hint: "confirm", text: "Allow use of key id_ed25519?"), .confirm(message: "Allow use of key id_ed25519?"))
        XCTAssertTrue(AskpassPrompt.password(account: "").canBeRemembered)
        XCTAssertFalse(AskpassPrompt.oneTimeCode(message: "").canBeRemembered)
        XCTAssertFalse(AskpassPrompt.hostKey(host: "", keyType: "", fingerprint: "").canBeRemembered)
    }

    // MARK: - Askpass server

    private final class Responder: AskpassResponder, @unchecked Sendable {
        var prompts = [AskpassPrompt]()
        var answer: String?
        func respond(to prompt: AskpassPrompt) async -> String? {
            prompts.append(prompt)
            return answer
        }
        func noticeBegan(_ message: String, id: UUID) {}
        func noticeEnded(id: UUID) {}
    }

    /// Plays the helper: connects, sends one question, returns the raw reply.
    private func ask(_ server: AskpassServer, token: String, hint: String, prompt: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in server.socketPath.utf8.enumerated() { raw[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let message = Array("\(token)\n\(hint)\n\(prompt)".utf8)
        _ = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        var reply = [UInt8](), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: reply, as: UTF8.self)
    }

    func testAskpassServerRoutesByToken() throws {
        let server = try AskpassServer(directory: try shortTemporaryDirectory())
        defer { server.stop() }
        let responder = Responder()
        responder.answer = "s3cret with spaces"
        let token = server.register(responder)

        XCTAssertEqual(ask(server, token: token, hint: "", prompt: "me@h's password: "), "0s3cret with spaces")
        XCTAssertEqual(responder.prompts, [.password(account: "me@h")])

        responder.answer = nil
        XCTAssertEqual(ask(server, token: token, hint: "", prompt: "me@h's password: "), "1", "nil cancels")

        XCTAssertEqual(ask(server, token: "wrong-token", hint: "", prompt: "me@h's password: "), "1", "unknown tokens are refused")
        server.unregister(token)
        XCTAssertEqual(ask(server, token: token, hint: "", prompt: "x"), "1")
        XCTAssertEqual(responder.prompts.count, 2)

        let environment = server.environment(token: token, helperPath: "/Applications/Navette.app/Contents/MacOS/navette-askpass")
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment["SSH_ASKPASS"], "/Applications/Navette.app/Contents/MacOS/navette-askpass")
        XCTAssertEqual(environment[AskpassServer.socketVariable], server.socketPath)
    }

    func testAskpassSocketIsPrivate() throws {
        let server = try AskpassServer(directory: try shortTemporaryDirectory())
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: server.socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRuntimeDirectoryIsPrivate() throws {
        let base = try temporaryDirectory()
        let url = try XCTUnwrap(RuntimeDirectory.url(base: base.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let other = try temporaryDirectory()
        let loose = other.appendingPathComponent("navette-\(getuid())")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        XCTAssertNil(RuntimeDirectory.url(base: other.path), "a folder others can write to is refused")
    }
}
