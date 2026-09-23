# mpv-Emo Linux / Yaozhi 可移植性审计

> 审计日期：2026-09-18
> 目标：保留真正有价值的功能，但不把 Yaozhi 的 Windows 自编译核心、私有 patch 或 Windows 运行时强行搬到 Linux。

## 当前基线

- 系统核心：`/usr/bin/mpv` 0.41.0
- libplacebo：7.360.1
- FFmpeg：9.0.1 / `ffmpeg-full`
- 输出：`gpu-next + Wayland Vulkan`
- 硬解：`auto-copy-safe + hwdec-codecs=all`
- GPU：NVIDIA RTX 4050 Laptop
- 已验证 FFmpeg：NVDEC/CUVID、NVENC、libplacebo、libvmaf、scale_cuda、ASS、HDR tonemap
- 当前所有 Linux Lua 脚本通过 `luajit` 语法检查

## 五级分类

### ① Linux 原生支持 —— 保留/直接使用

| 功能 | 当前实现 | 结论 |
| --- | --- | --- |
| gpu-next | mpv 原生 | 保留 |
| Vulkan/Wayland | mpv 原生 | 保留 |
| NVDEC/CUVID | FFmpeg + mpv | 保留 |
| NVENC | FFmpeg | 保留，主要用于外部编码/工具链 |
| HDR / tone mapping | gpu-next/libplacebo | 保留 |
| ICC / 色彩管理 | gpu-next/libplacebo | 保留 |
| zimg / libplacebo scaling | FFmpeg/mpv | 保留 |
| ASS / PGS 等字幕 | mpv + libass/FFmpeg | 保留 |
| PipeWire | mpv 原生 | 保留 |
| 精确 seek / watch-later | mpv 原生 | 保留 |
| 蓝光 ISO 读取 | libbluray/mpv 基础能力 | 保留读取；当前核心未提供 `discnav` |
### ② 脚本即可实现 —— Linux 可独立实现

| 功能 | 当前状态 | 处理 |
| --- | --- | --- |
| uosc / 菜单 / 播放列表 | 已有定制版 | 保留本地版本，不整包覆盖 |
| 弹幕 | `uosc_danmaku` | 保留 Linux 版本 |
| 在线媒体解析 | `online-media.lua` + Python resolver | 保留 Linux 路径/Firefox Cookie 方案 |
| 自适应直播画质 | `live-adaptive-quality.lua` | 保留 |
| AList/远程播放速度提示 | `alist_speed_indicator.lua` | 保留；不依赖 Yaozhi Windows HTTP 模块 |
| 自动保存/历史/断点 | 多个 Lua + mpv 原生 | 保留 |
| 截图裁剪/长截图 | Yaozhi `mpv-cropscreen.lua` | 可移植，但当前已有截图链；暂不重复引入 |
| WebDAV/AList 快捷入口 | Yaozhi `webdav_shortcut.lua` | Windows HTTP/文件浏览耦合，Linux 侧暂不移植 |
| YouTube 登录辅助 | Yaozhi `youtube-account.lua` | 可脚本化，但当前 Linux 在线媒体已使用本机 Cookie 路径，不引入专用浏览器方案 |

### ③ Shader / VapourSynth —— Linux 已有能力

- GLSL：Anime4K、ArtCNN、FSRCNNX、NNEDI3、RAVU、SSIM、KrigBilateral、adaptive-sharpen 等已在 `shaders/`。
- VapourSynth：当前已有 RIFE、MEMC、超分、降噪、去交错脚本；由 Linux 策略层负责准入和安全回退。
- FFmpeg 已验证包含 `scale_cuda`、`libplacebo`、`libvmaf` 与 tonemap 相关滤镜。
- 因此 Yaozhi 的 Windows RIFE/VS 配置不能原样复制；使用 Linux 的 Vulkan/VS 路径。

### ④ 需要 Yaozhi patch —— 不伪装成 Linux 原生

| 功能 | 原因 | 当前处理 |
| --- | --- | --- |
| Dolby Atmos `ad_orender` | 当前 Linux mpv 无 `ad-orender-bridge-path`，不是标准 mpv 能力 | 不移植；保持原生解码 |
| Yaozhi Atmos 实验模式 | 依赖上述私有音频解码桥接 | 不加载 |
| Yaozhi 专属增强光盘菜单 | 当前 Linux 0.41.0 无 `discnav` / `disc-menu` | 不复制 Windows core；等上游版本/本地 Linux core 具备后再接入 |
| 其他修改 mpv core 的私有补丁 | 与发行版核心 ABI/构建链耦合 | 不直接合入 |

注意：上游 master 目前已经有 `discnav` / `disc-menu`，但本机稳定版 0.41.0 实测没有；所以它属于“未来可转为①”，不是当前强行归类为原生。（依据当前本机 0.41.0 能力检测与上游文档核对）
### ⑤ Windows 专属 / Linux 不值得移植 —— 明确排除

| 内容 | 原因 | 处理 |
| --- | --- | --- |
| `d3d11va` / D3D11 渲染路径 | Windows 图形栈 | Linux 使用 Vulkan + NVDEC |
| `d3d11va-zero-copy` / `d3d11-exclusive-fs` | Windows/D3D11 专属 | 不移植 |
| Windows SMTC `media-controls` 集成 | Windows 系统媒体控制 | 不引入 Windows 依赖 |
| `window-corners` / Windows 窗口圆角 | Windows 窗口系统 | 不移植，交给 niri/Wayland |
| `screenshot_desktop.lua` | Windows 注册表/桌面路径 | Linux 不需要 |
| `sdl-fallback.lua` 的 Windows SDL/WASAPI 调优 | 针对 Windows SDL2 音频后端 | Linux 使用 PipeWire |
| `yaozhi-home.lua` / `yaozhi-donation.lua` 原版 | 包含 Windows 浏览器/Explorer/作者品牌逻辑 | 不复制；品牌统一为 Emo |
| `display-info.dll` 相关 | DLL + Windows 显示器接口 | 不移植 |
| Yaozhi Windows `mpv.exe` | 自编译 Windows core | 不作为 Linux 播放核心 |
| Yaozhi 便携 JRE / `libbluray` Windows 运行时 | Windows 便携包结构 | Linux 不复制运行时 |

## 最终架构

```text
mpv-Emo Linux
├─ ① mpv/FFmpeg/libplacebo 原生能力
├─ ② Lua/JS/Python 脚本能力
├─ ③ GLSL + VapourSynth + RIFE
├─ ④ Yaozhi 私有 patch：只记录，不硬移植
└─ ⑤ Windows-only：明确排除
```

## 已执行的清理

1. 统计并对照了当前 `~/.config/mpv` 与 Yaozhi 1.0.2 portable_config。
2. 没有把 Yaozhi Windows `mpv.exe` 作为 Linux 核心。
3. 保留已有 Linux/Wayland/uosc/RIFE/在线媒体定制，避免整目录覆盖。
4. 将 Linux release 模块从 `yaozhi-release.lua` 重命名为 `emo-release.lua`，并同步 `stats.lua` 引用。
5. 当前核心与全部 Lua 文件完成基础能力/语法检查。

## 后续同步规则

以后同步 Yaozhi 时，先进入本文件对应分类，再决定是否合并：

- ① 直接跟随发行版/上游更新。
- ② 做 Linux 原生脚本合并，不复制 Windows 路径。
- ③ 使用 Linux Shader/VS/RIFE 实现等价能力。
- ④ 只记录 patch 需求，不宣称当前系统支持。
- ⑤ 永久排除，除非未来 Linux 出现对应原生接口。
