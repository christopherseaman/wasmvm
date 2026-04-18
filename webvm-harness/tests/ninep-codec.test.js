import { describe, it, expect } from "vitest";
import {
  OP, QID_TYPE,
  encodeMessage, decodeMessage,
  appendString, readString,
  appendQid, readQid,
  concat,
} from "../ninep-codec.js";

describe("9P message header byte layout", () => {
  it("encodes size LE | type | tag LE | body exactly per spec/04", () => {
    const got = encodeMessage(OP.Tversion, 0xBEEF, new Uint8Array([0xDE, 0xAD]));
    expect(got).toEqual(new Uint8Array([
      0x09, 0x00, 0x00, 0x00,
      100,
      0xEF, 0xBE,
      0xDE, 0xAD,
    ]));
  });

  it("encodes empty body as 7-byte header (Rclunk pattern)", () => {
    const got = encodeMessage(OP.Rclunk, 1, new Uint8Array(0));
    expect(got).toEqual(new Uint8Array([
      0x07, 0x00, 0x00, 0x00,
      121,
      0x01, 0x00,
    ]));
  });
});

describe("9P message round-trip", () => {
  it.each([
    ["empty body", OP.Rclunk, 1, new Uint8Array(0)],
    ["single byte", OP.Tlopen, 0xFFFF, new Uint8Array([0x42])],
    ["64 KiB body (msize ceiling)", OP.Rread, 0x0100, new Uint8Array(65536 - 7).fill(0xA5)],
  ])("%s round-trips", (_label, op, tag, body) => {
    const wire = encodeMessage(op, tag, body);
    const out = decodeMessage(wire);
    expect(out.op).toBe(op);
    expect(out.tag).toBe(tag);
    expect(out.body).toEqual(body);
  });
});

describe("9P message decode error cases", () => {
  it("rejects buffer shorter than the 7-byte header", () => {
    expect(() => decodeMessage(new Uint8Array(6))).toThrow(/short header/);
  });

  it("rejects header size mismatch", () => {
    const bad = new Uint8Array([0x10, 0, 0, 0,  100,  0, 0]);
    expect(() => decodeMessage(bad)).toThrow(/size mismatch/);
  });

  it("rejects trailing bytes", () => {
    const wire = encodeMessage(OP.Rclunk, 0, new Uint8Array(0));
    const padded = new Uint8Array(wire.length + 1);
    padded.set(wire);
    expect(() => decodeMessage(padded)).toThrow(/size mismatch/);
  });

  it("rejects non-Uint8Array input", () => {
    expect(() => decodeMessage([1,2,3,4,5,6,7])).toThrow(/Uint8Array/);
  });
});

describe("9P message encode argument validation", () => {
  it("rejects op out of u8 range", () => {
    expect(() => encodeMessage(0x100, 0, new Uint8Array(0))).toThrow(/u8/);
  });

  it("rejects tag out of u16 range", () => {
    expect(() => encodeMessage(OP.Tversion, 0x10000, new Uint8Array(0))).toThrow(/u16/);
  });

  it("rejects non-Uint8Array body", () => {
    expect(() => encodeMessage(OP.Tversion, 0, "hi")).toThrow(/Uint8Array/);
  });
});

