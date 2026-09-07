# 更新记录

记录配置仓库的同步与结构调整。日常小改动见 git 提交历史；每次与
mpv-Yaozhi 便携包同步后，在此追加一条记录，写明合并范围、保留的本地
定制和跳过的内容，方便下次同步时对照。

同步流程约定：

1. 先提交本地当前状态作为还原点快照。
2. 在 git 历史中找到本地定制版首次入库的提交作为三方合并基点，对
   双方都改过的文件执行 `git merge-file` 三方合并，禁止整目录覆盖。
3. 合并后对全部改动文件做 `luajit` 语法解析，再用 `--idle` 冒烟测试
   确认无脚本加载错误。
4. 检查 `script-opts/` 键名与新脚本的选项表是否兼容。
5. 在本文件追加记录并提交。

## 2026-08-29 同步 Yaozhi 8.29 更新

来源：`~/Downloads/mpv-Yaozhi/portable_config`（2026.8.29 版便携包，
含当天发布的 uosc 菜单改版）。同步前快照提交为 `cd721b4`，本次同步
提交为 `007b86e`，如需回退可 `git revert 007b86e`。

### uosc（8 文件三方合并）

以 `ecbb57c`（本地定制版首次入库）为基点，对 `main.lua`、
`elements/Menu.lua`、`elements/Timeline.lua`、`elements/Button.lua`、
`elements/TopBar.lua`、`lib/menus.lua`、`lib/cursor.lua`、
`lib/utils.lua` 三方合并。

引入 Yaozhi 新版特性：

- 画面区域右键菜单贴近鼠标位置打开（`menu-blurred-at` 消息与 Menu 的
  `anchor_x` / `anchor_y` 锚点），配套 `conditional-rightclick.lua` 更新。
- 主菜单紧凑布局与 hint 省略号参数（`hint_max_ratio` 等）。
- 文件名自然排序浮点数修复（上游 5.13.0 的 fix）。

保留的本地定制（合并后逐项验证存在）：

- `timeline_mbtn_right` 时间轴右键章节菜单（本地 Timeline 实现 +
  `uosc.conf` 在用）。
- 按钮 `primary_click` 全点击修复，防止点击穿透（Yaozhi 仍为
  `primary_down`，保留本地）。
- cursor disablers：console 等 mpv 界面打开时挂起 uosc 光标处理。
- TopBar 关闭键 hover 使用 `config.color.error`（Yaozhi 为硬编码蓝色）。

冲突处理：`Menu.lua` 构造函数处两侧初始化都保留；`lib/utils.lua` 两处
属性读取写法差异取 Yaozhi 版，顺带修复本地曾意外退化丢失的自然排序
浮点修复（`padnum`）。

### uosc_danmaku（3 文件）

- `apis/dandanplay.lua`：集数请求竞态防护（防止旧请求覆盖新结果）。
- `sites/bilibili.lua`：响应 XML 合法性校验 + `--compressed`。
- `main.lua`：历史记录关联（`association`）修正。

本地 `modules/menu.lua`、`modules/render.lua` 的粉紫配色是本地定制，
未同步。

### 共享脚本（同步 6 个，跳过 3 个）

| 文件 | 说明 |
| --- | --- |
| `thumbfast.lua` | 新版含两阶段预览（先关键帧后精确画面）、`alist` / `fast_seek` 新选项；本地 `max_height=200` 等个人设置保留 |
| `stats.lua` | 新版；补齐硬依赖模块（见下） |
| `conditional-rightclick.lua` | 改用 `menu-blurred-at`，右键菜单开在鼠标处 |
| `startup-format-logos.lua` | 新增 DRA 音频编码识别，重构 APE 识别 |
| `dynamic-crop.lua` | 起播时视频尺寸未就绪会自动重试（适配 VapourSynth / RIFE 首帧窗口）；Yaozhi 侧静音了一条裁剪 OSD 提示 |
| `simplehistory.lua` | 新版修复；补回本地 2 处 `F4D6CD` 粉色 OSD 定制 |

跳过及理由：

- `music-mode.lua`：差异仅为"音乐模式→音乐播放模式"措辞与配色，
  无功能修复。
- `hdr-mode.lua`：Windows 专属（依赖 `display-info.dll`），本地版本
  开头即非 Windows 直接 `return`，属死代码。
