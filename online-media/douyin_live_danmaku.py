"""Read public Douyin chat through an isolated, media-blocked browser session.

The site's own client maintains its anonymous connection and acknowledgements.
No personal browser profile, account, chat posting, or third-party signing API
is used. Only public chat text is forwarded to the bounded JSONL consumer.
"""
from __future__ import annotations
import base64
import ctypes
from ctypes import wintypes
import io
import gzip
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import requests
import websocket
from platform_live_danmaku import DanmakuError, JsonlEmitter, clean_text, MAX_PACKET_BYTES
from youtube_cookie_import import choose_browser


def fields(data: bytes):
    """Bounded protobuf wire reader; unknown fields do not break new schemas."""
    if not isinstance(data, bytes) or len(data) > MAX_PACKET_BYTES:
        raise ValueError("message_limit")
    offset = 0
    def varint():
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            if offset >= len(data): raise ValueError("truncated_varint")
            byte = data[offset]; offset += 1
            value |= (byte & 127) << shift
            if byte < 128: return value
        raise ValueError("invalid_varint")
    while offset < len(data):
        tag = varint(); number, wire = tag >> 3, tag & 7
        if not number: raise ValueError("invalid_field")
        if wire == 0: value = varint()
        elif wire in (1, 2, 5):
            length = varint() if wire == 2 else 8 if wire == 1 else 4
            if offset + length > len(data): raise ValueError("truncated_field")
            value = data[offset:offset + length]; offset += length
        else: raise ValueError("unsupported_wire")
        yield number, value


def decode_frame(payload: bytes) -> tuple[list[dict], bool]:
    # PushFrame.payload=8 -> Response.messages=1 -> Message.method/payload.
    frame = dict(fields(payload)); body = frame.get(8, b"")
    if not isinstance(body, bytes) or not body: return [], False
    if body.startswith(b"\x1f\x8b"):
        with gzip.GzipFile(fileobj=io.BytesIO(body)) as stream:
            body = stream.read(MAX_PACKET_BYTES + 1)
        if len(body) > MAX_PACKET_BYTES: raise ValueError("decompressed_limit")
    messages, offline = [], False
    for number, message in fields(body):
        if number != 1 or not isinstance(message, bytes): continue
        value = dict(fields(message)); method = value.get(1)
        if method not in (b"WebcastChatMessage", b"WebcastControlMessage"): continue
        content = dict(fields(value.get(2, b"")))
        if method == b"WebcastControlMessage":
            offline = offline or content.get(2) == 3
            continue
        raw = content.get(3, b"")
        if not isinstance(raw, bytes): continue
        text = clean_text(raw.decode("utf-8", "replace"))
        if text:
            color = content.get(6, b"").decode("ascii", "ignore").lstrip('#')
            messages.append({"text":text,"type":1,"size":25,
                             "color":int(color,16) if re.fullmatch(r'[0-9A-Fa-f]{6}',color) else 0xFFFFFF})
    return messages, offline


