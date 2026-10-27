#!/usr/bin/env python3
"""按键审计：重复键位、死脚本目标、脚本裸键与 input.conf 的遮蔽关系。

用法：在仓库任意位置执行 `python3 audit/audit_bindings.py`。
何时跑：改过 input.conf、增删脚本、或重命名脚本之后。

口径说明：
- mpv 键名区分大小写（a 与 A 是不同绑定），判重必须用原始键名；
- mpv 会把脚本文件名里的非字母数字归一化为 _（如 mpv_chapters.js -> mpv_chapters），
  script-message-to / script-binding 的目标一律按归一化名核对；
- 用户绑定（input.conf）优先于脚本内 add_key_binding，同键时脚本侧被遮蔽，
  这类"冲突"只列出供人工确认，不视为错误。
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILTIN = {'console', 'select', 'stats', 'ytdl_hook', 'osc', 'input_forced'}


def norm(name):
    """mpv 把脚本名里的非字母数字归一化为 _"""
    return re.sub(r'[^A-Za-z0-9]', '_', name)


def existing_scripts():
    existing = set(BUILTIN)
    scripts_dir = os.path.join(ROOT, 'scripts')
    for f in os.listdir(scripts_dir):
        p = os.path.join(scripts_dir, f)
        if f.endswith('.lua'):
            existing.add(norm(f[:-4]))
        elif f.endswith('.js'):
            existing.add(norm(f[:-3]))
        elif os.path.isdir(p):
            existing.add(norm(f))
    return existing


def main():
    existing = existing_scripts()

    bindings = []
    for ln, line in enumerate(open(os.path.join(ROOT, 'input.conf')), 1):
        s = line.rstrip('\n')
        if not s.strip() or s.lstrip().startswith('#'):
            continue
        m = re.match(r'^(\S+)\s+(.*)$', s)
        if not m:
            continue
        key, cmd = m.group(1), m.group(2)
        if key == '#':
            continue
        bindings.append((key, cmd, ln))

    # 重复键位：原始键名精确判重（区分大小写）
    seen, dups = {}, []
    for key, cmd, ln in bindings:
        if key in seen:
            dups.append((key, seen[key], ln))
        else:
            seen[key] = ln

    # 死脚本目标
    dead = []
    for key, cmd, ln in bindings:
        for m in re.finditer(r'script-message-to\s+([A-Za-z0-9_.-]+)', cmd):
            if norm(m.group(1)) not in existing:
                dead.append((ln, 'script-message-to ' + m.group(1), key))
        for m in re.finditer(r'script-binding\s+([A-Za-z0-9_.-]+)/', cmd):
            if norm(m.group(1)) not in existing:
                dead.append((ln, 'script-binding ' + m.group(1), key))

    # 脚本裸键注册 vs input.conf（仅提示，遮蔽是有意设计时无需处理）
    conf_keys = {k for k, _, _ in bindings}
    shadowed = []
    for f in sorted(os.listdir(os.path.join(ROOT, 'scripts'))):
        p = os.path.join(ROOT, 'scripts', f)
        if not f.endswith(('.lua', '.js')):
            continue
        text = open(p, encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'add_(?:forced_)?key_binding\(\s*["\']([^"\']+)["\']', text):
            k = m.group(1)
            if k in ('nil', '') or k.startswith('_'):
                continue
            if k in conf_keys:
                shadowed.append((k, f))

    print('绑定总数:', len(bindings))
    print()
    print('== 重复键位（后者覆盖前者）==')
    for k, l1, l2 in dups:
        print(f'  {k}: 行 {l1} 被 行 {l2} 覆盖')
    if not dups:
        print('  (无)')
    print()
    print('== 死脚本目标 ==')
    for ln, what, key in dead:
        print(f'  行 {ln} [{key}] -> {what}')
    if not dead:
        print('  (无)')
    print()
    print('== 被 input.conf 遮蔽的脚本裸键（人工确认是否为有意设计）==')
    for k, f in shadowed:
        print(f'  {k:<12} {f}')
    if not shadowed:
        print('  (无)')

    failed = bool(dups or dead)
    print()
    print('结论:', 'FAIL（存在重复键位或死目标）' if failed else 'PASS')
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()
