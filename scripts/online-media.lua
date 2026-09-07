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
    live_reconnect_attempts = 2,
    live_danmaku = true,
    live_danmaku_poll = 0.35,
    live_danmaku_max_reconnects = 3,
    bilibili_cookie_file = '~~/online-media/bilibili-cookies.txt',
    youtube_cookie_file = '~~/online-media/youtube-cookies.txt',
    youtube_js_runtime = '~~/online-media/runtime/deno.exe',
    youtube_ytdl = '~~/online-media/yt-dlp.exe',
    youtube_resolver = '~~/online-media/resolve_youtube.py',
    bilibili_resolver = '~~/online-media/resolve_bilibili.py',
    live_resolver = '~~/online-media/resolve_live.py',
    bilibili_live_danmaku = '~~/online-media/bilibili_live_danmaku.py',
    platform_live_danmaku = '~~/online-media/platform_live_danmaku.py',
    python_runtime = '~~/online-media/runtime/python.exe',
}
options.read_options(o, 'online_media')

local python_path = mp.command_native({'expand-path', o.python_runtime})
local live_resolver_path = mp.command_native({'expand-path', o.live_resolver})
local bilibili_resolver_path = mp.command_native({'expand-path', o.bilibili_resolver})
local bilibili_live_danmaku_path = mp.command_native({'expand-path', o.bilibili_live_danmaku})
local platform_live_danmaku_path = mp.command_native({'expand-path', o.platform_live_danmaku})
local cookie_path = mp.command_native({'expand-path', o.bilibili_cookie_file})
local youtube_cookie_path = mp.command_native({'expand-path', o.youtube_cookie_file})
local youtube_js_path = mp.command_native({'expand-path', o.youtube_js_runtime})
local youtube_ytdl_path = mp.command_native({'expand-path', o.youtube_ytdl})
local youtube_resolver_path = mp.command_native({'expand-path', o.youtube_resolver})

local generation = 0
local resolve_request = nil
local resolve_timer = nil
local cancel_binding = false
local reconnect_timer = nil
local reconnect_ticket = 0
local pending_open = nil
local live_danmaku_request = nil
local live_danmaku_timer = nil
local live_danmaku_path = nil
local live_danmaku_offset = 0
local live_danmaku_partial = ''
local live_danmaku_ticket = 0

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
    streamlink_refreshes = 0,
    file_loaded = false,
    quality_id = '',
    quality_options = {},
    requested_quality = '',
    resume_time = 0,
    resume_paused = false,
    display_title = '',
    live_danmaku_status = 'off',
    failure_kind = '',
}

local function set_user_data(name, value)
    if type(value) == 'boolean' then
        mp.set_property_bool('user-data/online-media/' .. name, value)
    else
        mp.set_property_native('user-data/online-media/' .. name, tostring(value or ''))
    end
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
    set_user_data('quality-id', state.quality_id)
    set_user_data('quality-options-json', utils.format_json(state.quality_options or {}))
    set_user_data('candidate-count', state.candidates and #state.candidates or 0)
    set_user_data('reconnect-attempt', state.reconnect_attempt)
    set_user_data('live-danmaku-status', state.live_danmaku_status)
    set_user_data('failure-kind', state.failure_kind)
end

local function reset_state(reconnect_attempt, pending)
    pending = pending or {}
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
        streamlink_refreshes = 0,
        file_loaded = false,
        quality_id = '',
        quality_options = {},
        requested_quality = tostring(pending.quality_id or ''),
        resume_time = tonumber(pending.resume_time) or 0,
        resume_paused = pending.resume_paused == true,
        display_title = '',
        live_danmaku_status = 'off',
        failure_kind = '',
    }
    publish()
end

