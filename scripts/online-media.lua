local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'
local script_source = debug.getinfo(1, 'S').source:gsub('^@', '')
local script_directory = script_source:match('^(.*)[/\\][^/\\]+$') or '.'
local router = dofile(utils.join_path(
    script_directory, '../script-modules/online-media-router.lua'))

local o = {
    enabled = true,
    resolver_timeout = 18,
    max_candidates = 8,
    live_reconnect_attempts = 5,
    -- 断流重连语义是「**连续**失败 N 次才放弃」。重连后真出画面并播满这么多秒，才算
    -- 这次恢复成功、计数归零；秒断的地址播不满，计数照常累加，「最多 N 次」仍是上界。
    -- 门槛必须显著低于平台自己的断流周期：虎牙实测每条连接活 20~130 秒，拿
    -- live_stable_reset_secs（60 秒）当这个门槛时，一串几十秒的断流会把配额攒满，
    -- 用户看到的是「自动重连已达上限」——比断流本身更没有出路。
    live_reconnect_alive_secs = 8,
    -- 而「刚断掉的那台主机要避开多久」是另一件事：换主机是为了不回刚断的节点，
    -- 与配额算不算成功无关，所以留在这个更长的门槛上。
    live_stable_reset_secs = 60,
    live_danmaku = true,
    live_danmaku_poll = 0.35,
    live_danmaku_max_reconnects = 3,
    bilibili_cookie_file = '~~/online-media/bilibili-cookies.txt',
    douyu_cookie_file = '~~/online-media/douyu-cookies.txt',
    youtube_cookie_file = '~~/online-media/youtube-cookies.txt',
    -- 空值 = 自动发现：先找随包运行时，再按 PATH 查找（见下面的运行时发现段）。
    youtube_js_runtime = '',
    youtube_ytdl = '',
    youtube_resolver = '~~/online-media/resolve_youtube.py',
    bilibili_resolver = '~~/online-media/resolve_bilibili.py',
    live_resolver = '~~/online-media/resolve_live.py',
    bilibili_live_danmaku = '~~/online-media/bilibili_live_danmaku.py',
    platform_live_danmaku = '~~/online-media/platform_live_danmaku.py',
    douyin_live_danmaku = '~~/online-media/douyin_live_danmaku.py',
    -- 空值 = 自动发现：随包 runtime/bin/python3（Windows 另试 runtime/Scripts/python.exe），
    -- 再按 PATH 查找 python3 / python。显式写死路径时该值被原样尊重。
    python_runtime = '',
    -- 清晰度无缝切换：选档后当前画面继续播放，后台完成新档位的解析与线路验证，
    -- 验证通过才真正换流。关掉则退回「先停流再重新解析」的旧行为。
    seamless_quality_switch = true,
    -- 预验证单条线路的超时与最少确认字节数。超时太短会把慢 CDN 误判成不可用，
    -- 太长则用户在旧画面上多等；64KiB 足以确认 FLV/HLS 真的在出数据。
    quality_probe_timeout = 6,
    quality_probe_bytes = 65536,
}
options.read_options(o, 'online_media')

-- ===== 运行时发现 =====
-- 解析顺序固定：随包运行时 → PATH。全部用纯 Lua 实现（读 PATH、切分、io.open 探测），
-- 不调 command -v / where，也不拼 shell 字符串；路径统一交给 expand-path 处理，
-- Windows 的反斜杠、空格与 Unicode 路径都不需要自己拼接。
local IS_WINDOWS = mp.get_property('platform') == 'windows'
    or (package.config or ''):sub(1, 1) == '\\'

local function file_exists(path)
    if type(path) ~= 'string' or path == '' then return false end
    local handle = io.open(path, 'rb')
    if not handle then return false end
    handle:close()
    return true
end

--- expand-path 失败或为空时返回 nil：调用方据此判断"没有配置/没有发现"。
local function expand_path(path)
    if type(path) ~= 'string' or path == '' then return nil end
    local expanded = mp.command_native({'expand-path', path})
    if type(expanded) ~= 'string' or expanded == '' then return nil end
    return expanded
end

local function path_separator()
    return IS_WINDOWS and ';' or ':'
end

local function executable_suffixes()
    if IS_WINDOWS then return {'', '.exe', '.cmd', '.bat'} end
    return {''}
end

