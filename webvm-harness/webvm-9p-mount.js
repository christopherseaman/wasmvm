// CheerpX `dir`-mount device shim that proxies VFS ops over a 9P2000.L
// WebSocket to the Swift NinePServer (per spec/04-ninep-server.md).
//
// =====================================================================
// CheerpOSDevice / dir-mount interface (discovered shape)
// =====================================================================
//
// `cxcore.wasm` does not include the 9p.ko driver, so we cannot mount
// type "9p". Instead we use type "dir" and supply a dev whose VFS ops
// match the legacy CheerpJ-derived contract that `cheerpOS.js` (vendor
// code, lines 116, 118, 239, 919, 920) and `cx_esm.js` rely on:
//
//   mountOps = {
//     statAsync(mp, path, fileRef, cb),         // populate fileRef.{permType,inodeId,uid,gid,fileLength,lastModified}
//     listAsync(mp, path, fileRef, cb),         // call fileRef.push(name) for each child
//     makeFileData(mp, path, mode, uid, gid, cb),// resolve to a fileData with .mount = inodeOps
//     createDirAsync(mp, path, mode, uid, gid, cb),
//     renameAsync(mp, src, dst, cb),
//     linkAsync(mp, src, dst, cb),
//     unlinkAsync(mp, path, cb),
//   }
//   inodeOps = {
//     readAsync(fileData, fileOffset, buf, off, len, cb),  // cb(bytesRead | -errno)
//     writeAsync(fileData, fileOffset, buf, off, len, cb), // cb(bytesWritten | -errno)
//     close(fileData),
//   }
//
// The dev passed in `Linux.create({mounts: [{type:"dir", path, dev}]})`
// must extend `CheerpOSDevice` so `dev.this` (the C++-side handle) is
// valid; the engine reads our methods reflectively. Field names like
// `permType`, `inodeId`, etc. are stable across CheerpX versions
// because cheerpOS.js is shipped unchanged.
//
// W6 NOTE: this interface is the static-analysis best guess. The first
// runtime probe in a real browser should call `dev.__probe()` (defined
// below) and adjust if any method names differ. The 9P translations
// are independent of which method names CheerpX actually invokes.
// =====================================================================

import {
  OP, QID_TYPE,
  encodeMessage, decodeMessage,
  appendString, readString,
  appendQid, readQid,
  concat,
} from "./ninep-codec.js";

// CheerpJFileData mode bits (matches cheerpOS.js lines 104-110).
const S_IFREG = 0x8000;
const S_IFDIR = 0x4000;
const S_IFLNK = 0xa000;

const NOFID = 0xffffffff;
const ROOT_FID = 1;
const MSIZE = 65536;
const VERSION = "9P2000.L";

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8");

function u32(v) {
  const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v >>> 0, true); return b;
}
function u64(v) {
  const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(v), true); return b;
}
function u16(v) {
  const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, v, true); return b;
}

// Try to locate CheerpOSDevice at module load. Real harness imports cx.esm.js
// before loading us; under Vitest (no DOM) the import would crash, so guard.
let CheerpOSDeviceBase = class {
  constructor() { this.this = null; }
  delete() {}
};

export function setBaseClass(cls) {
  CheerpOSDeviceBase = cls;
}

export class NinePDirDevice {
  constructor(wsUrl) {
    if (typeof wsUrl !== "string") {
      throw new Error("NinePDirDevice: wsUrl must be a string");
    }
    this._wsUrl = wsUrl;
    this._ws = null;
    this._tag = 1;
    this._pending = new Map(); // tag -> { resolve, reject }
    this._fid = ROOT_FID + 1;
    this._inodeMap = new Map(); // qid.path bigint -> small int
    this._inodeNext = 1;
    this.mountOps = this._buildMountOps();
    this.inodeOps = this._buildInodeOps();
    // why: CheerpX VFS reads `dev.this` (a C++ handle); harmless `null` here
    // — `mountOps`/`inodeOps` carry the actual JS callbacks the engine reads.
    this.this = null;
  }

  // Probe helper for runtime debugging — call from browser dev console.
  __probe() {
    return {
      mountOps: Object.keys(this.mountOps),
      inodeOps: Object.keys(this.inodeOps),
      proto: Object.getOwnPropertyNames(Object.getPrototypeOf(this)),
    };
  }

