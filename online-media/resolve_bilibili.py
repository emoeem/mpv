"""Resolve an allowlisted Bilibili webpage to an mpv-friendly descriptor."""

from __future__ import annotations

import argparse
from http.cookiejar import MozillaCookieJar
import json
import os
import re
import sys
from typing import Any
from urllib.parse import urlsplit, urlunsplit
from urllib.parse import parse_qs

import requests
import yt_dlp
from yt_dlp.utils import DownloadError
from yt_dlp.version import __version__ as YT_DLP_VERSION


KINDS = {"bilibili-video", "bilibili-short", "bilibili-live"}
ALLOWED_HEADERS = {"user-agent", "referer", "origin"}
BILIBILI_HOSTS = {"bilibili.com", "www.bilibili.com", "m.bilibili.com"}
LIVE_API_ROOT = "https://api.live.bilibili.com"
BILIBILI_API_ROOT = "https://api.bilibili.com"
SMARTBOX_FNVAL = 85968
# The Smartbox API accepts a normal desktop browser UA, but some of the VVC
# CDN nodes reject that full Chrome UA for the media request itself. A short,
# stable UA is accepted by both the commercial and origin CDN paths and keeps
# the API/client identity separate from the byte-stream request.
VVC_MEDIA_USER_AGENT = "Mozilla/5.0"
LIVE_QN_LABELS = {
    30000: "杜比",
    20000: "4K",
    15000: "2K",
    10000: "原画",
    400: "蓝光",
    250: "超清",
    150: "高清",
    80: "流畅",
}


def emit(payload: dict[str, Any]) -> int:
    # The Windows embeddable runtime inherits the active ANSI code page
    # (usually GBK on Chinese systems), while mpv subprocess output is UTF-8.
    # Write bytes explicitly so titles and quality labels never depend on the
    # machine locale.
    output = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    sys.stdout.buffer.write(output.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0 if payload.get("ok") else 2


def clean_text(value: Any, limit: int = 300) -> str | None:
    if value is None:
        return None
    value = " ".join(str(value).replace("\x00", "").split())
    return value[:limit] or None


def redact_url(value: str) -> str:
    try:
        parts = urlsplit(value)
        return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    except ValueError:
        return "<redacted-url>"


def sanitize_detail(value: Any) -> str:
    text = clean_text(value, 800) or ""
    text = re.sub(
        r"(?i)(cookie|authorization|token|sign|auth|session|sessdata)\s*[:=]\s*[^\s,;]+",
        r"\1=<redacted>",
        text,
    )
    text = re.sub(r"https?://[^\s\]\[\"']+", lambda m: redact_url(m.group(0)), text)
    return text[:800]


def loopback_http_proxy(url: str) -> str | None:
    """Return a credential-free local proxy used by the current request stack.

    Bilibili VVC CDN signatures include the requesting public IP.  On Windows,
    ``requests`` also discovers WinINET proxies from the registry, while mpv's
    libcurl does not.  Passing only a loopback proxy to mpv keeps both requests
    on the same egress without exposing or inheriting remote proxy credentials.
    """
    proxies = requests.utils.get_environ_proxies(url)
    proxy = proxies.get("https") or proxies.get("http")
    if not isinstance(proxy, str) or not proxy:
        return None
    if "://" not in proxy:
        proxy = "http://" + proxy
    try:
        parts = urlsplit(proxy)
        port = parts.port
    except ValueError:
        return None
    if parts.scheme.lower() not in {"http", "https"} \
            or (parts.hostname or "").lower() not in {"127.0.0.1", "localhost", "::1"} \
            or parts.username or parts.password or port is None:
        return None
    host = f"[{parts.hostname}]" if ":" in (parts.hostname or "") else parts.hostname
    return f"{parts.scheme.lower()}://{host}:{port}"


def validate_url(url: str, kind: str) -> tuple[str | None, str | None]:
    try:
        parts = urlsplit(url.strip())
        port = parts.port
    except ValueError:
        return None, "链接格式不正确"
    if parts.scheme.lower() not in {"http", "https"} or parts.username or parts.password:
        return None, "只支持普通 HTTPS/HTTP 网页链接"
    if port not in {None, 80, 443}:
        return None, "B站网页链接使用了不支持的端口"

    host = (parts.hostname or "").lower().rstrip(".")
    path = parts.path or "/"
    if kind == "bilibili-short":
        if host != "b23.tv" or path == "/":
            return None, "当前链接不是有效的 b23.tv 短链接"
    elif kind == "bilibili-live":
        if host != "live.bilibili.com" or not re.match(r"^/[A-Za-z0-9_-]+/?", path):
            return None, "当前链接不是有效的 B 站直播间"
    else:
        is_video = bool(re.match(r"^/video/(?:[Bb][Vv][A-Za-z0-9]+|[Aa][Vv]\d+)", path))
        is_bangumi = bool(re.match(r"^/bangumi/play/(?:ep|ss|md)\d+", path, re.IGNORECASE))
        if host not in BILIBILI_HOSTS or not (is_video or is_bangumi):
            return None, "当前链接不是受支持的 B 站视频页面"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, parts.query, "")), None


