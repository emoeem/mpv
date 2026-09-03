#!/usr/bin/env python3
"""Local Bilibili QR login helper for mpv-Yaozhi.

Only Bilibili's official passport endpoints are contacted. QR pixels are
generated locally and successful session cookies are saved as a Netscape
cookie jar for yt-dlp/mpv.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import pathlib
import sys
import tempfile
import time
from typing import Any

# The bundled embeddable Python intentionally disables site imports and does
# not add the script directory to sys.path. Add only this audited helper folder
# so the vendored QR encoder remains importable without weakening isolation.
SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import requests

from qrcodegen import QrCode


GENERATE_URL = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate"
POLL_URL = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
)
TIMEOUT = (5, 10)


def emit(payload: dict[str, Any], exit_code: int = 0) -> None:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    sys.stdout.buffer.write(raw.encode("utf-8"))
    raise SystemExit(exit_code)


def safe_error(message: str, code: str = "request_failed") -> None:
    emit({"ok": False, "code": code, "message": message}, 1)


def request_json(session: requests.Session, url: str, **kwargs: Any) -> dict[str, Any]:
    response = session.get(url, timeout=TIMEOUT, **kwargs)
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise ValueError("invalid JSON response")
    return payload


def atomic_write_bgra(path: pathlib.Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def render_qr_bgra(text: str, output: pathlib.Path, requested_size: int) -> tuple[int, int]:
    qr = QrCode.encode_text(text, QrCode.Ecc.MEDIUM)
    quiet_zone = 4
    modules = qr.get_size() + quiet_zone * 2
    scale = max(1, min(12, requested_size // modules))
    side = modules * scale
    black = b"\x00\x00\x00\xff"
    white = b"\xff\xff\xff\xff"
    rows: list[bytes] = []
    for module_y in range(-quiet_zone, qr.get_size() + quiet_zone):
        row = bytearray()
        for module_x in range(-quiet_zone, qr.get_size() + quiet_zone):
            color = black if qr.get_module(module_x, module_y) else white
            row.extend(color * scale)
        rendered = bytes(row)
        rows.extend([rendered] * scale)
    atomic_write_bgra(output, b"".join(rows))
    return side, side


def create_session() -> requests.Session:
    session = requests.Session()
    session.headers.update({
        "User-Agent": USER_AGENT,
        "Accept": "application/json, text/plain, */*",
        "Referer": "https://passport.bilibili.com/login",
    })
    return session


def generate(args: argparse.Namespace) -> None:
    try:
        session = create_session()
        payload = request_json(session, GENERATE_URL)
        data = payload.get("data") if payload.get("code") == 0 else None
        if not isinstance(data, dict):
            safe_error("B站暂时没有返回登录二维码", "generate_rejected")
        login_url = data.get("url")
        qrcode_key = data.get("qrcode_key")
        if not isinstance(login_url, str) or not isinstance(qrcode_key, str):
            safe_error("B站返回的二维码信息不完整", "generate_invalid")
        width, height = render_qr_bgra(
            login_url,
            pathlib.Path(args.qr_output).resolve(),
            max(220, min(480, int(args.size))),
        )
        emit({
            "ok": True,
            "qrcode_key": qrcode_key,
            "width": width,
            "height": height,
            "expires_in": 180,
        })
    except requests.RequestException:
        safe_error("无法连接 B站登录服务，请检查网络后重试")
    except (OSError, ValueError, TypeError):
        safe_error("二维码生成失败，请重试", "generate_failed")


def save_cookie_jar(session: requests.Session, target: pathlib.Path) -> int:
    cookies = [
        cookie for cookie in session.cookies
        if cookie.domain.lstrip(".") == "bilibili.com"
        or cookie.domain.lstrip(".").endswith(".bilibili.com")
    ]
    if not any(cookie.name == "SESSDATA" and cookie.value for cookie in cookies):
        raise ValueError("missing SESSDATA")

    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=target.name + ".", suffix=".tmp", dir=target.parent)
    os.close(fd)
    try:
        jar = http.cookiejar.MozillaCookieJar(temp_name)
        for cookie in cookies:
            jar.set_cookie(cookie)
        jar.save(ignore_discard=True, ignore_expires=True)
        os.replace(temp_name, target)
    except BaseException:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise
    return len(cookies)


def poll(args: argparse.Namespace) -> None:
    try:
        session = create_session()
        payload = request_json(session, POLL_URL, params={"qrcode_key": args.qrcode_key})
        data = payload.get("data")
        if payload.get("code") != 0 or not isinstance(data, dict):
            safe_error("B站登录状态查询失败", "poll_rejected")
        status = int(data.get("code", -1))
        if status == 86101:
            emit({"ok": True, "status": "waiting_scan", "message": "等待扫码"})
        if status == 86090:
            emit({"ok": True, "status": "waiting_confirm", "message": "已扫码，请在手机确认"})
        if status == 86038:
            emit({"ok": True, "status": "expired", "message": "二维码已过期"})
        if status != 0:
            emit({"ok": True, "status": "rejected", "message": "登录未完成，请刷新二维码"})

        cookie_count = save_cookie_jar(session, pathlib.Path(args.cookie_file).resolve())
        emit({
            "ok": True,
            "status": "success",
            "message": "登录成功",
            "cookie_count": cookie_count,
        })
    except requests.RequestException:
        safe_error("网络暂时不可用，正在等待重试")
    except (OSError, ValueError, TypeError):
        safe_error("登录凭据保存失败，请重试", "cookie_save_failed")


def cookie_status(args: argparse.Namespace) -> None:
    target = pathlib.Path(args.cookie_file).resolve()
    if not target.is_file():
        emit({"ok": True, "logged_in": False, "status": "missing"})
    try:
        jar = http.cookiejar.MozillaCookieJar(str(target))
        jar.load(ignore_discard=True, ignore_expires=True)
        now = time.time()
        sessdata = next((
            cookie for cookie in jar
            if cookie.name == "SESSDATA" and cookie.value
            and (cookie.domain.lstrip(".") == "bilibili.com"
                 or cookie.domain.lstrip(".").endswith(".bilibili.com"))
            and (cookie.expires is None or cookie.expires > now)
        ), None)
        emit({
            "ok": True,
            "logged_in": sessdata is not None,
            "status": "ready" if sessdata is not None else "expired",
        })
    except (OSError, http.cookiejar.LoadError):
        emit({"ok": True, "logged_in": False, "status": "invalid"})


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=True)
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--qr-output", required=True)
    generate_parser.add_argument("--size", type=int, default=320)
    generate_parser.set_defaults(handler=generate)

    poll_parser = subparsers.add_parser("poll")
    poll_parser.add_argument("--qrcode-key", required=True)
    poll_parser.add_argument("--cookie-file", required=True)
    poll_parser.set_defaults(handler=poll)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--cookie-file", required=True)
    status_parser.set_defaults(handler=cookie_status)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