local function file_exists(path)
    if not path or path == '' then return false end
    local handle = io.open(path, 'rb')
    if not handle then return false end
    handle:close()
    return true
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
        pcall(mp.abort_async_command, live_danmaku_request)
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
    elseif state.platform == 'douyu' or state.platform == 'huya' then
        helper_path = platform_live_danmaku_path
        helper_args = {'--platform', state.platform}
    else
        set_live_danmaku_status('unsupported')
        return
    end
    if not file_exists(python_path) or not file_exists(helper_path) then
        set_live_danmaku_status('unavailable')
        msg.warn('[online-media] live danmaku helper is unavailable: ' .. state.platform)
        return
    end

    stop_live_danmaku(true)
    live_danmaku_ticket = live_danmaku_ticket + 1
    local ticket = live_danmaku_ticket
    -- Linux port: use the platform temp directory instead of the Windows TEMP
    -- convention (which would fall back to "." on Unix).
    local temp_root = os.getenv('TMPDIR') or os.getenv('TEMP')
        or os.getenv('TMP') or '/tmp'
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

    local args = {
        python_path,
        helper_path,
    }
    for _, value in ipairs(helper_args) do args[#args + 1] = value end
    args[#args + 1] = '--room-url'
    args[#args + 1] = state.canonical_url ~= '' and state.canonical_url or state.source_url
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
            set_live_danmaku_status(success and 'completed' or 'unavailable')
        end
        if not success then
            local detail = tostring(error or (result and result.error_string) or '')
            detail = detail:gsub('https?://[^%s]+', '<redacted-url>'):sub(1, 300)
            msg.warn('[online-media] live danmaku sidecar exited: ' .. detail)
        end
    end)
    live_danmaku_timer = mp.add_periodic_timer(
        math.max(0.15, math.min(1, tonumber(o.live_danmaku_poll) or 0.35)),
        poll_live_danmaku)
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
    mp.set_property('file-local-options/cache-secs', '20')
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
        ['js-runtimes'] = 'deno:' .. youtube_js_path,
    }
    if proxy ~= '' then
        raw.proxy = proxy
        mp.set_property('file-local-options/http-proxy', proxy)
    end
    if file_exists(youtube_cookie_path) then
        raw.cookies = youtube_cookie_path
    else
        -- Linux port: mpv.conf already reads Firefox cookies for yt-dlp; keep
        -- the same route here when no dedicated cookie file has been exported.
        raw['cookies-from-browser'] = 'firefox'
    end
    mp.set_property_native('file-local-options/ytdl-raw-options', raw)
end

local youtube_failure_priority = {
    generic = 0,
    network = 1,
    js_runtime = 2,
    login_required = 3,
}

local function record_youtube_failure(kind)
    if not state.matched or state.platform ~= 'youtube' then return end
    local current = youtube_failure_priority[state.failure_kind] or -1
    if (youtube_failure_priority[kind] or 0) > current then
        state.failure_kind = kind
    end
end

local function youtube_failure_message()
    if not file_exists(youtube_ytdl_path) or not file_exists(youtube_js_path) then
        return 'YouTube 解析组件不完整，请重新解压完整播放器'
    end
    if state.failure_kind == 'login_required' then
        return file_exists(youtube_cookie_path)
            and 'YouTube 登录已失效：请确认 Firefox 中的 YouTube 登录状态后重试'
            or 'YouTube 要求登录验证：请用 Firefox 登录 YouTube 后重试'
    end
    if state.failure_kind == 'js_runtime' then
        return 'YouTube JavaScript 验证失败，请更新完整播放器组件'
    end
    if state.failure_kind == 'network' then
        return 'YouTube 连接超时：请检查代理线路或出口质量后重试'
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
    state.quality_id = tostring(candidate.quality_id or '')
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
    -- Some signed Bilibili/Douyu/Huya media CDNs currently serve certificate
    -- chains/hostnames rejected by this bundled OpenSSL build. Scope the
    -- compatibility exception to the ephemeral media file returned by our
    -- allowlisted resolver. No Cookie header is forwarded here, while Python
    -- account/API requests continue to use normal certificate verification.
    local compatibility_media = state.platform == 'bilibili'
        or state.platform == 'douyu' or state.platform == 'huya'
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

local function remember_playlist_title(title)
    if title == '' then return end
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
    return apply_candidate(1)
end

local function stop_failed_load(message)
    state.status = 'error'
    publish()
    mp.osd_message(message, 6)
    mp.set_property('stream-open-filename', 'memory://')
    mp.add_timeout(0, function() mp.commandv('stop') end)
end

local function resolve_platform(kind, hook, purpose, resolver_path, fallback_to_ytdl, extra_args)
    resolver_path = resolver_path or live_resolver_path
    if not file_exists(python_path) or not file_exists(resolver_path) then
        stop_failed_load('在线解析组件不完整，请重新解压播放器')
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
    if resolver_path == bilibili_resolver_path and file_exists(cookie_path) then
        args[#args + 1] = '--cookie-file'
        args[#args + 1] = cookie_path
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

    resolve_timer = mp.add_timeout(math.max(5, o.resolver_timeout + 4), function()
        if my_generation ~= generation or continued then return end
        safe_abort_request()
        msg.error('[online-media] resolver_timeout')
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
    stop_live_danmaku(true)
    generation = generation + 1
    safe_abort_request()
    reconnect_ticket = reconnect_ticket + 1
    if reconnect_timer then
        reconnect_timer:kill()
        reconnect_timer = nil
    end

    local path = mp.get_property('path', '')
    -- ytdl_hook may internally reopen our explicit pseudo URL after extraction
    -- fails. Keep the owning YouTube state long enough to publish a useful
    -- authentication error instead of resetting to an unrelated raw URL.
    if state.matched and state.platform == 'youtube'
            and path == 'ytdl://' .. state.source_url then
        publish()
        return
    end
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
    publish()

    if state.content_type == 'video' and state.resume_time > 0 then
        mp.set_property_number('file-local-options/start', state.resume_time)
    end

    if route.kind == 'youtube-video' then
        if not file_exists(youtube_ytdl_path) or not file_exists(youtube_js_path)
                or not file_exists(youtube_resolver_path) then
            state.failure_kind = 'js_runtime'
            stop_failed_load('YouTube 解析组件不完整，请重新解压完整播放器')
            return
        end
        state.resolver = 'yt-dlp-direct'
        local extra_args = {'--js-runtime', youtube_js_path}
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
        msg.warn('[online-media] yt-dlp live open failed; trying Streamlink fallback')
        resolve_platform('bilibili-live', hook, 'fallback', live_resolver_path, false)
        return
    end

    if state.content_type == 'video' then
        state.status = 'error'
        publish()
        if state.platform == 'youtube' then
            if state.failure_kind == '' then state.failure_kind = 'generic' end
            publish()
            mp.osd_message(youtube_failure_message(), 9)
        else
            mp.osd_message('B站视频解析失败：可能需要登录 Cookie，或平台暂时限制访问', 7)
        end
    elseif state.content_type == 'live' then
        state.status = 'error'
        publish()
        mp.osd_message('直播线路已失效，请稍后重试', 6)
    end
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
    publish()
    if state.resume_paused then mp.set_property_bool('pause', true) end
    local label = platform_label() .. (state.content_type == 'live' and '直播' or '视频')
    mp.osd_message(label .. '已连接', 2)
    if state.content_type == 'live' then start_live_danmaku() end
end)

mp.register_event('end-file', function(event)
    safe_abort_request()
    stop_live_danmaku(true)
    if state.matched and state.platform == 'youtube' and event.reason == 'error' then
        if state.status ~= 'error' then
            state.status = 'error'
            publish()
            if state.failure_kind == '' then state.failure_kind = 'generic' end
            publish()
            mp.osd_message(youtube_failure_message(), 9)
        end
        return
    end
    if not state.matched or state.content_type ~= 'live' then return end

    local recoverable_live_end = event.reason == 'error' or event.reason == 'eof'
    if recoverable_live_end and state.file_loaded
            and state.reconnect_attempt < o.live_reconnect_attempts then
        local next_attempt = state.reconnect_attempt + 1
        local delay = next_attempt == 1 and 2 or 5
        local reload_url = state.canonical_url ~= '' and state.canonical_url or state.source_url
        local ticket = reconnect_ticket + 1
        reconnect_ticket = ticket
        state.status = 'reconnecting'
        publish()
        state.failure_kind = event.reason == 'eof' and 'live_stream_eof' or 'live_network_error'
        publish()
        mp.osd_message(string.format('直播意外断流，%d 秒后自动恢复（%d/%d）',
            delay, next_attempt, o.live_reconnect_attempts), delay + 1)
        reconnect_timer = mp.add_timeout(delay, function()
            reconnect_timer = nil
            if reconnect_ticket ~= ticket then return end
            pending_open = {url = reload_url, attempt = next_attempt, quality_id = state.quality_id}
            mp.commandv('loadfile', reload_url, 'replace')
        end)
        return
    end

    if event.reason == 'eof' then
        state.status = 'ended'
        state.failure_kind = 'live_stream_eof'
        publish()
        mp.osd_message('直播已结束', 4)
    elseif event.reason == 'error' and state.file_loaded then
        state.status = 'error'
        publish()
        mp.osd_message('直播连接已中断，自动重连次数已用完', 6)
    end
end)

mp.register_event('shutdown', function()
    stop_live_danmaku(true)
end)

mp.register_script_message('online-media-retry', function()
    if not state.matched or state.source_url == '' then return end
    pending_open = {url = state.source_url, attempt = 0, quality_id = state.quality_id}
    mp.commandv('loadfile', state.source_url, 'replace')
end)

mp.register_script_message('online-media-select-quality', function(quality_id)
    quality_id = tostring(quality_id or '')
    if not state.matched or quality_id == '' or quality_id == state.quality_id then return end

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