def safe_headers(*sources: Any) -> dict[str, str]:
    result: dict[str, str] = {}
    for source in sources:
        if not isinstance(source, dict):
            continue
        for key, value in source.items():
            if str(key).lower() in ALLOWED_HEADERS and value:
                result[str(key)] = clean_text(value, 512) or ""
    return result


def unwrap_info(info: dict[str, Any]) -> dict[str, Any]:
    entries = info.get("entries")
    if info.get("_type") in {"playlist", "multi_video"} and entries:
        for entry in entries:
            if isinstance(entry, dict) and (entry.get("url") or entry.get("requested_formats")):
                return entry
    return info


def stream_type(item: dict[str, Any]) -> str:
    protocol = str(item.get("protocol") or "")
    if "m3u8" in protocol:
        return "hls"
    if "dash" in protocol:
        return "dash"
    return str(item.get("ext") or protocol or "http")[:40]


def has_video(item: dict[str, Any]) -> bool:
    return item.get("vcodec") not in {None, "none"}


def has_audio(item: dict[str, Any]) -> bool:
    return item.get("acodec") not in {None, "none"}


def codec_label(item: dict[str, Any]) -> str:
    codec = str(item.get("vcodec") or "").lower()
    if codec.startswith(("vvi1", "vvc", "h266")):
        return "VVC"
    if codec.startswith(("av01", "av1")):
        return "AV1"
    if codec.startswith(("dvh1", "dvhe")):
        return "Dolby Vision"
    if codec.startswith(("hev1", "hvc1", "hevc", "h265")):
        return "HEVC"
    if codec.startswith(("avc1", "h264")):
        return "AVC"
    return codec.split(".", 1)[0].upper()[:16]


def quality_identity(item: dict[str, Any]) -> tuple[str, str]:
    format_id = str(item.get("format_id") or "")
    height = int(item.get("height") or 0)
    fps = float(item.get("fps") or 0)
    dynamic_range = str(item.get("dynamic_range") or "SDR").upper()
    note = clean_text(item.get("format_note"), 80)

    # Bilibili video quality IDs are stable across codecs.  Prefer them so a
    # menu choice remains valid when a short-lived CDN URL is refreshed.
    if item.get("_yaozhi_vvc"):
        quality_id = f"qn:{item.get('_bilibili_qn') or format_id}:codec:vvc"
    elif format_id.isdigit() and 1 <= int(format_id) < 1000:
        quality_id = f"qn:{format_id}"
    else:
        quality_id = f"h:{height}:f:{round(fps, 3)}:dr:{dynamic_range}"

    if note and not note.isdigit():
        label = note
    elif height:
        label = f"{height}P"
        if fps >= 50:
            label += f" {round(fps):d}帧"
        if dynamic_range not in {"", "SDR", "UNKNOWN"}:
            label += f" {dynamic_range}"
    else:
        label = "原画 / 最高可用"
    codec = codec_label(item)
    if codec and codec.lower() not in label.lower():
        label += f" · {codec}"
    return quality_id, label


