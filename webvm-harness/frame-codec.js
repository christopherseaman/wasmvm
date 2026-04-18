// NetBridge wire format per spec/03-net-bridge.md, JS side.
//
// Frame: op(1) | conn_id(4 LE) | length(4 LE) | payload
// One WebSocket binary message = one frame.

import {
  writeU8, writeU16LE, writeU32LE,
  readU8, readU16LE, readU32LE,
  checkBounds, viewOf, assertU8, assertU16, assertU32,
} from "./_le.js";

export const OP = Object.freeze({
  CONNECT:     0x01,
  DATA:        0x02,
  CLOSE:       0x03,
  CONNECT_OK:  0x04,
  CONNECT_ERR: 0x05,
  LISTEN:      0x06,
  LISTEN_OK:   0x07,
  ACCEPT:      0x08,
  RESOLVE:     0x09,
  RESOLVE_OK:  0x0A,
});

export const FAMILY = Object.freeze({ IPV4: 4, IPV6: 6 });
export const PROTO  = Object.freeze({ TCP:  6, UDP: 17 });

const FRAME_HEADER = 9;

const utf8enc = new TextEncoder();
const utf8dec = new TextDecoder("utf-8", { fatal: true });

/**
 * Encode a frame.
 * @param {number} op — one of OP values
 * @param {number} connId — u32
 * @param {Uint8Array} [payload]
 * @returns {Uint8Array}
 */
export function encodeFrame(op, connId, payload = new Uint8Array(0)) {
  assertU8(op, "encodeFrame.op");
  assertU32(connId, "encodeFrame.connId");
  if (!(payload instanceof Uint8Array)) {
    throw new Error("encodeFrame.payload: expected Uint8Array");
  }
  const out = new Uint8Array(FRAME_HEADER + payload.byteLength);
  const v = viewOf(out);
  writeU8(v, 0, op);
  writeU32LE(v, 1, connId);
  writeU32LE(v, 5, payload.byteLength);
  out.set(payload, FRAME_HEADER);
  return out;
}

/**
 * Decode a frame. Throws on short or truncated input. Trailing bytes are an error.
 * @param {Uint8Array} bytes
 * @returns {{ op:number, connId:number, payload:Uint8Array }}
 */
export function decodeFrame(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new Error("decodeFrame: expected Uint8Array");
  }
  if (bytes.byteLength < FRAME_HEADER) {
    throw new Error(`decodeFrame: short header (${bytes.byteLength} < ${FRAME_HEADER})`);
  }
  const v = viewOf(bytes);
  const op = readU8(v, 0);
  const connId = readU32LE(v, 1);
  const length = readU32LE(v, 5);
  if (FRAME_HEADER + length !== bytes.byteLength) {
    throw new Error(`decodeFrame: length mismatch (header says ${length}, frame body is ${bytes.byteLength - FRAME_HEADER})`);
  }
  const payload = bytes.slice(FRAME_HEADER, FRAME_HEADER + length);
  return { op, connId, payload };
}

/**
 * Encode a CONNECT payload for embedding in a frame.
 * Layout: family(1) | proto(1) | host_len(2 LE) | host(N) | port(2 LE).
 * @param {{ family:number, proto:number, host:string, port:number }} args
 * @returns {Uint8Array}
 */
export function encodeConnectPayload({ family, proto, host, port }) {
  assertU8(family, "encodeConnectPayload.family");
  assertU8(proto, "encodeConnectPayload.proto");
  assertU16(port, "encodeConnectPayload.port");
  if (typeof host !== "string") {
    throw new Error("encodeConnectPayload.host: expected string");
  }
  const hostBytes = utf8enc.encode(host);
  if (hostBytes.byteLength > 0xffff) {
    throw new Error(`encodeConnectPayload.host: too long (${hostBytes.byteLength} > 65535)`);
  }
  const out = new Uint8Array(1 + 1 + 2 + hostBytes.byteLength + 2);
  const v = viewOf(out);
  writeU8(v, 0, family);
  writeU8(v, 1, proto);
  writeU16LE(v, 2, hostBytes.byteLength);
  out.set(hostBytes, 4);
  writeU16LE(v, 4 + hostBytes.byteLength, port);
  return out;
}

/**
 * Decode a CONNECT payload.
 * @param {Uint8Array} bytes
 * @returns {{ family:number, proto:number, host:string, port:number }}
 */
export function decodeConnectPayload(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new Error("decodeConnectPayload: expected Uint8Array");
  }
  if (bytes.byteLength < 6) {
    throw new Error(`decodeConnectPayload: short (${bytes.byteLength} < 6)`);
  }
  const v = viewOf(bytes);
  const family = readU8(v, 0);
  const proto = readU8(v, 1);
  const hostLen = readU16LE(v, 2);
  const portOffset = 4 + hostLen;
  if (bytes.byteLength !== portOffset + 2) {
    throw new Error(`decodeConnectPayload: length mismatch (host_len=${hostLen}, expected total=${portOffset + 2}, got ${bytes.byteLength})`);
  }
  const hostBytes = bytes.subarray(4, portOffset);
  let host;
  try {
    host = utf8dec.decode(hostBytes);
  } catch (e) {
    throw new Error(`decodeConnectPayload: invalid UTF-8 in host: ${e.message}`);
  }
  const port = readU16LE(v, portOffset);
  return { family, proto, host, port };
}
