# 更新记录

## 2026-10-28 · TheIntroDB 迁移到 API v4（v2/v3 已被上游标记废弃）

上游维护者在 issue 里点名本仓库的 `skip_segments.conf` 仍在打 `/v3/media`。v1 已移除，
v2/v3 只保留一个 `GET /media` 且不再修复，v4 是唯一还在开发的面。

### 改了什么

| 项 | 改动 |
| --- | --- |
| 端点 | `introdb_url` 与脚本内默认值都改为 `https://api.theintrodb.org/v4/media` |
| 请求形状 | `season` 与 `episode` 现在**必须成对发送**；电影两个都不发 |
| 电影 | 顺带修好了一个 v3 时代就存在的 bug（详见下） |
| 响应形状 | 只认片段数组；v4 的「剧集清单回退」与错误体都按无数据处理，并写明原因 |
| 新选项 | `introdb_mapping=`，留空即 default；别名自动归一，填错则本次不发送 |

### 为什么电影这一条是必须改的

`parse_episode()` 对缺失的季号返回 `1`（`tonumber(season) or 1`），而电影没有集号。
旧代码 `if resolved_info.season then 拼 season end` 于是对**每一部电影**都发
`?tmdb_id=550&season=1`。实测 v3 与 v4 对这个形状的回应都是：

```
400 {"error":"season and episode must be provided together"}
```

也就是说**电影从来没有取到过片头片尾**，与 v4 无关。现在改成「只有 episode 存在才拼
season+episode」，同一请求变成 `?tmdb_id=550&duration_ms=…`，返回
`intro 0–119s` 与 `credits 8177–8348s`（后者超出测试片长，被 `valid_range` 正常丢弃）。

### 响应三种形态

`/v4/media` 的 200 有三种 body：片段（默认）、版本清单（`list_versions=true`）、
剧集清单回退（该媒体无已采纳提交且请求方未带 TMDb key）。后两种没有片段数组，
现在按无数据处理并打 `verbose` 日志，不再静默返回空。

### 验证

本地起捕获服务记录脚本真实发出的 URL，再叠加真实 v4 端点与新旧脚本 A/B：

脚本真实发出的 URL（本地捕获服务记录，90 s 测试片）：

| 场景 | 实际 URL | 结果 |
| --- | --- | --- |
| TV | `…/v4/media?tmdb_id=550&season=1&episode=2&duration_ms=90000` | 2 个片段 |
| 电影 | `…/v4/media?tmdb_id=550&duration_ms=90000` | 2 个片段 |
| `introdb_mapping=altdvd` | `…&season=1&episode=2&mapping=dvd&…` | 别名归一 |
| `introdb_mapping=Aired Order` | `…&mapping=official&…` | 空格/大小写忽略 |
| `introdb_mapping=bogus_order` | 不带 `mapping` | 一条告警，不发送 |

真实 v4 端点的三种回应（curl 直取，`tmdb_id` 取已知有数据的媒体）：

| 请求 | 回应 |
| --- | --- |
| `?tmdb_id=1399&season=1&episode=1` | `200`，`intro 483–581 s` |
| `?tmdb_id=550`（电影） | `200`，`intro 0–119 s`（`start_ms` 为 `null`，按 0 处理） |
| `?tmdb_id=1399&season=1`（旧脚本对电影的请求形状） | `400 season and episode must be provided together` |

剧集清单回退与 404 错误体均按无数据处理，打 `verbose` 日志，不产生 Lua 异常。

`luajit -bl` 通过；`audit_bindings` / `audit_readme_keys` / `audit_theme_colors` 全 PASS；
`git diff --check` 无输出。

---

## 2026-10-28 · 仓库同步：本轮全部改进入库并推送，文档补齐

前几天的工作一直只在工作区（10 个本地提交 + 40 个未提交文件），本次一次性收口。

### 提交拆分

| 提交 | 内容 |
| --- | --- |
| `feat(deploy)` | `platform.conf`、`deploy.py`、`fonts/MFGA/` 忽略规则首次入库 |
| `feat(uosc)` | 时间轴坐标修复、信息去重、控件自动隐藏、统计按钮状态化 |
| `chore(config)` | 配置审阅修复：Dracula 配色统一、`hwdec`/`ao` 交给平台层、脚本可移植性 |
| `docs` | README / CHANGELOG / PORTABILITY-AUDIT 对齐当前配置 |

### 一个容易误读的 diff