def live_api_json(
    session: requests.Session,
    path: str,
    timeout: float,
    params: dict[str, Any],
) -> dict[str, Any]:
    response = session.get(LIVE_API_ROOT + path, params=params, timeout=timeout)
    try:
        response.raise_for_status()
        payload = response.json()
    finally:
        response.close()
    if not isinstance(payload, dict) or payload.get("code") != 0:
        raise ValueError("Bilibili live API returned an unsuccessful response")
    data = payload.get("data")
    if not isinstance(data, dict):
        raise ValueError("Bilibili live API returned no data")
    return data


def load_netscape_cookies(session: requests.Session, cookie_file: str | None) -> None:
    if not cookie_file or not os.path.isfile(cookie_file):
        return
    try:
        jar = MozillaCookieJar(cookie_file)
        jar.load(ignore_discard=True, ignore_expires=True)
        session.cookies.update(jar)
    except (OSError, ValueError):
        # Cookies are optional. A malformed personal file must not remove the
        # anonymous quality path or expose its contents in diagnostics.
        return


def live_play_params(room_id: int, qn: int) -> dict[str, Any]:
    return {
        "room_id": room_id,
        "protocol": "0,1",
        "format": "0,1,2",
        "codec": "0,1,2",
        "qn": qn,
        "platform": "web",
        "ptype": "8",
    }


def live_playurl(data: dict[str, Any]) -> dict[str, Any]:
    playurl_info = data.get("playurl_info")
    if not isinstance(playurl_info, dict):
        return {}
    playurl = playurl_info.get("playurl")
    return playurl if isinstance(playurl, dict) else {}


def live_quality_descriptions(playurl: dict[str, Any]) -> dict[int, str]:
    descriptions: dict[int, str] = {}
    for item in playurl.get("g_qn_desc") or []:
        if not isinstance(item, dict):
            continue
        try:
            qn = int(item.get("qn") or 0)
        except (TypeError, ValueError):
            continue
        media = item.get("media_base_desc")
        detail = media.get("detail_desc") if isinstance(media, dict) else None
        label = clean_text(detail.get("desc"), 80) if isinstance(detail, dict) else None
        label = label or clean_text(item.get("desc"), 80) or LIVE_QN_LABELS.get(qn)
        if qn > 0 and label:
            descriptions[qn] = label
    return descriptions


def live_stream_candidate(
    playurl: dict[str, Any],
    requested_qn: int,
    descriptions: dict[int, str],
    canonical_url: str,
) -> dict[str, Any] | None:
    ranked: list[tuple[tuple[int, ...], dict[str, Any], str, str]] = []
    protocol_rank = {"http_stream": 3, "http_hls": 2}
    format_rank_live = {"flv": 3, "fmp4": 2, "ts": 1}
    codec_rank_live = {"avc": 3, "hevc": 2, "av1": 1}

    for stream in playurl.get("stream") or []:
        if not isinstance(stream, dict):
            continue
        protocol = str(stream.get("protocol_name") or "")
        for format_item in stream.get("format") or []:
            if not isinstance(format_item, dict):
                continue
            format_name = str(format_item.get("format_name") or "")
            for codec in format_item.get("codec") or []:
                if not isinstance(codec, dict):
                    continue
                try:
                    actual_qn = int(codec.get("current_qn") or 0)
                except (TypeError, ValueError):
                    continue
                base_url = codec.get("base_url")
                url_infos = codec.get("url_info")
                if actual_qn <= 0 or not isinstance(base_url, str) or not base_url \
                        or not isinstance(url_infos, list):
                    continue
                codec_name = str(codec.get("codec_name") or "").lower()
                for url_info in url_infos:
                    if not isinstance(url_info, dict):
                        continue
                    host = url_info.get("host")
                    extra = url_info.get("extra") or ""
                    if not isinstance(host, str) or not host.startswith(("https://", "http://")):
                        continue
                    stream_url = host.rstrip("/") + "/" + base_url.lstrip("/") + str(extra)
                    try:
                        parts = urlsplit(stream_url)
                    except ValueError:
                        continue
                    if parts.scheme not in {"http", "https"} or not parts.hostname \
                            or parts.username or parts.password:
                        continue
                    rank = (
                        int(actual_qn == requested_qn),
                        protocol_rank.get(protocol, 0),
                        format_rank_live.get(format_name, 0),
                        codec_rank_live.get(codec_name, 0),
                    )
                    ranked.append((rank, codec, stream_url, format_name or protocol))

    if not ranked:
        return None
    _rank, codec, stream_url, stream_type_name = max(ranked, key=lambda item: item[0])
    actual_qn = int(codec.get("current_qn") or requested_qn)
    codec_name = str(codec.get("codec_name") or "").lower()
    codec_label_live = {"avc": "AVC", "hevc": "HEVC", "av1": "AV1"}.get(
        codec_name, codec_name.upper()[:16]
    )
    label = descriptions.get(actual_qn) or LIVE_QN_LABELS.get(actual_qn) \
        or f"直播画质 {actual_qn}"
    if codec_label_live and codec_label_live.lower() not in label.lower():
        label += f" · {codec_label_live}"
    return {
        "quality_id": f"qn:{actual_qn}",
        "quality": label,
        "type": stream_type_name,
        "url": stream_url,
        "headers": {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
            ),
            "Referer": canonical_url,
        },
    }


