"""Resolve exact YouTube video URLs to selectable direct media tracks.

The helper emits one compact JSON object on stdout. Signed media URLs are only
returned inside successful descriptors consumed by mpv; error details never
contain URLs, cookies, or authorization data.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any
from urllib.parse import parse_qs, urlsplit

from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError


VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
ALLOWED_HEADERS = {"user-agent", "referer", "origin"}


class QuietLogger:
    def debug(self, _message: str, *args: Any, **kwargs: Any) -> None:
        pass

    info = debug
    warning = debug
    error = debug


def emit(payload: dict[str, Any]) -> int:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    sys.stdout.buffer.write(data.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0 if payload.get("ok") else 2


def clean_text(value: Any, limit: int = 240) -> str | None:
    if value is None:
        return None
    text = " ".join(str(value).replace("\x00", "").split())
    return text[:limit] or None


def canonicalize(url: str) -> tuple[str | None, str | None]:
    try:
        parts = urlsplit(url.strip())
        port = parts.port
    except ValueError:
        return None, "链接格式不正确"
    if parts.scheme.lower() not in {"http", "https"} or parts.username or parts.password:
        return None, "只支持普通 YouTube HTTPS/HTTP 链接"
    if port not in {None, 80, 443}:
        return None, "YouTube 链接使用了不支持的端口"

    host = (parts.hostname or "").lower().rstrip(".")
    path = parts.path or "/"
    video_id: str | None = None
    if host == "youtu.be":
        video_id = path.strip("/").split("/", 1)[0]
    elif host in {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}:
        if path == "/watch":
            video_id = (parse_qs(parts.query).get("v") or [None])[0]
        else:
            match = re.fullmatch(r"/(?:shorts|live|embed)/([^/?#]+)/*", path)
            video_id = match.group(1) if match else None
    if not video_id or not VIDEO_ID.fullmatch(video_id):
        return None, "当前只支持单个 YouTube 视频链接"
    return f"https://www.youtube.com/watch?v={video_id}", None


def sanitize_proxy(value: str | None) -> str | None:
    value = (value or "").strip().rstrip("/")
    if not value:
        return None
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        return None
    if parts.scheme not in {"http", "https"} or parts.username or parts.password:
        return None
    if not parts.hostname or not port or parts.path not in {"", "/"}:
        return None
    return value


def safe_headers(*sources: Any) -> dict[str, str]:
    result: dict[str, str] = {}
    for source in sources:
        if not isinstance(source, dict):
            continue
        for key, value in source.items():
            if str(key).lower() in ALLOWED_HEADERS and isinstance(value, str) and value:
                result[str(key)] = value.replace("\r", "").replace("\n", "")[:512]
    return result


def codec_family(codec: Any) -> str:
    value = str(codec or "").lower()
    if value.startswith(("av01", "av1")):
        return "AV1"
    if value.startswith(("vp09", "vp9")):
        return "VP9"
    if value.startswith(("avc1", "h264")):
        return "AVC"
    if value.startswith(("hev1", "hvc1", "hevc", "h265")):
        return "HEVC"
    return clean_text(value.upper(), 16) or "视频"


def direct_url_format(item: Any) -> bool:
    if not isinstance(item, dict):
        return False
    url = item.get("url")
    protocol = str(item.get("protocol") or "").lower()
    # Live YouTube qualities commonly arrive as individual HLS manifests.
    # mpv can play these directly; dropping them forces the hook fallback and
    # loses the complete quality descriptor even though playback still works.
    return isinstance(url, str) and url.startswith(("https://", "http://")) and protocol in {
        "https", "http", "m3u8", "m3u8_native",
    }


def number(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def fps_value(item: dict[str, Any]) -> int:
    return max(0, int(round(number(item.get("fps")))))


def dynamic_label(item: dict[str, Any]) -> str:
    value = str(item.get("dynamic_range") or "").upper()
    return "HDR" if value and value not in {"SDR", "UNKNOWN"} else ""


def quality_label(item: dict[str, Any]) -> str:
    height = int(number(item.get("height")))
    fps = fps_value(item)
    parts = [f"{height}p" if height else clean_text(item.get("resolution"), 24) or "视频"]
    if fps > 0:
        parts.append(f"{fps}fps")
    parts.extend((dynamic_label(item), codec_family(item.get("vcodec"))))
    return " · ".join(value for value in parts if value)


def codec_preference(item: dict[str, Any]) -> int:
    height = int(number(item.get("height")))
    family = codec_family(item.get("vcodec"))
    order = ({"AVC": 3, "VP9": 2, "AV1": 1, "HEVC": 0} if height <= 1080
             else {"VP9": 3, "AV1": 2, "HEVC": 1, "AVC": 0})
    return order.get(family, -1)


def representative_formats(formats: list[Any]) -> list[dict[str, Any]]:
    selected: dict[tuple[int, int, str, str], dict[str, Any]] = {}
    for raw in formats:
        if not direct_url_format(raw):
            continue
        if str(raw.get("vcodec") or "none") == "none":
            continue
        height = int(number(raw.get("height")))
        if height <= 0 or str(raw.get("ext") or "").lower() == "mhtml":
            continue
        key = (height, fps_value(raw), dynamic_label(raw), codec_family(raw.get("vcodec")))
        previous = selected.get(key)
        score = (number(raw.get("vbr")), number(raw.get("tbr")), number(raw.get("filesize_approx")))
        old_score = ((number(previous.get("vbr")), number(previous.get("tbr")), number(previous.get("filesize_approx")))
                     if previous else (-1, -1, -1))
        if score > old_score:
            selected[key] = raw
    return sorted(
        selected.values(),
        key=lambda item: (
            -int(number(item.get("height"))),
            -fps_value(item),
            0 if dynamic_label(item) == "HDR" else 1,
            -codec_preference(item),
            -number(item.get("vbr")),
            str(item.get("format_id") or ""),
        ),
    )


def best_audio(formats: list[Any], video: dict[str, Any]) -> dict[str, Any] | None:
    if str(video.get("acodec") or "none") != "none":
        return None
    audios = [item for item in formats if direct_url_format(item)
              and str(item.get("vcodec") or "none") == "none"
              and str(item.get("acodec") or "none") != "none"
              and "drc" not in str(item.get("format_note") or "").lower()
              and not str(item.get("format_id") or "").endswith("-drc")]
    family = codec_family(video.get("vcodec"))

    def score(item: dict[str, Any]) -> tuple[int, float, float]:
        codec = str(item.get("acodec") or "").lower()
        preferred = int((family == "AVC" and codec.startswith("mp4a"))
                        or (family != "AVC" and codec.startswith("opus")))
        return preferred, number(item.get("abr")), number(item.get("tbr"))

    return max(audios, key=score) if audios else None


def format_id(item: dict[str, Any]) -> str:
    return "fmt:" + str(item.get("format_id") or "")


def resolve(
    url: str,
    timeout: float,
    max_candidates: int,
    requested_quality: str | None,
    cookie_file: pathlib.Path | None,
    js_runtime: pathlib.Path | None,
    proxy: str | None,
) -> dict[str, Any]:
    canonical_url, error = canonicalize(url)
    if error or not canonical_url:
        return {"ok": False, "code": "unsupported_url", "user_message": error or "不支持的链接"}
    if not js_runtime or not js_runtime.is_file():
        return {"ok": False, "code": "js_runtime", "user_message": "YouTube JavaScript 运行环境不完整"}

    options: dict[str, Any] = {
        "quiet": True,
        "no_warnings": True,
        "logger": QuietLogger(),
        "noplaylist": True,
        "skip_download": True,
        "socket_timeout": timeout,
        "retries": 2,
        "fragment_retries": 2,
        "extractor_retries": 2,
        "js_runtimes": {"deno": {"path": str(js_runtime)}},
    }
    clean_proxy = sanitize_proxy(proxy)
    # yt-dlp otherwise inherits proxy environment variables on its own.  The
    # player resolves Windows' proxy once and passes that exact route here so
    # webpage extraction and the signed video/audio requests use one egress IP.
    # An explicit empty proxy also makes the direct path deterministic.
    options["proxy"] = clean_proxy or ""

    try:
        # Public videos are intentionally resolved anonymously first.  Recent
        # YouTube authenticated clients can expose SVPUC/PO-token-bound formats
        # which look valid but return HTTP 403 to an external player.  Cookies
        # remain the fallback for explicit sign-in / bot-verification responses.
        try:
            with YoutubeDL(options) as ydl:
                info = ydl.extract_info(canonical_url, download=False)
        except DownloadError as anonymous_error:
            text = str(anonymous_error).lower()
            login_required = any(token in text for token in (
                "sign in to confirm", "login_required", "cookies-from-browser",
            ))
            if not login_required or not cookie_file or not cookie_file.is_file():
                raise
            authenticated_options = dict(options)
            authenticated_options["cookiefile"] = str(cookie_file)
            with YoutubeDL(authenticated_options) as ydl:
                info = ydl.extract_info(canonical_url, download=False)
    except DownloadError as exc:
        text = str(exc).lower()
        if any(token in text for token in ("sign in to confirm", "login_required", "cookies-from-browser")):
            code, message = "login_required", "YouTube 要求登录验证，请在账号菜单中获取登录状态"
        elif any(token in text for token in ("javascript", "js challenge", "deno")):
            code, message = "js_runtime", "YouTube JavaScript 验证失败，请更新完整播放器组件"
        elif any(token in text for token in ("timed out", "timeout", "proxy", "connection")):
            code, message = "network", "YouTube 连接超时，请检查代理线路或出口质量"
        else:
            code, message = "resolve_failed", "YouTube 视频解析失败，请检查网络或登录状态"
        return {"ok": False, "code": code, "user_message": message, "detail": exc.__class__.__name__}
    except (OSError, ValueError) as exc:
        return {"ok": False, "code": "resolve_failed", "user_message": "YouTube 解析组件运行失败", "detail": exc.__class__.__name__}

    if not isinstance(info, dict):
        return {"ok": False, "code": "no_video", "user_message": "YouTube 没有返回可播放的视频信息"}
    formats = list(info.get("formats") or [])
    reps = representative_formats(formats)
    if not reps:
        return {"ok": False, "code": "no_direct_formats", "user_message": "没有取得可直接播放的 YouTube 清晰度"}

    selected = next((item for item in reps if format_id(item) == requested_quality), reps[0])
    selected_height = int(number(selected.get("height")))
    selected_fps = fps_value(selected)
    ordered = [selected]
    ordered.extend(item for item in reps if item is not selected
                   and int(number(item.get("height"))) == selected_height
                   and fps_value(item) == selected_fps)
    ordered.extend(item for item in reps if item is not selected and item not in ordered
                   and int(number(item.get("height"))) <= selected_height)

    common_headers = info.get("http_headers")
    candidates: list[dict[str, Any]] = []
    seen_urls: set[str] = set()
    for video in ordered:
        video_url = video.get("url")
        if not isinstance(video_url, str) or video_url in seen_urls:
            continue
        seen_urls.add(video_url)
        audio = best_audio(formats, video)
        candidate: dict[str, Any] = {
            "quality_id": format_id(video),
            "quality": quality_label(video),
            "type": str(video.get("ext") or "http"),
            "codec": codec_family(video.get("vcodec")),
            "url": video_url,
            "headers": safe_headers(common_headers, video.get("http_headers")),
        }
        if audio and isinstance(audio.get("url"), str):
            candidate["audio_url"] = audio["url"]
        if clean_proxy:
            candidate["http_proxy"] = clean_proxy
        candidates.append(candidate)
        if len(candidates) >= max(1, max_candidates):
            break

    if not candidates:
        return {"ok": False, "code": "no_direct_formats", "user_message": "YouTube 直连清晰度暂时不可用"}

    qualities = []
    for item in reps:
        bitrate = number(item.get("tbr")) or number(item.get("vbr"))
        hint = f"约 {bitrate / 1000:.1f} Mbps" if bitrate >= 1000 else (f"约 {bitrate:.0f} Kbps" if bitrate else None)
        entry: dict[str, Any] = {"id": format_id(item), "label": quality_label(item)}
        if hint:
            entry["hint"] = hint
        qualities.append(entry)

    return {
        "ok": True,
        "platform": "youtube",
        "content_type": "live" if info.get("is_live") is True else "video",
        "canonical_url": canonical_url,
        "title": clean_text(info.get("title")),
        "author": clean_text(info.get("channel") or info.get("uploader")),
        "resolver": "yt-dlp-direct",
        "resolver_version": clean_text(getattr(sys.modules.get("yt_dlp.version"), "__version__", None)),
        "qualities": qualities,
        "candidates": candidates,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--kind", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--timeout", type=float, default=18)
    parser.add_argument("--max-candidates", type=int, default=8)
    parser.add_argument("--quality-id")
    parser.add_argument("--cookie-file")
    parser.add_argument("--js-runtime")
    parser.add_argument("--proxy")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.kind != "youtube-video":
        return emit({"ok": False, "code": "unsupported_kind", "user_message": "不支持的 YouTube 链接类型"})
    return emit(resolve(
        args.url,
        max(5.0, min(args.timeout, 60.0)),
        max(1, min(args.max_candidates, 16)),
        args.quality_id,
        pathlib.Path(args.cookie_file) if args.cookie_file else None,
        pathlib.Path(args.js_runtime) if args.js_runtime else None,
        args.proxy,
    ))


if __name__ == "__main__":
    raise SystemExit(main())