  async connect() {
    if (this._ws) return this._connectPromise;
    const ws = new WebSocket(this._wsUrl);
    ws.binaryType = "arraybuffer";
    this._ws = ws;
    this._connectPromise = new Promise((resolve, reject) => {
      ws.addEventListener("open", async () => {
        try {
          await this._handshake();
          resolve();
        } catch (e) {
          reject(e);
        }
      }, { once: true });
      ws.addEventListener("error", () => reject(new Error(`WS error opening ${this._wsUrl}`)), { once: true });
    });
    ws.addEventListener("message", (ev) => this._onMessage(ev));
    ws.addEventListener("close", () => this._onClose());
    return this._connectPromise;
  }

  delete() {
    if (this._ws && this._ws.readyState <= 1) this._ws.close();
    this._ws = null;
    for (const p of this._pending.values()) p.reject(new Error("9p device deleted"));
    this._pending.clear();
  }

  // ---- 9P request helpers -------------------------------------------

  _allocTag() {
    const t = this._tag++;
    if (this._tag > 0xffff) this._tag = 1;
    return t;
  }

  _allocFid() {
    const f = this._fid++;
    if (this._fid > 0xfffffffe) this._fid = ROOT_FID + 1;
    return f;
  }

  _request(op, body) {
    const tag = this._allocTag();
    return new Promise((resolve, reject) => {
      this._pending.set(tag, { resolve, reject, op });
      try {
        this._ws.send(encodeMessage(op, tag, body));
      } catch (e) {
        this._pending.delete(tag);
        reject(e);
      }
    });
  }

  _onMessage(ev) {
    const data = ev.data;
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
      : data instanceof Uint8Array ? data : null;
    if (!bytes) return;
    const msg = decodeMessage(bytes);
    const p = this._pending.get(msg.tag);
    if (!p) return;
    this._pending.delete(msg.tag);
    if (msg.op === OP.Rlerror) {
      const ecode = new DataView(msg.body.buffer, msg.body.byteOffset).getUint32(0, true);
      const err = new Error(`9P Rlerror errno=${ecode}`);
      err.errno = ecode;
      p.reject(err);
    } else {
      p.resolve(msg);
    }
  }

  _onClose() {
    for (const p of this._pending.values()) p.reject(new Error("9p WS closed"));
    this._pending.clear();
  }

  async _handshake() {
    // Tversion: msize(4) | version(s)
    const vbody = [u32(MSIZE)];
    appendString(VERSION, vbody);
    await this._request(OP.Tversion, concat(vbody));
    // Tattach: fid(4) | afid(4) | uname(s) | aname(s) | n_uname(4)
    const abody = [u32(ROOT_FID), u32(NOFID)];
    appendString("user", abody);
    appendString("/", abody);
    abody.push(u32(1000));
    await this._request(OP.Tattach, concat(abody));
  }

  // Walk from ROOT to `path` into a fresh fid. Returns newfid on full match,
  // or throws if any component does not exist.
  async _walkTo(path) {
    const parts = path.split("/").filter(Boolean);
    const newfid = this._allocFid();
    const wbody = [u32(ROOT_FID), u32(newfid), u16(parts.length)];
    for (const name of parts) appendString(name, wbody);
    const r = await this._request(OP.Twalk, concat(wbody));
    const nwqid = new DataView(r.body.buffer, r.body.byteOffset).getUint16(0, true);
    if (nwqid !== parts.length) {
      // partial walk — newfid not bound; nothing to clunk
      const err = new Error("ENOENT");
      err.errno = 2;
      throw err;
    }
    let off = 2;
    let lastQid = null;
    for (let i = 0; i < nwqid; i++) {
      const [q, no] = readQid(r.body, off);
      lastQid = q;
      off = no;
    }
    return { fid: newfid, qid: lastQid };
  }

  // Walk to the parent of `path` and return {parentFid, leafName}.
  async _walkToParent(path) {
    const parts = path.split("/").filter(Boolean);
    const leaf = parts.pop();
    const newfid = this._allocFid();
    const wbody = [u32(ROOT_FID), u32(newfid), u16(parts.length)];
    for (const name of parts) appendString(name, wbody);
    const r = await this._request(OP.Twalk, concat(wbody));
    const nwqid = new DataView(r.body.buffer, r.body.byteOffset).getUint16(0, true);
    if (nwqid !== parts.length) {
      const err = new Error("ENOENT (parent walk failed)");
      err.errno = 2;
      throw err;
    }
    return { parentFid: newfid, leafName: leaf };
  }

