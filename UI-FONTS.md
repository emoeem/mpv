# mpv-Emo UI 字体规范

## 统一字体

```ini
font=LXGW ZhenKai GB
font_mono=LXGW ZhenKai GB
```

mpv-Emo 的界面字体统一使用 `LXGW ZhenKai GB`。

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

## 字体策略

脚本内部如果有自己的字体配置，优先改为 `LXGW ZhenKai GB`；
不要继续使用 `LXGW WenKai Screen` 或 `LXGW WenKai Mono Screen`。

mpv 核心字幕字体属于视频字幕渲染设置，与播放器 UI 字体分开处理；
除非用户明确要求，否则不因为 UI 字体统一而改变视频字幕的字体策略。

## 检查结果

2026-09-18：`fc-match 'LXGW ZhenKai GB'` 已确认字体可由 fontconfig 正常解析。

后续新增 UI 脚本也应遵循这一规范。