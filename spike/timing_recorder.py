#!/usr/bin/env python3
"""
timing_recorder.py - THROWAWAY SPIKE. Not part of the app.

What it is
    Records a whole live F1 session's raw live-timing messages to a file on your Mac, so app
    developers can replay it later as test data. It connects to F1's live timing the way the
    Android app does (LiveFeed.kt): POST negotiate, then a SignalR Core JSON WebSocket at
    livetiming.formula1.com/signalrcore, handshake, Subscribe to the same 13 topics, and keeps
    every message it receives. The WebSocket client is built in here (standard library only).

    It only READS public timing data with your F1 TV sign-in. No video, no licence requests.

How to run (on the Mac, with your own F1 TV subscription; Python 3.9+, standard library only)
    1. Sign in at https://account.formula1.com in a browser and copy the value of the
       `login-session` cookie (a bare subscription token also works), exactly as for
       stream_check.py.
    2. Start it a few minutes before the session and leave the window open:
           pbpaste | python3 timing_recorder.py
       (or just  python3 timing_recorder.py  and paste at the hidden prompt, if the cookie is short
       enough for the terminal.) Press Ctrl+C when the session is over.
    3. The recording is  timing_<YYYYmmdd-HHMM>.jsonl  next to this script (local time of the Mac
       at start). One JSON line per received message:  {"t": "<UTC time with ms>", "msg": <message>}.
       It contains NO sign-in details, but it is large (tens to hundreds of MB for a race), so
       do not paste it into chat; put it somewhere the developers can fetch it.

    Lines of the form {"t": ..., "recorder": "reconnect", ...} are written by this tool when the
    connection dropped and came back, so a gap in the data is visible. They have no "msg" key.

Replay data from a finished session (the same files the Android app reads for replays):
        pbpaste | python3 timing_recorder.py --archive 2026/2026-11-08_São_Paulo_Grand_Prix/2026-11-08_Race/
    downloads that session's static archive topics into a folder  archive_<session>/  next to this
    script. Also needs the sign-in (the archive wants the same token as a Bearer header).
"""

import argparse
import base64
import getpass
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import struct
import sys
import time
import urllib.parse
from datetime import datetime, timezone

# --- Mirrors of LiveFeed.kt / LiveTiming.kt --------------------------------------------------

HUB = "https://livetiming.formula1.com/signalrcore"
ARCHIVE_BASE = "https://livetiming.formula1.com/static/"
RS = "\x1e"
HANDSHAKE = '{"protocol":"json","version":1}'
TOPICS = [
    "Heartbeat", "Position.z", "CarData.z", "TimingData", "DriverList", "SessionInfo", "SessionStatus",
    "RaceControlMessages", "TeamRadio", "TimingAppData", "TrackStatus", "LapCount", "ExtrapolatedClock",
]
# The Android app's WebView user agent ("; wv" removed); a representative value, as in stream_check.py.
ANDROID_UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A.240805.005) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Version/4.0 Chrome/140.0.7339.207 Mobile Safari/537.36")

PING_INTERVAL_S = 15        # LiveFeed.kt: OkHttp pingInterval(15 s)
IDLE_LIMIT_S = 60           # no frame at all for this long: the connection is dead
STATUS_INTERVAL_S = 30
MAX_RECONNECTS = 5
HEALTHY_AFTER_S = 120       # a connection that lasted this long resets the reconnect count

# Archive files the Android app reads for a replay (LiveTiming.kt load()/loadSpeeds()), one per live topic.
ARCHIVE_FILES = [
    "SessionInfo.json", "DriverList.json", "Heartbeat.jsonStream", "Position.z.jsonStream",
    "CarData.z.jsonStream", "TimingData.jsonStream", "TimingAppData.jsonStream",
    "SessionStatus.jsonStream", "RaceControlMessages.jsonStream", "TrackStatus.jsonStream",
    "TeamRadio.jsonStream", "LapCount.jsonStream", "ExtrapolatedClock.jsonStream",
]

