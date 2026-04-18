import XCTest
import Foundation
@testable import WasmVMServer
import WasmVMCore

/// Real Telegraph + real URLSessionWebSocketTask client. We exercise the demux
/// by connecting to /net and /9p and validating that frames really flow through
/// the codec into the W5 bridges and back out.
final class WebSocketDemuxTests: XCTestCase {
    var tmpRoot: URL!
    var nineRoot: URL!
    var server: LocalServer!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wasmvm-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        nineRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wasmvm-ws-9p-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nineRoot, withIntermediateDirectories: true)

        server = LocalServer(
            assetRoot: { [tmpRoot] in tmpRoot! },
            nineRoot: { [nineRoot] in nineRoot }
        )
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let r = tmpRoot { try? FileManager.default.removeItem(at: r) }
        if let r = nineRoot { try? FileManager.default.removeItem(at: r) }
        super.tearDown()
    }

    private func wsURL(_ path: String) -> URL {
        URL(string: "ws://127.0.0.1:\(server.port)\(path)")!
    }

    // MARK: - /net

    func test_net_endpoint_replies_with_connect_err_for_unreachable_host() async throws {
        let task = URLSession.shared.webSocketTask(with: wsURL("/net"))
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Build a CONNECT frame for a host:port that should not accept TCP.
        // 127.0.0.1:1 is reserved/unused on every test host I've seen.
        let payload = FrameCodec.encodeConnectPayload(
            ConnectPayload(family: .ipv4, proto: .tcp, host: "127.0.0.1", port: 1)
        )
        let connectFrame = FrameCodec.encode(Frame(op: .connect, connID: 7, payload: payload))
        try await task.send(.data(connectFrame))

        // Expect a CONNECT_ERR back. The bridge runs dial off the work queue
        // and may take a moment.
        let reply = try await task.receive()
        guard case .data(let bytes) = reply else { return XCTFail("expected binary reply") }
        let frame = try FrameCodec.decode(bytes)
        XCTAssertEqual(frame.connID, 7)
        XCTAssertEqual(frame.op, .connectErr,
                       "got op \(frame.op), payload=\(String(data: frame.payload, encoding: .utf8) ?? "?")")
    }

    // MARK: - /9p

    func test_ninep_endpoint_replies_to_tversion() async throws {
        let task = URLSession.shared.webSocketTask(with: wsURL("/9p"))
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Tversion body: msize(4) | version(s)
        var body = Data()
        body.appendU32LE(8192)
        NinePCodec.appendString("9P2000.L", to: &body)
        let msg = NinePCodec.encode(NinePMessage(op: .Tversion, tag: 0xABCD, body: body))
        try await task.send(.data(msg))

        let reply = try await task.receive()
        guard case .data(let bytes) = reply else { return XCTFail("expected binary reply") }
        let parsed = try NinePCodec.decode(bytes)
        XCTAssertEqual(parsed.op, .Rversion)
        XCTAssertEqual(parsed.tag, 0xABCD)
        // Server should echo a clamped msize and the protocol string.
        let echoedMsize = parsed.body.readU32LE(at: 0) ?? 0
        XCTAssertEqual(echoedMsize, 8192)
    }

    // MARK: - unknown path

    func test_unknown_path_closes_socket() async throws {
        let task = URLSession.shared.webSocketTask(with: wsURL("/unknown"))
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // The server immediately initiates a close handshake. URLSessionWebSocketTask
        // delivers the close as a task-level error from `receive()`. Either the
        // first receive throws (typical) or a follow-up does — both are acceptable
        // signals that the demux refused the connection.
        var threw = false
        for _ in 0..<3 {
            do {
                _ = try await task.receive()
            } catch {
                threw = true
                break
            }
        }
        XCTAssertTrue(threw, "expected receive to fail after server-initiated close")
    }
}
