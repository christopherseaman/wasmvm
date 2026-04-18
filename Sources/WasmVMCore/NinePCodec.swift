import Foundation

/// 9P2000.L wire format per `spec/04-ninep-server.md`.
///
/// Message: `size(4 LE) | type(1) | tag(2 LE) | body`
/// `size` includes header. One WebSocket binary message = one 9P message.

public enum NinePOp: UInt8, Sendable {
    case Tlerror   = 6,  Rlerror   = 7
    case Tstatfs   = 8,  Rstatfs   = 9
    case Tlopen    = 12, Rlopen    = 13
    case Tlcreate  = 14, Rlcreate  = 15
    case Tsymlink  = 16, Rsymlink  = 17  // ENOSYS in MVP
    case Tmknod    = 18, Rmknod    = 19  // ENOSYS in MVP
    case Trename   = 20, Rrename   = 21  // deferred; MVP uses Trenameat (74/75) if needed
    case Treadlink = 22, Rreadlink = 23  // ENOSYS in MVP
    case Tgetattr  = 24, Rgetattr  = 25
    case Tsetattr  = 26, Rsetattr  = 27
    case Treaddir  = 40, Rreaddir  = 41
    case Tfsync    = 50, Rfsync    = 51
    case Tlock     = 52, Rlock     = 53  // ENOSYS in MVP
    case Tmkdir    = 70, Rmkdir    = 71
    case Tunlinkat = 72, Runlinkat = 73
    case Trenameat = 74, Rrenameat = 75  // post-MVP
    case Tversion  = 100, Rversion = 101
    case Tattach   = 104, Rattach  = 105
    case Twalk     = 110, Rwalk    = 111
    case Tread     = 116, Rread    = 117
    case Twrite    = 118, Rwrite   = 119
    case Tclunk    = 120, Rclunk   = 121
}

/// A decoded 9P message header + opaque body.
/// The interpretation of `body` is op-specific; codec helpers parse per-op.
public struct NinePMessage: Sendable, Equatable {
    public let op: NinePOp
    public let tag: UInt16
    public let body: Data

    public init(op: NinePOp, tag: UInt16, body: Data) {
        self.op = op
        self.tag = tag
        self.body = body
    }
}

public enum NinePCodecError: Error, Equatable, Sendable {
    case shortHeader            // < 7 bytes
    case truncatedMessage       // size field claims more bytes than buffer holds
    case unknownOp(UInt8)
    case invalidString          // string field length exceeds remaining bytes or non-UTF-8
    case invalidBody(reason: String)
}

/// 9P qid: `type(1) | version(4 LE) | path(8 LE)`
public struct Qid: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case file    = 0x00
        case symlink = 0x02
        case dir     = 0x80
    }
    public let kind: Kind
    public let version: UInt32
    public let path: UInt64

    public init(kind: Kind, version: UInt32, path: UInt64) {
        self.kind = kind
        self.version = version
        self.path = path
    }
}

public enum NinePCodec {
    public static let headerSize = 7
    public static let qidSize = 13

    public static func encode(_ message: NinePMessage) -> Data {
        let total = headerSize + message.body.count
        var out = Data()
        out.reserveCapacity(total)
        out.appendU32LE(UInt32(total))
        out.appendU8(message.op.rawValue)
        out.appendU16LE(message.tag)
        out.append(message.body)
        return out
    }

    public static func decode(_ bytes: Data) throws -> NinePMessage {
        guard bytes.count >= headerSize else { throw NinePCodecError.shortHeader }
        let size = bytes.readU32LE(at: 0)!
        guard Int(size) == bytes.count else {
            throw NinePCodecError.truncatedMessage
        }
        let opRaw = bytes.readU8(at: 4)!
        guard let op = NinePOp(rawValue: opRaw) else {
            throw NinePCodecError.unknownOp(opRaw)
        }
        let tag = bytes.readU16LE(at: 5)!
        let bodyLen = Int(size) - headerSize
        let body = bytes.slice(at: headerSize, length: bodyLen) ?? Data()
        return NinePMessage(op: op, tag: tag, body: body)
    }

    public static func appendString(_ s: String, to out: inout Data) {
        let utf8 = Data(s.utf8)
        out.appendU16LE(UInt16(utf8.count))
        out.append(utf8)
    }

    public static func readString(in bytes: Data, at offset: Int) throws -> (String, Int) {
        guard let len = bytes.readU16LE(at: offset) else {
            throw NinePCodecError.invalidString
        }
        let strStart = offset + 2
        let strEnd = strStart + Int(len)
        guard strEnd <= bytes.count else {
            throw NinePCodecError.invalidString
        }
        let strData = bytes.slice(at: strStart, length: Int(len)) ?? Data()
        guard let s = String(data: strData, encoding: .utf8) else {
            throw NinePCodecError.invalidString
        }
        return (s, strEnd)
    }

    public static func appendQid(_ qid: Qid, to out: inout Data) {
        out.appendU8(qid.kind.rawValue)
        out.appendU32LE(qid.version)
        out.appendU64LE(qid.path)
    }

    public static func readQid(in bytes: Data, at offset: Int) throws -> (Qid, Int) {
        guard offset + qidSize <= bytes.count else {
            throw NinePCodecError.invalidBody(reason: "qid out of bounds")
        }
        let kindRaw = bytes.readU8(at: offset)!
        guard let kind = Qid.Kind(rawValue: kindRaw) else {
            throw NinePCodecError.invalidBody(reason: "qid kind \(kindRaw)")
        }
        let version = bytes.readU32LE(at: offset + 1)!
        let path = bytes.readU64LE(at: offset + 5)!
        return (Qid(kind: kind, version: version, path: path), offset + qidSize)
    }
}
