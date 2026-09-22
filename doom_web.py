#!/usr/bin/env python3
"""The browser front door: a static page and a WebSocket-to-CedarDB tunnel.

A browser cannot open a Postgres connection, so this process relays bytes:
WebSocket frames from the page become the TCP stream CedarDB expects, and back.
It is a dumb pipe. It never parses SQL, never holds credentials, and never
decides anything about the game; the browser authenticates as its own database
role through the tunnel (SCRAM, in web/pgwire.js) and reaches the world only
through the api_* functions and views, exactly like the native client.

    python3 doom_web.py                      # http://<host>:8080, tunnel to 127.0.0.1:5720
    DOOM_WEB_PORT=8080 DOOM_WEB_TARGETS="127.0.0.1:5720,db.example:5432" python3 doom_web.py

DOOM_WEB_TARGETS is the allowlist of CedarDB endpoints the page may pick from
(the first is the default); without it the tunnel is not an open proxy.

Guests: with DOOM_GUESTS_FILE pointing at a file of provisioned guest roles
(the lines scripts/add_player.py prints, one per role), a page that opens the
tunnel with ?guest=1 is handed one free guest role for the life of its
connection, as a JSON text frame before the Postgres bytes start. The role
goes back into the pool DOOM_GUEST_COOLDOWN seconds after the connection
closes, once the referee has reaped its slot. The relay still never sees the
Postgres conversation; it only hands out a login it was given.

WebSocket framing and permessage-deflate (RFC 7692) are implemented here so
the server has no dependencies beyond the standard library. Deflate matters:
a DOOM frame is 64 KB of palette indices with long flat runs, and compressing
each message with a shared context takes it down several times over.

Delta frames: a page that asks for the "pg-delta" subprotocol gets every large
binary result column (a frame, an automap) XORed against the previous one of
the same size on that connection before it is compressed, and undoes the XOR
after decoding the row. Between two frames the status bar, the sky and most
walls do not change, so deflate sees mostly zeros. This is the one place the
relay looks at the Postgres stream: message boundaries and DataRow lengths,
never the content of a query or a login.
"""
import asyncio
import base64
import hashlib
import json
import os
import struct
import sys
import time
import zlib
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

WEB_ROOT = Path(__file__).resolve().parent / "web"
PORT = int(os.getenv("DOOM_WEB_PORT", "8080"))
ADDRESS = os.getenv("DOOM_WEB_ADDRESS", "0.0.0.0")
TARGETS = [t.strip() for t in os.getenv("DOOM_WEB_TARGETS", "127.0.0.1:5720").split(",") if t.strip()]
# CedarDB builds with the max_parallel_workers session setting: what each
# browser sets for its own connection (see MULTIPLAYER.md, capacity). Empty
# means leave the server default alone.
CLIENT_PARALLEL = os.getenv("DOOM_CLIENT_PARALLEL", "")
# The most frames per second a page asks for. Doom runs at 35; a wide server
# would answer faster, and every frame is 64 KB before the tunnel codes it,
# so this is the knob on egress and on renderer CPU. 0 lifts the cap.
MAX_FPS = int(os.getenv("DOOM_MAX_FPS", "35"))
WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
GUESTS_FILE = os.getenv("DOOM_GUESTS_FILE", "")
GUEST_COOLDOWN = float(os.getenv("DOOM_GUEST_COOLDOWN", "8"))
# A browser that vanishes without a close frame (lid closed, network change) leaves a tunnel
# nobody will ever close, and with it a guest seat. After this many seconds without a frame
# from the browser the relay pings; another such interval without an answer closes the tunnel.
WS_IDLE_SECONDS = float(os.getenv("DOOM_WS_IDLE", "45"))


class GuestPool:
    """Guest logins, leased one per tunnel."""

    def __init__(self, path):
        self.seats = {}
        for line in Path(path).read_text().splitlines():
            # "browser: user doom_guest1, password xyz" (add_player.py) or "doom_guest1 xyz"
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("browser:"):
                user = line.split("user ", 1)[1].split(",", 1)[0].strip()
                password = line.split("password ", 1)[1].strip()
            else:
                user, password = line.split(None, 1)
            self.seats[user] = password
        self.leased = set()
        self.cooldown_until = {}

    def lease(self):
        now = time.time()
        for user in sorted(self.seats):
            if user in self.leased or self.cooldown_until.get(user, 0) > now:
                continue
            self.leased.add(user)
            return user, self.seats[user]
        return None

    def release(self, user):
        self.leased.discard(user)
        self.cooldown_until[user] = time.time() + GUEST_COOLDOWN

    def free(self):
        now = time.time()
        return sum(1 for u in self.seats if u not in self.leased and self.cooldown_until.get(u, 0) <= now)


