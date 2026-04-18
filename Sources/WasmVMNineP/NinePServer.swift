import Foundation
import WasmVMCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 9P2000.L server backed by a security-scoped iOS `URL`.
/// One instance per accepted WebSocket on the `/9p` endpoint.
///
/// Wire format and op semantics are defined in `spec/04-ninep-server.md`.
/// Codec lives in `WasmVMCore.NinePCodec`.
public final class NinePServer {

    /// Abstract WebSocket connection the server speaks to.
    /// Same shape as `NetBridge.Socket` — kept independent so the two modules
    /// don't import each other.
    public protocol Socket: AnyObject {
        func sendBinary(_ data: Data)
        func close()
        var onBinary: ((Data) -> Void)? { get set }
        var onClose: (() -> Void)? { get set }
    }

    /// spec/04 line 198: clamp client-proposed msize to a server-defined ceiling.
    public static let msizeCeiling: UInt32 = 65536

    /// Generic Linux uid/gid reported in Tgetattr — matches the base disk image's
    /// `user` per project decision; spec/04 fix list says don't hand back macOS 501/20.
    public static let reportedUID: UInt32 = 1000
    public static let reportedGID: UInt32 = 1000

    /// Mask used for getattr_valid bits (basic POSIX fields).
    /// 0x000007ff covers MODE..BTIME, which is what we populate.
    private static let getattrValidBasic: UInt64 = 0x0000_07ff

    private let socket: Socket
    private let root: URL
    private let fids = FidTable()
    private var negotiated_msize: UInt32 = 8192
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.wasmvm.ninep.work")

    public init(socket: Socket, root: URL) {
        self.socket = socket
        self.root = root.standardized
        #if canImport(Darwin)
        _ = self.root.startAccessingSecurityScopedResource()
        #endif
        socket.onBinary = { [weak self] data in self?.dispatch(data) }
        socket.onClose  = { [weak self] in self?.shutdown() }
    }

    deinit {
        shutdown()
        #if canImport(Darwin)
        root.stopAccessingSecurityScopedResource()
        #endif
    }

    // MARK: - Dispatch

    private func dispatch(_ data: Data) {
        let msg: NinePMessage
        do { msg = try NinePCodec.decode(data) } catch {
            Log.ninep.error("9P decode failed: \(String(describing: error))")
            return
        }
        workQueue.async { [weak self] in
            self?.handle(msg)
        }
    }

    private func handle(_ msg: NinePMessage) {
        do {
            switch msg.op {
            case .Tversion:  try handleVersion(tag: msg.tag, body: msg.body)
            case .Tattach:   try handleAttach(tag: msg.tag, body: msg.body)
            case .Twalk:     try handleWalk(tag: msg.tag, body: msg.body)
            case .Tlopen:    try handleLopen(tag: msg.tag, body: msg.body)
            case .Tlcreate:  try handleLcreate(tag: msg.tag, body: msg.body)
            case .Tread:     try handleRead(tag: msg.tag, body: msg.body)
            case .Twrite:    try handleWrite(tag: msg.tag, body: msg.body)
            case .Tclunk:    try handleClunk(tag: msg.tag, body: msg.body)
            case .Tgetattr:  try handleGetattr(tag: msg.tag, body: msg.body)
            case .Tsetattr:  try handleSetattr(tag: msg.tag, body: msg.body)
            case .Treaddir:  try handleReaddir(tag: msg.tag, body: msg.body)
            case .Tmkdir:    try handleMkdir(tag: msg.tag, body: msg.body)
            case .Tunlinkat: try handleUnlinkat(tag: msg.tag, body: msg.body)
            case .Tstatfs:   try handleStatfs(tag: msg.tag, body: msg.body)
            case .Tfsync:    try handleFsync(tag: msg.tag, body: msg.body)
            default:
                sendLerror(tag: msg.tag, errno: LinuxErrno.ENOSYS)
            }
        } catch let e as WalkError {
            switch e {
            case .invalidComponent: sendLerror(tag: msg.tag, errno: .EINVAL)
            case .escapesRoot:      sendLerror(tag: msg.tag, errno: .EACCES)
            case .nameTooLong:      sendLerror(tag: msg.tag, errno: .ENAMETOOLONG)
            case .tooDeep:          sendLerror(tag: msg.tag, errno: .EINVAL)
            }
        } catch {
            let mapped = ErrnoMap.errno(for: error)
            sendLerror(tag: msg.tag, errno: mapped)
        }
    }

