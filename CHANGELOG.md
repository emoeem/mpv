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
