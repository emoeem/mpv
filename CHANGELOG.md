# 更新记录

## 2026-10-28 · uosc 集成补全、系统监控、滤镜预设与配置健康清理

对照 Mpv∞ 的剩余可移植项做完收尾，并清理了一轮配置健康扫描发现的问题。

### 新增

- `scripts/system-monitor.lua` + `script-opts/system_monitor.conf`：系统监控 OSD
  （`CTRL+ALT+y`），读 sysfs 与 `nvidia-smi`，显示 CPU 包温度、NVIDIA/AMD GPU
  温度与功耗、内存、电池。sysfs 同步读、nvidia-smi 异步 + 结果缓存；osd_overlay
  画布必须显式同步实际 OSD 尺寸，否则 `\pos` 会被按 1280x720 基准缩放画错位置。
  电池状态用文字（充电中/电池）而不是 emoji——libass 无 emoji 回退是本配置的
  既有约束。本机无 k10temp/coretemp，CPU 温度回退到 `acpitz`。
- 风格化滤镜预设（`CTRL+ALT+f` 循环 + 「视频滤镜 > 风格预设」菜单直达）：鲜艳 /
  电影 / 夜览暖色 / 冷峻 / 深黑 / 关闭。用 `set vf` 的单活跃语义，应用预设会
  清掉 `vf toggle` 的个别滤镜；实测 dynamic-crop 自管理的标签滤镜被清后会自动
  补回，共存正常。
- `uosc` 菜单状态提示（`update_menu_state_hints`）：睡眠定时器（剩余时间）、
  hdr-pipeline（原生/toys）、环境光晕（开/关）共 6 个分支，沿用既有硬编码模式。

### 修复

- `skip-segments` 的两个底栏按钮此前只发 `set-button` 数据、未在 `controls=`
  注册 `button:` 控件项，从未显示过。已在 `button:danmaku_menu` 后注册两个按钮；
  `skip-segments.lua` 在脚本顶层即发数据，无占位图标风险。
- README 死引用清理：`playback-info.lua`、`playlist-view.lua`、
  `quality-menu.lua`（3 个文件不存在）、`CTRL+ALT+i`、`CTRL+ALT+SHIFT+t`、
  `CTRL+ALT+c`、`CTRL+v`、`CTRL+ALT+v`（已归档的 smartcopypaste/占位脚本残留）。
  新增核对脚本口径：快捷键章节的每一行都必须能在 `input.conf` 找到绑定，
  现已归零。
- `UI-FONTS.md` 补「外部依赖」警告：MFGA 字体模块（约 237 MB）不在仓库内，
  fresh clone 会静默回退，需自行安装 `~/.local/share/fonts/MFGA/` 的
  200/300/400/700.ttf 四个字重。
- `scripts/undoredo.lua:45`：`file-loaded` 时 `time-pos` 可能尚无值（idle 起播、
  网络流缓冲），`math.floor(nil)` 在冒烟测试中稳定抛错；补默认值 0。

### 验证

- 滤镜预设 6 档 `keypress` 实测，`vf` 值逐步正确切换并复位。
- 系统监控实渲染截图核对：数据与本机传感器一致（acpitz/nvidia-smi/amdgpu
  hwmon/`/proc/meminfo`/BAT1），修复了画布缩放、emoji 丢失与 `3/0W` 三处问题。
- `luac -p`（uosc 文件按 LuaJIT 编译验证，`luac` 5.4 对其 `<const>` 语法有
  存量误报，与本次改动无关）；`git diff --check` 通过；README 键位核对归零。

### 提交拆分

- `chore(font)`：MFGA YouHei 迁移（2026-10-04 遗留的未提交改动）
- `feat`：本轮全部功能与修复，含 `linux_video_policy.conf` 的 `hdr_mode=hdr2sdr`
- `chore(archive)`：`.bak-mfga-*` 与 `audit-backups-20260924/` 移入 `archive/`

## 2026-10-28 · hdr-toys 双模式：原生直通链与替换链可切换

上一轮评估认为 hdr-toys 与常驻的 `HDR2SDR` 是替代关系、无法叠加，因此没有实施。
本次按「两条链路都保留、运行时切换」的方案补齐：原生链仍是默认，toys 是可选模式。

### 新增

- `shaders/hdr-toys/`：上游 83 个着色器（MIT）。安装为 `manager.json` 的 `check`
  来源，`baseline` 记录为 `b43e457`，不整体覆盖，便于保留本地补丁。
- `scripts/hdr-pipeline.lua` + `script-opts/hdr_pipeline.conf`：模式所有者。
  进入 toys 时快照 `tone-mapping`、`gamut-mapping-mode`、`target-*`、`icc-*`、
  `inverse-tone-mapping` 并接管，退出时按快照还原；运行期间观察这些属性，把
  其他写入方改回的值纠正过来。片源是 BT.2020 的 PQ / HLG / BT.1886 时分别套用
  上游三条链，其他片源回退原生并提示一次。
