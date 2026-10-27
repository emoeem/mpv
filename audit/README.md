# 配置审计脚本

三个可复跑的一致性检查，路径全部相对仓库根，直接执行即可：

```bash
python3 audit/audit_bindings.py       # 键位：重复键 / 死脚本目标 / 裸键遮蔽
python3 audit/audit_readme_keys.py    # README 快捷键表 vs input.conf
python3 audit/audit_theme_colors.py   # 主题色残留（旧色板黑名单 + 未知色提示）
```

退出码 0 = 通过，1 = 存在 FAIL 项。三个脚本互相独立，可单独跑。

## 何时跑

| 场景 | 跑哪个 |
| --- | --- |
| 改了 `input.conf`、增删/重命名脚本 | `audit_bindings.py` |
| 改了键位或编辑了 README 的快捷键表 | `audit_readme_keys.py` |
| 换主题、给脚本写硬编码颜色、改 script-opts 颜色项 | `audit_theme_colors.py` |
| 提交前（保险起见） | 三个都跑 |

## 口径备忘

- mpv 键名区分大小写（`a` 与 `A` 是不同绑定），判重用原始键名。
- 脚本名归一化：`-` 等非字母数字会变 `_`（`mpv_chapters.js` → `mpv_chapters`）。
- `script-message-to` / `script-binding` 指向不存在的脚本时 mpv 静默不报错，
  这是死目标必须靠静态扫描的原因。
- 脚本内 `add_key_binding` 与 input.conf 同键 = 用户绑定遮蔽脚本绑定，
  属于常见有意设计，脚本只列出供人工确认，不算失败。
- 主题扫描排除上游 `check` 管理目录（simple-mpv-webui、trakt-scrobble）
  与 `scripts/uosc/`（定制版 uosc 的颜色全部来自 `uosc.conf` 的 `color=` 行）。
  换主题时需要同步更新 `audit_theme_colors.py` 里的黑名单/白名单。

## 历史战果

- 2026-10-27：按键审计发现 3 处 `script-message-to` 目标带连字符导致的
  静默失效（uosc-subtitle-lines / trakt-scrobble / screenshot-to-clipboard）。
- 2026-10-27：键位表核对发现 `CTRL+ALT+i`、`CTRL+ALT+SHIFT+t`、
  `CTRL+ALT+c`、`CTRL+v`、`CTRL+ALT+v` 五个 README 死键。
- 2026-10-28：色值扫描在 Dracula 换肤收尾时抓出 stats.conf、
  file_browser.conf、chapterskip.conf、simplehistory.conf 等多处漏网色值。
