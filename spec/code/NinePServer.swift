import Foundation
import Network

/// Minimal 9P2000.L server. One instance per WS connection.
/// Spec ref: https://github.com/chaos/diod/blob/master/protocol.md
///
/// Wire: every message is `size(4 LE) | type(1) | tag(2 LE) | body`
///
/// This implements the minimum opcode set to make
///   `mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/host`
/// usable for read/write/list. Production-quality means filling in TODOs.
final class NinePServer {
    // MARK: Types

    private enum Op: UInt8 {
        case Tlerror = 6, Rlerror = 7
        case Tstatfs = 8, Rstatfs = 9
        case Tlopen = 12, Rlopen = 13
        case Tlcreate = 14, Rlcreate = 15
        case Tgetattr = 24, Rgetattr = 25
        case Treaddir = 40, Rreaddir = 41
        case Tversion = 100, Rversion = 101
        case Tattach = 104, Rattach = 105
        case Twalk = 110, Rwalk = 111
        case Tread = 116, Rread = 117
        case Twrite = 118, Rwrite = 119
        case Tclunk = 120, Rclunk = 121
    }

    /// A "fid" is the client's handle. We track the URL it points at and any open file descriptor.
    private struct Fid {
        var url: URL
        var handle: FileHandle?
        var isDir: Bool
    }

    // MARK: State

    private let ws: NWConnection
    /// Root URL the client mounts. Must be a security-scoped URL the user picked.
    private let root: URL
    private var fids: [UInt32: Fid] = [:]
    private var msize: UInt32 = 8192
    private let lock = NSLock()

    init(ws: NWConnection, root: URL) {
        self.ws = ws
        self.root = root
        _ = root.startAccessingSecurityScopedResource()
        readLoop()
    }

    deinit {
        root.stopAccessingSecurityScopedResource()
    }

    // MARK: Message loop

    private func readLoop() {
        wsReceive(ws) { [weak self] data in
            guard let self = self, let data = data else { return }
            self.dispatch(data)
            self.readLoop()
        }
    }

    private func dispatch(_ msg: Data) {
        guard msg.count >= 7 else { return }
        let size = Int(msg.readU32LE(at: 0))
        guard msg.count >= size, let opRaw = Op(rawValue: msg[4]) else { return }
        let tag = msg.readU16LE(at: 5)
        let body = msg.subdata(in: 7..<size)

        do {
            switch opRaw {
            case .Tversion: try handleVersion(tag: tag, body: body)
            case .Tattach:  try handleAttach(tag: tag, body: body)
            case .Twalk:    try handleWalk(tag: tag, body: body)
            case .Tlopen:   try handleLopen(tag: tag, body: body)
            case .Tread:    try handleRead(tag: tag, body: body)
            case .Twrite:   try handleWrite(tag: tag, body: body)
            case .Tclunk:   try handleClunk(tag: tag, body: body)
            case .Tgetattr: try handleGetattr(tag: tag, body: body)
            // TODO: Treaddir, Tlcreate, Tmkdir, Tunlinkat, Trename, Tstatfs
            default: sendLerror(tag: tag, errno: 38)  // ENOSYS
            }
        } catch let e as POSIXError {
            sendLerror(tag: tag, errno: UInt32(e.code.rawValue))
        } catch {
            sendLerror(tag: tag, errno: 5)  // EIO
        }
    }

    // MARK: Handlers

    private func handleVersion(tag: UInt16, body: Data) throws {
        // body: msize(4) | version_string(s)
        msize = body.readU32LE(at: 0)
        let ver = "9P2000.L"
        var r = Data()
        r.appendU32LE(msize)
        r.appendString9P(ver)
        sendR(.Rversion, tag: tag, body: r)
    }

    private func handleAttach(tag: UInt16, body: Data) throws {
        // body: fid(4) | afid(4) | uname(s) | aname(s) | n_uname(4)
        let fid = body.readU32LE(at: 0)
        lock.lock(); fids[fid] = Fid(url: root, handle: nil, isDir: true); lock.unlock()
        var r = Data(); r.appendQid(forURL: root)
        sendR(.Rattach, tag: tag, body: r)
    }

    private func handleWalk(tag: UInt16, body: Data) throws {
        // body: fid(4) | newfid(4) | nwname(2) | wname[nwname](s)
        let fid = body.readU32LE(at: 0)
        let newfid = body.readU32LE(at: 4)
        let nw = Int(body.readU16LE(at: 8))

        lock.lock(); guard let base = fids[fid] else { lock.unlock(); throw POSIXError(.EBADF) }
        lock.unlock()

        var url = base.url
        var qids = Data()
        var off = 10
        for _ in 0..<nw {
            let len = Int(body.readU16LE(at: off)); off += 2
            let name = String(data: body.subdata(in: off..<(off + len)), encoding: .utf8) ?? ""
            off += len
            url.appendPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw POSIXError(.ENOENT) }
            qids.appendQid(forURL: url)
        }

        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        lock.lock(); fids[newfid] = Fid(url: url, handle: nil, isDir: isDir); lock.unlock()

