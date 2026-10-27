# mpv-Emo UI 字体规范

## 统一字体

```ini
font=MFGA YouHei
font_mono=MFGA YouHei
```

mpv-Emo 的界面与字幕字体统一使用 `MFGA YouHei`
（家族名来自 MFGA 字体模块 `~/.local/share/fonts/MFGA/`，
200/300/400/700.ttf 由 fontconfig 的 scan 规则归并成该家族）。

## 外部依赖（换机必读）

MFGA 字体模块**不在本仓库内**，`fonts/` 目录里没有它。整块模块约 237 MB，
其中四个字重文件是必需的：

```text
~/.local/share/fonts/MFGA/200.ttf
~/.local/share/fonts/MFGA/300.ttf
~/.local/share/fonts/MFGA/400.ttf
~/.local/share/fonts/MFGA/700.ttf
```

在新机器上 clone 本配置后如果没有安装该模块，fontconfig 会把
`MFGA YouHei` **静默回退**到任意可用字体，mpv 不报错，表现为 UI 与字幕
字体变了样。装好后用 `fc-match 'MFGA YouHei'` 确认能解析。

## 应用范围

- stats 主字体
- stats 数字/等宽区域
- uosc 主界面
- uosc 菜单
- uosc tooltip / toast / input
- 右键菜单
- 弹幕界面
- 自定义启动页文字
- 章节、字幕选择、文件浏览器等 Lua UI
- 视频字幕（sub-font，2026-10-04 起）

## 字体策略

脚本内部如果有自己的字体配置，优先改为 `MFGA YouHei`；
不再使用 LXGW 系的 ZhenKai GB / WenKai Screen / WenKai Mono Screen。

2026-10-04 用户明确要求后，**视频字幕（sub-font）也统一改用 `MFGA YouHei`**，
原先「字幕与 UI 分开处理」的约定作废。

## 检查结果

2026-09-18：原先使用的 `LXGW ZhenKai GB` 可被 fontconfig 正常解析。
2026-10-04：切换为 `MFGA YouHei`，`fc-match 'MFGA YouHei'` 解析正常。

## 备注

等宽场景（file_browser / console）仍使用 `Noto Sans Mono CJK SC`，
不属于 UI 主字体规范的范围。
