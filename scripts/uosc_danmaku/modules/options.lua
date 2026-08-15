local opt = require("mp.options")

-- 选项
options = {
    -- 指定弹幕服务器地址，自定义服务需兼容 dandanplay 的 api
    -- 可指定多个用逗号分隔的有序 api_server 列表
    -- 支持每项使用 '|' 或 '#' 分隔备注，例如: "https://a.example.com|备用A" 或 "https://b.example.com#备用B"
    api_server = "https://danmu.cynn.top/cynnsq|炊烟袅袅,https://api.dandanplay.net",
    -- 指定 b 站和爱腾优的弹幕获取的兜底服务器地址，主要用于获取非动画弹幕
    -- 当前使用：https://dmku.hls.one
    -- 按顺序尝试链接解析代理；后续节点只在前一节点失败时使用。
    fallback_server = "https://dmku.hls.one,https://danmaku-api.152468.xyz",
    -- 设置 tmdb 的 API Key，用于获取非动画条目的中文信息(当搜索内容非中文时)
    -- 可以在 https://www.themoviedb.org 注册后去个人账号设置界面获取
    -- 注意：自定义此参数时还需要对获取到的 API Key 进行 base64 编码
    tmdb_api_key = "NmJmYjIxOTZkNzIyN2UyMTIzMGM3Y2YzZjQ4MDNkZGM=",
    auto_load = false,
    -- 自动加载失败后，严格按片名和集数搜索影视库并自动关联。只在高置信时执行。
    auto_search_associate = false,
    auto_search_strict = true,
    -- 自动关联英文片名时是否尝试通过 TMDB 转换中文名。默认关闭，避免客户版外网依赖和等待。
    auto_search_tmdb = false,
    auto_load_delay = 1.0,
    autoload_local_danmaku = false,
    autoload_for_url = false,
    save_danmaku = false,
    user_agent = "mpv_danmaku/1.0",
    proxy = "",
    -- 可选：向 HTTP 请求传递 cookie.txt 文件路径
    cookie_file = "",
    -- 旧版兼容开关：仅在显式选择 ASS 轨模式时允许 fps 视频滤镜。默认禁用
    vf_fps = false,
    -- 设置要使用的 fps 滤镜参数
    fps = "60/1.001",
    -- 弹幕渲染模式：overlay 独立刷新，不修改源视频帧率；auto 保留为兼容模式
    render_mode = "overlay",
    fullscreen_blackbar = true,
    -- overlay 兼容模式的最高刷新率，实际不会超过显示器刷新率
    overlay_fps = 60,
    -- 低帧率 overlay 使用显示同步重复绘制视频帧，让 60Hz 弹幕更新真正可见
    overlay_display_sync = true,
    -- 指定合并重复弹幕的时间间隔的容差值，单位为秒。默认值: -1，表示禁用
    merge_tolerance = -1,
    -- 合并重复弹幕时是否强制合并类型和颜色不同的弹幕。默认值: false，表示仅合并类型和颜色相同的弹幕
    merge_without_style = false,
    -- 指定弹幕关联历史记录文件的路径，支持绝对路径和相对路径
    history_path = "~~/danmaku-history.json",
    open_search_danmaku_menu_key = "Ctrl+d",
    show_danmaku_keyboard_key = "j",
    -- 中文简繁转换。0-不转换，1-转换为简体，2-转换为繁体
    chConvert = 0,
    --滚动弹幕的显示时间
    scrolltime = 15,
    --固定弹幕的显示时间
    fixtime = 5,
    --字体
    fontname = "sans-serif",
    --字体大小 
    fontsize = 50,
    --字体阴影
    shadow = 0,
    --字体粗体
    bold = true,
    -- 透明度：0（完全透明）到 1（不透明）
    opacity = 0.7,
    --全部弹幕的显示范围(0.0-1.0)
    displayarea = 0.85,
    --描边 0-4
    outline = 1.0,
    -- 限制屏幕中同时显示的最大弹幕数量，防止极端密度拖慢渲染；0 表示不限制
    max_screen_danmaku = 120,
    --指定弹幕屏蔽词文件路径(black.txt)，支持绝对路径和相对路径。文件内容以换行分隔
    --支持 lua 的正则表达式写法
    blacklist_path = "",
    --指定脚本相关消息显示的消息的对齐方式
    message_anlignment = 7,
    --指定脚本相关消息显示的消息的x轴坐标
    message_x = 30,
    --指定脚本相关消息显示的消息的y轴坐标
    message_y = 30,
    -- 自定义标题解析中的额外替换规则，内容格式为 JSON 字符串，替换模式为 lua 的 string.gsub 函数
    --! 注意：由于 mpv 的 lua 版本限制，自定义规则只支持形如 %n 的捕获组写法，即示例用法，不支持直接替换字符的写法
    title_replace = [[
       [{ 
           "rules": [{ "^〔(.-)〕": "%1"},{ "^.*《(.-)》": "%1" }],
       }]
    ]],
    -- 指定哈希匹配中需忽略的共享盘（挂载盘）的路径/目录。支持绝对路径和相对路径，多个路径用逗号分隔
    -- 示例：["X:", "Z:", "F:/Download/", "Download"]
    excluded_path = [[
        []
    ]],
}

opt.read_options(options, mp.get_script_name(), function() end)