# --- Sign-in (same as stream_check.py / LoginCookie.readToken()) -----------------------------

SECRETS = []  # exact strings never to print or write


def add_secret(value):
    if value and len(value) >= 6 and value not in SECRETS:
        SECRETS.append(value)
        enc = urllib.parse.quote(value, safe="")
        if enc != value:
            SECRETS.append(enc)


def scrub(text):
    text = str(text)
    for s in SECRETS:
        text = text.replace(s, "<masked>")
    return re.sub(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*", "<masked-jwt>", text)


def say(line=""):
    print(scrub(line), flush=True)


def decode_signin(raw):
    """Returns (subscription_token, kind). Cookie (JSON, raw or URL-encoded) or a bare token."""
    value = raw.strip().strip('"').strip("'").strip()
    if value.lower().startswith("login-session="):
        value = value.split("=", 1)[1].strip()
    candidates = [value]
    decoded = value
    for _ in range(2):
        nxt = urllib.parse.unquote(decoded)
        if nxt == decoded:
            break
        decoded = nxt
        candidates.append(decoded)
    looks_like_cookie = any(c.lstrip().startswith("{") for c in candidates)
    for kind, c in zip(["cookie (raw JSON)", "cookie (URL-encoded JSON)", "cookie (double URL-encoded JSON)"],
                       candidates):
        try:
            obj = json.loads(c)
        except ValueError:
            continue
        data = obj.get("data") if isinstance(obj, dict) else None
        token = data.get("subscriptionToken") if isinstance(data, dict) else None
        if isinstance(token, str) and token:
            return token, kind
    if looks_like_cookie:
        raise ValueError("That looks like the login-session cookie but has no data.subscriptionToken. "
                         "Sign in again at account.formula1.com and copy the cookie afresh.")
    if not value or re.search(r"\s", value):
        raise ValueError("That doesn't look like a login-session cookie or a subscription token.")
    return value, "bare subscription token"


def read_signin():
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
    else:
        print("Paste your F1 TV login-session cookie value (or a bare subscription token).")
        print("Input is hidden and is not stored or printed.")
        print("(If the terminal beeps or flashes, the value is too long to paste: press Ctrl+C,")
        print(" copy the cookie, and run:  pbpaste | python3 timing_recorder.py)")
        raw = getpass.getpass("login-session / token: ")
    token, kind = decode_signin(raw)
    add_secret(token)
    add_secret(raw.strip())
    return token, kind


# --- HTTP (http.client: exact headers, no redirects, no cookies jar) -------------------------

class FatalError(Exception):
    """Not worth retrying (refused login, bad path)."""


def https_request(method, url, headers):
    """Returns (connection, response); the caller reads the body and closes the connection."""
    p = urllib.parse.urlsplit(url)
    ctx = ssl.create_default_context()
    if p.scheme == "https":
        conn = http.client.HTTPSConnection(p.hostname, p.port or 443, timeout=20, context=ctx)
    else:  # plain http: only used against a local test server
        conn = http.client.HTTPConnection(p.hostname, p.port or 80, timeout=20)
    target = p.path + ("?" + p.query if p.query else "")
    try:
        conn.request(method, target, headers=headers)
        return conn, conn.getresponse()
    except ssl.SSLError as e:
        conn.close()
        if "CERTIFICATE_VERIFY_FAILED" in str(e):
            raise ConnectionError("TLS certificate check failed. If this is a python.org Python, run "
                                  "'Install Certificates.command' from its Applications folder, or use /usr/bin/python3.")
        raise ConnectionError("TLS error: %s" % e)
    except (OSError, http.client.HTTPException) as e:
        conn.close()
        raise ConnectionError("Network error: %s" % e)


def negotiate(token, ua):
    """POST $HUB/negotiate?negotiateVersion=1 as LiveFeed.negotiate(): Bearer header, no body.
    Returns (connection token, Cookie header value or None). The connection token is never printed."""
    conn, resp = https_request("POST", HUB + "/negotiate?negotiateVersion=1",
                               {"Authorization": "Bearer " + token, "User-Agent": ua})
    try:
        body = resp.read().decode("utf-8", errors="replace")
        if resp.status in (401, 403):
            raise FatalError("F1's live timing refused the login (HTTP %d). Sign in again and copy a fresh cookie." % resp.status)
        if not 200 <= resp.status < 300:
            raise ConnectionError("negotiate HTTP %d" % resp.status)
        try:
            j = json.loads(body)
        except ValueError:
            raise ConnectionError("negotiate returned something that isn't JSON")
        ident = (j.get("connectionToken") or j.get("connectionId") or "") if isinstance(j, dict) else ""
        if not ident:
            raise ConnectionError("no connection token in the negotiate response")
        add_secret(ident)
        cookies = "; ".join(v.split(";", 1)[0] for k, v in resp.getheaders() if k.lower() == "set-cookie")
        return ident, (cookies or None)
    finally:
        conn.close()


# --- Minimal RFC 6455 WebSocket client ------------------------------------------------------

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


def apply_mask(payload, key):
    n = len(payload)
    if n == 0:
        return b""
    stream = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big")


def encode_frame(opcode, payload=b"", fin=True, mask=True, key=None):
    """One WebSocket frame. Client frames must be masked (mask=True)."""
    n = len(payload)
    head = bytearray([(0x80 if fin else 0) | opcode])
    mbit = 0x80 if mask else 0
    if n < 126:
        head.append(mbit | n)
    elif n < 65536:
        head.append(mbit | 126)
        head += struct.pack("!H", n)
    else:
        head.append(mbit | 127)
        head += struct.pack("!Q", n)
    if mask:
        key = key if key is not None else os.urandom(4)
        return bytes(head) + key + apply_mask(payload, key)
    return bytes(head) + payload


def decode_frame(buf):
    """Parses one frame from the start of bytes `buf`. Returns None if incomplete, else
    (fin, opcode, payload, consumed). Unmasks payloads that arrive masked."""
    if len(buf) < 2:
        return None
    b0, b1 = buf[0], buf[1]
    fin, opcode = bool(b0 & 0x80), b0 & 0x0F
    masked, n, pos = bool(b1 & 0x80), b1 & 0x7F, 2
    if n == 126:
        if len(buf) < 4:
            return None
        n, pos = struct.unpack("!H", buf[2:4])[0], 4
    elif n == 127:
        if len(buf) < 10:
            return None
        n, pos = struct.unpack("!Q", buf[2:10])[0], 10
    key = b""
    if masked:
        if len(buf) < pos + 4:
            return None
        key, pos = buf[pos:pos + 4], pos + 4
    if len(buf) < pos + n:
        return None
    payload = bytes(buf[pos:pos + n])
    if masked:
        payload = apply_mask(payload, key)
    return fin, opcode, payload, pos + n


def split_records(buffer):
    """SignalR: records end with 0x1E. Returns (complete records, the unfinished remainder)."""
    parts = buffer.split(RS)
    return [p for p in parts[:-1] if p.strip()], parts[-1]


class WSError(Exception):
    pass


class WSConnection:
    """Client side of one WebSocket. recv_message() answers pings itself and reassembles
    fragmented messages; it raises socket.timeout when nothing arrived within the socket timeout
    (the connection stays usable)."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.frag_op = None
        self.frag = []
        self.closed = False

    @classmethod
    def connect(cls, url, headers, timeout=15):
        p = urllib.parse.urlsplit(url)
        secure = p.scheme in ("wss", "https")
        port = p.port or (443 if secure else 80)
        try:
            sock = socket.create_connection((p.hostname, port), timeout)
            if secure:
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=p.hostname)
        except ssl.SSLError as e:
            if "CERTIFICATE_VERIFY_FAILED" in str(e):
                raise ConnectionError("TLS certificate check failed. If this is a python.org Python, run "
                                      "'Install Certificates.command' from its Applications folder, or use /usr/bin/python3.")
            raise ConnectionError("TLS error: %s" % e)
        except OSError as e:
            raise ConnectionError("Network error: %s" % e)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        host = p.hostname if (p.port is None) else "%s:%d" % (p.hostname, p.port)
        lines = ["GET %s HTTP/1.1" % (p.path + ("?" + p.query if p.query else "")),
                 "Host: " + host, "Upgrade: websocket", "Connection: Upgrade",
                 "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13"]
        lines += ["%s: %s" % (k, v) for k, v in headers.items()]
        try:
            sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("utf-8"))
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    raise WSError("connection closed during the WebSocket handshake")
                data += chunk
                if len(data) > 65536:
                    raise WSError("handshake response too large")
        except (OSError, WSError) as e:
            sock.close()
            raise ConnectionError("WebSocket handshake failed: %s" % e)
        head, rest = data.split(b"\r\n\r\n", 1)
        head_lines = head.decode("iso-8859-1").split("\r\n")
        status = head_lines[0].split(" ", 2)
        code = int(status[1]) if len(status) > 1 and status[1].isdigit() else 0
        hdrs = {}
        for l in head_lines[1:]:
            if ":" in l:
                k, v = l.split(":", 1)
                hdrs[k.strip().lower()] = v.strip()
        if code in (401, 403):
            sock.close()
            raise FatalError("F1's live timing refused the WebSocket (HTTP %d)." % code)
        if code != 101:
            sock.close()
            raise ConnectionError("WebSocket upgrade refused (HTTP %s)" % (code or "?"))
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
        if hdrs.get("sec-websocket-accept") != accept:
            sock.close()
            raise ConnectionError("WebSocket handshake: bad Sec-WebSocket-Accept")
        conn = cls(sock)
        conn.buf = rest
        return conn

    def set_timeout(self, seconds):
        self.sock.settimeout(seconds)

    def _send(self, opcode, payload=b""):
        self.sock.sendall(encode_frame(opcode, payload, mask=True))

    def send_text(self, text):
        self._send(OP_TEXT, text.encode("utf-8"))

    def ping(self):
        self._send(OP_PING, b"apexduoview")

    def close(self, code=1000):
        if not self.closed:
            self.closed = True
            try:
                self._send(OP_CLOSE, struct.pack("!H", code))
            except OSError:
                pass
        try:
            self.sock.close()
        except OSError:
            pass

    def recv_message(self):
        """Returns ('text', str), ('binary', bytes), ('close', code, reason), ('ping',) or ('pong',)."""
        while True:
            frame = decode_frame(self.buf)
            if frame is None:
                chunk = self.sock.recv(65536)  # socket.timeout propagates; buf is untouched
                if not chunk:
                    raise ConnectionError("connection closed by the server (no close frame)")
                self.buf += chunk
                continue
            fin, op, payload, used = frame
            self.buf = self.buf[used:]
            if op == OP_PING:
                self._send(OP_PONG, payload)
                return ("ping",)
            if op == OP_PONG:
                return ("pong",)
            if op == OP_CLOSE:
                code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 1005
                reason = payload[2:].decode("utf-8", errors="replace")
                if not self.closed:
                    self.closed = True
                    try:
                        self._send(OP_CLOSE, payload[:2])
                    except OSError:
                        pass
                return ("close", code, reason)
            if op in (OP_TEXT, OP_BINARY):
                if self.frag_op is not None:
                    raise WSError("new data frame inside a fragmented message")
                self.frag_op, self.frag = op, [payload]
            elif op == OP_CONT:
                if self.frag_op is None:
                    raise WSError("continuation frame without a start")
                self.frag.append(payload)
            else:
                raise WSError("unknown opcode %d" % op)
            if fin:
                data, kind = b"".join(self.frag), self.frag_op
                self.frag_op, self.frag = None, []
                if kind == OP_TEXT:
                    return ("text", data.decode("utf-8", errors="replace"))
                return ("binary", data)


# --- Recorder -------------------------------------------------------------------------------

def utc_iso_ms():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def human_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def new_output_path(directory):
    base = "timing_" + datetime.now().strftime("%Y%m%d-%H%M")
    path, k = os.path.join(directory, base + ".jsonl"), 2
    while os.path.exists(path):
        path = os.path.join(directory, "%s-%d.jsonl" % (base, k))
        k += 1
    return path


class Recorder:
    def __init__(self, token, path, ua=ANDROID_UA):
        self.token, self.path, self.ua = token, path, ua
        self.f = open(path, "a", encoding="utf-8", newline="\n")
        self.count = 0
        self.topics = {}
        self.reconnects = 0
        self.last_status = time.time()
        self.started = time.time()

    def write_line(self, obj):
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
        for s in SECRETS:  # belt and braces: a secret must never reach the file
            if s in line:
                line = line.replace(s, "<masked>")
        self.f.write(line + "\n")
        self.f.flush()

    def write_message(self, msg):
        self.write_line({"t": utc_iso_ms(), "msg": msg})
        self.count += 1

    def note_topics(self, msg):
        if not isinstance(msg, dict):
            return
        if msg.get("type") == 1 and msg.get("target") == "feed":
            args = msg.get("arguments")
            if isinstance(args, list) and args and isinstance(args[0], str):
                self.topics[args[0]] = self.topics.get(args[0], 0) + 1
        elif msg.get("type") == 3 and isinstance(msg.get("result"), dict):
            for k in msg["result"]:
                self.topics[k] = self.topics.get(k, 0) + 1

    def status(self, force=False):
        now = time.time()
        if not force and now - self.last_status < STATUS_INTERVAL_S:
            return
        self.last_status = now
        try:
            size = os.path.getsize(self.path)
        except OSError:
            size = 0
        say("[%s] messages=%d  topics=%d (%s)  file=%s  reconnects=%d" % (
            datetime.now().strftime("%H:%M:%S"), self.count, len(self.topics),
            ", ".join(sorted(self.topics)) or "none yet", human_size(size), self.reconnects))

    def handle_record(self, raw, ws, state):
        """One SignalR record. Returns nothing; raises ConnectionError to drop the connection."""
        try:
            msg = json.loads(raw)
        except ValueError:
            self.write_line({"t": utc_iso_ms(), "msg_unparsed": raw})
            self.count += 1
            return
        self.write_message(msg)
        self.note_topics(msg)
        if not isinstance(msg, dict):
            return
        mtype = msg.get("type", -1)
        if mtype == -1:
            # The handshake reply is an empty object: now ask for the topics (LiveFeed.kt).
            if msg.get("error"):
                raise ConnectionError("handshake refused: %s" % msg.get("error"))
            if not state["subscribed"]:
                state["subscribed"] = True
                ws.send_text(json.dumps({"type": 1, "invocationId": "0", "target": "Subscribe",
                                         "arguments": [TOPICS]}, separators=(",", ":")) + RS)
        elif mtype == 3:
            if msg.get("error"):
                raise ConnectionError("subscribe failed: %s" % msg.get("error"))
            if isinstance(msg.get("result"), dict):
                state["got_state"] = True
                say("Subscribed; initial state received for %d topic(s): %s" % (
                    len(msg["result"]), ", ".join(msg["result"])))
        elif mtype == 6:
            ws.send_text('{"type":6}' + RS)
        elif mtype == 7:
            raise ConnectionError("server asked to close: %s" % (msg.get("error") or "no reason given"))

    def run_connection(self):
        """One connection until it drops. Returns seconds it was up. Raises on failure."""
        ident, cookie = negotiate(self.token, self.ua)
        query = "id=%s&access_token=%s" % (urllib.parse.quote(ident, safe="%+/=:"), urllib.parse.quote(self.token, safe="%+/=:."))
        url = "%s?%s" % (hub_ws_url(), query)
        headers = {"Authorization": "Bearer " + self.token, "User-Agent": self.ua}
        if cookie:
            headers["Cookie"] = cookie
        ws = WSConnection.connect(url, headers)
        began = time.time()
        state = {"subscribed": False, "got_state": False}
        try:
            ws.set_timeout(1.0)
            ws.send_text(HANDSHAKE + RS)
            say("Connected; handshake sent.")
            pending = ""
            last_rx = last_ping = time.time()
            while True:
                now = time.time()
                self.status()
                if now - last_ping >= PING_INTERVAL_S:
                    ws.ping()
                    last_ping = now
                if now - last_rx > IDLE_LIMIT_S:
                    raise ConnectionError("no data for %d s" % IDLE_LIMIT_S)
                try:
                    item = ws.recv_message()
                except socket.timeout:
                    continue
                last_rx = time.time()
                if item[0] == "close":
                    raise ConnectionError("server closed the connection (code %s%s)" % (
                        item[1], (": " + item[2]) if item[2] else ""))
                if item[0] != "text":
                    continue
                records, pending = split_records(pending + item[1])
                for rec in records:
                    self.handle_record(rec, ws, state)
        except ConnectionError:
            raise
        except OSError as e:
            raise ConnectionError("connection lost: %s" % e)
        finally:
            up = time.time() - began
            self.last_up = up
            ws.close()

    def run(self):
        """Until Ctrl+C or too many consecutive failures."""
        consecutive = 0
        say("Recording to %s" % self.path)
        say("Press Ctrl+C when the session is over.")
        try:
            while True:
                self.last_up = 0.0
                try:
                    self.run_connection()
                except FatalError as e:
                    say("Stopping: %s" % e)
                    return
                except (ConnectionError, WSError) as e:
                    say("Connection ended: %s" % e)
                except KeyboardInterrupt:
                    raise
                except Exception as e:  # keep a long recording alive through odd failures
                    say("Connection ended unexpectedly: %s: %s" % (type(e).__name__, e))
                if self.last_up >= HEALTHY_AFTER_S:
                    consecutive = 0
                consecutive += 1
                if consecutive > MAX_RECONNECTS:
                    say("Giving up after %d reconnect attempts in a row." % MAX_RECONNECTS)
                    return
                delay = min(2 ** consecutive, 30)
                self.reconnects += 1
                say("Reconnect %d of %d in %d s ..." % (consecutive, MAX_RECONNECTS, delay))
                self.write_line({"t": utc_iso_ms(), "recorder": "reconnect", "attempt": consecutive})
                end = time.time() + delay
                while time.time() < end:
                    time.sleep(0.25)
        except KeyboardInterrupt:
            say("")
            say("Stopped by Ctrl+C.")
        finally:
            self.f.close()


def hub_ws_url():
    p = urllib.parse.urlsplit(HUB)
    return urllib.parse.urlunsplit(("wss" if p.scheme == "https" else "ws", p.netloc, p.path, "", ""))


# --- Archive download -----------------------------------------------------------------------

def normalise_archive_path(arg):
    """'2026/2026-11-08_São_Paulo_Grand_Prix/2026-11-08_Race/' (also accepts a full /static/ URL)."""
    p = arg.strip()
    if "/static/" in p:
        p = p.split("/static/", 1)[1]
    p = urllib.parse.unquote(p).strip("/")
    if not p or ".." in p.split("/") or "\\" in p:
        raise ValueError("That doesn't look like an archive path like 2026/2026-11-08_São_Paulo_Grand_Prix/2026-11-08_Race/")
    return p + "/"


def archive_folder_name(path):
    parts = [x for x in path.strip("/").split("/") if x]
    return "archive_" + re.sub(r"[^\w.-]+", "_", "_".join(parts[-2:]))


def download_one(token, url_path, dest, ua):
    """Streams one archive file to dest. Returns (status, bytes). Status 'ok', 'missing' or an error text."""
    url = ARCHIVE_BASE + urllib.parse.quote(url_path, safe="/")
    conn, resp = https_request("GET", url, {"Authorization": "Bearer " + token, "User-Agent": ua})
    try:
        if resp.status in (401, 403):
            raise FatalError("F1's timing archive refused the login (HTTP %d). Sign in again and copy a fresh cookie." % resp.status)
        if resp.status == 404:
            return "missing", 0
        if resp.status != 200:
            return "HTTP %d" % resp.status, 0
        tmp, total = dest + ".part", 0
        with open(tmp, "wb") as f:
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                total += len(chunk)
        os.replace(tmp, dest)
        return "ok", total
    except (OSError, http.client.HTTPException) as e:
        return "error: %s" % e, 0
    finally:
        conn.close()


def download_archive(token, arg, directory, ua=ANDROID_UA):
    path = normalise_archive_path(arg)
    folder = os.path.join(directory, archive_folder_name(path))
    os.makedirs(folder, exist_ok=True)
    say("Archive path: %s" % path)
    say("Saving into:  %s" % folder)
    got = missing = failed = 0
    total = 0
    jobs = [(path + name, name) for name in ARCHIVE_FILES]
    year = path.split("/", 1)[0]
    if re.fullmatch(r"\d{4}", year):  # the Android app finds sessions through the year's index
        jobs.append((year + "/Index.json", "Index_%s.json" % year))
    for url_path, name in jobs:
        status, size = download_one(token, url_path, os.path.join(folder, name), ua)
        if status == "ok":
            got += 1
            total += size
            say("  %-34s %s" % (name, human_size(size)))
        elif status == "missing":
            missing += 1
            say("  %-34s not in the archive (404)" % name)
        else:
            failed += 1
            say("  %-34s FAILED: %s" % (name, status))
    say("")
    say("Done: %d file(s), %s; %d not in the archive; %d failed." % (got, human_size(total), missing, failed))
    if got == 0:
        say("Nothing was downloaded. Check the path (copy it from the archive index) and that you are signed in.")
    say("The folder holds public timing data and no sign-in details, but it is large: no need to paste it into chat.")
    return 0 if got else 1


# --- Main -----------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Throwaway spike: record a live F1 session's raw live-timing messages to a .jsonl file, "
                    "or (--archive) download a finished session's static archive files.",
        usage="pbpaste | python3 timing_recorder.py [--archive <year/meeting/session/>]")
    parser.add_argument("--archive", metavar="PATH",
                        help="instead of recording, download a finished session's archive files, e.g. "
                             "2026/2026-11-08_São_Paulo_Grand_Prix/2026-11-08_Race/")
    args = parser.parse_args(argv)
    directory = os.path.dirname(os.path.abspath(__file__))

    try:
        token, kind = read_signin()
    except (ValueError, EOFError, KeyboardInterrupt) as e:
        print("Error: %s" % (e if str(e) else "cancelled"))
        return 1

    if args.archive:
        try:
            return download_archive(token, args.archive, directory)
        except (ValueError, FatalError) as e:
            say("Error: %s" % e)
            return 1
        except KeyboardInterrupt:
            say("\nStopped by Ctrl+C.")
            return 1

    path = new_output_path(directory)
    say("F1 live timing recorder (throwaway spike). Sign-in given as: %s" % kind)
    rec = Recorder(token, path)
    rec.run()
    rec.status(force=True)
    say("")
    say("Recording: %s   (%d messages, %s)" % (path, rec.count, human_size(os.path.getsize(path))))
    say("It contains no sign-in details. It is large, so it need not be pasted into chat.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
