#!/usr/bin/env python3
"""Anonymous Douyu/Huya live danmaku sidecar for mpv-Yaozhi.

The sidecar writes bounded local JSONL batches consumed by online-media.lua.
It does not log room pages, signed stream URLs, cookies, or chat credentials.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import socket
import ssl
import struct
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import requests
import websocket


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
)
MAX_TEXT_LENGTH = 120
MAX_JSONL_BYTES = 4 * 1024 * 1024
MAX_PACKET_BYTES = 8 * 1024 * 1024


class DanmakuError(RuntimeError):
    pass


def clean_text(value: Any) -> str:
    text = str(value or "")
    text = "".join(
        char if ord(char) >= 32 and char not in "\u2028\u2029" else " "
        for char in text
    )
    return " ".join(text.split())[:MAX_TEXT_LENGTH]


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
            value["detail"] = clean_text(detail)
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


def room_from_url(url: str, platform: str) -> str:
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").lower().rstrip(".")
    except ValueError as error:
        raise DanmakuError("invalid_room_url") from error
    if parts.scheme not in {"http", "https"} or parts.username or parts.password:
        raise DanmakuError("invalid_room_url")
    if platform == "douyu":
        if host not in {"douyu.com", "www.douyu.com", "m.douyu.com"}:
            raise DanmakuError("invalid_douyu_host")
        match = re.fullmatch(r"/(?:topic/)?(\d+)/?", parts.path)
        if not match:
            raise DanmakuError("invalid_douyu_room")
        return match.group(1)
    if host not in {"huya.com", "www.huya.com", "m.huya.com"}:
        raise DanmakuError("invalid_huya_host")
    channel = parts.path.strip("/").split("/", 1)[0]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", channel or ""):
        raise DanmakuError("invalid_huya_room")
    return channel


# Douyu STT protocol ---------------------------------------------------------

DOUYU_HEADER = struct.Struct("<IIHBB")
DOUYU_COLORS = {
    "1": 0xFF2E2E,
    "2": 0x1E87FF,
    "3": 0x2FC96F,
    "4": 0xFF8A2A,
    "5": 0xB46CFF,
    "6": 0xFF67B3,
}


def douyu_escape(value: Any) -> str:
    return str(value).replace("@", "@A").replace("/", "@S")


def douyu_packet(values: dict[str, Any]) -> bytes:
    body = "".join(
        f"{douyu_escape(key)}@={douyu_escape(value)}/"
        for key, value in values.items()
    ).encode("utf-8") + b"\x00"
    data_length = len(body) + 8
    return DOUYU_HEADER.pack(data_length, data_length, 689, 0, 0) + body


def douyu_unescape(value: str) -> str:
    return value.replace("@S", "/").replace("@A", "@")


def decode_douyu_stt(body: bytes) -> dict[str, str]:
    try:
        text = body.rstrip(b"\x00").decode("utf-8", "replace")
    except Exception:
        return {}
    values: dict[str, str] = {}
    for field in text.split("/"):
        if "@=" not in field:
            continue
        key, value = field.split("@=", 1)
        values[douyu_unescape(key)] = douyu_unescape(value)
    return values


def decode_douyu_packets(payload: bytes) -> list[dict[str, Any]]:
    if len(payload) > MAX_PACKET_BYTES:
        return []
    messages: list[dict[str, Any]] = []
    offset = 0
    while offset + DOUYU_HEADER.size <= len(payload):
        data_length, duplicate, message_type, _encrypt, _reserved = DOUYU_HEADER.unpack_from(payload, offset)
        packet_length = data_length + 4
        if (
            data_length != duplicate
            or message_type not in {689, 690}
            or packet_length < DOUYU_HEADER.size
            or offset + packet_length > len(payload)
        ):
            break
        values = decode_douyu_stt(payload[offset + DOUYU_HEADER.size:offset + packet_length])
        offset += packet_length
        if values.get("type") != "chatmsg":
            continue
        text = clean_text(values.get("txt"))
        if text:
            messages.append({
                "text": text,
                "type": 1,
                "size": 25,
                "color": DOUYU_COLORS.get(values.get("col", ""), 0xFFFFFF),
            })
    return messages


def receive_douyu(room_id: str, emitter: JsonlEmitter, timeout: float,
                  deadline: float | None) -> None:
    ws = websocket.create_connection(
        "wss://danmuproxy.douyu.com:8506/",
        timeout=timeout,
        origin="https://www.douyu.com",
        header=[f"User-Agent: {USER_AGENT}"],
        # Douyu's current danmaku endpoint still negotiates legacy cipher
        # suites rejected by OpenSSL's default security level.  Keep normal
        # certificate-chain validation, but lower the cipher security level
        # only for this isolated public chat connection.
        sslopt={
            "cert_reqs": ssl.CERT_REQUIRED,
            "check_hostname": False,
            "ciphers": "DEFAULT@SECLEVEL=1",
        },
        enable_multithread=False,
    )
    try:
        ws.send_binary(douyu_packet({"type": "loginreq", "roomid": room_id}))
        ws.send_binary(douyu_packet({
            "type": "joingroup", "rid": room_id, "gid": "-9999",
        }))
        emitter.status("connected")
        last_heartbeat = 0.0
        while deadline is None or time.monotonic() < deadline:
            now = time.monotonic()
            if now - last_heartbeat >= 40:
                ws.send_binary(douyu_packet({"type": "mrkl"}))
                last_heartbeat = now
            try:
                payload = ws.recv()
            except (websocket.WebSocketTimeoutException, socket.timeout):
                continue
            if isinstance(payload, str):
                payload = payload.encode("utf-8", "replace")
            if isinstance(payload, bytes):
                emitter.messages(decode_douyu_packets(payload))
        emitter.status("completed")
    finally:
        ws.close()


# Huya Tars protocol ---------------------------------------------------------

TARS_BYTE = 0
TARS_SHORT = 1
TARS_INT = 2
TARS_LONG = 3
TARS_STRING1 = 6
TARS_STRING4 = 7
TARS_MAP = 8
TARS_LIST = 9
TARS_STRUCT_BEGIN = 10
TARS_STRUCT_END = 11
TARS_ZERO = 12
TARS_SIMPLE_LIST = 13


def tars_head(tag: int, field_type: int) -> bytes:
    if tag < 15:
        return bytes(((tag << 4) | field_type,))
    if tag < 256:
        return bytes((0xF0 | field_type, tag))
    raise ValueError("Tars tag is too large")


def tars_int(tag: int, value: int) -> bytes:
    if value == 0:
        return tars_head(tag, TARS_ZERO)
    if -128 <= value <= 127:
        return tars_head(tag, TARS_BYTE) + struct.pack(">b", value)
    if -32768 <= value <= 32767:
        return tars_head(tag, TARS_SHORT) + struct.pack(">h", value)
    if -(2**31) <= value <= 2**31 - 1:
        return tars_head(tag, TARS_INT) + struct.pack(">i", value)
    return tars_head(tag, TARS_LONG) + struct.pack(">q", value)


def tars_string(tag: int, value: str) -> bytes:
    raw = value.encode("utf-8")
    if len(raw) <= 255:
        return tars_head(tag, TARS_STRING1) + bytes((len(raw),)) + raw
    return tars_head(tag, TARS_STRING4) + struct.pack(">I", len(raw)) + raw


def tars_bytes(tag: int, value: bytes) -> bytes:
    return (
        tars_head(tag, TARS_SIMPLE_LIST)
        + tars_head(0, TARS_BYTE)
        + tars_int(0, len(value))
        + value
    )


def tars_struct(tag: int, value: bytes) -> bytes:
    return tars_head(tag, TARS_STRUCT_BEGIN) + value + tars_head(0, TARS_STRUCT_END)


class TarsReader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0

    def _head(self) -> tuple[int, int]:
        if self.pos >= len(self.data):
            raise DanmakuError("tars_eof")
        value = self.data[self.pos]
        self.pos += 1
        tag, field_type = value >> 4, value & 0x0F
        if tag == 15:
            if self.pos >= len(self.data):
                raise DanmakuError("tars_tag_eof")
            tag = self.data[self.pos]
            self.pos += 1
        return tag, field_type

    def _numeric(self, field_type: int) -> int:
        sizes = {
            TARS_BYTE: (1, ">b"), TARS_SHORT: (2, ">h"),
            TARS_INT: (4, ">i"), TARS_LONG: (8, ">q"),
        }
        if field_type == TARS_ZERO:
            return 0
        if field_type not in sizes:
            raise DanmakuError("tars_not_numeric")
        size, fmt = sizes[field_type]
        if self.pos + size > len(self.data):
            raise DanmakuError("tars_numeric_eof")
        value = struct.unpack_from(fmt, self.data, self.pos)[0]
        self.pos += size
        return int(value)

    def _length(self) -> int:
        _tag, field_type = self._head()
        value = self._numeric(field_type)
        if value < 0 or value > MAX_PACKET_BYTES:
            raise DanmakuError("tars_length_invalid")
        return value

    def _skip(self, field_type: int) -> None:
        if field_type in {TARS_ZERO, TARS_STRUCT_END}:
            return
        if field_type in {TARS_BYTE, TARS_SHORT, TARS_INT, TARS_LONG}:
            self._numeric(field_type)
            return
        if field_type == 4:
            self.pos += 4
            return
        if field_type == 5:
            self.pos += 8
            return
        if field_type == TARS_STRING1:
            length = self.data[self.pos]
            self.pos += 1 + length
            return
        if field_type == TARS_STRING4:
            length = struct.unpack_from(">I", self.data, self.pos)[0]
            self.pos += 4 + length
            return
        if field_type == TARS_SIMPLE_LIST:
            _element_tag, element_type = self._head()
            if element_type != TARS_BYTE:
                raise DanmakuError("tars_simple_list_type")
            self.pos += self._length()
            return
        if field_type == TARS_LIST:
            for _ in range(self._length()):
                _tag, nested_type = self._head()
                self._skip(nested_type)
            return
        if field_type == TARS_MAP:
            for _ in range(self._length() * 2):
                _tag, nested_type = self._head()
                self._skip(nested_type)
            return
        if field_type == TARS_STRUCT_BEGIN:
            while self.pos < len(self.data):
                _tag, nested_type = self._head()
                if nested_type == TARS_STRUCT_END:
                    return
                self._skip(nested_type)
            raise DanmakuError("tars_struct_eof")
        raise DanmakuError("tars_unknown_type")

    def _find(self, wanted_tag: int) -> int | None:
        while self.pos < len(self.data):
            saved = self.pos
            tag, field_type = self._head()
            if tag == wanted_tag:
                return field_type
            if tag > wanted_tag or field_type == TARS_STRUCT_END:
                self.pos = saved
                return None
            self._skip(field_type)
        return None

    def read_int(self, tag: int, default: int = 0) -> int:
        field_type = self._find(tag)
        return default if field_type is None else self._numeric(field_type)

    def read_string(self, tag: int, default: str = "") -> str:
        field_type = self._find(tag)
        if field_type is None:
            return default
        if field_type == TARS_STRING1:
            length = self.data[self.pos]
            self.pos += 1
        elif field_type == TARS_STRING4:
            length = struct.unpack_from(">I", self.data, self.pos)[0]
            self.pos += 4
        else:
            raise DanmakuError("tars_not_string")
        value = self.data[self.pos:self.pos + length]
        self.pos += length
        return value.decode("utf-8", "replace")

    def read_bytes(self, tag: int) -> bytes:
        field_type = self._find(tag)
        if field_type != TARS_SIMPLE_LIST:
            return b""
        _element_tag, element_type = self._head()
        if element_type != TARS_BYTE:
            return b""
        length = self._length()
        value = self.data[self.pos:self.pos + length]
        self.pos += length
        return value

    def read_struct(self, tag: int) -> bytes:
        field_type = self._find(tag)
        if field_type != TARS_STRUCT_BEGIN:
            return b""
        start = self.pos
        while self.pos < len(self.data):
            head_start = self.pos
            _nested_tag, nested_type = self._head()
            if nested_type == TARS_STRUCT_END:
                return self.data[start:head_start]
            self._skip(nested_type)
        return b""


def huya_command(command_type: int, data: bytes = b"") -> bytes:
    return tars_int(0, command_type) + tars_bytes(1, data)


def huya_register(uid: int) -> bytes:
    user = b"".join((
        tars_int(0, uid), tars_int(1, 0),
        tars_string(2, ""), tars_string(3, ""),
        tars_int(4, 0), tars_int(5, 0),
        tars_int(6, uid), tars_int(7, 3),
    ))
    return huya_command(1, user)


def decode_huya_message(payload: bytes) -> list[dict[str, Any]]:
    if not payload or len(payload) > MAX_PACKET_BYTES:
        return []
    try:
        outer = TarsReader(payload)
        if outer.read_int(0, -1) != 7:
            return []
        push = TarsReader(outer.read_bytes(1))
        if push.read_int(1, -1) != 1400:
            return []
        chat = TarsReader(push.read_bytes(2))
        user = TarsReader(chat.read_struct(0))
        _name = user.read_string(2, "")
        text = clean_text(chat.read_string(3, ""))
        color_reader = TarsReader(chat.read_struct(6))
        color = color_reader.read_int(0, -1)
        if color < 0 or color > 0xFFFFFF:
            color = 0xFFFFFF
        if text:
            return [{"text": text, "type": 1, "size": 25, "color": color}]
    except (DanmakuError, IndexError, struct.error, UnicodeError):
        return []
    return []


def huya_uid(channel: str, timeout: float) -> int:
    response = requests.get(
        f"https://www.huya.com/{channel}",
        headers={"User-Agent": USER_AGENT, "Referer": "https://www.huya.com/"},
        timeout=(5, timeout),
    )
    response.raise_for_status()
    match = re.search(r'"uid"\s*:\s*"?(\d+)"?', response.text)
    if not match:
        raise DanmakuError("huya_uid_unavailable")
    return int(match.group(1))


def receive_huya(uid: int, emitter: JsonlEmitter, timeout: float,
                 deadline: float | None) -> None:
    # The official hostname currently advertises IPv6 before IPv4. Some
    # Windows networks accept the IPv6 TCP route but never finish its TLS
    # handshake, so connect to an official DNS-resolved public IPv4 address
    # while retaining the original Host header and TLS SNI identity.
    addresses: list[str] = []
    for info in socket.getaddrinfo(
        "cdnws.api.huya.com", 443, socket.AF_INET, socket.SOCK_STREAM
    ):
        address = info[4][0]
        if ipaddress.ip_address(address).is_global and address not in addresses:
            addresses.append(address)
    if not addresses:
        raise DanmakuError("huya_ipv4_unavailable")

    ws = None
    last_error: Exception | None = None
    for address in addresses[:3]:
        try:
            ws = websocket.create_connection(
                f"wss://{address}/",
                timeout=timeout,
                host="cdnws.api.huya.com",
                origin="https://www.huya.com",
                header=[f"User-Agent: {USER_AGENT}"],
                sslopt={"server_hostname": "cdnws.api.huya.com"},
                enable_multithread=False,
            )
            break
        except Exception as error:
            last_error = error
    if ws is None:
        raise last_error or DanmakuError("huya_websocket_unavailable")
    try:
        ws.send_binary(huya_register(uid))
        emitter.status("connected")
        last_heartbeat = 0.0
        while deadline is None or time.monotonic() < deadline:
            now = time.monotonic()
            if now - last_heartbeat >= 30:
                ws.send_binary(huya_command(5))
                try:
                    ws.ping()
                except websocket.WebSocketException:
                    pass
                last_heartbeat = now
            try:
                payload = ws.recv()
            except (websocket.WebSocketTimeoutException, socket.timeout):
                continue
            if isinstance(payload, str):
                payload = payload.encode("latin1", "ignore")
            if isinstance(payload, bytes):
                emitter.messages(decode_huya_message(payload))
        emitter.status("completed")
    finally:
        ws.close()


def run(args: argparse.Namespace) -> int:
    emitter = JsonlEmitter(Path(args.output), args.max_messages_per_second)
    emitter.status("connecting")
    try:
        room = room_from_url(args.room_url, args.platform)
        uid = huya_uid(room, args.timeout) if args.platform == "huya" else None
    except Exception as error:
        emitter.status("unavailable", type(error).__name__)
        return 2

    deadline = time.monotonic() + args.max_runtime if args.max_runtime > 0 else None
    attempts = args.max_reconnects + 1
    for attempt in range(attempts):
        if deadline is not None and time.monotonic() >= deadline:
            return 0
        try:
            if args.platform == "douyu":
                receive_douyu(room, emitter, args.timeout, deadline)
            else:
                receive_huya(int(uid), emitter, args.timeout, deadline)
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
    parser.add_argument("--platform", required=True, choices=("douyu", "huya"))
    parser.add_argument("--room-url", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--max-reconnects", type=int, default=3)
    parser.add_argument("--max-messages-per-second", type=int, default=100)
    parser.add_argument("--max-runtime", type=float, default=0)
    args = parser.parse_args(argv)
    args.timeout = max(3, min(20, args.timeout))
    args.max_reconnects = max(0, min(5, args.max_reconnects))
    args.max_messages_per_second = max(10, min(200, args.max_messages_per_second))
    args.max_runtime = max(0, min(3600, args.max_runtime))
    return args


if __name__ == "__main__":
    sys.exit(run(parse_args(sys.argv[1:])))
