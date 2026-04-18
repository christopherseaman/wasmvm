import XCTest
import Foundation
@testable import WasmVMServer
import WasmVMCore

/// 1 MiB binary WS round-trip through Telegraph. Confirms Telegraph's parser
/// (`maxPayloadLength` default = 10 MiB) accepts our spec-defined max DATA frame.
/// The server-side handler is the WebSocketDemux which forwards into a real
/// NetBridge — but here we don't need a bridge response, only that the message
/// reaches the demux. We assert on the demux receiving the message via a peek.
final class PayloadSizeTests: XCTestCase {
    var tmpRoot: URL!
    var server: LocalServer!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wasmvm-payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        server = LocalServer(
            assetRoot: { [tmpRoot] in tmpRoot! },
            nineRoot: { nil }
        )
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let r = tmpRoot { try? FileManager.default.removeItem(at: r) }
        super.tearDown()
    }

    /// Sends a 1 MiB DATA frame for an unknown conn_id. The bridge should
    /// silently drop (no response), but the *fact* that the WS layer accepted
    /// it without erroring or closing proves Telegraph's payload cap is OK.
    /// We then send a small CONNECT to a closed port and expect CONNECT_ERR
    /// to confirm the WS is still alive.
    func test_one_mib_data_frame_does_not_blow_the_ws() async throws {
        let url = URL(string: "ws://127.0.0.1:\(server.port)/net")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // 1 MiB payload + 9-byte header. Pattern is non-trivial to prevent any
        // accidental compression-friendly path from masking a real bug.
        let payloadCount = 1 * 1024 * 1024
        var payload = Data(count: payloadCount)
        for i in 0..<payloadCount { payload[i] = UInt8(i & 0xFF) }
        let frame = FrameCodec.encode(Frame(op: .data, connID: 999, payload: payload))
        XCTAssertEqual(frame.count, FrameCodec.headerSize + payloadCount)
        try await task.send(.data(frame))

        // Now a small CONNECT to confirm the channel survived.
        let connectPayload = FrameCodec.encodeConnectPayload(
            ConnectPayload(family: .ipv4, proto: .tcp, host: "127.0.0.1", port: 1)
        )
        let connect = FrameCodec.encode(Frame(op: .connect, connID: 1, payload: connectPayload))
        try await task.send(.data(connect))

        let reply = try await task.receive()
        guard case .data(let bytes) = reply else { return XCTFail("expected binary reply") }
        let parsed = try FrameCodec.decode(bytes)
        XCTAssertEqual(parsed.connID, 1)
        XCTAssertEqual(parsed.op, .connectErr,
                       "1 MiB DATA frame must not have killed the WS; expected CONNECT_ERR after, got \(parsed.op)")
    }
}