- `autoload.lua`：两边是同一血统的不同定制变体（本地有
  `MAX_ENTRIES` / `MAX_DIR_STACK` / `directory_mode` 等自己的改动），
  整取会丢失本地逻辑，留待有实际需求时再做人工合并。

另外确认 `episode-preferences`、`open_dialog`、`playlistmanager`、
`skip-segments`、`evafast`、`history-bookmark` 为本地更新，不需要反向
同步。

### 配套调整

- `script-modules/audio-stats-info.lua`：新 stats.lua 的硬依赖，从
  Yaozhi 补齐；`startup-logo-bounds.lua` 两边一致，无需变动。
- `script-opts/startup_format_logos.conf`：`audio_priority` 补上
  `dra`，与新脚本默认值对齐。

### 验证

- 全部改动 Lua 文件通过 `luajit` 语法解析。
- `--idle` 冒烟测试：`uosc-version`、`uosc_danmaku-version` 正常广播，
  全部脚本零加载错误；新 stats.lua 的模块加载无报错。
- `script-opts/` 全部相关 conf 键名与新脚本选项表比对，无失效键；
  `thumbfast.conf` 新键 `alist`（默认关）、`fast_seek`（默认开）走
  合理默认值。

### 遗留事项

- `manager.json` 的 `uosc_danmaku` 源指向 `Tony15246/uosc_danmaku`，
  但本地实际血统（含 `modules/resolver_affinity.lua`，Yaozhi 系）在该
  仓库 main / dev 分支均不存在，其 `check` 结果仅供参考，不能作为
  更新依据。
- uosc `baseline` 仍为 `5.12.0`：合并后的本地内容相当于"5.13.0 开发
  快照 + Yaozhi 8.29 定制 + 本地增强"，`main.lua` 的版本字符串未改。

## 2026-09-07 同步 Yaozhi 9.7（V1.0.0）更新

来源：`~/Downloads/mpv-Yaozhi/portable_config`（2026.9.7 版便携包，
V1.0.0）。同步前快照提交为 `52cccab`。仍以 `ecbb57c` 为三方合并基点，
只同步可移植到 Linux 的脚本与配置，Windows 播放核心 / Atmos / 系统媒体
控制等二进制功能不涉及。

### uosc 界面（6 文件 + 1 新模块）

- `elements/Menu.lua` 采用 Yaozhi 9.7 新版：多级菜单贴边自动避让、进入子
  菜单后整页展开并带返回行；新增依赖 `lib/menu-layout.lua`。
- `main.lua`、`lib/menus.lua`：清晰度回退显示（无清晰度列表时显示实际
  分辨率 / 帧率）、菜单命令参数分层校验（异常地址不再拖垮 uosc）、在线
  播放列表元数据到达后合并刷新。本地 `timeline_mbtn_right` 选项保留。
- `elements/TopBar.lua`：标题与按钮按窗口高度连续缩放（540p 0.8x 起，
  4K 约 3x），不再重复叠加系统 DPI。
- `elements/Controls.lua`：竖屏播放保留完整主操作行并居中播放 / 暂停。
- `elements/BufferingIndicator.lua`：真实缓冲约 0.7 秒后才提示，取消整幕
  暗屏与中央大图标，提示贴近控制栏。
- 本地保留：Catppuccin 配色、字体与 `uosc.conf` 全部取值（上游差异仅为
  Windows 字体 / HiDPI 文案），`Timeline.lua` 本地版已含 9.7 全部改动，
  未重复覆盖。

### uosc_danmaku（5 文件）

`main.lua`、`apis/dandanplay.lua`、`apis/extra.lua`、
`modules/render.lua`、`modules/utils.lua`：请求代际取消与旧集清理
（切集 / 重新关联不再残留旧弹幕）、来源关联重建、无效来源分层拦截、
弹幕占用布局发布（统计面板避让）。本地弹幕配色与自定义来源保留。

### 在线媒体（online-media）

- `resolve_live.py`：抖音真实分辨率 / 帧率 / 码率 / HLS 与 FLV 档位合并、
  同档最高画质别名合并。
- `online-media.lua`：按上游 9.7 重构同步（直播断流有限次自动恢复、
  YouTube 路由与失败分类、系统代理协商等），并做 Linux 适配：运行时
  路径走 `script-opts/online_media.conf`（venv Python、系统 yt-dlp /
  deno）、临时目录用 `TMPDIR`、无专用 Cookie 文件时复用 Firefox 登录、
  登录文案改为 Firefox 提示。
