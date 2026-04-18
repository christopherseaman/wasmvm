import { describe, it, expect } from "vitest";
import {
  OP, FAMILY, PROTO,
  encodeFrame, decodeFrame,
  encodeConnectPayload, decodeConnectPayload,
} from "../frame-codec.js";

describe("frame header byte layout", () => {
  it("encodes op | conn_id LE | length LE | payload exactly per spec/03 table", () => {
    const got = encodeFrame(0x01, 0x12345678, new Uint8Array([0xAA, 0xBB]));
    expect(got).toEqual(new Uint8Array([
      0x01,
      0x78, 0x56, 0x34, 0x12,
      0x02, 0x00, 0x00, 0x00,
      0xAA, 0xBB,
    ]));
  });

  it("encodes empty payload (CLOSE) as 9-byte header", () => {
    const got = encodeFrame(OP.CLOSE, 1);
    expect(got).toEqual(new Uint8Array([
      0x03,
      0x01, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
    ]));
  });

  it("encodes max u32 conn_id without sign-extension", () => {
    const got = encodeFrame(OP.DATA, 0xFFFFFFFF, new Uint8Array(0));
    expect(got.slice(1, 5)).toEqual(new Uint8Array([0xFF, 0xFF, 0xFF, 0xFF]));
  });
});

describe("frame round-trip", () => {
  it.each([
    ["empty payload", OP.CLOSE, 7, new Uint8Array(0)],
    ["one byte", OP.DATA, 1, new Uint8Array([0x42])],
    ["64 KiB", OP.DATA, 99, new Uint8Array(65536).fill(0xCD)],
    ["1 MiB max DATA per spec", OP.DATA, 12345, new Uint8Array(1024 * 1024).fill(0x5A)],
  ])("%s round-trips", (_label, op, connId, payload) => {
    const wire = encodeFrame(op, connId, payload);
    const out = decodeFrame(wire);
    expect(out.op).toBe(op);
    expect(out.connId).toBe(connId);
    expect(out.payload).toEqual(payload);
  });
});

describe("frame decode error cases", () => {
  it("rejects buffer shorter than the 9-byte header", () => {
    expect(() => decodeFrame(new Uint8Array(8))).toThrow(/short header/);
  });

  it("rejects length-mismatch (header says more than is present)", () => {
    const truncated = new Uint8Array([0x02, 0,0,0,0,  0x10,0,0,0]);
    expect(() => decodeFrame(truncated)).toThrow(/length mismatch/);
  });

  it("rejects trailing bytes (header says less than is present)", () => {
    const trailing = new Uint8Array([0x02, 0,0,0,0,  0x01,0,0,0,  0xAA, 0xBB]);
    expect(() => decodeFrame(trailing)).toThrow(/length mismatch/);
  });

  it("rejects non-Uint8Array input", () => {
    expect(() => decodeFrame([0,1,2,3,4,5,6,7,8])).toThrow(/Uint8Array/);
  });
});

describe("frame encode argument validation", () => {
  it("rejects op out of u8 range", () => {
    expect(() => encodeFrame(0x100, 0)).toThrow(/u8/);
  });

  it("rejects negative conn_id", () => {
    expect(() => encodeFrame(OP.DATA, -1)).toThrow(/u32/);
  });

  it("rejects non-Uint8Array payload", () => {
    expect(() => encodeFrame(OP.DATA, 0, [0x00])).toThrow(/Uint8Array/);
  });
});

describe("CONNECT payload byte layout", () => {
  it("places port at offset 4+host_len (regression: NOT 2+host_len)", () => {
    const got = encodeConnectPayload({
      family: FAMILY.IPV4, proto: PROTO.TCP, host: "1.2.3.4", port: 0x5000,
    });
    const hostBytes = new TextEncoder().encode("1.2.3.4");
    expect(got).toEqual(new Uint8Array([
      0x04,
      0x06,
      hostBytes.length & 0xff, (hostBytes.length >> 8) & 0xff,
      ...hostBytes,
      0x00, 0x50,
    ]));
  });

  it("encodes IPv6 literal with port LE", () => {
    const host = "::1";
    const got = encodeConnectPayload({
      family: FAMILY.IPV6, proto: PROTO.TCP, host, port: 8080,
    });
    const hostBytes = new TextEncoder().encode(host);
    expect(got[0]).toBe(0x06);
    expect(got[1]).toBe(0x06);
    expect(got[2]).toBe(hostBytes.length);
    expect(got[3]).toBe(0x00);
    const portOff = 4 + hostBytes.length;
    expect(got[portOff]).toBe(0x90);
    expect(got[portOff + 1]).toBe(0x1F);
  });
});

describe("CONNECT payload round-trip", () => {
  it.each([
    ["IPv4 TCP", { family: 4, proto: 6,  host: "192.0.2.1",          port: 80 }],
    ["IPv6 TCP", { family: 6, proto: 6,  host: "2001:db8::1",        port: 443 }],
    ["IPv4 UDP", { family: 4, proto: 17, host: "10.0.0.1",           port: 53 }],
    ["DNS hostname",   { family: 4, proto: 6, host: "example.com",   port: 8080 }],
    ["non-ASCII",      { family: 4, proto: 6, host: "münchen.example", port: 80 }],
    ["emoji hostname", { family: 4, proto: 6, host: "host-\u{1F600}.test", port: 1 }],
    ["port 0",         { family: 4, proto: 6, host: "a",             port: 0 }],
    ["port max u16",   { family: 4, proto: 6, host: "a",             port: 0xFFFF }],
    ["empty host",     { family: 4, proto: 6, host: "",              port: 1234 }],
  ])("%s round-trips", (_label, args) => {
    const wire = encodeConnectPayload(args);
    const out = decodeConnectPayload(wire);
    expect(out).toEqual(args);
  });
});

describe("CONNECT payload error cases", () => {
  it("rejects port > u16 max", () => {
    expect(() =>
      encodeConnectPayload({ family: 4, proto: 6, host: "a", port: 65536 }),
    ).toThrow(/u16/);
  });

  it("rejects buffer shorter than 6 bytes", () => {
    expect(() => decodeConnectPayload(new Uint8Array(5))).toThrow(/short/);
  });

  it("rejects host_len that overruns the buffer", () => {
    const bad = new Uint8Array([0x04, 0x06, 0xFF, 0x00, 0x00, 0x00]);
    expect(() => decodeConnectPayload(bad)).toThrow(/length mismatch/);
  });

  it("rejects trailing bytes after port", () => {
    const wire = encodeConnectPayload({ family: 4, proto: 6, host: "a", port: 1 });
    const padded = new Uint8Array(wire.length + 1);
    padded.set(wire);
    expect(() => decodeConnectPayload(padded)).toThrow(/length mismatch/);
  });

  it("rejects invalid UTF-8 in host", () => {
    const bad = new Uint8Array([0x04, 0x06, 0x01, 0x00, 0xFF, 0x00, 0x00]);
    expect(() => decodeConnectPayload(bad)).toThrow(/UTF-8/);
  });
});
