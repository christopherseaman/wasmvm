import Foundation
import Telegraph
import WasmVMNet

/// Adapter that lets `NetBridge` consume a Telegraph `WebSocket`.
/// Telegraph delivers messages through a single `ServerWebSocketDelegate` on the
/// `Server`; LocalServer routes per-socket events here by looking up this adapter
/// in its socket-to-handler map.
public final class NetSocketHandler: NetBridge.Socket {
    private let socket: WebSocket
    public var onBinary: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    public init(socket: WebSocket) {
        self.socket = socket
    }

    public func sendBinary(_ data: Data) {
        socket.send(data: data)
    }

    public func close() {
        socket.close(immediately: false)
    }

    /// Called by LocalServer when Telegraph delivers a message for this socket.
    public func deliver(_ message: WebSocketMessage) {
        if case .binary(let data) = message.payload {
            onBinary?(data)
        }
    }

    /// Called by LocalServer when Telegraph reports the socket disconnected.
    public func deliverClose() {
        onClose?()
    }
}
