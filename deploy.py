#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mpv-Emo 三平台部署自检与运行时准备。

只在仓库根目录运行（脚本用自身的绝对路径定位仓库，不依赖当前目录）。
仅使用 Python 标准库，Python 3.9+。

用法：
    python3 deploy.py                  # 检测 + 准备（等价 --check --prepare）
    python3 deploy.py --check          # 只检测，不写任何文件
    python3 deploy.py --prepare        # 创建缺失运行时目录
    python3 deploy.py --fonts-dir PATH # 显式指定用户字体目录（Linux/Win/macOS）
    python3 deploy.py --skip-fonts     # 跳过字重复制（默认会按需复制，目录已入 .gitignore）
    python3 deploy.py --json           # 机器可读输出（stdout 只有 JSON）

退出码：
    0 = 关键依赖齐备，或仅有可选项降级/未验证
    2 = 关键依赖缺失（mpv 不可用，或解释器版本低于 3.9）

三态口径（外加 unverified）：
    available   = 已有命令输出/文件事实确认可用
    degraded    = 部分可用：缺可选项、只命中兜底路径，或需要按平台重建
    unavailable = 明确不可用（未安装 / 目录不存在）
    unverified  = 本机无法验证（跨平台能力、需要真实窗口或驱动才能确认）

本脚本不写入仓库配置，不改 mpv.conf / fonts 既有文件，不触碰 git。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent

EXIT_OK = 0
EXIT_CRITICAL = 2

STATUSES = ("available", "degraded", "unavailable", "unverified")
SEVERITY = {"available": 0, "unverified": 1, "degraded": 2, "unavailable": 3}
BADGE = {
    "available": "[可用]",
    "degraded": "[降级]",
    "unavailable": "[缺失]",
    "unverified": "[未验]",
}

EXPECTED_WEIGHTS = ("200.ttf", "300.ttf", "400.ttf", "700.ttf")
FONT_FAMILY = "MFGA YouHei"

# 运行时目录：路径 → 依据（都来自仓库内实际配置，不凭空创建）
RUNTIME_DIRS = (
    ("cache", "mpv 运行时缓存根目录（.gitignore 已忽略）"),
    ("files", "播放历史 / 书签 / 截图等运行时数据根目录（.gitignore 已忽略）"),
    ("cache/shaders_cache", "mpv.conf:236 gpu-shader-cache-dir"),
    ("cache/icc_cache", "mpv.conf:341/348 icc-cache-dir"),
    ("files/screen", "mpv.conf:228 screenshot-template=~~/files/screen/…"),
)

DEFAULT_TIMEOUT = 8


# --------------------------------------------------------------------------
# 基础工具
# --------------------------------------------------------------------------


class Runner:
    """带超时的外部命令执行器，永不抛异常（失败信息放进结果里）。"""

    def __init__(self, timeout=DEFAULT_TIMEOUT):
        self.timeout = timeout
        self.calls = 0

    def run(self, args, timeout=None):
        self.calls += 1
        path = shutil.which(args[0]) if not os.path.isabs(args[0]) else args[0]
        if not path:
            return {"ok": False, "rc": None, "out": "", "missing": True, "cmd": args[0]}
        try:
            proc = subprocess.run(
                [path] + list(args[1:]),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout or self.timeout,
            )
        except subprocess.TimeoutExpired:
            return {"ok": False, "rc": None, "out": "", "timeout": True, "cmd": args[0]}
        except OSError as exc:  # 权限、解释器损坏等
            return {"ok": False, "rc": None, "out": str(exc), "error": True, "cmd": args[0]}
        out = proc.stdout.decode("utf-8", "replace")
        return {"ok": proc.returncode == 0, "rc": proc.returncode, "out": out, "cmd": args[0]}


def display_width(text):
    """终端显示宽度：CJK/全角按 2 列算，避免中文标签把对齐拉歪。"""
    import unicodedata

    width = 0
    for ch in text:
        width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return width


def pad_right(text, width):
    return text + " " * max(0, width - display_width(text))


def first_line(text):
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()
    return ""


def item(item_id, label, status, detail, evidence="", informational=False, critical=False):
    assert status in STATUSES, status
    return {
        "id": item_id,
        "label": label,
        "status": status,
        "detail": detail,
        "evidence": evidence,
        "informational": informational,
        "critical": critical,
    }


# --------------------------------------------------------------------------
# 1. 平台与会话
# --------------------------------------------------------------------------


