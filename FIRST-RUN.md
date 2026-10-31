# 首次运行指南

把本目录内容放到 mpv 的配置目录（推荐整个目录替换/合并）：

- Linux / macOS：`~/.config/mpv/`
- Windows 安装版：`%APPDATA%/mpv/`
- Windows 便携版：mpv.exe 同目录下 `portable_config/`

## 1. 依赖自检

```bash
python3 deploy.py --check     # 报告缺失依赖（四态：available/degraded/unavailable/unverified）
python3 deploy.py --prepare   # 补建 cache/ files/ 运行时目录
```

## 2. UI 字体（必做）

界面字体 **MFGA** 因授权未定不随包分发。按 `UI-FONTS.md` 的指引下载后放到：

```
fonts/MFGA/200.ttf  300.ttf  400.ttf  700.ttf
```

没有该字体时界面会回退到系统默认字体，功能不受影响。

## 3. 开箱即用的功能入口

| 功能 | 入口 |
| --- | --- |
| 全功能右键菜单 | 播放区右键 |
| 全网弹幕 | `CTRL+D` 开关 · `CTRL+SHIFT+D` 菜单（自动匹配剧集） |
| 在线中文字幕 | `CTRL+F`（ASSRT）· `ALT+F`（Wyzie/TMDb） |
| 内容自适应超分 | 默认开启，`CTRL+ALT+c` 切换 动画/真人/自动 |
| 可视化均衡器 | `e` 键 |
| 360° 全景视频 | 右键 `视频 > 360°VR` |
| 画质配置组 | `ALT+1~8` 互斥切换 · `CTRL+P` 循环 |
| 命令面板 | `CTRL+P`（菜单版见右键 `工具`） |

## 4. 常见问题

- **着色器不生效/报错**：确认显卡驱动与 Vulkan 正常（`vulkaninfo --summary`）。
- **弹幕无内容**：部分 API 节点可能波动，右键 `字幕 > 字幕/弹幕` 手动搜索。
- **4K 掉帧**：右键 `Emo > 超分与补帧` 切到「性能优先」。
- 更多细节见 `README.md`（快捷键全表、HDR 双引擎、三平台部署）。

## 5. 更新

本配置内置第三方更新器：播放器内按 `M` 可检查 uosc / 弹幕插件 / Anime4K 等上游更新
（只报告，不覆盖本地定制）。
