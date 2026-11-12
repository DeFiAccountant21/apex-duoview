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


def write_result_file():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stream_check_result.txt")
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


def sign_in(token, platform, ua, verbose):
    """ENTITLEMENT then LOCATION, as F1TvApi.login() does. Returns (entitlement, tier, groupId)."""
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


# --- Main ------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Throwaway spike: ask F1 TV for one replay on several platform strings and "
                    "report whether a FairPlay HLS stream is offered. Reads JSON and manifest text only.",
        usage="python3 stream_check.py [--save-urls] <F1 TV page URL or numeric contentId>")
    parser.add_argument("content", help="e.g. https://f1tv.formula1.com/detail/1000009999/some-title or 1000009999")
    parser.add_argument("--save-urls", action="store_true",
                        help="also write the UNMASKED signed stream URLs to stream_urls_PRIVATE.txt next to "
                             "this script, for a local playback test. Never printed, never in the result file; "
                             "do not share it.")
    args = parser.parse_args()

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

    out("F1 TV stream check (throwaway spike for the iOS-port assessment)")
    out("This output is SAFE TO SHARE: subscription/entitlement tokens and URL query strings are masked.")
    out("No video is downloaded and no licence/key request is made.")
    out("Date: %s   Python: %s   contentId: %d   sign-in given as: %s" % (
        time.strftime("%Y-%m-%d %H:%M:%S %Z"), sys.version.split()[0], content_id, kind))
    out("")

    results = []
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
        out("")
        out("== 3. CONTENT/PLAY per variant (player=player_bm, no channelId) ==")
        for i, (label, platform, ua, devinfo) in enumerate(VARIANTS):
            if i:
                time.sleep(2)
            try:
                results.append(run_variant(label, platform, ua, devinfo, token, content_id, play_v))
            except Exception as e:  # one variant must never stop the others
                out("  Unexpected error in this variant: %s: %s" % (type(e).__name__, e))
                results.append({"label": label, "verdict": "refused", "detail": "script error"})
        out("")
        out("== 4. CONTENT/PLAY multiview (player=player_tm) ==")
        for label, platform, ua, devinfo in MULTIVIEW_VARIANTS:
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
    out("== Verdict ==")
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

    path = write_result_file()
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
