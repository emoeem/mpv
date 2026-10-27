#!/usr/bin/env python3
"""README 快捷键章节与 input.conf 的双向核对。

用法：`python3 audit/audit_readme_keys.py`。
何时跑：改过 input.conf 的键位、或编辑过 README 的快捷键表之后。

口径：
- 只核对 README 的「## 快捷键」章节（首个二级标题前结束）；
- README 有但未绑定的键 = 文档漂移，必须修；
- 「有 #menu 但表中未提及」仅作参考输出——表格不必穷举。
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

readme = open(os.path.join(ROOT, 'README.md')).read()
conf = open(os.path.join(ROOT, 'input.conf')).read()

section = re.search(r'^## 快捷键$(.*?)(?=^## )', readme, re.M | re.S)
if not section:
    raise SystemExit('README 中找不到「## 快捷键」章节')
table_keys = re.findall(r'^\s*\|\s*`([^`]+)`\s*\|', section.group(1), re.M)

bound = set()
for line in conf.splitlines():
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    m = re.match(r'^(\S+)\s', s)
    if m and m.group(1) != '#':
        bound.add(m.group(1).upper())

problems = [k for k in table_keys if k.upper() not in bound]
print('== README 键位表有但 input.conf 未绑定的键 ==')
for k in problems:
    print(f'  {k}')
if not problems:
    print('  (无)')

menu_bound = set()
for line in conf.splitlines():
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    m = re.match(r'^(\S+)\s', s)
    if m and m.group(1) != '#' and '#menu:' in s:
        menu_bound.add(m.group(1).upper())
documented = {k.upper() for k in table_keys}
undoc = sorted(k for k in menu_bound if k not in documented)
print()
print(f'== 有 #menu 但表中未提及（参考，{len(undoc)} 个）==')
print('  ' + ', '.join(undoc))

print()
print('结论:', 'FAIL（存在文档漂移）' if problems else 'PASS')
raise SystemExit(1 if problems else 0)
