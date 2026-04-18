import XCTest
@testable import WasmVMCore

final class FrameCodecTests: XCTestCase {

    func test_encode_close_frame_emits_9_byte_header_only() {
        let frame = Frame(op: .close, connID: 0x1234_5678, payload: Data())
        let bytes = FrameCodec.encode(frame)
        let expected: [UInt8] = [
            0x03,                       // op = CLOSE
            0x78, 0x56, 0x34, 0x12,     // conn_id = 0x12345678 LE
            0x00, 0x00, 0x00, 0x00,     // length = 0
        ]
        XCTAssertEqual(Array(bytes), expected)
    }

    func test_encode_data_frame_with_payload() {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let frame = Frame(op: .data, connID: 1, payload: payload)
        let bytes = FrameCodec.encode(frame)
        let expected: [UInt8] = [
            0x02,                       // op = DATA
            0x01, 0x00, 0x00, 0x00,     // conn_id = 1 LE
            0x04, 0x00, 0x00, 0x00,     // length = 4
            0xde, 0xad, 0xbe, 0xef,
        ]
        XCTAssertEqual(Array(bytes), expected)
    }

    func test_decode_round_trip_close() throws {
        let original = Frame(op: .close, connID: 42, payload: Data())
        let decoded = try FrameCodec.decode(FrameCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_round_trip_data_with_payload() throws {
        let original = Frame(op: .data, connID: 7, payload: Data([1, 2, 3, 4, 5]))
        let decoded = try FrameCodec.decode(FrameCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_round_trip_all_ops() throws {
        let ops: [FrameOp] = [.connect, .data, .close, .connectOK, .connectErr,
                              .listen, .listenOK, .accept, .resolve, .resolveOK]
        for op in ops {
            let original = Frame(op: op, connID: 0xff00ff00, payload: Data([0xAA]))
            let decoded = try FrameCodec.decode(FrameCodec.encode(original))
            XCTAssertEqual(decoded, original, "round-trip failed for \(op)")
        }
    }

    func test_decode_short_header_throws() {
        let bytes = Data([0x01, 0x00, 0x00])
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .shortHeader)
        }
    }

    func test_decode_unknown_op_throws() {
        var bytes = Data()
        bytes.append(0xFF)
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .unknownOp(0xFF))
        }
    }