class BrowserJob:
    """Kill this helper's browser tree even if mpv aborts the Python process."""
    def __init__(self):
        if os.name != 'nt': raise DanmakuError('windows_browser_required')
        class Basic(ctypes.Structure):
            _fields_=[('process_time',ctypes.c_int64),('job_time',ctypes.c_int64),
                      ('flags',wintypes.DWORD),('minimum',ctypes.c_size_t),('maximum',ctypes.c_size_t),
                      ('active',wintypes.DWORD),('affinity',ctypes.c_size_t),
                      ('priority',wintypes.DWORD),('scheduling',wintypes.DWORD)]
        class Extended(ctypes.Structure):
            _fields_=[('basic',Basic),('io',ctypes.c_uint64*6),('process_memory',ctypes.c_size_t),
                      ('job_memory',ctypes.c_size_t),('peak_process',ctypes.c_size_t),('peak_job',ctypes.c_size_t)]
        self.kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes=[ctypes.c_void_p,wintypes.LPCWSTR]
        self.kernel.CreateJobObjectW.restype=wintypes.HANDLE
        self.kernel.SetInformationJobObject.argtypes=[wintypes.HANDLE,ctypes.c_int,ctypes.c_void_p,wintypes.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes=[wintypes.HANDLE,wintypes.HANDLE]
        self.kernel.CloseHandle.argtypes=[wintypes.HANDLE]
        self.handle=self.kernel.CreateJobObjectW(None,None)
        if not self.handle: raise ctypes.WinError(ctypes.get_last_error())
        limits=Extended();limits.basic.flags=0x2000
        if not self.kernel.SetInformationJobObject(self.handle,9,ctypes.byref(limits),ctypes.sizeof(limits)):
            self.close();raise ctypes.WinError(ctypes.get_last_error())
    def assign(self,process):
        if not self.kernel.AssignProcessToJobObject(self.handle,int(process._handle)):
            process.terminate();raise ctypes.WinError(ctypes.get_last_error())
    def close(self):
        if self.handle: self.kernel.CloseHandle(self.handle);self.handle=None


def room_url(value: str) -> str:
    parts=urlsplit(value)
    if (parts.scheme not in ('http','https') or parts.username or parts.password
            or parts.hostname not in ('live.douyin.com','douyin.com','www.douyin.com')
            or parts.port not in (None,80,443) or not re.fullmatch(r'/[A-Za-z0-9_-]+/?',parts.path)):
        raise DanmakuError('invalid_douyin_room')
    return 'https://live.douyin.com/'+parts.path.strip('/')


def receive(url: str, emitter: JsonlEmitter, timeout: float, deadline: float | None) -> None:
    selected=choose_browser('edge') or choose_browser('chrome')
    if not selected: raise DanmakuError('browser_unavailable')
    job=BrowserJob()
    profile=Path(tempfile.mkdtemp(prefix='mpv-yaozhi-douyin-'))
    process=None;ws=None
    stop_file=Path(str(emitter.path)+'.stop')
    try:
        # 这个浏览器只负责接收弹幕文本（WebSocket + 签名），不显示任何东西。
        # 默认的硬件加速会让它的 GPU 进程持续参与合成，在显卡本已吃紧的机器
        # 上实测占用七成以上 GPU。全部改成软件渲染后 GPU 开销归零，弹幕
        # 接收路径不受影响（不依赖 GPU）。
        process=subprocess.Popen([str(selected[1]),'--headless=new','--disable-extensions',
            '--no-first-run','--no-default-browser-check','--disable-background-mode','--mute-audio',
            '--disable-gpu','--disable-gpu-compositing','--disable-accelerated-2d-canvas',
            '--disable-accelerated-video-decode','--disable-software-rasterizer',
            '--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',
            '--disk-cache-size=1',f'--user-data-dir={profile}','about:blank'],
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        startup=time.monotonic()+min(timeout*2,25)
        session=requests.Session();session.trust_env=False
        while time.monotonic()<startup:
            if stop_file.exists(): return
            if process.poll() is not None: raise DanmakuError('browser_stopped')
            try:
                port=int((profile/'DevToolsActivePort').read_text().splitlines()[0])
                targets=session.get(f'http://127.0.0.1:{port}/json',timeout=1).json()
                target=next(t for t in targets if t.get('type')=='page' and t.get('url')=='about:blank')
                address=target['webSocketDebuggerUrl']
                parts=urlsplit(address)
                if parts.hostname not in ('127.0.0.1','localhost') or parts.port!=port:
                    raise DanmakuError('invalid_debug_address')
                ws=websocket.create_connection(address,timeout=1,suppress_origin=True,enable_multithread=False)
                break
            except (OSError,ValueError,StopIteration,requests.RequestException): time.sleep(.15)
        session.close()
        if ws is None: raise DanmakuError('browser_start_timeout')
        sequence=0
        def send(method,params=None):
            nonlocal sequence
            sequence+=1;ws.send(json.dumps({'id':sequence,'method':method,'params':params or {}}));return sequence
        # Await setup replies before navigating. Never attach to extension or
        # personal tabs. The browser owns heartbeat/auth; we only receive.
        commands=[('Network.enable',{}),('Page.enable',{}),
            ('Network.setUserAgentOverride',{'userAgent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'}),
            ('Network.setCookie',{'name':'__ac_nonce','value':uuid.uuid4().hex[:21],
                'domain':'.douyin.com','path':'/','secure':True}),
            ('Network.setBlockedURLs',{'urls':['*.flv*','*.m3u8*','*.mp4*','*.ts?*']})]
        pending={send(method,params) for method,params in commands}
        setup=time.monotonic()+timeout
        while pending and time.monotonic()<setup:
            if stop_file.exists(): return
            try: event=json.loads(ws.recv())
            except websocket.WebSocketTimeoutException: continue
            if event.get('id') in pending:
                if event.get('error'): raise DanmakuError('browser_setup_failed')
                pending.remove(event['id'])
        if pending: raise DanmakuError('browser_setup_timeout')
        send('Page.navigate',{'url':url})
        room_sockets=set();connected=False;last_frame=time.monotonic()
        while deadline is None or time.monotonic()<deadline:
            if stop_file.exists(): return
            if process.poll() is not None: raise DanmakuError('browser_stopped')
            if time.monotonic()-last_frame>max(45,timeout*4): raise DanmakuError('douyin_no_connection')
            try: event=json.loads(ws.recv())
            except websocket.WebSocketTimeoutException: continue
            method=event.get('method');params=event.get('params',{})
            if method=='Network.webSocketCreated':
                address=urlsplit(params.get('url',''))
                if (address.scheme=='wss' and (address.hostname or '').endswith('.douyin.com')
                        and address.path.startswith('/webcast/im/push/')):
                    room_sockets.add(params['requestId'])
            elif method=='Network.webSocketFrameReceived' and params.get('requestId') in room_sockets:
                frame=params.get('response',{})
                if frame.get('opcode')!=2: continue
                raw=frame.get('payloadData','')
                if len(raw)>MAX_PACKET_BYTES*2: continue
                try: messages,offline=decode_frame(base64.b64decode(raw,validate=True))
                except (ValueError,EOFError,OSError): continue
                last_frame=time.monotonic()
                if not connected: emitter.status('connected');connected=True
                emitter.messages(messages)
                if offline: emitter.status('offline');return
        if not connected: raise DanmakuError('douyin_no_connection')
        emitter.status('completed')
    finally:
        if ws:
            try: ws.close()
            except Exception: pass
        job.close()
        if process:
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.terminate()
        # Only our newly created, resolved temporary profile can be removed.
        if profile.parent==Path(tempfile.gettempdir()).resolve() and profile.name.startswith('mpv-yaozhi-douyin-'):
            shutil.rmtree(profile,ignore_errors=True)
        stop_file.unlink(missing_ok=True)


def main(argv=None):
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--room-url',required=True);parser.add_argument('--output',required=True)
    parser.add_argument('--timeout',type=float,default=10)
    parser.add_argument('--max-runtime',type=float,default=0)
    parser.add_argument('--max-reconnects',type=int,default=3)
    args=parser.parse_args(argv)
    emitter=JsonlEmitter(Path(args.output),100);emitter.status('connecting')
    try: url=room_url(args.room_url)
    except Exception: emitter.status('unavailable','invalid_room');return 2
    deadline=time.monotonic()+args.max_runtime if args.max_runtime>0 else None
    attempts=max(0,min(5,args.max_reconnects))+1
    for attempt in range(attempts):
        if Path(str(args.output)+'.stop').exists(): return 0
        try:
            receive(url,emitter,max(5,min(20,args.timeout)),deadline);return 0
        except KeyboardInterrupt: return 0
        except Exception as error:
            if (deadline and time.monotonic()>=deadline) or attempt+1>=attempts:
                emitter.status('unavailable',type(error).__name__);return 4
            emitter.status('reconnecting');time.sleep(min(2*(attempt+1),5))
    return 4

if __name__=='__main__':sys.exit(main())
