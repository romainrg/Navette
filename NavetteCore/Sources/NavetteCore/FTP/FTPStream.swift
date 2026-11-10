import Foundation
import Network
import Security

/// How a TLS certificate is checked on FTP connections: the system's judgment, or exactly the certificate the user trusted.
final class FTPTrust: @unchecked Sendable {
    let serverName: String
    let trustedSHA256: String?
    private let lock = NSLock()
    private var _problem: CertificateSummary?

    init(serverName: String, trustedSHA256: String?) {
        self.serverName = serverName
        self.trustedSHA256 = trustedSHA256?.lowercased()
    }

    /// Set when a connection was refused because of its certificate.
    var problem: CertificateSummary? { lock.withLock { _problem } }

    func options(queue: DispatchQueue) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(security, serverName)
        sec_protocol_options_set_verify_block(security, { [self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let problem = CertificateInspector.problem(with: secTrust) else {
                complete(true)
                return
            }
            // Never bypassed silently: accepted only when the user trusted exactly this certificate.
            if let trustedSHA256, trustedSHA256 == problem.sha256 {
                complete(true)
            } else {
                lock.withLock { _problem = problem }
                complete(false)
            }
        }, queue)
        return tls
    }
}

/// One TCP connection (control or data), optionally with TLS, as an async byte stream.
final class FTPStream: @unchecked Sendable {
    enum Security {
        case plain
        /// TLS from the first byte: data connections, and implicit FTPS on port 990.
        case tls(FTPTrust)
        /// Explicit FTPS: the greeting and `AUTH TLS` in clear, then TLS on the same connection.
        case authTLS(FTPTrust)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let trust: FTPTrust?
    private let host: String
    private let lock = NSLock()
    private var reachedEnd = false

    var isEncrypted: Bool { trust != nil }

    init(host: String, port: Int, security: Security, queue: DispatchQueue) {
        self.host = host
        self.queue = queue
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 21
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        tcp.noDelay = true
        let parameters: NWParameters
        switch security {
        case .plain:
            trust = nil
            parameters = NWParameters(tls: nil, tcp: tcp)
        case .tls(let trust):
            self.trust = trust
            parameters = NWParameters(tls: trust.options(queue: queue), tcp: tcp)
        case .authTLS(let trust):
            self.trust = trust
            parameters = NWParameters(tls: nil, tcp: tcp)
            FTPAuthTLSFramer.register(trust, queue: queue, host: host, port: Int(endpointPort.rawValue))
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: FTPAuthTLSFramer.definition), at: 0)
        }
        connection = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    once.finish(.success(()))
                case .failed(let error), .waiting(let error):
                    self.connection.cancel()
                    once.finish(.failure(self.map(error)))
                case .cancelled:
                    once.finish(.failure(RemoteError.connectionLost("Cancelled")))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func map(_ error: NWError) -> RemoteError {
        if let problem = trust?.problem { return .untrustedCertificate(problem) }
        switch error {
        case .posix(let code) where code == .ECONNREFUSED || code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .ENETUNREACH || code == .ENETDOWN:
            return .unreachable("\(host): \(error.localizedDescription)")
        case .dns:
            return .unreachable("\(host): \(error.localizedDescription)")
        case .posix(let code) where code == .EPROTONOSUPPORT:
            return .unsupported("The server does not offer TLS (AUTH TLS was refused). Navette did not continue in clear.")
        case .tls:
            return .server("TLS: \(error.localizedDescription)")
        default:
            return .connectionLost(error.localizedDescription)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [self] error in
                if let error { continuation.resume(throwing: map(error)) } else { continuation.resume() }
            })
        }
    }

    /// Tells the other side that nothing more will be sent (end of an upload).
    func finishSending() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] error in
                if let error { continuation.resume(throwing: map(error)) } else { continuation.resume() }
            })
        }
    }

    /// The next bytes, or `nil` once the other side closed the connection.
    func receive() async throws -> Data? {
        // The last bytes arrive together with the end of the stream: asking again after that is an error.
        if lock.withLock({ reachedEnd }) { return nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
                if isComplete { lock.withLock { reachedEnd = true } }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: map(error))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// The state handler fires several times; the waiting task is resumed by the first decisive state only.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}

/// Sits below TLS on the control connection of explicit FTPS: reads the greeting, sends `AUTH TLS`, and on
/// `234` inserts TLS above itself, then gets out of the way.
final class FTPAuthTLSFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: FTPAuthTLSFramer.self)
    static var label: String { "navette-ftp-auth-tls" }

    // The system creates framers itself, so the TLS settings are looked up by remote endpoint.
    private static let lock = NSLock()
    private static var registry: [String: (trust: FTPTrust, queue: DispatchQueue)] = [:]

    static func register(_ trust: FTPTrust, queue: DispatchQueue, host: String, port: Int) {
        lock.withLock { registry["\(host.lowercased()):\(port)"] = (trust, queue) }
    }

    private var parser = FTPReplyParser()
    private var sentAuth = false

    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var received = Data()
        while true {
            var got = false
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 4096) { bytes, _ in
                guard let bytes, bytes.count > 0 else { return 0 }
                received.append(contentsOf: bytes)
                got = true
                return bytes.count
            }
            if !got { break }
        }
        guard let replies = try? parser.append(received) else {
            framer.markFailed(error: .posix(.EPROTO))
            return 0
        }
        for reply in replies {
            if !sentAuth, reply.code == 220 {
                sentAuth = true
                framer.writeOutput(data: Data("AUTH TLS\r\n".utf8))
            } else if sentAuth, reply.code == 234 {
                guard case .hostPort(let host, let port) = framer.remote,
                      let settings = Self.lock.withLock({ Self.registry["\("\(host)".lowercased()):\(port.rawValue)"] }) else {
                    framer.markFailed(error: .posix(.EPROTO))
                    return 0
                }
                do {
                    try framer.prependApplicationProtocol(options: settings.trust.options(queue: settings.queue))
                    framer.passThroughInput()
                    framer.passThroughOutput()
                    framer.markReady()
                } catch {
                    framer.markFailed(error: .posix(.EPROTO))
                }
            } else if reply.code >= 400 || (sentAuth && reply.code != 234) {
                // The server refuses TLS: stop here, never continue in clear.
                framer.markFailed(error: .posix(.EPROTONOSUPPORT))
            }
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }
}
