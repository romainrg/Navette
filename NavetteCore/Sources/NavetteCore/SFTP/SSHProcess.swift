import Foundation

/// Builds the argument array for the system `ssh`. Nothing here ever goes through a shell.
public enum SSHCommand {
    public static let executable = "/usr/bin/ssh"

    /// Arguments that open the SFTP subsystem on a host.
    /// The host always follows `--` and is validated, so it can never be read as an option.
    /// No option touches the user's trust settings (`StrictHostKeyChecking`, `UserKnownHostsFile`, identities).
    public static func sftpArguments(
        host: String, user: String? = nil, port: Int? = nil, controlPath: String? = nil, extraOptions: [String] = []
    ) throws -> [String] {
        guard ConnectionURL.isValidHost(host) else { throw RemoteError.server("Invalid host name") }
        var arguments = ["-T", "-x", "-a", "-oClearAllForwardings=yes"]
        if let controlPath {
            arguments += ["-oControlMaster=auto", "-oControlPath=\(controlPath)", "-oControlPersist=60"]
        }
        arguments += extraOptions
        if let user, !user.isEmpty {
            guard ConnectionURL.isValidUser(user) else { throw RemoteError.server("Invalid user name") }
            arguments += ["-l", user]
        }
        if let port {
            guard (1...65535).contains(port) else { throw RemoteError.server("Invalid port") }
            arguments += ["-p", String(port)]
        }
        return arguments + ["-s", "--", host, "sftp"]
    }

    /// Arguments that print the configuration `ssh` resolves for a host, without connecting.
    public static func resolveArguments(host: String, user: String? = nil, port: Int? = nil, extraOptions: [String] = []) throws -> [String] {
        guard ConnectionURL.isValidHost(host) else { throw RemoteError.server("Invalid host name") }
        var arguments = ["-G"] + extraOptions
        if let user, !user.isEmpty, ConnectionURL.isValidUser(user) { arguments += ["-l", user] }
        if let port, (1...65535).contains(port) { arguments += ["-p", String(port)] }
        return arguments + ["--", host]
    }
}

/// Turns what `ssh` printed before exiting into an error the app can explain.
public enum SSHFailure {
    public static func classify(stderr: String, host: String) -> RemoteError {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") && !$0.hasPrefix("debug") }
        let text = lines.joined(separator: "\n")

        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            var change = HostKeyChange(host: host)
            if let match = text.firstMatch(of: #/(SHA256:[A-Za-z0-9+/=]+)/#) { change.fingerprint = String(match.1) }
            if let match = text.firstMatch(of: #/Offending (\S+) key in (.+):(\d+)/#) {
                change.keyType = String(match.1)
                change.knownHostsFile = String(match.2)
                change.knownHostsLine = Int(match.3)
            }
            return .hostKeyChanged(change)
        }
        let last = lines.last ?? ""
        if text.contains("Host key verification failed") { return .cancelled }
        if let denied = lines.last(where: { $0.contains("Permission denied") || $0.contains("Too many authentication failures") }) {
            return .authenticationFailed(denied)
        }
        let unreachable = ["Could not resolve hostname", "Connection refused", "Operation timed out", "Connection timed out",
                           "No route to host", "Network is unreachable", "Connection closed by", "Connection reset by"]
        if let line = lines.last(where: { line in unreachable.contains { line.contains($0) } }) {
            return .unreachable(line)
        }
        if text.contains("subsystem request failed") { return .unsupported("The server does not offer SFTP.") }
        return .connectionLost(last.isEmpty ? "The connection was closed." : last)
    }
}

/// The stdin and stdout of an `ssh` process, as a transport for `SFTPClient`.
public final class SSHTransport: ByteTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let host: String
    private let lock = NSLock()
    private var stderrData = Data()
    private var finished = false

    public init(arguments: [String], environment: [String: String], host: String, executable: String = SSHCommand.executable) {
        self.host = host
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    /// What `ssh` printed so far, for the activity log. It never contains a secret: `ssh` does not echo them.
    public var diagnostics: String { lock.withLock { String(decoding: stderrData, as: UTF8.self) } }

    public func start(received: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable (RemoteError) -> Void) throws {
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock { if self.stderrData.count < 64 * 1024 { self.stderrData.append(data) } }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                received(data)
                return
            }
            handle.readabilityHandler = nil
            guard let self else { return }
            DispatchQueue.global().async {
                self.process.waitUntilExit()
                // Give the stderr handler a moment to drain what ssh wrote just before exiting.
                Thread.sleep(forTimeInterval: 0.05)
                let already = self.lock.withLock { () -> Bool in
                    defer { self.finished = true }
                    return self.finished
                }
                if !already { closed(SSHFailure.classify(stderr: self.diagnostics, host: self.host)) }
            }
        }
        try process.run()
    }

    public func send(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() {
        lock.withLock { finished = true }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
