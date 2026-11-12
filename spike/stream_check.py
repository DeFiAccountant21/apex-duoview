#!/usr/bin/env python3
"""
stream_check.py - THROWAWAY SPIKE for the iOS-port assessment. Not part of the app.

What it is
    iOS (AVPlayer) can only play DRM-protected video as FairPlay HLS. Nothing public says
    whether F1 TV will hand our requests a FairPlay stream. This script asks F1 TV for one
    replay on several platform strings, exactly the way the Android app's F1TvApi.kt does,
    and reports what comes back: the play response and the text manifest only.

    It does NOT download any video segments, does NOT make any licence/key request, and does
    not try to get around DRM in any way. It reads JSON and playlist text, nothing else.

How to run (on the Mac, with your own F1 TV subscription)
    1. Sign in at https://account.formula1.com in a browser, then copy the value of the
       `login-session` cookie (Safari: Develop > Show Web Inspector > Storage > Cookies;
       Chrome: DevTools > Application > Cookies). A bare subscription token also works.
    2. Pick any replay on https://f1tv.formula1.com and copy its URL.
    3. python3 stream_check.py https://f1tv.formula1.com/detail/1000009999/some-title
       (or just the numeric contentId). Paste the cookie/token at the hidden prompt.
    4. Send back stream_check_result.txt (written next to this script). Tokens are masked.

Also reported: per HLS media playlist, whether it carries #EXT-X-PROGRAM-DATE-TIME (a sync
clock), PLAYLIST-TYPE, TARGETDURATION, ENDLIST (absent = live) and the segment count; the
master's alternate audio renditions; and, in the multiview sections, the first feed plus one
feed whose URL has a query string (onboards) plus the last feed, with each feed's non-URL
metadata fields.

Optional: add --save-urls to also write stream_urls_PRIVATE.txt next to the script with the
UNMASKED signed URLs, so the owner can test playback locally (open the first URL in Safari on
the Mac; Safari plays HLS natively). That file is never printed and never goes into
stream_check_result.txt. Do NOT send it to anyone; the links expire.

LIVE MODE (--live): for a live session's F1 TV page URL / contentId. Makes the WEB_DASH single-feed
and multiview play requests as above, then for the world feed, F1 Live and one onboard fetches the
media playlist 4 times, 15 seconds apart, and reports per fetch: segment count, MEDIA-SEQUENCE,
ENDLIST, PLAYLIST-TYPE, first/last PROGRAM-DATE-TIME and the "live edge delay" (this Mac's UTC now
minus last PDT plus that segment's duration), plus the rewind window, whether the three feeds are in
step and whether any DRM tag shows up. Playlist text only: no segments, no licence requests.
    pbpaste | python3 stream_check.py --live https://f1tv.formula1.com/detail/1000009999/some-title
Output goes to stream_check_live_result.txt (also safe to share). Keep this Mac's clock on
"set automatically": the delay figure includes any error in it.

Python 3.9+, standard library only.
"""

import argparse
import getpass
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

# --- Mirrors of F1TvApi.kt -------------------------------------------------------------------

BASE = "https://f1tv.formula1.com"
LANGUAGE = "ENG"
TIMEOUT = 20
MANIFEST_CAP = 2 * 1024 * 1024

# The Android app sends the WebView's default UA with "; wv" removed (MainActivity.kt) and the
# WebView's Chrome major as browserVersion. This is a representative value for a Pixel on
# Android 14 with WebView 140 (the app's fallback chromeMajor).
ANDROID_UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A.240805.005) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Version/4.0 Chrome/140.0.7339.207 Mobile Safari/537.36")
ANDROID_CHROME_MAJOR = "140"
ANDROID_OS_VERSION = "14"

SAFARI_VERSION = "26.1"
SAFARI_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/%s Safari/605.1.15" % SAFARI_VERSION)

API_VERSION = re.compile(r"^\d+\.\d+$")


def device_info(os_name, browser, browser_version, os_version, multiview):
    """Same fields and order as webDeviceInfo() in F1TvApi.kt."""
    return ";".join([
        "device=web",
        "screen=browser",
        "os=" + os_name,
        "browser=" + browser,
        "browserVersion=" + browser_version,
        "osVersion=" + os_version,
        "appVersion=54.2.1",
        "playerVersion=8.212.0",
        "p=" + ("true" if multiview else "false"),
        "tms=1",
    ])


def android_device_info(multiview):
    return device_info("android", "chrome", ANDROID_CHROME_MAJOR, ANDROID_OS_VERSION, multiview)


def safari_device_info(multiview):
    return device_info("mac os", "safari", SAFARI_VERSION, "10.15.7", multiview)


# (label, platform, user agent, device-info builder or None)
VARIANTS = [
    ("WEB_DASH (app default, control)", "WEB_DASH", ANDROID_UA, android_device_info),
    ("WEB_HLS (app web UA/device-info)", "WEB_HLS", ANDROID_UA, android_device_info),
    ("WEB_HLS (macOS Safari UA/device-info)", "WEB_HLS", SAFARI_UA, safari_device_info),
    ("MOBILE_HLS", "MOBILE_HLS", ANDROID_UA, None),
    ("TABLET_HLS", "TABLET_HLS", ANDROID_UA, None),
    ("BIG_SCREEN_HLS", "BIG_SCREEN_HLS", ANDROID_UA, None),
]
# Premium multiview (player_tm): every feed of a session in one play session, as multiPlay() asks.
MULTIVIEW_VARIANTS = [
    ("MULTIVIEW WEB_DASH (app default, control)", "WEB_DASH", ANDROID_UA, android_device_info),
    ("MULTIVIEW WEB_HLS (macOS Safari UA/device-info)", "WEB_HLS", SAFARI_UA, safari_device_info),
]

MULTIVIEW_TIERS = ("OPS", "VIP", "PREMIUM")

# --- Output and masking ----------------------------------------------------------------------

SECRETS = []  # exact strings never to print (subscription and entitlement tokens)
LINES = []
PRIVATE_URLS = []  # (label, unmasked url): only ever written to stream_urls_PRIVATE.txt with --save-urls

JWT = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*")
URL_RE = re.compile(r"(?:https?|skd)://[^\s\"'<>,\[\]{}]+")
LONG_BLOB = re.compile(r"[A-Za-z0-9+/_=-]{64,}")


def add_secret(value):
    if value and len(value) >= 6 and value not in SECRETS:
        SECRETS.append(value)
        # Also mask its URL-encoded form.
        enc = urllib.parse.quote(value, safe="")
        if enc != value:
            SECRETS.append(enc)


def mask_url(url):
    """scheme://host/path with the query replaced by ?… and token-looking path parts masked."""
    try:
        p = urllib.parse.urlsplit(url)
    except ValueError:
        return "<unparseable url>"
    if not p.scheme or not p.netloc:
        return scrub_plain(url)
    segments = []
    for seg in p.path.split("/"):
        if ("=" in seg or "~" in seg or "hmac" in seg.lower()
                or (len(seg) >= 40 and re.fullmatch(r"[A-Za-z0-9+_=-]+", seg))):
            segments.append("…")
        else:
            segments.append(seg)
    out = "%s://%s%s" % (p.scheme, p.netloc, "/".join(segments))
    if p.query:
        out += "?…"
    return out


def scrub_plain(text):
    for s in SECRETS:
        text = text.replace(s, "<masked>")
    text = JWT.sub("<masked-jwt>", text)
    return text


def scrub(text):
    """Make any text safe to share: known tokens, JWTs, URL queries and long blobs masked."""
    text = scrub_plain(str(text))
    text = URL_RE.sub(lambda m: mask_url(m.group(0)), text)
    text = LONG_BLOB.sub("<masked-blob>", text)
    return text


def out(line=""):
    line = scrub(line)
    LINES.append(line)
    print(line)


def write_result_file(name="stream_check_result.txt"):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(LINES) + "\n")
        return path
    except OSError as e:
        print("Could not write %s: %s" % (path, e))
        return None


def record_private_url(label, url):
    """Remember an unmasked URL for --save-urls. Never printed and never added to LINES."""
    PRIVATE_URLS.append((" ".join(str(label).split()), url))


