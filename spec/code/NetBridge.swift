import Foundation
import Network

/// Bridges WS messages to NWConnection sockets.
/// Wire protocol:
///   u8 op | u32 conn_id (LE) | u32 length (LE) | payload
/// Ops:
///   0x01 CONNECT      (client→host) payload = family(1) proto(1) hostLen(2 LE) host port(2 LE)
///   0x02 DATA         (both)        payload = bytes
///   0x03 CLOSE        (both)        payload = empty
///   0x04 CONNECT_OK   (host→client) payload = empty
///   0x05 CONNECT_ERR  (host→client) payload = ascii reason
final class NetBridge {
    private let ws: NWConnection
    private var conns: [UInt32: NWConnection] = [:]
    private let lock = NSLock()

    init(ws: NWConnection) {
        self.ws = ws
        readLoop()
    }

    // MARK: - Frame parsing

    private func readLoop() {
        wsReceive(ws) { [weak self] data in
            guard let self = self, let data = data else { self?.shutdown(); return }
            self.handleFrame(data)
            self.readLoop()
        }
    }

    private func handleFrame(_ frame: Data) {
        guard frame.count >= 9 else { return }
        let op = frame[0]
        let id = frame.readU32LE(at: 1)
        let len = Int(frame.readU32LE(at: 5))
        guard frame.count >= 9 + len else { return }
        let payload = frame.subdata(in: 9..<(9 + len))

        switch op {
        case 0x01: handleConnect(id: id, payload: payload)
        case 0x02: handleData(id: id, payload: payload)
        case 0x03: handleClose(id: id)
        default: break
        }
    }

    // MARK: - Op handlers

    private func handleConnect(id: UInt32, payload: Data) {
        guard payload.count >= 6 else { sendErr(id, "short"); return }
        let proto = payload[1]
        let hostLen = Int(payload.readU16LE(at: 2))
        guard payload.count >= 4 + hostLen + 2 else { sendErr(id, "short"); return }
        let host = String(data: payload.subdata(in: 4..<(4 + hostLen)), encoding: .utf8) ?? ""
        let port = payload.readU16LE(at: 4 + hostLen)

        let endpoint = NWEndpoint.hostPort(host: .init(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let params: NWParameters = (proto == 17) ? .udp : .tcp
        let nw = NWConnection(to: endpoint, using: params)

        nw.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lock.lock(); self.conns[id] = nw; self.lock.unlock()
                self.sendOk(id)
                self.pumpFromSocket(id: id, nw: nw)
            case .failed(let e):
                self.sendErr(id, "\(e)")
            case .cancelled:
                self.sendClose(id)
            default: break
            }
        }
        nw.start(queue: .global(qos: .userInitiated))
    }

    private func handleData(id: UInt32, payload: Data) {
        lock.lock(); let nw = conns[id]; lock.unlock()
        nw?.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func handleClose(id: UInt32) {
        lock.lock(); let nw = conns.removeValue(forKey: id); lock.unlock()
        nw?.cancel()
    }

    // MARK: - Socket → WS pump

    private func pumpFromSocket(id: UInt32, nw: NWConnection) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.sendData(id, data)
            }
            if isComplete || error != nil {
                self.sendClose(id)
                self.lock.lock(); self.conns.removeValue(forKey: id); self.lock.unlock()
                nw.cancel()
                return
            }
            self.pumpFromSocket(id: id, nw: nw)
        }
    }

    // MARK: - Send helpers

    private func sendOk(_ id: UInt32)              { sendFrame(op: 0x04, id: id, payload: Data()) }
    private func sendErr(_ id: UInt32, _ s: String){ sendFrame(op: 0x05, id: id, payload: Data(s.utf8)) }
    private func sendData(_ id: UInt32, _ d: Data) { sendFrame(op: 0x02, id: id, payload: d) }
    private func sendClose(_ id: UInt32)           { sendFrame(op: 0x03, id: id, payload: Data()) }

    private func sendFrame(op: UInt8, id: UInt32, payload: Data) {
        var f = Data(); f.reserveCapacity(9 + payload.count)
        f.append(op)
        f.appendU32LE(id)
        f.appendU32LE(UInt32(payload.count))
        f.append(payload)
        wsSend(ws, f)
    }

    private func shutdown() {
        lock.lock(); for (_, nw) in conns { nw.cancel() }; conns.removeAll(); lock.unlock()
    }
}

// MARK: - Data extensions

extension Data {
    func readU16LE(at off: Int) -> UInt16 {
        UInt16(self[off]) | (UInt16(self[off+1]) << 8)
    }
    func readU32LE(at off: Int) -> UInt32 {
        UInt32(self[off])        | (UInt32(self[off+1]) << 8) |
        (UInt32(self[off+2]) << 16) | (UInt32(self[off+3]) << 24)
    }
    mutating func appendU32LE(_ v: UInt32) {
        append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff)); append(UInt8((v >> 24) & 0xff))
    }
}