`scripts/uosc/elements/Timeline.lua` 的全量 diff 是 **939 增 / 722 删**，看着像整体重写，
但 `git diff -w` 只有 **228 增 / 11 删**——差额来自 HEAD 里那份文件是 **CRLF/LF 混排**，
本次被归一为纯 LF。审这份 diff 时**必须加 `-w`**，否则会把行尾变化误判成逻辑改动。

### 文档补齐

| 位置 | 补充 |
| --- | --- |
| 目录结构 | `platform.conf`、`deploy.py` |
| 主要文件 | 同上两行的职责说明 |
| OSD、字体与 Dracula | `osd-margin-y=84` 的由来（顶栏 48 高胶囊栏压住左上 OSD） |
| 脚本功能 · 界面 | `stats-indicator.lua` 与 `stats-visible` 属性的映射关系 |

### 验证

`python3 audit/audit_bindings.py`、`audit_readme_keys.py`、`audit_theme_colors.py` 三个脚本
全部 exit 0；`luajit loadfile` 覆盖本次改动的全部 Lua 文件；`git diff --check` 无空白错误。

## 2026-10-28 · 统计信息按钮改成带状态的开关（点击开 / 再点关 / 高亮提示）

用户反馈：底栏「统计信息」按钮点一下会显示面板，但按钮没有状态反馈，也关不掉。

**根因**：`controls` 串里这一项是
`command:analytics:script-binding stats/display-stats:script-binding stats/display-stats-toggle`。
左键调的是 `display-stats`，它走 `process_key_binding(oneshot=true)`——只闪现
`duration`（4s）就自动清屏，**永远不进入「常驻」状态**，所以"再点一下"只会重新闪现。
只有右键才是 toggle，而他点的是左键。

### 改动

| 文件 | 改动 |
| --- | --- |
| `scripts/stats.lua` | `clear_screen()` 写 `user-data/mpv-emo/stats-visible=false`；显示分支末尾写 `true`。`clear_screen()` 是唯一关闭出口（toggle 关闭 / oneshot 到期），所以覆盖所有关闭路径 |
| `scripts/stats-indicator.lua`（新增） | 观察该属性，通过 uosc 官方 `set-button` 消息更新 `stats_toggle` 按钮：`active` 高低、tooltip 文案、左键 toggle、右键 oneshot |
| `script-opts/uosc.conf` | 两处 `command:analytics:...?统计信息` → `button:stats_toggle`（idle 排 + video/audio 排） |
| `scripts/uosc/elements/Controls.lua` | `button:` 分支补回 `stats_toggle → narrow_role='stats'` |

### 一个自己引入又修掉的回归

换成 `button:` 之后，`narrow_role='stats'` 丢了——原来只有 `command:` 分支在
`params[1]=='analytics'` 且命令含 `script-binding stats/` 时才设置它。
`Controls.lua` 里 `portrait_transport`（高 > 宽）会隐藏**所有没有 `narrow_role` 的控件**，
于是 948×1010 这类高窄窗口下统计按钮直接消失。已在 `kind == 'button'` 分支按名字补回。

### 验证（真实 mpv / grim 截图 + IPC 读属性）

| 场景 | `user-data/mpv-emo/stats-visible` | 按钮区 `#BD93F9` 像素 |
| --- | --- | --- |
| 全屏 1920×1080 初始 | property not found（未写过） | 0 |
| toggle #1 | `true` | 1566（区域 1500,994–1551,1045） |
| toggle #2 | `false` | 0 |
| `i`（oneshot）显示中 | `true` | — |
| oneshot 4s 到期后 | `false`（`clear_screen` 自动复位） | — |
| 高窄窗 948×1010 开启 | `true` | 1536（区域 1008,994–1058,1045） |
| 同窗口关闭 | `false` | 0 |

idle 排（不加载文件）同样验过开关与高亮，日志 0 error。

**未实测**：tooltip 文案只在截图里没抓到（合成 `mouse` 事件在 niri 下不产生
uosc 的 hover tooltip 序列），文案本身已写入按钮数据。

## 2026-10-28 · 修复：分段时间轴点哪不跳哪（坐标系错位）

用户实测反馈「点击时间轴不播放到鼠标位置」。用真实运行几何定位，不是视觉误差：

```
[render] bax=91.0 bbx=846.3 segs=10 usable=674.30 gap=9.00 x0=91.04
         t=92.00 ph=497.5  back=70.99  dPH=-21.009
```

圆点画在 92s（x=497.5）的位置，同一坐标反算回来却是 **71s**，整片 171.6s 上偏差 12%。