def write_private_file():
    """Writes stream_urls_PRIVATE.txt (owner-only permissions). Returns the path or None."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stream_urls_PRIVATE.txt")
    lines = ["# PRIVATE: contains signed F1 TV links tied to your account. Do NOT share or post this "
             "file. The links expire soon, so test promptly."]
    for label, url in PRIVATE_URLS:
        lines.append("# " + label)
        lines.append(url)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        return path
    except OSError as e:
        print("Could not write %s: %s" % (path, e))
        return None


# --- Helpers (unit-checkable) ----------------------------------------------------------------

def extract_content_id(arg):
    arg = arg.strip()
    if re.fullmatch(r"\d+", arg):
        return int(arg)
    m = re.search(r"/detail/(\d+)", arg)
    if m:
        return int(m.group(1))
    m = re.search(r"contentId=(\d+)", arg)
    if m:
        return int(m.group(1))
    m = re.search(r"/(\d{6,})(?:[/?#]|$)", arg)
    if m:
        return int(m.group(1))
    return None


def decode_signin(raw):
    """
    Returns (subscription_token, kind). Accepts the login-session cookie value (JSON, raw or
    URL-encoded, optionally with a 'login-session=' prefix) or a bare subscription token.
    Mirrors LoginCookie.readToken(): JSON -> data.subscriptionToken.
    Raises ValueError when it looks like a cookie but has no token.
    """
    value = raw.strip().strip('"').strip("'").strip()
    if value.lower().startswith("login-session="):
        value = value.split("=", 1)[1].strip()
    candidates = [value]
    decoded = value
    for _ in range(2):  # sometimes double-encoded
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


def parse_attributes(attr_text):
    """HLS attribute list: KEY=VALUE,KEY="quoted, with commas",..."""
    attrs = {}
    for m in re.finditer(r'([A-Z0-9-]+)=("([^"]*)"|[^,]*)', attr_text):
        attrs[m.group(1)] = m.group(3) if m.group(3) is not None else m.group(2)
    return attrs


def short_uri(uri):
    if uri is None:
        return "(none)"
    scheme = uri.split(":", 1)[0] if ":" in uri else "(relative)"
    return "scheme=%s first24=%s" % (scheme, scrub(uri[:24]))


def parse_hls(text):
    """Returns dict: keys [(tag, attrs)], variants [(attrs, uri)], audio [attrs], is_master."""
    keys, variants, audio = [], [], []
    lines = [l.strip() for l in text.splitlines()]
    pending = None
    for line in lines:
        if not line:
            continue
        if line.startswith("#EXT-X-KEY:") or line.startswith("#EXT-X-SESSION-KEY:"):
            tag, rest = line[1:].split(":", 1)
            keys.append((tag, parse_attributes(rest)))
        elif line.startswith("#EXT-X-MEDIA:"):
            a = parse_attributes(line.split(":", 1)[1])
            if a.get("TYPE", "").upper() == "AUDIO":
                audio.append(a)
        elif line.startswith("#EXT-X-STREAM-INF:"):
            pending = parse_attributes(line.split(":", 1)[1])
        elif not line.startswith("#") and pending is not None:
            variants.append((pending, line))
            pending = None
    return {"keys": keys, "variants": variants, "audio": audio, "is_master": bool(variants)}


def parse_media_playlist(text):
    """Sync-relevant facts of an HLS media (variant) playlist."""
    pdt, ptype, target = [], None, None
    endlist, segments = False, 0
    for line in (l.strip() for l in text.splitlines()):
        if line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
            pdt.append(line.split(":", 1)[1].strip())
        elif line.startswith("#EXT-X-PLAYLIST-TYPE:"):
            ptype = line.split(":", 1)[1].strip()
        elif line.startswith("#EXT-X-TARGETDURATION:"):
            target = line.split(":", 1)[1].strip()
        elif line.startswith("#EXT-X-ENDLIST"):
            endlist = True
        elif line.startswith("#EXTINF:"):
            segments += 1
    return {"pdt": pdt, "playlist_type": ptype, "target_duration": target,
            "endlist": endlist, "segments": segments}


def report_media_playlist(text, truncated, pad):
    """Prints the sync/shape facts of a media playlist. Returns True if it has PROGRAM-DATE-TIME."""
    mp = parse_media_playlist(text)
    out(pad + "Sync/shape of this media playlist%s:" % (" (truncated at 2 MB, counts are lower bounds)" if truncated else ""))
    out(pad + "  Segments listed (#EXTINF): %d" % mp["segments"])
    out(pad + "  #EXT-X-TARGETDURATION: %s" % (mp["target_duration"] if mp["target_duration"] is not None else "(absent)"))
    out(pad + "  #EXT-X-PLAYLIST-TYPE: %s" % (mp["playlist_type"] if mp["playlist_type"] is not None else "(absent)"))
    out(pad + "  #EXT-X-ENDLIST: %s" % ("present (finished / VOD-style)" if mp["endlist"]
                                         else "absent (live-style: playlist still growing)"))
    if mp["pdt"]:
        out(pad + "  #EXT-X-PROGRAM-DATE-TIME: %d tag(s), first = %s" % (len(mp["pdt"]), mp["pdt"][0][:40]))
    else:
        out(pad + "  #EXT-X-PROGRAM-DATE-TIME: none")
    return bool(mp["pdt"])


def has_query(url):
    try:
        return bool(urllib.parse.urlsplit(url).query)
    except ValueError:
        return False


def scalar_fields(obj, path=""):
    """[(path, scalar)] found recursively, leaving out URL values (they are never printed here)."""
    acc = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            acc.extend(scalar_fields(v, "%s.%s" % (path, k) if path else str(k)))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            acc.extend(scalar_fields(v, "%s[%d]" % (path, i)))
    elif not (isinstance(obj, str) and re.match(r"^(https?|skd)://", obj.strip())):
        acc.append((path, obj))
    return acc


def feed_fields_line(feed, limit=60):
    fields = scalar_fields(feed)
    parts = ["%s=%s" % (p, show_value(v, 80)) for p, v in fields[:limit]]
    if len(fields) > limit:
        parts.append("(+%d more fields)" % (len(fields) - limit))
    return "; ".join(parts) if parts else "(no scalar fields)"


def sync_clock_text(flags):
    if not flags:
        return "n/a (no HLS media playlist was fetched for this variant)"
    yes = sum(1 for f in flags if f)
    if yes == len(flags):
        return "yes (%d of %d inspected media playlists carry #EXT-X-PROGRAM-DATE-TIME)" % (yes, len(flags))
    return "no (%d of %d inspected media playlists carry #EXT-X-PROGRAM-DATE-TIME)" % (yes, len(flags))


def describe_key(tag, attrs):
    return "#%s METHOD=%s KEYFORMAT=%s URI[%s]" % (
        tag, attrs.get("METHOD", "?"), attrs.get("KEYFORMAT", "(none = identity)"), short_uri(attrs.get("URI")))


FAIRPLAY_KEYFORMAT = "com.apple.streamingkeydelivery"
WIDEVINE_UUID = "edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
PLAYREADY_UUID = "9a04f079-9840-4286-ab92-e65be0885f95"
FAIRPLAY_UUID = "94ce86fb-07ff-4f43-adb8-93d2fa968ca2"


def classify_hls_keys(keys):
    """Returns set of {'fairplay','widevine','playready','aes128','other'}."""
    found = set()
    for _, a in keys:
        method = a.get("METHOD", "").upper()
        if method == "NONE":
            continue
        fmt = a.get("KEYFORMAT", "").lower()
        uri = a.get("URI", "") or ""
        if fmt == FAIRPLAY_KEYFORMAT or uri.lower().startswith("skd://"):
            found.add("fairplay")
        elif WIDEVINE_UUID in fmt:
            found.add("widevine")
        elif "playready" in fmt or PLAYREADY_UUID in fmt:
            found.add("playready")
        elif method == "AES-128" and fmt in ("", "identity"):
            found.add("aes128")
        else:
            found.add("other")
    return found


def parse_dash_protection(text):
    """[(schemeIdUri, value)] for every ContentProtection element."""
    found = []
    for m in re.finditer(r"<(?:\w+:)?ContentProtection\b([^>]*)>", text):
        attrs = dict(re.findall(r'([\w:]+)\s*=\s*"([^"]*)"', m.group(1)))
        found.append((attrs.get("schemeIdUri", "?"), attrs.get("value", "")))
    return found


def dash_drm_name(scheme):
    s = scheme.lower()
    if WIDEVINE_UUID in s:
        return "Widevine"
    if PLAYREADY_UUID in s:
        return "PlayReady"
    if FAIRPLAY_UUID in s:
        return "FairPlay"
    if "mp4protection" in s:
        return "CENC marker"
    return "unknown"


def find_keys(obj, needles, path=""):
    """Recursively find keys whose name contains any needle (case-insensitive)."""
    hits = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = "%s.%s" % (path, k) if path else str(k)
            if any(n in str(k).lower() for n in needles):
                hits.append((p, v))
            hits.extend(find_keys(v, needles, p))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            hits.extend(find_keys(v, needles, "%s[%d]" % (path, i)))
    return hits


def show_value(v, limit=300):
    if isinstance(v, str):
        if re.match(r"^(https?|skd)://", v):
            return mask_url(v)
        s = v
    else:
        s = json.dumps(v, separators=(",", ":"), ensure_ascii=False)
    s = scrub(s)
    return s if len(s) <= limit else s[:limit] + "…(%d chars)" % len(s)


# --- HTTP ------------------------------------------------------------------------------------

class HttpError(Exception):
    def __init__(self, status, body, msg):
        Exception.__init__(self, msg)
        self.status = status
        self.body = body


def http_get(url, headers, cap=None):
    """Returns (status, text). Raises HttpError on >= 400 or network failure (status 0)."""
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = resp.read(cap + 1) if cap else resp.read()
            truncated = cap is not None and len(data) > cap
            if truncated:
                data = data[:cap]
            text = data.decode("utf-8", errors="replace")
            return resp.status, text, truncated
    except urllib.error.HTTPError as e:
        try:
            body = e.read(4096).decode("utf-8", errors="replace")
        except Exception:
            body = ""
        if e.code == 401:
            hint = "401 Unauthorized: the sign-in was refused (signed out or token expired). Copy a fresh cookie."
        elif e.code == 403:
            hint = ("403 Forbidden: refused for this account/platform (signed out, or the plan doesn't "
                    "include video, or this platform string isn't allowed).")
        else:
            hint = "HTTP %d" % e.code
        raise HttpError(e.code, body, hint)
    except urllib.error.URLError as e:
        reason = e.reason
        if isinstance(reason, ssl.SSLError) and "CERTIFICATE_VERIFY_FAILED" in str(reason):
            msg = ("TLS certificate check failed. If this is a python.org Python, run "
                   "'Install Certificates.command' from its Applications folder, or use /usr/bin/python3.")
        else:
            msg = "Network error: %s" % reason
        raise HttpError(0, "", msg)
    except (socket.timeout, TimeoutError):
        raise HttpError(0, "", "Network error: timed out after %d s" % TIMEOUT)
    except (ConnectionError, OSError) as e:
        raise HttpError(0, "", "Network error: %s" % e)


def f1_get(url, ua, headers=None):
    """Like F1TvApi.get(): UA + extra headers, JSON body. Returns (status, json)."""
    h = {"User-Agent": ua}
    h.update(headers or {})
    status, text, _ = http_get(url, h)
    try:
        return status, json.loads(text)
    except ValueError:
        raise HttpError(status, text, "HTTP %d but the body isn't JSON" % status)


def api_url(version, platform, path, signed_in=True):
    """F1TvApi.url(): $BASE/$version/$loginStatus/$LANGUAGE/$platform/ALL/$path"""
    return "%s/%s/%s/%s/%s/ALL/%s" % (BASE, version, "R" if signed_in else "A", LANGUAGE, platform, path)


def envelope_note(body):
    if isinstance(body, dict):
        code = body.get("resultCode")
        if code is not None and str(code).upper() != "OK":
            return "resultCode=%s message=%s errorDescription=%s" % (
                code, body.get("message"), body.get("errorDescription"))
    return None


def print_http_error(e, indent="  "):
    out(indent + ("HTTP status: %d" % e.status if e.status else "HTTP status: (no response)"))
    out(indent + str(e))
    if e.body:
        body = e.body
        out(indent + "Body (first 600 chars): " + scrub(body)[:600])


# --- Steps -----------------------------------------------------------------------------------

def step_config():
    out("== 1. GET /config ==")
    play_v, video_v = "3.0", "4.0"
    try:
        status, cfg = f1_get(BASE + "/config", ANDROID_UA)
    except HttpError as e:
        print_http_error(e)
        out("  Using the app's fallback versions play=%s video=%s" % (play_v, video_v))
        return play_v
    out("  HTTP status: %d" % status)
    api = cfg.get("apiConfig") if isinstance(cfg, dict) else None
    if isinstance(api, dict):
        pv = str(api.get("playAPIVersion", "")).strip()
        vv = str(api.get("videoAPIVersion", "")).strip()
        out("  apiConfig.playAPIVersion = %r   apiConfig.videoAPIVersion = %r" % (pv, vv))
        if API_VERSION.match(pv):
            play_v = pv
        if API_VERSION.match(vv):
            video_v = vv
        others = {k: v for k, v in api.items() if "version" in k.lower() and k not in ("playAPIVersion", "videoAPIVersion")}
        for k, v in others.items():
            out("  apiConfig.%s = %s" % (k, show_value(v)))
    else:
        out("  (no apiConfig object; top-level keys: %s)" % (", ".join(cfg.keys()) if isinstance(cfg, dict) else type(cfg).__name__))
    hits = find_keys(cfg, ("drm", "cert", "fairplay", "fps", "license", "licence"))
    out("  DRM/cert/licence-related keys found: %d" % len(hits))
    for p, v in hits[:80]:
        out("    %s = %s" % (p, show_value(v)))
    if len(hits) > 80:
        out("    … %d more not shown" % (len(hits) - 80))
    out("  Using play API version %s" % play_v)
    return play_v


def sign_in(token, platform, ua, verbose, capture=None):
    """ENTITLEMENT then LOCATION, as F1TvApi.login() does. Returns (entitlement, tier, groupId).
    capture: optional dict; when given, capture["location"] receives the raw userLocation[0]."""
    url = "%s/2.0/R/%s/%s/ALL/USER/ENTITLEMENT" % (BASE, LANGUAGE, platform)
    status, body = f1_get(url, ua, {"ascendontoken": token})
    result = body.get("resultObj") if isinstance(body, dict) else None
    ent = result.get("entitlementToken") if isinstance(result, dict) else None
    if not ent:
        note = envelope_note(body) or "no resultObj.entitlementToken"
        raise HttpError(status, json.dumps(body)[:600], "ENTITLEMENT returned no token (%s)" % note)
    add_secret(ent)
    if verbose:
        out("  ENTITLEMENT HTTP %d: entitlementToken received (%d chars, masked)" % (status, len(ent)))
        for k, v in result.items():
            if k != "entitlementToken":
                out("    resultObj.%s = %s" % (k, show_value(v)))

    status, body = f1_get(api_url("1.0", platform, "USER/LOCATION"), ua, {"entitlementtoken": ent})
    try:
        loc = body["resultObj"]["userLocation"][0]
    except (KeyError, IndexError, TypeError):
        raise HttpError(status, json.dumps(body)[:600], "LOCATION response had no resultObj.userLocation[0]")
    if capture is not None:
        capture["location"] = loc
    tier = str(loc.get("entitlement", ""))
    group = loc.get("groupId", 0)
    if verbose:
        out("  LOCATION HTTP %d: entitlement/tier = %s, groupId = %s" % (status, tier, group))
        for k in sorted(loc.keys()):
            if k not in ("entitlement", "groupId"):
                out("    userLocation[0].%s = %s" % (k, show_value(loc[k])))
    return ent, tier, group


CALLOUT_KEYS = ("streamType", "drmType", "laURL")


def run_variant(label, platform, ua, devinfo, token, content_id, play_v, player="player_bm"):
    """Returns dict with verdict info. Never raises."""
    r = {"label": label, "verdict": "refused", "detail": "", "sync": []}
    out("")
    out("== %s ==" % label)
    out("  platform=%s  UA=%s" % (platform, "macOS Safari %s" % SAFARI_VERSION if ua == SAFARI_UA else "Android WebView (app default)"))
    try:
        ent, tier, _ = sign_in(token, platform, ua, verbose=False)
        out("  ENTITLEMENT + LOCATION on %s: ok (tier %s)" % (platform, tier))
    except HttpError as e:
        out("  Sign-in on this platform string failed:")
        print_http_error(e, "    ")
        r["detail"] = "entitlement/location refused (%s)" % (e.status or "network")
        return r

    headers = {"ascendontoken": token, "entitlementtoken": ent}
    if devinfo is not None:  # F1TvApi.play(): only WEB* platforms send x-f1-device-info
        headers["x-f1-device-info"] = devinfo(tier in MULTIVIEW_TIERS)
        out("  x-f1-device-info: %s" % headers["x-f1-device-info"])
    else:
        out("  x-f1-device-info: (not sent, as the app does for non-WEB platforms)")
    url = api_url(play_v, platform, "CONTENT/PLAY") + "?contentId=%d&player=%s" % (content_id, player)
    out("  GET %s" % mask_url(url))
    try:
        status, body = f1_get(url, ua, headers)
    except HttpError as e:
        print_http_error(e)
        r["detail"] = "CONTENT/PLAY HTTP %s" % (e.status or "network error")
        return r
    out("  HTTP status: %d" % status)
    note = envelope_note(body)
    if note:
        out("  Envelope: " + note)
    result = body.get("resultObj") if isinstance(body, dict) else None
    if not isinstance(result, dict):
        out("  No resultObj in the response. Body (first 600): " + scrub(json.dumps(body))[:600])
        r["detail"] = "no resultObj"
        return r

    out("  resultObj keys:")
    for k, v in result.items():
        out("    %s = %s" % (k, show_value(v)))
    out("  Call-outs:")
    for k in CALLOUT_KEYS:
        out("    %s: %s" % (k, show_value(result[k]) if k in result else "(absent)"))
    drm_like = find_keys(result, ("cert", "fairplay", "fps", "drm"))
    for p, v in drm_like:
        if p not in CALLOUT_KEYS:
            out("    %s: %s" % (p, show_value(v)))

    hint_text = " ".join(str(result.get(k, "")) for k in ("streamType", "drmType")).lower()
    hint_text += " " + " ".join(str(v).lower() for p, v in drm_like if isinstance(v, (str, int, float)))
    fp_hint = ("fairplay" in hint_text or re.search(r"(^|[^a-z])fps?([^a-z]|$)", hint_text) is not None)
    wv_hint = "widevine" in hint_text or bool(result.get("laURL"))

    stream_url = result.get("url")
    tme = result.get("tme")
    feeds = tme.get("feeds") if isinstance(tme, dict) else None
    main_idx = None  # index of the feed used as the main manifest, when it came from the feed list
    usable = []
    if isinstance(feeds, list):
        usable = [i for i, f in enumerate(feeds) if isinstance(f, dict) and isinstance(f.get("url"), str) and f.get("url")]
        out("  Multiview feeds: %d" % len(feeds))
        shown = list(range(min(30, len(feeds))))
        if len(feeds) > 30:
            shown.append(len(feeds) - 1)  # the last feed is always described
        for i in shown:
            f = feeds[i]
            if isinstance(f, dict):
                meta = f.get("metadata") if isinstance(f.get("metadata"), dict) else {}
                out("    channel_id=%s url=%s" % (meta.get("channel_id"), show_value(f.get("url", ""))))
                out("      feed #%d fields: %s" % (i + 1, feed_fields_line(f)))
        if usable and not stream_url:
            main_idx = usable[0]
            stream_url = feeds[main_idx]["url"]
            out("  Inspecting the first feed's manifest.")
    found = set()
    manifest_read = False
    sync = []
    if not isinstance(stream_url, str) or not stream_url:
        out("  No url in resultObj.")
    else:
        if platform == "WEB_DASH" and player == "player_bm":
            ext = urllib.parse.urlsplit(stream_url).path.lower().rsplit(".", 1)[-1][:5]
            record_private_url("single-feed WEB_DASH play response url (.%s)" % ext, stream_url)
        elif main_idx is not None:
            record_private_url("%s feed #%d of %d (first)" % (label, main_idx + 1, len(feeds)), stream_url)
        manifest_read, found, sync = fetch_and_inspect(stream_url, ua, "", main_idx is not None)
    if usable:
        sync = sync + inspect_onboard_feeds(feeds, usable, main_idx, label, ua)
    r["sync"] = sync
    # Kept in memory only for --live (never printed here): signed URLs and the feed list.
    r["_stream_url"] = stream_url if isinstance(stream_url, str) and stream_url else None
    r["_feeds"] = feeds if isinstance(feeds, list) else None
    r["_drm_hint"] = {"drmType": show_value(result.get("drmType", "")) if result.get("drmType") else "",
                      "laURL": bool(result.get("laURL")), "fairplay_hint": fp_hint}

    r.update(classify(found, manifest_read, fp_hint, wv_hint, bool(stream_url)))
    return r


def fetch_and_inspect(stream_url, ua, pad="", always_variant=False):
    """Returns (read_ok, drm names, [has PROGRAM-DATE-TIME per media playlist inspected])."""
    path = urllib.parse.urlsplit(stream_url).path.lower()
    if path.endswith(".m3u8") or path.endswith(".mpd"):
        return inspect_manifest(stream_url, ua, path.endswith(".m3u8"), pad, always_variant)
    out(pad + "  Manifest not fetched: url path is not .m3u8 or .mpd (%s)" % mask_url(stream_url))
    return False, set(), []


def inspect_onboard_feeds(feeds, usable, main_idx, label, ua):
    """Inspects the first feed, one feed whose URL has a query string (onboards) and the last feed.
    Returns the PROGRAM-DATE-TIME flags of the media playlists inspected here."""
    roles = {}
    order = []

    def add(i, role):
        if i not in roles:
            roles[i] = []
            order.append(i)
        roles[i].append(role)

    add(usable[0], "first")
    q = next((i for i in usable[1:] if has_query(feeds[i]["url"])), None)
    if q is not None:
        add(q, "URL has a query string")
    else:
        out("  Onboard check: no other feed URL carries a query string.")
    add(usable[-1], "last")
    out("  Onboard check: feeds %s of %d (first / has query string / last)." % (
        ", ".join("#%d" % (i + 1) for i in order), len(feeds)))
    sync = []
    for i in order:
        f = feeds[i]
        meta = f.get("metadata") if isinstance(f.get("metadata"), dict) else {}
        out("  Feed #%d of %d (%s) channel_id=%s" % (i + 1, len(feeds), ", ".join(roles[i]), meta.get("channel_id")))
        if i == main_idx:
            out("    Already inspected above as the main manifest.")
            continue
        record_private_url("%s feed #%d of %d (%s)" % (label, i + 1, len(feeds), ", ".join(roles[i])), f["url"])
        _, _, s = fetch_and_inspect(f["url"], ua, "  ", True)
        sync.extend(s)
    return sync


def inspect_manifest(url, ua, is_hls, pad="", always_variant=False):
    """Returns (read_ok, set of drm names, [has PROGRAM-DATE-TIME per media playlist inspected]).
    always_variant fetches the first variant playlist even when the master already shows key tags."""
    sync = []
    out(pad + "  Manifest (%s, text only, cap 2 MB): %s" % ("HLS" if is_hls else "DASH", mask_url(url)))
    try:
        status, text, truncated = http_get(url, {"User-Agent": ua}, cap=MANIFEST_CAP)
    except HttpError as e:
        print_http_error(e, pad + "    ")
        return False, set(), sync
    out(pad + "    HTTP %d, %d chars%s" % (status, len(text), " (truncated at 2 MB)" if truncated else ""))
    if is_hls:
        if "#EXTM3U" not in text[:1024]:
            out(pad + "    Not an HLS playlist (no #EXTM3U).")
            return False, set(), sync
        info = parse_hls(text)
        out(pad + "    Key tags in master: %d" % len(info["keys"]))
        for tag, a in info["keys"]:
            out(pad + "      " + describe_key(tag, a))
        out(pad + "    Variant streams: %d" % len(info["variants"]))
        res = [a.get("RESOLUTION", "?") for a, _ in info["variants"]]
        if res:
            out(pad + "      RESOLUTION values: " + ", ".join(res))
        out(pad + "    Alternate audio renditions in master (#EXT-X-MEDIA:TYPE=AUDIO): %d" % len(info["audio"]))
        for a in info["audio"]:
            out(pad + "      NAME=%s LANGUAGE=%s" % (a.get("NAME", "(none)"), a.get("LANGUAGE", "(none)")))
        found = classify_hls_keys(info["keys"])
        if info["variants"] and (not info["keys"] or always_variant):
            variant_url = urllib.parse.urljoin(url, info["variants"][0][1])
            if info["keys"]:
                out(pad + "    Fetching first variant playlist: %s" % mask_url(variant_url))
            else:
                out(pad + "    No key tags in master; fetching first variant playlist: %s" % mask_url(variant_url))
            try:
                vstatus, vtext, vtrunc = http_get(variant_url, {"User-Agent": ua}, cap=MANIFEST_CAP)
                vinfo = parse_hls(vtext)
                out(pad + "      HTTP %d, key tags: %d" % (vstatus, len(vinfo["keys"])))
                seen = set()
                for tag, a in vinfo["keys"]:
                    d = describe_key(tag, a)
                    if d not in seen:  # rotation repeats the same tag shape
                        seen.add(d)
                        out(pad + "        " + d)
                if len(vinfo["keys"]) > len(seen):
                    out(pad + "        (%d repeats of the above not shown)" % (len(vinfo["keys"]) - len(seen)))
                found |= classify_hls_keys(vinfo["keys"])
                if "#EXTM3U" in vtext[:1024]:
                    sync.append(report_media_playlist(vtext, vtrunc, pad + "      "))
                else:
                    out(pad + "      Not an HLS playlist (no #EXTM3U); sync not checked.")
            except HttpError as e:
                print_http_error(e, pad + "      ")
                return False, found, sync
        return True, found, sync
    prot = parse_dash_protection(text)
    out(pad + "    ContentProtection elements: %d" % len(prot))
    seen = set()
    found = set()
    for scheme, value in prot:
        name = dash_drm_name(scheme)
        if (scheme, value) not in seen:
            seen.add((scheme, value))
            out(pad + "      schemeIdUri=%s%s  -> %s" % (scheme, (" value=%s" % value) if value else "", name))
        if name == "Widevine":
            found.add("widevine")
        elif name == "PlayReady":
            found.add("playready")
        elif name == "FairPlay":
            found.add("fairplay")
        elif name == "CENC marker":
            found.add("cenc")
    return True, found, sync


def classify(found, manifest_read, fp_hint, wv_hint, has_url):
    if not has_url:
        return {"verdict": "refused", "detail": "no stream url"}
    if "fairplay" in found or fp_hint:
        why = "FairPlay key tags in the manifest" if "fairplay" in found else "play response says FairPlay/FP"
        return {"verdict": "FairPlay offered", "detail": why}
    drm = found & {"widevine", "playready", "other", "cenc"}
    if drm or (wv_hint and not manifest_read):
        names = sorted(found & {"widevine", "playready", "other"}) or ["laURL/drmType in play response"]
        return {"verdict": "Widevine only", "detail": "no FairPlay; DRM seen: " + ", ".join(names)}
    if not manifest_read:
        return {"verdict": "unknown", "detail": "manifest not read and no DRM hints in the play response"}
    if "aes128" in found:
        return {"verdict": "unprotected", "detail": "AES-128 clear-key encryption only (AVPlayer plays this without FairPlay)"}
    if wv_hint:
        return {"verdict": "unprotected",
                "detail": "manifest has no key tags although the response carries a laURL; check the variant notes"}
    return {"verdict": "unprotected", "detail": "no key tags / ContentProtection"}


# --- Live mode (--live) ----------------------------------------------------------------------

LIVE_ROUNDS = 4
LIVE_INTERVAL_S = 15

PDT_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?\s*(Z|[+-]\d{2}:?\d{2})?$")


def parse_pdt(text):
    """#EXT-X-PROGRAM-DATE-TIME value to an aware UTC datetime (no zone = UTC). None if unparseable."""
    m = PDT_RE.match((text or "").strip())
    if not m:
        return None
    y, mo, d, h, mi, sec, frac, zone = m.groups()
    micro = int(((frac or "0") + "000000")[:6])
    try:
        dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(sec), micro, tzinfo=timezone.utc)
    except ValueError:
        return None
    if zone and zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        dt -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return dt


