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

---

## 三平台部署（2026-10-28 追加）

本轮把「能不能在另一台机器上装起来」从口头清单变成了可执行检查：
仓库根新增 `deploy.py`，README 新增「三平台部署」章节。审计结论按
`available` / `degraded` / `unavailable` / `unverified` 四态记录，**没有在真机上
跑过的能力一律标 `unverified`，不冒充已支持**。

### 实现位置

| 能力 | 实现位置 | 说明 |
| --- | --- | --- |
| 入口 / 参数 / 退出码 | `deploy.py` → `main()`、`EXIT_OK`、`EXIT_CRITICAL` | 0 = 可用或仅降级；2 = mpv 缺失或 Python < 3.9 |
| 状态模型与汇总 | `deploy.py` → `item()`、`STATUSES`、`SEVERITY`、`summarize()` | `informational` 项（仓库字体）不计入结论 |
| 平台与会话 | `deploy.py` → `detect_platform()`、`detect_session()` | 读 `XDG_SESSION_TYPE` / `WAYLAND_DISPLAY` / `DISPLAY` / `XDG_CURRENT_DESKTOP` |
| mpv 版本 | `deploy.py` → `detect_mpv()` | 解析 `mpv --version` 第一行，附带 libplacebo / FFmpeg 行 |
| 硬解后端列表 | `deploy.py` → `detect_hwdec()`、`parse_hwdec_help()` | 解析 `mpv --hwdec=help`，剥离 `auto*` 与 `-copy` 变体 |
| 硬解运行时 | `deploy.py` → `detect_hwdec_runtime()` | 恒 `unverified`；附 `nvidia-smi` / `vainfo` 作为旁证，不作为结论 |
| 渲染能力 | `deploy.py` → `detect_render()`、`parse_option_help()` | 解析 `mpv --vo=help` 与 `mpv --gpu-context=help`，按会话选 `waylandvk` / `x11vk` |
| 外部工具 | `deploy.py` → `detect_tool()`、`detect_python()` | Git / yt-dlp / Deno / 当前解释器 |
| 音频 | `deploy.py` → `detect_audio()` | Linux 用 `pactl info`（含 `PipeWire` 字样）或 `pw-cli ls Node`；Win/mac 只读声明，`unverified` |
| 剪贴板 | `deploy.py` → `detect_clipboard()` | Linux 按会话查 `wl-copy`+`wl-paste` / `xclip`；Win/mac 报脚本分支并标 `unverified` |
| 补帧 / AI 超分 | `deploy.py` → `detect_rife()`、`python_module_info()` | 查 `scripts/rife.lua`、`scripts/ai-interpolation.lua`、`vs/*.vpy`、`vapoursynth` / `vsmlrt` / `tensorrt` / `onnxruntime` 可导入性 |
| 字体（用户侧） | `deploy.py` → `detect_fonts_user()`、`scan_weights()`、`default_font_dirs()` | 四字重 + Linux 上 `fc-match 'MFGA YouHei'` 交叉验证 |
| 字体（仓库侧） | `deploy.py` → `detect_fonts_repo()` | 只报告 `fonts/MFGA/` 现状，作为信息项 |
| 字体复制 | `deploy.py` → `prepare()` | `--prepare` 默认执行（`--skip-fonts` 可关）；四字重齐全才复制，已存在跳过，缺字重整体跳过；`fonts/MFGA/` 已进 `.gitignore` |
| 在线媒体 venv | `deploy.py` → `detect_online_media()`、`venv_python()` | 按平台解析 `bin/python3` 或 `Scripts\python.exe`，并与 `online-media/runtime-manifest.json` 的 `architecture` 对比 |
| 运行时目录 | `deploy.py` → `detect_runtime_dirs()`、`RUNTIME_DIRS`、`prepare()` | 只建 `mpv.conf` 真正引用的目录，已存在跳过（幂等） |
| 渲染 / 音频 / 硬解分流 | `platform.conf` → `[platform-linux]` / `[platform-windows]` / `[platform-macos]` | 由 `mpv.conf:12 include=~~/platform.conf` 引入，`profile-cond=get("platform")` 自动匹配 |
| 更新器 replace 安全语义 | `scripts/manager.lua`（`replace` 模式） | 暂存 → 备份 → 整体替换；本地有改动时保护性跳过 |
| 剪贴板脚本分支 | `script-modules/extended-menu.lua`（`xclip` / `wl-paste` / `powershell` / `pbpaste`）、`scripts/uosc/lib/utils.lua`（`wl-copy` / `wl-paste` / `xclip` / PowerShell）、`scripts/screenshot-to-clipboard.lua`（`osascript`） | 三平台分支都在代码里，只有 Linux 实测过 |
| 字体族名约定 | `UI-FONTS.md` → 家族 `MFGA YouHei` | 缺字重时 fontconfig 静默回退，脚本用 `fc-match` 抓这一层 |

### 能力覆盖矩阵