- `ALT+H` 切换模式；「画面 > HDR 处理链」提供直接用原生链、直接用 toys、
  查看当前链路三个菜单项。

### 冲突处理

计划里列的四类写入方全部处理：

- `linux-video-policy.lua`：`apply_color_policy()` 检测
  `user-data/hdr-pipeline/active` 后直接返回，不再写 `target-*`。RIFE 准入不变。
  已确认没有其他脚本消费它的 user-data。
- `input.conf` 的 HDR 热键：不做改绑，靠属性观察在 `guard_delay`（默认 80 ms）
  后纠正，并提示一次。原生模式下这些键行为完全不变。
- uosc 的 `target-peak` 菜单：同上，`target-peak` / `target-contrast` 在 toys 下
  固定为 `auto` 并纳入守护。
- `[HDR画质]` / `[电影]` / `[动画]` 与着色器配置组：实测应用后属性会被纠正，
  `glsl-shaders=` 整体替换的 toys 链也会被补回。

回退分支不使用快照里的目标参数，而是用固定的原生基线（`auto`），因为快照是进入
toys 那一刻取的，切换片源后可能残留上一支片子的值；`inverse-tone-mapping` 与
ICC 两项例外，仍从快照继承，避免抹掉用户手动启用的方案。

### 上游补丁

`shaders/hdr-toys/tone-mapping/astra.glsl` 在 baseline `b43e457` 中把 GLSL 保留字
`packed` 用作变量名（histogram fusion 那段 compute pass）。libplacebo 7.360.1 /
GLSL 460 下编译报 `unexpected PACKED_TOK`，整个 pass 失败。本地改名为
`packed_bits` 并加注释标明。升级上游前需确认是否已修，否则重新应用。

### 验证

- `luac -p` 通过；`manager.json` 仍是合法 JSON。
- 属性级：PQ / HLG / BT.2020-SDR 三种片源分别得到正确的 `target-trc` 与
  5 / 5 / 3 个 toys 着色器；bt.709 SDR 回退原生且不带 toys 着色器。
- 守护：手动写入 `tone-mapping=auto`、`target-peak=300` 后均被纠正；
  应用 `[HDR画质]`、`[Anime4K]`、`[电影]` 后属性与着色器链均被恢复。
- 还原：`set-mode native` 后所有托管属性回到 `auto`，toys 着色器清零。
- 渲染：用 zscale 造不出的真 HDR10 片源（`libplacebo` 滤镜转 PQ/BT.2020/10bit）
  实测，原生与 toys 都无过曝死黑（均值 145.6 vs 118.7），HLG 同样正常，
  无 libplacebo 编译错误。
- 已知限制：本机 `--gpu-context=waylandvk` 在无头环境无法完成初始化，渲染验证
  使用 `wayland`（EGL）完成；shader 编译与画面结果与上下文无关，但 Vulkan 下的
  实际表现仍建议在本机正常播放时确认一次。

## 2026-10-27 · 移植 Mpv∞ 可移植功能：睡眠定时器、Wyzie 字幕、环境光晕

对照 `ZHINFINITY/Mpv-infinity`（Android 播放器，非开源许可）做功能层面对比，
只移植桌面端可行的部分。绝大多数特性属于 App 层（毛玻璃 UI、手势、Cast、
Jellyfin、Media3 双引擎、热管理），不进配置。

### 新增

- `scripts/sleep-timer.lua` + `script-opts/sleep_timer.conf`：睡眠定时器。
  一次性 timeout 承载真正的截止时间，1 秒周期 timer 只刷新 OSD 和徽标，
  避免周期回调累积漂移；支持 quit / quit-watch-later / pause 三种到点动作，
  以及可选的暂停感知。入口 `CTRL+ALT+m`。自定义分钟数走 uosc 可搜索菜单，
  因为本构建的 `mp.input` 为 nil（它依赖 console，实测取不到）。
- `script-modules/http-async.lua`：curl + `mp.command_native_async` 的共享异步请求
  模块，返回可取消句柄，HTTP 状态码与响应体分开解析。只允许 http/https，并拒绝
  环回、私有与保留地址；本地代理经 `--proxy` 传递，不受该限制影响。
- `scripts/sub-wyzie.lua` + `script-opts/sub_wyzie.conf`：Wyzie 在线字幕搜索。
  Wyzie 的 `/search` 只接受 TMDb / IMDb ID，因此流程是 文件名 → 标题清洗 →
  TMDb 解析 → Wyzie 搜索 → 下载挂载。季集识别与标题清洗覆盖 `SxxExx`、`1x04`、
  `第N季第N集`、`[05]` 和中文组名格式。需自行申请免费 API key，未配置时只提示
  申请地址、不发请求。
