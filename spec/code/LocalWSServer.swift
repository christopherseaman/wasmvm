import Foundation
import Network

/// Minimal localhost WebSocket server.
/// One server per port; hands each accepted connection to a handler.
final class LocalWSServer {
    private let listener: NWListener
    private let handler: (NWConnection) -> Void

    init(port: UInt16, path: String, handler: @escaping (NWConnection) -> Void) throws {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 16 * 1024 * 1024  // 16 MiB; 9P needs headroom

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        self.listener = try NWListener(using: params)
        self.handler = handler

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.handler(conn)
        }
    }

    func start() {
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
    }
}

/// Receive one WS message (binary). Calls completion with payload or nil on close.
func wsReceive(_ conn: NWConnection, _ done: @escaping (Data?) -> Void) {
    conn.receiveMessage { data, ctx, _, error in
        if error != nil || data == nil {
            done(nil)
            return
        }
        // Could inspect ctx?.protocolMetadata for opcode if you care about text vs binary
        done(data)
    }
}

/// Send one binary WS message.
func wsSend(_ conn: NWConnection, _ data: Data, _ done: @escaping (Bool) -> Void = { _ in }) {
    let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
    let ctx = NWConnection.ContentContext(identifier: "send", metadata: [meta])
    conn.send(content: data, contentContext: ctx, isComplete: true,
              completion: .contentProcessed { err in done(err == nil) })
}