**根因**：`Timeline:get_time_at_x()` 里两套坐标系混用。`lx` 先减掉 `self.ax + inset_l`
变成相对轴起点的坐标，`cursor` 却从绝对坐标 `layout.x0`（= `bax`）开始累加，
两边各扣了一次轴起点偏移，结果整体多走了约 8 个段宽。

**修复**：`lx = x - layout.x0`、`cursor = 0`，与渲染、与圆点绘制共用同一份几何。

验证（真实 mpv 0.41 / 948×1010 窗口 / 171.6s 片源，7 点全轴采样）：

| x | 期望 | 实际 | 误差 |
| --- | --- | --- | --- |
| 120 | 7.37s | 7.38s | +0.00 |
| 250 | 35.88s | 35.88s | -0.00 |
| 420 | 74.57s | 74.58s | +0.02 |
| 600 | 115.80s | 115.83s | +0.04 |
| 700 | 137.30s | 137.33s | +0.03 |
| 780 | 154.74s | 154.75s | +0.01 |
| 840 | 170.01s | 170.04s | +0.03 |

### 同时统一了段模式下的「时间 → x」

`t2x()` 是线性换算，而分段绘制里 gap 占掉了真实像素，两者不一致。
新增 `time2x()`：`seg_active` 时走与绘制/点击完全相同的分段几何，否则回落 `t2x()`。
替换了四处仍在用线性映射的调用点——章节 range 刻度、缓存纹理、intro/outro 手柄。

### 修正：中文数字章节编号未去重

上一版的去重正则只认阿拉伯数字，`第二章 相遇` 会被拼成「第 2 章 · 第二章 相遇」。
改为 `第[0-9一二三四五六七八九十百千零两]+[章话集幕回节]`，并允许编号出现在标题中间。

## 2026-10-28 · UI 第三轮：信息去重、控件自动隐藏、时间轴为核心

设计原则：**顶栏说「在看什么」，时间轴说「看到哪里」，技术信息默认收起。**

### 1. 时间语义收口到时间轴（消除三处重复）

- 顶栏章节胶囊不再显示播放时间，只显示「第 N 章 · 标题」；时间未知/无章节时整颗隐藏。
- 底栏 `TimeDisplay`（`当前 / -剩余`）从 `controls` 串里移除，连带删掉它两侧的一处 `space`。
- 时间轴左端=当前播放位置、右端=总时长，成为唯一完整的进度信息源。
- 同一屏里不再同时出现「总时长」与「剩余」两种算法。

### 2. 章节编号去重

`TopBar:get_now_playing_chapter_text()` 现在输出「第 N 章 · 标题」，
但标题自己已含编号（`第 N 章/话/集/幕/回`、`Chapter N`、`EP N`）时原样保留，不拼第二次。
标题为空时退回「第 N 章」，`[autoskip]` 内部章节仍视为无章节。

### 3. 顶栏跟随控制区显隐（`autohide=yes`）

- 根因不是 `top_bar=always`：该值只控制「是否允许渲染」，可见性仍走 proximity。
  真正让顶栏常驻的是 `script-opts/uosc.conf` 的 `autohide=no`。
- 改为 `autohide=yes`：播放中鼠标静止 1s 后，顶栏/底栏/时间轴一起淡出。
- 新增 `TopBar:get_visibility()` 覆写：**取自身与控制区的较大可见度**，
  避免「底栏已经展开、顶栏还藏着」的分两次给信息；幕布/菜单打开时不把顶栏拽出来。
- `timeline_persistency=paused`（原有配置）继续生效：暂停时整个控制区保持展开。
  实测 `--pause=yes` 会被 uosc 的 `keep-open-pause=no` 复位，验证必须用 IPC `set pause true`。

### 4. 媒体信息胶囊改为按需显示

新增 `timeline_media_info`（`auto` 默认 / `always` / `never`）：
- `auto`：仅在时间轴真正展开（visibility > 0.5）时绘制，鼠标离开即随底栏淡出；
- 悬停时间轴出现 thumbfast 缩略图卡片时让位，避免两层信息互相遮挡；
- `never` 时不画，技术信息仍可用 stats 面板查看（能力未删）。

### 5. 顶栏胶囊背景与窄窗优先级

- `opacity.title` 0.5 → 0.62，胶囊底衬在亮画面上可辨，仍保持半透明不变成色块。
- 章节胶囊先给文件名预留约 8 字的最小可读宽度：565px 窗口下章节胶囊自动消失、
  标题保留「天气之子.Weatherin…」，不再出现「天汽…」把标题压没的情况。

### 6. 验证（全部实机，Linux/Wayland/niri/mpv 0.41）

