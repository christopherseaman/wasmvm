import Foundation
@testable import WasmVMNet

/// A pair of in-process `NetBridge.Socket` adapters connected back-to-back.
/// Both sides really exchange bytes (no recording, no synthesis) — this is the
/// minimal "real" WebSocket substitute that exercises codecs from both ends.
/// The actual WS framing is covered by Telegraph integration in W7.
final class PipeSocketPair {
    let server: PipeSocket
    let client: PipeSocket

    init() {
        let s = PipeSocket()
        let c = PipeSocket()
        s.peer = c
        c.peer = s
        self.server = s
        self.client = c
    }

    func tearDown() {
        server.close()
    }
}

final class PipeSocket: NetBridge.Socket {
    fileprivate weak var peer: PipeSocket?
    private let lock = NSLock()
    private var closed = false
    private let deliveryQueue = DispatchQueue(label: "pipesocket.delivery")

    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    func sendBinary(_ data: Data) {
        // Async hop so receiver runs off the sender's stack — mirrors WS.
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