- `shaders/ambient/ambient_glow.glsl`：环境光晕，单个文件 6 个 pass（亮部提取 +
  两级可分离高斯 + 加性合成）。用 `ALT+a` 以 `change-list glsl-shaders toggle`
  开关，不写成 profile，因为着色器配置组会用 `glsl-shaders=` 整体替换列表。

### 修复

- `input.conf` 中 3 处 `script-message-to` 目标带连字符，而 mpv 会把脚本文件名里的
  `-` 归一化成 `_`（实测 `test-name.lua` → `test_name`），配合「目标不存在不报错」
  的语义，这些命令一直静默不执行：`uosc-subtitle-lines`、`trakt-scrobble`（2 处）、
  `screenshot-to-clipboard`。
- `README.md`：uosc 版本标识 `5.12.0` → `5.13.0`；删除已不存在的 `peak-percentile`
  auto profile，改为说明由 `hdr-peak-percentile-guard.lua` 在运行时管理；
  `CTRL+ALT+m` 原有记载与实际绑定不符，改为睡眠定时器入口。

### 验证

- `luac -p` 全部通过；`git diff --check` 无空白错误。
- 睡眠定时器：设 0.05 分钟（3 秒），进程在 4.3 秒退出；取消后不再触发；
  `user-data/sleep-timer/*` 的 active / remaining / action 值正确。
- HTTP 模块：环回、内网段、`file://` 均被拒绝；公网 HTTPS 返回 200 且响应体完整。
- Wyzie：标题解析为 `The Mandalorian`、S2E8，TMDb 解析出 id `82856`；
  无效 key 返回 403 并被正确提示。
- 光晕：默认参数下仅 1.39% 像素变化，且集中在亮区周围（变化包围盒
  401–546 × 191–341）；`STR=0` 时只剩 1 个色阶的取整差异。

### 未实施

- hdr-toys：已改为「原生链与替换链双模式可切换」并在 2026-10-28 的记录中实施，
  见上方条目。
- 视频压缩转码、主题切换系统、FRAME_EXTEND 黑边外延：投入产出比低或仅全屏
  字母盒有意义，按计划暂不做。

## 2026-09-18 · Yaozhi 可移植性归一化

- 新增 `PORTABILITY-AUDIT.md`，将 Yaozhi 功能统一分为 Linux 原生、脚本、Shader/VapourSynth、需要私有 patch、Windows 专属五类。
- 明确 Linux 默认链路为 mpv 0.41.0 + FFmpeg 9.0.1 + libplacebo 7.360.1 + gpu-next/Vulkan/NVDEC/PipeWire。
- 不再把 Yaozhi Windows 自编译核心、D3D11、SMTC、Atmos 私有桥接和 Windows 便携运行时作为 Linux 依赖。
- release 模块改名为 `script-modules/emo-release.lua`，同步 stats.lua 引用，统一播放器品牌为 mpv-Emo Linux。


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


### 2026-09-18 · 播放自动化与 Linux 策略增强

- 新增 `live-adaptive-quality.lua`：依据实际直播 demuxer 缓存水位与缓存暂停状态，在 resolver 提供的真实画质档位之间自动降级；缓存长期稳定后逐级恢复，带切换冷却与单文件切换上限，避免网络抖动造成画质来回跳变。
- 现有 `online-media.lua` 的备用 candidate、直播断流重连与画质重解析继续作为底层恢复链，自动画质控制只通过其公开 `online-media-select-quality` 消息切换，不绕过 resolver。
- `autoload.conf` 开启 `same_series=yes`：同目录按自然排序自动识别相似系列；现有 autoload playlist-next 负责自动下一集。
- `auto-save-state.conf` 保存周期调整为 15 秒；仍保持“播放中延迟写入、暂停/卸载安全落盘”，配合 mpv `watch-later` 的逐文件 key 保存播放位置。
- `simplehistory.conf` 改为 `resume_option=notification`、2% 阈值：重新打开有进度的视频时先询问恢复，不强制覆盖用户选择。
- 新增 `linux-video-policy.lua`：在 Linux 上按 PQ/HLG/BT.2020 自动维持 gpu-next 的 HDR/SDR 原生色彩管理；同时检查本机 RIFE/VapourSynth/k7sfunc 依赖与分辨率/FPS 安全范围。当前机器缺少 `k7sfunc`，因此不会偷偷启动失效 RIFE，而是保持原生播放。
- 视频处理继续由现有 `adaptive-quality.lua`/`rife.lua`/HDR 条件 profile 负责已验证能力；Linux 策略层只做准入与保护，不覆盖用户手动 Shader。
- uosc 保持现有 Catppuccin Mocha / 浮动 Dock / 动画与重复“更多”按钮修复，不再为了审美引入新的第三方 UI 依赖。

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
  `script-modules/emo-release.lua`）、长页按实际文字高度自动避让底栏
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