describe("9P string codec", () => {
  it("encodes len(2 LE) | utf8 bytes", () => {
    const chunks = [];
    appendString("hi", chunks);
    expect(concat(chunks)).toEqual(new Uint8Array([0x02, 0x00, 0x68, 0x69]));
  });

  it("encodes empty string as just len=0", () => {
    const chunks = [];
    appendString("", chunks);
    expect(concat(chunks)).toEqual(new Uint8Array([0x00, 0x00]));
  });

  it.each([
    ["ascii", "9p2000.L"],
    ["empty", ""],
    ["non-ASCII", "café"],
    ["emoji",  "smile \u{1F600}\u{1F4A9}"],
    ["chinese", "你好世界"],
  ])("%s string round-trips", (_label, s) => {
    const chunks = [];
    appendString(s, chunks);
    const wire = concat(chunks);
    const [got, end] = readString(wire, 0);
    expect(got).toBe(s);
    expect(end).toBe(wire.byteLength);
  });

  it("readString respects offset and reports newOffset", () => {
    const chunks = [new Uint8Array([0xAA, 0xBB, 0xCC])];
    appendString("ok", chunks);
    chunks.push(new Uint8Array([0xDD]));
    const wire = concat(chunks);
    const [s, end] = readString(wire, 3);
    expect(s).toBe("ok");
    expect(end).toBe(3 + 2 + 2);
    expect(wire[end]).toBe(0xDD);
  });

  it("rejects truncated length header", () => {
    expect(() => readString(new Uint8Array([0x05]), 0)).toThrow(/out of bounds/);
  });

  it("rejects body that runs off the end", () => {
    const bad = new Uint8Array([0x05, 0x00, 0x68]);
    expect(() => readString(bad, 0)).toThrow(/out of bounds/);
  });

  it("rejects invalid UTF-8 string body", () => {
    const bad = new Uint8Array([0x01, 0x00, 0xFF]);
    expect(() => readString(bad, 0)).toThrow(/UTF-8/);
  });

  it("rejects too-long string at encode", () => {
    const huge = "x".repeat(0x10000);
    expect(() => appendString(huge, [])).toThrow(/too long/);
  });
});

describe("9P qid codec", () => {
  it("encodes type(1) | version(4 LE) | path(8 LE) — 13 bytes", () => {
    const chunks = [];
    appendQid({ type: QID_TYPE.DIR, version: 0x01020304, path: 0x1122334455667788n }, chunks);
    expect(concat(chunks)).toEqual(new Uint8Array([
      0x80,
      0x04, 0x03, 0x02, 0x01,
      0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    ]));
  });

  it.each([
    ["dir, version 0, path 0",      { type: QID_TYPE.DIR,     version: 0,           path: 0n }],
    ["file, version 1, small path", { type: QID_TYPE.FILE,    version: 1,           path: 42n }],
    ["symlink, version max u32",    { type: QID_TYPE.SYMLINK, version: 0xFFFFFFFF,  path: 0xCAFEBABEDEADBEEFn }],
    ["path = u64 max",              { type: QID_TYPE.FILE,    version: 0,           path: 0xFFFFFFFFFFFFFFFFn }],
  ])("%s round-trips", (_label, qid) => {
    const chunks = [];
    appendQid(qid, chunks);
    const wire = concat(chunks);
    const [got, end] = readQid(wire, 0);
    expect(got).toEqual(qid);
    expect(end).toBe(13);
  });

  it("readQid respects offset and reports newOffset", () => {
    const chunks = [new Uint8Array([0xAA])];
    appendQid({ type: QID_TYPE.FILE, version: 7, path: 99n }, chunks);
    chunks.push(new Uint8Array([0xBB]));
    const wire = concat(chunks);
    const [qid, end] = readQid(wire, 1);
    expect(qid.type).toBe(0x00);
    expect(qid.version).toBe(7);
    expect(qid.path).toBe(99n);
    expect(end).toBe(14);
    expect(wire[end]).toBe(0xBB);
  });

  it("rejects truncated qid", () => {
    expect(() => readQid(new Uint8Array(12), 0)).toThrow(/out of bounds/);
  });

  it("rejects non-BigInt path at encode", () => {
    expect(() => appendQid({ type: 0, version: 0, path: 1 }, [])).toThrow(/BigInt/);
  });

  it("rejects negative path BigInt", () => {
    expect(() => appendQid({ type: 0, version: 0, path: -1n }, [])).toThrow(/u64 range/);
  });

  it("rejects type out of u8 range", () => {
    expect(() => appendQid({ type: 0x100, version: 0, path: 0n }, [])).toThrow(/u8/);
  });

  it("rejects version out of u32 range", () => {
    expect(() => appendQid({ type: 0, version: 0x100000000, path: 0n }, [])).toThrow(/u32/);
  });
});
