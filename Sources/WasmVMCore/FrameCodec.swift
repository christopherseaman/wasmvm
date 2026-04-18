import Foundation

/// NetBridge wire format per `spec/03-net-bridge.md`.
///
/// Frame: `op(1) | conn_id(4 LE) | length(4 LE) | payload`
/// One WebSocket binary message = one frame.
public enum FrameOp: UInt8, Sendable {
    case connect    = 0x01
    case data       = 0x02
    case close      = 0x03
    case connectOK  = 0x04
    case connectErr = 0x05
    case listen     = 0x06   // post-MVP
    case listenOK   = 0x07   // post-MVP
    case accept     = 0x08   // post-MVP
    case resolve    = 0x09   // post-MVP
    case resolveOK  = 0x0A   // post-MVP
}

/// CONNECT payload layout per `spec/03-net-bridge.md`:
/// `family(1) | proto(1) | host_len(2 LE) | host(N) | port(2 LE)`
public struct ConnectPayload: Sendable, Equatable {
    public enum Family: UInt8, Sendable { case ipv4 = 4, ipv6 = 6 }
    public enum Proto: UInt8, Sendable { case tcp = 6, udp = 17 }

    public let family: Family
    public let proto: Proto
    public let host: String
    public let port: UInt16

    public init(family: Family, proto: Proto, host: String, port: UInt16) {
        self.family = family
        self.proto = proto
        self.host = host
        self.port = port
    }
}

/// Decoded frame.
public struct Frame: Sendable, Equatable {
    public let op: FrameOp
    public let connID: UInt32
    public let payload: Data

    public init(op: FrameOp, connID: UInt32, payload: Data) {
        self.op = op
        self.connID = connID
        self.payload = payload
    }
}

/// Errors raised by the codec on malformed input.
public enum FrameCodecError: Error, Equatable, Sendable {
    case shortHeader            // < 9 bytes
    case truncatedPayload       // length field claims more bytes than buffer holds
    case unknownOp(UInt8)
    case invalidConnectPayload  // CONNECT body doesn't parse
    case invalidUTF8Host        // host bytes aren't valid UTF-8
}

public enum FrameCodec {
    public static let headerSize = 9

    public static func encode(_ frame: Frame) -> Data {
        var out = Data()
        out.reserveCapacity(headerSize + frame.payload.count)
        out.appendU8(frame.op.rawValue)
        out.appendU32LE(frame.connID)
        out.appendU32LE(UInt32(frame.payload.count))
        out.append(frame.payload)
        return out
    }

    public static func decode(_ bytes: Data) throws -> Frame {
        guard bytes.count >= headerSize else { throw FrameCodecError.shortHeader }
        let opRaw = bytes.readU8(at: 0)!
        guard let op = FrameOp(rawValue: opRaw) else {
            throw FrameCodecError.unknownOp(opRaw)
        }
        let connID = bytes.readU32LE(at: 1)!
        let length = bytes.readU32LE(at: 5)!
        let payloadEnd = headerSize + Int(length)
        guard bytes.count == payloadEnd else {
            throw FrameCodecError.truncatedPayload
        }
        let payload = bytes.slice(at: headerSize, length: Int(length)) ?? Data()
        return Frame(op: op, connID: connID, payload: payload)
    }

    public static func encodeConnectPayload(_ payload: ConnectPayload) -> Data {
        let hostBytes = Data(payload.host.utf8)
        var out = Data()
        out.reserveCapacity(1 + 1 + 2 + hostBytes.count + 2)
        out.appendU8(payload.family.rawValue)
        out.appendU8(payload.proto.rawValue)
        out.appendU16LE(UInt16(hostBytes.count))
        out.append(hostBytes)
        out.appendU16LE(payload.port)
        return out
    }

    public static func decodeConnectPayload(_ bytes: Data) throws -> ConnectPayload {
        guard bytes.count >= 1 + 1 + 2 else {
            throw FrameCodecError.invalidConnectPayload
        }
        let famRaw = bytes.readU8(at: 0)!
        let protoRaw = bytes.readU8(at: 1)!
        guard let family = ConnectPayload.Family(rawValue: famRaw),
              let proto = ConnectPayload.Proto(rawValue: protoRaw) else {
            throw FrameCodecError.invalidConnectPayload
        }
        let hostLen = Int(bytes.readU16LE(at: 2)!)
        let hostStart = 4
        let portStart = hostStart + hostLen
        guard bytes.count == portStart + 2 else {
            throw FrameCodecError.invalidConnectPayload
        }
        let hostData = bytes.slice(at: hostStart, length: hostLen) ?? Data()
        guard let host = String(data: hostData, encoding: .utf8) else {
            throw FrameCodecError.invalidUTF8Host
        }
        let port = bytes.readU16LE(at: portStart)!
        return ConnectPayload(family: family, proto: proto, host: host, port: port)
    }
}
