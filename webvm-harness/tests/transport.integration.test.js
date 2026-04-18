// Integration test for webvm-net-transport.js.
// Stands up a real Node `ws` server that speaks the spec/03 frame protocol,
// constructs the production transport, performs a CONNECT/DATA/echo/CLOSE
// round-trip through real WHATWG ReadableStream/WritableStream pairs, and
// verifies the WHATWG Direct Sockets-shaped object the CheerpX engine consumes.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { WebSocketServer } from "ws";
import {
  OP, FAMILY, PROTO,
  encodeFrame, decodeFrame, decodeConnectPayload, encodeConnectPayload,
} from "../frame-codec.js";
import { WebVMRawSocketTransport } from "../webvm-net-transport.js";

let wss = null;
let port = 0;
let serverConns = []; // {conn_id, recv: (op,payload)=>void}
let onWsClient = null;

function startStubServer() {
  return new Promise((resolve) => {
    wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    wss.on("listening", () => {
      port = wss.address().port;
      resolve();
    });
    wss.on("connection", (ws) => {
      ws.binaryType = "arraybuffer";
      const conns = new Map();
      onWsClient && onWsClient(ws, conns);
      ws.on("message", (data, isBinary) => {
        if (!isBinary) return;
        const bytes = new Uint8Array(data);
        const { op, connId, payload } = decodeFrame(bytes);
        const handler = conns.get(connId);
        if (op === OP.CONNECT) {
          // Default behavior: ACK and remember the connection.
          const c = { id: connId, recv: null };
          conns.set(connId, c);
          ws.send(encodeFrame(OP.CONNECT_OK, connId));
        } else if (op === OP.DATA) {
          // Echo back to the same conn_id by default.
          ws.send(encodeFrame(OP.DATA, connId, payload));
        } else if (op === OP.CLOSE) {
          ws.send(encodeFrame(OP.CLOSE, connId));
          conns.delete(connId);
        }
      });
    });
  });
}

beforeEach(async () => {
  await startStubServer();
});

afterEach(async () => {
  onWsClient = null;
  await new Promise((r) => wss.close(r));
});

describe("WebVMRawSocketTransport WHATWG shape", () => {
  it("up() opens a WebSocket against /net and resolves", async () => {
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    t.delete();
  });

  it("TCPSocket returns the WHATWG Direct Sockets shape after CONNECT_OK", async () => {
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const sock = t.TCPSocket("198.51.100.1", 80);
    expect(sock).toHaveProperty("opened");
    expect(sock).toHaveProperty("closed");
    expect(typeof sock.close).toBe("function");
    const opened = await sock.opened;
    expect(opened.readable).toBeInstanceOf(ReadableStream);
    expect(opened.writable).toBeInstanceOf(WritableStream);
    expect(opened.remoteAddress).toBe("198.51.100.1");
    expect(opened.remotePort).toBe(80);
    sock.close();
    await sock.closed;
    t.delete();
  });

  it("DATA frames flow bidirectionally through readable/writable streams (echo)", async () => {
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const sock = t.TCPSocket("198.51.100.1", 80);
    const { readable, writable } = await sock.opened;

    const writer = writable.getWriter();
    const reader = readable.getReader();

    const payload = new Uint8Array([0x01, 0x02, 0x03, 0x04, 0x05]);
    await writer.write(payload);

    const { value, done } = await reader.read();
    expect(done).toBe(false);
    expect(value).toEqual(payload);

    await writer.close();
    sock.close();
    await sock.closed;
    t.delete();
  });

  it("emits CONNECT with correct host/port encoding (frame inspection)", async () => {
    const seen = [];
    onWsClient = (ws, _conns) => {
      ws.on("message", (data, isBinary) => {
        if (!isBinary) return;
        const bytes = new Uint8Array(data);
        const f = decodeFrame(bytes);
        if (f.op === OP.CONNECT) {
          seen.push({ frame: f, connect: decodeConnectPayload(f.payload) });
        }
      });
    };
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const sock = t.TCPSocket("example.com", 443);
    await sock.opened;
    expect(seen.length).toBe(1);
    expect(seen[0].connect).toEqual({
      family: FAMILY.IPV4, proto: PROTO.TCP, host: "example.com", port: 443,
    });
    expect(seen[0].frame.connId).toBeGreaterThan(0);
    sock.close();
    await sock.closed;
    t.delete();
  });

  it("rejects opened on CONNECT_ERR with the server's reason string", async () => {
    onWsClient = (ws, conns) => {
      ws.removeAllListeners("message");
      ws.on("message", (data) => {
        const f = decodeFrame(new Uint8Array(data));
        if (f.op === OP.CONNECT) {
          ws.send(encodeFrame(OP.CONNECT_ERR, f.connId, new TextEncoder().encode("ECONNREFUSED")));
        }
      });
    };
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const sock = t.TCPSocket("198.51.100.1", 80);
    await expect(sock.opened).rejects.toThrow(/ECONNREFUSED/);
    t.delete();
  });

  it("closing readable when host sends CLOSE", async () => {
    onWsClient = (ws, conns) => {
      ws.removeAllListeners("message");
      ws.on("message", (data) => {
        const f = decodeFrame(new Uint8Array(data));
        if (f.op === OP.CONNECT) {
          ws.send(encodeFrame(OP.CONNECT_OK, f.connId));
          // Server EOF immediately after ACK.
          ws.send(encodeFrame(OP.CLOSE, f.connId));
        }
      });
    };
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const sock = t.TCPSocket("198.51.100.1", 80);
    const { readable } = await sock.opened;
    const reader = readable.getReader();
    const { done } = await reader.read();
    expect(done).toBe(true);
    await sock.closed;
    t.delete();
  });

  it("multiple concurrent TCPSocket calls allocate distinct conn_ids", async () => {
    const seenIds = new Set();
    onWsClient = (ws, conns) => {
      ws.removeAllListeners("message");
      ws.on("message", (data) => {
        const f = decodeFrame(new Uint8Array(data));
        if (f.op === OP.CONNECT) {
          seenIds.add(f.connId);
          ws.send(encodeFrame(OP.CONNECT_OK, f.connId));
        } else if (f.op === OP.CLOSE) {
          ws.send(encodeFrame(OP.CLOSE, f.connId));
        }
      });
    };
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const socks = await Promise.all(
      [80, 81, 82, 83].map(async (p) => {
        const s = t.TCPSocket("198.51.100.1", p);
        await s.opened;
        return s;
      }),
    );
    expect(seenIds.size).toBe(4);
    for (const s of socks) {
      s.close();
      await s.closed;
    }
    t.delete();
  });

  it("TCPServerSocket and UDPSocket reject as not implemented (MVP)", async () => {
    const t = new WebVMRawSocketTransport(`ws://127.0.0.1:${port}/net`);
    await t.up();
    const srv = t.TCPServerSocket("0.0.0.0", { localPort: 9999 });
    await expect(srv.opened).rejects.toThrow(/not implemented/);
    const udp = t.UDPSocket({ localPort: 9999 });
    await expect(udp.opened).rejects.toThrow(/not implemented/);
    t.delete();
  });
});