--- 在 PATH 里逐个目录探测可执行文件。Windows 额外试 .exe/.cmd/.bat。
local function find_in_path(names)
    local path_env = os.getenv('PATH') or os.getenv('Path')
    if type(path_env) ~= 'string' or path_env == '' then return nil end
    local separator = path_separator()
    local pattern = '([^' .. separator .. ']*)' .. separator
    local directories = {}
    for entry in (path_env .. separator):gmatch(pattern) do
        local directory = entry:gsub('^"', ''):gsub('"$', '')
        if directory ~= '' then
            -- 去掉尾部斜杠，但保留盘符根（C:）与 POSIX 根（/）。
            if not directory:match('^%a:$') and #directory > 1 then
                directory = directory:gsub('[/\\]+$', '')
            end
            if directory:match('^%a:$') then directory = directory .. '\\' end
            directories[#directories + 1] = directory
        end
    end
    for _, name in ipairs(names) do
        for _, directory in ipairs(directories) do
            for _, suffix in ipairs(executable_suffixes()) do
                local candidate = utils.join_path(directory, name .. suffix)
                if file_exists(candidate) then return candidate end
            end
        end
    end
    return nil
end

--- 配置非空 → 原样使用（expand-path 后）；为空 → 自动发现。
local function resolve_tool(configured, names)
    local explicit = expand_path(configured)
    if explicit then return explicit, 'config' end
    local discovered = find_in_path(names)
    if discovered then return discovered, 'PATH' end
    return nil, nil
end

--- Python：随包运行时 → PATH 的 python3/python。
local function resolve_python()
    local bundled = expand_path('~~/online-media/runtime/bin/python3')
    if file_exists(bundled) then return bundled, 'bundled' end
    if IS_WINDOWS then
        local bundled_windows = expand_path('~~/online-media/runtime/Scripts/python.exe')
        if file_exists(bundled_windows) then return bundled_windows, 'bundled' end
    end
    local discovered = find_in_path({'python3', 'python'})
    if discovered then return discovered, 'PATH' end
    return nil, nil
end

local python_path, python_source
do
    local configured = expand_path(o.python_runtime)
    if configured then
        python_path, python_source = configured, 'config'
    else
        python_path, python_source = resolve_python()
    end
end
if python_path and not file_exists(python_path) then
    msg.warn('[online-media] 配置的 python_runtime 不存在：' .. python_path
        .. '；在线解析会降级。请修正 script-opts/online_media.conf 或安装 python3')
end
if not python_path then
    msg.warn('[online-media] 未找到 Python 运行时（随包 runtime 与 PATH 均无 python3）；'
        .. '在线解析与弹幕会降级。可在 script-opts/online_media.conf 设置 python_runtime')
end

local youtube_js_path, youtube_js_source = resolve_tool(o.youtube_js_runtime, {'deno'})
local youtube_ytdl_path, youtube_ytdl_source = resolve_tool(o.youtube_ytdl, {'yt-dlp'})

msg.verbose(string.format('[online-media] python=%s (%s)',
    tostring(python_path), tostring(python_source or 'missing')))
msg.verbose(string.format('[online-media] deno=%s (%s)',
    tostring(youtube_js_path), tostring(youtube_js_source or 'missing')))
msg.verbose(string.format('[online-media] yt-dlp=%s (%s)',
    tostring(youtube_ytdl_path), tostring(youtube_ytdl_source or 'missing')))

--- YouTube JavaScript 运行时参数：没有运行时就不传（让 yt-dlp 自己报错并降级），
--- 而不是拼出 "--js-runtime nil" 或直接让脚本抛错。
local function js_runtime_args()
    if not youtube_js_path then return {} end
    return {'--js-runtime', youtube_js_path}
end

local function youtube_missing_component()
    local missing = {}
    if not file_exists(youtube_ytdl_path) then missing[#missing + 1] = 'yt-dlp' end
    if not file_exists(youtube_js_path) then missing[#missing + 1] = 'deno（JavaScript 运行时）' end
    return #missing > 0 and table.concat(missing, ' / ') or nil
end

local probe_path = mp.command_native({'expand-path', '~~/online-media/probe_stream.py'})
local live_resolver_path = mp.command_native({'expand-path', o.live_resolver})
local bilibili_resolver_path = mp.command_native({'expand-path', o.bilibili_resolver})
local bilibili_live_danmaku_path = mp.command_native({'expand-path', o.bilibili_live_danmaku})
local platform_live_danmaku_path = mp.command_native({'expand-path', o.platform_live_danmaku})
local douyin_live_danmaku_path = mp.command_native({'expand-path', o.douyin_live_danmaku})
local cookie_path = mp.command_native({'expand-path', o.bilibili_cookie_file})
local douyu_cookie_path = mp.command_native({'expand-path', o.douyu_cookie_file})
local youtube_cookie_path = mp.command_native({'expand-path', o.youtube_cookie_file})
local youtube_resolver_path = mp.command_native({'expand-path', o.youtube_resolver})

local generation = 0
local resolve_request = nil
local resolve_timer = nil
local cancel_binding = false
local reconnect_timer = nil
local reconnect_ticket = 0
local stability_timer = nil
local live_alive_timer = nil
local stop_cleanup_ticket = 0
local pending_open = nil
-- 断流重连「已经决定要重连，但还没真的发出 loadfile」的这段窗口。它是 pending_open
-- 的前一阶段：先挂在这里，等下一次 start-file 再提升成 pending_open。
--
-- 为什么不直接写进 pending_open：end-file 与 start-file 之间 mpv 会做播放列表前进。
-- 只要 loop-playlist 不是 no（用户按了 uosc 控制栏的列表循环、音乐模式接管了循环等），
-- mpv 就不会停在原地等我们的重连延迟，而是立刻自己重新加载同一个地址。那时如果重连
-- 状态还锁在尚未触发的定时器回调里，这次 start-file 就什么都读不到：档位退回默认候选、
-- 重连计数归零、而且会在刚断掉的那台 CDN 上原地重试。
local reconnect_pending = nil
-- 断流预警与「提前解析好的下一条线路」。
--
-- 虎牙的 FLV 边缘节点会周期性主动结束响应（实测每条连接 20~120 秒，三台主机一样），
-- 而 mpv 手里的缓存还能再播好几秒（实测 8.7 秒）——这段提前量足够把下一次解析在
-- 后台跑完。原来的恢复路径是「播完缓存 → end-file → 等 2 秒 → 解析 2.4 秒」，用户
-- 看见的冻结 4.5 秒；把解析挪进这段提前量之后，只剩「建连到首帧」那一秒多。
--
-- 存的是**刚解析出来的** descriptor，不是上次播放用的那份：签名地址的有效期是几分钟，
-- 但档位与线路列表随时会变，重连必须拿到当下这一份。end-file 用完即弃。
local live_eof_timer = nil
local live_preload = nil
local live_preload_request = nil
-- 预解析结果最多留这么久。正常只有几秒（缓存排空的时间），留宽一点是为了深缓存情形。
local LIVE_PRELOAD_MAX_AGE = 60
-- 清晰度切换事务。它和 pending_open 不是一回事：pending_open 描述「下一次
-- loadfile 要带什么意图进去」，这里是「正在后台准备的那一次切换」。准备期间
-- 旧流还在播，所以进度不能写进 state —— 那会被下一轮 reset_state 冲掉，也会让
-- UI 以为正在播的就是新档位。
local switch = {
    ticket = 0,
    quality_id = '',
    phase = 'idle',   -- idle / resolving / probing
    request = nil,
    timer = nil,
    temp = nil,
}
local live_danmaku_request = nil
local live_danmaku_timer = nil
local live_danmaku_path = nil
local live_danmaku_offset = 0
local live_danmaku_partial = ''
local live_danmaku_ticket = 0
local live_danmaku_started_url = ''
local live_danmaku_startup_retry_used = false
local ensure_live_danmaku_started

local state = {
    matched = false,
    source_url = '',
    canonical_url = '',
    platform = '',
    kind = '',
    content_type = '',
    resolver = '',
    status = 'idle',
    candidates = nil,
    candidate_index = 0,
    reconnect_attempt = 0,
    failed_host = '',
    failed_quality_id = '',
    streamlink_refreshes = 0,
    file_loaded = false,
    quality_id = '',
    quality_options = {},
    requested_quality = '',
    resume_time = 0,
    resume_paused = false,
    -- 点播切档要搬过去的播放状态。直播用不到它们，永远是空/零。
    resume_speed = 0,
    resume_aid = '',
    resume_sid = '',
    -- 记下「这一轮是切档切过来的」，供切换完成判定区分「首次起播」与「换流」。
    switched_from_quality = '',
    force_play = false,
    display_title = '',
    live_danmaku_status = 'off',
    failure_kind = '',
    -- 番剧 / PGC：当前这一集的 ep_id（裸 id）。列表怎么排、名字怎么显示、失败时
    -- 报哪一集都靠它，见 bangumi_* 那一段。
    bangumi_ep = '',
}

local function set_user_data(name, value)
    if type(value) == 'boolean' then
        mp.set_property_bool('user-data/online-media/' .. name, value)
    else
        mp.set_property_native('user-data/online-media/' .. name, tostring(value or ''))
    end
end

-- Keep live capability as an explicit published state instead of making UI
-- consumers reconstruct it from timing-sensitive metadata. Huya/Douyu/Douyin
-- routes in this module are live-only; Bilibili/YouTube remain content-type/kind
-- driven because they also handle VOD. URL checks are only a final safety net.
local function state_is_live_context()
    local content_type = tostring(state.content_type or ''):lower()
    if content_type == 'live' then return true end

    local kind = tostring(state.kind or ''):lower()
    if kind == 'live' or kind:match('%-live$') then return true end

    local platform = tostring(state.platform or ''):lower()
    if platform == 'huya' or platform == 'douyu' or platform == 'douyin' then
        return true
    end

    local url = tostring(state.canonical_url ~= '' and state.canonical_url or state.source_url or ''):lower()
    if url:match('^https?://live%.bilibili%.com[/?:]')
            or url:match('^https?://live%.douyin%.com[/?:]') then
        return true
    end
    return false
end

local function url_host(url)
    return tostring(url or ''):match('^https?://([^/]+)') or ''
end

local function publish()
    set_user_data('matched', state.matched)
    set_user_data('platform', state.platform)
    set_user_data('kind', state.kind)
    set_user_data('content-type', state.content_type)
    set_user_data('resolver', state.resolver)
    set_user_data('status', state.status)
    set_user_data('canonical-url', state.canonical_url)
    set_user_data('quality', state.candidates and state.candidates[state.candidate_index]
        and state.candidates[state.candidate_index].quality or '')
    -- 主菜单那一行的摘要（档位 · 分辨率 · 帧率），完整标签仍走上面的 quality。
    set_user_data('quality-summary', state.candidates and state.candidates[state.candidate_index]
        and state.candidates[state.candidate_index].quality_summary or '')
    set_user_data('quality-id', state.quality_id)
    set_user_data('quality-options-json', utils.format_json(state.quality_options or {}))
    set_user_data('can-reload-live', state.matched and state_is_live_context())
    set_user_data('candidate-count', state.candidates and #state.candidates or 0)
    -- 只发布主机名（不含签名串），断流重连是否真的换了 CDN 靠它才看得出来。
    set_user_data('candidate-host', state.candidates and state.candidates[state.candidate_index]
        and url_host(state.candidates[state.candidate_index].url) or '')
    set_user_data('reconnect-attempt', state.reconnect_attempt)
    set_user_data('live-danmaku-status', state.live_danmaku_status)
    set_user_data('failure-kind', state.failure_kind)
end

local function reset_state(reconnect_attempt, pending)
    pending = pending or {}
    -- 新事务开始，上一次断流挂起、还没兑现的重连意图到此为止。
    reconnect_pending = nil
    state = {
        matched = false,
        source_url = '',
        canonical_url = '',
        platform = '',
        kind = '',
        content_type = '',
        resolver = '',
        status = 'idle',
        candidates = nil,
        candidate_index = 0,
        reconnect_attempt = reconnect_attempt or 0,
        failed_host = tostring(pending.failed_host or ''),
        failed_quality_id = tostring(pending.failed_quality_id or ''),
        streamlink_refreshes = 0,
        youtube_media_retries = pending.youtube_media_retries or {},
        youtube_media_refreshes = pending.youtube_media_refreshes or 0,
        youtube_media_started = pending.youtube_media_started,
        retry_descriptor = pending.retry_descriptor,
        retry_candidate = pending.retry_candidate,
        -- 无缝切档预先解析并验证好的结果。on_load 见到它就跳过重新解析，
        -- 切档的黑屏只剩「建连到首帧」这一段。
        preload_descriptor = pending.preload_descriptor,
        preload_candidate = pending.preload_candidate,
        file_loaded = false,
        quality_id = '',
        quality_options = {},
        requested_quality = tostring(pending.quality_id or ''),
        resume_time = tonumber(pending.resume_time) or 0,
        resume_paused = pending.resume_paused == true,
        resume_speed = tonumber(pending.resume_speed) or 0,
        resume_aid = tostring(pending.resume_aid or ''),
        resume_sid = tostring(pending.resume_sid or ''),
        switched_from_quality = tostring(pending.switched_from_quality or ''),
        force_play = pending.force_play == true,
        display_title = '',
        live_danmaku_status = 'off',
        failure_kind = '',
        bangumi_ep = '',
    }
    publish()
end

-- file_exists 已在文件顶部定义（运行时发现要用）；这里不再重复定义。

-- 平台身份绑定的清晰度：接口只对能识别身份的请求给最高档（B站直播匿名压到超清；
-- 斗鱼在有蓝光档位的房间把原画扣给匿名请求，网页端登录后才出现原画/2K）。
-- 所以「有账号凭据就带上」，没有文件就保持匿名。登录态只喂给对应平台，不跨平台串
-- （虎牙 / 抖音 / YouTube 的解析器永远拿不到斗鱼的 Cookie）。
local function account_cookie_file(kind)
    if kind:match('^bilibili') and file_exists(cookie_path) then return cookie_path end
    if kind == 'douyu-live' and file_exists(douyu_cookie_path) then return douyu_cookie_path end
    return nil
end

local function sanitize_http_proxy(value)
    value = tostring(value or ''):match('^%s*(.-)%s*$') or ''
    if value == '' then return '' end
    if not value:match('^[%a][%w+%.%-]*://') then value = 'http://' .. value end
    if value:find('@', 1, true) or value:find('[%s\r\n]') then return '' end
    if not value:match('^https?://[^/]+:%d+/?$') then return '' end
    return value:gsub('/$', '')
end

local function registry_value(name)
    local result = mp.command_native({
        name = 'subprocess', playback_only = false,
        capture_stdout = true, capture_stderr = false,
        args = {
            'reg.exe', 'query',
            'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings',
            '/v', name,
        },
    })
    if type(result) ~= 'table' or tonumber(result.status) ~= 0 then return '' end
    return tostring(result.stdout or '')
end

local function detect_system_proxy()
    local proxy = sanitize_http_proxy(mp.get_property('http-proxy', ''))
    if proxy ~= '' then return proxy end
    for _, name in ipairs({'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy',
            'HTTP_PROXY', 'http_proxy'}) do
        proxy = sanitize_http_proxy(os.getenv(name))
        if proxy ~= '' then return proxy end
    end
    if package.config:sub(1, 1) ~= '\\' then return '' end

    local enabled = registry_value('ProxyEnable')
    if not enabled:match('0x0*1%s*$') then return '' end
    local output = registry_value('ProxyServer')
    local server = output:match('ProxyServer%s+REG_%w+%s+([^\r\n]+)') or ''
    if server:find(';', 1, true) then
        server = server:match('https=([^;]+)') or server:match('http=([^;]+)') or ''
    end
    return sanitize_http_proxy(server)
end

local function set_live_danmaku_status(status)
    state.live_danmaku_status = tostring(status or 'off')
    publish()
end

local function remove_live_danmaku_file(path)
    if not path or path == '' then return end
    pcall(os.remove, path)
end

local function stop_live_danmaku(clear_renderer)
    live_danmaku_ticket = live_danmaku_ticket + 1
    if live_danmaku_request then
        local request,path=live_danmaku_request,live_danmaku_path
        if state.platform=='douyin' and path then
            -- Give the isolated browser receiver time to release its profile.
            -- The job object still kills its tree if mpv shuts down immediately.
            local signal=io.open(path..'.stop','wb')
            if signal then signal:close() end
            mp.add_timeout(3,function()
                pcall(mp.abort_async_command,request)
                remove_live_danmaku_file(path)
                remove_live_danmaku_file(path..'.stop')
            end)
        else
            pcall(mp.abort_async_command,request)
        end
        live_danmaku_request = nil
    end
    if live_danmaku_timer then
        live_danmaku_timer:kill()
        live_danmaku_timer = nil
    end
    local old_path = live_danmaku_path
    live_danmaku_path = nil
    live_danmaku_offset = 0
    live_danmaku_partial = ''
    remove_live_danmaku_file(old_path)
    if clear_renderer then
        mp.commandv('script-message-to', 'uosc_danmaku', 'live-danmaku-stop')
    end
    set_live_danmaku_status('off')
end

local function consume_live_danmaku_line(line, messages)
    if line == '' or #line > 262144 then return end
    local value = utils.parse_json(line)
    if type(value) ~= 'table' then return end
    if value.type == 'status' then
        local status = tostring(value.status or '')
        if status == 'connecting' or status == 'reconnecting' or status == 'connected'
                or status == 'offline' or status == 'unavailable'
                or status == 'disconnected' or status == 'completed' then
            set_live_danmaku_status(status)
        end
        return
    end
    if value.type ~= 'batch' or type(value.messages) ~= 'table' then return end
    for _, item in ipairs(value.messages) do
        if type(item) == 'table' and type(item.text) == 'string'
                and item.text ~= '' and #messages < 240 then
            messages[#messages + 1] = {
                text = item.text:sub(1, 480),
                type = tonumber(item.type) or 1,
                size = tonumber(item.size) or 25,
                color = tonumber(item.color) or 0xFFFFFF,
            }
        end
    end
end

local function poll_live_danmaku()
    if not live_danmaku_path then return end
    local handle = io.open(live_danmaku_path, 'rb')
    if not handle then return end
    local size = handle:seek('end') or 0
    if size < live_danmaku_offset then
        live_danmaku_offset = 0
        live_danmaku_partial = ''
    end
    handle:seek('set', live_danmaku_offset)
    local chunk = handle:read('*a') or ''
    live_danmaku_offset = handle:seek() or size
    handle:close()
    if chunk == '' then return end

    local content = live_danmaku_partial .. chunk
    local position = 1
    local messages = {}
    while true do
        local newline = content:find('\n', position, true)
        if not newline then break end
        local line = content:sub(position, newline - 1):gsub('\r$', '')
        consume_live_danmaku_line(line, messages)
        position = newline + 1
    end
    live_danmaku_partial = content:sub(position)
    if #live_danmaku_partial > 262144 then live_danmaku_partial = '' end
    if #messages > 0 then
        local payload = utils.format_json(messages)
        if payload then
            mp.commandv('script-message-to', 'uosc_danmaku', 'live-danmaku-batch', payload)
        end
    end
end

local function start_live_danmaku()
    if not o.live_danmaku or state.content_type ~= 'live' then return end
    local helper_path = nil
    local helper_args = {}
    if state.kind == 'bilibili-live' then
        helper_path = bilibili_live_danmaku_path
    elseif state.platform == 'douyin' then
        helper_path = douyin_live_danmaku_path
    elseif state.platform == 'douyu' or state.platform == 'huya' then
        helper_path = platform_live_danmaku_path
        helper_args = {'--platform', state.platform}
    else
        set_live_danmaku_status('unsupported')
        return
    end
    if not file_exists(python_path) then
        set_live_danmaku_status('unavailable')
        msg.warn('[online-media] live danmaku disabled: Python runtime not found'
            .. ' (set python_runtime in script-opts/online_media.conf)')
        return
    end
    if not file_exists(helper_path) then
        set_live_danmaku_status('unavailable')
        msg.warn('[online-media] live danmaku helper missing: ' .. tostring(helper_path))
        return
    end

    stop_live_danmaku(true)
    live_danmaku_ticket = live_danmaku_ticket + 1
    local ticket = live_danmaku_ticket
    local started_before_file_loaded = not state.file_loaded
    local temp_root = os.getenv('TEMP') or os.getenv('TMP') or '.'
    local process_id = utils.getpid and utils.getpid()
        or mp.get_property_number('pid', 0) or 0
    local pid = tostring(process_id):gsub('[^%d]', '')
    live_danmaku_path = utils.join_path(temp_root, string.format(
        'mpv-yaozhi-%s-live-danmaku-%s-%d.jsonl', state.platform, pid, ticket))
    live_danmaku_offset = 0
    live_danmaku_partial = ''
    remove_live_danmaku_file(live_danmaku_path)
    set_live_danmaku_status('connecting')
    mp.commandv('script-message-to', 'uosc_danmaku', 'live-danmaku-reset', state.platform)

    local room_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
    live_danmaku_started_url = room_url
    local args = {
        python_path,
        helper_path,
    }
    for _, value in ipairs(helper_args) do args[#args + 1] = value end
    args[#args + 1] = '--room-url'
    args[#args + 1] = room_url
    args[#args + 1] = '--output'
    args[#args + 1] = live_danmaku_path
    args[#args + 1] = '--timeout'
    args[#args + 1] = tostring(math.max(5, math.min(15, o.resolver_timeout)))
    args[#args + 1] = '--max-reconnects'
    args[#args + 1] = tostring(o.live_danmaku_max_reconnects)
    live_danmaku_request = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        if ticket ~= live_danmaku_ticket then return end
        live_danmaku_request = nil
        poll_live_danmaku()
        if live_danmaku_timer then
            live_danmaku_timer:kill()
            live_danmaku_timer = nil
        end
        remove_live_danmaku_file(live_danmaku_path)
        live_danmaku_path = nil
        if state.live_danmaku_status ~= 'offline'
                and state.live_danmaku_status ~= 'unavailable'
                and state.live_danmaku_status ~= 'disconnected' then
            local completed = success and result and result.status == 0
            set_live_danmaku_status(completed and 'completed' or 'unavailable')
        end
        if not success then
            local detail = tostring(error or (result and result.error_string) or '')
            detail = detail:gsub('https?://[^%s]+', '<redacted-url>'):sub(1, 300)
            msg.warn('[online-media] live danmaku sidecar exited: ' .. detail)
        end
        -- The early process may exit just after file-loaded's liveness check.
        -- Its original startup phase still permits the same one-shot recovery.
        if started_before_file_loaded and state.file_loaded then
            ensure_live_danmaku_started()
        end
    end)
    live_danmaku_timer = mp.add_periodic_timer(
        math.max(0.15, math.min(1, tonumber(o.live_danmaku_poll) or 0.35)),
        poll_live_danmaku)
end

ensure_live_danmaku_started = function()
    if not state.matched or not state.file_loaded or state.content_type ~= 'live' then return end
    local room_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
    local changed_room = live_danmaku_started_url ~= room_url
    local failed_start = not live_danmaku_request
        and (state.live_danmaku_status == 'unavailable'
            or state.live_danmaku_status == 'disconnected')
    if (changed_room or failed_start) and not live_danmaku_startup_retry_used then
        -- Canonicalizing a share link or recovering an early transient failure
        -- gets one post-load launch. Offline/completed helpers are not retried.
        live_danmaku_startup_retry_used = true
        start_live_danmaku()
    end
end

local function platform_label()
    local labels = {
        youtube = 'YouTube',
        bilibili = 'B站',
        douyin = '抖音',
        douyu = '斗鱼',
        huya = '虎牙',
    }
    return labels[state.platform] or '在线'
end

local function configure_live_playback()
    mp.set_property('file-local-options/cache', 'yes')
    mp.set_property('file-local-options/cache-on-disk', 'no')
    mp.set_property('file-local-options/cache-pause', 'yes')
    mp.set_property('file-local-options/cache-pause-initial', 'yes')
    mp.set_property('file-local-options/cache-pause-wait', '1.5')
    -- 10 秒足以吸收常见网络抖动，同时把直播延迟上限压住。20 秒时网络好会
    -- 悄悄缓满，延迟跟着涨回去（FLV 实测只缓 3.8 秒，HLS 曾到 9.3 秒）。
    mp.set_property('file-local-options/cache-secs', '10')
    mp.set_property('file-local-options/demuxer-max-bytes', '128MiB')
    mp.set_property('file-local-options/demuxer-max-back-bytes', '32MiB')
    mp.set_property('file-local-options/network-timeout', '20')
    mp.set_property_native('file-local-options/stream-lavf-o', {
        reconnect = '1',
        reconnect_streamed = '1',
        reconnect_delay_max = '5',
        reconnect_on_network_error = '1',
    })
end

local function configure_bilibili_ytdl()
    local raw = {
        ['ignore-config'] = '',
        ['socket-timeout'] = tostring(o.resolver_timeout),
        retries = '2',
        ['fragment-retries'] = '2',
        ['extractor-retries'] = '2',
    }
    if file_exists(cookie_path) then
        raw.cookies = cookie_path
        mp.set_property('file-local-options/cookies', 'yes')
        mp.set_property('file-local-options/cookies-file', cookie_path)
    end
    mp.set_property_native('file-local-options/ytdl-raw-options', raw)
end

local function configure_youtube_playback()
    local proxy = detect_system_proxy()
    -- YouTube uses independent DASH video/audio requests. Build enough memory
    -- runway for bursty residential proxies without changing local files,
    -- AList/WebDAV, or unrelated HTTP streams.
    mp.set_property('file-local-options/cache', 'yes')
    mp.set_property('file-local-options/cache-on-disk', 'no')
    mp.set_property('file-local-options/cache-pause', 'yes')
    mp.set_property('file-local-options/cache-pause-initial', 'yes')
    mp.set_property('file-local-options/cache-pause-wait', '5')
    mp.set_property('file-local-options/cache-secs', '60')
    mp.set_property('file-local-options/demuxer-max-bytes', '256MiB')
    mp.set_property('file-local-options/demuxer-max-back-bytes', '64MiB')
    mp.set_property('file-local-options/network-timeout', '20')
    mp.set_property_bool('file-local-options/cookies', false)
    if proxy ~= '' then
        mp.set_property('file-local-options/http-proxy', proxy)
        mp.set_property_native('file-local-options/stream-lavf-o', {http_proxy = proxy})
        -- Keep this compatibility exception scoped to proxied ephemeral Google
        -- media URLs. yt-dlp webpage/API requests still verify TLS.
        mp.set_property_bool('file-local-options/tls-verify', false)
    end
    msg.info('[online-media] YouTube network route: ' .. (proxy ~= '' and 'system-proxy' or 'direct'))
    return proxy
end

local function configure_youtube_ytdl()
    local proxy = configure_youtube_playback()
    -- Prefer separate direct-HTTPS DASH tracks at the highest available
    -- resolution. Manifest-only variants remain a fallback, but avoiding them
    -- first makes proxy playback more reliable and preserves 4K/AV1 when the
    -- video exposes those direct tracks.
    mp.set_property('file-local-options/ytdl-format',
        'bestvideo[protocol=https]+bestaudio[protocol=https]/bestvideo+bestaudio/best')
    local raw = {
        ['ignore-config'] = '',
        ['no-playlist'] = '',
        ['socket-timeout'] = tostring(o.resolver_timeout),
        retries = '2',
        ['fragment-retries'] = '2',
        ['extractor-retries'] = '2',
    }
    -- 没有 deno 时不传 js-runtimes：让 yt-dlp 自己报错并由上面的失败归类给出
    -- 可读提示，而不是把空字符串拼进参数里。
    if youtube_js_path then raw['js-runtimes'] = 'deno:' .. youtube_js_path end
    if proxy ~= '' then
        raw.proxy = proxy
        mp.set_property('file-local-options/http-proxy', proxy)
    end
    local account_status = mp.get_property_native('user-data/youtube-account/status')
    if file_exists(youtube_cookie_path) and account_status ~= 'expired' and account_status ~= 'invalid' then
        raw.cookies = youtube_cookie_path
    end
    mp.set_property_native('file-local-options/ytdl-raw-options', raw)
end

local youtube_failure_priority = {
    media_denied = 1,
    generic = 0,
    network = 1,
    js_runtime = 2,
    login_required = 3,
    verification_required = 4,
    auth_unavailable = 4,
}

local function record_youtube_failure(kind)
    if not state.matched or state.platform ~= 'youtube' then return end
    local current = youtube_failure_priority[state.failure_kind] or -1
    if (youtube_failure_priority[kind] or 0) > current then
        state.failure_kind = kind
    end
end

local function youtube_failure_message()
    local missing = youtube_missing_component()
    if missing then
        return 'YouTube 解析组件不完整：未找到 ' .. missing
            .. '（自动发现失败时可用 script-opts/online_media.conf 指定路径）'
    end
    if state.failure_kind == 'login_required' then
        local status = mp.get_property_native('user-data/youtube-account/status')
        if status == 'expired' then
            return 'YouTube 登录已失效：请在“账号相关 > YouTube 登录验证”中重新获取'
        end
        return 'YouTube 要求登录或人机验证：请打开“账号相关 > YouTube 登录验证”'
    end
    if state.failure_kind == 'verification_required' then
        return 'YouTube 账号仍有效，但当前请求需要人机验证，请检查代理出口或在浏览器验证'
    end
    if state.failure_kind == 'auth_unavailable' then
        return '暂时无法确认 YouTube 登录状态，请检查代理或稍后重试'
    end
    if state.failure_kind == 'js_runtime' then
        return 'YouTube JavaScript 验证失败，请更新完整播放器组件'
    end
    if state.failure_kind == 'network' then
        return 'YouTube 连接超时：请检查代理线路或出口质量后重试'
    end
    if state.failure_kind == 'media_denied' then
        return 'YouTube 媒体线路暂时拒绝访问，有限重试仍未成功；请稍后重试或更换代理出口'
    end
    return file_exists(youtube_cookie_path)
        and 'YouTube 视频解析失败：请检查网络、登录状态或更新播放器'
        or 'YouTube 视频解析失败：请检查网络后重试；若提示人机验证请登录'
end

mp.enable_messages('warn')
mp.register_event('log-message', function(event)
    if not state.matched or state.platform ~= 'youtube' then return end
    local text = tostring(event and event.text or ''):lower()
    if text == '' then return end
    if text:find('sign in to confirm', 1, true)
            or text:find('login_required', 1, true)
            or text:find('use --cookies-from-browser', 1, true)
            or text:find('account cookies are no longer valid', 1, true) then
        record_youtube_failure('login_required')
    elseif text:find('no supported javascript runtime', 1, true)
            or text:find('javascript challenge solving failed', 1, true)
            or text:find('js challenge provider', 1, true) and text:find('unavailable', 1, true) then
        record_youtube_failure('js_runtime')
    elseif text:find('timed out', 1, true)
            or text:find('timeout was reached', 1, true)
            or text:find('unable to download webpage', 1, true)
            or text:find('proxyerror', 1, true)
            or text:find('connectionerror', 1, true) then
        record_youtube_failure('network')
    elseif text:find('403', 1, true) or text:find('429', 1, true) then
        record_youtube_failure('media_denied')
    end
end)

local function remove_cancel_binding()
    if not cancel_binding then return end
    mp.remove_key_binding('online-media-cancel')
    cancel_binding = false
end

local function clear_resolve_handles()
    if resolve_timer then
        resolve_timer:kill()
        resolve_timer = nil
    end
    resolve_request = nil
    remove_cancel_binding()
end

local function safe_abort_request()
    if resolve_request then
        pcall(mp.abort_async_command, resolve_request)
        resolve_request = nil
    end
    if resolve_timer then
        resolve_timer:kill()
        resolve_timer = nil
    end
    remove_cancel_binding()
end

local function header_fields(headers)
    local fields = {}
    local allowed = {['user-agent'] = true, referer = true, origin = true}
    if type(headers) == 'table' then
        for key, value in pairs(headers) do
            if allowed[tostring(key):lower()] and type(value) == 'string' and value ~= '' then
                fields[#fields + 1] = tostring(key) .. ': ' .. value:gsub('[\r\n]', '')
            end
        end
    end
    table.sort(fields)
    return fields
end

local function apply_candidate(index)
    local candidate = state.candidates and state.candidates[index]
    if type(candidate) ~= 'table' or type(candidate.url) ~= 'string'
            or not candidate.url:match('^https?://') then
        return false
    end
    state.candidate_index = index
    if state.platform == 'youtube' and not state.youtube_media_started then
        state.youtube_media_started = mp.get_time()
    end
    state.quality_id = tostring(candidate.quality_id or '')
    if state.platform == 'youtube' and mp.get_property_native('option-info/curl-enabled') then
        if state.youtube_original_curl == nil then
            state.youtube_original_curl = mp.get_property_bool('curl-enabled', false)
        end
        -- Some proxy/FFmpeg TLS combinations stall on a nonzero Range seek.
        -- Direct video/audio files use curl's interruptible range transport.
        -- Do not enable nested HLS IO on FFmpeg versions which gate it off.
        mp.set_property_bool('file-local-options/curl-enabled',
            candidate.direct_media == true or state.youtube_original_curl)
    end
    local proxy = sanitize_http_proxy(candidate.http_proxy)
    if state.platform ~= 'youtube' and proxy ~= ''
            and not proxy:match('^https?://127%.0%.0%.1:%d+$')
            and not proxy:match('^https?://localhost:%d+$')
            and not proxy:match('^https?://%[::1%]:%d+$') then
        proxy = ''
    end
    mp.set_property('file-local-options/http-proxy', proxy)
    local fields = header_fields(candidate.headers)
    mp.set_property_native('file-local-options/http-header-fields', fields)
    -- Some signed Bilibili/Douyu/Huya/Douyin media CDNs currently serve
    -- certificate chains/hostnames rejected by this bundled OpenSSL build.
    -- Douyin's signed FLV CDN is one of them: without this exception its
    -- top-tier FLV routes fail TLS and playback silently stays on the
    -- lower-tier HLS fallback. Scope the compatibility exception to the
    -- ephemeral media file returned by our allowlisted resolver. No Cookie
    -- header is forwarded here, while Python account/API requests continue to
    -- use normal certificate verification.
    local compatibility_media = state.platform == 'bilibili'
        or state.platform == 'douyu' or state.platform == 'huya'
        or state.platform == 'douyin'
        or (state.platform == 'youtube' and proxy ~= '')
    if compatibility_media then
        mp.set_property_bool('file-local-options/tls-verify', false)
        mp.set_property_bool('file-local-options/cookies', false)
    end
    if type(candidate.headers) == 'table' then
        for key, value in pairs(candidate.headers) do
            if tostring(key):lower() == 'user-agent' then
                mp.set_property('file-local-options/user-agent', tostring(value):gsub('[\r\n]', ''))
            end
        end
    end
    mp.set_property('stream-open-filename', candidate.url)
    if type(candidate.audio_url) == 'string' and candidate.audio_url:match('^https?://') then
        mp.set_property('file-local-options/audio-file-auto', 'no')
        mp.set_property_native('file-local-options/audio-files', {candidate.audio_url})
    else
        mp.set_property_native('file-local-options/audio-files', {})
    end
    state.status = 'opening'
    publish()
    return true
end

-- ===== B站番剧 / PGC：整季正片播放列表 =====
--
-- 番剧页面（/bangumi/play/ep<id>）默认只解析当前这一集，播完就停在 idle。这里把整季
-- 正片摆进 mpv 的播放列表，但**条目只存每集的页面地址**：真正切到那一集时照常走
-- on_load → 解析链路（登录态 Cookie、最高可用画质、无缝切档、断流重连全部复用），
-- 所以不存在「提前解析出来的签名地址播到一半就过期」这回事。
--
-- 为什么必须用 insert-at / append：实测这个 build 的 `loadfile ... replace` 会清空
-- 整个播放列表（无缝切档 1111 行、直播重连 1948 行走的都是它），`stop` 同样会清空。
-- 所以列表被抹掉之后由 file-loaded 里的**幂等重建**补回来：判据是「本季在列表里的
-- 条目数 < 正片数」。正常播下一集、从菜单点选切集时列表早已齐全，重建是空操作。
--
-- 这个表跨 loadfile 事务存活（reset_state 换掉的是 state，不碰这里）。
local bangumi = {
    seasons = {},      -- season_id -> {season_id, title, total, episodes = {{ep_id, url, label}}}
    order = {},        -- 上面那张表的接收顺序，只用于淘汰
    labels = {},       -- ep_id -> 「第N话 标题」，播放列表显示名的唯一来源
    rebuild_timer = nil,
    rebuild_ticket = 0,
}
local BANGUMI_SEASON_KEEP = 4

-- 只认页面地址形式（播放列表分类、on_load 判身份都用它）。router 允许 EP / Ep
-- 这类大小写变体，这里跟着放宽（地址里的数字不受大小写影响）。
local function bangumi_ep_id(value)
    local id = tostring(value or ''):lower():match('/bangumi/play/ep(%d+)')
    return id or ''
end

-- 宽松版：也接受裸 ep_id（state.bangumi_ep 存的就是裸 id）。
local function bangumi_anchor_id(value)
    local text = tostring(value or '')
    if text:match('^%d+$') then return text end
    return bangumi_ep_id(text)
end

-- 番剧条目的显示名统一从这里写进 uosc 的播放列表：`titles[行地址] = 「第N话 标题」`。
-- 只写**列表里真实存在的行**加当前这一集的别名键，不让 titles 无限膨胀——
-- playlistmanager 会把读到的名字按 filename 永久缓存（get_saved_playlist_title）。
local function bangumi_write_titles()
    -- 抄进一张**新表**再写，不能直接读回来改。mpv 的 user-data 属性当前值若是空数组
    -- （`[]`），读回来的表再写回去会被当数组写走、字符串键全丢（实测：读-改-写之后属性
    -- 还是 `[]`，换成新表就正常）。而本函数的头一次调用正好会踩这个坑——当前这一行是
    -- 季地址、还认不出是哪一集，写下去的表就是空的；此后每次读-改-写都继承空数组身份
    -- 静默失效，播放列表里的名字就永远空着。
    local existing = mp.get_property_native('user-data/playlistmanager/titles')
    local titles = {}
    if type(existing) == 'table' then
        for key, value in pairs(existing) do
            if type(key) == 'string' and type(value) == 'string' then
                titles[key] = value
            end
        end
    end
    local count = mp.get_property_number('playlist-count', 0) or 0
    for index = 0, count - 1 do
        local name = mp.get_property('playlist/' .. index .. '/filename', '')
        local label = bangumi.labels[bangumi_ep_id(name)]
        if label then titles[name] = label end
    end
    -- 正在播的这一行的地址不一定长得像 ep 页：用户粘的可能是 /video/BV…（被平台
    -- 重定向到番剧页）或者 ss 链接（播的是第一集）。它们和当前这一集是同一个东西。
    local label = bangumi.labels[state.bangumi_ep]
    if label then
        for _, key in ipairs({state.source_url, state.canonical_url}) do
            if type(key) == 'string' and key ~= '' then titles[key] = label end
        end
    end
    mp.set_property_native('user-data/playlistmanager/titles', titles)
end

-- `loadfile` 是把命令丢给 mpv 核心、由它稍后执行：刚发完插入就回头读播放列表，
-- 有可能还看不到新行（实测插入与写名字相隔 1 毫秒时列表还是旧的，4 毫秒才看得到）。
-- 与其赌这个时间差，不如让列表每次变化都补写一遍名字——行数变了就说明 mpv 已经
-- 处理完那几条插入，这一刻写的名字才落得到实处。读-改-写，别人的条目不动。
mp.observe_property('playlist-count', 'number', function(_, _)
    if state.bangumi_ep == '' or next(bangumi.labels) == nil then return end
    bangumi_write_titles()
end)

-- 收下一季的正片表。Python 侧已经滤掉预告 / 花絮 / SP（section_type > 0）并排好序，
-- 这里不重排，只做形状校验：一个字段不对不该让整季列表消失。
local function bangumi_adopt(season)
    if type(season) ~= 'table' or type(season.episodes) ~= 'table' then return false end
    local season_id = tostring(season.season_id or '')
    if season_id == '' then return false end
    local episodes = {}
    for _, entry in ipairs(season.episodes) do
        if type(entry) == 'table' then
            local ep_id = tostring(entry.ep_id or '')
            local url = tostring(entry.url or '')
            if ep_id ~= '' and url ~= '' then
                local label = tostring(entry.label or '')
                episodes[#episodes + 1] = {ep_id = ep_id, url = url, label = label}
                if label ~= '' then bangumi.labels[ep_id] = label end
            end
        end
    end
    if #episodes == 0 then return false end
    if bangumi.seasons[season_id] == nil then
        bangumi.order[#bangumi.order + 1] = season_id
        while #bangumi.order > BANGUMI_SEASON_KEEP do
            bangumi.seasons[table.remove(bangumi.order, 1)] = nil
        end
    end
    bangumi.seasons[season_id] = {
        season_id = season_id,
        title = tostring(season.title or ''),
        total = tonumber(season.total) or #episodes,
        episodes = episodes,
    }
    bangumi_write_titles()
    return true
end

-- 当前播的这一集属于哪一季。用 ep 身份反查而不是记「上一次是哪一季」：粘了新链接
-- 之后旧值就是错的，而这个判据在列表混着两季条目时也照样成立。
local function bangumi_current_season()
    local ep_id = state.bangumi_ep
    if ep_id == '' then return nil end
    for _, season in pairs(bangumi.seasons) do
        for _, item in ipairs(season.episodes) do
            if item.ep_id == ep_id then return season end
        end
    end
    return nil
end

-- `insert-at` 的落点越过列表末尾时等于追加；用 append 表达同一件事，不去依赖
-- 越界插入这种没验证过的行为。
local function bangumi_insert(url, index)
    if index >= (mp.get_property_number('playlist-count', 0) or 0) then
        mp.commandv('loadfile', url, 'append')
    else
        mp.commandv('loadfile', url, 'insert-at', tostring(index))
    end
end

-- 把整季正片排进播放列表，并让「当前这一集」正好是正在播的那一行。幂等。
local function bangumi_ensure_playlist(season, anchor_ep)
    if type(season) ~= 'table' or type(season.episodes) ~= 'table' then return end
    local total = #season.episodes
    if total == 0 then return end

    local present = {}
    local count = mp.get_property_number('playlist-count', 0) or 0
    for index = 0, count - 1 do
        local ep_id = bangumi_ep_id(mp.get_property('playlist/' .. index .. '/filename', ''))
        if ep_id ~= '' then present[ep_id] = true end
    end
    local have = 0
    for _, item in ipairs(season.episodes) do
        if present[item.ep_id] then have = have + 1 end
    end
    if have >= total then
        bangumi_write_titles()
        return
    end

    local anchor = bangumi_anchor_id(anchor_ep)
    local position = 0
    for index, item in ipairs(season.episodes) do
        if item.ep_id == anchor then
            position = index
            break
        end
    end
    local playlist_pos = mp.get_property_number('playlist-pos', -1) or -1

    -- 没有「当前集」这一行可以依靠：解析失败后 mpv 已经 idle（`stop` 会清空播放
    -- 列表），或者这一集本身不在正片里（正在播 PV / 花絮）。这时只把缺的正片排成
    -- 待播队列，**不自动起播**——一集坏掉就自动重试会变成死循环，交给用户点选。
    if playlist_pos < 0 or position == 0 then
        -- 从 0 号位开始**按话数顺序**排：列表为空时就是顺序追加（`insert-at` 插进
        -- 已插进去的后面才保持正序，全插在 0 号位会反过来）。列表里若还有别的文件，
        -- 整季排在它前面，而正在播的那一条不受插入影响。
        local cursor = 0
        for _, item in ipairs(season.episodes) do
            if not present[item.ep_id] then
                bangumi_insert(item.url, cursor)
                cursor = cursor + 1
            end
        end
        bangumi_write_titles()
        return
    end

    -- 前置集：从后往前都插在正在播的这一行的位置上，插完自然就是正序。
    local inserted = 0
    for index = position - 1, 1, -1 do
        local item = season.episodes[index]
        if not present[item.ep_id] then
            bangumi_insert(item.url, playlist_pos)
            inserted = inserted + 1
        end
    end
    -- 后续集：接着正在播的这一行往后排。
    local cursor = playlist_pos + inserted
    for index = position + 1, total do
        local item = season.episodes[index]
        if not present[item.ep_id] then
            cursor = cursor + 1
            bangumi_insert(item.url, cursor)
        end
    end
    bangumi_write_titles()
end

-- 单集失败时 mpv 会自己跳过它，解析组件缺失那类硬失败则会 stop —— 而 `stop` 会把
-- 整个播放列表清空。等 mpv 收拾完再把整季放回去，免得「一集坏掉，整季列表都没了」。
-- 只在确实 idle 时才动手：那说明用户没有紧接着打开别的东西。
local function bangumi_schedule_rebuild(anchor_ep)
    local season = bangumi_current_season()
    if not season then return end
    local anchor = bangumi_anchor_id(anchor_ep)
    if bangumi.rebuild_timer then bangumi.rebuild_timer:kill() end
    bangumi.rebuild_ticket = bangumi.rebuild_ticket + 1
    local ticket = bangumi.rebuild_ticket
    bangumi.rebuild_timer = mp.add_timeout(0.4, function()
        bangumi.rebuild_timer = nil
        if ticket ~= bangumi.rebuild_ticket then return end
        if not mp.get_property_bool('idle-active', false) then return end
        bangumi_ensure_playlist(season, anchor)
    end)
end

-- 正在播的这一集有正片表可用时，播放列表里的名字由 bangumi_write_titles 统一负责。
-- 没有 season 数据（接口失败 / 非番剧）时返回 false，一切照旧。
local function bangumi_owns_current_title()
    if bangumi.labels[state.bangumi_ep] == nil then return false end
    return bangumi_ep_id(state.source_url) ~= '' or bangumi_ep_id(state.canonical_url) ~= ''
end

local function remember_playlist_title(title)
    if title == '' then return end
    -- 「第N话 标题」比「标题 · UP主」更适合当播放列表条目名；而且 playlistmanager
    -- 一旦读到某个 filename 的名字就会缓存住，这里写上去就再也改不回来了。
    if bangumi_owns_current_title() then return end
    local titles = mp.get_property_native('user-data/playlistmanager/titles') or {}
    if type(titles) ~= 'table' then titles = {} end
    local keys = {state.source_url, state.canonical_url}
    local pos = mp.get_property_number('playlist-pos', -1)
    if pos and pos >= 0 then
        keys[#keys + 1] = mp.get_property('playlist/' .. pos .. '/filename', '')
    end
    for _, key in ipairs(keys) do
        if type(key) == 'string' and key ~= '' then titles[key] = title end
    end
    mp.set_property_native('user-data/playlistmanager/titles', titles)
end

-- 断流重连的起播线路。默认仍是候选 1（TX 优先、最高可用画质都不变）；只有在上一次
-- 连接是被 CDN 结束时，才轮到**同一清晰度**的下一条主机，避免每次断流都回到刚刚
-- 断掉的那个节点再断一次。同档没有其它主机时保持原样。
local function reconnect_candidate_index()
    local candidates = state.candidates or {}
    local failed = state.failed_host
    if failed == '' then return 1 end
    local quality = state.failed_quality_id
    local order = {}
    local first_of_host = {}
    for index, candidate in ipairs(candidates) do
        if quality == '' or tostring(candidate.quality_id or '') == quality then
            local host = url_host(candidate.url)
            if host ~= '' and first_of_host[host] == nil then
                first_of_host[host] = index
                order[#order + 1] = host
            end
        end
    end
    if #order < 2 then return first_of_host[failed] or 1 end
    for position, host in ipairs(order) do
        if host == failed then
            return first_of_host[order[position % #order + 1]]
        end
    end
    return first_of_host[order[1]] or 1
end

local function apply_descriptor(data)
    if type(data) ~= 'table' or data.ok ~= true or type(data.candidates) ~= 'table'
            or #data.candidates == 0 then
        return false
    end
    state.resolver = tostring(data.resolver or 'streamlink')
    state.canonical_url = tostring(data.canonical_url or state.canonical_url)
    state.platform = tostring(data.platform or state.platform)
    state.content_type = tostring(data.content_type or state.content_type)
    state.candidates = data.candidates
    state.quality_options = type(data.qualities) == 'table' and data.qualities or {}
    state.candidate_index = 0

    -- 番剧 / PGC 的 payload 会多一个 season（整季正片身份表）。先收下再写标题：
    -- 它的显示名归 bangumi_write_titles 管（remember_playlist_title 会被跳过），
    -- 而且这一集的身份要在后面按 ep 反查季的时候已经就位。
    if type(data.season) == 'table' then
        bangumi_adopt(data.season)
        -- ss / md 链接在 on_load 里认不出是哪一集（那是季地址），这里用解析回来的
        -- 规范地址补上。注意 bangumi_ep_id 没命中时返回的是空串而不是 nil，
        -- 不能靠 `or` 串联（空串在 Lua 里是真值）。
        if state.bangumi_ep == '' then
            local anchor = bangumi_ep_id(state.canonical_url)
            if anchor == '' then anchor = bangumi_ep_id(state.source_url) end
            state.bangumi_ep = anchor
        end
    end

    local title = tostring(data.title or '')
    local author = tostring(data.author or '')
    if title ~= '' then
        if author ~= '' then title = title .. ' · ' .. author end
        state.display_title = title
        mp.set_property('file-local-options/force-media-title', title)
        remember_playlist_title(title)
    end
    if state.content_type == 'live' then
        configure_live_playback()
    elseif state.platform == 'youtube' then
        configure_youtube_playback()
    end
    return apply_candidate(reconnect_candidate_index())
end

local function stop_failed_load(message)
    state.status = 'error'
    publish()
    -- 番剧：下面的 `stop` 会把整个播放列表清空，所以先把这一集是哪一集说清楚，
    -- 再排一次重建，让整季回到列表里等用户点选（单集失败不赔上整季）。
    local label = bangumi.labels[state.bangumi_ep]
    if label then
        message = label .. ' ' .. message
        bangumi_schedule_rebuild(state.bangumi_ep)
    end
    mp.osd_message(message, 6)
    mp.set_property('stream-open-filename', 'memory://')
    mp.add_timeout(0, function() mp.commandv('stop') end)
end

-- ===== 清晰度无缝切换：Prepare → Validate → Switch =====
--
-- 原来的切档是「立刻 loadfile 同一个房间地址 → on_load 里重新解析 → 才播新流」，
-- 于是解析要多久用户就黑屏多久，解析失败还会把正在看的流一起赔进去。现在改成
-- 三拍：旧流继续播着在后台解析，再逐条验证候选线路是不是真能出数据，通过了才
-- 换流；验证不过就什么都不做，画面完全不受影响。

local function switch_publish()
    set_user_data('switch-phase', switch.phase)
    set_user_data('switch-quality-id', switch.quality_id)
end

local function switch_cleanup_temp()
    if switch.temp then
        pcall(os.remove, switch.temp)
        switch.temp = nil
    end
end

-- 任何一笔新事务、任何一次新的播放事务开始，都要先走这里让旧事务的回调全部失效。
local function cancel_quality_switch()
    switch.ticket = switch.ticket + 1
    if switch.request then
        pcall(mp.abort_async_command, switch.request)
        switch.request = nil
    end
    if switch.timer then
        switch.timer:kill()
        switch.timer = nil
    end
    switch_cleanup_temp()
    if switch.phase ~= 'idle' or switch.quality_id ~= '' then
        switch.phase = 'idle'
        switch.quality_id = ''
        switch_publish()
    end
end

local function quality_label_for(quality_id)
    for _, quality in ipairs(state.quality_options or {}) do
        if tostring(quality.id or '') == quality_id then
            return tostring(quality.label or quality_id)
        end
    end
    return quality_id
end

-- 切档要复用「当前这次播放用的那个解析器」。分派规则必须和 on_load 里一致，
-- 否则会出现「直播主链路走 B 站解析器、切档却走通用解析器」这种错配。
local function resolver_plan_for_kind(kind)
    if kind == 'youtube-video' then
        local extra = js_runtime_args()
        if file_exists(youtube_cookie_path) then
            extra[#extra + 1] = '--cookie-file'
            extra[#extra + 1] = youtube_cookie_path
        end
        local proxy = detect_system_proxy()
        if proxy ~= '' then
            extra[#extra + 1] = '--proxy'
            extra[#extra + 1] = proxy
        end
        return youtube_resolver_path, extra
    end
    if kind == 'bilibili-video' or kind == 'bilibili-short' or kind == 'bilibili-live' then
        return bilibili_resolver_path, nil
    end
    return live_resolver_path, nil
end

-- 与 apply_candidate 同一套判断：这几个平台的签名 CDN 用的是 bundled OpenSSL
-- 拒绝的证书链，播放时本来就关掉了校验。预验证必须同样宽松——否则会把实际
-- 能播的线路判成不可用，那种故障比黑屏更难查。
local function candidate_is_insecure(platform, proxy)
    if platform == 'bilibili' or platform == 'douyu'
            or platform == 'huya' or platform == 'douyin' then
        return true
    end
    return platform == 'youtube' and proxy ~= ''
end

-- 同样是 apply_candidate 里的规则：只有 YouTube 允许走代理，其余平台把非本机
-- 代理清掉。验证请求必须走和播放完全一样的链路，否则验证的是另一条路。
local function candidate_proxy_for(platform, raw)
    local proxy = sanitize_http_proxy(raw)
    if platform ~= 'youtube' and proxy ~= ''
            and not proxy:match('^https?://127%.0%.0%.1:%d+$')
            and not proxy:match('^https?://localhost:%d+$')
            and not proxy:match('^https?://%[::1%]:%d+$') then
        return ''
    end
    return proxy
end

-- 请求放进临时文件而不是命令行：mpv 在 Windows 上的 subprocess 后端不支持
-- stdin_data（见 history-bookmark.lua 的注释），而签名 URL 不该出现在进程列表里。
local function write_probe_request(payload)
    switch_cleanup_temp()
    local folder = os.getenv('TEMP') or os.getenv('TMP') or '.'
    local pid = utils.getpid and utils.getpid() or 0
    local path = utils.join_path(folder,
        string.format('mpv-yaozhi-probe-%d-%d.json', pid, switch.ticket))
    local handle = io.open(path, 'wb')
    if not handle then return nil end
    handle:write(utils.format_json(payload))
    handle:close()
    switch.temp = path
    return path
end

local function fail_quality_switch(quality_id, reason)
    local label = quality_label_for(quality_id)
    cancel_quality_switch()
    msg.warn(string.format('[online-media] seamless switch to %s failed: %s', quality_id, reason))
    mp.osd_message('切换「' .. label .. '」失败（' .. reason .. '），当前线路继续播放', 5)
end

-- ===== 换流时「搬什么状态过去」：点播与直播是两套 =====
--
-- 两边共用的只有外壳（后台解析 → 逐条验证 → 通过才换流 → 失败原样不动、防竞态、
-- 取消）。而「换流时搬什么状态」「怎么算切完了」「URL 能活多久」必须分开实现：
--
--   点播：有稳定时间轴，可恢复播放位置与播放状态。换流时要搬运当前时间点、暂停
--         状态、倍速、音轨与字幕轨，否则换个清晰度会从头播 / 音轨跳回默认。
--   直播：**没有可恢复的位置**。新线路有自己的 live edge，拿旧时间戳去 seek 只会
--         倒退，或者让新线路为了追时间戳额外加大缓冲。所以一个 position 都不搬。
--
-- 也不能按平台名去猜：B站视频与 B站直播共用同一个解析器但换流语义完全不同，
-- 虎牙 / 斗鱼 / 抖音的 CDN 与 token 行为也各不相同，所以判定一律挂在
-- content_type / kind 上，不挂在平台名上。

-- 定性走的是已有的权威判据 state_is_live_context()，不自己另造一套：它已经把
-- 虎牙 / 斗鱼 / 抖音这些 live-only 平台、`*-live` 的 kind 和 live 系 URL 都算进去了。
-- 判错的代价是不对称的——把直播当成点播会去 seek 一个别家 CDN 的时间戳（倒退、
-- 拉高延迟），把点播当成直播只是丢掉播放位置。所以拿不准时倒向直播那一侧。
local function switch_targets_vod()
    if state_is_live_context() then return false end
    return tostring(state.content_type or ''):lower() == 'video'
end

-- 点播的播放入参。音轨 / 字幕轨按原生值取再 tostring：这个属性可能是
-- 'auto' / 'no' / 数字，用 get_property_number 会把「自动」错当成 0 号轨。
local function capture_vod_playback_state()
    local function track(name)
        local value = mp.get_property_native(name)
        if value == nil then return '' end
        return tostring(value)
    end
    return {
        resume_time = tonumber(mp.get_property_number('time-pos', 0)) or 0,
        resume_paused = mp.get_property_bool('pause', false) == true,
        resume_speed = tonumber(mp.get_property_number('speed', 1)) or 0,
        resume_aid = track('aid'),
        resume_sid = track('sid'),
    }
end

-- URL 生命周期也不一样。直播的签名地址（尤其虎牙 / 抖音的 CDN token）有效期短，
-- 而预验证本身就在消耗它的寿命：探测多花一秒，换流后就多一分「刚验证过的线路
-- 已经过期」的风险。所以直播用更紧的探测窗口；点播的地址活得久，可以放宽。
local function probe_timeout_for_target()
    if switch_targets_vod() then return o.quality_probe_timeout end
    return math.max(2, math.min(o.quality_probe_timeout, 4))
end

-- 斗鱼的签名媒体 URL 是一次性的：被连接过一次之后，第二次连接会被 CDN 吐掉一小段
-- 缓冲后立刻结束——与间隔无关（实测 0 / 2 / 5 秒一样），只读 64 KB 就足以触发。
-- 而切档路径正是「用这条 URL 验证 → mpv 再用同一条 URL 播放」，所以新流必然在
-- 约 150 ms 内被结束（日志里三次 lavf EOF reached 都落在 loadfile 打断播放之后，
-- 而 mpv 已 idle 时的四次 loadfile 全部稳定）。改成 HEAD 后验证不再建立数据会话，
-- URL 留到播放那一刻才第一次被连接。
-- 代价：HEAD 只能确认边缘节点可达（TLS / DNS / 超时认得出），认不出「有响应但不
-- 吐流」的线路——那类线路由解析器筛掉，这里不为它牺牲上面那条。
local function probe_method_for(descriptor)
    local platform = type(descriptor) == 'table' and tostring(descriptor.platform or '')
        or ''
    if platform == '' then platform = state.platform end
    return platform == 'douyu' and 'HEAD' or 'GET'
end

-- 验证通过才换流。这里不是「直接 loadfile 再解析一遍」，而是把已经验证过的
-- descriptor 塞进 pending_open，让 on_load 认出来直接应用，跳过整个解析等待。
local function perform_quality_switch(descriptor, index, quality_id)
    local reload_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
    if reload_url == '' then
        cancel_quality_switch()
        return
    end

    local pending = {
        url = reload_url,
        attempt = 0,
        quality_id = quality_id,
        preload_descriptor = descriptor,
        preload_candidate = index,
        -- 供切换完成判定区分「首次起播」与「切档切过来的」。
        switched_from_quality = state.quality_id,
    }

    local label = quality_label_for(quality_id)
    if switch_targets_vod() then
        -- 点播：位置与播放状态原样搬过去，由 on_load 用 file-local-options 设进
        -- 新文件——等播起来再调音轨会先响一下默认轨。
        for key, value in pairs(capture_vod_playback_state()) do pending[key] = value end
    else
        -- 直播：一个 position 都不带，让它从自己的 live edge 起播。若用户此前把
        -- 直播暂停了，切档后继续播——恢复暂停会让新流迟迟不建缓冲，画面反而更慢。
        pending.resume_time = 0
        pending.resume_paused = false
        pending.force_play = true
    end

    -- 用户点选的那一档优先：断流预警准备的是「上一次那条流的下一份」，这里作废。
    live_preload = nil
    pending_open = pending
    -- 事务到此结束：ticket 前进让残留回调失效，临时请求文件删掉。
    cancel_quality_switch()
    mp.osd_message(switch_targets_vod()
        and ('切换到「' .. label .. '」，保持当前进度')
        or ('切换到「' .. label .. '」'), 3)
    mp.commandv('loadfile', reload_url, 'replace')
end

local function probe_quality_candidates(descriptor, picks, position, ticket, quality_id)
    if switch.ticket ~= ticket then return end
    if not file_exists(python_path) or not file_exists(probe_path) then
        fail_quality_switch(quality_id, '缺少 Python 运行时或验证脚本')
        return
    end
    local pick = picks[position]
    if not pick then
        fail_quality_switch(quality_id, '该档位的线路都没能通过验证')
        return
    end
    local candidate = pick.candidate
    local proxy = candidate_proxy_for(state.platform, candidate.http_proxy)
    local payload = {
        url = tostring(candidate.url or ''),
        headers = candidate.headers or {},
        proxy = proxy,
        insecure = candidate_is_insecure(state.platform, proxy),
        timeout = probe_timeout_for_target(),
        bytes = o.quality_probe_bytes,
        method = probe_method_for(descriptor),
    }
    if type(candidate.audio_url) == 'string' and candidate.audio_url ~= '' then
        payload.audio_url = candidate.audio_url
        payload.audio_headers = candidate.audio_headers or candidate.headers or {}
    end
    local request_path = write_probe_request(payload)
    if not request_path then
        fail_quality_switch(quality_id, '无法创建验证请求文件')
        return
    end
    switch.request = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {python_path, probe_path, '--request', request_path},
    }, function(_success, result)
        if switch.ticket ~= ticket then return end
        switch.request = nil
        switch_cleanup_temp()
        local probe = result and utils.parse_json(result.stdout or '') or nil
        if type(probe) == 'table' and probe.ok == true then
            perform_quality_switch(descriptor, pick.index, quality_id)
            return
        end
        local reason = type(probe) == 'table' and tostring(probe.reason or '未通过') or '验证进程失败'
        -- 只记主机名。签名地址不落日志。
        msg.warn(string.format('[online-media] quality candidate %d rejected (%s, host=%s)',
            pick.index, reason,
            type(probe) == 'table' and tostring(probe.host or '') or ''))
        probe_quality_candidates(descriptor, picks, position + 1, ticket, quality_id)
    end)
end

local function begin_quality_switch(quality_id)
    if not state.matched or state.kind == '' then return end
    if quality_id == '' or quality_id == state.quality_id then return end
    -- 同一档正在准备中就不要再起一次解析（用户连点同一个档位很常见）。
    if switch.phase ~= 'idle' and switch.quality_id == quality_id then
        mp.osd_message('「' .. quality_label_for(quality_id) .. '」正在准备中…', 2)
        return
    end

    local selectable = false
    for _, quality in ipairs(state.quality_options or {}) do
        if tostring(quality.id or '') == quality_id then
            selectable = quality.selectable ~= false
            break
        end
    end
    if not selectable then
        msg.warn('[online-media] rejected unknown quality id')
        return
    end

    if not file_exists(python_path) then
        mp.osd_message('切换清晰度不可用：未找到 Python 运行时（见 script-opts/online_media.conf）', 4)
        msg.warn('[online-media] quality switch skipped: python runtime not found')
        return
    end

    cancel_quality_switch()
    local ticket = switch.ticket
    switch.quality_id = quality_id
    switch.phase = 'resolving'
    switch_publish()
    -- 记一行「这次按哪套策略走」。实测时能直接从日志确认媒体类型 / 平台识别对不对，
    -- 不用去猜黑屏那几秒到底进的是点播还是直播分支。--msg-level=online-media=verbose
    msg.verbose(string.format('[online-media] quality switch %s: kind=%s platform=%s strategy=%s',
        quality_id, state.kind, state.platform, switch_targets_vod() and 'vod' or 'live'))

    local resolver_path, extra_args = resolver_plan_for_kind(state.kind)
    local args = {
        python_path,
        resolver_path,
        '--kind', state.kind,
        '--url', state.canonical_url ~= '' and state.canonical_url or state.source_url,
        '--timeout', tostring(o.resolver_timeout),
        '--max-candidates', tostring(o.max_candidates),
        '--quality-id', quality_id,
    }
    for _, value in ipairs(extra_args or {}) do args[#args + 1] = value end
    local switch_cookie = account_cookie_file(state.kind)
    if switch_cookie then
        args[#args + 1] = '--cookie-file'
        args[#args + 1] = switch_cookie
    end

    switch.request = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(_success, result, error)
        if switch.ticket ~= ticket then return end
        switch.request = nil
        if switch.timer then
            switch.timer:kill()
            switch.timer = nil
        end

        local data = result and utils.parse_json(result.stdout or '') or nil
        if type(data) ~= 'table' or data.ok ~= true
                or type(data.candidates) ~= 'table' or #data.candidates == 0 then
            local user_message = type(data) == 'table' and tostring(data.user_message or '') or ''
            if user_message == '' then
                user_message = tostring(error or '解析失败')
            end
            fail_quality_switch(quality_id, user_message)
            return
        end

        -- 只在目标档位里挑线路：同一档可能有多台 CDN，逐条验证、用第一条通的。
        local picks = {}
        for index, candidate in ipairs(data.candidates) do
            if tostring(candidate.quality_id or '') == quality_id then
                picks[#picks + 1] = {index = index, candidate = candidate}
            end
        end
        if #picks == 0 then
            -- 精确匹配落空：斗鱼原画的档位 id 就是接口给的动态码率，同一场直播相邻
            -- 两次解析都会变（19153k → 4164k），点选时的 id 到切档时已经不存在了。
            -- 解析器知道这件事，会把旧 id 映射到本轮的新 id 并回在 preferred_quality
            -- 里——那是它实际采用的目标档位，比在这里自己猜（按顺序、按名字）可靠：
            -- 猜错就是静默换到别的画质，而「不允许为了切换稳定性静默降画质」。
            -- 字段缺失、或与旧 id 相同时维持原样报错，宁可不切。
            local effective = tostring(data.preferred_quality or '')
            if effective ~= '' and effective ~= quality_id then
                for index, candidate in ipairs(data.candidates) do
                    if tostring(candidate.quality_id or '') == effective then
                        picks[#picks + 1] = {index = index, candidate = candidate}
                    end
                end
            end
        end
        if #picks == 0 then
            -- 解析器没能给出该档线路（例如平台刚把它摘了）。这时退回候选 1 就是
            -- 静默换到别的画质，而「不允许为了切换稳定性静默降画质」，所以说清楚。
            fail_quality_switch(quality_id, '该档位当前没有可用线路')
            return
        end
        switch.phase = 'probing'
        switch_publish()
        probe_quality_candidates(data, picks, 1, ticket, quality_id)
    end)

    switch.timer = mp.add_timeout(math.max(5, o.resolver_timeout + 4), function()
        switch.timer = nil
        if switch.ticket ~= ticket then return end
        fail_quality_switch(quality_id, '解析超时')
    end)
end

local function resolve_platform(kind, hook, purpose, resolver_path, fallback_to_ytdl, extra_args)
    resolver_path = resolver_path or live_resolver_path
    if not file_exists(python_path) then
        stop_failed_load('未找到 Python 运行时：在线解析不可用（可用 script-opts/online_media.conf 的 python_runtime 指定）')
        return
    end
    if not file_exists(resolver_path) then
        stop_failed_load('解析器脚本缺失：' .. tostring(resolver_path) .. '（请重新解压完整播放器）')
        return
    end

    safe_abort_request()
    local my_generation = generation
    local continued = false
    local function continue_hook()
        if continued then return end
        continued = true
        hook:cont()
    end

    hook:defer()
    state.status = purpose == 'reconnect' and 'reconnecting' or 'resolving'
    publish()
    local media_label = state.content_type == 'live' and '直播' or '视频'
    mp.osd_message('正在解析' .. platform_label() .. media_label .. '…  Esc 取消', 30)

    cancel_binding = true
    mp.add_forced_key_binding('ESC', 'online-media-cancel', function()
        safe_abort_request()
        state.status = 'canceled'
        publish()
        mp.osd_message('已取消' .. media_label .. '连接', 2)
        mp.set_property('stream-open-filename', 'memory://')
        continue_hook()
        mp.add_timeout(0, function() mp.commandv('stop') end)
    end)

    local args = {
        python_path,
        resolver_path,
        '--kind', kind,
        '--url', state.canonical_url,
        '--timeout', tostring(o.resolver_timeout),
        '--max-candidates', tostring(o.max_candidates),
    }
    if state.requested_quality ~= '' then
        args[#args + 1] = '--quality-id'
        args[#args + 1] = state.requested_quality
    end
    for _, value in ipairs(extra_args or {}) do
        args[#args + 1] = value
    end
    -- B 站直播清晰度同样与账号绑定：接口只对已识别身份的请求返回原画，匿名会被
    -- 压到超清。VOD 和直播两条解析器都必须拿到同一个 Cookie 文件。斗鱼同理
    -- （匿名只给蓝光4M），文件不存在就还是匿名解析。
    local account_cookie = account_cookie_file(kind)
    if account_cookie then
        args[#args + 1] = '--cookie-file'
        args[#args + 1] = account_cookie
    end

    resolve_request = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(_success, result, error)
        if my_generation ~= generation or continued then return end
        clear_resolve_handles()

        local data = result and utils.parse_json(result.stdout or '') or nil
        if type(data) == 'table' and data.ok == true and apply_descriptor(data) then
            if fallback_to_ytdl == 'youtube' and data.account_status then
                mp.commandv('script-message-to', 'youtube_account', 'validation-result', data.account_status)
            end
            msg.info(string.format('[online-media] %s %s resolved by %s (%d candidates)',
                state.platform, state.content_type, state.resolver, #state.candidates))
            continue_hook()
            return
        end

        local code = type(data) == 'table' and tostring(data.code or 'resolve_failed') or 'resolver_process_failed'
        local user_message = type(data) == 'table' and tostring(data.user_message or '') or ''
        if user_message == '' then user_message = '在线解析失败，请检查网络后重试' end
        local detail = type(data) == 'table' and tostring(data.detail or '')
            or tostring(error or (result and result.error_string) or '')
        detail = detail:gsub('https?://[^%s]+', '<redacted-url>'):sub(1, 600)
        msg.error(string.format('[online-media] %s: %s%s', code,
            user_message, detail ~= '' and (' · ' .. detail) or ''))
        if fallback_to_ytdl == 'youtube' then
            if type(data) == 'table' and data.account_status then
                mp.commandv('script-message-to', 'youtube_account', 'validation-result', data.account_status)
            end
            if code == 'login_required' or code == 'verification_required' or code == 'auth_unavailable' then
                -- Anonymous + cookie extraction already failed, and the helper
                -- performed its bounded refresh if the server proved expiry.
                -- Repeating the identical cookie through ytdl_hook cannot help.
                state.failure_kind = code
                stop_failed_load(user_message)
                continue_hook()
                return
            end
        end
        if fallback_to_ytdl then
            state.resolver = 'yt-dlp-hook'
            state.status = 'opening'
            if fallback_to_ytdl == 'youtube' then
                configure_youtube_ytdl()
            else
                configure_bilibili_ytdl()
            end
            mp.set_property('stream-open-filename', 'ytdl://' .. state.source_url)
            publish()
            mp.osd_message(fallback_to_ytdl == 'youtube'
                and '正在切换 YouTube 原生兼容解析模式…'
                or '正在切换 B站兼容解析模式…', 4)
            continue_hook()
            return
        end
        stop_failed_load(user_message)
        continue_hook()
    end)

    -- A YouTube auth failure may require server validation, one silent profile
    -- export and one retry. Keep that transaction bounded without aborting it
    -- at the old single-attempt deadline and retrying the same cookie in a hook.
    local resolve_budget = fallback_to_ytdl == 'youtube'
        and math.min(120, o.resolver_timeout * 4 + 30) or o.resolver_timeout + 4
    resolve_timer = mp.add_timeout(math.max(5, resolve_budget), function()
        if my_generation ~= generation or continued then return end
        safe_abort_request()
        msg.error('[online-media] resolver_timeout')
        if fallback_to_ytdl == 'youtube' then
            state.failure_kind = 'network'
            stop_failed_load('YouTube 解析或账号验证超时，请检查代理线路后重试')
            continue_hook()
            return
        end
        if fallback_to_ytdl then
            state.resolver = 'yt-dlp-hook'
            state.status = 'opening'
            if fallback_to_ytdl == 'youtube' then
                configure_youtube_ytdl()
            else
                configure_bilibili_ytdl()
            end
            mp.set_property('stream-open-filename', 'ytdl://' .. state.source_url)
            publish()
            mp.osd_message(fallback_to_ytdl == 'youtube'
                and 'YouTube 清晰度解析超时，正在切换兼容模式…'
                or 'B站异步解析超时，正在切换兼容模式…', 5)
            continue_hook()
        else
            stop_failed_load(media_label .. '连接超时，请检查网络后重试')
            continue_hook()
        end
    end)
end

mp.register_event('start-file', function()
    -- Cancel a deferred user-Stop cleanup before resetting for the new item.
    -- playlist-next/prev can end the old item with reason=stop too; start-file
    -- is the authoritative proof that playback is continuing instead of idling.
    stop_cleanup_ticket = stop_cleanup_ticket + 1
    stop_live_danmaku(true)
    live_danmaku_started_url = ''
    live_danmaku_startup_retry_used = false
    generation = generation + 1
    safe_abort_request()
    -- 新的播放事务开始了，后台正在准备的切档已经没有意义（用户换了别的视频、
    -- 断流重连、或刚刚那次切档自己触发的 loadfile）。
    cancel_quality_switch()
    reconnect_ticket = reconnect_ticket + 1
    if reconnect_timer then
        reconnect_timer:kill()
        reconnect_timer = nil
    end
    -- 新的播放事务开始，上一次连接攒的「播够久就算成功」计时到此为止。
    if stability_timer then
        stability_timer:kill()
        stability_timer = nil
    end
    if live_alive_timer then
        live_alive_timer:kill()
        live_alive_timer = nil
    end
    -- 断流预警是为上一条流准备的，换流之后作废（真正要用的那一刻在 end-file 里就已经
    -- 取走了，走到这里说明这次 start-file 与它无关）。
    live_preload = nil

    local path = mp.get_property('path', '')
    -- ytdl_hook may internally reopen our explicit pseudo URL after extraction
    -- fails. Keep the owning YouTube state long enough to publish a useful
    -- authentication error instead of resetting to an unrelated raw URL.
    if state.matched and state.platform == 'youtube'
            and path == 'ytdl://' .. state.source_url then
        publish()
        return
    end
    -- mpv 抢在我们的重连延迟之前自己前进了（见 reconnect_pending 的说明）。这一次
    -- start-file 本质上就是「重连提前发生」，把挂起的重连意图提升上来，它才拿得到
    -- 档位与失败节点。定时器不用管：上面已经 kill 过，ticket 也前进过了。
    if pending_open == nil and reconnect_pending and reconnect_pending.url == path then
        pending_open = reconnect_pending
    end
    reconnect_pending = nil

    local attempt = 0
    local pending = nil
    if pending_open and pending_open.url == path then
        pending = pending_open
        attempt = pending_open.attempt or 0
    end
    pending_open = nil
    reset_state(attempt, pending)
end)

mp.add_hook('on_load', 5, function(hook)
    if not o.enabled then return end
    local path = mp.get_property('path', '')
    local route = router.classify(path)
    if not route then return end

    state.matched = true
    state.source_url = path
    state.canonical_url = path
    state.platform = route.platform
    state.kind = route.kind
    state.content_type = route.content_type
    state.status = 'resolving'
    -- 番剧 / 剧集：播放列表条目存的就是每集的页面地址，先记下这一集的身份。ss 链接
    -- 这里认不出来（它是季地址），等解析出的规范地址回来再补（见 apply_descriptor）。
    state.bangumi_ep = bangumi_ep_id(path)
    publish()

    if route.kind == 'youtube-video' and state.resume_time == 0 then
        local timestamp = path:match('[?&]t=([^&#]+)') or path:match('[?&]start=([^&#]+)')
        if timestamp then
            state.resume_time = tonumber(timestamp)
                or ((tonumber(timestamp:match('(%d+)h')) or 0) * 3600
                    + (tonumber(timestamp:match('(%d+)m')) or 0) * 60
                    + (tonumber(timestamp:match('(%d+)s')) or 0))
        end
    end

    -- 弹幕与解析并行启动：等画面出来再启动，会把浏览器启动时间整段加进
    -- 用户等待。分享短链会被弹幕脚本拒绝（它只认标准直播间地址），那种
    -- 情形由 file-loaded 的二次启动用解析出的规范地址补上。
    if state.content_type == 'live' then start_live_danmaku() end

    -- 点播的时间轴与轨道选择要在**文件加载之前**设成 file-local-options：等播起来
    -- 再调的话，位置已经从头播了几秒、音轨也会先响一下默认轨。轨道 id 在新线路里
    -- 不存在时 mpv 会忽略这个设置并退回默认轨——这正是我们要的降级行为。
    -- 直播走不到这里：它没有可恢复的位置，也没有跨线路通用的轨道 id。
    if state.content_type == 'video' then
        if state.resume_time > 0 then
            mp.set_property('file-local-options/start', tostring(state.resume_time))
        end
        if state.resume_aid ~= '' then
            mp.set_property('file-local-options/aid', state.resume_aid)
        end
        if state.resume_sid ~= '' then
            mp.set_property('file-local-options/sid', state.resume_sid)
        end
    end

    -- 无缝切档已经在后台解析并验证过线路：直接应用，省掉整段解析等待。
    -- 放在 retry_descriptor 之前——预解析的结果比 YouTube 的重试路径更具体。
    if state.preload_descriptor then
        local descriptor, index = state.preload_descriptor, state.preload_candidate
        state.preload_descriptor, state.preload_candidate = nil, nil
        -- 有明确候选号（无缝切档挑好的那条）就照它来。没有候选号的是断流预警的那份：
        -- apply_descriptor 内部已经按「避开刚断掉的那台主机」挑过一轮，不能再覆盖回
        -- 候选 1——那会正好回到刚刚断线的节点上重连。
        if index and apply_descriptor(descriptor) and apply_candidate(index) then return end
        if not index and apply_descriptor(descriptor) then return end
        msg.warn('[online-media] preloaded quality candidate unusable; resolving normally')
    end

    if state.platform == 'youtube' and state.retry_descriptor then
        local descriptor, index = state.retry_descriptor, state.retry_candidate
        state.retry_descriptor, state.retry_candidate = nil, nil
        if apply_descriptor(descriptor) and apply_candidate(index or 1) then return end
    end

    if route.kind == 'youtube-video' then
        local missing = youtube_missing_component()
        if missing or not file_exists(youtube_resolver_path) then
            state.failure_kind = 'js_runtime'
            local detail = missing
                or ('resolve_youtube.py（' .. tostring(youtube_resolver_path) .. '）')
            stop_failed_load('YouTube 解析组件缺失：' .. detail
                .. '；可在 script-opts/online_media.conf 指定路径，或安装到 PATH 后重试')
            return
        end
        state.resolver = 'yt-dlp-direct'
        local extra_args = js_runtime_args()
        if file_exists(youtube_cookie_path) then
            extra_args[#extra_args + 1] = '--cookie-file'
            extra_args[#extra_args + 1] = youtube_cookie_path
        end
        local proxy = detect_system_proxy()
        if proxy ~= '' then
            extra_args[#extra_args + 1] = '--proxy'
            extra_args[#extra_args + 1] = proxy
        end
        configure_youtube_playback()
        publish()
        resolve_platform(route.kind, hook, 'initial', youtube_resolver_path, 'youtube', extra_args)
        return
    end

    if route.kind == 'bilibili-video' or route.kind == 'bilibili-short'
            or route.kind == 'bilibili-live' then
        state.resolver = 'yt-dlp'
        if route.content_type == 'live' then configure_live_playback() end
        publish()
        resolve_platform(route.kind, hook, 'initial', bilibili_resolver_path, true)
        return
    end

    configure_live_playback()
    resolve_platform(route.kind, hook, 'initial', live_resolver_path, false)
end)

mp.add_hook('on_load_fail', 5, function(hook)
    if not state.matched then return end

    if state.platform == 'youtube' and state.candidates and state.candidate_index > 0 then
        local index = state.candidate_index
        local attempts = state.youtube_media_retries[index] or 0
        -- A valid signed URL can receive a transient 403 and succeed on a new
        -- connection. Retry the exact quality before moving to a lower tier.
        if attempts < 1 and mp.get_time() - (state.youtube_media_started or mp.get_time()) < 45 then
            state.youtube_media_retries[index] = attempts + 1
            hook:defer()
            local serial = generation
            mp.add_timeout(0.35, function()
                if serial == generation then
                    msg.warn('[online-media] retrying YouTube media connection once')
                    apply_candidate(index)
                end
                hook:cont()
            end)
            return
        end
    end

    if state.candidates
            and state.candidate_index < #state.candidates then
        local next_index = state.candidate_index + 1
        msg.warn(string.format('[online-media] opening fallback candidate %d/%d',
            next_index, #state.candidates))
        local media_label = state.content_type == 'live' and '直播' or '视频'
        mp.osd_message('当前' .. media_label .. '线路不可用，正在切换备用线路…', 4)
        apply_candidate(next_index)
        return
    end

    if state.kind == 'bilibili-live' and state.resolver ~= 'streamlink' then
        state.streamlink_refreshes = state.streamlink_refreshes + 1
        -- 这行日志是判断「兜底路径多久被用到一次」的依据，所以除了触发本身，还
        -- 要写清是哪条线路、哪个 CDN 主机没打开：B 站直播的首条线路失败时走的
        -- 就是这里，事后翻日志能直接数出频率和原因，不用再复现。
        -- 只写主机名，不写完整地址——地址里带鉴权 token，日志不该留。
        local failed = state.candidates and state.candidates[state.candidate_index]
        msg.warn(string.format(
            '[online-media] bilibili-live initial route failed '
            .. '(quality=%s, host=%s, routes=%d); trying Streamlink fallback',
            failed and failed.quality or 'unknown',
            tostring(failed and failed.url or ''):match('^https?://([^/]+)') or 'unknown',
            state.candidates and #state.candidates or 0))
        resolve_platform('bilibili-live', hook, 'fallback', live_resolver_path, false)
        return
    end

    if state.content_type == 'video' then
        if state.platform == 'youtube' and state.candidates
                and state.youtube_media_refreshes < 1 then
            state.youtube_media_refreshes = state.youtube_media_refreshes + 1
            state.youtube_media_retries = {}
            local extra = js_runtime_args()
            if file_exists(youtube_cookie_path) then
                extra[#extra + 1] = '--cookie-file'; extra[#extra + 1] = youtube_cookie_path
            end
            local proxy = detect_system_proxy()
            if proxy ~= '' then extra[#extra + 1] = '--proxy'; extra[#extra + 1] = proxy end
            msg.warn('[online-media] refreshing exhausted YouTube media descriptors once')
            resolve_platform('youtube-video', hook, 'fallback', youtube_resolver_path, 'youtube', extra)
            return
        end
        state.status = 'error'
        publish()
        if state.platform == 'youtube' then
            if state.failure_kind == '' then state.failure_kind = 'generic' end
            publish()
            mp.osd_message(youtube_failure_message(), 9)
        else
            -- 番剧：说清是哪一集失败。这里失败之后 mpv 会自己跳过这一条、继续播下一集
            -- （实测播放列表条目加载失败会自动前进），所以整季列表不受影响。
            local label = bangumi.labels[state.bangumi_ep]
            mp.osd_message(label
                and (label .. ' 解析失败：可能需要登录 Cookie，或这一集暂时不可播')
                or 'B站视频解析失败：可能需要登录 Cookie，或平台暂时限制访问', 7)
        end
    elseif state.content_type == 'live' then
        state.status = 'error'
        publish()
        mp.osd_message('直播线路已失效，请稍后重试', 6)
    end
end)

-- ===== 断流预警：在缓存播完之前，把下一条线路先解析好 =====
--
-- 见 live_preload 的说明。这里只做两件事：发现「服务器已经结束响应」，起一次静默
-- 解析；把结果留着，等 end-file 用它顶掉那 2 秒延迟 + 2.4 秒解析。
local function live_preload_is_usable(quality_id)
    if type(live_preload) ~= 'table' then return false end
    if live_preload.url ~= state.canonical_url then return false end
    if live_preload.quality_id ~= quality_id then return false end
    if mp.get_time() - live_preload.at > LIVE_PRELOAD_MAX_AGE then return false end
    return true
end

local function start_live_preload()
    if not file_exists(python_path) or not file_exists(live_resolver_path) then return end
    local resolver_path, extra_args = resolver_plan_for_kind(state.kind)
    if not file_exists(resolver_path) then return end
    local args = {
        python_path,
        resolver_path,
        '--kind', state.kind,
        '--url', state.canonical_url,
        '--timeout', tostring(o.resolver_timeout),
        '--max-candidates', tostring(o.max_candidates),
    }
    -- 参数必须和主解析一模一样：少一个档位就解析成别的画质，少一个 Cookie 就可能
    -- 从原画掉到匿名档（B 站直播与斗鱼都这样），预解析反而会把用户降级。
    if state.quality_id ~= '' then
        args[#args + 1] = '--quality-id'
        args[#args + 1] = state.quality_id
    end
    for _, value in ipairs(extra_args or {}) do args[#args + 1] = value end
    local account_cookie = account_cookie_file(state.kind)
    if account_cookie then
        args[#args + 1] = '--cookie-file'
        args[#args + 1] = account_cookie
    end

    local url, quality, my_generation = state.canonical_url, state.quality_id, generation
    live_preload = nil
    live_preload_request = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(_success, result, _error)
        live_preload_request = nil
        -- 新事务已经开始（用户换了流、切了档、重连已经跑起来了）：这份结果没有主人。
        if my_generation ~= generation or state.canonical_url ~= url then return end
        local data = result and utils.parse_json(result.stdout or '') or nil
        if type(data) ~= 'table' or data.ok ~= true
                or type(data.candidates) ~= 'table' or #data.candidates == 0 then
            msg.warn('[online-media] live preload resolve failed; the cut will resolve normally')
            return
        end
        live_preload = {descriptor = data, url = url, quality_id = quality, at = mp.get_time()}
        msg.info(string.format(
            '[online-media] live preload ready (%d candidates) while %s keeps playing from cache',
            #data.candidates, tostring(state.quality_id)))
    end)
end

-- 服务器结束响应那一刻 demuxer-cache-state 的 eof 就翻真，而画面还在播缓存里剩下的
-- 那几秒——这就是提前量的来源。正在切档 / 正在重连时一律不掺和：那两条路各自会解析
-- 自己需要的线路。
mp.add_periodic_timer(0.25, function()
    if not o.enabled or not state.matched or state.content_type ~= 'live' then return end
    if not state.file_loaded or pending_open or reconnect_pending then return end
    if switch.phase ~= 'idle' or live_preload_request then return end
    if mp.get_property_bool('idle-active', false) then return end
    -- 暂停时缓存不会排空，提前量不存在；这次断流交给 end-file 那条路照旧处理。
    if mp.get_property_bool('pause', false) then return end
    local cache = mp.get_property_native('demuxer-cache-state')
    if type(cache) ~= 'table' or cache.eof ~= true then return end
    if live_preload_is_usable(state.quality_id) then return end
    start_live_preload()
end)

mp.register_event('file-loaded', function()
    if not state.matched then return end
    state.file_loaded = true
    state.status = 'playing'
    state.failure_kind = ''
    if state.canonical_url == '' then state.canonical_url = state.source_url end
    if state.display_title ~= '' then
        mp.set_property('force-media-title', state.display_title)
        remember_playlist_title(state.display_title)
    end
    -- 番剧 / 剧集：把整季正片摆进播放列表，并且让正在播的这一集正好是它那一行。
    -- 已齐全时是空操作，所以每集都会经过这里也不会重复插。
    if state.bangumi_ep ~= '' then
        bangumi_ensure_playlist(bangumi_current_season(), state.bangumi_ep)
    end
    publish()
    if state.force_play then
        -- `pause` can survive a loadfile replacement. Reloading a live stream
        -- means returning to the live edge, so explicitly resume the new stream.
        mp.set_property_bool('pause', false)
    elseif state.resume_paused then
        mp.set_property_bool('pause', true)
    end
    -- 切换完成判定，两边判的不是一回事：
    --   点播：确认真的回到了切换前的时间点。差得远说明 file-local-options/start
    --         没生效，与其悄悄从头播，不如留一条能查的记录——不在这里补 seek，
    --         那会造成第二次跳动，比从头播更难受。
    --   直播：没有可比的位置。各 CDN 的直播时间戳基准本来就不同，拿旧值去比只会
    --         误报，这里只确认新线路已经起播（能走到 file-loaded 即已满足）。
    local switched = state.switched_from_quality
    if switched ~= '' then
        if switch_targets_vod() then
            if state.resume_time > 0 then
                local landed = mp.get_property_number('time-pos', 0) or 0
                if math.abs(landed - state.resume_time) > 5 then
                    msg.warn(string.format(
                        '[online-media] vod quality switch landed at %.1fs, expected ~%.1fs',
                        landed, state.resume_time))
                end
            end
            -- 倍速是全局属性，正常情况下 loadfile 不会重置它；显式恢复一次，
            -- 免得换了流之后忘了自己还在 1.5 倍速。
            if state.resume_speed > 0 then
                mp.set_property_number('speed', state.resume_speed)
            end
        end
        state.switched_from_quality = ''
    end
    local label = platform_label() .. (state.content_type == 'live' and '直播' or '视频')
    -- 切档成功时把结果说出来，否则用户只看到「已连接」，不确定刚才那一下切没切过去。
    mp.osd_message(switched ~= '' and (label .. '画质已切换') or (label .. '已连接'), 2)
    if state.content_type == 'live' then
        -- 断流计数只对「连续失败」有意义：重连后播满 live_reconnect_alive_secs 秒
        -- 就算这次恢复成功，配额归零。旧版拿 live_stable_reset_secs（60 秒）当这个
        -- 门槛，而虎牙的正常断流周期就有 20~130 秒——一串几十秒的断流会把 5 次配额
        -- 攒满，用户看到「自动重连已达上限」。秒断的地址播不满这个门槛，计数照常
        -- 累加，「最多 5 次」还是上界。
        if state.reconnect_attempt > 0 then
            if live_alive_timer then live_alive_timer:kill() end
            live_alive_timer = mp.add_timeout(o.live_reconnect_alive_secs, function()
                live_alive_timer = nil
                if not state.matched or state.content_type ~= 'live' then return end
                if mp.get_property_bool('idle-active', false) then return end
                state.reconnect_attempt = 0
                publish()
            end)
            -- 刚断掉的那台主机避开得更久：换主机是为了不回刚断的节点，跟「配额算不算
            -- 成功」是两件事，所以留在更长的门槛上。
            if stability_timer then stability_timer:kill() end
            stability_timer = mp.add_timeout(o.live_stable_reset_secs, function()
                stability_timer = nil
                if not state.matched or state.content_type ~= 'live' then return end
                if mp.get_property_bool('idle-active', false) then return end
                state.failed_host = ''
                state.failed_quality_id = ''
                publish()
            end)
        end
        ensure_live_danmaku_started()
    end
end)

mp.register_event('end-file', function(event)
    safe_abort_request()
    cancel_quality_switch()
    stop_live_danmaku(true)

    -- `reason=stop` only means playback was ended by a command; playlist-next /
    -- playlist-prev and shell-driven episode changes can use the same reason.
    -- Do not equate it with the user's Stop button.  Defer cleanup briefly and
    -- require mpv to have actually entered idle/start-page state.  Any following
    -- start-file increments the ticket above and cancels this cleanup.
    if event.reason == 'stop' and state.matched and state.file_loaded
            and not pending_open then
        stop_cleanup_ticket = stop_cleanup_ticket + 1
        local ticket = stop_cleanup_ticket
        local checks_left = 4
        local function cleanup_if_idle()
            if ticket ~= stop_cleanup_ticket or pending_open or not state.matched then return end
            if mp.get_property_bool('idle-active', false) then
                reset_state(0)
                return
            end
            checks_left = checks_left - 1
            if checks_left > 0 then mp.add_timeout(0.05, cleanup_if_idle) end
        end
        mp.add_timeout(0, cleanup_if_idle)
        return
    end

    if state.matched and state.platform == 'youtube' and event.reason == 'error' then
        -- mpv's on_load_fail hook runs only once per loadfile. A second media
        -- failure arrives here, so remaining candidates need an explicit new
        -- load transaction instead of an unreachable third hook invocation.
        if state.candidates and not state.file_loaded
                and mp.get_time() - (state.youtube_media_started or mp.get_time()) < 45 then
            local next_index = state.candidate_index + 1
            local descriptor
            if next_index <= #state.candidates then
                descriptor = {ok=true, platform=state.platform, content_type=state.content_type,
                    resolver=state.resolver, canonical_url=state.canonical_url,
                    title=state.display_title,
                    candidates=state.candidates, qualities=state.quality_options}
            elseif state.youtube_media_refreshes < 1 then
                state.youtube_media_refreshes = state.youtube_media_refreshes + 1
                state.youtube_media_retries = {}
            else
                next_index = nil
            end
            if descriptor or next_index then
                local serial, url = generation, state.source_url
                pending_open = {url=url, attempt=0, retry_descriptor=descriptor,
                    quality_id=state.requested_quality,
                    retry_candidate=next_index, youtube_media_retries=state.youtube_media_retries,
                    youtube_media_refreshes=state.youtube_media_refreshes,
                    youtube_media_started=state.youtube_media_started,
                    resume_time=state.resume_time, resume_paused=state.resume_paused}
                mp.add_timeout(0, function()
                    if generation == serial and pending_open and pending_open.url == url then
                        mp.commandv('loadfile', url, 'replace')
                    end
                end)
                return
            end
        end
        if state.status ~= 'error' then
            state.status = 'error'
            publish()
            if state.failure_kind == '' then state.failure_kind = 'generic' end
            publish()
            mp.osd_message(youtube_failure_message(), 9)
        end
        return
    end

    -- 番剧：这一集没能起来就被 mpv 跳过去了（实测：解析成功但线路全打不开时，
    -- on_load_fail 只会被调用一次，之后 mpv 直接前进到下一集，用户什么都看不到）。
    -- 说一声跳过了哪一集。status 已是 error 的说明 on_load_fail 已经提示过，不重复。
    if state.matched and state.bangumi_ep ~= '' and event.reason == 'error'
            and not state.file_loaded and state.status ~= 'error' then
        local label = bangumi.labels[state.bangumi_ep]
        if label then
            -- 只写 ep 号，不写地址（地址里带鉴权串，日志不留）。
            msg.warn(string.format('[online-media] bangumi episode skipped (ep=%s)',
                state.bangumi_ep))
            mp.osd_message(label .. ' 打不开，已跳到下一集', 6)
        end
    end

    if not state.matched or state.content_type ~= 'live' then return end

    local recoverable_live_end = event.reason == 'error' or event.reason == 'eof'
    if recoverable_live_end and state.file_loaded
            and state.reconnect_attempt < o.live_reconnect_attempts then
        local next_attempt = state.reconnect_attempt + 1
        -- 断流预警已经把下一条线路解析好了（见 live_preload）：这时延迟只剩「让 mpv
        -- 收拾完 end-file」的意义，不该再压 2 秒。没预警到才退回原来的退避。
        local preloaded = live_preload_is_usable(state.quality_id) and live_preload.descriptor or nil
        local delay = preloaded and 0.2 or (next_attempt == 1 and 2 or 5)
        local reload_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
        -- 记下刚刚断掉的那条线路：重新解析后换到同清晰度的另一台 CDN，避免每次都
        -- 回到刚断的节点再断一次。
        local failed = state.candidates and state.candidates[state.candidate_index]
        local failed_host = url_host(failed and failed.url)
        local failed_quality = tostring(failed and failed.quality_id or state.quality_id or '')
        local ticket = reconnect_ticket + 1
        reconnect_ticket = ticket
        state.status = 'reconnecting'
        publish()
        state.failure_kind = event.reason == 'eof' and 'live_stream_eof' or 'live_network_error'
        publish()
        mp.osd_message(preloaded
            and string.format('直播断流，正在自动恢复（%d/%d）',
                next_attempt, o.live_reconnect_attempts)
            or string.format('直播意外断流，%d 秒后自动恢复（%d/%d）',
                delay, next_attempt, o.live_reconnect_attempts), delay + 1)
        -- 重连意图在这里就挂上，而不是等下面的定时器：mpv 可能压根不等它。
        reconnect_pending = {url = reload_url, attempt = next_attempt, quality_id = state.quality_id,
            failed_host = failed_host, failed_quality_id = failed_quality,
            preload_descriptor = preloaded}
        live_preload = nil
        reconnect_timer = mp.add_timeout(delay, function()
            reconnect_timer = nil
            if reconnect_ticket ~= ticket then return end
            -- 用户在这段延迟里按了停止。断流之后 mpv 已经在 idle，此时 `stop` 只清空
            -- 播放列表、不产生 end-file，所以上面那个 stop_cleanup 分支接不到它——
            -- 只能到点了自己认出来。不认就会把用户刚停掉的直播重新拉起来。
            if (mp.get_property_number('playlist-count', 0) or 0) == 0 then
                reset_state(0)
                return
            end
            pending_open = reconnect_pending
            reconnect_pending = nil
            mp.commandv('loadfile', reload_url, 'replace')
        end)
        return
    end

    -- 走到这里只说明「重连次数用完了」，不说明主播下播。CDN 主动结束 FLV 响应和真的
    -- 下播在 mpv 侧长得一模一样（都是 EOF），唯一能分辨的是重新解析：真下播会在下一次
    -- 解析时拿到 offline_or_unavailable，由 resolve_platform 统一报「未开播/已结束」并
    -- 停播。所以这里只能如实说重连到上限，不能再断言「直播已结束」。
    if state.file_loaded and (event.reason == 'eof' or event.reason == 'error') then
        state.status = 'error'
        state.failure_kind = 'live_reconnect_exhausted'
        publish()
        mp.osd_message(string.format(
            '直播连续断流，自动重连已达上限（%d 次）；请重新打开该直播间', o.live_reconnect_attempts), 8)
    elseif event.reason == 'eof' then
        -- 没能播起来就 EOF：同样不能说是「已结束」，留给上面的重连上限提示或用户重载。
        state.status = 'error'
        state.failure_kind = 'live_stream_eof'
        publish()
    end
end)

mp.register_event('shutdown', function()
    cancel_quality_switch()
    stop_live_danmaku(true)
end)

mp.register_script_message('online-media-retry', function()
    if not state.matched or state.source_url == '' then return end
    pending_open = {url = state.source_url, attempt = 0, quality_id = state.quality_id}
    mp.commandv('loadfile', state.source_url, 'replace')
end)

mp.register_script_message('online-media-reload-live', function()
    -- Use the same authoritative capability predicate that is published to
    -- uosc. This prevents a visible reload row from becoming a no-op when a
    -- timing-sensitive content-type/kind property is briefly stale.
    if not state.matched or not state_is_live_context() then return end

    local reload_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
    if reload_url == '' then return end

    -- Cancel a queued automatic reconnect so a manual reload owns the next
    -- generation. Re-resolving the canonical room URL refreshes expiring
    -- signatures/CDN routes and naturally drops the old demux/cache backlog.
    reconnect_ticket = reconnect_ticket + 1
    if reconnect_timer then
        reconnect_timer:kill()
        reconnect_timer = nil
    end

    pending_open = {
        url = reload_url,
        attempt = 0,
        quality_id = state.quality_id,
        force_play = true,
    }
    mp.osd_message('正在重新加载直播…', 3)
    mp.commandv('loadfile', reload_url, 'replace')
end)

mp.register_script_message('online-media-select-quality', function(quality_id)
    quality_id = tostring(quality_id or '')
    if not state.matched or quality_id == '' or quality_id == state.quality_id then return end

    if o.seamless_quality_switch then
        begin_quality_switch(quality_id)
        return
    end

    -- 旧行为：先停当前流，再重新解析新档位。留着它只为出问题时能一键退回
    -- （online_media.conf 里 seamless_quality_switch=no），不是默认路径。
    local known = false
    for _, quality in ipairs(state.quality_options or {}) do
        if tostring(quality.id or '') == quality_id then
            known = quality.selectable ~= false
            break
        end
    end
    if not known then
        msg.warn('[online-media] rejected unknown quality id')
        return
    end

    local reload_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
    pending_open = {
        url = reload_url,
        attempt = 0,
        quality_id = quality_id,
        resume_time = state.content_type == 'video' and mp.get_property_number('time-pos', 0) or 0,
        resume_paused = state.content_type == 'video' and mp.get_property_bool('pause', false) or false,
    }
    mp.osd_message('正在切换清晰度…', 3)
    mp.commandv('loadfile', reload_url, 'replace')
end)

reset_state(0)
