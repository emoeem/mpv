#!/usr/bin/env python3
"""主题色残留扫描：旧调色板色值必须为零，未知色值列出供人工判断。

用法：`python3 audit/audit_theme_colors.py`。
何时跑：换主题、给脚本加硬编码颜色、或改 script-opts 里的颜色项之后。

口径：
- 黑名单 = 上一任主题（Catppuccin Mocha）与本项目用过的全部旧变体色，
  出现即 FAIL；
- 白名单 = 当前主题（Dracula）官方色板 + 派生层级色，不计入未知项；
- 未知色值（不在两个名单里）只提示不失败——可能是合法的一次性功能色
  （如字幕样式的特殊色），由人判断；
- 排除上游 `check` 管理目录（simple-mpv-webui、trakt-scrobble）与
  scripts/uosc/（定制版 uosc 的颜色全部来自 uosc.conf 的 color= 行）。
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 旧主题（Catppuccin Mocha）与历史变体：出现即 FAIL
FORBIDDEN = {
    'F5E0DC', 'CDD6F4', '11111B', '181825', '1E1E2E', '313244', '45475A',
    '585B70', '6C7086', '9399B2', 'A6ADC8', 'B4BEFE', 'CBA6F7', '89B4FA',
    'A6E3A1', 'F38BA8', 'FAB489', 'F4D6CD', 'F7A6CB', 'AFE2F9', 'A88BF3',
    'A1E3A6', '2E1E1E', '443231', 'DEC2BA', 'B29993', 'C8ADA6', '1B1111',
    'EBDC89', '251818', '74C7EC', '94E2D5', 'F9E2AF', 'F5C2E7', 'EBA0AC',
    'F2CDCD',
}

# 当前主题（Dracula）+ 派生层级色：白名单
KNOWN = {
    'F8F8F2', '282A36', '44475A', '6272A4', 'BD93F9', 'FF79C6', '50FA7B',
    'FF5555', 'FFB86C', '8BE9FD', 'F1FA8C', '191A21', '21222C', '343746',
    '939CC3',
}

SCAN_ROOTS = ['mpv.conf', 'input.conf', 'script-opts', 'scripts', 'script-modules']
EXCLUDE_PARTS = ('simple-mpv-webui', 'trakt-scrobble',
                 os.path.join('scripts', 'uosc'))
HEX = re.compile(r'\b([0-9A-Fa-f]{6})\b')


def iter_targets():
    for item in SCAN_ROOTS:
        p = os.path.join(ROOT, item)
        if os.path.isfile(p):
            yield p
        else:
            for dirpath, dirnames, filenames in os.walk(p):
                dirnames[:] = [d for d in dirnames
                               if d not in ('.git', '__pycache__')]
                for fn in filenames:
                    if not fn.endswith(('.conf', '.lua', '.js', '.md')):
                        continue
                    yield os.path.join(dirpath, fn)


def main():
    forbidden_hits, unknown_hits = [], []
    for path in iter_targets():
        rel = os.path.relpath(path, ROOT)
        if any(part in rel for part in EXCLUDE_PARTS):
            continue
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for m in HEX.finditer(text):
            color = m.group(1).upper()
            if color in FORBIDDEN:
                line_no = text[:m.start()].count('\n') + 1
                forbidden_hits.append((rel, line_no, color))
            elif color not in KNOWN and not color.isdigit():
                line_no = text[:m.start()].count('\n') + 1
                unknown_hits.append((rel, line_no, color))

    print('== 旧主题残留（FAIL 项）==')
    for rel, ln, c in forbidden_hits:
        print(f'  {rel}:{ln}  {c}')
    if not forbidden_hits:
        print('  (无)')
    print()
    print('== 未知色值（人工判断，不计失败）==')
    seen = set()
    for rel, ln, c in unknown_hits:
        key = (rel, c)
        if key in seen:
            continue
        seen.add(key)
        print(f'  {rel}:{ln}  {c}')
    if not unknown_hits:
        print('  (无)')

    print()
    print('结论:', 'FAIL（存在旧主题残留）' if forbidden_hits else 'PASS')
    raise SystemExit(1 if forbidden_hits else 0)


if __name__ == '__main__':
    main()
