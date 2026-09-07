"""Resolve supported live-room pages to short-lived media URLs.

The script has one machine-readable JSON object on stdout.  It never prints
cookies, authorization headers, or signed stream URLs in error details.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin, urlsplit, urlunsplit

import requests
import streamlink
from streamlink import Streamlink
from streamlink.exceptions import NoPluginError, NoStreamsError, PluginError


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/132.0.0.0 Safari/537.36"
)
ALLOWED_HEADERS = {"user-agent", "referer", "origin"}
KINDS = {
    "douyin-live", "douyin-share", "bilibili-live",
    "douyu-live", "huya-live",
}
DOUYIN_REDIRECT_HOSTS = {
    "v.douyin.com",
    "live.douyin.com",
    "douyin.com",
    "www.douyin.com",
    "www.iesdouyin.com",
}


def emit(payload: dict[str, Any]) -> int:
    # Keep the machine-readable boundary deterministic on Windows.  The
    # embeddable runtime otherwise uses the active ANSI code page, but mpv
    # consumes captured subprocess output as UTF-8.
    output = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    sys.stdout.buffer.write(output.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0 if payload.get("ok") else 2


def clean_text(value: Any, limit: int = 240) -> str | None:
    if value is None:
        return None
    value = " ".join(str(value).replace("\x00", "").split())
    return value[:limit] or None


def sanitize_detail(value: Any) -> str:
    text = clean_text(value, 600) or ""
    text = re.sub(
        r"(?i)(cookie|authorization|token|sign|auth|session|sessdata)\s*[:=]\s*[^\s,;]+",
        r"\1=<redacted>",
        text,
    )
    text = re.sub(r"https?://[^\s\]\[\"']+", redact_url_match, text)
    return text[:600]


def redact_url_match(match: re.Match[str]) -> str:
    try:
        parts = urlsplit(match.group(0))
        return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    except ValueError:
        return "<redacted-url>"


def douyu_room_from_page(body: str) -> tuple[str | None, str | None]:
    """Read the actual player room, never a recommendation elsewhere in the page."""
    room_ids: set[str] = set()

    class PlayerParser(HTMLParser):
        def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
            values = dict(attrs)
            classes = (values.get("class") or "").split()
            if any(name == "playerWrap" or name.startswith("playerWrap__") for name in classes):
                room = values.get("data-room-id") or ""
                if re.fullmatch(r"[1-9][0-9]{0,11}", room):
                    room_ids.add(room)

    PlayerParser().feed(body)
    # Both are assignments to the current page's player, not generic room_id keys.
    for pattern in [r"\$ROOM\.room_id\s*=\s*['\"]?([1-9][0-9]{0,11})\b",
                    r"getLegacyFirstStream\(\s*\{\s*roomID\s*:\s*([1-9][0-9]{0,11})\b"]:
        room_ids.update(re.findall(pattern, body))
    if len(room_ids) != 1:
        return None, None
    title = re.search(r"<title>(.*?)</title>", body, re.I | re.S)
    return next(iter(room_ids)), clean_text(html.unescape(title[1]).split("_", 1)[0]) if title else None


def canonicalize(url: str, kind: str) -> tuple[str | None, str | None]:
    try:
        parts = urlsplit(url.strip())
        port = parts.port
    except ValueError:
        return None, "链接格式不正确"

    if parts.scheme.lower() not in {"http", "https"} or parts.username or parts.password:
        return None, "只支持普通 HTTPS/HTTP 网页链接"
    if port not in {None, 80, 443}:
        return None, "直播网页链接使用了不支持的端口"

    host = (parts.hostname or "").lower().rstrip(".")
    path = parts.path or "/"
    if kind == "douyin-live":
        if host not in {"live.douyin.com", "douyin.com"}:
            return None, "当前只支持抖音直播间链接，不支持普通抖音视频"
        room = path.strip("/").split("/", 1)[0]
        if not room or not re.fullmatch(r"[A-Za-z0-9_-]+", room):
            return None, "没有识别到有效的抖音直播间号"
        return f"https://live.douyin.com/{room}", None

    if kind == "douyin-share":
        if host not in {"v.douyin.com", "www.iesdouyin.com"}:
            return None, "当前链接不是受支持的抖音直播分享链接"
        if not path.strip("/"):
            return None, "抖音分享链接不完整"
        return urlunsplit(("https", host, path, parts.query, "")), None

    if kind == "bilibili-live":
        if host != "live.bilibili.com":
            return None, "当前链接不是 B 站直播间"
        room = path.strip("/").split("/", 1)[0]
        if not room or not re.fullmatch(r"[A-Za-z0-9_-]+", room):
            return None, "没有识别到有效的 B 站直播间号"
        return f"https://live.bilibili.com/{room}", None

    if kind == "douyu-live":
        if host not in {"douyu.com", "www.douyu.com", "m.douyu.com"}:
            return None, "当前链接不是受支持的斗鱼直播间"
        room_match = re.fullmatch(r"/(?:topic/)?(\d+)/?", path)
        if not room_match:
            return None, "没有识别到有效的斗鱼直播间号"
        return f"https://www.douyu.com/{room_match.group(1)}", None

    if kind == "huya-live":
        if host not in {"huya.com", "www.huya.com", "m.huya.com"}:
            return None, "当前链接不是受支持的虎牙直播间"
        channel = path.strip("/").split("/", 1)[0]
        reserved = {"", "l", "live", "lives", "category", "g", "m", "search"}
        if channel.lower() in reserved or not re.fullmatch(r"[A-Za-z0-9_-]+", channel):
            return None, "没有识别到有效的虎牙直播间号"
        return f"https://www.huya.com/{channel}", None

    return None, "不支持的解析类型"


def resolve_douyin_share(url: str, timeout: float) -> tuple[str | None, str | None]:
    """Follow a bounded, Douyin-only redirect chain and accept live rooms only."""
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})
    current = url

    for _ in range(6):
        try:
            response = session.get(current, allow_redirects=False, timeout=timeout)
        except requests.RequestException as exc:
            return None, sanitize_detail(exc) or "share redirect request failed"

        try:
            if 300 <= response.status_code < 400 and response.headers.get("Location"):
                target = urljoin(current, response.headers["Location"])
                parts = urlsplit(target)
                host = (parts.hostname or "").lower().rstrip(".")
                try:
                    port = parts.port
                except ValueError:
                    return None, "share redirect contained an invalid port"
                if parts.scheme.lower() not in {"http", "https"} or host not in DOUYIN_REDIRECT_HOSTS \
                        or port not in {None, 80, 443}:
                    return None, "share redirect left the Douyin allowlist"
                current = target
                continue

            parts = urlsplit(current)
            host = (parts.hostname or "").lower().rstrip(".")
            if host == "live.douyin.com":
                room = parts.path.strip("/").split("/", 1)[0]
                if re.fullmatch(r"[A-Za-z0-9_-]+", room or ""):
                    return f"https://live.douyin.com/{room}", None

            share_room = re.search(r"/share/live/([A-Za-z0-9_-]+)", parts.path)
            if share_room:
                return f"https://live.douyin.com/{share_room.group(1)}", None

            # Some share pages finish on an HTML landing page instead of a 3xx.
            # Only accept an explicit live.douyin.com room URL from that page.
            body = response.text[:1_000_000]
            live_match = re.search(r"https?://live\.douyin\.com/([A-Za-z0-9_-]+)", body)
            if live_match:
                return f"https://live.douyin.com/{live_match.group(1)}", None
            return None, "share target was not a live room"
        finally:
            response.close()

    return None, "too many Douyin share redirects"


def safe_headers(stream: Any, canonical_url: str) -> dict[str, str]:
    headers: dict[str, str] = {
        "User-Agent": USER_AGENT,
        "Referer": canonical_url,
    }
    host = (urlsplit(canonical_url).hostname or "").lower()
    if host.endswith("huya.com"):
        headers["Referer"] = "https://www.huya.com/"
        headers["Origin"] = "https://www.huya.com"
    elif host.endswith("douyu.com"):
        headers["Referer"] = "https://www.douyu.com/"
    args = getattr(stream, "args", None)
    source = args.get("headers") if isinstance(args, dict) else None
    if isinstance(source, dict):
        for key, value in source.items():
            if str(key).lower() in ALLOWED_HEADERS and value:
                headers[str(key)] = clean_text(value, 512) or ""
    return headers


def captured_quality_labels(response: Any, kind: str) -> dict[str, str]:
    """Read platform display names from responses Streamlink already requested."""
    labels: dict[str, str] = {}
    try:
        response_url = str(getattr(response, "url", ""))
        body = bytes(getattr(response, "content", b"")).decode("utf-8", "strict")
        if kind == "huya-live" and "huya.com/" in response_url:
            match = re.search(r'"vMultiStreamInfo"\s*:\s*(\[.*?\])', body, re.S)
            for item in json.loads(match.group(1)) if match else []:
                bitrate = int(item.get("iBitRate", 0))
                quality_id = "source" if bitrate == 0 else f"{bitrate}k"
                label = clean_text(item.get("sDisplayName"), 80)
                if label:
                    labels[quality_id] = label
        elif kind == "douyu-live" and "/lapi/live/getH5PlayV1/" in response_url:
            payload = json.loads(body)
            data = payload.get("data") if isinstance(payload, dict) else None
            for item in data.get("multirates", []) if isinstance(data, dict) else []:
                bitrate = int(item.get("bit", 0))
                quality_id = "source" if bitrate == 0 else f"{bitrate}k"
                label = clean_text(item.get("name"), 80)
                if label:
                    labels[quality_id] = label
    except (UnicodeDecodeError, ValueError, TypeError, AttributeError):
        pass
    return labels


def captured_douyin_stream_info(
    response: Any,
) -> tuple[str | None, dict[str, dict[str, Any]]]:
    """Extract Douyin origin HLS and actual quality parameters from its page."""
    quality_ids = {
        "origin": "origin",
        "uhd": "full_hd1",
        "full_hd1": "full_hd1",
        "hd": "hd1",
        "hd1": "hd1",
        "sd": "sd2",
        "sd2": "sd2",
        "ld": "sd1",
        "sd1": "sd1",
    }
    metadata: dict[str, dict[str, Any]] = {}
    metadata_scores: dict[str, tuple[int, int, int]] = {}

    def dictionary(value: Any) -> dict[str, Any]:
        if isinstance(value, dict):
            return value
        if isinstance(value, str):
            try:
                parsed = json.loads(value)
                return parsed if isinstance(parsed, dict) else {}
            except (ValueError, TypeError):
                return {}
        return {}

    def bounded_number(value: Any, maximum: float) -> float | None:
        number = float(value)
        return number if 0 < number <= maximum else None

    def normalized_resolution(*values: Any) -> str | None:
        for value in values:
            resolution = clean_text(value, 32)
            if resolution and re.fullmatch(r"\d{2,5}[xX×]\d{2,5}", resolution):
                return resolution.lower().replace("x", "×")
        return None

    try:
        response_url = str(getattr(response, "url", ""))
        if "live.douyin.com/" not in response_url:
            return None, metadata
        body = bytes(getattr(response, "content", b"")).decode("utf-8", "strict")
        matches = re.findall(
            r'self\.__pace_f\.push\(\[\d+,("\w+:.+?")]\)</script>',
            body,
        )
        for encoded in reversed(matches):
            if "state" not in encoded or "streamStore" not in encoded:
                continue
            outer = json.loads(encoded)
            nodes = json.loads(re.sub(r"^\w+:", "", outer))
            for node in nodes if isinstance(nodes, list) else []:
                state = node.get("state") if isinstance(node, dict) else None
                room = ((((state or {}).get("roomStore") or {}).get("roomInfo") or {}).get("room") or {})
                if room.get("status") != 2:
                    continue
                stream_url = room.get("stream_url") or {}
                origin = stream_url.get("hls_pull_url")
                if not isinstance(origin, str) or not origin.startswith(("https://", "http://")):
                    continue
                parts = urlsplit(origin)
                if parts.username or parts.password or not parts.hostname:
                    continue
                # Douyin can omit a top-tier resolution in room.stream_url
                # while publishing the same sdk_key with complete metadata in
                # room.web_stream_url. Merge only identical sdk tiers. The
                # primary stream keeps its codec/fps/bitrate; the web stream
                # may only fill fields which are genuinely absent.
                stream_sources = [(1, stream_url)]
                web_stream_url = dictionary(room.get("web_stream_url"))
                if web_stream_url:
                    stream_sources.append((0, web_stream_url))

                for source_priority, source_stream in stream_sources:
                    sdk_data = dictionary(source_stream.get("live_core_sdk_data"))
                    pull_data = dictionary(sdk_data.get("pull_data"))
                    options = dictionary(pull_data.get("options"))
                    qualities = options.get("qualities")
                    for item in qualities if isinstance(qualities, list) else []:
                        if not isinstance(item, dict):
                            continue
                        sdk_key = (clean_text(item.get("sdk_key"), 32) or "").lower()
                        quality_id = quality_ids.get(sdk_key)
                        if not quality_id:
                            continue

                        details: dict[str, Any] = {}
                        display_name = clean_text(item.get("name"), 32)
                        if display_name:
                            details["name"] = display_name
                        resolution = normalized_resolution(item.get("resolution"))
                        if resolution:
                            details["resolution"] = resolution
                        try:
                            fps = bounded_number(item.get("fps"), 240)
                            if fps is not None:
                                details["fps"] = fps
                        except (TypeError, ValueError):
                            pass
                        try:
                            bitrate = bounded_number(item.get("v_bit_rate"), 1_000_000_000)
                            if bitrate is not None:
                                details["bitrate"] = int(bitrate)
                        except (TypeError, ValueError):
                            pass
                        codec = (clean_text(item.get("v_codec"), 24) or "").lower()
                        codec_names = {
                            "264": "H.264", "h264": "H.264", "avc": "H.264",
                            "265": "HEVC", "h265": "HEVC", "hevc": "HEVC",
                        }
                        if codec:
                            details["codec"] = codec_names.get(codec, codec.upper())
                        try:
                            level = int(item.get("level", 0))
                        except (TypeError, ValueError):
                            level = 0
                        score = (
                            source_priority,
                            sum(key in details for key in ("resolution", "fps", "bitrate")),
                            level,
                        )
                        existing = metadata.get(quality_id, {})
                        if score > metadata_scores.get(quality_id, (-1, -1, -1)):
                            merged = dict(existing)
                            merged.update(details)
                            metadata[quality_id] = merged
                            metadata_scores[quality_id] = score
                        else:
                            merged = metadata.setdefault(quality_id, {})
                            for key, value in details.items():
                                merged.setdefault(key, value)

                    # Some live rooms publish a same-tier resolution in
                    # stream_data.main/sdk_params instead of options.qualities.
                    stream_data = dictionary(pull_data.get("stream_data"))
                    stream_entries = dictionary(stream_data.get("data"))
                    for stream_key, raw_item in stream_entries.items():
                        item = dictionary(raw_item)
                        sdk_key = (clean_text(item.get("sdk_key"), 32)
                                   or clean_text(stream_key, 32) or "").lower()
                        quality_id = quality_ids.get(sdk_key)
                        if not quality_id:
                            continue
                        main = dictionary(item.get("main"))
                        sdk_params = dictionary(main.get("sdk_params"))
                        resolution = normalized_resolution(
                            item.get("resolution"), main.get("resolution"),
                            sdk_params.get("resolution"),
                        )
                        if resolution:
                            details = metadata.setdefault(quality_id, {})
                            details.setdefault("resolution", resolution)

                # Some H.264 room payloads leave the top quality's resolution
                # blank in both option lists. The same stream_url publishes
                # its actual source width/height in `extra`; this belongs only
                # to the top/origin tier and is therefore safe to merge there.
                extra = dictionary(stream_url.get("extra"))
                try:
                    width = int(extra.get("width", 0))
                    height = int(extra.get("height", 0))
                except (TypeError, ValueError):
                    width = height = 0
                if 16 <= width <= 32768 and 16 <= height <= 32768:
                    metadata.setdefault("origin", {}).setdefault(
                        "resolution", f"{width}×{height}")

                # Streamlink names Douyin's highest FLV URL FULL_HD1, while
                # the page's SDK metadata calls that exact top tier `origin`.
                # Copy only missing fields when the matching FLV key exists;
                # this is a same-tier alias, not a resolution guess.
                flv_keys = {
                    str(key).lower()
                    for key in dictionary(stream_url.get("flv_pull_url"))
                }
                if "full_hd1" in flv_keys and metadata.get("origin"):
                    full_hd = metadata.setdefault("full_hd1", {})
                    for key, value in metadata["origin"].items():
                        full_hd.setdefault(key, value)
                return origin, metadata
    except (UnicodeDecodeError, ValueError, TypeError, AttributeError):
        pass
    return None, metadata


def captured_douyin_origin(response: Any) -> str | None:
    """Compatibility wrapper for callers that only need the origin HLS URL."""
    return captured_douyin_stream_info(response)[0]


def format_bitrate(bitrate: int) -> str:
    if bitrate >= 1_000_000:
        return f"{bitrate / 1_000_000:.1f}".rstrip("0").rstrip(".") + " Mbps"
    if bitrate >= 1_000:
        return f"{bitrate / 1_000:.0f} Kbps"
    return f"{bitrate} bps"


def quality_label(
    name: str,
    kind: str,
    index: int,
    platform_labels: dict[str, str] | None = None,
    douyin_quality_params: dict[str, dict[str, Any]] | None = None,
) -> str:
    if kind == "bilibili-live":
        protocol = "FLV" if name.startswith("httpstream") else "HLS" if name.startswith("hls") else name.upper()
        suffix = "" if index == 0 else f" · 备用线路 {index}"
        return f"最高可用 · {protocol}{suffix}"
    captured = platform_labels.get(name) if platform_labels else None
    if captured:
        return captured
    if kind == "huya-live":
        if name == "source":
            return "蓝光原画 / 最高画质"
        bitrate = re.fullmatch(r"(\d+)k", name)
        if bitrate:
            kbps = int(bitrate.group(1))
            rate = f"{kbps / 1000:g} Mbps" if kbps >= 1000 else f"{kbps} Kbps"
            if kbps >= 4000:
                return f"蓝光{kbps / 1000:g}M"
            if kbps >= 2000:
                return f"超清 · {rate}"
            if kbps <= 1000:
                return f"流畅 · {rate}"
            return f"高清 · {rate}"
    if kind == "douyu-live":
        if name == "source":
            return "原画 / 最高画质"
        bitrate = re.fullmatch(r"(\d+)k", name)
        if bitrate:
            kbps = int(bitrate.group(1))
            return f"{kbps / 1000:g} Mbps" if kbps >= 1000 else f"{kbps} Kbps"
    labels = {
        "origin": "原画",
        "full_hd1": "蓝光",
        "hd1": "高清",
        "sd2": "标清",
        "sd1": "流畅",
    }
    label = labels.get(name, name.replace("_", " ").upper())
    if kind != "douyin-live":
        return label

    details = (douyin_quality_params or {}).get(name, {})
    parts = [clean_text(details.get("name"), 32) or label]
    if details.get("resolution"):
        parts.append(str(details["resolution"]))
    if details.get("fps"):
        fps = float(details["fps"])
        parts.append(f"{fps:g}fps")
    if details.get("bitrate"):
        parts.append(format_bitrate(int(details["bitrate"])))
    parts.append("HLS" if name == "origin" else "FLV")
    return " · ".join(parts)


def semantic_quality(name: str, kind: str) -> str:
    if kind == "huya-live":
        match = re.fullmatch(r"[^_]+_(source|\d+k)(?:_alt)?", name)
        if match:
            return match.group(1)
    return name


def ordered_streams(
    plugin: Any,
    streams: dict[str, Any],
    preferred_quality: str | None,
    kind: str,
) -> list[tuple[str, Any]]:
    # Exclude aliases and let the plugin's own quality weights define the
    # highest-to-lowest order. This preserves a stable quality ID for UI use.
    ranked: list[tuple[float, str, str, Any]] = []
    for name, stream in streams.items():
        if name in {"best", "worst"}:
            continue
        try:
            weight = float(plugin.stream_weight(name)[0])
        except (TypeError, ValueError):
            weight = 0.0
        ranked.append((weight, name, semantic_quality(name, kind), stream))

    ranked.sort(key=lambda item: (
        item[2] != preferred_quality if preferred_quality else False,
        -item[0], item[1],
    ))
    result: list[tuple[str, Any]] = []
    seen_objects: set[int] = set()

    if kind == "huya-live":
        groups: dict[str, list[tuple[float, str, Any]]] = {}
        group_order: list[str] = []
        for weight, name, semantic, stream in ranked:
            if semantic not in groups:
                groups[semantic] = []
                group_order.append(semantic)
            groups[semantic].append((weight, name, stream))

        # Prefer two same-quality CDN choices, then expose one primary stream
        # for each lower tier before filling remaining CDN fallbacks.
        flattened: list[tuple[str, Any]] = []
        if group_order:
            first = group_order[0]
            flattened.extend((first, item[2]) for item in groups[first][:2])
            for semantic in group_order[1:]:
                flattened.append((semantic, groups[semantic][0][2]))
            flattened.extend((first, item[2]) for item in groups[first][2:])
            for semantic in group_order[1:]:
                flattened.extend((semantic, item[2]) for item in groups[semantic][1:])
        iterable = flattened
    else:
        iterable = [(semantic, stream) for _weight, _name, semantic, stream in ranked]

    for name, stream in iterable:
        if id(stream) in seen_objects:
            continue
        seen_objects.add(id(stream))
        result.append((name, stream))

    # A plugin can expose only the aliases. Retain that unusual case without
    # losing playback, while keeping the normal menu free of a vague "best" ID.
    if not result and streams.get("best") is not None:
        result.append(("best", streams["best"]))
    return result


def resolve(
    url: str,
    kind: str,
    timeout: float,
    max_candidates: int,
    preferred_quality: str | None,
) -> dict[str, Any]:
    canonical_url, error = canonicalize(url, kind)
    if error or not canonical_url:
        return {
            "ok": False,
            "code": "unsupported_url",
            "user_message": error or "不支持的链接",
            "detail": "URL did not pass the exact live-room allowlist",
        }

    if kind == "douyin-share":
        canonical_url, redirect_error = resolve_douyin_share(canonical_url, timeout)
        if not canonical_url:
            return {
                "ok": False,
                "code": "not_a_live_share",
                "user_message": "该抖音分享链接不是直播间；当前不支持抖音普通视频",
                "detail": redirect_error or "share link did not resolve to a live room",
            }
        kind = "douyin-live"

    session = Streamlink()
    session.set_option("http-timeout", timeout)
    session.set_option("stream-timeout", max(timeout, 20.0))
    session.set_option("user-input-requester", None)
    session.http.headers.update({"User-Agent": USER_AGENT})
    page_title = None
    if kind == "douyu-live":
        # Public short room numbers can differ from the API's actual room ID.
        # The retired betard endpoint can return HTML, so use the page's player.
        try:
            page = session.http.get(canonical_url)
            room_id, page_title = douyu_room_from_page(page.text)
            if room_id:
                canonical_url = f"https://www.douyu.com/{room_id}"
        except (PluginError, requests.RequestException, ValueError):
            pass  # Keep the existing direct-room path if the page is unavailable.
    platform_labels: dict[str, str] = {}
    douyin_origin: dict[str, str] = {}
    douyin_quality_params: dict[str, dict[str, Any]] = {}
    if kind in {"douyin-live", "douyu-live", "huya-live"}:
        def capture_labels(response: Any, *args: Any, **kwargs: Any) -> Any:
            if kind == "douyin-live":
                origin, params = captured_douyin_stream_info(response)
                if origin:
                    douyin_origin["url"] = origin
                douyin_quality_params.update(params)
            else:
                platform_labels.update(captured_quality_labels(response, kind))
            return response

        session.http.hooks.setdefault("response", []).append(capture_labels)

    try:
        plugin_name, plugin_class, resolved_url = session.resolve_url(canonical_url, follow_redirect=False)
        expected = {
            "douyin-live": "douyin",
            "bilibili-live": "bilibili",
            "douyu-live": "douyu",
            "huya-live": "huya",
        }.get(kind)
        if plugin_name != expected:
            raise NoPluginError
        plugin = plugin_class(session, resolved_url)
        streams = plugin.streams()
        if not streams:
            return {
                "ok": False,
                "code": "offline_or_unavailable",
                "user_message": "直播间当前未开播，或暂时没有可用线路",
                "detail": f"{plugin_name} returned no streams",
            }

        candidates: list[dict[str, Any]] = []
        seen_urls: set[str] = set()
        quality_order = ordered_streams(plugin, streams, None, kind)
        ordered = ordered_streams(plugin, streams, preferred_quality, kind)
        origin_url = douyin_origin.get("url")
        if origin_url:
            quality_order = [("origin", None), *quality_order]
            origin_entry = ("origin", None)
            if preferred_quality and preferred_quality != "origin" and ordered:
                ordered = [ordered[0], origin_entry, *ordered[1:]]
            else:
                ordered = [origin_entry, *ordered]

        for quality, stream in ordered:
            if len(candidates) >= max_candidates:
                break
            if quality == "origin" and stream is None:
                stream_url = origin_url
                stream_type = "hls"
                stream_headers = {"User-Agent": USER_AGENT, "Referer": canonical_url}
            else:
                try:
                    stream_url = stream.to_url()
                except (TypeError, ValueError, AttributeError):
                    continue
                stream_type = clean_text(stream.shortname(), 40) or "http"
                stream_headers = safe_headers(stream, canonical_url)
            if not isinstance(stream_url, str) or not stream_url.startswith(("https://", "http://")):
                continue
            if stream_url in seen_urls:
                continue
            seen_urls.add(stream_url)
            candidates.append(
                {
                    "quality_id": clean_text(quality, 80) or "best",
                    "quality": quality_label(
                        clean_text(quality, 80) or "best", kind, len(candidates),
                        platform_labels, douyin_quality_params),
                    "type": stream_type,
                    "url": stream_url,
                    "headers": stream_headers,
                }
            )

        if not candidates:
            return {
                "ok": False,
                "code": "no_direct_stream",
                "user_message": "已找到直播间，但没有得到播放器可直接打开的线路",
                "detail": f"{plugin_name} streams were not URL-translatable",
            }

        return {
            "ok": True,
            "platform": {
                "douyin-live": "douyin",
                "bilibili-live": "bilibili",
                "douyu-live": "douyu",
                "huya-live": "huya",
            }[kind],
            "content_type": "live",
            "canonical_url": canonical_url,
            "title": clean_text(plugin.get_title()) or page_title,
            "author": clean_text(plugin.get_author()),
            "resolver": "streamlink",
            "resolver_version": streamlink.__version__,
            # Bilibili's Streamlink extractor exposes protocol/CDN fallbacks,
            # not semantic quality levels. Keep those for failover but do not
            # misrepresent them as user-selectable resolutions.
            "qualities": ([] if kind == "bilibili-live" else [
                {"id": quality, "label": quality_label(
                    quality, kind, index, platform_labels, douyin_quality_params)}
                for index, quality in enumerate(dict.fromkeys(
                    item[0] for item in quality_order
                ))
            ]),
            "candidates": candidates,
        }
    except NoPluginError as exc:
        return {
            "ok": False,
            "code": "resolver_mismatch",
            "user_message": "该链接暂时无法由内置直播解析器识别",
            "detail": sanitize_detail(exc) or "no matching Streamlink plugin",
        }
    except NoStreamsError as exc:
        return {
            "ok": False,
            "code": "offline_or_unavailable",
            "user_message": "直播间当前未开播，或暂时没有可用线路",
            "detail": sanitize_detail(exc) or "plugin reported no streams",
        }
    except (PluginError, OSError, ValueError) as exc:
        return {
            "ok": False,
            "code": "resolve_failed",
            "user_message": "直播解析失败，请检查网络后重试",
            "detail": sanitize_detail(exc) or exc.__class__.__name__,
        }
    except Exception as exc:  # Keep the player-facing process bounded and machine-readable.
        return {
            "ok": False,
            "code": "unexpected_error",
            "user_message": "直播解析器遇到异常，请稍后重试",
            "detail": sanitize_detail(exc) or exc.__class__.__name__,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--url", required=True)
    parser.add_argument("--kind", required=True, choices=sorted(KINDS))
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--max-candidates", type=int, default=4)
    parser.add_argument("--quality-id")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    timeout = min(max(args.timeout, 3.0), 30.0)
    max_candidates = min(max(args.max_candidates, 1), 6)
    return emit(resolve(args.url, args.kind, timeout, max_candidates, args.quality_id))


if __name__ == "__main__":
    raise SystemExit(main())
