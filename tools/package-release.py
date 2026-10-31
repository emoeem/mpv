#!/usr/bin/env python3
"""打包 mpv-Emo 配置懒人包。

用法:
    python3 tools/package-release.py            # 完整包 → dist/*.zip + sha256
    python3 tools/package-release.py --lite     # 精简包（不含 CuNNy/Anime4K 大着色器集）

排除原则：授权未定的字体、隐私凭据、运行时数据、Windows 遗产脚本一律不入包。
"""

import argparse
import datetime
import hashlib
import shutil
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TOP_LEVEL = [
    "mpv.conf", "input.conf", "profiles.conf", "platform.conf", "menu.conf",
    "manager.json", "deploy.py",
    "README.md", "CHANGELOG.md", "PORTABILITY-AUDIT.md", "UI-FONTS.md",
    "scripts", "script-opts", "shaders",
]

EXCLUDE_FILES = {
    "trakt_scrobble.conf",            # 应用凭据（历史泄露，需轮换，永不入包）
    "equalizer-gui.json",             # 本机 EQ 状态
    "sub-select.json",                # 本机字幕偏好（无害但属个人状态）
    "yaozhi-keybindings.json",
}

EXCLUDE_DIRS = {
    "__pycache__", ".git", ".manager", "archive", "audit", "cache", "files",
    "runtime", "bilibili-cookies.txt",
}

EXCLUDE_SUFFIX = (".bak-mux-", ".bak", ".pyc", ".log")


def excluded(path: Path) -> bool:
    if path.name in EXCLUDE_FILES:
        return True
    if any(part in EXCLUDE_DIRS for part in path.parts):
        return True
    return any(s in path.name for s in EXCLUDE_SUFFIX)


def collect(lite: bool, staging: Path) -> int:
    count = 0
    for item in TOP_LEVEL:
        src = ROOT / item
        if not src.exists():
            print(f"  [跳过] {item}（不存在）")
            continue
        if src.is_file():
            shutil.copy2(src, staging / item)
            count += 1
            continue
        for f in src.rglob("*"):
            if f.is_dir() or excluded(f):
                continue
            if lite and ("/CuNNy/" in f.as_posix() or "/Anime4K/" in f.as_posix()):
                continue
            rel = f.relative_to(src)
            dst = staging / item / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
            count += 1
    return count


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lite", action="store_true", help="排除 CuNNy / Anime4K 大着色器集")
    args = ap.parse_args()

    date = datetime.date.today().strftime("%Y%m%d")
    tag = "lite" if args.lite else "full"
    name = f"mpv-emo-config-{date}-{tag}"
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp) / name
        staging.mkdir()
        n = collect(args.lite, staging)
        first_run = ROOT / "FIRST-RUN.md"
        if first_run.exists():
            shutil.copy2(first_run, staging / "FIRST-RUN.md")
        size_mb = sum(f.stat().st_size for f in staging.rglob("*") if f.is_file()) / 1e6
        print(f"已收集 {n} 个文件，共 {size_mb:.1f} MB")

        zip_path = dist / f"{name}.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for f in sorted(staging.rglob("*")):
                if f.is_file():
                    zf.write(f, f.relative_to(staging))

    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    (dist / f"{name}.zip.sha256").write_text(f"{digest}  {zip_path.name}\n")
    print(f"✅ {zip_path}  ({zip_path.stat().st_size / 1e6:.1f} MB)")
    print(f"   sha256: {digest[:16]}…")


if __name__ == "__main__":
    main()
