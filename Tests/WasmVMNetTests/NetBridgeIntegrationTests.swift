import XCTest
@testable import WasmVMNet
@testable import WasmVMCore

final class NetBridgeIntegrationTests: XCTestCase {

    private var echo: LoopbackEchoServer!
    private var pair: PipeSocketPair!
    private var bridge: NetBridge!
    private var received: ReceivedFrames!

    override func setUpWithError() throws {
        echo = try LoopbackEchoServer()
        pair = PipeSocketPair()
        bridge = NetBridge(socket: pair.server)
        received = ReceivedFrames()
        pair.client.onBinary = { [weak received] data in
            received?.add(data)
        }
    }

    override func tearDown() {
        pair?.tearDown()
        echo?.stop()
        bridge = nil
        pair = nil
        echo = nil
        received = nil
    }

    // MARK: - Helpers

    private func sendConnect(id: UInt32, host: String, port: UInt16) {
        let payload = FrameCodec.encodeConnectPayload(
            ConnectPayload(family: .ipv4, proto: .tcp, host: host, port: port)
        )
        let frame = Frame(op: .connect, connID: id, payload: payload)
        pair.client.sendBinary(FrameCodec.encode(frame))
    }

    private func sendData(id: UInt32, _ bytes: Data) {
        pair.client.sendBinary(FrameCodec.encode(Frame(op: .data, connID: id, payload: bytes)))
    }

    private func sendCloseFrame(id: UInt32) {
        pair.client.sendBinary(FrameCodec.encode(Frame(op: .close, connID: id, payload: Data())))
    }