def detect_session(system):
    """返回 {'kind','desktop','raw'}；kind ∈ wayland/x11/windows/macos/unknown。"""
    desktop = os.environ.get("XDG_CURRENT_DESKTOP") or os.environ.get("DESKTOP_SESSION") or ""
    if system == "Windows":
        return {"kind": "windows", "desktop": desktop, "raw": "Windows 会话（不可判定图形协议）"}
    if system == "Darwin":
        return {"kind": "macos", "desktop": desktop, "raw": "macOS Aqua（未实测）"}
    stype = (os.environ.get("XDG_SESSION_TYPE") or "").strip().lower()
    wayland = bool(os.environ.get("WAYLAND_DISPLAY"))
    x11 = bool(os.environ.get("DISPLAY"))
    if stype == "wayland" or (not stype and wayland):
        kind = "wayland"
    elif stype == "x11" or (not stype and x11):
        kind = "x11"
    elif wayland:
        kind = "wayland"
    elif x11:
        kind = "x11"
    else:
        kind = "unknown"
    raw = "XDG_SESSION_TYPE=%s WAYLAND_DISPLAY=%s DISPLAY=%s" % (
        stype or "-",
        os.environ.get("WAYLAND_DISPLAY") or "-",
        os.environ.get("DISPLAY") or "-",
    )
    return {"kind": kind, "desktop": desktop, "raw": raw}


def detect_platform(session):
    system = platform.system()
    machine = platform.machine()
    kind = session["kind"]
    desktop = session["desktop"]
    if kind == "wayland":
        detail = "%s/%s，会话 wayland%s" % (system, machine, " (%s)" % desktop if desktop else "")
    elif kind == "x11":
        detail = "%s/%s，会话 X11%s" % (system, machine, " (%s)" % desktop if desktop else "")
    elif kind == "unknown":
        detail = "%s/%s，会话类型无法判定（无 XDG_SESSION_TYPE / WAYLAND_DISPLAY / DISPLAY）" % (
            system,
            machine,
        )
    else:
        detail = "%s/%s，%s" % (system, machine, session["raw"])
    return item("platform", "平台", "available", detail, session["raw"])


# --------------------------------------------------------------------------
# 2. mpv：可执行文件、版本、硬解后端、渲染能力
# --------------------------------------------------------------------------


def detect_mpv(runner):
    path = shutil.which("mpv") or shutil.which("mpv.exe")
    if not path:
        return item(
            "mpv",
            "mpv",
            "unavailable",
            "PATH 中找不到 mpv；播放器本身不可用，其余检测仅供参考",
            "shutil.which('mpv') -> None",
            critical=True,
        )
    res = runner.run(["mpv", "--version"])
    version = ""
    if res["ok"]:
        version = first_line(res["out"])
    m = re.search(r"mpv\s+(v[\w.\-]+)", version)
    ver = m.group(1) if m else "版本未知"
    extra = []
    for line in (res["out"] or "").splitlines()[1:]:
        if re.search(r"libplacebo|FFmpeg version", line):
            extra.append(line.strip())
    detail = "%s · %s" % (path, ver)
    if extra:
        detail += " · " + " · ".join(extra)
    return item("mpv", "mpv", "available", detail, first_line(res["out"]))


def parse_hwdec_help(text):
    """从 `mpv --hwdec=help` 解析硬解后端，返回 (基础后端, copy 变体)。"""
    base, copy_variants = set(), set()
    skip = {
        "no",
        "auto",
        "auto-safe",
        "auto-copy",
        "auto-copy-safe",
        "auto-copy-unsafe",
        "auto-unsafe",
        "yes",
    }
    for line in (text or "").splitlines():
        m = re.match(r"^\s{2,}([a-zA-Z0-9][\w\-]*)\b", line)
        if not m:
            continue
        token = m.group(1)
        if token in skip:
            continue
        if token.endswith("-copy"):
            copy_variants.add(token)
            base.add(token[: -len("-copy")])
        else:
            base.add(token)
    return sorted(base), sorted(copy_variants)


def detect_hwdec(runner):
    res = runner.run(["mpv", "--hwdec=help"])
    if not res["ok"]:
        return item(
            "hwdec",
            "硬解后端",
            "unverified",
            "mpv --hwdec=help 执行失败，无法枚举硬解后端",
            first_line(res["out"]),
        )
    base, copies = parse_hwdec_help(res["out"])
    if not base:
        return item("hwdec", "硬解后端", "unavailable", "mpv 未编译任何硬解后端", "空列表")
    detail = "%d 个后端：%s" % (len(base), ", ".join(base))
    if copies:
        detail += "（另有 %d 个 -copy 变体）" % len(copies)
    return item(
        "hwdec",
        "硬解后端",
        "available",
        detail,
        "mpv --hwdec=help（编译期列表，不等于运行时可用）",
    )


