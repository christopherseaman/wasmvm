// Integration test for webvm-9p-mount.js.
// A real Node `ws` server speaks 9P2000.L using the shared ninep-codec.js;
// the JS shim drives it through its public dir-mount-device interface.
//
// We verify the shim issues correct Tversion/Tattach/Twalk/Tlopen/Tread/
// Treaddir/Twrite/Tmkdir/Tunlinkat/Tclunk sequences in response to its
// public method calls, and that it correctly decodes R-replies built by
// the same codec.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { WebSocketServer } from "ws";
import {
  OP, QID_TYPE,
  encodeMessage, decodeMessage,
  appendString, readString,
  appendQid, readQid,
  concat,
} from "../ninep-codec.js";
import { NinePDirDevice } from "../webvm-9p-mount.js";

let wss;
let port;
let serverState;

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8");

function u32LE(v) {
  const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v >>> 0, true); return b;
}
function u64LE(v) {
  const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(v), true); return b;
}
function u16LE(v) {
  const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, v, true); return b;
}
function u8(v) {
  return new Uint8Array([v & 0xff]);
}

function readU32(body, off) {
  return new DataView(body.buffer, body.byteOffset, body.byteLength).getUint32(off, true);
}
function readU16(body, off) {
  return new DataView(body.buffer, body.byteOffset, body.byteLength).getUint16(off, true);
}
function readU64BI(body, off) {
  return new DataView(body.buffer, body.byteOffset, body.byteLength).getBigUint64(off, true);
}