def resolve_bilibili_live_api(
    canonical_url: str,
    timeout: float,
    cookie_file: str | None,
    preferred_quality: str | None,
    max_candidates: int,
) -> dict[str, Any] | None:
    room_token = urlsplit(canonical_url).path.strip("/").split("/", 1)[0]
    if not room_token:
        return None

    session = requests.Session()
    session.headers.update({
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
        ),
        "Referer": canonical_url,
    })
    load_netscape_cookies(session, cookie_file)
    try:
        room_init = live_api_json(
            session, "/room/v1/Room/room_init", timeout, {"id": room_token})
        room_id = int(room_init.get("room_id") or 0)
        if room_id <= 0 or int(room_init.get("live_status") or 0) != 1:
            return None

        preferred_qn = 0
        match = re.fullmatch(r"qn:(\d+)", preferred_quality or "")
        if match:
            preferred_qn = int(match.group(1))
        first_qn = preferred_qn or 10000
        first_data = live_api_json(
            session,
            "/xlive/web-room/v2/index/getRoomPlayInfo",
            timeout,
            live_play_params(room_id, first_qn),
        )
        first_playurl = live_playurl(first_data)
        if not first_playurl:
            return None
        descriptions = live_quality_descriptions(first_playurl)

        accepted: set[int] = set()
        for stream in first_playurl.get("stream") or []:
            if not isinstance(stream, dict):
                continue
            for format_item in stream.get("format") or []:
                if not isinstance(format_item, dict):
                    continue
                for codec in format_item.get("codec") or []:
                    if not isinstance(codec, dict):
                        continue
                    for value in codec.get("accept_qn") or []:
                        try:
                            qn = int(value)
                        except (TypeError, ValueError):
                            continue
                        if qn > 0:
                            accepted.add(qn)
        requested_qns = sorted(accepted, reverse=True)
        if preferred_qn in requested_qns:
            requested_qns.remove(preferred_qn)
            requested_qns.insert(0, preferred_qn)

        candidates: list[dict[str, Any]] = []
        seen_quality: set[str] = set()
        for requested_qn in requested_qns[:6]:
            playurl = first_playurl if requested_qn == first_qn else live_playurl(live_api_json(
                session,
                "/xlive/web-room/v2/index/getRoomPlayInfo",
                timeout,
                live_play_params(room_id, requested_qn),
            ))
            candidate = live_stream_candidate(
                playurl, requested_qn, descriptions, canonical_url)
            if not candidate or candidate["quality_id"] in seen_quality:
                continue
            seen_quality.add(candidate["quality_id"])
            candidates.append(candidate)
            if len(candidates) >= max_candidates:
                break
        if not candidates:
            return None

        room_info: dict[str, Any] = {}
        try:
            room_info = live_api_json(
                session, "/room/v1/Room/get_info", timeout, {"room_id": room_id})
        except (requests.RequestException, ValueError):
            pass
        available_qualities = {
            str(item["quality_id"]): item["quality"] for item in candidates
        }
        quality_options: list[dict[str, Any]] = []
        for qn in requested_qns:
            quality_id = f"qn:{qn}"
            available_label = available_qualities.get(quality_id)
            if available_label:
                quality_options.append({
                    "id": quality_id,
                    "label": available_label,
                    "selectable": True,
                })
            else:
                quality_options.append({
                    "id": f"unavailable:{quality_id}",
                    "label": descriptions.get(qn) or LIVE_QN_LABELS.get(qn)
                        or f"直播画质 {qn}",
                    "hint": "当前账号或直播间未返回此画质",
                    "selectable": False,
                })
        if len(quality_options) == 1:
            quality_options.append({
                "id": "status:single-live-quality",
                "label": "当前直播仅提供这一档",
                "hint": "线路变化后会在下次连接时自动刷新",
                "selectable": False,
            })

        return {
            "ok": True,
            "platform": "bilibili",
            "content_type": "live",
            "canonical_url": f"https://live.bilibili.com/{room_id}",
            "title": clean_text(room_info.get("title")),
            "author": clean_text(room_info.get("uname")),
            "resolver": "bilibili-live-api",
            "qualities": quality_options,
            "candidates": candidates,
        }
    except (requests.RequestException, OSError, ValueError):
        return None
    finally:
        session.close()


