local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
local Color = require("modules/color")
local msg = require('mp.msg')
local utils = require('mp.utils')
local SourceCache = require('modules/source_cache')

local user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

-- 将 URL 中的百分号编码解码为字符
local function normalize_url(path)
    if not path then return '' end
    return (path:gsub('%%(%x%x)', hex_to_char))
end

-- 从 URL 提取 vid
local function extract_vid(url)
    if not url then return nil end
    local vid = url:match('[?&]vid=([^&?#]+)')
    if not vid then
        local last = nil
        for seg in url:gmatch('/([^/?#]+)') do
            last = seg
        end
        if last then
            vid = last:match('([^%.]+)')
        end
    end
    return vid
end

-- 构造 curl 请求参数（通用）
local function build_curl_args(target_url)
    local args = {
        'curl',
        '-L',
        '-s',
        '--connect-timeout', '4',
        '--max-time', '20',
        '--fail',
        '--user-agent',
        user_agent,
        target_url,
    }

    if options.cookie_file and options.cookie_file ~= '' then
        table.insert(args, '-b')
        table.insert(args, mp.command_native({'expand-path', options.cookie_file}))
    end
    return args
end

-- 解析单个 segment 返回并把弹幕追加到 output_table
local function get_segment_start_ms(segment_url)
    local start_ms = tostring(segment_url or ''):match('/(%d+)/%d+/?$')
    return tonumber(start_ms) or 0
end

local function parse_segment_to_output(seg_json, output_table, segment_url)
    if not seg_json or not seg_json['barrage_list'] then return end
    local segment_start_ms = get_segment_start_ms(segment_url)
    for _, item in ipairs(seg_json['barrage_list']) do
        local raw_offset_ms = tonumber(item['time_offset']) or 0
        local time_ms = raw_offset_ms
        -- Tencent segment responses may use segment-relative offsets.
        -- Keep absolute offsets intact to avoid double-applying the segment start.
        if raw_offset_ms < segment_start_ms then
            time_ms = segment_start_ms + raw_offset_ms
        end
        local time = time_ms / 1000
        local color = ""
        local mode = 1

        local style = item['content_style']
        if style then
            if type(style) == 'string' then
                style = utils.parse_json(style)
            end
            if type(style) == 'table' then
                -- 将 hex 颜色字符串（"#FF1964" 或 "FF1964"）转为整数
                local function parse_color(col)
                    return Color.normalize(col, "hex")
                end
                -- 优先取渐变颜色数组的第一个颜色
                if style['gradient_colors'] and type(style['gradient_colors']) == 'table' and #style['gradient_colors'] > 0 then
                    local c = parse_color(style['gradient_colors'][1])
                    if c then color = c end
                elseif style['color'] then
                    local c = parse_color(style['color'])
                    if c then color = c end
                end
                -- 弹幕位置: 1=滚动 2=顶部 3=底部
                local pos = tonumber(style['position'])
                if pos == 2 then
                    mode = 5
                elseif pos == 3 then
                    mode = 4
                end
            end
        end

        table.insert(output_table, {time = time, color = Color.normalize(color),
            type = mode, size = 25, text = item['content'] or ''})
    end
end

-- 保存并加载最终弹幕 JSON
local function save_output_and_load(output_table, source_url)
    if #output_table == 0 then
        show_message(i18n.t('未获取到任何弹幕'), 3)
        return
    end
    -- Segment responses are already Lua tables. Encoding the whole episode
    -- and immediately parsing it again doubled allocation on first display.
    local source = DANMAKU.sources[source_url] or {from = 'user_custom'}
    source.data = output_table
    DANMAKU.sources[source_url] = source
    load_danmaku(true)
end

-- 为 腾讯视频 加载弹幕
function load_danmaku_for_tencent(path, callback)
    callback = callback or function() end
    local url = normalize_url(path)
    if not url or url == '' then
        url = mp.get_property('stream-open-filename', '')
    end

    local vid = extract_vid(url)
    if not vid then
        msg.error('无法从 URL 中解析 vid: ' .. tostring(url))
        callback(false)
        return
    end

    local cached_path = SourceCache.path('tencent', vid)
    local cached = SourceCache.read(cached_path, vid)
    if cached then
        msg.info('复用本集完整弹幕缓存')
        save_output_and_load(cached, url)
        callback(true)
        return
    end

    local api_base = 'https://dm.video.qq.com/barrage/base/' .. vid
    local api_segment_base = 'https://dm.video.qq.com/barrage/segment/' .. vid .. '/'

    local base_args = build_curl_args(api_base)

    call_cmd_async(base_args, function(err, out)
        if err then
            msg.error('请求腾讯弹幕 base 失败: ' .. tostring(err))
            callback(false)
            return
        end

        local base_json = utils.parse_json(out)
        if not base_json or not base_json['segment_index'] then
            show_message(i18n.t('好像没有弹幕哦'), 3)
            callback(false)
            return
        end

        -- 构造 segment 请求列表
        local segments = {}
        local seg_index = base_json['segment_index']
        if type(seg_index) == 'table' then
            for k, v in pairs(seg_index) do
                local seg_name = nil
                if type(v) == 'table' and v['segment_name'] then
                    seg_name = v['segment_name']
                elseif type(k) == 'string' then
                    seg_name = k
                end
                if seg_name then
                    table.insert(segments, api_segment_base .. seg_name)
                end
            end
        end

        if #segments == 0 then
            show_message(i18n.t('没有找到弹幕分段'), 3)
            callback(false)
            return
        end

        local output_table = {}
        local failed_segments = {}

        local function build_args_fn(server)
            return build_curl_args(server)
        end

        local function per_response_cb(server, err, out)
            if err then
                msg.warn('请求段失败: ' .. tostring(server) .. ' 错误: ' .. tostring(err))
                failed_segments[server] = true
                return
            end
            local seg_json = utils.parse_json(out)
            if seg_json and seg_json['barrage_list'] then
                parse_segment_to_output(seg_json, output_table, server)
            else
                msg.warn('分段数据解析为空: ' .. tostring(server))
                failed_segments[server] = true
            end
        end

        local function finish()
            local ok = #output_table > 0
            save_output_and_load(output_table, url)
            callback(ok)
            if ok and cached_path and next(failed_segments) == nil then
                SourceCache.save_later(cached_path, vid, output_table)
            end
        end

        local function retry_failed(attempt)
            local retry_list = {}
            for url, _ in pairs(failed_segments) do
                table.insert(retry_list, url)
            end
            if #retry_list == 0 or attempt > 2 then finish(); return end
            failed_segments = {}
            -- Use the same cancellable request queue as the first attempt.
            -- A slow retry must never block the Lua/UI thread in subprocess.
            parallel_requests(retry_list, build_args_fn, per_response_cb,
                function() retry_failed(attempt + 1) end,
                {concurrency = 3, per_request_timeout = 20})
        end

        -- 并行请求 segments（降低并发避免被限流）
        parallel_requests(segments, build_args_fn, per_response_cb,
            function() retry_failed(1) end, {concurrency = 3, per_request_timeout = 20})
    end)
end