// Minimal in-memory 9P server. Files are flat by absolute path.
function makeServer(tree) {
  // tree: { "/": {dir:true}, "/foo.txt": {data: Uint8Array}, ... }
  const fids = new Map(); // fid -> { path }
  const requests = []; // log of decoded T-messages

  function qidFor(path, entry) {
    const isDir = !!entry.dir;
    const isLink = !!entry.symlink;
    const type = isDir ? QID_TYPE.DIR : isLink ? QID_TYPE.SYMLINK : QID_TYPE.FILE;
    let h = 1469598103934665603n;
    for (const c of enc.encode(path)) { h ^= BigInt(c); h = (h * 1099511628211n) & 0xffffffffffffffffn; }
    return { type, version: 0, path: h };
  }

  function handle(send, body, op, tag) {
    requests.push({ op, tag, body });
    if (op === OP.Tversion) {
      // body: msize(4) | version_str(s)
      const msize = readU32(body, 0);
      const [ver] = readString(body, 4);
      const out = [];
      out.push(u32LE(Math.min(msize, 65536)));
      appendString(ver, out);
      return send(OP.Rversion, tag, concat(out));
    }
    if (op === OP.Tattach) {
      const fid = readU32(body, 0);
      // afid(4) | uname(s) | aname(s) | n_uname(4) — we don't strictly parse all
      fids.set(fid, { path: "/" });
      const out = [];
      appendQid(qidFor("/", tree["/"]), out);
      return send(OP.Rattach, tag, concat(out));
    }
    if (op === OP.Twalk) {
      const fid = readU32(body, 0);
      const newfid = readU32(body, 4);
      const nwname = readU16(body, 8);
      let off = 10;
      let path = fids.get(fid).path;
      const qids = [];
      for (let i = 0; i < nwname; i++) {
        const [name, no] = readString(body, off);
        off = no;
        path = path === "/" ? "/" + name : path + "/" + name;
        const entry = tree[path];
        if (!entry) {
          // partial walk: return qids accumulated so far without binding newfid
          break;
        }
        qids.push(qidFor(path, entry));
      }
      if (qids.length === nwname) {
        fids.set(newfid, { path });
      }
      const out = [u16LE(qids.length)];
      for (const q of qids) appendQid(q, out);
      return send(OP.Rwalk, tag, concat(out));
    }
    if (op === OP.Tlopen) {
      const fid = readU32(body, 0);
      const f = fids.get(fid);
      const entry = tree[f.path];
      const out = [];
      appendQid(qidFor(f.path, entry), out);
      out.push(u32LE(0)); // iounit
      return send(OP.Rlopen, tag, concat(out));
    }
    if (op === OP.Tread) {
      const fid = readU32(body, 0);
      const offset = Number(readU64BI(body, 4));
      const count = readU32(body, 12);
      const f = fids.get(fid);
      const entry = tree[f.path];
      const data = (entry.data || new Uint8Array(0)).subarray(offset, offset + count);
      const out = [u32LE(data.byteLength), data];
      return send(OP.Rread, tag, concat(out));
    }
    if (op === OP.Twrite) {
      const fid = readU32(body, 0);
      const offset = Number(readU64BI(body, 4));
      const count = readU32(body, 12);
      const data = body.subarray(16, 16 + count);
      const f = fids.get(fid);
      const entry = tree[f.path] || (tree[f.path] = { data: new Uint8Array(0) });
      const old = entry.data || new Uint8Array(0);
      const newLen = Math.max(old.byteLength, offset + data.byteLength);
      const buf = new Uint8Array(newLen);
      buf.set(old);
      buf.set(data, offset);
      entry.data = buf;
      return send(OP.Rwrite, tag, u32LE(data.byteLength));
    }
    if (op === OP.Tgetattr) {
      const fid = readU32(body, 0);
      const f = fids.get(fid);
      const entry = tree[f.path];
      const isDir = !!entry.dir;
      const out = [];
      out.push(u64LE(0x3fffn)); // valid mask
      appendQid(qidFor(f.path, entry), out);
      out.push(u32LE(isDir ? 0o040755 : 0o100644)); // mode
      out.push(u32LE(1000)); out.push(u32LE(1000)); // uid, gid
      out.push(u64LE(1)); // nlink
      out.push(u64LE(0)); // rdev
      out.push(u64LE(entry.data ? entry.data.byteLength : 0)); // size
      out.push(u64LE(4096)); // blksize
      out.push(u64LE(8)); // blocks
      // atime/mtime/ctime sec+nsec, btime sec+nsec, gen, data_version
      for (let i = 0; i < 10; i++) out.push(u64LE(0));
      return send(OP.Rgetattr, tag, concat(out));
    }
    if (op === OP.Treaddir) {
      const fid = readU32(body, 0);
      const offset = Number(readU64BI(body, 4));
      const count = readU32(body, 12);
      const f = fids.get(fid);
      const prefix = f.path === "/" ? "/" : f.path + "/";
      const entries = Object.keys(tree)
        .filter((p) => p !== f.path && p.startsWith(prefix) && !p.slice(prefix.length).includes("/"));
      const out = [];
      let used = 0;
      for (let i = offset; i < entries.length; i++) {
        const childPath = entries[i];
        const childEntry = tree[childPath];
        const name = childPath.slice(prefix.length);
        const nameBytes = enc.encode(name);
        const entrySize = 13 + 8 + 1 + 2 + nameBytes.length;
        if (used + entrySize > count) break;
        const chunks = [];
        appendQid(qidFor(childPath, childEntry), chunks);
        chunks.push(u64LE(i + 1));
        chunks.push(u8(childEntry.dir ? 4 : 8));
        appendString(name, chunks);
        out.push(...chunks);
        used += entrySize;
      }
      const merged = concat(out);
      return send(OP.Rreaddir, tag, concat([u32LE(merged.byteLength), merged]));
    }
    if (op === OP.Tclunk) {
      const fid = readU32(body, 0);
      fids.delete(fid);
      return send(OP.Rclunk, tag, new Uint8Array(0));
    }
    if (op === OP.Tmkdir) {
      // dfid(4) | name(s) | mode(4) | gid(4)
      const dfid = readU32(body, 0);
      const [name, no] = readString(body, 4);
      const f = fids.get(dfid);
      const path = f.path === "/" ? "/" + name : f.path + "/" + name;
      tree[path] = { dir: true };
      const out = [];
      appendQid(qidFor(path, tree[path]), out);
      return send(OP.Rmkdir, tag, concat(out));
    }
    if (op === OP.Tunlinkat) {
      // dfid(4) | name(s) | flags(4)
      const dfid = readU32(body, 0);
      const [name] = readString(body, 4);
      const f = fids.get(dfid);
      const path = f.path === "/" ? "/" + name : f.path + "/" + name;
      delete tree[path];
      return send(OP.Runlinkat, tag, new Uint8Array(0));
    }
    if (op === OP.Tlcreate) {
      // fid(4) | name(s) | flags(4) | mode(4) | gid(4)
      const fid = readU32(body, 0);
      const [name] = readString(body, 4);
      const f = fids.get(fid);
      const path = f.path === "/" ? "/" + name : f.path + "/" + name;
      tree[path] = { data: new Uint8Array(0) };
      // After Tlcreate, fid refers to the new file.
      f.path = path;
      const out = [];
      appendQid(qidFor(path, tree[path]), out);
      out.push(u32LE(0)); // iounit
      return send(OP.Rlcreate, tag, concat(out));
    }
    if (op === OP.Tfsync) {
      return send(OP.Rfsync, tag, new Uint8Array(0));
    }
    if (op === OP.Tsetattr) {
      return send(OP.Rsetattr, tag, new Uint8Array(0));
    }
    // Default: Rlerror EOPNOTSUPP=95
    const out = [u32LE(95)];
    return send(OP.Rlerror, tag, concat(out));
  }

  return { fids, requests, handle };
}

beforeEach(async () => {
  await new Promise((resolve) => {
    wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    wss.on("listening", () => { port = wss.address().port; resolve(); });
  });
  serverState = {
    tree: {
      "/": { dir: true },
      "/hello.txt": { data: enc.encode("hello world") },
      "/dir": { dir: true },
      "/dir/inner.bin": { data: new Uint8Array([1, 2, 3, 4]) },
    },
    handle: null,
    requests: null,
  };
  wss.on("connection", (ws) => {
    ws.binaryType = "arraybuffer";
    const srv = makeServer(serverState.tree);
    serverState.handle = srv.handle;
    serverState.requests = srv.requests;
    const send = (op, tag, body) => ws.send(encodeMessage(op, tag, body));
    ws.on("message", (data) => {
      const msg = decodeMessage(new Uint8Array(data));
      srv.handle(send, msg.body, msg.op, msg.tag);
    });
  });
});