| 能力 | Linux / Wayland（本机实测） | Windows | macOS |
| --- | --- | --- | --- |
| `vo=gpu-next` | `available`：vo 列表含 `gpu-next`，`gpu-context=waylandvk` 在列 | `unverified`：需 D3D11/Vulkan 实测 | `unverified`：只有 cocoa |
| 硬解后端（编译期） | `available`：`amf cuda nvdec qsv rkmpp v4l2m2m vaapi vdpau vulkan` | `unverified`：期望 `d3d11va`/`dxva2`，本机构建 `d3d11=disabled` | `unverified`：期望 `videotoolbox` |
| 硬解运行时 | `unverified`：`--vo=null` 不接受 DR 帧（日志 `DR failed - disabling`） | `unverified` | `unverified` |
| 音频 | `available`：`PulseAudio (on PipeWire 1.6.10)` | `unverified`：`ao=wasapi` | `unverified`：`ao=coreaudio` |
| 剪贴板 | `available`：`wl-copy` + `wl-paste`（`xclip` 兜底） | `unverified`：PowerShell 分支 | `unverified`：`pbcopy` / `osascript` 分支 |
| 补帧 / AI 超分 | `degraded`：`rife.lua` 在、`vapoursynth` 可导入、`vsmlrt` 缺失 | `unverified`：需 mlrt runtime + 显卡后端 | `unverified`：同左 |
| 用户字体 | `available`：四字重 + `fc-match` 解析 | `unverified`：需 `--fonts-dir` | `unverified`：需 `--fonts-dir` |
| 在线媒体 venv | `degraded`：venv 可执行，但 manifest 声明 `windows-x86_64` | `unverified`：需 `Scripts\python.exe` 重建 | `unverified`：需 `bin/python3` 重建 |
| 更新器 `check` / `replace` | 未在本轮重跑（键位审计另跑） | `unverified`：`replace` 仅按安全检查对待 | `unverified` |

### 待验证清单

Windows（全部待实测）：

1. `mpv --hwdec=help` 是否列出 `d3d11va` / `dxva2`；再用一段 H.264 片源配合
   `--hwdec=d3d11va-copy --msg-level=vd=v` 看是否出现 `Using hardware decoding`。
2. `mpv --gpu-context=help` 是否含 `winvk` / `d3d11`；`platform.conf` 的
   `[platform-windows]` 未设 `gpu-context`，需确认 mpv 自选结果不是软渲染。
3. `ao=wasapi` 是否真的出声；`pactl` 不存在时 `deploy.py` 不应误报（应按设计走
   `unverified` 分支）。
4. `scripts/manager.lua` 的 `replace` 在 Windows 路径分隔符 / 文件锁下能否完成
   暂存与替换；锁文件被 mpv 占用时是否保护性跳过。
5. `Scripts\python.exe` 重建 venv 后，`online-media/resolve_*.py` 与
   `scripts/online-media.lua` 的调用路径是否仍指向 `runtime` 目录。
6. `Get-Clipboard` / `Set-Clipboard` 分支（`extended-menu.lua`、
   `scripts/uosc/lib/utils.lua`）复制标题、截图是否可用。
7. `deploy.py --fonts-dir "%LOCALAPPDATA%\Microsoft\Windows\Fonts\MFGA"` 的
   路径展开与四个字重识别。

macOS（全部待实测）：

1. `platform.conf` 的 `[platform-macos]` 不设 `gpu-context`，需确认 cocoa 下
   `gpu-next` 正常出画、`vo=libmpv` 不相关。
2. `hwdec=videotoolbox,auto-copy-safe` 是否在该机型生效；
   `mpv --hwdec=help` 是否列出 `videotoolbox`。
3. `ao=coreaudio` 是否出声。
4. `pbcopy` / `pbpaste`（`extended-menu.lua`）与 `osascript`
   （`screenshot-to-clipboard.lua:116`）是否可用；Apple Silicon 上 `osascript`
   的 `«class PNGf»` 写法是否仍被接受。
5. `deploy.py --fonts-dir ~/Library/Fonts/MFGA` 与 `fc-match`（macOS 通常没有
   fontconfig，脚本应跳过该项而不是报错）。
6. `python3 -m venv online-media/runtime` 后 resolver 依赖是否齐备
   （`PySocks` / `websocket-client` 等按 `runtime-manifest.json` 口径）。

Linux 侧仍待补的一项：**真实硬解与补帧的运行时验证**——本机只验证了后端列表与
驱动可见性，`--vo=null` 无法承载硬解帧，需要在有窗口的会话里播放实际片源确认。

补充说明：`deploy.py` 的检测全部只读（`shutil.which` + 只读命令行），只有
`--prepare` 会写目录，且写之前逐项判断是否已存在；脚本不会修改 `mpv.conf`、
`platform.conf`、`script-opts/`、`scripts/` 或 `fonts/` 里任何既有文件。

### 本轮运行时证据（Linux / Wayland，mpv 0.41.0 实机）

`profile-cond` 是否真的在启动时生效，不能只看配置文件文本。用 IPC 读取真实运行值：

```
mpv --config-dir=~/.config/mpv --input-ipc-server=/tmp/mpvui.sock <测试片源>
  platform      = linux
  gpu-context   = [{'name': 'waylandvk', 'enabled': True}]
  ao            = [{'name': 'pipewire', 'enabled': True}]
  current-ao    = pipewire            # 实际打开的音频后端，不只是候选列表
  hwdec         = ['nvdec-copy', 'vaapi-copy', 'auto-copy-safe']
  user-data/hdr-pipeline/mode = native
```

- `hwdec` 这一条同时验证了**配置顺序**：`mpv.conf` 的全局 `hwdec` 必须写在
  `include=~~/platform.conf` **之前**。实测把全局值放在 include 之后会反向覆盖
  profile（`{'ao': 'null', 'hwdec': 'no'}` 覆盖成功），已在 `mpv.conf` 注释里写明。
- `--profile=游戏` 实机启动后 `gpu-context` 仍为 `waylandvk`、`video-sync=display-resample`
  生效、`vo-configured=True`：移除 `[游戏]` 里的 `gpu-api=vulkan` / `gpu-context=waylandvk`
  没有破坏 Linux 行为。
- 仍未验证：Windows/macOS 上 `profile-cond` 的 `ao=wasapi` / `ao=coreaudio` 实际出声。
  这两项保持 `unverified`，不得根据配置文本升级为 `available`。