def detect_hwdec_runtime(runner, session, system):
    probes = []
    if shutil.which("nvidia-smi"):
        res = runner.run(
            ["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"], timeout=6
        )
        if res["ok"] and res["out"].strip():
            probes.append("nvidia-smi: %s" % first_line(res["out"]))
        else:
            probes.append("nvidia-smi 存在但查询失败")
    if system == "Linux" and shutil.which("vainfo"):
        res = runner.run(["vainfo"], timeout=6)
        if res["ok"]:
            drivers = re.findall(r"Driver version:\s*(.+)", res["out"])
            probes.append("vainfo 可用%s" % ("（Driver version: %s）" % drivers[0].strip() if drivers else ""))
        else:
            probes.append("vainfo 调用失败（无 VAAPI 驱动或权限不足）")
    evidence = "；".join(probes) or "无驱动探测工具"
    return item(
        "hwdec_runtime",
        "硬解运行时",
        "unverified",
        "硬解后端列表只证明编译进 mpv，不证明驱动能解码。"
        "无窗口的 --vo=null 不接受硬解帧（实测日志出现 'DR failed - disabling'），"
        "真实硬解需在有窗口的会话里按片源实测",
        evidence,
    )


def parse_option_help(text):
    names = []
    for line in (text or "").splitlines():
        m = re.match(r"^\s{2,}(\S+)\s{2,}\S", line)
        if m:
            names.append(m.group(1))
    return names


def detect_render(runner, session, system):
    vo_res = runner.run(["mpv", "--vo=help"])
    ctx_res = runner.run(["mpv", "--gpu-context=help"])
    vos = parse_option_help(vo_res["out"])
    ctxs = parse_option_help(ctx_res["out"])
    evidence = "mpv --vo=help / mpv --gpu-context=help"
    if not vos:
        return item(
            "render", "视频输出", "unavailable", "mpv 未编译任何 vo", evidence
        )
    if "gpu-next" not in vos:
        return item(
            "render",
            "视频输出",
            "degraded",
            "vo 列表中没有 gpu-next（当前配置 vo=gpu-next 会失败）；可用 vo：%s" % ", ".join(vos),
            evidence,
        )
    ctx_list = ", ".join(ctxs) if ctxs else "（空）"
    if system != "Linux":
        return item(
            "render",
            "视频输出",
            "unverified",
            "vo=gpu-next 在列；gpu-context 需按目标平台实测（Windows 常见 winvk/d3d11，"
            "macOS 只有 cocoa）。本机列表：%s" % ctx_list,
            evidence,
        )
    preferred = "waylandvk" if session["kind"] == "wayland" else "x11vk"
    if session["kind"] not in ("wayland", "x11"):
        return item(
            "render",
            "视频输出",
            "unverified",
            "vo=gpu-next 在列，但会话类型无法判定，未确认能创建 %s 上下文" % preferred,
            evidence,
        )
    if preferred in ctxs:
        return item(
            "render",
            "视频输出",
            "available",
            "vo=gpu-next + gpu-context=%s（会话 %s，上下文在 mpv 列表中）；"
            "未打开窗口做逐帧实测" % (preferred, session["kind"]),
            evidence,
        )
    return item(
        "render",
        "视频输出",
        "degraded",
        "会话是 %s，但 mpv 的 gpu-context 列表里没有 %s；可用：%s"
        % (session["kind"], preferred, ctx_list),
        evidence,
    )


# --------------------------------------------------------------------------
# 3. 外部工具
# --------------------------------------------------------------------------


def detect_tool(runner, label, argv, exec_id):
    path = shutil.which(argv[0]) or (shutil.which(argv[0] + ".exe") if os.name == "nt" else None)
    if not path:
        return item(exec_id, label, "unavailable", "PATH 中找不到 %s" % argv[0], "shutil.which -> None")
    res = runner.run(argv)
    if not res["ok"]:
        return item(
            exec_id, label, "degraded", "%s 存在但 `%s` 执行失败" % (path, " ".join(argv)), first_line(res["out"])
        )
    return item(exec_id, label, "available", "%s · %s" % (path, first_line(res["out"])), " ".join(argv))


def detect_python():
    ver = "%d.%d.%d" % sys.version_info[:3]
    status = "available" if sys.version_info >= (3, 9) else "unavailable"
    detail = "%s · Python %s" % (sys.executable, ver)
    if status != "available":
        detail += "（部署脚本要求 3.9+）"
    return item("python", "Python", status, detail, "sys.version_info", critical=(status != "available"))


# --------------------------------------------------------------------------
# 4. 音频与剪贴板
# --------------------------------------------------------------------------