GUESTS = GuestPool(GUESTS_FILE) if GUESTS_FILE and Path(GUESTS_FILE).is_file() else None
CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8", ".json": "application/json",
                 ".png": "image/png", ".ico": "image/x-icon", ".svg": "image/svg+xml"}


def log(message):
    print(f"[web {time.strftime('%H:%M:%S')}] {message}", flush=True)


async def read_http_head(reader):
    head = await reader.readuntil(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    method, path, _ = lines[0].split(" ", 2)
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return method, path, headers


def http_response(status, body=b"", content_type="text/plain; charset=utf-8", extra=()):
    head = [f"HTTP/1.1 {status}", f"Content-Type: {content_type}",
            f"Content-Length: {len(body)}", "Connection: close",
            "Cache-Control: no-store"]
    head.extend(extra)
    return ("\r\n".join(head) + "\r\n\r\n").encode("latin-1") + body


def serve_static(path):
    if path in ("", "/"):
        path = "/index.html"
    if path == "/config.json":
        body = json.dumps({"targets": TARGETS,
                           "parallel": int(CLIENT_PARALLEL) if CLIENT_PARALLEL.isdigit() else None,
                           "max_fps": MAX_FPS,
                           "guests": len(GUESTS.seats) if GUESTS else 0,
                           "guests_free": GUESTS.free() if GUESTS else 0}).encode()
        # Another origin (the cloud demo's Deathmatch tab) reads this to learn
        # whether the match is on and how many seats are free. It holds no
        # secret, so any origin may.
        return http_response("200 OK", body, "application/json",
                             extra=("Access-Control-Allow-Origin: *",))
    target = (WEB_ROOT / path.lstrip("/")).resolve()
    if WEB_ROOT not in target.parents or not target.is_file():
        return http_response("404 Not Found", b"not found")
    content_type = CONTENT_TYPES.get(target.suffix, "application/octet-stream")
    return http_response("200 OK", target.read_bytes(), content_type)


# ---------------------------------------------------------------- WebSocket

def ws_frame(payload, opcode=2, rsv1=False):
    """One unmasked server frame."""
    first = 0x80 | (0x40 if rsv1 else 0) | opcode
    n = len(payload)
    if n < 126:
        head = struct.pack("!BB", first, n)
    elif n < 65536:
        head = struct.pack("!BBH", first, 126, n)
    else:
        head = struct.pack("!BBQ", first, 127, n)
    return head + payload


async def ws_read_frame(reader):
    """(fin, rsv1, opcode, payload) of one client frame, unmasked."""
    b0, b1 = await reader.readexactly(2)
    fin, rsv1, opcode = bool(b0 & 0x80), bool(b0 & 0x40), b0 & 0x0F
    masked, n = bool(b1 & 0x80), b1 & 0x7F
    if n == 126:
        (n,) = struct.unpack("!H", await reader.readexactly(2))
    elif n == 127:
        (n,) = struct.unpack("!Q", await reader.readexactly(8))
    mask = await reader.readexactly(4) if masked else None
    payload = await reader.readexactly(n) if n else b""
    if mask:
        # XOR with the repeating 4-byte mask; int arithmetic on the whole
        # buffer is far faster than a Python loop over bytes.
        full = (mask * (n // 4 + 1))[:n]
        payload = (int.from_bytes(payload, "big") ^ int.from_bytes(full, "big")).to_bytes(n, "big")
    return fin, rsv1, opcode, payload


DELTA_MIN = 32768   # a binary column at least this long is a frame worth delta-coding


class DeltaCoder:
    """XOR large DataRow columns against the previous one of the same length.
    Both ends see the same ordered stream, so "previous" means the same thing
    on both sides; the first frame of each size goes through unchanged."""

    def __init__(self):
        self.buf = bytearray()
        self.prev = {}
        self.frames = 0

    def feed(self, chunk):
        self.buf.extend(chunk)
        out = bytearray()
        while len(self.buf) >= 5:
            length = int.from_bytes(self.buf[1:5], "big")
            if len(self.buf) < 1 + length:
                break
            msg = bytes(self.buf[:1 + length])
            del self.buf[:1 + length]
            out.extend(self._code(msg) if msg[0] == 0x44 else msg)   # 'D'
        return bytes(out)

    def _code(self, msg):
        ncols = int.from_bytes(msg[5:7], "big")
        if ncols != 1:
            return msg
        clen = int.from_bytes(msg[7:11], "big", signed=True)
        if clen < DELTA_MIN or 11 + clen != len(msg):
            return msg
        cell = msg[11:]
        prev = self.prev.get(clen)
        self.prev[clen] = cell
        self.frames += 1
        if prev is None:
            return msg
        coded = (int.from_bytes(cell, "big") ^ int.from_bytes(prev, "big")).to_bytes(clen, "big")
        return msg[:11] + coded


class Tunnel:
    """One browser connection bridged to one CedarDB TCP connection."""

    def __init__(self, ws_reader, ws_writer, deflate, peer, delta=False):
        self.ws_reader, self.ws_writer = ws_reader, ws_writer
        self.deflate = deflate
        self.peer = peer
        self.comp = zlib.compressobj(6, zlib.DEFLATED, -15) if deflate else None
        self.decomp = zlib.decompressobj(-15) if deflate else None
        self.delta = DeltaCoder() if delta else None
        self.raw_out = self.wire_out = self.raw_in = 0
        self.closed = asyncio.Event()

    async def send(self, payload):
        self.raw_out += len(payload)
        rsv1 = False
        if self.comp is not None:
            data = self.comp.compress(payload) + self.comp.flush(zlib.Z_SYNC_FLUSH)
            if data.endswith(b"\x00\x00\xff\xff"):
                data = data[:-4]
            payload, rsv1 = data, True
        self.wire_out += len(payload)
        self.ws_writer.write(ws_frame(payload, 2, rsv1))
        await self.ws_writer.drain()

    async def report_wire(self):
        """Once a second, tell the page what actually went over the wire: the
        browser cannot see its own compressed byte count, and the page shows
        egress next to the frame rate. A JSON text frame, uncompressed; a
        page that does not know it ignores it (pgwire.js)."""
        last = -1
        try:
            while not self.closed.is_set():
                await asyncio.sleep(1)
                if self.wire_out == last:
                    continue
                last = self.wire_out
                self.ws_writer.write(ws_frame(json.dumps(
                    {"wire_out": self.wire_out, "raw_out": self.raw_out}).encode(), 1))
                await self.ws_writer.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass

    async def pump_db_to_ws(self, db_reader):
        try:
            while True:
                chunk = await db_reader.read(65536)
                if not chunk:
                    break
                if self.delta is not None:
                    chunk = self.delta.feed(chunk)
                    if not chunk:
                        continue
                await self.send(chunk)
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            try:
                self.ws_writer.write(ws_frame(struct.pack("!H", 1000), 8))
                await self.ws_writer.drain()
            except ConnectionError:
                pass
            self.closed.set()

    async def pump_ws_to_db(self, db_writer):
        message, compressed = bytearray(), False
        pinged = False
        try:
            while True:
                try:
                    fin, rsv1, opcode, payload = await asyncio.wait_for(ws_read_frame(self.ws_reader), WS_IDLE_SECONDS)
                except asyncio.TimeoutError:
                    if pinged:
                        break            # silent for two intervals: gone
                    pinged = True
                    self.ws_writer.write(ws_frame(b"", 9))
                    await self.ws_writer.drain()
                    continue
                pinged = False
                if opcode == 8:
                    break
                if opcode == 9:
                    self.ws_writer.write(ws_frame(payload, 10))
                    await self.ws_writer.drain()
                    continue
                if opcode == 10:
                    continue
                if opcode in (1, 2):
                    message, compressed = bytearray(payload), rsv1
                else:
                    message.extend(payload)
                if not fin:
                    continue
                data = bytes(message)
                if compressed and self.decomp is not None:
                    data = self.decomp.decompress(data + b"\x00\x00\xff\xff")
                self.raw_in += len(data)
                db_writer.write(data)
                await db_writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            db_writer.close()
            self.closed.set()


def pick_target(query):
    wanted = parse_qs(query).get("target", [TARGETS[0]])[0]
    if wanted not in TARGETS:
        return None
    host, port = wanted.rsplit(":", 1)
    return host, int(port)


async def handle_websocket(reader, writer, path, headers, peer):
    key = headers.get("sec-websocket-key")
    if not key or headers.get("upgrade", "").lower() != "websocket":
        writer.write(http_response("400 Bad Request", b"websocket upgrade expected"))
        return
    query = urlsplit(path).query
    target = pick_target(query)
    if target is None:
        writer.write(http_response("403 Forbidden", b"that database endpoint is not on the allowlist"))
        return
    wants_guest = parse_qs(query).get("guest", ["0"])[0] == "1"
    guest = None
    if wants_guest:
        guest = GUESTS.lease() if GUESTS else None
    offered = headers.get("sec-websocket-extensions", "")
    deflate = "permessage-deflate" in offered
    protocols = [p.strip() for p in headers.get("sec-websocket-protocol", "").split(",") if p.strip()]
    delta = "pg-delta" in protocols
    accept = base64.b64encode(hashlib.sha1(key.encode() + WS_GUID).digest()).decode()
    lines = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
             f"Sec-WebSocket-Accept: {accept}"]
    if deflate:
        lines.append("Sec-WebSocket-Extensions: permessage-deflate")
    if delta:
        lines.append("Sec-WebSocket-Protocol: pg-delta")
    try:
        db_reader, db_writer = await asyncio.open_connection(*target)
    except OSError as exc:
        writer.write(http_response("502 Bad Gateway", f"cannot reach {target[0]}:{target[1]}: {exc}".encode()))
        return
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
    await writer.drain()
    if wants_guest:
        # The guest login, or the refusal, as the first (text) frame.
        if guest is None:
            reason = "no guest seats are configured" if not GUESTS else "all guest seats are taken; try again in a minute"
            writer.write(ws_frame(json.dumps({"error": reason}).encode(), 1))
            writer.write(ws_frame(struct.pack("!H", 1000), 8))
            await writer.drain()
            db_writer.close()
            log(f"{peer} guest refused: {reason}")
            return
        writer.write(ws_frame(json.dumps({"user": guest[0], "password": guest[1]}).encode(), 1))
        await writer.drain()
    tunnel = Tunnel(reader, writer, deflate, peer, delta)
    log(f"{peer} tunnel open -> {target[0]}:{target[1]} (deflate {'on' if deflate else 'off'}, delta frames {'on' if delta else 'off'})"
        + (f" as guest {guest[0]}" if guest else ""))
    started = time.perf_counter()
    tasks = [asyncio.create_task(tunnel.report_wire()),
             asyncio.create_task(tunnel.pump_db_to_ws(db_reader)),
             asyncio.create_task(tunnel.pump_ws_to_db(db_writer))]
    await tunnel.closed.wait()
    for task in tasks:
        task.cancel()
    db_writer.close()
    if guest:
        GUESTS.release(guest[0])
    seconds = time.perf_counter() - started
    ratio = tunnel.raw_out / tunnel.wire_out if tunnel.wire_out else 0.0
    frames = f", {tunnel.delta.frames} frames delta-coded" if tunnel.delta else ""
    log(f"{peer} tunnel closed after {seconds:.0f} s: db->browser {tunnel.raw_out / 1e6:.1f} MB raw, "
        f"{tunnel.wire_out / 1e6:.1f} MB on the wire (x{ratio:.1f}){frames}, browser->db {tunnel.raw_in / 1e3:.0f} KB")


async def handle(reader, writer):
    peer = "%s:%s" % writer.get_extra_info("peername")[:2]
    try:
        method, path, headers = await asyncio.wait_for(read_http_head(reader), 10)
        if headers.get("upgrade", "").lower() == "websocket":
            await handle_websocket(reader, writer, path, headers, peer)
        elif method == "GET":
            writer.write(serve_static(urlsplit(path).path))
        else:
            writer.write(http_response("405 Method Not Allowed", b"GET only"))
        await writer.drain()
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()


async def main():
    if not (WEB_ROOT / "index.html").is_file():
        raise SystemExit(f"no page to serve at {WEB_ROOT}")
    server = await asyncio.start_server(handle, ADDRESS, PORT)
    log(f"serving {WEB_ROOT} on http://{ADDRESS}:{PORT}/ ; tunnel targets: {', '.join(TARGETS)}")
    if GUESTS:
        log(f"{len(GUESTS.seats)} guest seats from {GUESTS_FILE}; visitors play without an account")
    log("players open the page, pick the server, and sign in with the role scripts/add_player.py gave them")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