| 场景 | 结果 |
| --- | --- |
| 播放中鼠标静止 3.5s | 顶栏+底栏+媒体信息全部淡出 |
| 暂停时鼠标静止 4s | 顶栏+底栏+时间轴保持（`timeline_persistency=paused`） |
| 鼠标靠近底栏 | 顶栏同时出现，章节胶囊 + 引擎胶囊 + 文件名截断正常 |
| 悬停时间轴 | 章节 tooltip「第 1 章 序幕」+ 缩略图，媒体胶囊让位 |
| 无章节文件 | 章节胶囊消失，时间轴退化为装饰分段 |
| 565 / 948 / 1904 px 三档 | 无重叠；窄窗优先保标题 |
| 经典 `bar` 样式 | 细线 + 菱形标记照旧，无报错 |

## 2026-10-28 · UI 打磨第二轮：拖动映射修正、分段缝隙、播放圆点、OSD 让位

这一轮的四个问题都是**实机截图 + 像素测量**发现的，不是看代码猜的。

### 1. 拖动/点击的时间映射与画出来的分段不一致（真 bug）

- 现象：分段模式拖动时间轴时，白色播放圆点会**离开光标**，越到后段偏得越多。
- 根因：`Timeline:get_time_at_x()` 只扣了两端时间标签的留白，没有扣段间 `gap`；
  而绘制走的是 `usable = bar_width - gap*(n-1)`。两套坐标，越到后面差得越多。
- 数值（`/tmp/rt.py` 往返校验，复刻同一份公式）：
  | 场景 | 旧反向最大误差 | 新反向最大误差 |
  | --- | --- | --- |
  | 4 章 / 112s / 670px | 0.84s | 0.000000s |
  | 24 装饰段 / 2h / 1400px | 37.85s | 0.000000s |
- 修法：渲染时把分段几何缓存进 `self.seg_layout`（`segments/usable/gap/x0`），
  点击按同一份几何反算；落在缝隙里收口到该段起点；收起态（细线）与经典样式仍走线性换算，
  并把缓存置空，避免用过期分段。
- 实机验证：t=62.5s 时圆点画在 x=1001.5，按旧公式反算该坐标得出 70.6s（偏 8.1s）；
  新公式反算得 62.5s。

### 2. 段间缝隙里出现亮色小菱形

- 根因：分段条上又叠了一层 uosc 原生"章节菱形标记"（`\bord` 描边 + `fg` 填充），
  正好落在段间缝隙里，看起来像脏点。
- 修法：`seg_active` 时不画章节菱形（段本身已经表达章节边界），A-B 循环标记保留，
  经典 `bar`/`line` 样式照旧。

### 3. 播放位置圆点

- 半径从 `bar_height*0.85` 收到 `0.62`，并夹在轴内（0%/100% 时不再探到两端时间文字上）；
- 颜色改前景色 + 不再叠"底色大圆"——底色大圆会在已播段里挖出一圈黑环。

### 4. 装饰段数量自适应 + 间距跟条高走

- 固定 24 段 → `clamp(6, round(bar_width / (56*scale)), 24)`：窄窗少段、宽窗多段，
  段宽稳定在 ~56px，间距占比恒定（670px 轴上从 24 段降到 ~10 段，不再糊成一条）。
- `gap = max(3, round(bar_height*0.5))`，且 `radius` 受 `gap` 与条高共同约束，
  缝隙读作"槽"而不是"菱形孔"。

### 5. OSD 文本被顶栏压住

- 现象：跳转反馈、`show-text` 一律画在左上，正好压在文件标题胶囊上。
- 根因：`osd-align-x=left` / `osd-align-y=top` + `osd-margin=16`，而顶栏改成 48 高的胶囊栏。
- 修法：`mpv.conf` 加 `osd-margin-y=84`（≈ `top_bar_size 48 × scale 1.3` + 原边距 16），
  实机 `show-text HELLO-OSD` 已落在顶栏下方。

### 6. 标题截断尾巴

- `fit_text_to_width()` 在截断点吃掉尾部 `. : · - _ , 空格` 再接「…」，
  不再出现 `2019....` 这种四个点。

### 校验

- `luajit -e loadfile` 两个改动文件通过；`git diff --check` 干净；
  `audit_bindings.py` / `audit_readme_keys.py` / `audit_theme_colors.py` 三个 exit 0 PASS。
- 实机画面：1080p / ~840px 窗 / 有章节 / 无章节 / 经典 bar 回退，日志 0 error、0 traceback。

