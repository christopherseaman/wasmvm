import Foundation
import WasmVMCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `stat()`-based qid construction per `spec/04-ninep-server.md`
/// §"Inode-based qid.path". Uses the OS `stat` syscall directly so qid.path is
/// a stable st_ino rather than an ephemeral Foundation hash.
enum QidBuilder {
    /// Build a Qid for the file at `url`. Throws POSIXError if the file is
    /// missing or inaccessible.
    static func qid(for url: URL) throws -> Qid {
        let st = try statCall(url)
        let kind = QidBuilder.kind(forMode: st.st_mode)
        return Qid(kind: kind, version: 0, path: UInt64(st.st_ino))
    }

    /// Look up the raw stat struct (handlers like Tgetattr need full fields).
    static func statOf(_ url: URL) throws -> stat {
        return try statCall(url)
    }

    private static func statCall(_ url: URL) throws -> stat {
        // We use lstat to sidestep a Swift name-collision in Glibc where the
        // module exports both a `stat` struct and a `stat` function, making
        // `Glibc.stat(...)` resolve as the type. lstat semantics are fine for
        // MVP (symlinks are explicitly out of scope per spec/04 §"Out of scope").
        var st = stat()
        let rc: Int32 = url.path.withCString { p in
            #if canImport(Darwin)
            return Darwin.lstat(p, &st)
            #else
            return Glibc.lstat(p, &st)
            #endif
        }
        if rc != 0 {
            throw POSIXError(currentErrnoCode())
        }
        return st
    }

    static func kind(forMode mode: mode_t) -> Qid.Kind {
        let masked = Int32(mode) & Int32(S_IFMT)
        switch masked {
        case Int32(S_IFDIR):  return .dir
        case Int32(S_IFLNK):  return .symlink
        default:              return .file
        }
    }

    /// DT_* value for use in Treaddir entry encoding.
    static func dtType(forMode mode: mode_t) -> UInt8 {
        let masked = Int32(mode) & Int32(S_IFMT)
        switch masked {
        case Int32(S_IFDIR):  return 4    // DT_DIR
        case Int32(S_IFREG):  return 8    // DT_REG
        case Int32(S_IFLNK):  return 10   // DT_LNK
        case Int32(S_IFCHR):  return 2    // DT_CHR
        case Int32(S_IFBLK):  return 6    // DT_BLK
        case Int32(S_IFIFO):  return 1    // DT_FIFO
        case Int32(S_IFSOCK): return 12   // DT_SOCK
        default:              return 0    // DT_UNKNOWN
        }
    }
}

@inline(__always)
func currentErrnoCode() -> POSIXErrorCode {
    #if canImport(Darwin)
    let e = Darwin.errno
    #else
    let e = Glibc.errno
    #endif
    return POSIXErrorCode(rawValue: e) ?? .EIO
}