  async _clunk(fid) {
    try { await this._request(OP.Tclunk, u32(fid)); } catch {}
  }

  _qidToInodeId(qid) {
    let id = this._inodeMap.get(qid.path);
    if (id === undefined) {
      id = this._inodeNext++;
      this._inodeMap.set(qid.path, id);
    }
    return id;
  }

  _qidToPermType(qid) {
    if (qid.type & QID_TYPE.DIR) return S_IFDIR | 0o755;
    if (qid.type & QID_TYPE.SYMLINK) return S_IFLNK | 0o644;
    return S_IFREG | 0o644;
  }

  // ---- mountOps construction ---------------------------------------

  _buildMountOps() {
    const dev = this;
    return {
      statAsync(_mp, path, fileRef, cb) {
        dev._stat(path, fileRef).then(() => cb()).catch((e) => {
          fileRef.permType = 0;
          cb();
        });
      },
      listAsync(_mp, path, fileRef, cb) {
        dev._readdir(path, fileRef).then(() => cb()).catch(() => cb());
      },
      makeFileData(_mp, path, mode, uid, gid, cb) {
        dev._open(path, mode, uid, gid).then(cb).catch(() => cb(null));
      },
      createDirAsync(_mp, path, mode, uid, gid, cb) {
        dev._mkdir(path, mode, uid, gid).then(() => cb()).catch((e) => cb(e));
      },
      renameAsync(_mp, _src, _dst, cb) {
        // why: spec scope-cut — no atomic rename for MVP.
        const e = new Error("ENOSYS");
        e.errno = 38;
        cb(e);
      },
      linkAsync(_mp, _src, _dst, cb) {
        const e = new Error("ENOSYS");
        e.errno = 38;
        cb(e);
      },
      unlinkAsync(_mp, path, cb) {
        dev._unlink(path).then(() => cb()).catch((e) => cb(e));
      },
    };
  }

  _buildInodeOps() {
    const dev = this;
    return {
      readAsync(fileData, fileOffset, buf, off, len, cb) {
        dev._read(fileData, fileOffset, buf, off, len).then(cb).catch(() => cb(-5));
      },
      writeAsync(fileData, fileOffset, buf, off, len, cb) {
        dev._write(fileData, fileOffset, buf, off, len).then(cb).catch(() => cb(-5));
      },
      close(fileData) {
        if (fileData && fileData._9pFid !== undefined) {
          dev._clunk(fileData._9pFid);
          fileData._9pFid = undefined;
        }
      },
    };
  }

  // ---- VFS implementations -----------------------------------------

  async _stat(path, fileRef) {
    const { fid, qid } = await this._walkTo(path);
    try {
      // Tgetattr: fid(4) | request_mask(8 LE)
      const body = concat([u32(fid), u64(0x3fffn)]);
      const r = await this._request(OP.Tgetattr, body);
      const dv = new DataView(r.body.buffer, r.body.byteOffset, r.body.byteLength);
      // valid(8) | qid(13) | mode(4) | uid(4) | gid(4) | nlink(8) | rdev(8) | size(8) | ...
      let off = 8;
      const [q] = readQid(r.body, off); off += 13;
      const mode = dv.getUint32(off, true); off += 4;
      const uid = dv.getUint32(off, true); off += 4;
      const gid = dv.getUint32(off, true); off += 4;
      off += 8; // nlink
      off += 8; // rdev
      const size = dv.getBigUint64(off, true); off += 8;
      fileRef.permType = mode || this._qidToPermType(q);
      fileRef.inodeId = this._qidToInodeId(q);
      fileRef.uid = uid;
      fileRef.gid = gid;
      fileRef.fileLength = Number(size);
      fileRef.lastModified = 0;
    } finally {
      await this._clunk(fid);
    }
  }