## 2026-10-28 · 三平台适配：顶栏/分段进度条收口、platform.conf、Lua 跨平台、deploy.py

本轮把「界面像 Mpv∞」和「能在 Windows/macOS 跑起来」拆成可验收的两条线，
所有结论都有实机命令或截图证据；本机只能验证 Linux，Windows/macOS 一律写「待实测」。

### Phase A · 顶栏与进度条

- 顶栏改为右侧胶囊排：`文件标题 → 「章节 · 当前时间」→ 引擎状态 → 圆形窗口控制`，
  全部从窗口控制左边缘向左排，标题最后拿剩余宽度，互不重叠。
  - 新增 `TopBar:get_now_playing_chapter_text()` / `get_now_playing_time_text()`：
    有章节显示「章节名 · HH:MM:SS」，无章节只显示时间，`[autoskip]` 内部章节视为无章节，
    时间未知（待机/直播未起播）整颗胶囊隐藏，不画空占位。
  - 文件名过长用 UTF-8 安全的 `fit_text_to_width()` 加「…」，不再硬裁半个字符；
    空间不足时先丢章节名、再整颗隐藏，绝不压到右侧胶囊或窗口按钮。
  - 引擎胶囊读 `user-data/hdr-pipeline/mode`（`get_property_native`，`native→原生`、
    `toys→Toys`），点击发 `script-message-to hdr_pipeline toggle`；脚本未加载则隐藏。
    `toys` 切换已实机截图验证，胶囊同步更新。
  - 旧版「标题下方第二行章节 + 剩余时间」删除（同一信息不再出现两次）；
    `top_bar_now_playing=no` 可回退旧布局的行为开关。
- 新增配置 `top_bar_capsule`（默认 yes）：标题/进度/引擎胶囊与窗口按钮用全圆角，
  关掉回退 `border_radius` 经典圆角。`top_bar_size=48`，与 `controls_size=40`、
  `scale=1.3` 协调（实机 1080p 与 948px 窄窗均无重叠）。
- 进度条 `timeline_style=segments` 重做：
  - **有真实章节时 1 段 = 1 章**（2~40 章），无章节时才用 24 个等宽装饰段；
    装饰段只服务视觉节奏，不当虚假章节。
  - 段内分别画未播轨道、已缓冲（淡）、已播放（强调色部分填充），段间距按条高收窄，
    极窄窗口自动压缩间距；播放位置用圆点表示，不单靠颜色。
  - 两端新增当前时间 / 总时长文字（`state.time_human` 与 `format_time(duration)`），
    先量宽再从两端预留空间；放不下整对隐藏。`Timeline:get_time_at_x()` 同步扣除这段
    留白，点击/拖动坐标不会因为标签而偏移。
  - 收起态（只剩底部细线）仍走原经典细线，分段块只在真正展开时绘制。
- 未新增投屏 / Cast / 纯音频聆听 / 移动端传输入口（全仓库 grep 复核：`投屏|Cast|DLNA|纯音频`
  只命中注释与文档）。字幕、音轨、章节、截图、缩放、去黑边、补帧、键盘映射全部保留。

### Phase B · 平台分流

- 新增 `platform.conf`，由 `mpv.conf` 以 `include=~~/platform.conf` 引入：
  `[platform-linux]` → `gpu-context=waylandvk` + `ao=pipewire` +
  `hwdec=nvdec-copy,vaapi-copy,auto-copy-safe`；`[platform-windows]` → `ao=wasapi` +
  `hwdec=nvdec-copy,d3d11va-copy,auto-copy-safe`；`[platform-macos]` →
  `ao=coreaudio` + `hwdec=videotoolbox,auto-copy-safe`。
  macOS 条件写 `get("platform") == "darwin" or ... == "macos"`——mpv 在 macOS 报的是
  `darwin`，只写 `macos` 会让整条 profile 永不生效。
- `mpv.conf`：删除硬编码 `gpu-context=waylandvk` 与 `ao=pipewire`；全局
  `hwdec=nvdec-copy,auto-copy-safe` 移到 `include` **之前**。原因不是风格：
  实测 mpv 按配置出现顺序取值，全局项写在 include 之后会反向覆盖 profile
  （复现：profile 设 `ao=pipewire/hwdec=nvdec-copy`，之后写 `ao=null/hwdec=no`，
  运行值就是 `null/no`）。
