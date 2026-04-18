import Foundation
@testable import WasmVMNineP

/// Same in-process pipe pair as in WasmVMNetTests, retyped for NinePServer.Socket.
final class NinePPipeSocketPair {
    let server: NinePPipeSocket
    let client: NinePPipeSocket

    init() {
        let s = NinePPipeSocket()
        let c = NinePPipeSocket()
        s.peer = c
        c.peer = s
        self.server = s
        self.client = c
    }

    func tearDown() {
        server.close()
    }
}

final class NinePPipeSocket: NinePServer.Socket {
    fileprivate weak var peer: NinePPipeSocket?
    private let lock = NSLock()
    private var closed = false
    private let deliveryQueue = DispatchQueue(label: "ninep.pipesocket.delivery")

    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    func sendBinary(_ data: Data) {
        let target = peer
        deliveryQueue.async {
            guard let target = target else { return }
            target.deliver(data)
        }
    }

    fileprivate func deliver(_ data: Data) {
        lock.lock()
        let cb = onBinary
        let isClosed = closed
        lock.unlock()
        if isClosed { return }
        cb?(data)
    }

    func close() {
        lock.lock()
        let already = closed
        closed = true
        let cb = onClose
        lock.unlock()
        if already { return }
        cb?()
        peer?.peerDidClose()
    }

    fileprivate func peerDidClose() {
        lock.lock()
        let already = closed
        closed = true
        let cb = onClose
        lock.unlock()
        if already { return }
        cb?()
    }
}