    // MARK: - Handlers

    /// Tversion — body: msize(4) | version(s)
    /// Per spec/04 line 198, msize = min(client_proposed, ceiling).
    /// Tversion is also a session reset: clear all FIDs.
    private func handleVersion(tag: UInt16, body: Data) throws {
        guard let proposed = body.readU32LE(at: 0) else {
            throw POSIXError(.EINVAL)
        }
        let clamped = min(proposed, NinePServer.msizeCeiling)
        // Drop any prior session state including open file handles.
        for f in fids.removeAll() {
            try? f.handle?.close()
        }
        lock.lock(); negotiated_msize = clamped; lock.unlock()

        var r = Data()
        r.appendU32LE(clamped)
        NinePCodec.appendString("9P2000.L", to: &r)
        sendR(.Rversion, tag: tag, body: r)
    }

    /// Tattach — body: fid(4) | afid(4) | uname(s) | aname(s) | n_uname(4)
    private func handleAttach(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        let qid = try QidBuilder.qid(for: root)
        guard fids.put(fid, Fid(url: root, handle: nil, isDir: true, dirCursor: nil)) else {
            throw POSIXError(.ENOMEM)
        }
        var r = Data()
        NinePCodec.appendQid(qid, to: &r)
        sendR(.Rattach, tag: tag, body: r)
    }

    /// Twalk — body: fid(4) | newfid(4) | nwname(2) | wname[nwname](s)
    /// Per spec/04, partial failure must NOT establish newfid; build qids in
    /// a temp accumulator and only commit when the full walk succeeds.
    /// Return the prefix of qids that succeeded so client can recover.
    private func handleWalk(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0),
              let newfid = body.readU32LE(at: 4),
              let nw = body.readU16LE(at: 8) else {
            throw POSIXError(.EINVAL)
        }
        guard let base = fids.get(fid) else { throw POSIXError(.EBADF) }

        // Parse + validate names first; bail on protocol-level invalidity (no Rwalk).
        var names: [String] = []
        var off = 10
        for _ in 0..<Int(nw) {
            let (s, next) = try NinePCodec.readString(in: body, at: off)
            names.append(s)
            off = next
        }
        try Walk.validateComponents(names)

        // Walk component-by-component, building a qid per success. On the first
        // ENOENT, return the partial prefix (Rwalk with fewer qids than nwname);
        // newfid is NOT established in that case.
        var url = base.url
        var qids: [Qid] = []
        var fullSuccess = true
        for n in names {
            url.appendPathComponent(n)
            let canonical = url.standardized
            // Defensive — even if validateComponent rejects ".."/"." at the
            // string level, symlink resolution could pull us out of root.
            if !pathInRoot(canonical) {
                if qids.isEmpty { throw POSIXError(.EACCES) }
                fullSuccess = false
                break
            }
            do {
                let qid = try QidBuilder.qid(for: canonical)
                qids.append(qid)
                url = canonical
            } catch {
                if qids.isEmpty { throw POSIXError(.ENOENT) }
                fullSuccess = false
                break
            }
        }

        // Commit newfid only on full success (or zero-component clone).
        if fullSuccess {
            // Twalk(nwname=0) clones the FID at the same URL.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // If newfid == fid and it has no open handle, the spec allows in-place replace.
            if newfid != fid {
                if fids.get(newfid) != nil { throw POSIXError(.EBADF) }
            } else {
                if base.handle != nil { throw POSIXError(.EBADF) }
            }
            guard fids.put(newfid, Fid(url: url, handle: nil, isDir: isDir, dirCursor: nil)) else {
                throw POSIXError(.ENOMEM)
            }
        }

