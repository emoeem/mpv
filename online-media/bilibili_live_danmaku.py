#!/usr/bin/env python3
"""Receive anonymous Bilibili live danmaku and append bounded JSON batches.

The output is an ephemeral local JSONL transport consumed by online-media.lua.
It intentionally contains no login cookies, WBI keys, danmaku tokens, or stream URLs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request
import zlib
from pathlib import Path
from typing import Any

import websocket


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
)
MIXIN_KEY_TABLE = (
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
)
HEADER = struct.Struct(">IHHII")
MAX_PACKET_BYTES = 8 * 1024 * 1024
MAX_TEXT_LENGTH = 120
MAX_JSONL_BYTES = 4 * 1024 * 1024


class DanmakuError(RuntimeError):
    pass


def request_json(url: str, referer: str, timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Referer": referer, "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def wbi_key(referer: str, timeout: float) -> str:
    response = request_json(
        "https://api.bilibili.com/x/web-interface/nav", referer, timeout)
    data = response.get("data") or {}
    wbi = data.get("wbi_img") or {}
    urls = (wbi.get("img_url"), wbi.get("sub_url"))
    if not all(isinstance(url, str) and "/" in url for url in urls):
        raise DanmakuError("wbi_key_unavailable")
    lookup = "".join(url.rsplit("/", 1)[1].split(".", 1)[0] for url in urls)
    if len(lookup) < 64:
        raise DanmakuError("wbi_key_invalid")
    return "".join(lookup[index] for index in MIXIN_KEY_TABLE)[:32]


def sign_wbi(params: dict[str, Any], key: str) -> dict[str, str]:
    signed = {**params, "wts": str(round(time.time()))}
    normalized = {
        name: "".join(char for char in str(value) if char not in "!'()*")
        for name, value in sorted(signed.items())
    }
    query = urllib.parse.urlencode(normalized)
    normalized["w_rid"] = hashlib.md5((query + key).encode()).hexdigest()
    return normalized


def resolve_room(room_value: str, timeout: float) -> tuple[int, bool, str]:
    room_id = room_value.strip().rstrip("/").rsplit("/", 1)[-1].split("?", 1)[0]
    if not room_id.isdigit():
        raise DanmakuError("invalid_room_id")
    referer = f"https://live.bilibili.com/{room_id}"
    url = "https://api.live.bilibili.com/room/v1/Room/room_init?" + urllib.parse.urlencode(
        {"id": room_id})
    response = request_json(url, referer, timeout)
    data = response.get("data") or {}
    real_room_id = data.get("room_id")
    if response.get("code") != 0 or not isinstance(real_room_id, int):
        raise DanmakuError("room_not_found")
    return real_room_id, data.get("live_status") == 1, referer


def resolve_server(room_id: int, referer: str, timeout: float) -> tuple[str, list[dict[str, Any]]]:
    params = sign_wbi({"id": room_id, "type": 0}, wbi_key(referer, timeout))
    url = (
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?"
        + urllib.parse.urlencode(params)
    )
    response = request_json(url, referer, timeout)
    data = response.get("data") or {}
    token = data.get("token")
    hosts = data.get("host_list")
    if response.get("code") != 0 or not isinstance(token, str) or not token:
        raise DanmakuError("danmaku_token_unavailable")
    if not isinstance(hosts, list) or not hosts:
        raise DanmakuError("danmaku_host_unavailable")
    return token, hosts


def packet(operation: int, body: bytes, version: int = 1) -> bytes:
    length = HEADER.size + len(body)
    return HEADER.pack(length, HEADER.size, version, operation, 1) + body


def clean_text(value: Any) -> str:
    text = str(value or "")
    text = "".join(char if ord(char) >= 32 and char not in "\u2028\u2029" else " " for char in text)
    return " ".join(text.split())[:MAX_TEXT_LENGTH]


def as_number(value: Any, default: int, minimum: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, number))


def decode_command(command: dict[str, Any]) -> dict[str, Any] | None:
    if not str(command.get("cmd") or "").startswith("DANMU_MSG"):
        return None
    info = command.get("info")
    if not isinstance(info, list) or len(info) < 2 or not isinstance(info[0], list):
        return None
    text = clean_text(info[1])
    if not text:
        return None
    settings = info[0]
    return {
        "text": text,
        "type": as_number(settings[1] if len(settings) > 1 else None, 1, 1, 5),
        "size": as_number(settings[2] if len(settings) > 2 else None, 25, 12, 64),
        "color": as_number(settings[3] if len(settings) > 3 else None, 0xFFFFFF, 0, 0xFFFFFF),
    }


def decode_packets(payload: bytes, depth: int = 0) -> tuple[list[dict[str, Any]], bool]:
    if depth > 3 or len(payload) > MAX_PACKET_BYTES:
        return [], False
    messages: list[dict[str, Any]] = []
    authenticated = False
    offset = 0
    while offset + HEADER.size <= len(payload):
        length, header_length, version, operation, _sequence = HEADER.unpack_from(payload, offset)
        if length < header_length or header_length < HEADER.size or offset + length > len(payload):
            break
        body = payload[offset + header_length:offset + length]
        offset += length
        if version == 2:
            try:
                nested, nested_auth = decode_packets(zlib.decompress(body), depth + 1)
            except zlib.error:
                continue
            messages.extend(nested)
            authenticated = authenticated or nested_auth
        elif operation == 8:
            try:
                reply = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                reply = {}
            authenticated = reply.get("code", 0) == 0
        elif operation == 5:
            try:
                command = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            item = decode_command(command)
            if item:
                messages.append(item)
    return messages, authenticated


class JsonlEmitter:
    def __init__(self, path: Path, max_messages_per_second: int) -> None:
        self.path = path
        self.max_messages_per_second = max_messages_per_second
        self.window_started = time.monotonic()
        self.window_count = 0
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("", encoding="utf-8")

    def _write(self, value: dict[str, Any]) -> None:
        line = json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
        try:
            if self.path.stat().st_size >= MAX_JSONL_BYTES:
                self.path.write_text("", encoding="utf-8")
        except OSError:
            pass
        with self.path.open("a", encoding="utf-8", newline="\n") as output:
            output.write(line)
            output.flush()

    def status(self, status: str, detail: str = "") -> None:
        value: dict[str, Any] = {"type": "status", "status": status}
        if detail:
            value["detail"] = detail[:120]
        self._write(value)

    def messages(self, values: list[dict[str, Any]]) -> None:
        now = time.monotonic()
        if now - self.window_started >= 1:
            self.window_started = now
            self.window_count = 0
        remaining = max(0, self.max_messages_per_second - self.window_count)
        selected = values[:remaining]
        if not selected:
            return
        self.window_count += len(selected)
        self._write({"type": "batch", "messages": selected})


def receive_once(
    room_id: int,
    token: str,
    host: dict[str, Any],
    emitter: JsonlEmitter,
    timeout: float,
    deadline: float | None,
) -> None:
    hostname = str(host.get("host") or "")
    port = as_number(host.get("wss_port"), 443, 1, 65535)
    if not hostname or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-" for char in hostname):
        raise DanmakuError("danmaku_host_invalid")
    ws = websocket.create_connection(
        f"wss://{hostname}:{port}/sub",
        timeout=timeout,
        header=[f"User-Agent: {USER_AGENT}", "Origin: https://live.bilibili.com"],
        enable_multithread=False,
    )
    try:
        auth = json.dumps({
            "uid": 0,
            "roomid": room_id,
            "protover": 2,
            "platform": "web",
            "type": 2,
            "key": token,
        }, separators=(",", ":")).encode()
        ws.send_binary(packet(7, auth))
        last_heartbeat = 0.0
        is_authenticated = False
        while deadline is None or time.monotonic() < deadline:
            now = time.monotonic()
            if now - last_heartbeat >= 25:
                ws.send_binary(packet(2, b"{}"))
                last_heartbeat = now
            try:
                payload = ws.recv()
            except (websocket.WebSocketTimeoutException, socket.timeout):
                continue
            if isinstance(payload, str):
                payload = payload.encode()
            if not isinstance(payload, bytes):
                continue
            messages, auth_reply = decode_packets(payload)
            if auth_reply and not is_authenticated:
                is_authenticated = True
                emitter.status("connected")
            if messages:
                emitter.messages(messages)
        emitter.status("completed")
    finally:
        ws.close()


def run(args: argparse.Namespace) -> int:
    emitter = JsonlEmitter(Path(args.output), args.max_messages_per_second)
    emitter.status("connecting")
    try:
        room_id, is_live, referer = resolve_room(args.room_url, args.timeout)
        if not is_live:
            emitter.status("offline")
            return 3
        token, hosts = resolve_server(room_id, referer, args.timeout)
    except Exception as error:
        emitter.status("unavailable", type(error).__name__)
        return 2

    deadline = time.monotonic() + args.max_runtime if args.max_runtime > 0 else None
    unique_hosts: list[dict[str, Any]] = []
    seen: set[tuple[str, int]] = set()
    for host in hosts:
        identity = (str(host.get("host") or ""), as_number(host.get("wss_port"), 443, 1, 65535))
        if identity not in seen:
            unique_hosts.append(host)
            seen.add(identity)

    attempts = min(max(1, args.max_reconnects + 1), max(1, len(unique_hosts)))
    for attempt in range(attempts):
        if deadline is not None and time.monotonic() >= deadline:
            return 0
        try:
            receive_once(room_id, token, unique_hosts[attempt % len(unique_hosts)], emitter, args.timeout, deadline)
            return 0
        except KeyboardInterrupt:
            return 0
        except Exception as error:
            if attempt + 1 >= attempts:
                emitter.status("disconnected", type(error).__name__)
                return 4
            emitter.status("reconnecting")
            time.sleep(min(2 * (attempt + 1), 5))
    return 4


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--room-url", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--max-reconnects", type=int, default=3)
    parser.add_argument("--max-messages-per-second", type=int, default=100)
    parser.add_argument("--max-runtime", type=float, default=0)
    args = parser.parse_args(argv)
    args.timeout = max(3, min(30, args.timeout))
    args.max_reconnects = max(0, min(5, args.max_reconnects))
    args.max_messages_per_second = max(10, min(200, args.max_messages_per_second))
    args.max_runtime = max(0, min(3600, args.max_runtime))
    return args


if __name__ == "__main__":
    sys.exit(run(parse_args(sys.argv[1:])))