    /// Wait until the predicate is true or timeout elapses.
    @discardableResult
    private func waitFor(timeout: TimeInterval = 5.0,
                         _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    // MARK: - Tests

    func test_connect_then_close_round_trip() {
        sendConnect(id: 1, host: "127.0.0.1", port: echo.port)
        XCTAssertTrue(waitFor { self.received.firstFrame(op: .connectOK, id: 1) != nil },
                      "expected CONNECT_OK")

        sendData(id: 1, Data("hello".utf8))
        XCTAssertTrue(waitFor {
            self.received.dataPayload(id: 1) == Data("hello".utf8)
        }, "expected echo of hello")

        sendCloseFrame(id: 1)
        // After client CLOSE, host should not be sending more frames; allow time to drain.
        Thread.sleep(forTimeInterval: 0.05)
    }

    func test_multiple_data_frames_round_trip() {
        sendConnect(id: 2, host: "127.0.0.1", port: echo.port)
        XCTAssertTrue(waitFor { self.received.firstFrame(op: .connectOK, id: 2) != nil })

        let chunks = ["one", "two", "three", "four"]
        for c in chunks { sendData(id: 2, Data(c.utf8)) }

        let expected = Data("onetwothreefour".utf8)
        XCTAssertTrue(waitFor(timeout: 8) {
            self.received.dataPayload(id: 2) == expected
        }, "expected concatenated echo, got \(self.received.dataPayload(id: 2)?.count ?? 0) bytes")
        sendCloseFrame(id: 2)
    }

    func test_one_mib_data_frame_round_trip() {
        sendConnect(id: 3, host: "127.0.0.1", port: echo.port)
        XCTAssertTrue(waitFor { self.received.firstFrame(op: .connectOK, id: 3) != nil })

        var big = Data(count: 1024 * 1024)
        for i in 0..<big.count { big[i] = UInt8(i & 0xff) }
        sendData(id: 3, big)

        XCTAssertTrue(waitFor(timeout: 30) {
            (self.received.dataPayload(id: 3)?.count ?? 0) >= big.count
        }, "expected 1 MiB echoed; got \(self.received.dataPayload(id: 3)?.count ?? 0)")
        XCTAssertEqual(received.dataPayload(id: 3)?.prefix(big.count), big)
        sendCloseFrame(id: 3)
    }

    func test_concurrent_connections() {
        let n: UInt32 = 100
        for i in 0..<n {
            sendConnect(id: 1000 + i, host: "127.0.0.1", port: echo.port)
        }
        XCTAssertTrue(waitFor(timeout: 15) {
            (0..<n).allSatisfy { self.received.firstFrame(op: .connectOK, id: 1000 + $0) != nil }
        }, "expected all CONNECT_OK")

        for i in 0..<n {
            let payload = Data("c\(i)\n".utf8)
            sendData(id: 1000 + i, payload)
        }
        XCTAssertTrue(waitFor(timeout: 30) {
            (0..<n).allSatisfy {
                self.received.dataPayload(id: 1000 + $0) == Data("c\($0)\n".utf8)
            }
        }, "expected all echoes")
        for i in 0..<n { sendCloseFrame(id: 1000 + i) }
    }

    func test_port_zero_returns_connect_err_no_crash() {
        sendConnect(id: 5, host: "127.0.0.1", port: 0)
        XCTAssertTrue(waitFor { self.received.firstFrame(op: .connectErr, id: 5) != nil },
                      "expected CONNECT_ERR for port 0")
    }

    func test_bad_host_returns_connect_err() {
        // .invalid TLD per RFC 6761 — guaranteed not to resolve.
        sendConnect(id: 6, host: "definitely-not-a-host.invalid", port: 65000)
        XCTAssertTrue(waitFor(timeout: 15) {
            self.received.firstFrame(op: .connectErr, id: 6) != nil
        }, "expected CONNECT_ERR for unresolvable host")
    }

    func test_no_double_close_on_eof_then_explicit_close() {
        sendConnect(id: 7, host: "127.0.0.1", port: echo.port)
        XCTAssertTrue(waitFor { self.received.firstFrame(op: .connectOK, id: 7) != nil })

        // Explicitly tell the bridge to close the upstream — this triggers the
        // socket to EOF in the pump (echo server returns EOF on its end too).
        sendCloseFrame(id: 7)
        // Wait a tick for pump teardown
        Thread.sleep(forTimeInterval: 0.1)

        // Bridge must NOT have sent its own CLOSE for this id (it processed the
        // guest's CLOSE, removed the entry; pump teardown should be a no-op).
        let hostSentCloses = received.frames(op: .close, id: 7)
        XCTAssertEqual(hostSentCloses.count, 0,
                       "host sent \(hostSentCloses.count) CLOSE(s) after guest CLOSE")
    }

    func test_capacity_cap_enforced() {
        let cap = ConnectionTable.capacity
        for i in 0..<UInt32(cap) {
            sendConnect(id: 5000 + i, host: "127.0.0.1", port: echo.port)
        }
        XCTAssertTrue(waitFor(timeout: 30) {
            (0..<UInt32(cap)).allSatisfy {
                self.received.firstFrame(op: .connectOK, id: 5000 + $0) != nil
            }
        })
        // 257th connection must be rejected.
        sendConnect(id: 9999, host: "127.0.0.1", port: echo.port)
        XCTAssertTrue(waitFor(timeout: 5) {
            self.received.firstFrame(op: .connectErr, id: 9999) != nil
        }, "expected CONNECT_ERR for over-cap connection")

        for i in 0..<UInt32(cap) { sendCloseFrame(id: 5000 + i) }
    }
}

/// Concurrent-safe accumulator of decoded frames received by the test client.
final class ReceivedFrames {
    private let lock = NSLock()
    private var raw: [Data] = []

    func add(_ data: Data) {
        lock.lock(); raw.append(data); lock.unlock()
    }

    func snapshot() -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return raw.compactMap { try? FrameCodec.decode($0) }
    }

    func firstFrame(op: FrameOp, id: UInt32) -> Frame? {
        snapshot().first { $0.op == op && $0.connID == id }
    }

    func frames(op: FrameOp, id: UInt32) -> [Frame] {
        snapshot().filter { $0.op == op && $0.connID == id }
    }

    /// Concatenate all DATA payloads for a given conn-id in receipt order.
    func dataPayload(id: UInt32) -> Data? {
        let parts = snapshot().filter { $0.op == .data && $0.connID == id }.map { $0.payload }
        if parts.isEmpty { return nil }
        var out = Data()
        for p in parts { out.append(p) }
        return out
    }
}