- `profiles.conf` 的 `[游戏]` 移除 `gpu-api=vulkan` / `gpu-context=waylandvk`
  强制项，避免无 Vulkan 的 Windows 机器初始化失败；Linux 仍由 platform profile
  注入 waylandvk。`--profile=游戏` 实机复核：`gpu-context=waylandvk`、
  `video-sync=display-resample`、`vo-configured=True`。
- 实机运行值（IPC）：`platform=linux`、`gpu-context=[waylandvk]`、
  `ao=[pipewire]`、`current-ao=pipewire`、`hwdec=[nvdec-copy,vaapi-copy,auto-copy-safe]`。

### Phase C · Lua 跨平台

- `linux-video-policy.lua`：`require 'mp'` 之后、其它 require 之前加平台守卫，
  非 Linux 直接 `msg.verbose` + `return`，不注册观察者/定时器、不写色彩管理属性。
- `screenshot-to-clipboard.lua`：Wayland `wl-copy` / X11 `xclip -t image/png -i` /
  Windows PowerShell `Clipboard::SetImage`（STA + 单引号转义）/ macOS
  `osascript … «class PNGf»`；复制的是**图像数据**，成败都清理临时文件，三类失败
  都给出可读 OSD。mpv 0.41 的 `stdin_data` 拒绝含 NUL 的二进制（PNG 必含 0x00），
  Wayland 走常量 `sh -c … < "$1"`，路径只经位置参数，不做字符串拼接。
- `open_dialog.lua`：平台判断改用 `mp.get_property('platform')`；macOS 新增
  `choose folder` / `choose file … multiple selections` + `POSIX path of`；
  取消（zenity/osascript 非零退出）静默返回，不再当错误；顺带修掉 Linux 也会调
  powershell 的剪贴板兜底。
- `online-media.lua` + `script-opts/online_media.conf`：Python 解析顺序
  `~~/online-media/runtime/bin/python3` → Windows `Scripts/python.exe` → PATH
  `python3`/`python`；`youtube_js_runtime` / `youtube_ytdl` 默认留空并走 PATH
  （Windows 试 `.exe/.cmd/.bat`），非空配置原样尊重；纯 Lua PATH 扫描，无 shell。
  实机日志：`python=…/runtime/bin/python3 (bundled)`、`deno=/usr/bin/deno (PATH)`、
  `yt-dlp=/usr/bin/yt-dlp (PATH)`；PATH 清空时三项 missing + 可读告警，脚本不报错。
- `copy-paste-URL-optimized.lua`：读取剪贴板加 `pbpaste`（darwin）与
  `Get-Clipboard -Raw`（windows），Linux 的 `wl-paste`/`xclip`/`xsel` 顺序不变。
- `manager.lua`：Windows 下 `replace` 在 `ensure_mirror` 之前拦下 → warn + `skipped`，
  不进 staging、不执行 `git`/`env`/`cp -a`/`rm -rf`；`mkdir -p` 换 `make_directories()`；
  Windows 不创建 staging/worktrees 目录；`check` 模式完全不变。
- `rife.lua`：缓存候选 `~~cache` → `XDG_CACHE_HOME` → `HOME/.cache` →
  Windows `TEMP`/`TMP` → `%LOCALAPPDATA%\mpv\cache` → 系统临时目录；删除全部
  `os.execute("mkdir -p")`，分平台建目录；Linux 缓存路径不变。

### Phase D · 部署工具与文档

- 新增 `deploy.py`（仅标准库，Python 3.9+）：`--check` / `--prepare` /
  `--fonts-dir` / `--skip-fonts` / `--json` / `--timeout`；四态
  `available / degraded / unavailable / unverified`，退出码 0/2。
  区分「检测到可执行文件」与「验证了后端」：硬解运行时在无窗口环境无法验证，
  一律 `unverified`。
- `--prepare` 幂等：运行时目录已存在则跳过；用户字体四字重齐全才复制到
  `fonts/MFGA/`，缺字重整体跳过并报缺哪几个。`.gitignore` 新增 `fonts/MFGA/`，
  126 MiB 字体不进 git（复制后 `git status fonts/` 为空，已实测）。
- README 新增「三平台部署」章节；PORTABILITY-AUDIT 追加实现位置 / 能力矩阵 /
  待验证清单与本轮运行时证据。

### Phase E · 验证

- Lua：`git diff --name-only | grep .lua` 共 20 个文件，`luajit -e "assert(loadfile(...))"`
  全部通过（mpv 运行时是 LuaJIT）。`luac -p`（Lua 5.4）对
  `scripts/uosc/lib/menus.lua` 报 `attempt to assign to const variable 'directory'`
  ——HEAD 版本同样报，属 Lua 5.4 把 for 控制变量当常量的版本差异，不是回归。