def utc_now():
    return datetime.now(timezone.utc)


def fmt_utc(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def parse_live_playlist(text):
    """Live-relevant facts of an HLS media playlist, including each segment's start time.
    A segment's start is its own #EXT-X-PROGRAM-DATE-TIME if it has one, else the previous
    segment's end (flagged as derived)."""
    media_seq = ptype = target = None
    endlist = False
    discontinuities = 0
    segs = []
    pdt_raw = []
    pending = None  # parsed PDT waiting for the next #EXTINF
    prev_end = None
    for line in (l.strip() for l in text.splitlines()):
        if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            try:
                media_seq = int(line.split(":", 1)[1].strip())
            except ValueError:
                media_seq = None
        elif line.startswith("#EXT-X-PLAYLIST-TYPE:"):
            ptype = line.split(":", 1)[1].strip()
        elif line.startswith("#EXT-X-TARGETDURATION:"):
            target = line.split(":", 1)[1].strip()
        elif line.startswith("#EXT-X-ENDLIST"):
            endlist = True
        elif line == "#EXT-X-DISCONTINUITY":
            discontinuities += 1
        elif line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
            raw = line.split(":", 1)[1].strip()
            pdt_raw.append(raw)
            pending = parse_pdt(raw)
        elif line.startswith("#EXTINF:"):
            try:
                dur = float(line[len("#EXTINF:"):].split(",", 1)[0])
            except ValueError:
                dur = 0.0
            if pending is not None:
                start, tagged = pending, True
            else:
                start, tagged = prev_end, False
            pending = None
            segs.append({"start": start, "dur": dur, "tagged": tagged})
            prev_end = start + timedelta(seconds=dur) if start is not None else None
    return {"media_sequence": media_seq, "playlist_type": ptype, "target_duration": target,
            "endlist": endlist, "segments": len(segs), "segs": segs, "pdt_raw": pdt_raw,
            "discontinuities": discontinuities}


def analyse_live_playlist(parsed, t_recv):
    """Adds first/last start, live edge delay and rewind (seconds) when segment times are known."""
    a = {"first_start": None, "last_start": None, "last_dur": None, "last_derived": False,
         "delay": None, "rewind": None, "rewind_full": None}
    segs = parsed["segs"]
    if not segs or segs[0]["start"] is None or segs[-1]["start"] is None:
        return a
    first, last = segs[0], segs[-1]
    last_end = last["start"] + timedelta(seconds=last["dur"])
    a.update(first_start=first["start"], last_start=last["start"], last_dur=last["dur"],
             last_derived=not last["tagged"],
             delay=(t_recv - last_end).total_seconds(),
             rewind=(last["start"] - first["start"]).total_seconds(),
             rewind_full=(last_end - first["start"]).total_seconds())
    return a


def fmt_s(v, digits=1):
    return "n/a" if v is None else ("%+.*f s" % (digits, v))


def resolve_media_playlist(master_url, ua):
    """Fetches the master (text only) and returns (media playlist url, drm names found, note).
    A url that is already a media playlist is returned as is."""
    path = urllib.parse.urlsplit(master_url).path.lower()
    if not path.endswith(".m3u8"):
        return None, set(), "not an HLS (.m3u8) url, so not polled"
    try:
        _, text, _ = http_get(master_url, {"User-Agent": ua}, cap=MANIFEST_CAP)
    except HttpError as e:
        return None, set(), "master playlist fetch failed: %s" % e
    if "#EXTM3U" not in text[:1024]:
        return None, set(), "master url did not return an HLS playlist"
    info = parse_hls(text)
    found = classify_hls_keys(info["keys"])
    if info["variants"]:
        return urllib.parse.urljoin(master_url, info["variants"][0][1]), found, "first variant of the master"
    if "#EXTINF:" in text:
        return master_url, found, "url is itself a media playlist"
    return None, found, "master had no variant streams"


def feed_text(feed):
    """Lower-case text of every non-URL scalar in a multiview feed, to recognise it by name."""
    return " | ".join("%s=%s" % (p, v) for p, v in scalar_fields(feed) if isinstance(v, (str, int, float))).lower()


def pick_live_feeds(feeds, f1live_channel=None, onboard_channel=None):
    """Returns {'F1 Live': (idx, how), 'onboard': (idx, how)} from the multiview feed list (any may be missing)."""
    picked = {}
    usable = [i for i, f in enumerate(feeds or []) if isinstance(f, dict) and isinstance(f.get("url"), str) and f.get("url")]

    def channel(i):
        meta = feeds[i].get("metadata") if isinstance(feeds[i].get("metadata"), dict) else {}
        return meta.get("channel_id")

    def is_onboard(i):
        return any(v not in (None, "", 0) for _, v in find_keys(feeds[i], ("racing_number",)))

    if f1live_channel is not None:
        for i in usable:
            if str(channel(i)) == str(f1live_channel):
                picked["F1 Live"] = (i, "--f1live-channel")
    if "F1 Live" not in picked:
        for i in usable:
            txt = feed_text(feeds[i])
            if not is_onboard(i) and ("f1 live" in txt or "f1_live" in txt or "f1live" in txt):
                picked["F1 Live"] = (i, "metadata mentions F1 Live")
                break
    if onboard_channel is not None:
        for i in usable:
            if str(channel(i)) == str(onboard_channel):
                picked["onboard"] = (i, "--onboard-channel")
    if "onboard" not in picked:
        for i in usable:
            if is_onboard(i):
                picked["onboard"] = (i, "metadata has racing_number")
                break
    return picked


def fetch_live_snapshot(spec, ua):
    """One media playlist fetch for a feed spec. Appends to spec['snaps'] and returns the snapshot."""
    snap = {"error": None}
    try:
        _, text, truncated = http_get(spec["media_url"], {"User-Agent": ua}, cap=MANIFEST_CAP)
        snap["t_recv"] = utc_now()  # taken as soon as the body is in
    except HttpError as e:
        snap["error"] = str(e)
        spec["snaps"].append(snap)
        return snap
    if "#EXTM3U" not in text[:1024]:
        snap["error"] = "not an HLS playlist (no #EXTM3U)"
        spec["snaps"].append(snap)
        return snap
    parsed = parse_live_playlist(text)
    snap["parsed"] = parsed
    snap["a"] = analyse_live_playlist(parsed, snap["t_recv"])
    snap["truncated"] = truncated
    spec["keys"] |= classify_hls_keys(parse_hls(text)["keys"])
    spec["snaps"].append(snap)
    return snap


def report_snapshot(spec, n, total, snap):
    pad = "    "
    if snap["error"]:
        out("  [%s] fetch %d/%d FAILED: %s" % (spec["name"], n, total, snap["error"]))
        return
    p, a = snap["parsed"], snap["a"]
    out("  [%s] fetch %d/%d at %s (local UTC)" % (spec["name"], n, total, snap["t_recv"].strftime("%H:%M:%S")))
    out(pad + "segments=%d  #EXT-X-MEDIA-SEQUENCE=%s  ENDLIST=%s  #EXT-X-PLAYLIST-TYPE=%s" % (
        p["segments"], p["media_sequence"] if p["media_sequence"] is not None else "(absent)",
        "PRESENT" if p["endlist"] else "absent",
        p["playlist_type"] if p["playlist_type"] is not None else "(absent)"))
    if p["pdt_raw"]:
        out(pad + "first PDT = %s   last PDT = %s   (%d PDT tags)" % (p["pdt_raw"][0], p["pdt_raw"][-1], len(p["pdt_raw"])))
    else:
        out(pad + "no #EXT-X-PROGRAM-DATE-TIME tags")
    if a["delay"] is None:
        out(pad + "live edge delay: n/a (no usable PROGRAM-DATE-TIME)")
        return
    out(pad + "last segment %.3f s%s   live edge delay = %s   rewind (first->last PDT) = %.1f s (%.1f s to the live edge)" % (
        a["last_dur"], " (start derived, not tagged)" if a["last_derived"] else "",
        fmt_s(a["delay"]), a["rewind"], a["rewind_full"]))
    if p["discontinuities"]:
        out(pad + "note: %d #EXT-X-DISCONTINUITY tag(s) in this window" % p["discontinuities"])
    if snap.get("truncated"):
        out(pad + "note: playlist truncated at 2 MB")


def live_poll(specs, ua, rounds=LIVE_ROUNDS, interval=LIVE_INTERVAL_S):
    """Fetches every feed's media playlist once per round, `interval` seconds between rounds."""
    for r in range(rounds):
        if r:
            out("  ... waiting %d s ..." % interval)
            time.sleep(interval)
        for spec in specs:
            if spec.get("media_url"):
                snap = fetch_live_snapshot(spec, ua)
                report_snapshot(spec, r + 1, rounds, snap)


def _median(vals):
    v = sorted(vals)
    n = len(v)
    return None if not n else (v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2.0)


def live_summary(specs, drm_hints=None):
    """Prints the closing block. Returns a dict of the headline answers (for tests)."""
    out("")
    out("== LIVE SUMMARY ==")
    res = {"delay": {}, "rewind": {}, "in_step": None, "drm": None}
    out("  Live edge delay (this Mac's UTC now - (last PDT + that segment's duration)):")
    for spec in specs:
        good = [s for s in spec["snaps"] if not s["error"] and s["a"]["delay"] is not None]
        if not spec.get("media_url"):
            out("    %-10s not measured (%s)" % (spec["name"], spec.get("note", "no playlist")))
            continue
        if not good:
            out("    %-10s not measured (no usable fetch)" % spec["name"])
            continue
        ds = [s["a"]["delay"] for s in good]
        res["delay"][spec["name"]] = _median(ds)
        out("    %-10s median %s   range %s to %s   over %d fetch(es): %s" % (
            spec["name"], fmt_s(_median(ds)), fmt_s(min(ds)), fmt_s(max(ds)), len(ds),
            ", ".join("%.1f" % d for d in ds)))
    out("  Rewind window (first -> last PDT in the playlist):")
    for spec in specs:
        good = [s for s in spec["snaps"] if not s["error"] and s["a"]["rewind"] is not None]
        if not good:
            out("    %-10s n/a" % spec["name"])
            continue
        rw = [s["a"]["rewind"] for s in good]
        res["rewind"][spec["name"]] = rw[-1]
        out("    %-10s %.0f s (%.1f min) at the last fetch; range %.0f to %.0f s; segments listed %d" % (
            spec["name"], rw[-1], rw[-1] / 60.0, min(rw), max(rw), good[-1]["parsed"]["segments"]))

    # Feeds in step: compare the last segment start of every feed, round by round.
    rounds = max((len(s["snaps"]) for s in specs), default=0)
    spreads, exact = [], 0
    tol = 0.0
    for r in range(rounds):
        lasts = []
        for spec in specs:
            if r < len(spec["snaps"]) and not spec["snaps"][r]["error"] and spec["snaps"][r]["a"]["last_start"] is not None:
                lasts.append(spec["snaps"][r]["a"]["last_start"])
                tol = max(tol, spec["snaps"][r]["a"]["last_dur"] or 0.0)
        if len(lasts) >= 2:
            sp = (max(lasts) - min(lasts)).total_seconds()
            spreads.append(sp)
            if sp == 0:
                exact += 1
    if spreads:
        res["in_step"] = max(spreads) <= tol
        out("  Last PDT per round, spread between feeds (s): %s" % ", ".join("%.3f" % s for s in spreads))
        out("  Feeds in step: %s   (yes = last PDTs within one segment, %.1f s, in every round; identical in %d of %d rounds)" % (
            "YES" if res["in_step"] else "NO", tol, exact, len(spreads)))
    else:
        out("  Feeds in step: unknown (fewer than two feeds had usable PROGRAM-DATE-TIME)")

    # Live, advancing.
    for spec in specs:
        seqs = [s["parsed"]["media_sequence"] for s in spec["snaps"] if not s["error"] and s["parsed"]["media_sequence"] is not None]
        ended = any(s["parsed"]["endlist"] for s in spec["snaps"] if not s["error"])
        if seqs:
            out("    %-10s media sequence %s -> %s (%s), ENDLIST %s" % (
                spec["name"], seqs[0], seqs[-1], "advancing" if seqs[-1] > seqs[0] else "NOT advancing",
                "seen" if ended else "never seen"))

    # DRM
    fetched = [s for s in specs if any(not x["error"] for x in s["snaps"])]
    found = set()
    for s in fetched:
        found |= s["keys"]
    drm_found = found & {"fairplay", "widevine", "playready", "other"}
    hints = drm_hints or {}
    if not fetched:
        res["drm"] = None
        out("  DRM: unknown (no playlist was fetched)")
    else:
        res["drm"] = bool(drm_found)
        extra = ""
        if hints:
            extra = "; play response drmType=%s laURL=%s" % (hints.get("drmType") or "(none)", "present" if hints.get("laURL") else "absent")
        if drm_found:
            out("  DRM: YES (%s key tags seen)%s" % (", ".join(sorted(drm_found)), extra))
        elif "aes128" in found:
            out("  DRM: NO (only AES-128 clear-key tags seen)%s" % extra)
        else:
            out("  DRM: NO (no #EXT-X-KEY / session key tags in the master or media playlists of %d feed(s))%s" % (len(fetched), extra))
    out("  (The delay figure includes any error in this Mac's clock; keep Date & Time on automatic.)")
    return res


def run_live_section(single, multi, ua, f1live_channel, onboard_channel, box):
    """single/multi: run_variant() results for the WEB_DASH single-feed and multiview requests."""
    out("")
    out("== 5. LIVE EDGE: media playlists, %d fetches %d s apart ==" % (LIVE_ROUNDS, LIVE_INTERVAL_S))
    specs = []
    drm_hints = {}
    for r in (single, multi):
        if r and r.get("_drm_hint"):
            h = r["_drm_hint"]
            drm_hints = {"drmType": drm_hints.get("drmType") or h["drmType"], "laURL": drm_hints.get("laURL") or h["laURL"]}

    world_url = single.get("_stream_url") if single else None
    candidates = [("World feed", world_url, "single-feed play response url")]
    feeds = multi.get("_feeds") if multi else None
    picked = pick_live_feeds(feeds, f1live_channel, onboard_channel) if feeds else {}
    for name in ("F1 Live", "onboard"):
        if name in picked:
            i, how = picked[name]
            meta = feeds[i].get("metadata") if isinstance(feeds[i].get("metadata"), dict) else {}
            candidates.append(("F1 Live" if name == "F1 Live" else "Onboard",
                               feeds[i]["url"], "multiview feed #%d of %d, channel_id=%s (%s)" % (i + 1, len(feeds), meta.get("channel_id"), how)))
        else:
            candidates.append(("F1 Live" if name == "F1 Live" else "Onboard", None,
                               "not identified in the multiview feed list (try --%s-channel <channel_id>)" % ("f1live" if name == "F1 Live" else "onboard")))
    if feeds:
        out("  Multiview feeds available: %d" % len(feeds))
    for name, url, note in candidates:
        spec = {"name": name, "media_url": None, "keys": set(), "snaps": [], "note": note}
        if url:
            record_private_url("LIVE %s master" % name, url)
            media_url, keys, how = resolve_media_playlist(url, ua)
            spec["keys"] |= keys
            spec["media_url"] = media_url
            spec["note"] = note if media_url else "%s; %s" % (note, how)
            out("  %-10s %s -> %s" % (name, note, ("polling the " + how) if media_url else how))
        else:
            out("  %-10s %s" % (name, note))
        specs.append(spec)
    box["state"] = (specs, drm_hints)  # so a Ctrl+C mid-poll still gets a summary of what was fetched
    if not any(s["media_url"] for s in specs):
        out("  No feed playlist could be resolved: nothing to poll.")
    else:
        out("")
        live_poll(specs, ua)
    return specs, drm_hints


# --- Fixture recording (--dump-catalogue) ------------------------------------------------------

import unicodedata
import zipfile

FIXTURE_CONTENT_ID = 1000010431   # 2026 Sao Paulo race
FIXTURE_ONBOARD_CHANNEL = 1016    # its first onboard
FIXTURE_MISSING_ID = 1000009999
FIXTURE_HOME_PAGE = 395
FIXTURE_LIST_LIMIT = 6
FIXTURE_GAP_S = 2
FIXTURE_NAMES = [
    "config", "location", "home", "livenow", "calendar-2026", "weekend-saopaulo", "archive-races",
    "season-1998", "video-1000010431-WEB_HLS", "video-1000010431-WEB_DASH", "play-1000010431-WEB_HLS",
    "play-1000010431-onboard-WEB_HLS", "play-1000010431-iosheader-WEB_HLS", "play-1000009999-WEB_HLS",
]
SENSITIVE_KEY = re.compile(r"token|ascendon|subscriber|email|password|cookie", re.I)
URL_KEY = re.compile(r"^(url|laurl)$", re.I)
REMOVED = "<removed>"
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def sanitize(obj):
    """Returns a sanitised copy: sensitive keys removed, URL strings masked (mask_url via scrub),
    known tokens, JWTs and long blobs masked, and every list cut to its first 6 items."""
    if isinstance(obj, dict):
        return {k: (REMOVED if SENSITIVE_KEY.search(str(k)) else sanitize(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize(v) for v in obj[:FIXTURE_LIST_LIMIT]]
    if isinstance(obj, str):
        return EMAIL_RE.sub(REMOVED, scrub(obj))
    return obj


def remove_urls(obj):
    """Copy with every `url` / `laURL` value replaced (play responses: signed stream links)."""
    if isinstance(obj, dict):
        return {k: (REMOVED if URL_KEY.match(str(k)) and isinstance(v, str) else remove_urls(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [remove_urls(v) for v in obj]
    return obj


def sanitize_location(loc):
    """Only entitlement (the tier), groupId and the country codes of userLocation[0]."""
    keep = {}
    if isinstance(loc, dict):
        for k, v in loc.items():
            if k in ("entitlement", "groupId") or "country" in str(k).lower():
                keep[k] = sanitize(v)
    return {"resultObj": {"userLocation": [keep]}}


def fold(text):
    return "".join(c for c in unicodedata.normalize("NFKD", str(text)) if not unicodedata.combining(c)).lower()


def find_meeting_page_id(calendar_body, needle="paulo"):
    """PageID of the first calendar meeting whose name, circuit or country mentions the needle."""
    result = calendar_body.get("resultObj") if isinstance(calendar_body, dict) else None
    for container in (result.get("containers") if isinstance(result, dict) else None) or []:
        meta = container.get("metadata") if isinstance(container, dict) else None
        emf = meta.get("emfAttributes") if isinstance(meta, dict) else None
        if not isinstance(emf, dict):
            continue
        names = " ".join(str(emf.get(k) or "") for k in ("Meeting_Name", "Circuit_Short_Name", "Meeting_Country_Name"))
        if needle in fold(names):
            try:
                page_id = int(emf.get("PageID") or 0)
            except (TypeError, ValueError):
                page_id = 0
            if page_id > 0:
                return page_id
    return None


def url_kind(url):
    if not isinstance(url, str) or not url:
        return "absent"
    try:
        path = urllib.parse.urlsplit(url).path.lower()
    except ValueError:
        return "other"
    return "m3u8" if path.endswith(".m3u8") else ("mpd" if path.endswith(".mpd") else "other")


def search_path(params):
    return "PAGE/SEARCH/VOD/{tier}/{group}?" + urllib.parse.urlencode(params)  # Java URLEncoder style


def dump_catalogue(token, base_dir=None):
    """Records the sanitised responses named in FIXTURE_NAMES into <base_dir>/fixtures and zips them
    to <base_dir>/fixtures.zip. A failed request is recorded as an error file; the run goes on."""
    base_dir = base_dir or os.path.dirname(os.path.abspath(__file__))
    fx_dir = os.path.join(base_dir, "fixtures")
    os.makedirs(fx_dir, exist_ok=True)
    written = []
    sessions = {}   # platform -> (entitlement, tier, groupId) or the HttpError that stopped it
    raw_location = {}
    versions = {"play": "3.0", "video": "4.0"}

    def save(name, doc):
        with open(os.path.join(fx_dir, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1, ensure_ascii=False)
            f.write("\n")
        written.append(name)
        out("  %s.json %s" % (name, "ERROR %s" % doc["error"] if isinstance(doc, dict) and "error" in doc else "ok"))

    def record(name, fn):
        try:
            doc = fn()
        except HttpError as e:
            doc = {"error": e.status, "body": scrub(e.body or str(e))[:600]}
        except Exception as e:  # one bad request must never stop the run
            doc = {"error": type(e).__name__, "body": scrub(str(e))[:600]}
        save(name, doc)

    def session(platform):
        if platform not in sessions:
            try:
                sessions[platform] = sign_in(token, platform, SAFARI_UA, False,
                                             raw_location if platform == "WEB_HLS" else None)
            except HttpError as e:
                sessions[platform] = e
        got = sessions[platform]
        if isinstance(got, HttpError):
            raise HttpError(got.status, got.body, "sign-in on %s failed: %s" % (platform, got))
        return got

    def catalogue(path, platform="WEB_HLS", version="2.0", with_entitlement=False):
        def run():
            ent, tier, group = session(platform)
            headers = {"entitlementtoken": ent} if with_entitlement else None
            _, body = f1_get(api_url(version, platform, path.format(tier=tier, group=group)), SAFARI_UA, headers)
            return sanitize(body)
        return run

    def play(content_id, platform="WEB_HLS", channel_id=None, device=None):
        def run():
            ent, tier, _ = session(platform)
            query = "contentId=%d&player=player_bm" % content_id
            if channel_id is not None:
                query += "&channelId=%d" % channel_id
            multiview = tier in MULTIVIEW_TIERS
            info = device(multiview) if device else safari_device_info(multiview)
            headers = {"ascendontoken": token, "entitlementtoken": ent, "x-f1-device-info": info}
            _, body = f1_get(api_url(versions["play"], platform, "CONTENT/PLAY") + "?" + query, SAFARI_UA, headers)
            result = body.get("resultObj") if isinstance(body, dict) else None
            result = result if isinstance(result, dict) else {}
            doc = sanitize(remove_urls(body))
            if not isinstance(doc, dict):
                doc = {"_body": doc}
            doc["_url_kind"] = url_kind(result.get("url"))
            doc["_has_laURL"] = bool(result.get("laURL"))
            return doc
        return run

    def ios_device(multiview):
        return device_info("ios", "safari", "27", "27.2", multiview)

    out("== Recording fixtures into spike/fixtures (sanitised) ==")

    def config():
        _, cfg = f1_get(BASE + "/config", SAFARI_UA)
        api = cfg.get("apiConfig") if isinstance(cfg, dict) else None
        if isinstance(api, dict):
            for key, field in (("play", "playAPIVersion"), ("video", "videoAPIVersion")):
                v = str(api.get(field, "")).strip()
                if API_VERSION.match(v):
                    versions[key] = v
        return sanitize(cfg)
    record("config", config)

    def location():
        session("WEB_HLS")
        return sanitize_location(raw_location.get("location"))
    record("location", location)

    record("home", catalogue("PAGE/%d/{tier}/{group}" % FIXTURE_HOME_PAGE))
    record("livenow", catalogue("EVENTS/LIVENOW/{tier}/{group}", version="1.0"))

    calendar_params = [("orderBy", "meeting_End_Date"), ("sortOrder", "asc"), ("filter_objectSubtype", "Meeting"),
                       ("filter_season", "2026"), ("filter_orderByFom", "Y"), ("maxResults", "100")]
    calendar_raw = {}

    def calendar():
        ent, tier, group = session("WEB_HLS")
        _, body = f1_get(api_url("2.0", "WEB_HLS", search_path(calendar_params).format(tier=tier, group=group)), SAFARI_UA)
        calendar_raw["body"] = body  # unsanitised, in memory only: the weekend's page id is read from it
        return sanitize(body)
    record("calendar-2026", calendar)

    def weekend():
        page_id = find_meeting_page_id(calendar_raw.get("body"))
        if page_id is None:
            raise HttpError("not_found", "", "no Sao Paulo meeting with a PageID in the 2026 calendar response")
        return catalogue("PAGE/%d/{tier}/{group}" % page_id)()
    record("weekend-saopaulo", weekend)

    record("archive-races", catalogue(search_path([
        ("filter_Series", "Formula 1"), ("filter_genres", "Full Race,Race"), ("filter_objectSubtype", "Replay"),
        ("filter_objectType", "Video"), ("orderBy", "shortPeriod"), ("sortOrder", "desc"), ("maxResults", "100")])))
    record("season-1998", catalogue(search_path([("filter_season", "1998"), ("maxResults", "100")])))

    for platform in ("WEB_HLS", "WEB_DASH"):
        record("video-%d-%s" % (FIXTURE_CONTENT_ID, platform),
               catalogue("CONTENT/VIDEO/%d/{tier}/{group}" % FIXTURE_CONTENT_ID, platform,
                         versions["video"], with_entitlement=True))

    plays = [
        ("play-%d-WEB_HLS" % FIXTURE_CONTENT_ID, play(FIXTURE_CONTENT_ID)),
        ("play-%d-onboard-WEB_HLS" % FIXTURE_CONTENT_ID, play(FIXTURE_CONTENT_ID, channel_id=FIXTURE_ONBOARD_CHANNEL)),
        ("play-%d-iosheader-WEB_HLS" % FIXTURE_CONTENT_ID, play(FIXTURE_CONTENT_ID, device=ios_device)),
        ("play-%d-WEB_HLS" % FIXTURE_MISSING_ID, play(FIXTURE_MISSING_ID)),
    ]
    for i, (name, fn) in enumerate(plays):
        if i:
            time.sleep(FIXTURE_GAP_S)
        record(name, fn)

    zip_path = os.path.join(base_dir, "fixtures.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in written:
            z.write(os.path.join(fx_dir, name + ".json"), name + ".json")
    out("Wrote %d files and fixtures.zip (%d bytes)." % (len(written), os.path.getsize(zip_path)))
    return written


# --- Main ------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Throwaway spike: ask F1 TV for one replay on several platform strings and "
                    "report whether a FairPlay HLS stream is offered. Reads JSON and manifest text only.",
        usage="python3 stream_check.py [--live] [--save-urls] <F1 TV page URL or numeric contentId>\n"
              "       python3 stream_check.py --dump-catalogue")
    parser.add_argument("content", nargs="?",
                        help="e.g. https://f1tv.formula1.com/detail/1000009999/some-title or 1000009999 "
                             "(not needed with --dump-catalogue)")
    parser.add_argument("--dump-catalogue", action="store_true",
                        help="record sanitised F1 TV responses as JSON fixtures in fixtures/ (zipped to "
                             "fixtures.zip) next to this script, for the app's parser tests. Fixed requests; "
                             "no contentId needed.")
    parser.add_argument("--save-urls", action="store_true",
                        help="also write the UNMASKED signed stream URLs to stream_urls_PRIVATE.txt next to "
                             "this script, for a local playback test. Never printed, never in the result file; "
                             "do not share it.")
    parser.add_argument("--live", action="store_true",
                        help="live-session mode: WEB_DASH single-feed + multiview play requests, then poll the "
                             "world feed, F1 Live and one onboard's media playlist 4 times, 15 s apart, and "
                             "report live edge delay, rewind window, feeds in step and DRM.")
    parser.add_argument("--f1live-channel", metavar="CHANNEL_ID",
                        help="--live: the multiview channel_id to use as F1 Live, if it isn't recognised by name")
    parser.add_argument("--onboard-channel", metavar="CHANNEL_ID",
                        help="--live: the multiview channel_id to use as the onboard, if none is recognised")
    args = parser.parse_args()

    content_id = None
    if not args.dump_catalogue:
        if not args.content:
            parser.error("a contentId or F1 TV page URL is required (or use --dump-catalogue)")
        content_id = extract_content_id(args.content)
        if content_id is None:
            parser.error("couldn't find a contentId in %r" % args.content)

    # The cookie is longer than the 1024 characters a macOS terminal accepts on one typed
    # line, so the normal way in is the clipboard:  pbpaste | python3 stream_check.py <url>
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
    else:
        print("Paste your F1 TV login-session cookie value (or a bare subscription token).")
        print("Input is hidden and is not stored or printed.")
        print("(If the terminal beeps or flashes, the value is too long to paste: press Ctrl+C,")
        print(" copy the cookie, and run:  pbpaste | python3 stream_check.py <url>)")
        try:
            raw = getpass.getpass("login-session / token: ")
        except (EOFError, KeyboardInterrupt):
            print("\nCancelled.")
            return 1
    try:
        token, kind = decode_signin(raw)
    except ValueError as e:
        print("Error: %s" % e)
        return 1
    add_secret(token)
    add_secret(raw.strip())

    if args.dump_catalogue:
        try:
            dump_catalogue(token)
        except KeyboardInterrupt:
            out("Interrupted.")
            return 1
        print("fixtures.zip holds sanitised responses only; it is git-ignored. Send it back, do not post it elsewhere.")
        return 0

    out("F1 TV stream check (throwaway spike for the iOS-port assessment)%s" % ("  [LIVE MODE]" if args.live else ""))
    out("This output is SAFE TO SHARE: subscription/entitlement tokens and URL query strings are masked.")
    out("No video is downloaded and no licence/key request is made.")
    out("Date: %s   Python: %s   contentId: %d   sign-in given as: %s" % (
        time.strftime("%Y-%m-%d %H:%M:%S %Z"), sys.version.split()[0], content_id, kind))
    out("")

    results = []
    live_box = {}  # --live: {"state": (feed specs, DRM hints)}; the summary prints at the very end
    try:
        play_v = step_config()
        out("")
        out("== 2. ENTITLEMENT + LOCATION (WEB_DASH, as the app signs in by default) ==")
        try:
            _, tier, group = sign_in(token, "WEB_DASH", ANDROID_UA, verbose=True)
            out("  Tier: %s, groupId: %s%s" % (tier, group,
                "  <- REG/ANONYMOUS usually means the plan has no video" if tier in ("REG", "ANONYMOUS") else ""))
        except HttpError as e:
            print_http_error(e)
            if e.status in (401, 403):
                out("  The sign-in itself was refused; the play requests below will most likely fail too.")
        if args.live:
            live_variants = [(VARIANTS[0], "player_bm"), (MULTIVIEW_VARIANTS[0], "player_tm")]
            out("")
            out("== 3. CONTENT/PLAY, WEB_DASH request style: single feed, then multiview ==")
            for i, ((label, platform, ua, devinfo), player) in enumerate(live_variants):
                if i:
                    time.sleep(2)
                try:
                    results.append(run_variant(label, platform, ua, devinfo, token, content_id, play_v, player))
                except Exception as e:
                    out("  Unexpected error in this variant: %s: %s" % (type(e).__name__, e))
                    results.append({"label": label, "verdict": "refused", "detail": "script error"})
            try:
                run_live_section(results[0], results[1] if len(results) > 1 else None,
                                 ANDROID_UA, args.f1live_channel, args.onboard_channel, live_box)
            except Exception as e:
                out("  Unexpected error in the live section: %s: %s" % (type(e).__name__, e))
        else:
            out("")
            out("== 3. CONTENT/PLAY per variant (player=player_bm, no channelId) ==")
        for i, (label, platform, ua, devinfo) in enumerate([] if args.live else VARIANTS):
            if i:
                time.sleep(2)
            try:
                results.append(run_variant(label, platform, ua, devinfo, token, content_id, play_v))
            except Exception as e:  # one variant must never stop the others
                out("  Unexpected error in this variant: %s: %s" % (type(e).__name__, e))
                results.append({"label": label, "verdict": "refused", "detail": "script error"})
        if not args.live:
            out("")
            out("== 4. CONTENT/PLAY multiview (player=player_tm) ==")
        for label, platform, ua, devinfo in ([] if args.live else MULTIVIEW_VARIANTS):
            time.sleep(2)
            try:
                results.append(run_variant(label, platform, ua, devinfo, token, content_id, play_v, "player_tm"))
            except Exception as e:
                out("  Unexpected error in this variant: %s: %s" % (type(e).__name__, e))
                results.append({"label": label, "verdict": "refused", "detail": "script error"})
    except KeyboardInterrupt:
        out("")
        out("Interrupted.")

    out("")
    out("== Verdict ==" if not args.live else "== Play request results (live mode) ==")
    for r in results:
        out("  %-48s %s  (%s)" % (r["label"], r["verdict"], r["detail"]))
        out("      sync clock: %s" % sync_clock_text(r.get("sync", [])))
    fp =[r["label"] for r in results if r["verdict"] == "FairPlay offered"]
    plain = [r["label"] for r in results if r["verdict"] == "unprotected"]
    if fp:
        overall = "FairPlay IS offered on: %s. An AVPlayer-based iOS port looks feasible with that platform string." % "; ".join(fp)
    elif plain:
        overall = ("No FairPlay, but unprotected/clear-key HLS on: %s, which AVPlayer can play without FairPlay."
                   % "; ".join(plain))
    elif results and all("network" in r["detail"] for r in results):
        overall = "Couldn't reach F1 TV at all (network errors): nothing was tested. Check the connection/VPN and run again."
    elif results and all(r["verdict"] == "refused" for r in results):
        overall = "Every variant was refused: check the sign-in and that the plan includes video, then run again."
    elif results:
        overall = "No FairPlay offered on any variant tested: F1 TV gave us only Widevine (or nothing). An AVPlayer iOS port is blocked."
    else:
        overall = "No variants completed."
    out("  OVERALL: " + overall)
    all_sync = [flag for r in results for flag in r.get("sync", [])]
    if not all_sync:
        out("  OVERALL sync clock: unknown (no HLS media playlist was inspected)")
    elif all(all_sync):
        out("  OVERALL sync clock: all %d inspected media playlists/feeds carried #EXT-X-PROGRAM-DATE-TIME" % len(all_sync))
    else:
        out("  OVERALL sync clock: NOT all inspected media playlists/feeds carried #EXT-X-PROGRAM-DATE-TIME "
            "(%d of %d did)" % (sum(1 for f in all_sync if f), len(all_sync)))

    if args.live:
        if live_box.get("state"):
            live_summary(*live_box["state"])
        else:
            out("")
            out("== LIVE SUMMARY ==")
            out("  Not available: the live polling did not run (see the errors above).")

    path = write_result_file("stream_check_live_result.txt" if args.live else "stream_check_result.txt")
    if path:
        msg = "The same output was saved to %s - please paste that file back." % path
        print("")
        print(msg)
    if args.save_urls:
        ppath = write_private_file() if PRIVATE_URLS else None
        print("")
        if ppath:
            print("PRIVATE test links (%d, signed, tied to your account, expire soon) were saved to %s" % (
                len(PRIVATE_URLS), ppath))
            print("Do NOT share that file; it is not part of the result file. To test playback: open the "
                  "FIRST URL in it in Safari on this Mac (Safari plays HLS natively; an .mpd URL is DASH "
                  "and will not play there).")
        else:
            print("--save-urls: no stream URLs were captured, so no private file was written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