def bilibili_api_json(
    session: requests.Session,
    path: str,
    timeout: float,
    params: dict[str, Any],
) -> dict[str, Any]:
    response = session.get(BILIBILI_API_ROOT + path, params=params, timeout=timeout)
    try:
        response.raise_for_status()
        payload = response.json()
    finally:
        response.close()
    if not isinstance(payload, dict) or payload.get("code") != 0:
        raise ValueError("Bilibili video API returned an unsuccessful response")
    data = payload.get("data")
    if not isinstance(data, dict):
        raise ValueError("Bilibili video API returned no data")
    return data


def video_identifiers(
    session: requests.Session,
    webpage_url: str,
    timeout: float,
) -> tuple[int, int] | None:
    parts = urlsplit(webpage_url)
    match = re.search(r"/video/(BV[A-Za-z0-9]+|av\d+)", parts.path, re.IGNORECASE)
    if not match:
        return None
    token = match.group(1)
    params = {"bvid": token} if token.lower().startswith("bv") \
        else {"aid": token[2:]}
    view = bilibili_api_json(session, "/x/web-interface/view", timeout, params)
    try:
        aid = int(view.get("aid") or 0)
        page_index = max(1, int((parse_qs(parts.query).get("p") or ["1"])[0]))
    except (TypeError, ValueError):
        return None
    pages = [item for item in (view.get("pages") or []) if isinstance(item, dict)]
    if aid <= 0 or not pages:
        return None
    page = pages[min(page_index, len(pages)) - 1]
    try:
        cid = int(page.get("cid") or 0)
    except (TypeError, ValueError):
        return None
    return (aid, cid) if cid > 0 else None