def detect_audio(runner, system, mpv_ao_list):
    if system == "Windows":
        return item(
            "audio",
            "音频后端",
            "unverified",
            "platform.conf 只声明 wasapi；本机无法验证（构建特性里 wasapi=disabled，属于跨平台声明）",
            "platform.conf [platform-windows] ao=wasapi",
        )
    if system == "Darwin":
        return item(
            "audio",
            "音频后端",
            "unverified",
            "platform.conf 只声明 coreaudio；本机无法验证（本构建 coreaudio=disabled）",
            "platform.conf [platform-macos] ao=coreaudio",
        )
    ao_note = "mpv ao 列表：%s" % (", ".join(mpv_ao_list) if mpv_ao_list else "（未知）")
    if shutil.which("pactl"):
        res = runner.run(["pactl", "info"], timeout=6)
        if res["ok"]:
            server = ""
            m = re.search(r"Server Name:\s*(.+)", res["out"])
            if m:
                server = m.group(1).strip()
            if "pipewire" in res["out"].lower():
                return item(
                    "audio",
                    "音频后端",
                    "available",
                    "PipeWire 已确认：%s" % server,
                    "pactl info；%s" % ao_note,
                )
            return item(
                "audio",
                "音频后端",
                "degraded",
                "只检测到 PulseAudio（%s），未确认 PipeWire；配置里 ao=pipewire 会回落到 pulse"
                % (server or "服务器名未知"),
                "pactl info；%s" % ao_note,
            )
        # pactl 在但查询失败 → 继续尝试 pw-cli
    if shutil.which("pw-cli"):
        res = runner.run(["pw-cli", "ls", "Node"], timeout=6)
        if res["ok"]:
            return item(
                "audio",
                "音频后端",
                "available",
                "pw-cli 可用（PipeWire 在跑），但 pactl 缺失/失败 → 音量与设备脚本可能降级",
                "pw-cli ls Node；%s" % ao_note,
            )
    return item(
        "audio",
        "音频后端",
        "unavailable",
        "未检测到 PipeWire 或 PulseAudio（pactl / pw-cli 均不可用）",
        ao_note,
    )


def detect_clipboard(system, session):
    if system == "Windows":
        return item(
            "clipboard",
            "剪贴板",
            "unverified",
            "使用 PowerShell Get-Clipboard / Set-Clipboard（extended-menu.lua:783、"
            "uosc/lib/utils.lua:640），未在 Windows 实测",
            "仓库脚本内 PowerShell 分支",
        )
    if system == "Darwin":
        return item(
            "clipboard",
            "剪贴板",
            "unverified",
            "pbcopy/pbpaste（extended-menu.lua:808）与 osascript（screenshot-to-clipboard.lua:116），"
            "未在 macOS 实测",
            "仓库脚本内 darwin 分支",
        )
    wl = [cmd for cmd in ("wl-copy", "wl-paste") if shutil.which(cmd)]
    xclip = shutil.which("xclip")
    if session["kind"] == "wayland":
        if len(wl) == 2:
            extra = "；xclip 也在（X11 兼容兜底）" if xclip else ""
            return item(
                "clipboard",
                "剪贴板",
                "available",
                "Wayland: wl-copy + wl-paste 均在 PATH%s" % extra,
                "shutil.which('wl-copy'/'wl-paste')",
            )
        return item(
            "clipboard",
            "剪贴板",
            "degraded",
            "会话是 Wayland，但只找到 %s；uosc 复制（wl-copy）与粘贴（wl-paste）需要两者"
            % (", ".join(wl) or "0 个"),
            "shutil.which('wl-copy'/'wl-paste')",
        )
    if session["kind"] == "x11":
        if xclip:
            return item(
                "clipboard",
                "剪贴板",
                "available",
                "X11: xclip 在 PATH",
                "shutil.which('xclip')",
            )
        return item(
            "clipboard", "剪贴板", "unavailable", "会话是 X11，但没有 xclip", "shutil.which('xclip') -> None"
        )
    both = bool(xclip) and len(wl) == 2
    return item(
        "clipboard",
        "剪贴板",
        "unverified" if both else "degraded",
        "会话类型无法判定；wl-copy/wl-paste=%d/2，xclip=%s" % (len(wl), "有" if xclip else "无"),
        "shutil.which",
    )


# --------------------------------------------------------------------------
# 5. GPU（辅助证据，不是硬解结论）
# --------------------------------------------------------------------------