        var r = Data()
        r.appendU16LE(UInt16(qids.count))
        for q in qids { NinePCodec.appendQid(q, to: &r) }
        sendR(.Rwalk, tag: tag, body: r)
    }

    /// Tlopen — body: fid(4) | flags(4)
    private func handleLopen(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0),
              let flags = body.readU32LE(at: 4) else {
            throw POSIXError(.EINVAL)
        }
        guard let f = fids.get(fid) else { throw POSIXError(.EBADF) }

        var handle: FileHandle? = nil
        if !f.isDir {
            let writable = (flags & 0x3) != 0  // O_WRONLY=1, O_RDWR=2
            // O_TRUNC=01000 in Linux; we don't track flags but honor it best-effort.
            let truncate = (flags & 0o1000) != 0
            handle = try writable
                ? FileHandle(forUpdating: f.url)
                : FileHandle(forReadingFrom: f.url)
            if truncate, let h = handle {
                try h.truncate(atOffset: 0)
            }
        }
        let qid = try QidBuilder.qid(for: f.url)
        fids.mutate(fid) { $0.handle = handle }

        var r = Data()
        NinePCodec.appendQid(qid, to: &r)
        r.appendU32LE(0)   // iounit = 0 means "use msize-header"
        sendR(.Rlopen, tag: tag, body: r)
    }

    /// Tlcreate — body: fid(4) | name(s) | flags(4) | mode(4) | gid(4)
    /// fid must refer to a directory; on success, fid becomes the new file
    /// (URL replaced) with an open handle.
    private func handleLcreate(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        let (name, next) = try NinePCodec.readString(in: body, at: 4)
        guard let _ = body.readU32LE(at: next),
              let mode = body.readU32LE(at: next + 4),
              let _ = body.readU32LE(at: next + 8) else {
            throw POSIXError(.EINVAL)
        }
        guard let parent = fids.get(fid), parent.isDir else { throw POSIXError(.ENOTDIR) }
        try Walk.validateComponent(name)
        let target = parent.url.appendingPathComponent(name).standardized
        guard pathInRoot(target) else { throw POSIXError(.EACCES) }

        let perm = mode_t(mode & 0o7777)
        let fd = target.path.withCString { open($0, O_CREAT | O_RDWR | O_EXCL, perm) }
        if fd < 0 { throw POSIXError(currentErrnoCode()) }
        _ = close(fd)

        let handle = try FileHandle(forUpdating: target)
        let qid = try QidBuilder.qid(for: target)

        // fid now refers to the new file with an open handle (per spec).
        fids.put(fid, Fid(url: target, handle: handle, isDir: false, dirCursor: nil))

        var r = Data()
        NinePCodec.appendQid(qid, to: &r)
        r.appendU32LE(0)   // iounit
        sendR(.Rlcreate, tag: tag, body: r)
    }

    /// Tread — body: fid(4) | offset(8) | count(4)
    private func handleRead(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0),
              let offset = body.readU64LE(at: 4),
              let count = body.readU32LE(at: 12) else {
            throw POSIXError(.EINVAL)
        }
        guard let f = fids.get(fid), let h = f.handle else { throw POSIXError(.EBADF) }
        try h.seek(toOffset: offset)
        let chunk = try h.read(upToCount: Int(count)) ?? Data()

        var r = Data()
        r.appendU32LE(UInt32(chunk.count))
        r.append(chunk)
        sendR(.Rread, tag: tag, body: r)
    }

    /// Twrite — body: fid(4) | offset(8) | count(4) | data
    private func handleWrite(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0),
              let offset = body.readU64LE(at: 4),
              let count = body.readU32LE(at: 12) else {
            throw POSIXError(.EINVAL)
        }
        let dataStart = 16
        guard dataStart + Int(count) <= body.count else { throw POSIXError(.EINVAL) }
        let payload = body.subdata(in: dataStart..<(dataStart + Int(count)))

        guard let f = fids.get(fid), let h = f.handle else { throw POSIXError(.EBADF) }
        try h.seek(toOffset: offset)
        try h.write(contentsOf: payload)

        var r = Data()
        r.appendU32LE(UInt32(count))
        sendR(.Rwrite, tag: tag, body: r)
    }

    /// Tclunk — body: fid(4)
    /// Idempotent: succeed even on garbage FID.
    private func handleClunk(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        if let f = fids.remove(fid) {
            try? f.handle?.close()
        }
        sendR(.Rclunk, tag: tag, body: Data())
    }

    /// Tgetattr — body: fid(4) | request_mask(8)
    private func handleGetattr(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        guard let f = fids.get(fid) else { throw POSIXError(.EBADF) }

        let st = try QidBuilder.statOf(f.url)
        let qid = try QidBuilder.qid(for: f.url)

        var r = Data()
        r.appendU64LE(NinePServer.getattrValidBasic)
        NinePCodec.appendQid(qid, to: &r)
        r.appendU32LE(UInt32(st.st_mode))
        r.appendU32LE(NinePServer.reportedUID)
        r.appendU32LE(NinePServer.reportedGID)
        r.appendU64LE(UInt64(st.st_nlink))
        r.appendU64LE(UInt64(st.st_rdev))
        r.appendU64LE(UInt64(st.st_size))
        r.appendU64LE(UInt64(st.st_blksize))
        r.appendU64LE(UInt64(st.st_blocks))
        let (atimeSec, atimeNsec) = atimeFields(st)
        let (mtimeSec, mtimeNsec) = mtimeFields(st)
        let (ctimeSec, ctimeNsec) = ctimeFields(st)
        r.appendU64LE(atimeSec); r.appendU64LE(atimeNsec)
        r.appendU64LE(mtimeSec); r.appendU64LE(mtimeNsec)
        r.appendU64LE(ctimeSec); r.appendU64LE(ctimeNsec)
        r.appendU64LE(0); r.appendU64LE(0)   // btime
        r.appendU64LE(0); r.appendU64LE(0)   // gen, data_version
        sendR(.Rgetattr, tag: tag, body: r)
    }

    /// Tsetattr — body: fid(4) | valid(4) | mode(4) | uid(4) | gid(4) | size(8)
    ///               | atime_sec(8) | atime_nsec(8) | mtime_sec(8) | mtime_nsec(8)
    /// Required for chmod/touch/truncate/vim save.
    private func handleSetattr(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0),
              let valid = body.readU32LE(at: 4),
              let mode = body.readU32LE(at: 8),
              let _ = body.readU32LE(at: 12),
              let _ = body.readU32LE(at: 16),
              let size = body.readU64LE(at: 20) else {
            throw POSIXError(.EINVAL)
        }
        guard let f = fids.get(fid) else { throw POSIXError(.EBADF) }

        // Linux p9_setattr valid bits: MODE=0x1, UID=0x2, GID=0x4, SIZE=0x8,
        // ATIME=0x10, MTIME=0x20, CTIME=0x40, ATIME_SET=0x80, MTIME_SET=0x100.
        if (valid & 0x1) != 0 {
            let rc = f.url.path.withCString { chmod($0, mode_t(mode & 0o7777)) }
            if rc != 0 { throw POSIXError(currentErrnoCode()) }
        }
        if (valid & 0x8) != 0 {
            // Truncate the file (or via open handle if present).
            if let h = f.handle {
                try h.truncate(atOffset: size)
            } else {
                let rc = f.url.path.withCString { truncate($0, off_t(size)) }
                if rc != 0 { throw POSIXError(currentErrnoCode()) }
            }
        }
        // ATIME/MTIME — accept and best-effort apply via utimes if requested.
        // For MVP we ignore time fields; touch's main use returns OK and the
        // file already exists with current mtime which is close enough.

        sendR(.Rsetattr, tag: tag, body: Data())
    }

    /// Treaddir — body: fid(4) | offset(8) | count(4)
    /// Per spec/04 §"Directory reading semantics", snapshot on first read.
    /// Entries: qid(13) | offset(8) | type(1) | name(s)
    private func handleReaddir(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0),
              let offset = body.readU64LE(at: 4),
              let count = body.readU32LE(at: 12) else {
            throw POSIXError(.EINVAL)
        }
        guard let f = fids.get(fid), f.isDir else { throw POSIXError(.ENOTDIR) }

        var cursor = f.dirCursor
        if cursor == nil {
            cursor = try ReaddirCursor.snapshot(of: f.url)
            fids.mutate(fid) { $0.dirCursor = cursor }
        }
        guard let entries = cursor?.entries else { throw POSIXError(.EIO) }

        // Synthetic dot / dotdot occupy offsets 0 and 1.
        // Real entries start at offset 2 → entries[offset - 2].
        var entryBytes = Data()
        let limit = Int(count)
        var emitted: UInt64 = offset

        func tryEmit(name: String, url: URL, kindForFallback: Qid.Kind) -> Bool {
            let qid: Qid
            let dt: UInt8
            do {
                let st = try QidBuilder.statOf(url)
                qid = Qid(kind: QidBuilder_kindForMode(st.st_mode),
                          version: 0,
                          path: UInt64(st.st_ino))
                dt = QidBuilder.dtType(forMode: st.st_mode)
            } catch {
                // File vanished between snapshot and read; emit a synthesized entry.
                qid = Qid(kind: kindForFallback, version: 0, path: 0)
                dt = (kindForFallback == .dir) ? 4 : 8
            }
            let nameBytes = Data(name.utf8)
            let oneEntry = NinePCodec.qidSize + 8 + 1 + 2 + nameBytes.count
            if entryBytes.count + oneEntry > limit { return false }
            NinePCodec.appendQid(qid, to: &entryBytes)
            emitted += 1
            entryBytes.appendU64LE(emitted)
            entryBytes.appendU8(dt)
            NinePCodec.appendString(name, to: &entryBytes)
            return true
        }

        // Synthetic entries
        var idx = offset
        if idx == 0 {
            if !tryEmit(name: ".", url: f.url, kindForFallback: .dir) { idx = 0 }
            else { idx = 1 }
        }
        if idx == 1 {
            let parent = f.url.deletingLastPathComponent()
            let parentURL = pathInRoot(parent.standardized) ? parent : f.url
            if !tryEmit(name: "..", url: parentURL, kindForFallback: .dir) {
                // emit count limit hit, idx unchanged
            } else {
                idx = 2
            }
        }
        var i = Int(idx) - 2
        while i >= 0 && i < entries.count {
            let name = entries[i]
            let child = f.url.appendingPathComponent(name)
            if !tryEmit(name: name, url: child, kindForFallback: .file) { break }
            i += 1
        }

        var r = Data()
        r.appendU32LE(UInt32(entryBytes.count))
        r.append(entryBytes)
        sendR(.Rreaddir, tag: tag, body: r)
    }

    /// Tmkdir — body: dfid(4) | name(s) | mode(4) | gid(4)
    /// Reply: qid(13)
    private func handleMkdir(tag: UInt16, body: Data) throws {
        guard let dfid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        let (name, next) = try NinePCodec.readString(in: body, at: 4)
        guard let mode = body.readU32LE(at: next),
              let _ = body.readU32LE(at: next + 4) else {
            throw POSIXError(.EINVAL)
        }
        guard let parent = fids.get(dfid), parent.isDir else { throw POSIXError(.ENOTDIR) }
        try Walk.validateComponent(name)
        let target = parent.url.appendingPathComponent(name).standardized
        guard pathInRoot(target) else { throw POSIXError(.EACCES) }

        let rc = target.path.withCString { mkdir($0, mode_t(mode & 0o7777)) }
        if rc != 0 { throw POSIXError(currentErrnoCode()) }

        let qid = try QidBuilder.qid(for: target)
        var r = Data()
        NinePCodec.appendQid(qid, to: &r)
        sendR(.Rmkdir, tag: tag, body: r)
    }

    /// Tunlinkat — body: dfid(4) | name(s) | flags(4)
    /// flags & AT_REMOVEDIR (0x200) → rmdir, else unlink.
    private func handleUnlinkat(tag: UInt16, body: Data) throws {
        guard let dfid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        let (name, next) = try NinePCodec.readString(in: body, at: 4)
        guard let flags = body.readU32LE(at: next) else { throw POSIXError(.EINVAL) }
        guard let parent = fids.get(dfid), parent.isDir else { throw POSIXError(.ENOTDIR) }
        try Walk.validateComponent(name)
        let target = parent.url.appendingPathComponent(name).standardized
        guard pathInRoot(target) else { throw POSIXError(.EACCES) }

        let isRmdir = (flags & 0x200) != 0   // AT_REMOVEDIR
        let rc = target.path.withCString { p -> Int32 in
            isRmdir ? rmdir(p) : unlink(p)
        }
        if rc != 0 { throw POSIXError(currentErrnoCode()) }
        sendR(.Runlinkat, tag: tag, body: Data())
    }

    /// Tstatfs — body: fid(4)
    /// Reply: type(4) bsize(4) blocks(8) bfree(8) bavail(8) files(8) ffree(8)
    ///        fsid(8) namelen(4)
    /// Some kernels invoke this during mount even though we don't enforce quotas;
    /// return plausible values.
    private func handleStatfs(tag: UInt16, body: Data) throws {
        guard body.count >= 4 else { throw POSIXError(.EINVAL) }
        var r = Data()
        r.appendU32LE(0x01021997)   // V9FS_MAGIC
        r.appendU32LE(4096)         // bsize
        r.appendU64LE(0xffff_ffff)  // blocks
        r.appendU64LE(0xffff_ffff)  // bfree
        r.appendU64LE(0xffff_ffff)  // bavail
        r.appendU64LE(0xffff_ffff)  // files
        r.appendU64LE(0xffff_ffff)  // ffree
        r.appendU64LE(0)            // fsid
        r.appendU32LE(255)          // namelen
        sendR(.Rstatfs, tag: tag, body: r)
    }

    /// Tfsync — body: fid(4) | datasync(4)
    private func handleFsync(tag: UInt16, body: Data) throws {
        guard let fid = body.readU32LE(at: 0) else { throw POSIXError(.EINVAL) }
        if let f = fids.get(fid), let h = f.handle {
            try h.synchronize()
        }
        sendR(.Rfsync, tag: tag, body: Data())
    }

    // MARK: - Plumbing

    private func sendR(_ op: NinePOp, tag: UInt16, body: Data) {
        let msg = NinePMessage(op: op, tag: tag, body: body)
        socket.sendBinary(NinePCodec.encode(msg))
    }

    private func sendLerror(tag: UInt16, errno: LinuxErrno) {
        var b = Data()
        b.appendU32LE(errno.rawValue)
        sendR(.Rlerror, tag: tag, body: b)
    }

    private func pathInRoot(_ url: URL) -> Bool {
        let canonical = url.standardized.path
        let rootPath = root.path
        if canonical == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return canonical.hasPrefix(prefix)
    }

    private func shutdown() {
        for f in fids.removeAll() {
            try? f.handle?.close()
        }
    }
}

