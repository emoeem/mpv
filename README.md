# mpv 配置

这是我的个人 mpv 配置仓库，主要面向 Linux / Wayland 桌面，使用
`gpu-next + Vulkan` 输出，并围绕高质量视频、HDR/SDR 色彩处理、字幕、播放列表、
历史记录和 uosc 操作界面进行定制。

当前配置的核心原则：

- 以 `mpv.conf`、`input.conf` 和 `script-opts/` 为主要配置入口。
- 禁用 mpv 默认键位，使用仓库内可审计的自定义键位。
- 使用定制版 uosc，不直接用上游文件覆盖本地改动。
- 使用 profile 组织画质、色彩、HDR、着色器和场景模式。
- 运行时数据、缓存和第三方更新器的 Git 镜像不提交到仓库。

> 文档以当前工作区中的实际文件为准。修改配置后，快捷键和参数说明应再次以
> `input.conf`、`mpv.conf` 与 `script-opts/` 为最终依据。

## 目录

- [快速开始](#快速开始)
- [目录结构](#目录结构)
- [配置特点](#配置特点)
- [画质与色彩 profile](#画质与色彩-profile)
- [uosc 界面](#uosc-界面)
- [脚本功能](#脚本功能)
- [快捷键](#快捷键)
- [第三方更新器](#第三方更新器)
- [依赖与注意事项](#依赖与注意事项)

## 快速开始

### 依赖

建议使用带有以下能力的完整 mpv 构建：

- `gpu-next`
- Vulkan / Wayland 视频输出
- PipeWire 音频输出
- VapourSynth
- `ytdl_hook`
- `yt-dlp`

部分脚本还需要系统工具或外部运行时，例如 VapourSynth、Whisper、Trakt
访问令牌、浏览器 cookies 和桌面剪贴板工具。未使用对应功能时，可以不安装
相关依赖。

### 安装

如果目标目录还没有 mpv 配置，可以执行：

```bash
git clone https://github.com/emoeem/mpv.git ~/.config/mpv
```

如果目录已经存在，请先备份当前配置，再根据需要合并文件。此仓库包含个人
字体、ICC 文件、脚本和着色器，不建议直接覆盖另一个完整配置目录。

### 启动与检查

```bash
mpv --force-window=yes
```

运行时可使用 `M` 检查 `manager.json` 中配置的第三方来源。检查配置语法时，
可以执行：

```bash
git diff --check
luac -p scripts/uosc/main.lua \
  scripts/uosc/elements/Menu.lua \
  scripts/uosc/elements/Controls.lua \
  scripts/uosc/elements/Timeline.lua
```

## 目录结构

```text
~/.config/mpv/
├── mpv.conf                         # 主配置：输出、解码、音频、字幕、截图和 profile
├── input.conf                       # 自定义快捷键与 uosc 菜单
├── inputevent_key.conf              # 单击、双击、长按等增强键位
├── profiles.conf                    # 游戏、电影、动画、HDR 等场景 profile
├── menu.conf                        # select.lua 菜单数据，目前由动态菜单接管
├── scripts/                         # Lua / JavaScript 播放脚本
├── script-opts/                     # 各脚本的配置
├── script-modules/                  # 脚本共用模块
├── shaders/                         # GLSL 缩放、锐化、去色带和 AI 着色器
├── vs/                              # VapourSynth 补帧、超分、降噪和去交错脚本
├── fonts/                           # OSD、字幕和 uosc 字体
├── osc-style/                       # 其他 OSC 样式备份
├── icc/                             # ICC 色彩配置文件
├── script-assets/                   # 起播格式徽标等资源
├── manager.json                     # 第三方来源与更新策略
├── .manager/                        # 更新器缓存和备份，已加入 gitignore
├── cache/                           # watch-later、着色器和 ICC 缓存，已忽略
├── files/                           # 播放历史、截图等运行时数据，已忽略
└── archive/                         # 已停用的历史配置备份
```

### 主要文件

| 文件 | 作用 |
| --- | --- |
| `mpv.conf` | 定义默认输出、解码、音频、字幕、截图、网络和 profile |
| `input.conf` | 定义键位，并通过 `#menu:` 注释生成 uosc 菜单 |
| `profiles.conf` | 定义可手动启用的场景模式 |
| `script-opts/uosc.conf` | 定义 uosc 控件、颜色、字体、时间轴和动画 |
| `manager.json` | 定义哪些第三方目录只检查，哪些目录允许整体替换 |
| `scripts/manager.lua` | 异步检查、比较、备份和更新第三方脚本 / 着色器 |
| `script-opts/` | 控制各个脚本的行为，避免把脚本参数硬编码在 Lua 中 |

## 配置特点

### 视频输出与硬件解码

`mpv.conf` 的默认视频链路为：

```text
vo=gpu-next
gpu-context=waylandvk
hwdec=auto-safe
hwdec-codecs=all
```

这套设置适合 Wayland + Vulkan 环境。`auto-safe` 优先保证硬解兼容性，
`hwdec-codecs=all` 允许全功能构建尝试更多编码格式。高负载的 8K、高帧率
内容会通过条件 profile 降低后处理或切换到音频同步，减少掉帧风险。

### 播放状态与历史

- `idle=yes`：没有文件或播放结束后保持 mpv 窗口运行。
- `ontop`：默认窗口置顶。
- `save-position-on-quit=yes`：退出时保存播放位置。
- `watch-later-dir=~~/cache/watch_later`：将 watch-later 状态放入缓存目录。
- `resume-playback-check-mtime=yes`：文件修改时间改变时避免错误恢复同名文件。
- `save-watch-history=yes`：将播放记录写入 `files/watch_history.jsonl`。
- `reset-on-next-file=...`：切换文件时重置音轨、字幕、滤镜、速度、色彩和画面变换。
- `hr-seek=yes`：默认启用精确跳转。
- `hr-seek-framedrop=no`：精确跳转时不主动丢帧，便于保持音视频同步和配合补帧。

### OSD、字体与 Catppuccin Mocha

主 OSD、文本字幕和 uosc 使用 LXGW WenKai Screen，并回退到 Noto Color Emoji。
当前主题是 [Catppuccin Mocha](https://catppuccin.com/palette/)：

| 用途 | 颜色 |
| --- | --- |
| Text | `#CDD6F4` |
| Crust | `#11111B` |
| Mantle | `#181825` |
| Base / Surface | `#1E1E2E` |
| Overlay | `#313244` |
| Window border | `#45475A` |
| Blue | `#89B4FA` |
| Mauve | `#CBA6F7` |
| Green | `#A6E3A1` |
| Red | `#F38BA8` |

对应设置分布在：

- `mpv.conf`：`osd-color`、`osd-back-color`、字幕颜色和轮廓。
- `script-opts/uosc.conf`：uosc 控件、菜单、时间轴、选中状态和提示颜色。
- `scripts/manager.lua`：更新器底部进度条的独立颜色。

原生 OSC 通过 `osc=no` 禁用，由定制版 uosc 提供播放控制界面。

### 音频

- `ao=pipewire`：Linux 下使用 PipeWire。
- `audio-format=float`：使用浮点格式处理音频。
- `audio-channels=auto-safe`：默认按安全方式选择输出声道。
- `replaygain=album`：优先使用专辑 ReplayGain。
- `gapless-audio=weak`：音乐模式下尽量无缝切歌，同时保留格式变化时的兼容性。
- `audio-file-auto=fuzzy`：从 `audio/` 等目录自动查找匹配音轨。
- `alang=japanese,jpn,jap,ja,jp,english,eng,en`：日语优先，其次英语。

### 字幕

- `sub-codepage=gb18030`：兼容常见中文文本字幕编码。
- `sub-auto=fuzzy`：自动加载匹配的外挂字幕。
- `sub-file-paths=sub:subs:subtitles:字幕`：搜索多个字幕目录。
- `slang=chs,sc,zh-Hans,zh-CN,cht,tc,zh-Hant,zh-HK,zh-TW,chi,zho,zh`：
  优先加载中文字幕。
- 默认字幕字体为 `LXGW WenKai Screen`，字号为 34。
- 支持字幕重载、轨道切换、字幕同步、字幕导出、Whisper 生成字幕和字幕兼容性
  开关，见[字幕快捷键](#字幕)。

### 截图

默认截图为 WebP：

```text
screenshot-format=webp
screenshot-webp-quality=85
screenshot-webp-compression=6
screenshot-tag-colorspace=yes
```

截图模板为：

```text
~~/files/screen/%{media-title}-%P-%n
```

因此截图会保存在 `files/screen/`，同时保留正确的色彩空间标记。`profiles.conf`
中的 `截图` profile 可以临时切换到高质量 PNG。

### 网络播放与 yt-dlp

- `ytdl=yes`：启用 mpv 的 URL 解析增强。
- 默认优先选择 2160p 以下视频并排除 VP9.2。
- 通过 `cookies-from-browser=Firefox` 读取 Firefox cookies。
- `script-opts/quality-menu.conf` 与 `quality-menu.lua` 提供视频 / 音频格式菜单。
- `profiles.conf` 中的 `网络流` 会在 `demuxer-via-network=yes` 时自动启用：
  预读目标为 30 秒，前向缓存上限为 256 MiB，回退缓存上限为 32 MiB。
- `直播` 是需要手动应用的低缓存、低延迟场景配置，不会被普通网络视频自动触发。

### 输入策略

`input-default-bindings=no` 会关闭 mpv 默认键位和脚本默认键位注册方案，
主要行为统一由 `input.conf` 显式定义。这样可以减少不同脚本之间的快捷键冲突，
也便于通过 uosc 菜单找到对应操作。

## 画质与色彩 profile

### 当前默认启用

`mpv.conf` 当前启用以下 profile：

```text
profile=Target
profile=Dither
profile=HQ
profile=HDR2SDR
```

| Profile | 作用 |
| --- | --- |
| `Target` | 使用目标色彩空间链路，不自动套用系统 ICC |
| `Dither` | 使用 `fruit` 抖动，降低量化色带且开销适中 |
| `HQ` | EWA Lanczos Sharp、Catmull-Rom、抗振铃和 sigmoid upscaling |
| `HDR2SDR` | HDR 到 SDR 的动态峰值检测和 tone mapping |

`Target` 与 `ICC` / `ICC+` 是不同的色彩管理路径，不建议同时启用。

### 主配置中的可选 profile

| Profile | 用途 |
| --- | --- |
| `ICC` | 使用系统自动发现的 ICC 配置 |
| `ICC+` | 使用仓库中的 ICC 文件或手动指定的显示器 ICC |
| `Dither+` | Floyd-Steinberg 误差扩散，质量更高、开销更大 |
| `Tscale` | `display-resample + oversample` 时域插值 |
| `Tscale+` | `display-resample + sphinx` 时域插值 |
| `DeBand-low` | 轻度去色带 |
| `DeBand-medium` | 中等去色带 |
| `DeBand-high` | 强去色带 |
| `SDR2HDR` | SDR 反向映射到 HDR，仅适合 HDR 显示设备 |
| `SWscaler` | 软件缩放器备用方案 |
| `NNEDI3` / `NNEDI3+` | 高质量神经网络插值，后者开销更大 |
| `ravu-zoom` | 较轻量的通用放大 |
| `FSRCNNX` / `FSRCNNX+` | HD 放大 / SD 去伪影变体 |
| `Ani4K` / `AniSD` | 动画和 SD 动画的高负载 ArtCNN 方案 |
| `Anime4K` | KrigBilateral + Anime4K 修复、抗锯齿和高光限制 |
| `SSIM` | 适合 4K 或希望控制开销的场景 |

### `profiles.conf` 场景模式

除 `网络流` 会按网络媒体属性自动触发外，其余场景 profile 需要在启动参数或配置中
使用 `--profile=<名称>`；也可以通过快捷键动态应用部分着色器 profile。

| Profile | 说明 |
| --- | --- |
| `游戏` | 低延迟、高性能，关闭插帧和去色带 |
| `电影` | 高质量、插帧、去色带和 HDR 映射 |
| `动画` | 动画专用 Anime4K 修复与去模糊 |
| `低功耗` | 关闭硬解并降低缩放和解码负载，适合排查性能问题 |
| `网络流` | 网络媒体自动触发，使用 30 秒预读、256 MiB 前向缓存和网络超时设置 |
| `HDR画质` | 手动 HDR 画质预设：目标峰值、色域映射和 PixelClipper |
| `截图` | PNG 高质量截图和高质量缩放 |
| `直播` | 低缓存、低延迟和流重连 |

### 自动条件 profile

以下 profile 由 mpv 属性或媒体参数自动触发：

| Profile | 触发目的 |
| --- | --- |
| `hdr-2390` | 使用 BT.2390 时调整 tone mapping 参数 |
| `peak-percentile` | 对低亮度 HDR 场景降低峰值百分位 |
| `SDR-gamut` | 对非 BT.709 SDR 内容使用 clip 色域映射 |
| `SDR-target` | 对普通 SDR 内容关闭不必要的目标色彩提示 |
| `HDR` | 识别 PQ / HLG 内容并设置 HDR 目标参数 |
| `HDR-PASS` | HDR 显示设备满足条件时启用直通路径 |
| `video-sync` | 速度修正较大时切换到 `display-tempo` |
| `fps-fix` | 高帧率视频改用音频同步，降低异常耗能 |
| `8k-fix` | 8K 级别视频关闭高负载后处理并降低掉帧风险 |
| `pgs-fix` | 修复超宽画面中 PGS 字幕的比例错位 |
| `pause` | 暂停时取消置顶 |
| `maximized` | 最大化时禁止自动调整窗口大小 |
| `minimized` | 最小化时自动暂停 |
| `end` | 播放结束后退出全屏和最大化 |
| `media-title` | 网络协议和磁链使用媒体标题作为窗口标题 |

## uosc 界面

当前定制版 uosc 位于 `scripts/uosc/`，版本标识为 `5.12.0`。它不是可以随意
整体替换的上游副本，原因是本地对菜单、时间轴、顶栏、鼠标行为、动画和颜色
有定制。

### 主要外观设置

来自 `script-opts/uosc.conf`：

| 设置 | 当前值 | 作用 |
| --- | --- | --- |
| `timeline_style` | `bar` | 展开时间轴使用条形样式 |
| `timeline_size` | `12` | 展开时间轴高度 |
| `timeline_cache` | `no` | 不显示网络渲染缓存指标 |
| `timeline_heatmap` | `no` | 不显示 YouTube 热图 |
| `chapter_display` | `yes` | 在时间轴显示章节标记和名称 |
| `controls_size` | `36` | 控制按钮尺寸 |
| `controls_margin` | `18` | 控制栏外边距 |
| `controls_persistency` | `idle` | 空闲时保留控制栏 |
| `menu_font` | `LXGW WenKai Screen` | 菜单字体 |
| `menu_item_height` | `44` | 菜单项目高度 |
| `scale` | `1.30` | 界面缩放 |
| `font_scale` | `1.15` | 文字缩放 |
| `border_radius` | `7` | 控件和菜单圆角 |
| `pause_indicator` | `none` | 不显示中央暂停指示器 |
| `progress` | `windowed` | 窗口模式显示细进度条 |
| `progress_playing_only` | `yes` | 只在实际播放时显示细进度条 |
| `dock_animation` | `yes` | 启用底部 Dock 动画 |
| `dock_animation_mode` | `classic` | 默认使用经典 Morph 动画 |

### 控制栏

控制栏根据媒体类型动态显示，包含以下功能：

- 打开文件、最近播放和按钮提示。
- 音轨、字幕轨和弹幕菜单。
- 时间显示、上一集、停止、播放 / 暂停、下一集和播放速度。
- WebDAV 快捷入口。
- 片头片尾标记与跳过。
- 播放列表、统计信息和更多菜单。
- 空闲状态下保留打开文件、历史、WebDAV、播放列表等入口。

时间轴右键绑定为 `uosc/chapters`，不会修改视频或片头片尾标记。
uosc 快捷键面板由 `CTRL+ALT+u` 打开，界面开关由
`CTRL+ALT+SHIFT+u` 控制。

## 脚本功能

### 界面、播放列表与文件

| 脚本 | 功能 |
| --- | --- |
| `uosc/` | 主播放界面、菜单、时间轴、顶栏、缩放和自定义按钮 |
| `uosc_danmaku/` | 弹幕搜索、加载、延迟、保存、源管理和弹幕样式菜单 |
| `thumbfast.lua` | 时间轴缩略图预览 |
| `playlistmanager.lua` | 播放列表浏览、排序、移动、保存、随机和网络标题解析 |
| `playlist-view.lua` | 播放列表视图 |
| `file-browser/` | OSD 文件浏览器、目录缓存、收藏和多选 |
| `open_dialog.lua` | 调用原生文件选择器 |
| `command_palette.lua` | 命令面板 |
| `dyn_menu.lua` / `cycle-commands.lua` | 动态菜单和循环命令 |

### 历史、书签与状态

| 脚本 | 功能 |
| --- | --- |
| `simplehistory.lua` | 播放历史、隐身历史、恢复进度和最近播放菜单 |
| `recentmenu.lua` | 对历史菜单进行 uosc / select / 命令面板适配 |
| `simplebookmark.lua` | 文件书签和进度书签 |
| `history-bookmark.lua` | 历史与书签辅助功能 |
| `auto-save-state.lua` | 自动保存状态 |
| `episode-preferences.lua` | 在同一连续剧内临时保持音轨、字幕位置和播放倍速 |
| `persist_properties.lua` | 跨文件持久化指定属性 |
| `memo.lua` | 本地备注记录 |
| `undoredo.lua` | 跳转和循环跳转撤销 / 重做 |

### 字幕、章节与片段

| 脚本 | 功能 |
| --- | --- |
| `sub-select.lua` | 字幕选择 |
| `sub-assrt.lua` | 字幕下载菜单 |
| `autosubsync/` | 字幕同步菜单和同步处理 |
| `sub-fastwhisper.lua` | 使用本地 Whisper 生成字幕 |
| `sub_export.lua` | 导出当前内封字幕 |
| `uosc-subtitle-lines.lua` | 在 uosc 中查看字幕行内容 |
| `mute-on-specific-subtitle-words.js` | 根据指定字幕词语切换静音 |
| `chapter-list.lua` | 章节列表 |
| `chapter-make-read.lua` | 创建、编辑、删除和写出章节文件 |
| `chapterskip.lua` | 静音跳转、章节跳过和片头片尾标记 |
| `mpv_chapters.js` | JavaScript 章节列表 |
| `skip-segments.lua` | 标记、编辑和自动跳过片头片尾 |

### 画面、音频和截图

| 脚本 | 功能 |
| --- | --- |
| `dynamic-crop.lua` | 检测并切除黑边，只对视频流工作 |
| `hdr-mode.lua` | HDR 模式辅助 |
| `drcbox.lua` | 音频动态范围处理 |
| `music-mode.lua` | 音乐播放模式 |
| `playback-info.lua` | 播放信息面板 |
| `stats.lua` | 中文增强统计信息 |
| `screenshot-to-clipboard.lua` | 截图并复制到剪贴板 |
| `mpv-animated.lua` | 动图截取与导出 |
| `pip.lua` | 画中画辅助 |
| `startup-format-logos.lua` | 起播时显示编码、音频、字幕等格式徽标 |

### 在线服务和远程控制

| 脚本 | 功能 |
| --- | --- |
| `quality-menu.lua` | 使用 yt-dlp 选择在线视频和音频格式 |
| `simple-mpv-webui/` | 提供浏览器控制界面，端口由 `script-opts/webui.conf` 决定 |
| `trakt-scrobble/` | Trakt 搜索和播放记录同步 |
| `sponsorblock` 相关脚本 | 跳过已标记的赞助商片段 |
| `trackselect.lua` | 按语言或元数据辅助选择音轨 |

### 画质增强资源

`shaders/` 按用途收录多类 GLSL 资源，包括：

- Anime4K、Ani4K、AniSD、ArtCNN、ACNet、CuNNy。
- FSRCNNX、NNEDI3、RAVU、SSIM、AiUpscale。
- KrigBilateral、JointBilateral、色度升频和自适应锐化。
- SMAA、DLAA、CMAA、去色带、降噪、翻转、旋转、缩放和色温滤镜。

`vs/` 收录 VapourSynth 处理链，包括：

- `MEMC_*`：RIFE、SVP、MVT 和 DRBA 补帧。
- `SR_*`：ACNet、ArtCNN 超分。
- `NR_*`：BM3D、CCD 降噪。
- `ETC_DEINT_EX`：去交错。
- `MIX_UAI_*`：AI 画质增强。

## 快捷键

快捷键定义在 `input.conf`。下表只记录当前启用的绑定；以大写字母书写的键名
表示需要按住 `Shift`，例如 `A` 与 `a` 是两个不同绑定。uosc 菜单中的项目
也来自 `input.conf` 行尾的 `#menu:` 注释。

为避免被 niri 的全局绑定截获，mpv 不直接使用 `F2`、`F7`–`F11` 和
`CTRL+LEFT` / `CTRL+RIGHT`；对应功能使用下表中的带修饰键组合。

### 打开、历史、书签与剪贴板

| 按键 | 功能 |
| --- | --- |
| `o` | 打开 uosc 内置文件浏览器 |
| `CTRL+o` | 打开原生文件浏览器 |
| `TAB` | 打开 OSD 文件浏览器并刷新 |
| `` ` `` | 打开播放历史 |
| `ALT+l` | 切换隐身历史模式 |
| `CTRL+L` | 加载最后播放文件 |
| `CTRL+l` | 加载最后播放文件及进度 |
| `N` | 打开书签菜单 |
| `CTRL+n` | 添加进度书签 |
| `CTRL+N` | 添加文件书签 |
| `ALT+C` | 打开剪贴菜单 |
| `CTRL+c` | 复制文件路径和进度 |
| `CTRL+ALT+c` | 只复制文件路径 |
| `CTRL+v` | 跳转到剪贴板中的路径或进度 |
| `CTRL+ALT+v` | 将剪贴板内容加入播放列表 |
| `CTRL+F` | 打开 / 关闭 yt-dlp 视频格式菜单 |
| `ALT+F` | 打开 / 关闭 yt-dlp 音频格式菜单 |
| `CTRL+ALT+h` | 打开近期播放菜单 |

### 文件、窗口与播放状态

| 按键 | 功能 |
| --- | --- |
| `SHIFT+F11` | 停止当前播放 |
| `ALT+t` | 切换窗口置顶 |
| `ALT+b` | 切换窗口最大化 |
| `ENTER` | 切换全屏 |
| `i` | 临时显示统计信息 |
| `I` | 常驻显示统计信息 |
| `l` | 设置或清除 A-B 片段循环 |
| `L` | 切换单文件循环 |
| `n` | 随机播放列表 |
| `[` / `]` | 播放速度减 0.1 / 加 0.1 |
| `{` / `}` | 播放速度减半 / 加倍 |
| `BS` | 播放速度重置为 1.0 |
| `ALT+o` | 在文件管理器中定位当前文件 |
| `DEL` | 删除当前文件，并要求确认 |
| `b` | 最小化窗口 |
| `q` | 退出 mpv |
| `Q` | 退出并保存 watch-later 状态 |

### 导航、章节与跳转

| 按键 | 功能 |
| --- | --- |
| `O` | 切换 OSD 时间轴 |
| `F4` | 打开综合 OSD 菜单 |
| `F5` | 打开播放列表 |
| `F6` | 打开音频设备列表 |
| `CTRL+F7` | 打开章节列表 |
| `CTRL+F8` | 打开轨道列表 |
| `CTRL+F9` | 打开视频轨列表 |
| `CTRL+F10` | 打开音频轨列表 |
| `CTRL+F11` | 打开字幕轨列表 |
| `ALT+c` | 标记章节时间 |
| `ALT+e` | 编辑当前章节标题 |
| `ALT+r` | 删除当前章节 |
| `ALT+w` | 写出 CHAPTER 文件 |
| `ALT+g` | 写出 OGM 章节文件 |
| `<` / `>` | 播放列表上一个 / 下一个文件 |
| `PGDWN` / `PGUP` | 上一章节 / 下一章节 |
| `F3` | 跳到下一个静音位置 |
| `ALT+q` | 切换章节跳过模式 |
| `ALT+n` | 标记片头或片尾 |
| `,` / `.` | 上一帧 / 下一帧 |
| `LEFT` / `RIGHT` | 后退 30 秒 / 前进 60 秒 |
| `SHIFT+LEFT` / `SHIFT+RIGHT` | 精确后退 / 前进 1 秒 |
| `SHIFT+DOWN` / `SHIFT+UP` | 精确后退 80 秒 / 前进 80 秒 |
| `CTRL+z` / `CTRL+x` | 撤销 / 重做跳转 |
| `CTRL+ALT+z` | 撤销循环跳转 |

### 画面、窗口缩放与色彩

| 按键 | 功能 |
| --- | --- |
| `A` | 循环切换 16:9、4:3、2.35:1 和默认宽高比 |
| `ALT+SHIFT+LEFT` / `ALT+SHIFT+RIGHT` | 左旋转 / 右旋转视频 |
| `CTRL+-` / `CTRL+=` | 缩小 / 放大窗口 |
| `ALT+-` / `ALT+=` | 缩小 / 放大视频画面 |
| `ALT+LEFT` / `ALT+RIGHT` | 向左 / 向右移动画面 |
| `ALT+UP` / `ALT+DOWN` | 向上 / 向下移动画面 |
| `ALT+p` | 切换裁切填充 |
| `ALT+BS` | 重置画面缩放、裁切、旋转、平移和宽高比 |
| `CTRL+I` | 切换 ICC 自动校色 |
| `1` / `2` | 对比度减 1 / 加 1 |
| `3` / `4` | 明度减 1 / 加 1 |
| `5` / `6` | 伽马减 1 / 加 1 |
| `7` / `8` | 饱和度减 1 / 加 1 |
| `-` / `=` | 色相减 1 / 加 1 |
| `CTRL+BS` | 重置对比度、明度、伽马、饱和度和色相 |
| `D` | 切换 deband |
| `ALT+z` / `ALT+x` | 增加 / 降低 deband 强度 |
| `h` | 循环切换 HDR tone mapping 曲线 |
| `ALT+h` | 切换 HDR 动态峰值检测 |
| `CTRL+h` | 切换 HDR 直通提示 |
| `CTRL+t` | 循环切换显示器传输特性 |
| `CTRL+T` | 切换映射目标峰值 100 / 203 |
| `CTRL+g` | 切换色域映射模式 |

### 视频、截图与动图

| 按键 | 功能 |
| --- | --- |
| `ALT+i` | 切换插帧 / 抖动补偿 |
| `C` | 切换 dynamic-crop 去黑边 |
| `d` | 切换去交错 |
| `s` | 有字幕、无 OSD 的源尺寸单帧截图 |
| `S` | 无字幕、无 OSD 的源尺寸单帧截图 |
| `CTRL+s` | 有字幕、有 OSD 的窗口尺寸单帧截图 |
| `ALT+s` | 有字幕、无 OSD 的逐帧截图 |
| `ALT+S` | 无字幕、无 OSD 的逐帧截图 |
| `CTRL+S` | 有字幕、有 OSD 的窗口尺寸逐帧截图 |
| `c` | 标记片段剪切起止位置 |
| `a` | 切换剪切音频信息 |
| `CTRL+C` | 清除剪切标记 |
| `w` / `W` | 设置动图开始 / 结束时间 |
| `CTRL+w` | 导出无字幕动图 |
| `CTRL+W` | 导出带字幕动图 |

### 音频与音量

| 按键 | 功能 |
| --- | --- |
| `UP` / `DOWN` | 音量加 5 / 减 5 |
| `9` / `0` | 音量减 1 / 加 1 |
| `y` | 切换音轨 |
| `m` | 切换静音 |
| `CTRL+,` / `CTRL+.` | 音频延迟减 0.1 / 加 0.1 |
| `;` | 重置音频延迟 |
| `CTRL+y` | 切换音频独占模式 |
| `CTRL+Y` | 切换精确跳转丢帧同步模式 |
| `ALT+y` | 循环切换 7.1、5.1、立体声和自动声道模式 |
| `CTRL+F2` | 循环切换动态范围 / 响度滤镜 |
| ``ALT+` `` | 清空音频滤镜 |

### 字幕

| 按键 | 功能 |
| --- | --- |
| `j` | 切换主字幕轨 |
| `k` | 切换次字幕轨 |
| `v` / `ALT+V` | 切换主字幕 / 次字幕可见性 |
| `u` | 切换 ASS 字幕渲染样式 |
| `F` | 循环切换默认字幕字体 |
| `CTRL+r` | 重载当前字幕 |
| `ALT+R` | 切换次字幕样式覆盖 |
| `ALT+T` | 切换字幕与视频帧混合 |
| `K` | 切换字幕时序修复 |
| `J` | 切换 ASS 字幕颜色转换兼容 |
| `V` | 切换使用视频信息渲染字幕 |
| `ALT+B` | 切换 bidi 双向检测兼容 |
| `ALT+X` | 切换 ASS 阴影边框缩放覆盖 |
| `H` | 切换 ASS 字幕输出到黑边 |
| `ALT+Z` | 切换文本字幕输出到黑边 |
| `P` | 切换 PGS 字幕铺满屏幕 |
| `p` | 切换 PGS 字幕灰度转换 |
| `Y` | 切换字幕选择脚本 |
| `CTRL+f` | 打开字幕下载菜单 |
| `CTRL+m` | 打开字幕同步菜单 |
| `CTRL+M` | 打开字幕内容菜单 |
| `ALT+m` | 导出当前内封字幕 |
| `ALT+f` | 使用 Whisper 生成 AI 字幕 |
| `r` / `t` | 主字幕上移 / 下移 |
| `R` / `T` | 次字幕上移 / 下移 |
| `z` / `x` | 主字幕延迟减 0.1 / 加 0.1 |
| `Z` / `X` | 次字幕延迟减 0.1 / 加 0.1 |
| `ALT+j` / `ALT+k` | 主字幕缩小 / 放大 |
| `CTRL+j` / `CTRL+k` | 跳转上一条 / 下一条字幕 |
| `SHIFT+BS` | 重置字幕位置、字号和延迟 |

### 视频滤镜

| 按键 | 功能 |
| --- | --- |
| ``CTRL+` `` | 清空视频滤镜 |
| `ALT+v` | 切换弱去色块滤镜 |
| `!` | 切换限定色域格式滤镜 |
| `@` | 垂直翻转 |
| `SHARP` | 水平翻转 |
| `$` | 旋转 180 度 |
| `%` | Gamma 2.2 修正 |
| `^` | 强制 59.94 fps |
| `*` | 填充 16:9 黑边并居中 |
| `&` | 6500K 色温修正 |

### 着色器

| 按键 | 着色器 |
| --- | --- |
| `CTRL+0` | 清空所有 GLSL 着色器 |
| `CTRL+1` | KrigBilateral |
| `CTRL+2` | SSimSuperRes |
| `CTRL+3` | SSimDownscaler |
| `CTRL+4` | adaptive-sharpen |
| `CTRL+5` | FSRCNNX |
| `CTRL+6` | FSRCNNX distort |
| `CTRL+7` | NNEDI3 nns32 win8x4 |
| `CTRL+8` | RAVU zoom |
| `CTRL+9` | Anime4K 抗锯齿 |

### profile、命令面板与工具

| 按键 | 功能 |
| --- | --- |
| `CTRL+P` | 循环切换 FSRCNNX、FSRCNNX+、NNEDI3、ravu-zoom 和 Anime4K |
| `ALT+1` | 应用 `FSRCNNX` |
| `ALT+2` | 应用 `FSRCNNX+` |
| `ALT+3` | 应用 `ravu-zoom` |
| `ALT+4` | 应用 `Ani4K` |
| `ALT+5` | 应用 `AniSD` |
| `ALT+6` | 应用 `Anime4K` |
| `ALT+7` | 应用 `NNEDI3` |
| `ALT+8` | 应用 `NNEDI3+` |
| `CTRL+B` | 切换标题栏 |
| `CTRL+R` | 切换播放下一个文件时重置的状态集合 |
| `~` | 打开 mpv 控制台 |
| `Ctrl+p` | 打开 Command Palette |
| `CTRL+ALT+u` | 打开 uosc 快捷键面板 |
| `CTRL+ALT+SHIFT+u` | 显示 / 隐藏 uosc 界面 |
| `CTRL+ALT+t` | 复制当前时间 |
| `CTRL+ALT+s` | 复制当前字幕内容 |
| `M` | 检查并更新第三方脚本和着色器 |
| `CTRL+ALT+SHIFT+s` | 截图到剪贴板 |
| `CTRL+ALT+b` | 切换 SponsorBlock |
| `CTRL+ALT+i` | 显示 / 隐藏播放信息面板 |
| `CTRL+ALT+SHIFT+t` | 复制当前时间戳 |
| `CTRL+ALT+g` | 显示 / 隐藏 JavaScript 章节列表 |
| `CTRL+ALT+m` | 根据字幕特定词语切换静音 |

### Trakt、弹幕和 Web 功能

| 按键 | 功能 |
| --- | --- |
| `ALT+d` | 打开 Trakt 搜索菜单 |
| `ALT+D` | 切换 Trakt 播放记录同步 |
| `CTRL+d` | 显示 / 隐藏弹幕 |
| `CTRL+D` | 打开弹幕综合菜单 |
| `CTRL+ALT+d` | 弹幕延迟加 1 秒 |
| `CTRL+ALT+a` | 弹幕延迟减 1 秒 |
| `_` | 立即保存当前弹幕 |
| `ALT+_` | 检查弹幕脚本更新 |

### 鼠标、媒体键和退出

| 按键 | 功能 |
| --- | --- |
| `MENU` | 开关 uosc 菜单 |
| `POWER` | 退出 mpv |
| `PLAY` / `PAUSE` / `PLAYPAUSE` | 播放 / 暂停 |
| `STOP` | 退出 mpv |
| `FORWARD` / `REWIND` | 前进 30 秒 / 后退 30 秒 |
| `NEXT` / `PREV` | 播放列表下一个 / 上一个文件 |
| `SPACE` | 播放 / 暂停 |
| `MBTN_LEFT` | 播放 / 暂停 |
| `MBTN_Right` | 开关 uosc 菜单 |
| `MBTN_FORWARD` / `MBTN_BACK` | 播放列表下一个 / 上一个文件 |
| `Wheel_Up` / `Wheel_Down` | 音量加 10 / 减 10 |
| `ESC` | 退出全屏并取消窗口最大化 |

## 第三方更新器

按 `M` 会运行 `scripts/manager.lua`，来源由根目录的 `manager.json` 管理。
更新器使用异步 Git 子进程，不阻塞 mpv 的播放和其他 Lua 脚本，并在 uosc / OSD
底部显示来源、阶段和总体进度。

### 来源策略

| 来源 | 目标目录 | 模式 | 说明 |
| --- | --- | --- | --- |
| `uosc` | `scripts/uosc` | `check` | 基于本地定制版 `5.12.0`，只检查上游 |
| `uosc_danmaku` | `scripts/uosc_danmaku` | `check` | 本地有弹幕适配和行为定制 |
| `trakt_scrobble` | `scripts/trakt-scrobble` | `check` | 本地配置可能包含服务适配 |
| `simple_mpv_webui` | `scripts/simple-mpv-webui` | `check` | 本地端口和页面有定制 |
| `anime4k` | `shaders/Anime4K/glsl` | `replace` | 允许整体替换上游 GLSL 目录 |
| `file_browser` | `scripts/file-browser` | `replace` | 允许整体替换上游文件浏览器 |

### `check` 与 `replace`

- `check`：获取上游分支并比较提交和目录树，只报告是否有更新，绝不覆盖本地目录。
- `replace`：确认上游目录树确实变化后，才暂存、备份和整体替换。
- 无变化时不更新、不创建备份、不改动目标目录。
- 已管理目录出现本地修改时，`replace` 会保护性跳过，避免覆盖本地文件。
- 旧版嵌套 `.git` 会移动到 `.manager/backups/<name>/`，不会参与目标目录复制。
- 每个来源使用 `.manager/<name>.git` bare mirror，并在 `.manager/state.json` 保存状态。
- mpv 退出时会中止仍在运行的更新子进程。

`manager.json` 中的 `baseline` 用于记录定制版本基于哪个上游版本或提交。
例如 uosc 当前 baseline 为 `5.12.0`；发现上游版本变化时，需要人工比较和合并
本地改动，再决定是否更新 baseline。不要把 `.manager/` 缓存目录提交到仓库。

添加来源时，建议先使用 `check`：

```json
{
  "name": "unique_name",
  "url": "https://github.com/owner/project.git",
  "branch": "main",
  "source": "upstream/subdirectory",
  "destination": "scripts/project",
  "mode": "check",
  "baseline": "v1.0.0"
}
```

只有明确允许整体替换、且没有本地定制的目录，才使用
`"mode": "replace"`。

## 依赖与注意事项

- `vo=gpu-next` 和 `gpu-context=waylandvk` 适用于 Wayland；在 X11 或 Windows
  环境中需要调整 GPU context。
- `hwdec=auto-safe` 不能保证所有显卡驱动和编码格式都能硬解。遇到画面异常时，
  可用 `--hwdec=no` 临时排查。
- `dynamic-crop.lua` 只处理视频流。播放音乐封面或单张图片时看到
  `only works for videos` 属于预期行为。
- VapourSynth、Anime4K、NNEDI3、Ani4K 和 Whisper 等高负载功能会明显增加
  GPU / CPU 使用率，建议按片源和设备性能选择。
- `ytdl-raw-options-append=cookies-from-browser=Firefox` 需要 Firefox cookies
  可访问，并且不应把浏览器 cookies 文件复制进仓库。
- WebUI 会监听由 `script-opts/webui.conf` 指定的地址和端口。若监听在局域网
  地址，应确认防火墙和访问权限。
- `cache/`、`files/` 和 `.manager/` 是运行时目录，已在 `.gitignore` 中排除。
- 字体、ICC、着色器和脚本属于配置的一部分，克隆后不要只复制 `mpv.conf`。
- 修改 `uosc` 时应优先手动比较上游变化；不要对当前定制目录直接执行上游整体覆盖。

## 相关链接

- [mpv 官方手册](https://mpv.io/manual/master/)
- [uosc](https://github.com/tomasklaen/uosc)
- [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)
- [thumbfast](https://github.com/po5/thumbfast)
- [InputEvent](https://github.com/zhongfly/InputEvent)
- [Catppuccin Mocha 调色板](https://catppuccin.com/palette/)