def detect_gpu(runner, system):
    if system == "Darwin":
        return item("gpu", "GPU", "unverified", "Apple Silicon/AMD 无 nvidia-smi，GPU 能力待实测", "—")
    if shutil.which("nvidia-smi"):
        res = runner.run(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"], timeout=6)
        if res["ok"] and res["out"].strip():
            return item(
                "gpu",
                "GPU",
                "available",
                "%s（驱动信息来自 nvidia-smi，本身不证明 mpv 硬解可用）" % first_line(res["out"]),
                "nvidia-smi",
            )
        return item("gpu", "GPU", "unverified", "nvidia-smi 存在但查询失败", first_line(res["out"]))
    return item(
        "gpu",
        "GPU",
        "unverified",
        "无 nvidia-smi（非 NVIDIA 或未装驱动工具）；GPU 由 Vulkan/VAAPI 侧决定，未探测",
        "—",
    )


# --------------------------------------------------------------------------
# 6. RIFE / 补帧
# --------------------------------------------------------------------------


def python_module_info():
    """在当前解释器里探测模块，返回 {name: {'found':bool,'where':str}}。"""
    out = {}
    for name in ("vapoursynth", "vsmlrt", "tensorrt", "onnxruntime"):
        try:
            spec = importlib.util.find_spec(name)
        except (ImportError, ValueError):
            spec = None
        where = ""
        if spec:
            where = spec.origin or ",".join(spec.submodule_search_locations or []) or "built-in"
        out[name] = {"found": bool(spec), "where": where}
    return out


def detect_rife():
    rife_lua = REPO / "scripts" / "rife.lua"
    ai_lua = REPO / "scripts" / "ai-interpolation.lua"
    vs_dir = REPO / "vs"
    vpy = sorted(p.name for p in vs_dir.glob("*.vpy")) if vs_dir.is_dir() else []
    mods = python_module_info()
    evidence_bits = []
    evidence_bits.append("scripts/rife.lua %s" % ("存在" if rife_lua.is_file() else "缺失"))
    if ai_lua.is_file():
        evidence_bits.append("scripts/ai-interpolation.lua 存在")
    evidence_bits.append("vs/*.vpy %d 个" % len(vpy))
    if mods["vapoursynth"]["found"]:
        evidence_bits.append("vapoursynth 可导入（%s）" % mods["vapoursynth"]["where"])
        plugin_dir = Path(mods["vapoursynth"]["where"]).parent / "plugins"
        vsmlrt_py = plugin_dir / "vsmlrt.py"
        evidence_bits.append("vsmlrt.py %s" % ("存在" if vsmlrt_py.is_file() else "缺失（%s）" % plugin_dir))
    else:
        evidence_bits.append("vapoursynth 不可导入")
    evidence_bits.append("tensorrt %s" % ("可导入" if mods["tensorrt"]["found"] else "不可导入"))
    evidence = "；".join(evidence_bits)

    have_script = rife_lua.is_file() or ai_lua.is_file()
    have_vs = mods["vapoursynth"]["found"]
    have_vsmlrt = mods["vsmlrt"]["found"]
    if not have_script:
        return item("rife", "RIFE 补帧", "unavailable", "仓库里没有 scripts/rife.lua，补帧入口不存在", evidence)
    if not have_vs:
        return item(
            "rife",
            "RIFE 补帧",
            "degraded",
            "rife.lua 在，但当前 Python 无法 import vapoursynth → CTRL+ALT+r 补帧不可用",
            evidence,
        )
    if not have_vsmlrt:
        return item(
            "rife",
            "RIFE 补帧",
            "degraded",
            "rife.lua 在、vapoursynth 可导入，但 vsmlrt 模块缺失 → 补帧与 AI 超分不可用"
            "（需 vapoursynth-plugin-mlrt-*-runtime，TensorRT 后端还要求本机 TensorRT）",
            evidence,
        )
    return item(
        "rife",
        "RIFE 补帧",
        "available",
        "rife.lua + vapoursynth + vsmlrt 齐备；具体后端（ncnn/ort_cuda/trt）仍需按显卡实测",
        evidence,
    )


# --------------------------------------------------------------------------
# 7. 字体
# --------------------------------------------------------------------------


def default_font_dirs(system):
    home = Path.home()
    if system == "Windows":
        local = os.environ.get("LOCALAPPDATA")
        dirs = []
        if local:
            dirs.append(Path(local) / "Microsoft" / "Windows" / "Fonts" / "MFGA")
        dirs.append(Path("C:/Windows/Fonts/MFGA"))
        return dirs
    if system == "Darwin":
        return [home / "Library" / "Fonts" / "MFGA", Path("/Library/Fonts/MFGA")]
    return [home / ".local" / "share" / "fonts" / "MFGA", home / ".fonts" / "MFGA"]


def scan_weights(directory):
    """返回 (found: {weight: Path}, missing: [weight])。目录不存在时全缺。"""
    found = {}
    if directory and directory.is_dir():
        for path in sorted(directory.iterdir()):
            if path.is_file() and path.name.lower() in EXPECTED_WEIGHTS:
                found[path.name.lower()] = path
    missing = [w for w in EXPECTED_WEIGHTS if w not in found]
    return found, missing


def detect_fonts_user(runner, system, explicit_dir):
    candidates = [explicit_dir] if explicit_dir else default_font_dirs(system)
    chosen = None
    for cand in candidates:
        found, missing = scan_weights(cand)
        if len(found) == len(EXPECTED_WEIGHTS):
            chosen = (cand, found, missing)
            break
        if chosen is None and found:
            chosen = (cand, found, missing)
    if chosen is None:
        detail = "用户字体目录里没有预期字重：%s" % "、".join(EXPECTED_WEIGHTS)
        if explicit_dir:
            detail = "显式目录 %s 不存在或没有预期字重（%s）" % (explicit_dir, "、".join(EXPECTED_WEIGHTS))
        return item(
            "fonts_user",
            "用户字体",
            "unavailable",
            detail + "；MFGA YouHei 会静默回退到任意可用字体，mpv 不报错",
            "查找路径：%s" % "、".join(str(c) for c in candidates),
            informational=False,
        ), None
    cand, found, missing = chosen
    total = sum(p.stat().st_size for p in found.values())
    evidence = "目录 %s；合计 %.1f MiB" % (cand, total / (1024.0 * 1024.0))
    if missing:
        return item(
            "fonts_user",
            "用户字体",
            "degraded",
            "%s 缺 %s → 缺失字重会回退，UI/字幕字重不一致" % (cand, "、".join(missing)),
            evidence,
        ), (cand, found, missing)
    detail = "%s 四个字重齐备（%s）" % (cand, "、".join(EXPECTED_WEIGHTS))
    if system == "Linux" and shutil.which("fc-match"):
        res = runner.run(["fc-match", FONT_FAMILY], timeout=6)
        if res["ok"] and FONT_FAMILY.lower() in res["out"].lower():
            detail += "；fc-match '%s' 可解析" % FONT_FAMILY
            evidence += "；fc-match: %s" % first_line(res["out"])
        else:
            detail += "；fc-match 未解析到 %s（fontconfig 可能回退）" % FONT_FAMILY
            evidence += "；fc-match: %s" % first_line(res["out"])
    return item("fonts_user", "用户字体", "available", detail, evidence), (cand, found, missing)


def detect_fonts_repo():
    repo_dir = REPO / "fonts" / "MFGA"
    found, missing = scan_weights(repo_dir)
    if not repo_dir.is_dir():
        return item(
            "fonts_repo",
            "仓库字体",
            "unavailable",
            "仓库内无 fonts/MFGA/（设计如此：整块模块约 237 MB，四个字重约 126 MiB，不入库）",
            str(repo_dir),
            informational=True,
        )
    if missing:
        return item(
            "fonts_repo",
            "仓库字体",
            "degraded",
            "fonts/MFGA/ 存在但缺 %s（部分拷贝）" % "、".join(missing),
            str(repo_dir),
            informational=True,
        )
    return item(
        "fonts_repo",
        "仓库字体",
        "available",
        "fonts/MFGA/ 四个字重齐备；注意 mpv 会从 ~~/fonts 加载，但入库前必须确认授权",
        str(repo_dir),
        informational=True,
    )


# --------------------------------------------------------------------------
# 8. 在线媒体 venv
# --------------------------------------------------------------------------


def venv_python(runtime_dir):
    if os.name == "nt" or platform.system() == "Windows":
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python3"


def detect_online_media(runner):
    runtime_dir = REPO / "online-media" / "runtime"
    manifest_path = REPO / "online-media" / "runtime-manifest.json"
    py = venv_python(runtime_dir)
    if not py.is_file():
        return item(
            "online_media_runtime",
            "在线媒体 venv",
            "degraded",
            "缺少 %s；在线媒体 resolver 需要按当前平台重建："
            "python3 -m venv online-media/runtime && online-media/runtime/bin/pip install -r …" % py,
            str(py),
        )
    res = runner.run([str(py), "-c", "import sys;print(sys.version.split()[0])"], timeout=8)
    version = first_line(res["out"]) if res["ok"] else "无法执行"
    manifest_arch = ""
    if manifest_path.is_file():
        try:
            manifest_arch = json.loads(manifest_path.read_text(encoding="utf-8")).get("architecture", "")
        except (ValueError, OSError):
            manifest_arch = ""
    system = platform.system()
    local_arch = {
        "Linux": "linux",
        "Darwin": "macos",
        "Windows": "windows",
    }.get(system, system.lower()) + "-" + platform.machine().lower()
    evidence = "%s；manifest architecture=%s；本机=%s" % (py, manifest_arch or "未知", local_arch)
    if manifest_arch and manifest_arch.lower() not in (local_arch, local_arch.replace("x86_64", "amd64")):
        return item(
            "online_media_runtime",
            "在线媒体 venv",
            "degraded",
            "venv 可执行（Python %s），但 manifest 声明 %s，本机是 %s → 该 venv 必须按平台重建，"
            "不能跨平台复用" % (version, manifest_arch, local_arch),
            evidence,
        )
    if not res["ok"]:
        return item(
            "online_media_runtime",
            "在线媒体 venv",
            "degraded",
            "venv 的 python 存在但无法执行，需重建",
            evidence,
        )
    return item(
        "online_media_runtime",
        "在线媒体 venv",
        "available",
        "venv 可执行（Python %s），manifest 与本机架构一致" % version,
        evidence,
    )


# --------------------------------------------------------------------------
# 9. 运行时目录
# --------------------------------------------------------------------------


def detect_runtime_dirs():
    missing = [(rel, why) for rel, why in RUNTIME_DIRS if not (REPO / rel).is_dir()]
    if not missing:
        return item(
            "runtime_dirs",
            "运行时目录",
            "available",
            "%d 个目录齐备（%s）" % (len(RUNTIME_DIRS), "、".join(rel for rel, _ in RUNTIME_DIRS)),
            "逐目录 is_dir() 检查",
        )
    return item(
        "runtime_dirs",
        "运行时目录",
        "degraded",
        "缺 %d 个：%s；`--prepare` 会创建（已存在的跳过）"
        % (len(missing), "、".join(rel for rel, _ in missing)),
        "；".join("%s → %s" % (rel, why) for rel, why in missing),
    )


# --------------------------------------------------------------------------
# 检测总入口
# --------------------------------------------------------------------------


def detect_all(runner, system, session, explicit_fonts_dir):
    ao_res = runner.run(["mpv", "--ao=help"])
    ao_list = parse_option_help(ao_res["out"])
    fonts_item, fonts_state = detect_fonts_user(runner, system, explicit_fonts_dir)
    items = [
        detect_platform(session),
        detect_mpv(runner),
        detect_hwdec(runner),
        detect_hwdec_runtime(runner, session, system),
        detect_render(runner, session, system),
        detect_gpu(runner, system),
        detect_audio(runner, system, ao_list),
        detect_clipboard(system, session),
        detect_tool(runner, "Git", ["git", "--version"], "git"),
        detect_tool(runner, "yt-dlp", ["yt-dlp", "--version"], "ytdlp"),
        detect_tool(runner, "Deno", ["deno", "--version"], "deno"),
        detect_python(),
        detect_rife(),
        fonts_item,
        detect_fonts_repo(),
        detect_online_media(runner),
        detect_runtime_dirs(),
    ]
    return items, fonts_state


def summarize(items):
    counts = {status: 0 for status in STATUSES}
    for entry in items:
        counts[entry["status"]] += 1
    actionable = [e for e in items if not e["informational"] and not e["critical"]]
    worst = "available"
    for entry in actionable:
        if SEVERITY[entry["status"]] > SEVERITY[worst]:
            worst = entry["status"]
    critical_missing = [e["id"] for e in items if e["critical"] and e["status"] != "available"]
    return {
        "counts": counts,
        "worst_optional": worst,
        "critical_missing": critical_missing,
        "exit_code": EXIT_CRITICAL if critical_missing else EXIT_OK,
    }


# --------------------------------------------------------------------------
# 准备
# --------------------------------------------------------------------------


def prepare(runner, args, fonts_state, system):
    actions = {"dirs": [], "fonts": None, "created": 0, "skipped": 0}

    for rel, why in RUNTIME_DIRS:
        target = REPO / rel
        if target.is_dir():
            actions["dirs"].append({"path": rel, "action": "exists", "note": "已存在，跳过"})
            actions["skipped"] += 1
            continue
        try:
            target.mkdir(parents=True, exist_ok=True)
            actions["dirs"].append({"path": rel, "action": "created", "note": why})
            actions["created"] += 1
        except OSError as exc:
            actions["dirs"].append({"path": rel, "action": "error", "note": str(exc)})

    dest = REPO / "fonts" / "MFGA"
    if args.skip_fonts:
        actions["fonts"] = {
            "action": "skip",
            "reason": "按 --skip-fonts 跳过字重复制（四个字重约 126 MiB；fonts/MFGA/ 已进 .gitignore）",
            "destination": str(dest),
        }
    elif not fonts_state:
        actions["fonts"] = {
            "action": "skip",
            "reason": "用户字体目录里没有完整的四个字重，不复制（避免只拷一半）",
            "destination": str(dest),
        }
    else:
        src, found, missing = fonts_state
        if missing:
            actions["fonts"] = {
                "action": "skip",
                "reason": "缺 %s，不复制" % "、".join(missing),
                "destination": str(dest),
            }
        else:
            copied, skipped, failed = [], [], []
            try:
                dest.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                actions["fonts"] = {"action": "error", "reason": str(exc), "destination": str(dest)}
                return actions
            for weight in EXPECTED_WEIGHTS:
                source = found[weight]
                target = dest / weight
                if target.exists():
                    skipped.append(weight)
                    continue
                try:
                    shutil.copy2(str(source), str(target))
                    copied.append(weight)
                except OSError as exc:
                    failed.append("%s（%s）" % (weight, exc))
            actions["fonts"] = {
                "action": "copied" if copied else ("exists" if skipped and not failed else "error"),
                "source": str(src),
                "destination": str(dest),
                "copied": copied,
                "skipped": skipped,
                "failed": failed,
                "warning": "字体授权未随仓库分发；确认可再分发后再提交，并确保 fonts/MFGA/ 不被入库",
            }
    return actions


# --------------------------------------------------------------------------
# 输出
# --------------------------------------------------------------------------


def render_text(items, summary, actions, do_check, do_prepare, runner, args):
    lines = []
    session_line = next((e["detail"] for e in items if e["id"] == "platform"), "")
    lines.append("mpv-Emo 部署自检 · %s" % session_line)
    lines.append("仓库：%s" % REPO)
    lines.append("")

    if do_check:
        width = max(display_width(e["label"]) for e in items)
        for entry in items:
            detail = entry["detail"]
            lines.append("%s %s %s" % (BADGE[entry["status"]], pad_right(entry["label"], width + 2), detail))
            if entry["informational"]:
                lines.append(" " * 7 + "（信息项，不计入结论）")
        counts = summary["counts"]
        lines.append("")
        lines.append(
            "汇总：available %d · degraded %d · unavailable %d · unverified %d"
            % (counts["available"], counts["degraded"], counts["unavailable"], counts["unverified"])
        )

    if do_prepare and actions is not None:
        lines.append("")
        lines.append("准备结果：")
        for entry in actions["dirs"]:
            label = {"exists": "已存在，跳过", "created": "已创建", "error": "失败"}[entry["action"]]
            lines.append("  %s %s" % (pad_right(entry["path"], 22), label))
        fonts = actions.get("fonts") or {}
        if fonts.get("action") == "skip":
            lines.append("  %s 跳过：%s" % (pad_right("fonts/MFGA/", 22), fonts.get("reason", "")))
        elif fonts.get("action") == "copied":
            lines.append(
                "  %s 已复制 %s；已存在跳过 %s"
                % (
                    pad_right("fonts/MFGA/", 22),
                    "、".join(fonts.get("copied") or []) or "无",
                    "、".join(fonts.get("skipped") or []) or "无",
                )
            )
            lines.append("    注意：%s" % fonts.get("warning", ""))
        elif fonts.get("action") == "exists":
            lines.append("  %s 四个字重已存在，跳过" % pad_right("fonts/MFGA/", 22))
        elif fonts.get("action") == "error":
            lines.append(
                "  %s 失败：%s" % (pad_right("fonts/MFGA/", 22), fonts.get("reason") or fonts.get("failed"))
            )

    lines.append("")
    if summary["critical_missing"]:
        lines.append("退出码：2（关键依赖缺失：%s）" % "、".join(summary["critical_missing"]))
    else:
        lines.append("退出码：0（关键依赖齐备；降级/未验证项见上）")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="mpv-Emo 三平台部署自检与运行时准备（只读检测，--prepare 才写目录）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="退出码：0 = 可用或仅降级；2 = 关键依赖缺失（mpv / Python 3.9+）",
    )
    parser.add_argument("--check", action="store_true", help="只检测，不写任何文件")
    parser.add_argument("--prepare", action="store_true", help="创建缺失运行时目录（已存在则跳过）")
    parser.add_argument("--fonts-dir", metavar="PATH", default=None, help="显式指定用户字体目录")
    parser.add_argument(
        "--copy-fonts",
        action="store_true",
        help="兼容旧参数；字体复制现在是 --prepare 的默认行为，显式给出不改变结果",
    )
    parser.add_argument(
        "--skip-fonts",
        action="store_true",
        help="跳过字重复制（四字重齐全时 --prepare 默认会复制到 fonts/MFGA/）",
    )
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON（stdout 只有 JSON）")
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT, help="单条外部命令超时秒数（默认 8）"
    )
    args = parser.parse_args(argv)

    explicit = args.check or args.prepare
    do_check = args.check or not explicit
    do_prepare = args.prepare or not explicit

    system = platform.system()
    session = detect_session(system)
    runner = Runner(timeout=args.timeout)
    fonts_dir = Path(args.fonts_dir).expanduser() if args.fonts_dir else None

    items, fonts_state = detect_all(runner, system, session, fonts_dir)
    summary = summarize(items)

    actions = None
    if do_prepare:
        actions = prepare(runner, args, fonts_state, system)

    exit_code = summary["exit_code"]

    if args.json:
        payload = {
            "schemaVersion": 1,
            "generatedAt": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "repo": str(REPO),
            "mode": {"check": do_check, "prepare": do_prepare, "fontsDir": str(fonts_dir) if fonts_dir else None,
                     "copyFonts": not args.skip_fonts},
            "platform": {
                "system": system,
                "machine": platform.machine(),
                "session": session["kind"],
                "desktop": session["desktop"],
                "sessionRaw": session["raw"],
                "python": "%d.%d.%d" % sys.version_info[:3],
            },
            "items": items,
            "summary": summary,
            "prepare": actions,
            "exitCode": exit_code,
        }
        if hasattr(sys.stdout, "reconfigure"):
            try:
                sys.stdout.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return exit_code

    text = render_text(items, summary, actions, do_check, do_prepare, runner, args)
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (ValueError, OSError):
            pass
    print(text)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
