import Foundation

/// What `ssh` is asking through the askpass helper.
public enum AskpassPrompt: Equatable, Sendable {
    /// A host seen for the first time. The answer is "yes" or "no".
    case hostKey(host: String, keyType: String, fingerprint: String)
    case passphrase(keyPath: String)
    /// `account` is "user@host" when `ssh` says it.
    case password(account: String)
    case oneTimeCode(message: String)
    /// A yes/no question (`SSH_ASKPASS_PROMPT=confirm`).
    case confirm(message: String)
    /// Information that needs no answer, such as "touch your security key" (`SSH_ASKPASS_PROMPT=none`).
    case notice(message: String)
    /// Anything unrecognized: shown as is, answered as a secret.
    case other(message: String)

    public static func classify(hint: String, text: String) -> AskpassPrompt {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if hint == "none" { return .notice(message: message) }
        if lower.contains("continue connecting") {
            let host = message.firstMatch(of: #/authenticity of host '([^']+)'/#).map { String($0.1) } ?? ""
            let key = message.firstMatch(of: #/(\S+) key fingerprint is:? (\S+)/#)
            var fingerprint = key.map { String($0.2) } ?? ""
            if fingerprint.hasSuffix(".") { fingerprint.removeLast() }
            return .hostKey(host: host, keyType: key.map { String($0.1) } ?? "", fingerprint: fingerprint)
        }
        if hint == "confirm" { return .confirm(message: message) }
        if lower.contains("passphrase") {
            let path = message.firstMatch(of: #/'(.+)'/#).map { String($0.1) } ?? ""
            return .passphrase(keyPath: path)
        }
        if let match = message.firstMatch(of: #/^(.+)'s password:$/#.ignoresCase()) {
            return .password(account: String(match.1))
        }
        if ["verification code", "one-time", "otp", "passcode", "authenticator", "duo ", "token"].contains(where: lower.contains) {
            return .oneTimeCode(message: message)
        }
        if lower.contains("password") {
            let account = message.firstMatch(of: #/^\(([^)]+)\)/#).map { String($0.1) } ?? ""
            return .password(account: account)
        }
        return .other(message: message)
    }

    /// Whether the answer may be offered to the Keychain.
    public var canBeRemembered: Bool {
        switch self {
        case .passphrase, .password: true
        default: false
        }
    }
}

public protocol AskpassResponder: AnyObject, Sendable {
    /// The answer to send back to `ssh`, or `nil` to cancel the connection attempt.
    func respond(to prompt: AskpassPrompt) async -> String?
    func noticeBegan(_ message: String, id: UUID)
    func noticeEnded(id: UUID)
}

/// Listens on a Unix socket for the askpass helper that `ssh` launches, and routes each question to the
/// responder registered for that connection attempt.
///
/// Wire format, helper to app: `<token>\n<SSH_ASKPASS_PROMPT>\n<prompt>` then the helper closes its write side.
/// App to helper: `0<answer>` or `1` for cancel.
public final class AskpassServer: @unchecked Sendable {
    public static let socketVariable = "NAVETTE_ASKPASS_SOCKET"
    public static let tokenVariable = "NAVETTE_ASKPASS_TOKEN"

    public let socketPath: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var responders: [String: any AskpassResponder] = [:]
    private var stopped = false

    public init(directory: URL) throws {
        socketPath = directory.appendingPathComponent("a-\(getpid())-\(UInt16.random(in: 0...UInt16.max)).sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard descriptor >= 0, pathBytes.count < capacity else { throw RemoteError.server("Cannot create the askpass socket") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw RemoteError.server("Cannot listen on the askpass socket")
        }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "navette-askpass"
        thread.start()
    }

    deinit { stop() }

    public func stop() {
        let wasStopped = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !wasStopped else { return }
        close(descriptor)
        unlink(socketPath)
    }

    /// Returns the token to pass to the `ssh` process of one connection attempt.
    public func register(_ responder: any AskpassResponder) -> String {
        let token = UUID().uuidString
        lock.withLock { responders[token] = responder }
        return token
    }

    public func unregister(_ token: String) {
        lock.withLock { responders[token] = nil }
    }

    /// The variables that make `ssh` ask through the helper instead of a terminal.
    public func environment(token: String, helperPath: String) -> [String: String] {
        ["SSH_ASKPASS": helperPath, "SSH_ASKPASS_REQUIRE": "force", Self.socketVariable: socketPath, Self.tokenVariable: token]
    }

    private func acceptLoop() {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if lock.withLock({ stopped }) { return }
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let parts = data.split(separator: UInt8(ascii: "\n"), maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let token = String(decoding: parts[0], as: UTF8.self)
        guard let responder = lock.withLock({ responders[token] }) else {
            reply(client, nil)
            return
        }
        let prompt = AskpassPrompt.classify(hint: String(decoding: parts[1], as: UTF8.self), text: String(decoding: parts[2], as: UTF8.self))

        if case .notice(let message) = prompt {
            // ssh kills the helper when the notice is over: wait for the socket to hang up.
            let id = UUID()
            responder.noticeBegan(message, id: id)
            var descriptor = pollfd(fd: client, events: Int16(POLLHUP), revents: 0)
            for _ in 0..<600 {
                if poll(&descriptor, 1, 500) != 0 { break }
            }
            responder.noticeEnded(id: id)
            return
        }

        let done = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        Task {
            box.answer = await responder.respond(to: prompt)
            done.signal()
        }
        done.wait()
        reply(client, box.answer)
    }

    private func reply(_ client: Int32, _ answer: String?) {
        let bytes = Array((answer.map { "0" + $0 } ?? "1").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    private final class AnswerBox: @unchecked Sendable {
        var answer: String?
    }
}
