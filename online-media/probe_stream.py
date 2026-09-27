#!/usr/bin/env python3
"""清晰度无缝切换用的线路预验证。

解析器给出的签名 URL 在真正打开之前不会暴露 403 / 签名过期 / CDN 拒绝，
所以单纯「解析成功」不等于「这条线能播」。切档时如果不能提前发现，用户看到
的就是黑屏之后弹一句失败。这里用一次极小的 Range 请求确认真能拿到数据，
验证不通过的线路直接跳过，当前播放完全不被打断。

method = "HEAD" 是给**一次性 URL** 的平台用的（目前只有斗鱼）。斗鱼的签名
媒体 URL 被连接过一次之后，第二次连接会被 CDN 吐掉一小段缓冲后立刻结束——
与间隔无关（实测 0 / 2 / 5 秒一样），只读 64 KB 就足以触发。而切档路径正是
「用这条 URL 验证 → 播放器再用同一条 URL 播放」，所以新流必然在约 150 ms 内
被结束。HEAD 不传输 body、CDN 也不把它计入「已服务」（实测连发两次 HEAD 之后
仍能正常播放），代价是只能确认**边缘节点可达**：TLS / DNS / 超时 / 连接被拒
都认得出，但「有响应却不吐流」的线路认不出（HEAD 对不存在的路径和篡改过的
签名同样回 200，只有 GET 会断）。那类线路本就由解析器筛掉，这里不为它牺牲
「URL 必须留到播放那一刻」。

用法:
    python.exe probe_stream.py --request <请求JSON路径>

请求 JSON（放在文件里而不是命令行，避免签名 URL 出现在进程列表里）:
    {
      "url": "https://...",
      "headers": {"User-Agent": "...", "Referer": "..."},
      "proxy": "",
      "insecure": true,
      "timeout": 6,
      "bytes": 65536,
      "method": "GET",
      "audio_url": "",
      "audio_headers": {}
    }

输出 JSON（**只含主机名，不含完整地址**——地址里带鉴权串）:
    {"ok": true, "status": 206, "bytes": 65536, "method": "get", "host": "..."}
    {"ok": false, "reason": "http_403", "status": 403, "host": "..."}

reason 取值：http_<状态码> / timeout / network / empty_response / invalid_url
"""

import json
import socket
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

# 只报主机名。签名 URL 的查询串是即时的鉴权凭据，不该出现在任何输出里。
DEFAULT_BYTES = 65536
DEFAULT_TIMEOUT = 6.0


def host_of(url):
    try:
        return urlsplit(url).hostname or ""
    except ValueError:
        return ""


def build_opener(proxy, insecure):
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    else:
        # 路线由 Lua 侧显式决定（与 apply_candidate 同一套规则），不要因为环境
        # 变量里恰好有代理就改走另一条路——那会让验证结果和实际播放不一致。
        handlers.append(urllib.request.ProxyHandler({}))
    context = ssl.create_default_context()
    # 有些 CDN 只支持静态 RSA 密钥交换的 AES256-GCM-SHA384（斗鱼 edgesrv.com 全线
    # 如此），而 OpenSSL 3.x 把静态 RSA 套件移出了默认列表：create_default_context()
    # 给出的十几个套件里一个都没有，ClientHello 一发出去就被服务器回 alert 40。
    # 探针把它记成 "network"，与真正的网络故障分不开——症状是该档位的线路「全都没能
    # 通过验证」，而 mpv 自己播得好好的（播放器走 ffmpeg 的 TLS 栈，允许静态 RSA）。
    # 显式要一份 OpenSSL 的默认列表即可；证书校验强度由 verify_mode 决定，与套件
    # 支不支持前向保密无关。
    context.set_ciphers("DEFAULT")
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    handlers.append(urllib.request.HTTPSHandler(context=context))
    return urllib.request.build_opener(*handlers)


def probe(url, headers, opener, timeout, want, method="GET"):
    """GET：读一小段就断开，拿到任意字节即视为这条线可用。
    HEAD：不建立数据会话，2xx 即视为边缘节点可达（没有 body 可读）。"""
    head = str(method or "").strip().lower() == "head"
    request = urllib.request.Request(url)
    if isinstance(headers, dict):
        for key, value in headers.items():
            if isinstance(key, str) and isinstance(value, str) and value != "":
                request.add_header(key, value)
    if head:
        request.get_method = lambda: "HEAD"
    elif not request.has_header("Range"):
        request.add_header("Range", "bytes=0-%d" % max(0, want - 1))

    try:
        with opener.open(request, timeout=timeout) as response:
            chunk = response.read(want)
            status = getattr(response, "status", None) or response.getcode()
        if head:
            if status and 200 <= status < 300:
                return {"ok": True, "status": status, "bytes": 0, "method": "head",
                        "host": host_of(url)}
            return _fail(url, "http_%d" % (status or 0), status or 0)
        if not chunk:
            return _fail(url, "empty_response", status or 0)
        return {"ok": True, "status": status, "bytes": len(chunk), "method": "get",
                "host": host_of(url)}
    except urllib.error.HTTPError as exc:
        return _fail(url, "http_%d" % exc.code, exc.code)
    except urllib.error.URLError as exc:
        reason = exc.reason
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return _fail(url, "timeout", 0)
        return _fail(url, "network", 0)
    except (TimeoutError, socket.timeout):
        return _fail(url, "timeout", 0)
    except Exception:  # noqa: BLE001 - 兜底，任何异常都只是「这条线没通过」
        return _fail(url, "network", 0)


def _fail(url, reason, status):
    return {"ok": False, "reason": reason, "status": status, "bytes": 0, "host": host_of(url)}


def main(argv):
    if "--request" not in argv:
        print(json.dumps({"ok": False, "reason": "invalid_url", "host": ""}))
        return 2
    try:
        payload = json.loads(Path(argv[argv.index("--request") + 1]).read_text(encoding="utf-8"))
    except Exception:
        print(json.dumps({"ok": False, "reason": "invalid_url", "host": ""}))
        return 0

    url = str(payload.get("url") or "")
    if not url.startswith(("http://", "https://")):
        print(json.dumps({"ok": False, "reason": "invalid_url", "host": ""}))
        return 0

    timeout = float(payload.get("timeout") or DEFAULT_TIMEOUT)
    want = int(payload.get("bytes") or DEFAULT_BYTES)
    opener = build_opener(str(payload.get("proxy") or ""), payload.get("insecure") is True)

    result = probe(url, payload.get("headers"), opener, timeout, want,
                   str(payload.get("method") or "GET"))

    # YouTube 的 DASH 音视频是两条独立请求，只验证视频轨等于没验证：音频轨
    # 失效时同样会黑屏。两条都通过才算这条线可用。音频轨固定用 GET——需要
    # HEAD 的是一次性 URL 的直播，那里没有独立音轨。
    audio = str(payload.get("audio_url") or "")
    if result["ok"] and audio.startswith(("http://", "https://")):
        audio_result = probe(audio, payload.get("audio_headers") or payload.get("headers"),
                             opener, timeout, want)
        if not audio_result["ok"]:
            audio_result["track"] = "audio"
            result = audio_result
        else:
            result["audio_bytes"] = audio_result["bytes"]

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    sys.exit(main(sys.argv[1:]))