- 实机 UI（mpv 0.41 / Wayland / niri）：1080p 与 948px 窄窗截图确认顶栏胶囊排、
  章节·时间、原生/Toys 切换、分段进度条两端时间、无章节 24 段、待机隐藏时间胶囊；
  全程无 Lua 报错（`fresh.log` 只有 pipewire 状态日志）。
- 剪贴板端到端：清空后触发 `script-message-to screenshot_to_clipboard screenshot-to-clipboard`，
  `wl-paste -t image/png` 读回 960×540 PNG（测试片源分辨率），证明写的是图像而非路径。
- 配置：`mpv --config-dir=~/.config/mpv` 实机启动 + IPC 读取 `platform/gpu-context/ao/
  current-ao/hwdec/chapter-list`；`--profile=游戏` 复核无初始化失败。
- 仓库：`git diff --check` 无输出（exit 0）；`audit/audit_bindings.py`、
  `audit_readme_keys.py`、`audit_theme_colors.py` 三个脚本 exit 0 且结论 PASS；
  `python3 deploy.py --check`、`--prepare`（连跑两次验证幂等）均 exit 0。
- 未实测（明确列出，不冒充通过）：鼠标拖动/点击时间轴的自动化（mpv IPC 的合成
  mouse 事件在本机不触发 uosc 的 zone，需桌面手动点一次）、悬停态视觉、
  Windows/macOS 的 wasapi/coreaudio/videotoolbox/PowerShell 剪贴板/osascript 弹窗。

## 2026-10-28 · 审计脚本入库与配置卫生

- 新增 `audit/` 目录：三个可复跑的一致性检查脚本（`audit_bindings.py` 按键
  重复/死目标、`audit_readme_keys.py` README 键位表核对、
  `audit_theme_colors.py` 主题色残留扫描），路径改为仓库相对、退出码可判，
  用法与历史战果见 `audit/README.md`。此前它们只在会话的 /tmp 里，换主题或
  改键位时无法复跑。
- `.gitignore` 补 `.mimosa/` 与 `.zcode/`（会话工具生成的本地状态）。
- README 目录清单删除已不存在的 `osc-style/`，新增 `audit/`；
  孤儿配置 `script-opts/select.conf`（全仓库无读取者）归档至
  `archive/select.conf-orphaned-20261028`。
- `uosc_danmaku` 源说明修正：经镜像核实，origin 确为
  `Tony15246/uosc_danmaku`（与 baseline `d8c1cd8` 一致），上游未前进；
  本地含 `resolver_affinity.lua` 重构。URL 正确、无需更换——原备注
  "check 结果仅供参考，不能作为更新依据"改为准确语义：check 永不覆盖本地、
  只回答上游是否前进，合并需人工三方合并，该目录禁用 `replace`。
- 安全核查确认：`online-media/bilibili-cookies.txt`（含登录态）与
  `online-media/runtime/` 均在 `.gitignore` 内，不会入库。

## 2026-10-28 · 按键全面核验、Dracula 主题、分段式时间轴

### 按键全面核验

- 静态审计：`input.conf` 241 条生效绑定，**0 重复键位、0 死脚本目标**
  （审计脚本按 mpv 语义区分大小写键名，`a` 与 `A` 是不同绑定；早先报告的
  42 个"重复"全部是审计脚本自身的折叠误报，已修正口径）。
- 运行时验证：`input-bindings` 属性共 487 条（含脚本内部绑定），无一空命令；
  `Ctrl+Alt+m → sleep_timer open-menu` 确认在列。
- 脚本裸键注册（`add_key_binding` 带显式键名）与 input.conf 的同键关系均为
  有意遮蔽：mpv 中用户绑定优先，脚本绑定只在用户未占用时生效（如
  dynamic-crop 的 `C` 与 input.conf 指向同一功能、simplebookmark 的 1-9/0
  仅在其 UI 打开时用 forced binding 抢占）。无需改动。

### Dracula 主题（Catppuccin Mocha → Dracula）

官方色板：bg `282A36`、current-line `44475A`、fg `F8F8F2`、comment `6272A4`、
purple `BD93F9`、pink `FF79C6`、green `50FA7B`、red `FF5555`、orange `FFB86C`、
cyan `8BE9FD`、yellow `F1FA8C`。视频贴近层用派生深色 `191A21` / `21222C` /
`343746` 保持背景 → 菜单 → 选中的层次；主强调色取 Dracula 紫。

