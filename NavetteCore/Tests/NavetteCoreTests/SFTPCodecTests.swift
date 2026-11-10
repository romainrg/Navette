import XCTest
@testable import NavetteCore

final class SFTPCodecTests: XCTestCase {
    func testIntegersAndStrings() throws {
        var writer = ByteWriter()
        writer.u8(7)
        writer.u32(0xDEADBEEF)
        writer.u64(0x0102_0304_0506_0708)
        writer.string("héllo")
        writer.string([0xff, 0x00, 0x2f])
        XCTAssertEqual(writer.bytes.prefix(5), [7, 0xDE, 0xAD, 0xBE, 0xEF])

        var reader = ByteReader(writer.bytes)
        XCTAssertEqual(try reader.u8(), 7)
        XCTAssertEqual(try reader.u32(), 0xDEADBEEF)
        XCTAssertEqual(try reader.u64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try reader.string(), Array("héllo".utf8))
        XCTAssertEqual(try reader.string(), [0xff, 0x00, 0x2f])
        XCTAssertTrue(reader.isAtEnd)
    }

    func testTruncatedInputThrows() {
        var short = ByteReader([0, 0])
        XCTAssertThrowsError(try short.u32())
        var lying = ByteReader([0, 0, 0, 9, 1, 2])
        XCTAssertThrowsError(try lying.string()) { XCTAssertEqual($0 as? RemoteError, .protocolViolation("Truncated SFTP packet")) }
        var huge = ByteReader([0xff, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try huge.string())
    }

    func testPacketEncoding() {
        let packet = SFTPPacket(type: SFTPType.initialize, payload: [0, 0, 0, 3])
        XCTAssertEqual(Array(packet.encoded), [0, 0, 0, 5, 1, 0, 0, 0, 3])
    }

    func testFrameParserHandlesSplitAndJoinedPackets() throws {
        let first = SFTPPacket(type: SFTPType.status, payload: [0, 0, 0, 1, 0, 0, 0, 0])
        let second = SFTPPacket(type: SFTPType.handle, payload: [0, 0, 0, 2, 0, 0, 0, 1, 0x41])
        let stream = first.encoded + second.encoded

        var whole = SFTPFrameParser()
        XCTAssertEqual(try whole.append(stream), [first, second])

        var byByte = SFTPFrameParser()
        var packets = [SFTPPacket]()
        for byte in stream { packets += try byByte.append(Data([byte])) }
        XCTAssertEqual(packets, [first, second])

        var split = SFTPFrameParser()
        XCTAssertEqual(try split.append(stream.prefix(15)), [first])
        XCTAssertEqual(try split.append(stream.dropFirst(15)), [second])
    }

    func testFrameParserRejectsAbsurdLengths() {
        var zero = SFTPFrameParser()
        XCTAssertThrowsError(try zero.append(Data([0, 0, 0, 0, 1])))
        var huge = SFTPFrameParser()
        XCTAssertThrowsError(try huge.append(Data([0x7f, 0xff, 0xff, 0xff, 1])))
    }

    func testAttributesRoundTrip() throws {
        let attributes = SFTPAttributes(size: 5 << 30, uid: 501, gid: 20, permissions: 0o100644, accessTime: 1_800_000_000, modificationTime: 1_800_000_100)
        var writer = ByteWriter()
        attributes.encode(to: &writer)
        var reader = ByteReader(writer.bytes)
        XCTAssertEqual(try SFTPAttributes(from: &reader), attributes)
        XCTAssertTrue(reader.isAtEnd)

        var empty = ByteWriter()
        SFTPAttributes().encode(to: &empty)
        XCTAssertEqual(empty.bytes, [0, 0, 0, 0])
    }

    func testAttributesSkipExtendedPairs() throws {
        var writer = ByteWriter()
        writer.u32(0x8000_0001)
        writer.u64(42)
        writer.u32(2)
        writer.string("a@b")
        writer.string("1")
        writer.string("c@d")
        writer.string("22")
        writer.u32(99)
        var reader = ByteReader(writer.bytes)
        let attributes = try SFTPAttributes(from: &reader)
        XCTAssertEqual(attributes.size, 42)
        XCTAssertEqual(try reader.u32(), 99, "the reader must sit right after the attributes")
    }

    func testItemFromAttributes() {
        let path = RemotePath("/srv/a.txt")
        let longName = Array("-rw-r--r--    1 deploy   www-data     1234 Nov 10 10:00 a.txt".utf8)
        let file = SFTPAttributes(size: 1234, uid: 1000, gid: 33, permissions: 0o100644, accessTime: 0, modificationTime: 1_800_000_000).item(path: path, longName: longName)
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.size, 1234)
        XCTAssertEqual(file.permissions, 0o644)
        XCTAssertEqual(file.owner, "deploy")
        XCTAssertEqual(file.group, "www-data")
        XCTAssertEqual(file.modified, Date(timeIntervalSince1970: 1_800_000_000))

        let numeric = SFTPAttributes(uid: 1000, gid: 33, permissions: 0o040755).item(path: path)
        XCTAssertEqual(numeric.kind, .directory)
        XCTAssertEqual(numeric.owner, "1000")
        XCTAssertNil(numeric.size)
        XCTAssertEqual(SFTPAttributes(permissions: 0o120777).kind, .symlink)
        XCTAssertEqual(SFTPAttributes(permissions: 0o140755).kind, .other)
        XCTAssertEqual(SFTPAttributes(permissions: 0o104755).item(path: path).permissions, 0o4755)
    }

