import XCTest
@testable import WasmVMCore

final class NinePCodecTests: XCTestCase {

    func test_encode_message_emits_size_type_tag_then_body() {
        let body = Data([0xAA, 0xBB])
        let msg = NinePMessage(op: .Tclunk, tag: 0x1234, body: body)
        let bytes = NinePCodec.encode(msg)
        let expected: [UInt8] = [
            0x09, 0x00, 0x00, 0x00,     // size = 7 + 2 = 9 LE
            120,                        // type = Tclunk
            0x34, 0x12,                 // tag LE
            0xAA, 0xBB,
        ]
        XCTAssertEqual(Array(bytes), expected)
    }

    func test_decode_round_trip_empty_body() throws {
        let original = NinePMessage(op: .Rclunk, tag: 7, body: Data())
        let decoded = try NinePCodec.decode(NinePCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func test_decode_round_trip_all_ops() throws {
        let ops: [NinePOp] = [
            .Tlerror, .Rlerror, .Tstatfs, .Rstatfs, .Tlopen, .Rlopen,
            .Tlcreate, .Rlcreate, .Tgetattr, .Rgetattr, .Tsetattr, .Rsetattr,
            .Treaddir, .Rreaddir, .Tfsync, .Rfsync, .Tmkdir, .Rmkdir,
            .Tunlinkat, .Runlinkat, .Tversion, .Rversion, .Tattach, .Rattach,
            .Twalk, .Rwalk, .Tread, .Rread, .Twrite, .Rwrite,
            .Tclunk, .Rclunk,
        ]
        for op in ops {
            let body = Data([0x01, 0x02, 0x03])
            let original = NinePMessage(op: op, tag: 0xCAFE, body: body)
            let decoded = try NinePCodec.decode(NinePCodec.encode(original))
            XCTAssertEqual(decoded, original, "round-trip failed for \(op)")
        }
    }

    func test_decode_short_header_throws() {
        let bytes = Data([0x07, 0x00, 0x00])
        XCTAssertThrowsError(try NinePCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? NinePCodecError, .shortHeader)
        }
    }

    func test_decode_size_mismatch_truncated_throws() {
        var bytes = Data()
        bytes.append(contentsOf: [0x10, 0x00, 0x00, 0x00])  // claims 16 bytes
        bytes.append(120)                                    // type
        bytes.append(contentsOf: [0x00, 0x00])               // tag
        XCTAssertThrowsError(try NinePCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? NinePCodecError, .truncatedMessage)
        }
    }

    func test_decode_size_mismatch_trailing_bytes_throws() {
        var bytes = NinePCodec.encode(NinePMessage(op: .Rclunk, tag: 1, body: Data()))
        bytes.append(0xFF)
        XCTAssertThrowsError(try NinePCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? NinePCodecError, .truncatedMessage)
        }
    }

    func test_decode_unknown_op_throws() {
        var bytes = Data()
        bytes.append(contentsOf: [0x07, 0x00, 0x00, 0x00])
        bytes.append(0xFE)
        bytes.append(contentsOf: [0x00, 0x00])
        XCTAssertThrowsError(try NinePCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? NinePCodecError, .unknownOp(0xFE))
        }
    }

    func test_appendString_layout() {
        var out = Data()
        NinePCodec.appendString("hi", to: &out)
        XCTAssertEqual(Array(out), [0x02, 0x00, 0x68, 0x69])
    }

    func test_appendString_empty() {
        var out = Data()
        NinePCodec.appendString("", to: &out)
        XCTAssertEqual(Array(out), [0x00, 0x00])
    }

    func test_appendString_unicode() {
        var out = Data()
        NinePCodec.appendString("café", to: &out)
        let utf8: [UInt8] = Array("café".utf8)
        var expected: [UInt8] = [UInt8(utf8.count & 0xff), UInt8((utf8.count >> 8) & 0xff)]
        expected.append(contentsOf: utf8)
        XCTAssertEqual(Array(out), expected)
    }

    func test_readString_round_trip() throws {
        var out = Data()
        out.append(0xAB)                                    // leading filler
        NinePCodec.appendString("hello", to: &out)
        out.append(0xCD)                                    // trailing filler
        let (s, newOffset) = try NinePCodec.readString(in: out, at: 1)
        XCTAssertEqual(s, "hello")
        XCTAssertEqual(newOffset, 1 + 2 + 5)
        XCTAssertEqual(out[newOffset], 0xCD)
    }

    func test_readString_short_length_field_throws() {
        let bytes = Data([0x05])     // only 1 byte; length needs 2
        XCTAssertThrowsError(try NinePCodec.readString(in: bytes, at: 0)) { error in
            XCTAssertEqual(error as? NinePCodecError, .invalidString)
        }
    }

    func test_readString_length_overflows_buffer_throws() {
        let bytes = Data([0xff, 0xff, 0x41])  // claims 65535 bytes, only 1 available
        XCTAssertThrowsError(try NinePCodec.readString(in: bytes, at: 0)) { error in
            XCTAssertEqual(error as? NinePCodecError, .invalidString)
        }
    }

    func test_readString_invalid_utf8_throws() {
        let bytes = Data([0x02, 0x00, 0xc3, 0x28])
        XCTAssertThrowsError(try NinePCodec.readString(in: bytes, at: 0)) { error in
            XCTAssertEqual(error as? NinePCodecError, .invalidString)
        }
    }

    func test_appendQid_layout() {
        var out = Data()
        let qid = Qid(kind: .dir, version: 0x01020304, path: 0x1122_3344_5566_7788)
        NinePCodec.appendQid(qid, to: &out)
        let expected: [UInt8] = [
            0x80,                                                       // dir
            0x04, 0x03, 0x02, 0x01,                                     // version LE
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,             // path LE
        ]
        XCTAssertEqual(Array(out), expected)
        XCTAssertEqual(out.count, 13)
    }

    func test_readQid_round_trip_all_kinds() throws {
        let kinds: [Qid.Kind] = [.file, .symlink, .dir]
        for kind in kinds {
            var out = Data()
            out.append(0xEE)
            let original = Qid(kind: kind, version: 42, path: 9_999_999_999)
            NinePCodec.appendQid(original, to: &out)
            let (decoded, newOffset) = try NinePCodec.readQid(in: out, at: 1)
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(newOffset, 14)
        }
    }

    func test_readQid_out_of_bounds_throws() {
        let bytes = Data([0x80, 0x00, 0x00])    // only 3 bytes
        XCTAssertThrowsError(try NinePCodec.readQid(in: bytes, at: 0)) { error in
            guard case .invalidBody = error as? NinePCodecError else {
                XCTFail("expected invalidBody, got \(error)")
                return
            }
        }
    }

    func test_readQid_unknown_kind_throws() {
        var bytes = Data([0x55])    // unknown kind
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 12))
        XCTAssertThrowsError(try NinePCodec.readQid(in: bytes, at: 0)) { error in
            guard case .invalidBody = error as? NinePCodecError else {
                XCTFail("expected invalidBody, got \(error)")
                return
            }
        }
    }

    func test_message_with_string_body_round_trip() throws {
        var body = Data()
        NinePCodec.appendString("9P2000.L", to: &body)
        let msg = NinePMessage(op: .Rversion, tag: 0xFFFF, body: body)
        let wire = NinePCodec.encode(msg)
        let decoded = try NinePCodec.decode(wire)
        XCTAssertEqual(decoded, msg)
        let (s, _) = try NinePCodec.readString(in: decoded.body, at: 0)
        XCTAssertEqual(s, "9P2000.L")
    }
}