覆盖文件：`mpv.conf`（OSD/字幕 5 处）、`uosc.conf`（`color=` 26 个键 +
`chapter_ranges` 8 处）、`console.conf`、`context_menu.conf`、
`file_browser.conf`、`simplehistory.conf`、`simplebookmark.conf`、
`chapterskip.conf`、`stats.conf`，以及脚本内硬编码色：`skip-segments.lua`、
`manager.lua`、`music-mode.lua`、`autosubsync/autosubsync.lua`、
`system-monitor.lua`、`simplehistory.lua`、`simplebookmark.lua`、
`playlistmanager.lua`、`memo.lua`、`mpv_chapters.js`、
`script-modules/extended-menu.lua`。上游 `check` 管理的
simple-mpv-webui 与 trakt-scrobble 不动。全库扫描零 Catppuccin 残留。

### 分段式时间轴（timeline_style=segments）

- `Timeline.lua` 的 `draw_progress()` 新增 `segments` 分支：固定 24 段圆角块，
  段间距约为条高的 22%；未播段 `timeline_track` 暗色、已播段 `match` 强调色、
  当前段部分填充；保留定位圆点。segments 样式下展开条高提升到约 13px
  （默认仅约 6px，是时间轴"细"的根因）。
- `uosc.conf`：`timeline_style=bar → segments`。章节标记、skip-segments
  自定义区间、缓存纹理画在分段之上，不受影响。

### 底栏补回「打开文件 / 最近播放」

上一轮把这两项只留在空闲排是误判：播放中无法一键打开文件。现已在
`<video,audio>` 排最前加回，左排变为：打开、最近播放、CC、音轨、弹幕、
片尾跳过、标记、去黑边。

## 2026-10-28 · 界面风格对齐 Mpv∞：顶栏常驻、胶囊控件、中央暂停指示器

按 Mpv∞（Android 播放器）的界面风格调整 uosc，全部为配置层改动，无结构性
代码修改：

- `top_bar=no-border` → `always`：播放时始终显示顶栏标题排（对齐其顶部胶囊排）。
- `opacity.controls=0.08 → 0.5`：uosc 按钮本就自带圆角底衬，此前透明度接近隐形
  造成"扁平图标"观感；调到 0.5 后形成可见胶囊。`opacity.speed=0.5`、
  `opacity.title=0.5` 同理（顶栏标题获得胶囊底衬）。
- `pause_indicator=none → static`：暂停时中央常驻圆形指示器。
- 底部控件重排为「左排功能开关 · 中央播放 · 右排工具」：左排 CC / 音轨 / 弹幕 /
  片尾跳过 / 标记 / 去黑边；右排截图（新增 `command:photo_camera`）/ 睡眠定时器 /
  统计 / 播放列表 / 速度胶囊 / 更多。`stop` 从底栏移除（菜单与 SHIFT+F11 保留），
  打开文件与最近播放保留在空闲排。
- `input.conf` 的 SPACE / MBTN_LEFT / PLAY / PAUSE / PLAYPAUSE 绑定移除
  `flash-pause-indicator` 后缀：该 flash 会把指示器透明度在 300ms 内动画到 0，
  覆盖 static 模式的常驻显示，导致暂停指示器一闪即逝。

### 第二轮打磨（空闲态一致性 + 时间轴）

- 空闲态底栏：原本 4 个按钮挤在左下角、与播放态不协调；改为前后 `space` 居中，
  并补上统计入口（打开 / 最近播放 / 播放列表 / 统计 / 更多，共 5 个）。
- 时间轴：`timeline_size=12 → 18` 更饱满；`timeline_persistency=paused` 暂停时
  保持展开方便找位置；最小化细线 `progress_size=1.2 → 2.4`。
- 强调色：`time_current=CDD6F4 → 89B4FA`。已播放进度条本来就用 `match`
  （89B4FA 蓝），时钟与时间轴文字改蓝后形成贯穿的强调色。

验证：空闲态（niri 窗口截图）5 个按钮居中；播放态实渲染确认 18px 时间轴 +
蓝色进度与手柄；全套功能冒烟无 Lua 错误。

验证：1600px 窗口实渲染截图——顶栏标题胶囊、左排 6 个功能圆片、右排 6 个工具
胶囊、速度胶囊全部正确；960px 窄窗下 uosc 按 narrow 角色自动收编低优先级按钮，
属响应式行为。中央暂停指示器经 `decide-pause-indicator` 实渲染确认（双竖条居中）；
无头截图在暂停后不合成后续 OSD 更新，属测试环境限制，真实桌面会话不受影响。

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
