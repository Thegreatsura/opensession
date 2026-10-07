import { describe, expect, test } from "bun:test";
import { inflateRawSync } from "node:zlib";
import { connect } from "node:net";
import { clientAcceptsCompressedFrames } from "./ws-compression";

describe("clientAcceptsCompressedFrames", () => {
  test("Apple networking clients get uncompressed frames", () => {
    for (const ua of [
      // Home Screen web app / Safari on iPhone
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
      // Chrome and Firefox on iOS are WebKit too
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/150.0.0.0 Mobile/15E148 Safari/604.1",
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/150.0 Mobile/15E148 Safari/605.1.15",
      // Safari on macOS
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15",
      // Native apps (URLSessionWebSocketTask)
      "OS1/814 CFNetwork/3896.100.1.2.1 Darwin/27.0.0",
    ]) {
      expect(clientAcceptsCompressedFrames(ua)).toBe(false);
    }
  });

  test("Chromium clients and unknown clients keep compression", () => {
    for (const ua of [
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) OS/0.4.74 Chrome/150.0.7871.129 Electron/43.2.0 Safari/537.36",
      "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0",
      null,
      "",
    ]) {
      expect(clientAcceptsCompressedFrames(ua)).toBe(true);
    }
  });
});

// The reason for the split above. If Bun stops ending short compressed
// messages with BFINAL, Apple clients could have compression back.
test("Bun ends a short compressed message with a BFINAL block", async () => {
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(req, srv) {
      return srv.upgrade(req) ? undefined : new Response(null, { status: 400 });
    },
    websocket: {
      perMessageDeflate: { compress: "shared", decompress: "shared" },
      open(ws) {
        ws.send(
          JSON.stringify({ type: "transcript_append", text: "hi" }),
          true,
        );
      },
      message() {},
    },
  });
  try {
    const payload = await new Promise<Buffer>((resolve, reject) => {
      const sock = connect(server.port!, "127.0.0.1");
      sock.on("error", reject);
      sock.write(
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" +
          "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n",
      );
      let buf = Buffer.alloc(0);
      sock.on("data", (chunk: Buffer) => {
        buf = Buffer.concat([buf, chunk]);
        const end = buf.indexOf("\r\n\r\n");
        if (end < 0) return;
        const frame = buf.subarray(end + 4);
        if (frame.length < 2 || frame.length < 2 + (frame[1]! & 127)) return;
        expect(frame[0]! & 0x40).toBe(0x40); // RSV1: compressed
        sock.destroy();
        resolve(frame.subarray(2, 2 + (frame[1]! & 127)));
      });
    });
    // A sync-flushed message cannot inflate on its own; a finished one can.
    expect(() => inflateRawSync(payload)).not.toThrow();
  } finally {
    server.stop(true);
  }
});