- 新增 `resolve_youtube.py`；`script-modules/online-media-router.lua`
  增加 YouTube 链接分类。
- `bilibili-account.lua` 保持本地版（上游差异仅 Windows 路径）。

### 共享脚本与统计

- `stats.lua`：右上角版本标识（新增本地
  `script-modules/yaozhi-release.lua`）、长页按实际文字高度自动避让底栏
  与弹幕预留空间；配套 `script-modules/media-format-info.lua` 更新
  （Dolby Vision / 实际解码器识别）。
- `chapterskip.lua` 04-30 上游修复；`auto-save-state.lua` 播放中延迟落盘；
  `fix-avsync.lua` 网络流豁免；`history-bookmark.lua` 路径哈希与环境传递
  修复；`mpv-animated.lua`、`sub_export.lua` 改用参数数组避免 shell
  引号问题；`sub-assrt.lua` URL 解码修复；`uosc-subtitle-lines.lua`
  搜索样式更新。
- `episode-preferences.lua`：同一列表切集按字幕语言 / 简繁标记匹配，
  避免轨道编号变化选错字幕。
- `simplehistory.lua`：直播只保存可重新解析的直播间地址。
- `open_dialog.lua`：ISO 交给 `auto_iso_loader.lua` 改写，Linux 保留
  zenity 文件夹 / 多选。
- `persist_properties.conf`：弹幕开关跨文件保持。

### 新增脚本

- `strm-loader.lua`：本地 UTF-16 STRM 规范化为 UTF-8（UTF-8 / 网络流
  保持原生路径）。
- `media-format-metadata.lua`：解析 demuxer 报告的 Dolby Vision 配置，
  供统计与时间轴徽标使用。

### 跳过及理由

- 播放核心 / mpv-Atmos / orender / ASIO / SMTC / d3d11 显卡策略 /
  `hdr-mode.lua` / `mpv-cropscreen.lua` / `screenshot_desktop.lua` /
  `sdl-fallback.lua` / `webdav_shortcut.lua` / `network-backend.lua` /
  `audio-passthrough.lua` / `yaozhi-atmos-mode.lua` /
  `yaozhi-donation.lua`：Windows 专属。
- YouTube 专用 Chrome/Edge 登录窗口（`youtube-account.lua`、
  `youtube_cookie_import.py`）：Windows 路径 + CDP；Linux 沿用 Firefox
  cookies 方案。
- 蓝光标题列表与原盘菜单（`bluray-titles-menu.lua`、`disc-menu.lua`、
  相关 conf）：依赖原盘 JRE / libbluray 组件，本地未启用原盘菜单栈。
- file-browser 及其 fork 改动（`navigation/mouse.lua`、AList 插件、
  `file_browser.conf`、keybinds）：目录由 `manager.json` 的 replace 模式
  对接 OSS 上游，Yaozhi fork 不混入。
- `autoload`、`trackselect`、`playlistmanager`、`music-mode`、
  `sub-fastwhisper`、`evafast`：本地为同血统的不同定制变体，整取会丢
  本地逻辑 / 依赖缺失脚本（如 `seek_feedback`），维持本地版。
- `mpv.conf`、`input.conf`、`inputevent_key.conf`：上游改动整体面向
  Windows（`ytdl=no` + 全量 exclude 等）；本地保留 `ytdl=yes` 架构与
  既有键位，对应功能已通过脚本层同步。
- 各 `script-opts/*.conf` 仅核对键名，不覆盖本地字体 / 颜色 / 路径值。
- 删除已跟踪的 `online-media/__pycache__/*.pyc` 运行时缓存。

### 验证

- 全部改动 Lua 通过 `luajit` 语法解析。
- `mpv --idle --vo=null --ao=null` 冒烟测试通过，无脚本加载错误。
- `script-opts/` 键名与新版脚本选项表比对一致（uosc、uosc_danmaku、
  chapterskip、stats、auto_save_state、online_media 等）。

### 补充（核对后追加）

- `ai-interpolation.lua` 同步 9.7 的可移植部分：缩短预热启动等待
  （`start_delay` 0.8→0.35）、就绪轮询可配置
  （`startup_verify_interval`），并补充预热阶段 / 计时与建模缓存提示
  的 user-data 与 OSD。配置保留本地 `enabled=no` 默认不自动启用。
- `adaptive-quality.lua` 未同步：上游差异为 d3d11-adapter 手动显卡选择
  （Windows 专属），无 Linux 相关改动。
