import Foundation
import WasmVMCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Translates raw-socket-over-WS frames into POSIX TCP socket I/O.
/// One instance per accepted WebSocket on the `/net` endpoint.
///
/// Wire format and op semantics are defined in `spec/03-net-bridge.md`.
/// Codec lives in `WasmVMCore.FrameCodec`.
public final class NetBridge {

    /// Abstract WebSocket connection the bridge speaks to.
    /// W7 supplies a Telegraph-backed adapter conforming to this; tests
    /// supply an in-process adapter or one wrapping URLSessionWebSocketTask.
    public protocol Socket: AnyObject {
        /// Send a single binary WebSocket message.
        func sendBinary(_ data: Data)
        /// Close the WebSocket. Idempotent.
        func close()
        /// Set by the consumer to receive incoming binary messages, one per call.
        var onBinary: ((Data) -> Void)? { get set }
        /// Set by the consumer to receive close events.
        var onClose: (() -> Void)? { get set }
    }

    private let socket: Socket
    private let table = ConnectionTable()
    /// Concurrent for parallel pumps + dialing across connections; per-connection
    /// write ordering is preserved by `writeQueues[id]` (one serial queue per id).
    private let workQueue = DispatchQueue(label: "com.wasmvm.netbridge.work", attributes: .concurrent)
    private let sendQueue = DispatchQueue(label: "com.wasmvm.netbridge.send")
    private var pumps: [UInt32: DispatchSourceRead] = [:]
    private var writeQueues: [UInt32: DispatchQueue] = [:]
    private let pumpsLock = NSLock()

    public init(socket: Socket) {
        self.socket = socket
        socket.onBinary = { [weak self] data in self?.handleIncoming(data) }
        socket.onClose  = { [weak self] in self?.shutdownAll() }
    }

    deinit {
        shutdownAll()
    }

    // MARK: - Frame ingest

    private func handleIncoming(_ data: Data) {
        let frame: Frame
        do { frame = try FrameCodec.decode(data) } catch {
            Log.net.error("frame decode failed: \(String(describing: error))")
            return
        }
        switch frame.op {
        case .connect: handleConnect(id: frame.connID, payload: frame.payload)
        case .data:    handleData(id: frame.connID, payload: frame.payload)
        case .close:   handleClose(id: frame.connID)
        case .listen:
            // spec/03 §"Listen/accept": MVP scope cut. Reply with CONNECT_ERR
            // so guest sees a clean failure rather than hanging.
            sendErr(id: frame.connID, reason: "LISTEN not supported in MVP")
        case .resolve:
            sendErr(id: frame.connID, reason: "RESOLVE not supported in MVP")
        default:
            // Host-direction ops (CONNECT_OK/ERR/ACCEPT/RESOLVE_OK) shouldn't be
            // received from guest; ignore.
            break
        }
    }

    // MARK: - CONNECT

    private func handleConnect(id: UInt32, payload: Data) {
        let cp: ConnectPayload
        do { cp = try FrameCodec.decodeConnectPayload(payload) } catch {
            sendErr(id: id, reason: "bad CONNECT payload")
            return
        }
        // Guard table cap before dialing; spec/03 §"Validation" caps 256.
        if table.count >= ConnectionTable.capacity {
            sendErr(id: id, reason: "connection cap exceeded")
            return
        }
        // Reject port=0 explicitly per bug-fix note (force-unwrap NWEndpoint.Port
        // would have crashed); POSIX connect to port 0 on Linux maps to a random
        // ephemeral but is undefined here.
        guard cp.port != 0 else {
            sendErr(id: id, reason: "port 0 not allowed")
            return
        }
        guard cp.proto == .tcp else {
            sendErr(id: id, reason: "UDP not supported in MVP")
            return
        }
        workQueue.async { [weak self] in
            self?.dialAndAttach(id: id, payload: cp)
        }
    }

    private func dialAndAttach(id: UInt32, payload: ConnectPayload) {
        let fd = posixDial(host: payload.host, port: payload.port, family: payload.family)
        switch fd {
        case .success(let fd):
            guard table.insert(id: id, fd: fd) else {
                _ = closeFd(fd)
                sendErr(id: id, reason: "duplicate conn_id or cap exceeded")
                return
            }
            sendOK(id: id)
            startPump(id: id, fd: fd)
        case .failure(let reason):
            sendErr(id: id, reason: reason)
        }
    }

    // MARK: - DATA / CLOSE from guest