    func test_decode_length_claims_more_than_buffer_throws() {
        var bytes = Data()
        bytes.append(0x02)                                       // op
        bytes.append(contentsOf: [0, 0, 0, 0])                   // conn_id
        bytes.append(contentsOf: [0x10, 0, 0, 0])                // length = 16
        bytes.append(contentsOf: [1, 2, 3])                      // only 3 payload bytes
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .truncatedPayload)
        }
    }

    func test_decode_trailing_bytes_throws() {
        var bytes = FrameCodec.encode(Frame(op: .close, connID: 1, payload: Data()))
        bytes.append(0x99)
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .truncatedPayload)
        }
    }

    func test_encode_connect_payload_layout() {
        let payload = ConnectPayload(family: .ipv4, proto: .tcp, host: "ab", port: 0x1234)
        let bytes = FrameCodec.encodeConnectPayload(payload)
        let expected: [UInt8] = [
            0x04,                   // family = 4 (IPv4)
            0x06,                   // proto = 6 (TCP)
            0x02, 0x00,             // host_len = 2 LE
            0x61, 0x62,             // "ab"
            0x34, 0x12,             // port = 0x1234 LE
        ]
        XCTAssertEqual(Array(bytes), expected)
    }

    func test_decode_connect_payload_round_trip_ipv4_tcp() throws {
        let original = ConnectPayload(family: .ipv4, proto: .tcp, host: "example.com", port: 443)
        let decoded = try FrameCodec.decodeConnectPayload(FrameCodec.encodeConnectPayload(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_connect_payload_round_trip_ipv6_udp() throws {
        let original = ConnectPayload(family: .ipv6, proto: .udp, host: "::1", port: 53)
        let decoded = try FrameCodec.decodeConnectPayload(FrameCodec.encodeConnectPayload(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_connect_payload_empty_host() throws {
        let original = ConnectPayload(family: .ipv4, proto: .tcp, host: "", port: 80)
        let decoded = try FrameCodec.decodeConnectPayload(FrameCodec.encodeConnectPayload(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_connect_payload_unicode_host() throws {
        let original = ConnectPayload(family: .ipv4, proto: .tcp, host: "münchen.example", port: 80)
        let decoded = try FrameCodec.decodeConnectPayload(FrameCodec.encodeConnectPayload(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_connect_payload_short_throws() {
        let bytes = Data([0x04, 0x06, 0x00])
        XCTAssertThrowsError(try FrameCodec.decodeConnectPayload(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .invalidConnectPayload)
        }
    }

    func test_decode_connect_payload_bad_family_throws() {
        let bytes = Data([0x09, 0x06, 0x00, 0x00, 0x50, 0x00])
        XCTAssertThrowsError(try FrameCodec.decodeConnectPayload(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .invalidConnectPayload)
        }
    }

    func test_decode_connect_payload_bad_proto_throws() {
        let bytes = Data([0x04, 0x99, 0x00, 0x00, 0x50, 0x00])
        XCTAssertThrowsError(try FrameCodec.decodeConnectPayload(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .invalidConnectPayload)
        }
    }

    func test_decode_connect_payload_host_len_overflows_throws() {
        var bytes = Data()
        bytes.append(contentsOf: [0x04, 0x06])
        bytes.append(contentsOf: [0xff, 0xff])              // host_len = 65535
        bytes.append(contentsOf: [0x41, 0x41])              // only 2 host bytes
        bytes.append(contentsOf: [0x50, 0x00])
        XCTAssertThrowsError(try FrameCodec.decodeConnectPayload(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .invalidConnectPayload)
        }
    }

    func test_decode_connect_payload_invalid_utf8_throws() {
        var bytes = Data()
        bytes.append(contentsOf: [0x04, 0x06])
        bytes.append(contentsOf: [0x02, 0x00])              // host_len = 2
        bytes.append(contentsOf: [0xc3, 0x28])              // invalid utf-8 (continuation byte missing)
        bytes.append(contentsOf: [0x50, 0x00])
        XCTAssertThrowsError(try FrameCodec.decodeConnectPayload(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .invalidUTF8Host)
        }
    }

    func test_decode_connect_payload_trailing_bytes_throws() {
        var bytes = FrameCodec.encodeConnectPayload(
            ConnectPayload(family: .ipv4, proto: .tcp, host: "x", port: 1)
        )
        bytes.append(0xAA)
        XCTAssertThrowsError(try FrameCodec.decodeConnectPayload(bytes)) { error in
            XCTAssertEqual(error as? FrameCodecError, .invalidConnectPayload)
        }
    }

    func test_full_connect_frame_round_trip() throws {
        let payloadStruct = ConnectPayload(family: .ipv4, proto: .tcp, host: "example.com", port: 443)
        let payloadBytes = FrameCodec.encodeConnectPayload(payloadStruct)
        let frame = Frame(op: .connect, connID: 99, payload: payloadBytes)
        let wire = FrameCodec.encode(frame)
        let decodedFrame = try FrameCodec.decode(wire)
        XCTAssertEqual(decodedFrame.op, .connect)
        XCTAssertEqual(decodedFrame.connID, 99)
        let decodedPayload = try FrameCodec.decodeConnectPayload(decodedFrame.payload)
        XCTAssertEqual(decodedPayload, payloadStruct)
    }

    func test_encode_data_frame_with_one_megabyte_payload() throws {
        let oneMiB = Data(repeating: 0x5a, count: 1 << 20)
        let frame = Frame(op: .data, connID: 1, payload: oneMiB)
        let wire = FrameCodec.encode(frame)
        XCTAssertEqual(wire.count, 9 + (1 << 20))
        let decoded = try FrameCodec.decode(wire)
        XCTAssertEqual(decoded.payload.count, 1 << 20)
        XCTAssertEqual(decoded.payload, oneMiB)
    }
}
