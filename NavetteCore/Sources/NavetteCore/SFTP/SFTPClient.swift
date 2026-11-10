import Foundation

/// An ordered byte pipe to an SFTP server: in production, the stdin and stdout of an `ssh` process.
public protocol ByteTransport: AnyObject, Sendable {
    /// Starts delivering incoming bytes. `closed` is called once, when the other side goes away.
    func start(received: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable (RemoteError) -> Void) throws
    /// May block until the bytes are accepted.
    func send(_ data: Data) throws
    func close()
}

/// SFTP v3 requests and replies over a transport. Requests are pipelined: many can be in flight at once.
public final class SFTPClient: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var readLength = 32_768
        public var writeLength = 32_768
    }

    private let transport: any ByteTransport
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "io.github.romainrg.Navette.sftp.write")
    private var parser = SFTPFrameParser()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<SFTPPacket, Error>] = [:]
    private var versionContinuation: CheckedContinuation<SFTPPacket, Error>?
    private var closedError: RemoteError?

    public private(set) var extensions: [String: String] = [:]
    public private(set) var limits = Limits()

    public init(transport: any ByteTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Sends INIT, reads VERSION and the extensions, then asks the server for its limits.
    public func start() async throws {
        let packet: SFTPPacket = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { versionContinuation = continuation }
            do {
                try transport.start(
                    received: { [weak self] data in self?.receive(data) },
                    closed: { [weak self] error in self?.fail(with: error) })
                var writer = ByteWriter()
                writer.u32(3)
                try transport.send(SFTPPacket(type: SFTPType.initialize, payload: writer.bytes).encoded)
            } catch {
                fail(with: (error as? RemoteError) ?? .connectionLost(error.localizedDescription))
            }
        }
        var reader = ByteReader(packet.payload)
        let version = try reader.u32()
        guard version >= 3 else { throw RemoteError.protocolViolation("Unsupported SFTP version \(version)") }
        var found: [String: String] = [:]
        while !reader.isAtEnd {
            let name = String(decoding: try reader.string(), as: UTF8.self)
            found[name] = String(decoding: try reader.string(), as: UTF8.self)
        }
        extensions = found
        if found["limits@openssh.com"] != nil {
            let reply = try await request(SFTPType.extended) { $0.string("limits@openssh.com") }
            if reply.type == SFTPType.extendedReply {
                var body = ByteReader(reply.payload)
                _ = try body.u32()
                _ = try body.u64()
                let read = try body.u64(), write = try body.u64()
                if read > 0 { limits.readLength = Int(min(read, 1 << 20)) }
                if write > 0 { limits.writeLength = Int(min(write, 1 << 20)) }
            }
        }
    }

    public func close() {
        transport.close()
        fail(with: .connectionLost("Disconnected"))
    }

    public func supports(_ name: String) -> Bool { extensions[name] != nil }

    // MARK: - Requests

    /// Sends one request and waits for its reply. The request id is written before whatever `build` adds.
    public func request(_ type: UInt8, _ build: (inout ByteWriter) -> Void) async throws -> SFTPPacket {
        var body = ByteWriter()
        build(&body)
        let payload = body.bytes
        return try await withCheckedThrowingContinuation { continuation in
            let id: UInt32? = lock.withLock {
                if closedError != nil { return nil }
                let id = nextID
                nextID &+= 1
                pending[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(throwing: lock.withLock { closedError } ?? RemoteError.connectionLost("Disconnected"))
                return
            }
            var writer = ByteWriter()
            writer.u32(id)
            let frame = SFTPPacket(type: type, payload: writer.bytes + payload).encoded
            writeQueue.async { [self] in
                do {
                    try transport.send(frame)
                } catch {
                    let waiting = lock.withLock { pending.removeValue(forKey: id) }
                    waiting?.resume(throwing: RemoteError.connectionLost(error.localizedDescription))
                }
            }
        }
    }

    /// Throws unless the reply is a STATUS with code OK.
    public func expectOK(_ packet: SFTPPacket, path: String) throws {
        guard packet.type == SFTPType.status else { throw RemoteError.protocolViolation("Unexpected SFTP reply \(packet.type)") }
        let status = try Self.status(packet)
        guard status.code == SFTPStatus.ok else { throw RemoteError.sftpStatus(code: status.code, message: status.message, path: path) }
    }

    /// Throws the error carried by a STATUS reply when another type was expected.
    public func expect(_ type: UInt8, _ packet: SFTPPacket, path: String) throws -> ByteReader {
        if packet.type == SFTPType.status {
            let status = try Self.status(packet)
            throw RemoteError.sftpStatus(code: status.code, message: status.message, path: path)
        }
        guard packet.type == type else { throw RemoteError.protocolViolation("Unexpected SFTP reply \(packet.type)") }
        var reader = ByteReader(packet.payload)
        _ = try reader.u32()
        return reader
    }

    public static func status(_ packet: SFTPPacket) throws -> (code: UInt32, message: String) {
        var reader = ByteReader(packet.payload)
        _ = try reader.u32()
        let code = try reader.u32()
        let message = reader.isAtEnd ? "" : String(decoding: try reader.string(), as: UTF8.self)
        return (code, message)
    }

    // MARK: - Incoming

    private func receive(_ data: Data) {
        let packets: [SFTPPacket]
        do {
            packets = try lock.withLock { try parser.append(data) }
        } catch {
            transport.close()
            fail(with: (error as? RemoteError) ?? .protocolViolation("Invalid SFTP stream"))
            return
        }
        for packet in packets {
            if packet.type == SFTPType.version {
                lock.withLock { () -> CheckedContinuation<SFTPPacket, Error>? in
                    defer { versionContinuation = nil }
                    return versionContinuation
                }?.resume(returning: packet)
                continue
            }
            guard packet.payload.count >= 4 else { continue }
            let id = packet.payload[0..<4].reduce(0) { $0 << 8 | UInt32($1) }
            lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: packet)
        }
    }

    private func fail(with error: RemoteError) {
        let (waiting, version): ([CheckedContinuation<SFTPPacket, Error>], CheckedContinuation<SFTPPacket, Error>?) = lock.withLock {
            if closedError == nil { closedError = error }
            defer {
                pending.removeAll()
                versionContinuation = nil
            }
            return (Array(pending.values), versionContinuation)
        }
        let reason = lock.withLock { closedError } ?? error
        version?.resume(throwing: reason)
        waiting.forEach { $0.resume(throwing: reason) }
    }
}