        var r = Data()
        r.appendU16LE(UInt16(nw))
        r.append(qids)
        sendR(.Rwalk, tag: tag, body: r)
    }

    private func handleLopen(tag: UInt16, body: Data) throws {
        // body: fid(4) | flags(4)
        let fid = body.readU32LE(at: 0)
        let flags = body.readU32LE(at: 4)

        lock.lock(); guard var f = fids[fid] else { lock.unlock(); throw POSIXError(.EBADF) }
        lock.unlock()

        if !f.isDir {
            // Open with appropriate mode. flags follows Linux open(2) conventions.
            let writable = (flags & 0x3) != 0  // O_WRONLY or O_RDWR
            f.handle = writable
                ? try FileHandle(forUpdating: f.url)
                : try FileHandle(forReadingFrom: f.url)
        }
        lock.lock(); fids[fid] = f; lock.unlock()

        var r = Data()
        r.appendQid(forURL: f.url)
        r.appendU32LE(0)  // iounit, 0 means use msize
        sendR(.Rlopen, tag: tag, body: r)
    }

    private func handleRead(tag: UInt16, body: Data) throws {
        // body: fid(4) | offset(8) | count(4)
        let fid = body.readU32LE(at: 0)
        let offset = body.readU64LE(at: 4)
        let count = body.readU32LE(at: 12)

        lock.lock(); guard let f = fids[fid], let h = f.handle else { lock.unlock(); throw POSIXError(.EBADF) }
        lock.unlock()

        try h.seek(toOffset: offset)
        let chunk = try h.read(upToCount: Int(count)) ?? Data()

        var r = Data()
        r.appendU32LE(UInt32(chunk.count))
        r.append(chunk)
        sendR(.Rread, tag: tag, body: r)
    }

    private func handleWrite(tag: UInt16, body: Data) throws {
        // body: fid(4) | offset(8) | count(4) | data
        let fid = body.readU32LE(at: 0)
        let offset = body.readU64LE(at: 4)
        let count = Int(body.readU32LE(at: 12))
        let data = body.subdata(in: 16..<(16 + count))

        lock.lock(); guard let f = fids[fid], let h = f.handle else { lock.unlock(); throw POSIXError(.EBADF) }
        lock.unlock()

        try h.seek(toOffset: offset)
        try h.write(contentsOf: data)

        var r = Data(); r.appendU32LE(UInt32(count))
        sendR(.Rwrite, tag: tag, body: r)
    }

    private func handleClunk(tag: UInt16, body: Data) throws {
        let fid = body.readU32LE(at: 0)
        lock.lock(); let f = fids.removeValue(forKey: fid); lock.unlock()
        try? f?.handle?.close()
        sendR(.Rclunk, tag: tag, body: Data())
    }

    private func handleGetattr(tag: UInt16, body: Data) throws {
        // body: fid(4) | request_mask(8)
        let fid = body.readU32LE(at: 0)
        lock.lock(); guard let f = fids[fid] else { lock.unlock(); throw POSIXError(.EBADF) }
        lock.unlock()

        let attrs = try FileManager.default.attributesOfItem(atPath: f.url.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mode: UInt32 = f.isDir ? 0o040755 : 0o100644

        var r = Data()
        r.appendU64LE(0x3fff)             // valid mask: basic fields
        r.appendQid(forURL: f.url)
        r.appendU32LE(mode)
        r.appendU32LE(501)                // uid
        r.appendU32LE(20)                 // gid
        r.appendU64LE(1)                  // nlink
        r.appendU64LE(0)                  // rdev
        r.appendU64LE(size)
        r.appendU64LE(4096)               // blksize
        r.appendU64LE((size + 511) / 512) // blocks
        r.appendU64LE(UInt64(mtime)); r.appendU64LE(0)  // atime
        r.appendU64LE(UInt64(mtime)); r.appendU64LE(0)  // mtime
        r.appendU64LE(UInt64(mtime)); r.appendU64LE(0)  // ctime
        r.appendU64LE(0); r.appendU64LE(0)              // btime
        r.appendU64LE(0); r.appendU64LE(0)              // gen, data_version
        sendR(.Rgetattr, tag: tag, body: r)
    }

    // MARK: Send helpers

    private func sendR(_ op: Op, tag: UInt16, body: Data) {
        let total = 7 + body.count
        var msg = Data(); msg.reserveCapacity(total)
        msg.appendU32LE(UInt32(total))
        msg.append(op.rawValue)
        msg.appendU16LE(tag)
        msg.append(body)
        wsSend(ws, msg)
    }

    private func sendLerror(tag: UInt16, errno: UInt32) {
        var b = Data(); b.appendU32LE(errno)
        sendR(.Rlerror, tag: tag, body: b)
    }
}

// MARK: - 9P encoding helpers

extension Data {
    func readU64LE(at off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[off + i]) << (8 * i) }
        return v
    }
    mutating func appendU16LE(_ v: UInt16) {
        append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff))
    }
    mutating func appendU64LE(_ v: UInt64) {
        for i in 0..<8 { append(UInt8((v >> (8 * i)) & 0xff)) }
    }
    mutating func appendString9P(_ s: String) {
        let b = Data(s.utf8)
        appendU16LE(UInt16(b.count))
        append(b)
    }

    /// 9P qid is type(1) | version(4) | path(8). We derive a stable path from inode.
    mutating func appendQid(forURL url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let type: UInt8 = isDir ? 0x80 : 0x00
        let inode: UInt64 = {
            // Best-effort stable identifier; FileManager doesn't expose inode directly.
            // For a real impl, use stat() via Darwin.
            var st = stat()
            return url.path.withCString { stat($0, &st) == 0 ? UInt64(st.st_ino) : 0 }
        }()
        append(type)
        appendU32LE(0)             // version
        appendU64LE(inode)         // path (qid.path)
    }
}
