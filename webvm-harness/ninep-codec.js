// 9P2000.L wire format per spec/04-ninep-server.md, JS side.
// Used by webvm-9p-mount.js (the JS-side 9P client) only if the W4 investigation
// concludes that we must implement 9P as a `dir`-mount shim (rather than using
// CheerpX's internal 9P support). If CheerpX accepts a real `9p` mount config
// directly, this file may go unused — keep it small and tested anyway.
//
// Message: size(4 LE) | type(1) | tag(2 LE) | body
//
// `qid.path` is u64 on the wire; this codec uses BigInt for that field on the
// JS side because Number cannot represent the full u64 range exactly.

import {
  writeU8, writeU16LE, writeU32LE, writeU64LE,
  readU8, readU16LE, readU32LE, readU64LE,
  checkBounds, viewOf, concat, assertU8, assertU16, assertU32,
} from "./_le.js";

export const OP = Object.freeze({
  Tlerror:    6,  Rlerror:    7,
  Tstatfs:    8,  Rstatfs:    9,
  Tlopen:    12,  Rlopen:    13,
  Tlcreate:  14,  Rlcreate:  15,
  Tgetattr:  24,  Rgetattr:  25,
  Tsetattr:  26,  Rsetattr:  27,
  Treaddir:  40,  Rreaddir:  41,
  Tfsync:    50,  Rfsync:    51,
  Tmkdir:    70,  Rmkdir:    71,
  Tunlinkat: 72,  Runlinkat: 73,
  Tversion: 100,  Rversion: 101,
  Tattach:  104,  Rattach:  105,
  Twalk:    110,  Rwalk:    111,
  Tread:    116,  Rread:    117,
  Twrite:   118,  Rwrite:   119,
  Tclunk:   120,  Rclunk:   121,
});

export const QID_TYPE = Object.freeze({ FILE: 0x00, SYMLINK: 0x02, DIR: 0x80 });

const MSG_HEADER = 7;
const QID_SIZE = 13;

const utf8enc = new TextEncoder();
const utf8dec = new TextDecoder("utf-8", { fatal: true });

/**
 * Encode a message (size header included).
 * @param {number} op
 * @param {number} tag — u16
 * @param {Uint8Array} body
 * @returns {Uint8Array}
 */
export function encodeMessage(op, tag, body) {
  assertU8(op, "encodeMessage.op");
  assertU16(tag, "encodeMessage.tag");
  if (!(body instanceof Uint8Array)) {
    throw new Error("encodeMessage.body: expected Uint8Array");
  }
  const total = MSG_HEADER + body.byteLength;
  if (total > 0xffffffff) {
    throw new Error(`encodeMessage: total size ${total} exceeds u32`);
  }
  const out = new Uint8Array(total);
  const v = viewOf(out);
  writeU32LE(v, 0, total);
  writeU8(v, 4, op);
  writeU16LE(v, 5, tag);
  out.set(body, MSG_HEADER);
  return out;
}

/**
 * Decode a message. Throws on short or truncated input.
 * @param {Uint8Array} bytes
 * @returns {{ op:number, tag:number, body:Uint8Array }}
 */
export function decodeMessage(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new Error("decodeMessage: expected Uint8Array");
  }
  if (bytes.byteLength < MSG_HEADER) {
    throw new Error(`decodeMessage: short header (${bytes.byteLength} < ${MSG_HEADER})`);
  }
  const v = viewOf(bytes);
  const size = readU32LE(v, 0);
  if (size !== bytes.byteLength) {
    throw new Error(`decodeMessage: size mismatch (header says ${size}, frame is ${bytes.byteLength})`);
  }
  const op = readU8(v, 4);
  const tag = readU16LE(v, 5);
  const body = bytes.slice(MSG_HEADER, size);
  return { op, tag, body };
}

/**
 * Encode a 9P string (len(2 LE) | utf8 bytes) appended to `chunks`.
 * @param {string} s
 * @param {Uint8Array[]} chunks — caller accumulates and concatenates
 */
export function appendString(s, chunks) {
  if (typeof s !== "string") {
    throw new Error("appendString: expected string");
  }
  if (!Array.isArray(chunks)) {
    throw new Error("appendString: chunks must be an array");
  }
  const bytes = utf8enc.encode(s);
  if (bytes.byteLength > 0xffff) {
    throw new Error(`appendString: too long (${bytes.byteLength} > 65535)`);
  }
  const header = new Uint8Array(2);
  writeU16LE(viewOf(header), 0, bytes.byteLength);
  chunks.push(header);
  chunks.push(bytes);
}

/**
 * Read a 9P string starting at `offset`. Returns [string, newOffset].
 * @param {Uint8Array} bytes
 * @param {number} offset
 * @returns {[string, number]}
 */
export function readString(bytes, offset) {
  if (!(bytes instanceof Uint8Array)) {
    throw new Error("readString: expected Uint8Array");
  }
  checkBounds(bytes, offset, 2, "readString.length");
  const v = viewOf(bytes);
  const len = readU16LE(v, offset);
  const start = offset + 2;
  checkBounds(bytes, start, len, "readString.body");
  let s;
  try {
    s = utf8dec.decode(bytes.subarray(start, start + len));
  } catch (e) {
    throw new Error(`readString: invalid UTF-8: ${e.message}`);
  }
  return [s, start + len];
}

/**
 * Encode a 13-byte qid: type(1) | version(4 LE) | path(8 LE).
 * @param {{ type:number, version:number, path:bigint }} qid
 * @param {Uint8Array[]} chunks
 */
export function appendQid(qid, chunks) {
  if (qid == null || typeof qid !== "object") {
    throw new Error("appendQid: expected qid object");
  }
  if (!Array.isArray(chunks)) {
    throw new Error("appendQid: chunks must be an array");
  }
  assertU8(qid.type, "appendQid.type");
  assertU32(qid.version, "appendQid.version");
  if (typeof qid.path !== "bigint") {
    throw new Error("appendQid.path: expected BigInt");
  }
  if (qid.path < 0n || qid.path > 0xffffffffffffffffn) {
    throw new Error(`appendQid.path: out of u64 range (${qid.path})`);
  }
  const buf = new Uint8Array(QID_SIZE);
  const v = viewOf(buf);
  writeU8(v, 0, qid.type);
  writeU32LE(v, 1, qid.version);
  writeU64LE(v, 5, qid.path);
  chunks.push(buf);
}

/**
 * Read a qid starting at `offset`. Returns [qid, newOffset].
 * @param {Uint8Array} bytes
 * @param {number} offset
 * @returns {[{type:number, version:number, path:bigint}, number]}
 */
export function readQid(bytes, offset) {
  if (!(bytes instanceof Uint8Array)) {
    throw new Error("readQid: expected Uint8Array");
  }
  checkBounds(bytes, offset, QID_SIZE, "readQid");
  const v = viewOf(bytes);
  const type = readU8(v, offset);
  const version = readU32LE(v, offset + 1);
  const path = readU64LE(v, offset + 5);
  return [{ type, version, path }, offset + QID_SIZE];
}

export { concat };