    func testStatusMapping() {
        XCTAssertEqual(RemoteError.sftpStatus(code: SFTPStatus.noSuchFile, message: "No such file", path: "/x"), .notFound("/x"))
        XCTAssertEqual(RemoteError.sftpStatus(code: SFTPStatus.permissionDenied, message: "", path: "/x"), .permissionDenied("/x"))
        XCTAssertEqual(RemoteError.sftpStatus(code: SFTPStatus.failure, message: "Failure", path: "/x"), .server("Failure: /x"))
        XCTAssertEqual(RemoteError.sftpStatus(code: SFTPStatus.connectionLost, message: "gone", path: "/x"), .connectionLost("gone"))
    }

    // MARK: - Client over a scripted transport

    func testClientMatchesRepliesToRequestsOutOfOrder() async throws {
        let transport = ScriptedTransport()
        let client = SFTPClient(transport: transport)
        transport.onSend = { packet in
            if packet.type == SFTPType.initialize {
                var writer = ByteWriter()
                writer.u32(3)
                writer.string("posix-rename@openssh.com")
                writer.string("1")
                return [SFTPPacket(type: SFTPType.version, payload: writer.bytes)]
            }
            return []
        }
        try await client.start()
        XCTAssertTrue(client.supports("posix-rename@openssh.com"))
        XCTAssertEqual(client.limits, SFTPClient.Limits())

        // Hold the replies, then deliver them in reverse order.
        var held = [SFTPPacket]()
        let lock = NSLock()
        transport.onSend = { packet in
            var writer = ByteWriter()
            writer.u32(packet.payload[0..<4].reduce(0) { $0 << 8 | UInt32($1) })
            writer.string(Array(packet.payload[4...]))
            lock.withLock { held.append(SFTPPacket(type: SFTPType.data, payload: writer.bytes)) }
            return []
        }
        async let a = client.request(SFTPType.read) { $0.u8(1) }
        async let b = client.request(SFTPType.read) { $0.u8(2) }
        async let c = client.request(SFTPType.read) { $0.u8(3) }
        while lock.withLock({ held.count }) < 3 { try await Task.sleep(for: .milliseconds(5)) }
        for packet in lock.withLock({ held.reversed() }) { transport.deliver(packet) }
        let replies = try await [a, b, c]
        for (index, reply) in replies.enumerated() {
            var reader = try client.expect(SFTPType.data, reply, path: "")
            XCTAssertEqual(try reader.string(), [UInt8(index + 1)])
        }
    }

    func testClientFailsPendingRequestsWhenTheTransportCloses() async throws {
        let transport = ScriptedTransport()
        let client = SFTPClient(transport: transport)
        transport.onSend = { $0.type == SFTPType.initialize ? [SFTPPacket(type: SFTPType.version, payload: [0, 0, 0, 3])] : [] }
        try await client.start()
        async let pending = client.request(SFTPType.lstat) { $0.string("/x") }
        try await Task.sleep(for: .milliseconds(20))
        transport.closeFromServer(.authenticationFailed("Permission denied (publickey)."))
        do {
            _ = try await pending
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? RemoteError, .authenticationFailed("Permission denied (publickey)."))
        }
        do {
            _ = try await client.request(SFTPType.lstat) { $0.string("/y") }
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? RemoteError, .authenticationFailed("Permission denied (publickey)."))
        }
    }

    func testClientReportsWhySSHExitedBeforeTheHandshake() async {
        let transport = ScriptedTransport()
        let client = SFTPClient(transport: transport)
        transport.onSend = { _ in
            transport.closeFromServer(.unreachable("ssh: connect to host x port 22: Connection refused"))
            return []
        }
        do {
            try await client.start()
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? RemoteError, .unreachable("ssh: connect to host x port 22: Connection refused"))
        }
    }
}

/// A transport driven by the test: `onSend` sees each packet the client sends and returns the replies.
final class ScriptedTransport: ByteTransport, @unchecked Sendable {
    var onSend: (SFTPPacket) -> [SFTPPacket] = { _ in [] }
    private var received: (@Sendable (Data) -> Void)?
    private var closed: (@Sendable (RemoteError) -> Void)?
    private var parser = SFTPFrameParser()

    func start(received: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable (RemoteError) -> Void) throws {
        self.received = received
        self.closed = closed
    }

    func send(_ data: Data) throws {
        for packet in try parser.append(data) {
            for reply in onSend(packet) { deliver(reply) }
        }
    }

    func deliver(_ packet: SFTPPacket) {
        received?(packet.encoded)
    }

    func closeFromServer(_ error: RemoteError) {
        closed?(error)
    }

    func close() {}
}