    private func handleData(id: UInt32, payload: Data) {
        guard let fd = table.fd(for: id) else { return }
        // Per-connection serial queue preserves DATA frame ordering through write().
        // POSIX write may be partial; loop until consumed or error.
        writeQueueFor(id: id).async {
            var written = 0
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                while written < payload.count {
                    let n = sendAll(fd: fd,
                                    buf: base.advanced(by: written),
                                    len: payload.count - written)
                    if n <= 0 { break }
                    written += n
                }
            }
        }
    }

    private func writeQueueFor(id: UInt32) -> DispatchQueue {
        pumpsLock.lock(); defer { pumpsLock.unlock() }
        if let q = writeQueues[id] { return q }
        let q = DispatchQueue(label: "com.wasmvm.netbridge.write.\(id)")
        writeQueues[id] = q
        return q
    }

    private func handleClose(id: UInt32) {
        cancelPump(id: id)
        if let entry = table.remove(id: id) {
            // Half-close write side first so peer sees EOF, then full close.
            shutdownWrite(fd: entry.fd)
            _ = closeFd(entry.fd)
        }
    }

    // MARK: - Socket → WS pump

    private func startPump(id: UInt32, fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workQueue)
        let bufLen = 64 * 1024
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
            defer { buf.deallocate() }
            let n = recvOnce(fd: fd, buf: buf, len: bufLen)
            if n > 0 {
                let data = Data(bytes: buf, count: n)
                self.sendData(id: id, data: data)
            } else if n == 0 {
                // EOF from peer: emit CLOSE once, tear down.
                self.cancelPump(id: id)
                if self.table.markHostSentCloseIfNeeded(id: id) {
                    self.sendClose(id: id)
                }
                if let e = self.table.remove(id: id) {
                    _ = closeFd(e.fd)
                }
            } else {
                // n < 0: errno set; for EAGAIN/EWOULDBLOCK keep pumping; otherwise tear down.
                let e = currentErrno()
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return }
                self.cancelPump(id: id)
                if self.table.markHostSentCloseIfNeeded(id: id) {
                    self.sendClose(id: id)
                }
                if let entry = self.table.remove(id: id) {
                    _ = closeFd(entry.fd)
                }
            }
        }
        pumpsLock.lock()
        pumps[id] = source
        pumpsLock.unlock()
        source.resume()
    }

    private func cancelPump(id: UInt32) {
        pumpsLock.lock()
        let src = pumps.removeValue(forKey: id)
        writeQueues.removeValue(forKey: id)
        pumpsLock.unlock()
        src?.cancel()
    }

    // MARK: - Send helpers

    private func sendOK(id: UInt32) {
        sendFrame(.connectOK, id: id, payload: Data())
    }
    private func sendErr(id: UInt32, reason: String) {
        sendFrame(.connectErr, id: id, payload: Data(reason.utf8))
    }
    private func sendData(id: UInt32, data: Data) {
        sendFrame(.data, id: id, payload: data)
    }
    private func sendClose(id: UInt32) {
        sendFrame(.close, id: id, payload: Data())
    }

    private func sendFrame(_ op: FrameOp, id: UInt32, payload: Data) {
        let bytes = FrameCodec.encode(Frame(op: op, connID: id, payload: payload))
        sendQueue.async { [weak self] in
            self?.socket.sendBinary(bytes)
        }
    }

    // MARK: - Shutdown

    private func shutdownAll() {
        pumpsLock.lock()
        let allPumps = pumps
        pumps.removeAll()
        writeQueues.removeAll()
        pumpsLock.unlock()
        for (_, src) in allPumps { src.cancel() }

        for entry in table.removeAll() {
            _ = closeFd(entry.fd)
        }
    }
}

// MARK: - POSIX socket helpers (file-private; fully real OS calls)

private enum DialResult {
    case success(Int32)
    case failure(String)
}

private func posixDial(host: String, port: UInt16, family: ConnectPayload.Family) -> DialResult {
    var hints = addrinfo()
    hints.ai_family = (family == .ipv6) ? AF_INET6 : AF_UNSPEC
    hints.ai_socktype = sockType_STREAM
    var res: UnsafeMutablePointer<addrinfo>? = nil
    let portStr = String(port)
    let rc = getaddrinfo(host, portStr, &hints, &res)
    if rc != 0 || res == nil {
        return .failure("getaddrinfo: \(host):\(port)")
    }
    defer { freeaddrinfo(res) }

    var cur = res
    while let info = cur {
        let fd = socket(info.pointee.ai_family,
                        info.pointee.ai_socktype,
                        info.pointee.ai_protocol)
        if fd >= 0 {
            // Non-blocking so DispatchSourceRead can drain w/o blocking the queue.
            let connectRC = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if connectRC == 0 {
                _ = setNonBlocking(fd: fd)
                return .success(fd)
            }
            _ = closeFd(fd)
        }
        cur = info.pointee.ai_next
    }
    return .failure("connect failed: \(host):\(port)")
}

private func setNonBlocking(fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0 { return false }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
}

@inline(__always)
private func recvOnce(fd: Int32, buf: UnsafeMutablePointer<UInt8>, len: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, buf, len)
    #else
    return Glibc.read(fd, buf, len)
    #endif
}

@inline(__always)
private func sendAll(fd: Int32, buf: UnsafeRawPointer, len: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buf, len)
    #else
    return Glibc.write(fd, buf, len)
    #endif
}

@inline(__always)
private func closeFd(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

@inline(__always)
private func shutdownWrite(fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.shutdown(fd, Int32(SHUT_WR))
    #else
    _ = Glibc.shutdown(fd, Int32(SHUT_WR))
    #endif
}

@inline(__always)
private func currentErrno() -> Int32 {
    #if canImport(Darwin)
    return Darwin.errno
    #else
    return Glibc.errno
    #endif
}

private var sockType_STREAM: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}
