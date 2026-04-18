import Foundation
import Telegraph
import WasmVMNet
import WasmVMNineP

/// One Telegraph server bound to `127.0.0.1:<ephemeral>`. Serves the asset
/// document root over HTTP and demuxes WS upgrades by `handshake.uri.path`:
/// `/net` → NetBridge, `/9p` → NinePServer, anything else closes.
///
/// One instance per app run. Resolved port is published via `port` after `start()`.
public final class LocalServer {
    public let assetRoot: () -> URL
    public let nineRoot: () -> URL?

    private let server = Server()
    private let routes: AssetRoutes
    private let demux = WebSocketDemux()

    /// Port assigned by the OS after `start()`. Zero before start.
    public var port: UInt16 { server.port }

    /// - Parameters:
    ///   - assetRoot: closure returning the document root for HTTP asset serving.
    ///     Closure form lets the host (VMHost) swap roots without restarting the server.
    ///   - nineRoot: closure returning the security-scoped folder root for 9P, or
    ///     nil if the user hasn't picked one yet (we'll close /9p with a policy violation).
    public init(assetRoot: @escaping () -> URL,
                nineRoot: @escaping () -> URL?) {
        self.assetRoot = assetRoot
        self.nineRoot = nineRoot
        self.routes = AssetRoutes(rootProvider: assetRoot)
        self.demux.nineRootProvider = nineRoot
    }

    public func start() throws {
        server.webSocketConfig.pingInterval = 30
        server.webSocketDelegate = demux
        routes.install(on: server)
        try server.start(port: 0, interface: "127.0.0.1")
    }

    public func stop() {
        server.stop(immediately: true)
    }
}

/// Telegraph delivers all WS events through one delegate per server instance.
/// We demux by handshake URI path and own one bridge instance per accepted socket.
final class WebSocketDemux: ServerWebSocketDelegate {
    enum Kind { case net, ninep }
    final class Slot {
        let kind: Kind
        // Hold the bridge so it stays alive for the WS lifetime.
        var net: NetBridge?
        var ninep: NinePServer?
        let socketHandler: AnyObject
        init(kind: Kind, socketHandler: AnyObject, net: NetBridge?, ninep: NinePServer?) {
            self.kind = kind
            self.socketHandler = socketHandler
            self.net = net
            self.ninep = ninep
        }
    }

    var nineRootProvider: () -> URL? = { nil }

    private var slots: [ObjectIdentifier: Slot] = [:]
    private let lock = NSLock()

    func server(_ server: Server, webSocketDidConnect webSocket: WebSocket, handshake: HTTPRequest) {
        let path = handshake.uri.path
        let key = ObjectIdentifier(webSocket)
        switch path {
        case "/net":
            let handler = NetSocketHandler(socket: webSocket)
            let bridge = NetBridge(socket: handler)
            lock.lock()
            slots[key] = Slot(kind: .net, socketHandler: handler, net: bridge, ninep: nil)
            lock.unlock()
        case "/9p":
            guard let root = nineRootProvider() else {
                // No shared folder picked yet; reject with policy-violation 1008.
                webSocket.send(message: WebSocketMessage(closeCode: 1008, reason: "no shared folder"))
                return
            }
            let handler = NinePSocketHandler(socket: webSocket)
            let server9p = NinePServer(socket: handler, root: root)
            lock.lock()
            slots[key] = Slot(kind: .ninep, socketHandler: handler, net: nil, ninep: server9p)
            lock.unlock()
        default:
            // Telegraph's WebSocketConnection.send(closeMessage) marks `closing`
            // so it won't double-close; that's the cleanest way to signal 1008.
            webSocket.send(message: WebSocketMessage(closeCode: 1008, reason: "unknown endpoint"))
        }
    }

    func server(_ server: Server, webSocketDidDisconnect webSocket: WebSocket, error: Error?) {
        let key = ObjectIdentifier(webSocket)
        lock.lock()
        let slot = slots.removeValue(forKey: key)
        lock.unlock()
        guard let slot = slot else { return }
        switch slot.kind {
        case .net:   (slot.socketHandler as? NetSocketHandler)?.deliverClose()
        case .ninep: (slot.socketHandler as? NinePSocketHandler)?.deliverClose()
        }
    }

    func server(_ server: Server, webSocket: WebSocket, didReceiveMessage message: WebSocketMessage) {
        let key = ObjectIdentifier(webSocket)
        lock.lock()
        let slot = slots[key]
        lock.unlock()
        guard let slot = slot else { return }
        switch slot.kind {
        case .net:   (slot.socketHandler as? NetSocketHandler)?.deliver(message)
        case .ninep: (slot.socketHandler as? NinePSocketHandler)?.deliver(message)
        }
    }
}
