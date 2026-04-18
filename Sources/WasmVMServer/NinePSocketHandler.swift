import Foundation
import Telegraph
import WasmVMNineP

/// Adapter that lets `NinePServer` consume a Telegraph `WebSocket`.
/// Mirrors `NetSocketHandler`; kept separate so the two protocol modules
/// don't need to share a common Telegraph adapter type.
public final class NinePSocketHandler: NinePServer.Socket {
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

    public func deliver(_ message: WebSocketMessage) {
        if case .binary(let data) = message.payload {
            onBinary?(data)
        }
    }

    public func deliverClose() {
        onClose?()
    }
}