  async _readdir(path, fileRef) {
    const { fid, qid } = await this._walkTo(path);
    try {
      // Tlopen with O_RDONLY=0
      await this._request(OP.Tlopen, concat([u32(fid), u32(0)]));
      let offset = 0n;
      const COUNT = 8192;
      while (true) {
        const body = concat([u32(fid), u64(offset), u32(COUNT)]);
        const r = await this._request(OP.Treaddir, body);
        const dv = new DataView(r.body.buffer, r.body.byteOffset);
        const dataLen = dv.getUint32(0, true);
        if (dataLen === 0) break;
        let off = 4;
        let progressed = false;
        while (off < 4 + dataLen) {
          const [q, no] = readQid(r.body, off); off = no;
          offset = dv.getBigUint64(off, true); off += 8;
          const _type = r.body[off]; off += 1;
          const [name, no2] = readString(r.body, off); off = no2;
          if (name !== "." && name !== "..") fileRef.push(name);
          progressed = true;
        }
        if (!progressed) break;
      }
    } finally {
      await this._clunk(fid);
    }
  }

  async _open(path, mode, _uid, gid) {
    const wantWrite = typeof mode === "string" && (mode.startsWith("w") || mode.startsWith("rw") || mode.includes("+"));
    const wantCreate = typeof mode === "string" && mode.startsWith("w");
    if (wantCreate) {
      // Walk to parent, then Tlcreate.
      const { parentFid, leafName } = await this._walkToParent(path);
      // Tlcreate: fid(4) | name(s) | flags(4) | mode(4) | gid(4)
      const cbody = [u32(parentFid)];
      appendString(leafName, cbody);
      cbody.push(u32(0o102)); // O_RDWR|O_CREAT
      cbody.push(u32(0o644));
      cbody.push(u32(gid || 0));
      const r = await this._request(OP.Tlcreate, concat(cbody));
      const [q] = readQid(r.body, 0);
      // After Tlcreate, parentFid IS now the new file fid.
      return this._buildFileData(path, parentFid, q, S_IFREG | 0o644);
    }
    const { fid, qid } = await this._walkTo(path);
    try {
      const flags = wantWrite ? 0o2 : 0o0; // O_RDWR or O_RDONLY
      await this._request(OP.Tlopen, concat([u32(fid), u32(flags)]));
      return this._buildFileData(path, fid, qid, this._qidToPermType(qid));
    } catch (e) {
      await this._clunk(fid);
      throw e;
    }
  }

  _buildFileData(path, fid, qid, permType) {
    return {
      path,
      permType,
      inodeId: this._qidToInodeId(qid),
      fileLength: 0,
      mount: this.inodeOps,
      _9pFid: fid,
    };
  }

  async _read(fileData, fileOffset, buf, off, len) {
    let total = 0;
    while (total < len) {
      const want = Math.min(len - total, 32768);
      const body = concat([u32(fileData._9pFid), u64(BigInt(fileOffset + total)), u32(want)]);
      const r = await this._request(OP.Tread, body);
      const dv = new DataView(r.body.buffer, r.body.byteOffset);
      const got = dv.getUint32(0, true);
      if (got === 0) break;
      const data = r.body.subarray(4, 4 + got);
      buf.set(data, off + total);
      total += got;
      if (got < want) break;
    }
    return total;
  }

  async _write(fileData, fileOffset, buf, off, len) {
    let total = 0;
    while (total < len) {
      const want = Math.min(len - total, 32768);
      const slice = buf.subarray(off + total, off + total + want);
      const body = concat([u32(fileData._9pFid), u64(BigInt(fileOffset + total)), u32(want), slice]);
      const r = await this._request(OP.Twrite, body);
      const got = new DataView(r.body.buffer, r.body.byteOffset).getUint32(0, true);
      if (got === 0) break;
      total += got;
    }
    return total;
  }

  async _mkdir(path, mode, _uid, gid) {
    const { parentFid, leafName } = await this._walkToParent(path);
    try {
      const body = [u32(parentFid)];
      appendString(leafName, body);
      body.push(u32(mode || 0o755));
      body.push(u32(gid || 0));
      await this._request(OP.Tmkdir, concat(body));
    } finally {
      await this._clunk(parentFid);
    }
  }

  async _unlink(path) {
    const { parentFid, leafName } = await this._walkToParent(path);
    try {
      // Tunlinkat: dfid(4) | name(s) | flags(4)
      const body = [u32(parentFid)];
      appendString(leafName, body);
      body.push(u32(0));
      await this._request(OP.Tunlinkat, concat(body));
    } finally {
      await this._clunk(parentFid);
    }
  }
}