def smartbox_vvc_formats(
    webpage_url: str,
    timeout: float,
    cookie_file: str | None,
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    """Return Bilibili's opt-in VVC tracks without changing the default codec.

    yt-dlp deliberately uses the regular web playurl feature mask, which does
    not currently expose Bilibili's ``vvi1`` tracks.  Smartbox publishes those
    tracks as ordinary DASH streams.  They are added as explicit quality menu
    choices so machines without efficient VVC decoding keep the normal default.
    """
    session = requests.Session()
    session.headers.update({
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
        ),
        "Referer": webpage_url,
    })
    media_proxy = loopback_http_proxy(BILIBILI_API_ROOT)
    load_netscape_cookies(session, cookie_file)
    try:
        identifiers = video_identifiers(session, webpage_url, timeout)
        if not identifiers:
            return [], None
        aid, cid = identifiers
        data = bilibili_api_json(
            session,
            "/x/tv/smartbox/playurl",
            timeout,
            {
                "aid": aid,
                "cid": cid,
                "qn": 0,
                "fnver": 0,
                "fnval": SMARTBOX_FNVAL,
                "fourk": 1,
            },
        )
        dash = data.get("dash")
        if not isinstance(dash, dict):
            return [], None

        headers = {"User-Agent": VVC_MEDIA_USER_AGENT, "Referer": webpage_url}
        vvc_formats: list[dict[str, Any]] = []
        for item in dash.get("video") or []:
            if not isinstance(item, dict) \
                    or not str(item.get("codecs") or "").lower().startswith("vvi1"):
                continue
            stream_url = item.get("base_url") or item.get("baseUrl")
            if not isinstance(stream_url, str) or not stream_url.startswith(("https://", "http://")):
                continue
            try:
                qn = int(item.get("id") or 0)
                bandwidth = float(item.get("bandwidth") or 0)
                fps = float(item.get("frame_rate") or item.get("frameRate") or 0)
            except (TypeError, ValueError):
                continue
            vvc_formats.append({
                "format_id": str(qn),
                "format_note": f"{int(item.get('height') or 0)}P",
                "url": stream_url,
                "protocol": "https",
                "ext": "mp4",
                "vcodec": "vvc",
                "acodec": "none",
                "width": item.get("width"),
                "height": item.get("height"),
                "fps": fps,
                "tbr": bandwidth / 1000 if bandwidth > 0 else None,
                "http_headers": headers,
                "_yaozhi_vvc": True,
                "_bilibili_qn": qn,
                "_yaozhi_http_proxy": media_proxy,
            })

        audio_formats: list[dict[str, Any]] = []
        for item in dash.get("audio") or []:
            if not isinstance(item, dict):
                continue
            stream_url = item.get("base_url") or item.get("baseUrl")
            if not isinstance(stream_url, str) or not stream_url.startswith(("https://", "http://")):
                continue
            try:
                bandwidth = float(item.get("bandwidth") or 0)
            except (TypeError, ValueError):
                bandwidth = 0
            audio_formats.append({
                "format_id": str(item.get("id") or "smartbox-audio"),
                "url": stream_url,
                "protocol": "https",
                "ext": "m4a",
                "vcodec": "none",
                "acodec": str(item.get("codecs") or "aac"),
                "tbr": bandwidth / 1000 if bandwidth > 0 else None,
                "http_headers": headers,
            })
        audio = max(audio_formats, key=lambda item: float(item.get("tbr") or 0)) \
            if audio_formats else None
        return vvc_formats, audio
    except (requests.RequestException, OSError, ValueError):
        # VVC is an optional extension. The regular yt-dlp result remains a
        # complete, playable fallback if Smartbox changes or is unavailable.
        return [], None
    finally:
        session.close()


def candidate_from_streams(
    info: dict[str, Any],
    primary: dict[str, Any],
    audio: dict[str, Any] | None,
) -> dict[str, Any]:
    if has_audio(primary):
        audio = None
    # One header set is shared by mpv's primary stream and external audio.
    # Let the primary video win: VVC CDN nodes reject the full browser UA that
    # yt-dlp attaches to the regular audio format, while that audio remains
    # compatible with the short VVC media UA.
    headers = safe_headers(
        info.get("http_headers"),
        audio.get("http_headers") if audio else None,
        primary.get("http_headers"),
    )
    quality_id, quality = quality_identity(primary)
    return {
        "quality_id": quality_id,
        "quality": quality,
        "type": stream_type(primary),
        "url": primary["url"],
        "audio_url": audio.get("url") if audio else None,
        "headers": headers,
        "width": primary.get("width"),
        "height": primary.get("height"),
        "fps": primary.get("fps"),
        "codec": codec_label(primary) or None,
        "http_proxy": primary.get("_yaozhi_http_proxy"),
    }


