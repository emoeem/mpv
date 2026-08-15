# mpv 配置

个人 mpv 播放器配置，面向 Linux / Wayland 环境，针对 `gpu-next`（vulkan）视频输出与高质量画质 / 补帧 / 字幕体验深度定制。

> 适用于 mpv 全功能构建版本（含 `gpu-next`、`vapoursynth`、`ytdl_hook` 等特性）。

## 目录结构

```
~/.config/mpv/
├── mpv.conf               # 主配置文件（解码 / 输出 / OSD / 视频 / 音频 / 字幕 / 截图 / 着色器 / 配置组）
├── input.conf             # 键位绑定
├── inputevent_key.conf    # InputEvent 脚本的增强式键位（单击 / 双击 / 长按 / 条件触发）
├── profiles.conf          # 可手动套用的场景预设（游戏 / 电影 / 动画 / 低功耗 / 网络流 / HDR / 截图 / 直播）
├── menu.conf              # select.lua 的菜单数据（已置空，由 dyn_menu.lua 接管）
├── scripts/               # Lua / JS 脚本（播放增强、UI、字幕、历史记录等）
├── script-opts/           # 脚本对应的设置文件
├── script-modules/        # 脚本依赖的模块
├── shaders/               # GLSL 着色器合集（缩放 / 锐化 / 去色带 / 色彩）
├── vs/                    # VapourSynth 脚本（MEMC 补帧 / 超分 / 降噪 / 去交错）
├── fonts/                 # OSD 字体（LXGW WenKai、Noto CJK、Material Icons 等）
├── osc-style/             # 多种 OSC 界面样式（uosc / modernx / 等）
├── icc/                   # ICC 色彩配置文件
├── archive/               # 已停用但保留备用的配置
├── cache/                 # 运行时缓存（已 gitignore）
└── files/                 # 历史记录 / 书签等运行时数据（已 gitignore）
```

## 核心特性

### 视频输出与解码

- `vo=gpu-next` + `gpu-context=waylandvk`：Wayland 下显式使用 Vulkan
- `hwdec=auto-safe` + `hwdec-codecs=all`：自动硬件解码，兼容性优先
- 支持 `profile=HQ` 等内置算法配置组，按需切换画质

### 色彩管理

- `Target` + `Dither` 配置组：目标色彩空间映射 + 高质量抖动
- `HDR2SDR` / `SDR2HDR` / `HDR-PASS`：HDR 与 SDR 双向映射
- `ICC` / `ICC+`：ICC 配置文件色彩管理
- 条件配置组自动适配：`hdr-2390`、`peak-percentile`、`SDR-gamut`、`SDR-target`、`HDR` 等

### 缩放与着色器

内置多种缩放配置组，按需启用：

| 配置组 | 适用场景 |
| --- | --- |
| `HQ` | 常用内置算法 |
| `NNEDI3` / `NNEDI3+` | 大多数场景（NNEDI3-32 / 64） |
| `ravu-zoom` | 大多数场景（轻量） |
| `FSRCNNX` / `FSRCNNX+` | HD / SD 场景 |
| `Ani4K` / `AniSD` | 动画（性能开销大） |
| `Anime4K` | 大多数动画 |
| `SSIM` | 4K / 低性能设备 |

`shaders/` 目录收录了 Anime4K、FSRCNNX、NNEDI3、RAVU、SSIM、ArtCNN 等大量 GLSL 着色器。

### VapourSynth 补帧 / 画质增强（vs/）

- **MEMC 补帧**：`MEMC_RIFE_*`、`MEMC_SVP_PRO`、`MEMC_MVT_LQ`、`MEMC_DRBA_NV`
- **超分辨率**：`SR_ACNET_STD`、`SR_ARTCNN_NV`
- **降噪**：`NR_BM3D_NV`、`NR_CCD_STD`
- **AI 画质增强**：`MIX_UAI_*`（Waifu2x 系）
- **去交错**：`ETC_DEINT_EX`

### 脚本（scripts/）

包含约 60 个脚本，常用功能：

- **界面**：`uosc`（现代 OSC 界面）、`thumbfast`（缩略图预览）、`uosc_danmaku`（弹幕）、`stats.lua`
- **播放列表 / 文件**：`playlistmanager`、`playlist-view`、`file-browser`、`command_palette`、`autoload`
- **字幕**：`sub-select`、`sub-fastwhisper`（Whisper 本地字幕生成）、`sub_export`、`autosubsync`
- **历史 / 书签**：`history-bookmark`、`simplehistory`、`simplebookmark`、`recentmenu`、`memo`
- **在线视频**：`quality-menu`（yt-dlp 画质选择）、`ytdl_hook` 增强、`trakt-scrobble`
- **远程控制**：`simple-mpv-webui`（网页端控制）
- **其他**：`screenshot-to-clipboard`、`auto-save-state`、`persist_properties`、`skip-segments`（跳过片头尾）等

### 键位增强（inputevent_key.conf）

基于 [InputEvent](https://github.com/zhongfly/InputEvent) 脚本，支持单击 / 双击 / 长按 / 长按释放，以及基于条件的命令触发。

### 场景预设（profiles.conf）

在 `mpv.conf` 中添加 `profile=游戏` 等方式套用：

- `游戏`：低延迟高性能
- `电影`：高质量画质
- `动画`：动画优化 + Anime4K 着色器
- `低功耗`：省电（软解 + 低负载）
- `网络流`：在线视频优化
- `HDR`：HDR 内容优化
- `截图`：高质量截图
- `直播`：实时流媒体低延迟

## 使用方法

```bash
# 克隆到 mpv 配置目录
git clone https://github.com/emoeem/mpv.git ~/.config/mpv
```

> 若已存在本地配置，请先备份，再覆盖。

## 注意事项

- 部分功能依赖 mpv **全功能构建**（含 `gpu-next`、`vapoursynth`、`ytdl_hook`），以及系统中已安装的 `vapoursynth`、`yt-dlp` 等工具。
- `fonts/` 目录字体体积较大，供 OSD 使用（`osd-fonts-dir` 指向此处）。
- `cache/`、`files/` 等运行时数据已在 `.gitignore` 中排除，不会入库。
- 若使用 SVP Manager，`input-ipc-server` 需设置为 `mpvpipe` 值（见 `mpv.conf` 注释）。

## 相关链接

- [mpv 官方手册](https://mpv.io/manual/master/)
- [uosc](https://github.com/tomasklaen/uosc)
- [thumbfast](https://github.com/po5/thumbfast)
- [InputEvent](https://github.com/zhongfly/InputEvent)