// MARK: - Stat field accessors (Darwin vs. Linux name differences)

@inline(__always)
private func atimeFields(_ st: stat) -> (UInt64, UInt64) {
    #if canImport(Darwin)
    return (UInt64(st.st_atimespec.tv_sec), UInt64(st.st_atimespec.tv_nsec))
    #else
    return (UInt64(st.st_atim.tv_sec), UInt64(st.st_atim.tv_nsec))
    #endif
}

@inline(__always)
private func mtimeFields(_ st: stat) -> (UInt64, UInt64) {
    #if canImport(Darwin)
    return (UInt64(st.st_mtimespec.tv_sec), UInt64(st.st_mtimespec.tv_nsec))
    #else
    return (UInt64(st.st_mtim.tv_sec), UInt64(st.st_mtim.tv_nsec))
    #endif
}

@inline(__always)
private func ctimeFields(_ st: stat) -> (UInt64, UInt64) {
    #if canImport(Darwin)
    return (UInt64(st.st_ctimespec.tv_sec), UInt64(st.st_ctimespec.tv_nsec))
    #else
    return (UInt64(st.st_ctim.tv_sec), UInt64(st.st_ctim.tv_nsec))
    #endif
}

@inline(__always)
private func QidBuilder_kindForMode(_ mode: mode_t) -> Qid.Kind {
    QidBuilder.kind(forMode: mode)
}