afterEach(async () => {
  await new Promise((r) => wss.close(r));
});

describe("NinePDirDevice connection lifecycle", () => {
  it("connect() issues Tversion + Tattach and resolves", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Tversion);
    expect(ops).toContain(OP.Tattach);
    dev.delete();
  });
});

describe("NinePDirDevice VFS ops translate to 9P", () => {
  it("statAsync('/hello.txt') walks then getattrs and clunks", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    const stat = await new Promise((resolve, reject) => {
      const fileRef = {};
      dev.mountOps.statAsync(dev, "/hello.txt", fileRef, (err) => {
        if (err) reject(err); else resolve(fileRef);
      });
    });
    expect(stat.fileLength).toBe(11);
    expect(stat.permType & 0xf000).toBe(0x8000); // S_IFREG
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Twalk);
    expect(ops).toContain(OP.Tgetattr);
    expect(ops).toContain(OP.Tclunk);
    dev.delete();
  });

  it("listAsync('/dir') uses Treaddir and yields child names", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    const out = [];
    out.push = Array.prototype.push;
    await new Promise((resolve, reject) => {
      dev.mountOps.listAsync(dev, "/dir", out, (err) => {
        if (err) reject(err); else resolve();
      });
    });
    expect(out).toContain("inner.bin");
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Treaddir);
    dev.delete();
  });

  it("readAsync('/hello.txt') opens, reads, returns bytes", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    // makeFileData first to obtain a fileData with the open inode.
    const fileData = await new Promise((resolve, reject) => {
      dev.mountOps.makeFileData(dev, "/hello.txt", "r", 1000, 1000, (fd) => {
        if (!fd) reject(new Error("makeFileData null")); else resolve(fd);
      });
    });
    const buf = new Uint8Array(11);
    const got = await new Promise((resolve, reject) => {
      fileData.mount.readAsync(fileData, 0, buf, 0, 11, (n) => {
        if (n < 0) reject(new Error("read failed: " + n)); else resolve(n);
      });
    });
    expect(got).toBe(11);
    expect(dec.decode(buf.subarray(0, got))).toBe("hello world");
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Tlopen);
    expect(ops).toContain(OP.Tread);
    dev.delete();
  });

  it("writeAsync writes bytes that the server records", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    // Create a fresh file via makeFileData with create=true equivalent — use Tlcreate path:
    const fileData = await new Promise((resolve, reject) => {
      dev.mountOps.makeFileData(dev, "/new.txt", "w", 1000, 1000, (fd) => {
        if (!fd) reject(new Error("makeFileData null")); else resolve(fd);
      });
    });
    const data = enc.encode("payload");
    const wrote = await new Promise((resolve, reject) => {
      fileData.mount.writeAsync(fileData, 0, data, 0, data.byteLength, (n) => {
        if (n < 0) reject(new Error("write failed: " + n)); else resolve(n);
      });
    });
    expect(wrote).toBe(data.byteLength);
    expect(dec.decode(serverState.tree["/new.txt"].data)).toBe("payload");
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Tlcreate);
    expect(ops).toContain(OP.Twrite);
    dev.delete();
  });

  it("createDirAsync issues Tmkdir", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    await new Promise((resolve, reject) => {
      dev.mountOps.createDirAsync(dev, "/newdir", 0o755, 1000, 1000, (err) => {
        if (err) reject(err); else resolve();
      });
    });
    expect(serverState.tree["/newdir"]).toBeDefined();
    expect(serverState.tree["/newdir"].dir).toBe(true);
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Tmkdir);
    dev.delete();
  });

  it("unlinkAsync issues Tunlinkat", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    await new Promise((resolve, reject) => {
      dev.mountOps.unlinkAsync(dev, "/hello.txt", (err) => {
        if (err) reject(err); else resolve();
      });
    });
    expect(serverState.tree["/hello.txt"]).toBeUndefined();
    const ops = serverState.requests.map((r) => r.op);
    expect(ops).toContain(OP.Tunlinkat);
    dev.delete();
  });
});

describe("NinePDirDevice request multiplexing", () => {
  it("uses unique tags for concurrent in-flight requests", async () => {
    const dev = new NinePDirDevice(`ws://127.0.0.1:${port}/9p`);
    await dev.connect();
    const tagsSeen = new Set();
    // Fire 4 concurrent stats; each must have a distinct tag.
    await Promise.all([
      new Promise((res) => dev.mountOps.statAsync(dev, "/hello.txt", {}, () => res())),
      new Promise((res) => dev.mountOps.statAsync(dev, "/dir", {}, () => res())),
      new Promise((res) => dev.mountOps.statAsync(dev, "/dir/inner.bin", {}, () => res())),
      new Promise((res) => dev.mountOps.statAsync(dev, "/missing.txt", {}, () => res())),
    ]);
    for (const r of serverState.requests) tagsSeen.add(r.tag);
    expect(tagsSeen.size).toBeGreaterThan(2);
    dev.delete();
  });
});