def selected_candidate(info: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    selected = info.get("requested_downloads") or info.get("requested_formats") or []
    selected = [item for item in selected if isinstance(item, dict) and item.get("url")]

    video: dict[str, Any] | None = None
    audio: dict[str, Any] | None = None
    muxed: dict[str, Any] | None = None
    for item in selected:
        item_has_video = has_video(item)
        item_has_audio = has_audio(item)
        if item_has_video and item_has_audio and muxed is None:
            muxed = item
        elif item_has_video and video is None:
            video = item
        elif item_has_audio and audio is None:
            audio = item

    primary = muxed or video
    if primary is None and isinstance(info.get("url"), str):
        primary = info
    if primary is None:
        return None, audio
    return candidate_from_streams(info, primary, audio), audio


def format_rank(item: dict[str, Any]) -> tuple[float, ...]:
    def number(value: Any) -> float:
        try:
            return float(value or 0)
        except (TypeError, ValueError):
            return 0.0

    codec = codec_label(item)
    codec_rank = {"AV1": 4, "HEVC": 3, "Dolby Vision": 3, "AVC": 2}.get(codec, 1)
    return (
        number(item.get("height")),
        number(item.get("width")),
        number(item.get("fps")),
        number(item.get("quality")),
        number(item.get("tbr") or item.get("vbr")),
        float(codec_rank),
    )


def build_candidates(
    info: dict[str, Any],
    preferred_quality: str | None,
    max_candidates: int,
) -> list[dict[str, Any]]:
    selected, selected_audio = selected_candidate(info)
    formats = [item for item in (info.get("formats") or [])
               if isinstance(item, dict) and isinstance(item.get("url"), str)]
    audio_formats = [item for item in formats if has_audio(item) and not has_video(item)]
    if selected_audio is None and audio_formats:
        selected_audio = max(audio_formats, key=lambda item: (
            float(item.get("abr") or 0), float(item.get("tbr") or 0)))

    groups: dict[str, list[dict[str, Any]]] = {}
    for item in formats:
        if not has_video(item):
            continue
        quality_id, _label = quality_identity(item)
        groups.setdefault(quality_id, []).append(item)

    candidates: list[dict[str, Any]] = []
    if selected:
        candidates.append(selected)
    for _quality_id, items in sorted(
        groups.items(), key=lambda pair: max(format_rank(item) for item in pair[1]), reverse=True
    ):
        primary = max(items, key=format_rank)
        candidates.append(candidate_from_streams(info, primary, selected_audio))

    deduped: list[dict[str, Any]] = []
    seen_urls: set[tuple[str, str | None]] = set()
    seen_quality: set[str] = set()
    for candidate in candidates:
        key = (str(candidate.get("url")), candidate.get("audio_url"))
        quality_id = str(candidate.get("quality_id") or "")
        if key in seen_urls or quality_id in seen_quality:
            continue
        seen_urls.add(key)
        seen_quality.add(quality_id)
        deduped.append(candidate)

    if preferred_quality:
        deduped.sort(key=lambda item: item.get("quality_id") != preferred_quality)
    return deduped[:max_candidates]


def resolve(
    url: str,
    kind: str,
    timeout: float,
    cookie_file: str | None,
    preferred_quality: str | None,
    max_candidates: int,
) -> dict[str, Any]:
    canonical, error = validate_url(url, kind)
    if error or not canonical:
        return {
            "ok": False,
            "code": "unsupported_url",
            "user_message": error or "不支持的链接",
            "detail": "URL did not pass the exact Bilibili allowlist",
        }

    if kind == "bilibili-live":
        live_descriptor = resolve_bilibili_live_api(
            canonical, timeout, cookie_file, preferred_quality, max_candidates)
        if live_descriptor:
            return live_descriptor

    ydl_options: dict[str, Any] = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
        "format": "bestvideo+bestaudio/best",
        "socket_timeout": timeout,
        "retries": 2,
        "fragment_retries": 2,
        "extractor_retries": 2,
        "cachedir": False,
    }
    if cookie_file and os.path.isfile(cookie_file):
        ydl_options["cookiefile"] = cookie_file

    try:
        with yt_dlp.YoutubeDL(ydl_options) as ydl:
            raw_info = ydl.extract_info(canonical, download=False)
        if not isinstance(raw_info, dict):
            raise DownloadError("extractor returned no media descriptor")
        info = unwrap_info(raw_info)
        if kind != "bilibili-live":
            webpage_url_for_vvc = str(
                info.get("webpage_url") or raw_info.get("webpage_url") or canonical)
            vvc_formats, vvc_audio = smartbox_vvc_formats(
                webpage_url_for_vvc, timeout, cookie_file)
            if vvc_formats:
                # Keep yt-dlp's selected stream first. Smartbox VVC is opt-in
                # through the quality menu and participates in normal fallback.
                info = dict(info)
                formats = list(info.get("formats") or [])
                formats.extend(vvc_formats)
                if vvc_audio:
                    formats.append(vvc_audio)
                info["formats"] = formats
        candidates = build_candidates(info, preferred_quality, max_candidates)
        if not candidates:
            return {
                "ok": False,
                "code": "no_direct_stream",
                "user_message": "已识别 B 站页面，但没有得到可播放线路",
                "detail": "selected formats did not contain direct URLs",
            }

        is_live = bool(info.get("is_live") or raw_info.get("is_live"))
        webpage_url = str(info.get("webpage_url") or raw_info.get("webpage_url") or canonical)
        webpage_parts = urlsplit(webpage_url)
        webpage_host = (webpage_parts.hostname or "").lower().rstrip(".")
        if webpage_host not in BILIBILI_HOSTS | {"live.bilibili.com", "b23.tv"}:
            webpage_url = canonical
        else:
            webpage_url = urlunsplit((
                webpage_parts.scheme or "https",
                webpage_parts.netloc,
                webpage_parts.path,
                webpage_parts.query,
                "",
            ))

        return {
            "ok": True,
            "platform": "bilibili",
            "content_type": "live" if is_live or kind == "bilibili-live" else "video",
            "canonical_url": webpage_url,
            "title": clean_text(info.get("title") or raw_info.get("title")),
            "author": clean_text(info.get("uploader") or raw_info.get("uploader")),
            "duration": info.get("duration") or raw_info.get("duration"),
            "resolver": "yt-dlp",
            "resolver_version": YT_DLP_VERSION,
            "qualities": [
                {
                    "id": item["quality_id"],
                    "label": item["quality"],
                    **({
                        "hint": "可点击切换；无硬解时可能较吃 CPU，失败会自动回退",
                        "selectable": True,
                    }
                       if item.get("codec") == "VVC" else {}),
                }
                for item in candidates
            ],
            "candidates": candidates,
        }
    except DownloadError as exc:
        message = "B站直播当前未开播，或暂时没有可用线路" if kind == "bilibili-live" \
            else "B站视频解析失败，可能需要登录 Cookie 或稍后重试"
        return {
            "ok": False,
            "code": "extract_failed",
            "user_message": message,
            "detail": sanitize_detail(exc),
        }
    except (OSError, ValueError) as exc:
        return {
            "ok": False,
            "code": "resolve_failed",
            "user_message": "B站解析失败，请检查网络后重试",
            "detail": sanitize_detail(exc) or exc.__class__.__name__,
        }
    except Exception as exc:
        return {
            "ok": False,
            "code": "unexpected_error",
            "user_message": "B站解析器遇到异常，请稍后重试",
            "detail": sanitize_detail(exc) or exc.__class__.__name__,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--url", required=True)
    parser.add_argument("--kind", required=True, choices=sorted(KINDS))
    parser.add_argument("--timeout", type=float, default=18.0)
    parser.add_argument("--cookie-file")
    parser.add_argument("--quality-id")
    parser.add_argument("--max-candidates", type=int, default=8)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return emit(resolve(
        args.url,
        args.kind,
        min(max(args.timeout, 3.0), 30.0),
        args.cookie_file,
        args.quality_id,
        min(max(args.max_candidates, 1), 12),
    ))


if __name__ == "__main__":
    raise SystemExit(main())
