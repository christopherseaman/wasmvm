// Internal little-endian helpers shared by frame-codec.js and ninep-codec.js.
// Not part of the public package surface.

export function writeU8(view, offset, v) {
  view.setUint8(offset, v);
}

export function writeU16LE(view, offset, v) {
  view.setUint16(offset, v, true);
}

export function writeU32LE(view, offset, v) {
  view.setUint32(offset, v >>> 0, true);
}

export function writeU64LE(view, offset, v) {
  view.setBigUint64(offset, BigInt.asUintN(64, v), true);
}

export function readU8(view, offset) {
  return view.getUint8(offset);
}

export function readU16LE(view, offset) {
  return view.getUint16(offset, true);
}

export function readU32LE(view, offset) {
  return view.getUint32(offset, true);
}

export function readU64LE(view, offset) {
  return view.getBigUint64(offset, true);
}

export function checkBounds(bytes, offset, need, label) {
  if (offset + need > bytes.byteLength) {
    throw new Error(`${label}: out of bounds (need ${need} at ${offset}, have ${bytes.byteLength})`);
  }
}

export function viewOf(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

export function concat(chunks) {
  let total = 0;
  for (const c of chunks) total += c.byteLength;
  const out = new Uint8Array(total);
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.byteLength;
  }
  return out;
}

export function assertU8(v, label) {
  if (!Number.isInteger(v) || v < 0 || v > 0xff) {
    throw new Error(`${label}: expected u8, got ${v}`);
  }
}

export function assertU16(v, label) {
  if (!Number.isInteger(v) || v < 0 || v > 0xffff) {
    throw new Error(`${label}: expected u16, got ${v}`);
  }
}

export function assertU32(v, label) {
  if (!Number.isInteger(v) || v < 0 || v > 0xffffffff) {
    throw new Error(`${label}: expected u32, got ${v}`);
  }
}
