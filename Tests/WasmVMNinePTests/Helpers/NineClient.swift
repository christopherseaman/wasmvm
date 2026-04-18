import Foundation
@testable import WasmVMCore
@testable import WasmVMNineP

/// Minimal in-process Swift 9P2000.L client for NinePServer integration tests.
/// Built on top of WasmVMCore.NinePCodec — exercises the same wire format as
/// the Linux kernel's 9p client, just from Swift.
///
/// Synchronous request/response semantics: send a T-message, wait on the
/// matching R-message by tag with a timeout. One outstanding request at a
/// time per client (we use unique tags but only block one caller).
final class NineClient {
    private let socket: NinePPipeSocket
    private var nextTag: UInt16 = 1
    private let lock = NSLock()
    private var pending: [UInt16: (NinePMessage) -> Void] = [:]

    init(socket: NinePPipeSocket) {
        self.socket = socket
        socket.onBinary = { [weak self] data in self?.deliver(data) }
    }

    private func deliver(_ data: Data) {
        guard let msg = try? NinePCodec.decode(data) else { return }
        lock.lock()
        let cb = pending.removeValue(forKey: msg.tag)
        lock.unlock()
        cb?(msg)
    }

    func request(_ op: NinePOp, body: Data, timeout: TimeInterval = 5.0) throws -> NinePMessage {
        lock.lock()
        let tag = nextTag
        nextTag &+= 1
        if nextTag == 0 { nextTag = 1 }
        lock.unlock()

        let sema = DispatchSemaphore(value: 0)
        var result: NinePMessage?
        lock.lock()
        pending[tag] = { msg in result = msg; sema.signal() }
        lock.unlock()

        socket.sendBinary(NinePCodec.encode(NinePMessage(op: op, tag: tag, body: body)))
        let r = sema.wait(timeout: .now() + timeout)
        if r == .timedOut {
            lock.lock(); pending.removeValue(forKey: tag); lock.unlock()
            throw NSError(domain: "NineClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "timeout waiting for R-msg for op \(op)"])
        }
        return result!
    }

    /// Convenience: throws if reply was Rlerror.
    @discardableResult
    func call(_ op: NinePOp, body: Data, timeout: TimeInterval = 5.0) throws -> NinePMessage {
        let r = try request(op, body: body, timeout: timeout)
        if r.op == .Rlerror {
            let errno = r.body.readU32LE(at: 0) ?? 5
            throw NinePLerror(errno: errno)
        }
        return r
    }

    // MARK: - Op helpers

    func tversion(msize: UInt32 = 65536) throws -> (UInt32, String) {
        var b = Data()
        b.appendU32LE(msize)
        NinePCodec.appendString("9P2000.L", to: &b)
        let r = try call(.Tversion, body: b)
        let m = r.body.readU32LE(at: 0)!
        let (s, _) = try NinePCodec.readString(in: r.body, at: 4)
        return (m, s)
    }

    func tattach(fid: UInt32, afid: UInt32 = 0xffffffff,
                 uname: String = "user", aname: String = "/", n_uname: UInt32 = 1000) throws -> Qid {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU32LE(afid)
        NinePCodec.appendString(uname, to: &b)
        NinePCodec.appendString(aname, to: &b)
        b.appendU32LE(n_uname)
        let r = try call(.Tattach, body: b)
        let (q, _) = try NinePCodec.readQid(in: r.body, at: 0)
        return q
    }

    func twalk(fid: UInt32, newfid: UInt32, names: [String]) throws -> [Qid] {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU32LE(newfid)
        b.appendU16LE(UInt16(names.count))
        for n in names { NinePCodec.appendString(n, to: &b) }
        let r = try call(.Twalk, body: b)
        let count = Int(r.body.readU16LE(at: 0)!)
        var qids: [Qid] = []
        var off = 2
        for _ in 0..<count {
            let (q, n) = try NinePCodec.readQid(in: r.body, at: off)
            qids.append(q)
            off = n
        }
        return qids
    }

    /// Returns Rlerror errno, OR throws on transport timeout.
    func twalkExpectingError(fid: UInt32, newfid: UInt32, names: [String]) throws -> UInt32 {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU32LE(newfid)
        b.appendU16LE(UInt16(names.count))
        for n in names { NinePCodec.appendString(n, to: &b) }
        let r = try request(.Twalk, body: b)
        if r.op == .Rlerror {
            return r.body.readU32LE(at: 0) ?? 5
        }
        // Server returned a partial-prefix Rwalk — for tests that expected error,
        // surface that as a sentinel (0 means "no error").
        return 0
    }

    func tlopen(fid: UInt32, flags: UInt32) throws -> (Qid, UInt32) {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU32LE(flags)
        let r = try call(.Tlopen, body: b)
        let (q, off) = try NinePCodec.readQid(in: r.body, at: 0)
        let iounit = r.body.readU32LE(at: off)!
        return (q, iounit)
    }

    func tlcreate(fid: UInt32, name: String, flags: UInt32, mode: UInt32, gid: UInt32) throws -> (Qid, UInt32) {
        var b = Data()
        b.appendU32LE(fid)
        NinePCodec.appendString(name, to: &b)
        b.appendU32LE(flags)
        b.appendU32LE(mode)
        b.appendU32LE(gid)
        let r = try call(.Tlcreate, body: b)
        let (q, off) = try NinePCodec.readQid(in: r.body, at: 0)
        let iounit = r.body.readU32LE(at: off)!
        return (q, iounit)
    }

    func tread(fid: UInt32, offset: UInt64, count: UInt32) throws -> Data {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU64LE(offset)
        b.appendU32LE(count)
        let r = try call(.Tread, body: b)
        let n = Int(r.body.readU32LE(at: 0)!)
        return r.body.subdata(in: 4..<(4 + n))
    }

    func twrite(fid: UInt32, offset: UInt64, data: Data) throws -> UInt32 {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU64LE(offset)
        b.appendU32LE(UInt32(data.count))
        b.append(data)
        let r = try call(.Twrite, body: b)
        return r.body.readU32LE(at: 0)!
    }

    func tclunk(fid: UInt32) throws {
        var b = Data()
        b.appendU32LE(fid)
        try call(.Tclunk, body: b)
    }

    func tmkdir(dfid: UInt32, name: String, mode: UInt32, gid: UInt32) throws -> Qid {
        var b = Data()
        b.appendU32LE(dfid)
        NinePCodec.appendString(name, to: &b)
        b.appendU32LE(mode)
        b.appendU32LE(gid)
        let r = try call(.Tmkdir, body: b)
        let (q, _) = try NinePCodec.readQid(in: r.body, at: 0)
        return q
    }

    func tunlinkat(dfid: UInt32, name: String, flags: UInt32) throws {
        var b = Data()
        b.appendU32LE(dfid)
        NinePCodec.appendString(name, to: &b)
        b.appendU32LE(flags)
        try call(.Tunlinkat, body: b)
    }

    func treaddir(fid: UInt32, offset: UInt64, count: UInt32) throws -> [(Qid, UInt64, UInt8, String)] {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU64LE(offset)
        b.appendU32LE(count)
        let r = try call(.Treaddir, body: b)
        let n = Int(r.body.readU32LE(at: 0)!)
        let raw = r.body.subdata(in: 4..<(4 + n))
        var out: [(Qid, UInt64, UInt8, String)] = []
        var off = 0
        while off < raw.count {
            let (q, next1) = try NinePCodec.readQid(in: raw, at: off)
            let nextOff = raw.readU64LE(at: next1)!
            let typ = raw.readU8(at: next1 + 8)!
            let (name, end) = try NinePCodec.readString(in: raw, at: next1 + 9)
            out.append((q, nextOff, typ, name))
            off = end
        }
        return out
    }

    func tgetattr(fid: UInt32, requestMask: UInt64 = 0x3fff) throws -> Getattr {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU64LE(requestMask)
        let r = try call(.Tgetattr, body: b)
        let valid = r.body.readU64LE(at: 0)!
        let (qid, off) = try NinePCodec.readQid(in: r.body, at: 8)
        let mode = r.body.readU32LE(at: off)!
        let uid = r.body.readU32LE(at: off + 4)!
        let gid = r.body.readU32LE(at: off + 8)!
        let nlink = r.body.readU64LE(at: off + 12)!
        let rdev = r.body.readU64LE(at: off + 20)!
        let size = r.body.readU64LE(at: off + 28)!
        return Getattr(valid: valid, qid: qid, mode: mode, uid: uid, gid: gid,
                       nlink: nlink, rdev: rdev, size: size)
    }

    func tsetattr(fid: UInt32, valid: UInt32, mode: UInt32 = 0, size: UInt64 = 0) throws {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU32LE(valid)
        b.appendU32LE(mode)
        b.appendU32LE(0) // uid
        b.appendU32LE(0) // gid
        b.appendU64LE(size)
        b.appendU64LE(0); b.appendU64LE(0)  // atime
        b.appendU64LE(0); b.appendU64LE(0)  // mtime
        try call(.Tsetattr, body: b)
    }

    func tfsync(fid: UInt32) throws {
        var b = Data()
        b.appendU32LE(fid)
        b.appendU32LE(0)
        try call(.Tfsync, body: b)
    }

    func tstatfs(fid: UInt32) throws -> NinePMessage {
        var b = Data()
        b.appendU32LE(fid)
        return try call(.Tstatfs, body: b)
    }
}

struct Getattr {
    let valid: UInt64
    let qid: Qid
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let nlink: UInt64
    let rdev: UInt64
    let size: UInt64
}

struct NinePLerror: Error, Equatable {
    let errno: UInt32
}
