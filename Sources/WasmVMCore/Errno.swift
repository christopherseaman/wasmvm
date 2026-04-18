import Foundation

/// Linux errno values used in 9P `Rlerror` replies per `spec/04-ninep-server.md`.
///
/// We use raw values (not POSIXErrorCode) because the wire format demands the
/// numeric Linux errno, which on Darwin happens to coincide with Linux for the
/// values we use. Spell them out so the wire format is unambiguous.
public enum LinuxErrno: UInt32, Sendable {
    case EPERM    = 1
    case ENOENT   = 2
    case EIO      = 5
    case EBADF    = 9
    case ENOMEM   = 12
    case EACCES   = 13
    case EEXIST   = 17
    case ENOTDIR  = 20
    case EISDIR   = 21
    case EINVAL   = 22
    case EFBIG    = 27
    case ENOSPC   = 28
    case EROFS    = 30
    case ENAMETOOLONG = 36
    case ENOSYS   = 38
    case ENOTEMPTY = 39
}

public enum ErrnoMap {
    public static func errno(for error: Error) -> LinuxErrno {
        if let posix = error as? POSIXError {
            return mapPOSIX(posix.code)
        }
        // Inspect domain BEFORE `as? CocoaError`: on swift-corelibs-foundation,
        // any NSError bridges to CocoaError regardless of domain, which would
        // misclassify NSPOSIXErrorDomain errors.
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            if let pc = POSIXErrorCode(rawValue: Int32(ns.code)) {
                return mapPOSIX(pc)
            }
            return .EIO
        }
        if ns.domain == NSCocoaErrorDomain {
            return mapCocoa(CocoaError.Code(rawValue: ns.code))
        }
        if let cocoa = error as? CocoaError {
            return mapCocoa(cocoa.code)
        }
        return .EIO
    }

    private static func mapPOSIX(_ code: POSIXErrorCode) -> LinuxErrno {
        if let v = LinuxErrno(rawValue: UInt32(code.rawValue)) {
            return v
        }
        return .EIO
    }

    private static func mapCocoa(_ code: CocoaError.Code) -> LinuxErrno {
        switch code {
        case .fileReadNoPermission, .fileWriteNoPermission:
            return .EACCES
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .ENOENT
        default:
            return .EIO
        }
    }
}
