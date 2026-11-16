local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
local Color = require 'modules/color'
local msg   = require 'mp.msg'
local utils = require 'mp.utils'
local s2t   = require("dicts/s2t_chars")
local t2s   = require("dicts/t2s_chars")

local function ass_escape(text)
    return text:gsub("\\", "\\\\")
               :gsub("{", "\\{")
               :gsub("}", "\\}")
               :gsub("\n", "\\N")
end

-- 构建 per-source 的延迟查询函数
local function make_delay_lookup(source)
    local segments = nil
    local prefix = nil
    if source and source.delay_segments and #source.delay_segments > 0 then
        segments = {}
        for i, v in ipairs(source.delay_segments) do segments[i] = v end
        table.sort(segments, function(a, b) return (a.start or 0) < (b.start or 0) end)
        prefix = {}
        local s = 0
        for i, v in ipairs(segments) do
            s = s + (v.delay or 0)
            prefix[i] = s
        end
    end

    return function(t)
        local segs = segments or {}
        local pre = prefix or {}
        if #segs == 0 then return 0 end
        local idx = binary_search(segs, t, function(s) return (s and s.start) or 0 end)
        local target = idx - 1
        if target < 1 then return 0 end
        return pre[target] or 0
    end
end

local function xml_unescape(str)
    return str:gsub("&quot;", "\"")
              :gsub("&apos;", "'")
              :gsub("&gt;", ">")
              :gsub("&lt;", "<")
              :gsub("&amp;", "&")
end

local function decode_html_entities(text)
    return text:gsub("&#x([%x]+);", function(hex)
        local codepoint = tonumber(hex, 16)
        return unicode_to_utf8(codepoint)
    end):gsub("&#(%d+);", function(dec)
        local codepoint = tonumber(dec, 10)
        return unicode_to_utf8(codepoint)
    end)
end

-- 加载黑名单模式
local function load_blacklist_patterns(filepath)
    local patterns = {}
    if not file_exists(filepath) then
        return patterns
    end
    local file = io.open(filepath, "r")
    if not file then
        msg.error("无法打开黑名单文件: " .. filepath)
        return patterns
    end

    if string.match(filepath, "%.xml$") then
        -- xml文件格式示例
        --<?xml version="1.0" encoding="utf-8"?>
        --<filters>
        --  <item enabled="true">t=卡在</item>
        --  <item enabled="true">t=进度条</item>
        --</filters>
        print("加载黑名单文件: " .. filepath)
        for line in file:lines() do
            local pattern = line:match('<item%s+enabled="true">t=(.-)</item>')
            if pattern then
                print("加载黑名单模式: " .. pattern)
                table.insert(patterns, pattern)
            end
        end
    end

    if string.match(filepath, "%.json$") then
        -- json文件格式示例
        -- [{"type":0,"filter":"开门","opened":true,"id":15628936}
        -- ,{"type":0,"filter":"tony","opened":true,"id":15628939}
        -- ,{"type":1,"filter":"0+.1","opened":true,"id":15628951}]
        local content = read_file(filepath)
        if content then
            local json = utils.parse_json(content)
            if json and type(json) == "table" then
                for _, entry in ipairs(json) do
                    if entry.opened and entry.filter and entry.type == 0 then
                        table.insert(patterns, entry.filter)
                    end
                end
            end
        end
    end

    if string.match(filepath, "%.txt$") then
        -- 文本文件格式示例
        -- 卡在
        -- 进度条
        for line in file:lines() do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then
                table.insert(patterns, line)
            end
        end
    end

    file:close()
    return patterns
end

local blacklist_file = mp.command_native({ "expand-path", options.blacklist_path })
local black_patterns = load_blacklist_patterns(blacklist_file)

-- 屏蔽词管理器（scripts/danmaku-blocklist.lua）改完文件后发该消息即时重载，
-- 免重启。black_patterns 是本 chunk 的局部量，下方调用点经 upvalue 取到新值。
mp.register_script_message("reload-blacklist", function()
    black_patterns = load_blacklist_patterns(blacklist_file)
    msg.info("弹幕屏蔽词已重载")
end)

-- 检查字符串是否在黑名单中
function is_blacklisted(str, patterns)
    for _, pattern in ipairs(patterns) do
        local ok, result = pcall(function()
            return str:match(pattern)
        end)

        if ok and result then
            return true, pattern
        elseif not ok then
            -- msg.debug("黑名单规则错误，跳过: " .. pattern .. "，错误信息：" .. result)
        end
    end
    return false
end

-- 简繁转换
local function convert(text, dict)
    return text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return dict[c] or c
    end)
end

local function ch_convert(str)
    if options.chConvert == 1 then
        return convert(str, t2s)
    elseif options.chConvert == 2 then
        return convert(str, s2t)
    end
    return str
end

local ch_convert_cache = {}
local ch_cache_keys = {}
local ch_cache_max = 5000
local ch_cache_next, ch_cache_mode = 1, nil

local function ch_convert_cached(text)
    if type(text) ~= "string" or text == "" then return text end
    if options.chConvert ~= 1 and options.chConvert ~= 2 then return text end
    if ch_cache_mode ~= options.chConvert then
        ch_convert_cache, ch_cache_keys = {}, {}
        ch_cache_next, ch_cache_mode = 1, options.chConvert
    end
    local cached = ch_convert_cache[text]
    if cached ~= nil then return cached end

    local converted = ch_convert(text)
    -- A fixed ring avoids moving all 5,000 keys for every new comment in a
    -- long episode. Disabled conversion also needs no cache at all.
    local old_key = ch_cache_keys[ch_cache_next]
    if old_key then ch_convert_cache[old_key] = nil end
    ch_convert_cache[text] = converted
    ch_cache_keys[ch_cache_next] = text
    ch_cache_next = ch_cache_next % ch_cache_max + 1

    return converted
end

-- 合并重复弹幕
local function merge_duplicate_danmaku(danmakus, threshold)
    if not threshold or tonumber(threshold) < 0 then return danmakus end

    local groups = {}

    for _, d in ipairs(danmakus) do
        local tkey = options.merge_without_style and "any" or tostring(d.type or "")
        local text = d.text or ""

        groups[text] = groups[text] or {}
        groups[text][tkey] = groups[text][tkey] or {}
        table.insert(groups[text][tkey], d)
    end

    local final_groups = {}

    -- 颜色合并
    for _, type_groups in pairs(groups) do
        for _, list in pairs(type_groups) do
            if options.merge_without_style then
                table.insert(final_groups, list)
            else
                local color_groups = {}
                -- 利用弹幕同色大量重复的特征，缓存 颜色值 -> color_groups 索引
                local exact_color_cache = {}

                for _, d in ipairs(list) do
                    local c = d.color or 16777215
                    local g_idx = exact_color_cache[c]

                    if g_idx then
                        -- 命中缓存，直接插入
                        table.insert(color_groups[g_idx], d)
                    else
                        -- 未命中的颜色值，计算它是否落入已有代表颜色的 15 容差范围内
                        local found = false
                        for i, cg in ipairs(color_groups) do
                            if color_dist(cg[1].color or 16777215, c) <= 15 then
                                table.insert(cg, d)
                                -- 将该颜色值缓存为这个代表颜色的索引，后续遇到完全相同的颜色值可以直接命中
                                exact_color_cache[c] = i
                                found = true
                                break
                            end
                        end

                        -- 超出容差范围的全新颜色代表，开辟新组
                        if not found then
                            table.insert(color_groups, {d})
                            exact_color_cache[c] = #color_groups
                        end
                    end
                end
            
                for _, cg in ipairs(color_groups) do
                    table.insert(final_groups, cg)
                end
            end
        end
    end

    local merged = {}
    local abs = math.abs

    for _, group in ipairs(final_groups) do
        table.sort(group, function(a, b) return a.time < b.time end)

        local i = 1
        while i <= #group do
            local base = group[i]
            local color_source = base.color_source
            local times = { base.time }
            local count = 1
            local j = i + 1

            while j <= #group and abs(group[j].time - base.time) <= threshold do
                -- A merged uncoloured copy must not cause an explicitly
                -- authored colour (including white) to receive smart fill.
                if color_source and Color.normalize(color_source.color) == nil
                    and group[j].color ~= nil then
                    color_source = group[j].color_source
                end
                times[#times+1] = group[j].time
                count = count + 1
                j = j + 1
            end

            local same_time = true
            for k = 2, #times do
                if times[k] ~= times[1] then
                    same_time = false
                    break
                end
            end

            local danmaku = {
                time = base.time,
                type = base.type,
                size = base.size,
                color = base.color,
                color_source = color_source,
                text = base.text,
                source = base.source,
                orig_time = base.orig_time,
            }
            if count > 2 or not same_time then
                danmaku.text = danmaku.text .. string.format("x%d", count)
            end

            table.insert(merged, danmaku)
            i = j
        end
    end

    table.sort(merged, function(a, b) return a.time < b.time end)
    return merged
end

-- 限制每屏弹幕条数
local function limit_danmaku(danmakus, limit)
    if not limit or limit <= 0 then
        return danmakus
    end

    local window = {}
    for _, d in ipairs(danmakus) do
        for i = #window, 1, -1 do
            if window[i].end_time <= d.start_time then
                table.remove(window, i)
            end
        end

        if #window < limit then
            table.insert(window, d)
        else
            -- 窗口满时排队等待，先到先出
            d.drop = true
        end
    end

    local result = {}
    for _, d in ipairs(danmakus) do
        if not d.drop then
            table.insert(result, d)
        end
    end
    return result
end

-- 解析 XML 弹幕
function parse_xml_danmaku(xml_string)
    local danmakus = {}
    if not xml_string then
        return danmakus
    end
    -- [^>]* 匹配其他 attributes
    -- %f[^%s] 确保 p= 前面是空白字符
    for p_attr, text in xml_string:gmatch('<d%s+[^>]*%f[^%s]p="([^"]+)"[^>]*>([^<]+)</d>') do
        local params = Color.csv(p_attr)
        local time, mode, size = tonumber(params[1]), tonumber(params[2]), tonumber(params[3])
        if time and mode and size then
            table.insert(danmakus, {
                time = time,
                type = mode,
                size = size,
                color = Color.normalize(params[4]),
                text = xml_unescape(text)
            })
        end
    end

    table.sort(danmakus, function(a, b) return a.time < b.time end)
    return danmakus
end

-- 解析 JSON 弹幕
function parse_json_danmaku(json_string)
    local danmakus = {}
    if json_string:sub(1, 3) == "\239\187\191" then
        json_string = json_string:sub(4)
    end

    local json = utils.parse_json(json_string)
    if not json or type(json) ~= "table" then
        msg.info("JSON 解析失败")
        return danmakus
    end

    for _, entry in ipairs(json) do
        local c = entry.c
        local text = entry.m or ""
        if type(c) == "string" then
            local params = Color.csv(c)
            local time, mode, size = tonumber(params[1]), tonumber(params[3]), tonumber(params[4])
            if time and mode and size then
                table.insert(danmakus, {
                    time = time,
                    color = Color.normalize(params[2]),
                    type = mode,
                    size = size,
                    text = text
                })
            end
        end
    end

    table.sort(danmakus, function(a, b) return a.time < b.time end)
    return danmakus
end

-- 解析弹幕文件
function parse_danmaku_file(danmaku_input)
    local danmakus = {}

    if file_exists(danmaku_input) then
        local content = read_file(danmaku_input)
        if content then
            local parsed = {}
            if danmaku_input:match("%.xml$") then
                parsed = parse_xml_danmaku(content)
            elseif danmaku_input:match("%.json$") then
                parsed = parse_json_danmaku(content)
            end

            for _, d in ipairs(parsed) do
                table.insert(danmakus, d)
            end
        else
            msg.info("无法读取文件内容: " .. danmaku_input)
        end
    else
        msg.info("文件不存在: " .. danmaku_input)
    end

    for _, d in ipairs(danmakus) do
        if d.orig_time == nil then d.orig_time = d.time end
    end

    if #danmakus == 0 then
        msg.info("未能解析任何弹幕")
        return nil
    end

    return danmakus
end

--# 弹幕数组与布局算法 (Danmaku Array & Layout Algorithms)
local DanmakuArray = {}
DanmakuArray.__index = DanmakuArray

function DanmakuArray:new(res_x, res_y, font_size)
    local obj = {
        solution_y = res_y,
        font_size = font_size,
        rows = math.floor(res_y / font_size),
        time_length_array = {}
    }
    for i = 1, obj.rows do
        obj.time_length_array[i] = { time = 0, length = 0, empty = true }
    end
    setmetatable(obj, self)
    return obj
end

function DanmakuArray:set_time_length(row, time, length, kind, duration, span)
    for i = row, math.min(self.rows, row + (span or 1) - 1) do
        if i > 0 then
            self.time_length_array[i] = {time=time, length=length, empty=false,
                kind=kind or 'rolling', until_time=time + (duration or 0)}
        end
    end
end

function DanmakuArray:get_time(row)
    if row > 0 and row <= self.rows then
        return self.time_length_array[row].time
    end
    return -1
end

function DanmakuArray:get_length(row)
    if row > 0 and row <= self.rows then
        return self.time_length_array[row].length
    end
    return 0
end

function DanmakuArray:is_empty(row)
    if row > 0 and row <= self.rows then
        return self.time_length_array[row].empty
    end
    return false
end

-- 滚动弹幕 Y 坐标算法
function get_position_y(font_size, appear_time, text_length, resolution_x, roll_time, array, span)
    local velocity = (text_length + resolution_x) / roll_time
    span = span or 1
    for i = 1, array.rows - span + 1 do
        local clear = true
        for row = i, i + span - 1 do
            local previous = array.time_length_array[row]
            if not previous.empty then
                if previous.kind == 'fixed' then
                    clear = appear_time >= previous.until_time
                else
                    local previous_velocity = (previous.length + resolution_x) / roll_time
                    local delta_velocity = velocity - previous_velocity
                    local delta_x = (appear_time - previous.time) * previous_velocity - previous.length
                    clear = delta_x >= 0 and (delta_velocity <= 0
                        or delta_x / delta_velocity >= roll_time)
                end
                if not clear then break end
            end
        end
        if clear then
            array:set_time_length(i, appear_time, text_length, 'rolling', roll_time, span)
            return 1 + (i - 1) * font_size
        end
    end
    -- 所有行都被占用，放弃渲染
    return nil
end

-- 固定弹幕 Y 坐标算法
function get_fixed_y(font_size, appear_time, fixtime, array, from_top, span)
    span = span or 1
    local row_start, row_end, row_step
    if from_top then
        row_start, row_end, row_step = 1, array.rows - span + 1, 1
    else
        row_start, row_end, row_step = array.rows - span + 1, 1, -1
    end

    for i = row_start, row_end, row_step do
        local clear = true
        for row = i, i + span - 1 do
            local previous = array.time_length_array[row]
            if not previous.empty and appear_time < previous.until_time then
                clear = false
                break
            end
        end
        if clear then
            array:set_time_length(i, appear_time, 0, 'fixed', fixtime, span)
            return (i - 1) * font_size + 1
        end
    end
    -- 所有行都被占用，放弃渲染
    return nil
end

-- Layout uses plain text, never ASS escape/style tags. Leave room for bold
-- glyphs, wide Latin letters and outlines without synchronous libass calls for
-- every comment. Multiline comments reserve a contiguous block of lanes.
local function estimate_text_size(text, font_size, width_padding)
    local longest, line_width, lines = 0, 0, 1
    for ch in utf8_iter(text) do
        if ch == '\n' then
            longest, line_width, lines = math.max(longest, line_width), 0, lines + 1
        elseif ch ~= '\r' then
            local width = 1
            if #ch == 1 then
                if ch:match('[MW@%%&]') then width = 1
                elseif ch:match('[ilI%.,:;!|%s]') then width = 0.45
                else width = 0.75 end
            end
            line_width = line_width + width * font_size
        end
    end
    local padding = 2 * math.max(0, tonumber(options.outline) or 0)
        + math.max(0, tonumber(options.shadow) or 0) + 2
    return math.ceil(math.max(longest, line_width) * 1.1 + padding + (width_padding or 0)), lines
end

-- 将弹幕转换为 XML 格式
function convert_danmaku_to_xml(danmaku_out)
    local danmakus = {}
    for url, source in pairs(DANMAKU.sources) do
        if not source.blocked and source.data then
            local get_cached_delay = make_delay_lookup(source)

            for _, d in ipairs(source.data) do
                local base_time = d.orig_time or d.time
                local adjusted_time = base_time + get_cached_delay(base_time)
                table.insert(danmakus, {
                    orig_time = d.orig_time,
                    time = adjusted_time,
                    type = d.type,
                    size = d.size,
                    color = Color.normalize(d.color),
                    text = d.text,
                    source = url,
                })
            end
        end
    end

    if #danmakus == 0 then
        show_message(i18n.t("弹幕内容为空，无法保存"), 3)
        msg.verbose("弹幕内容为空，无法保存")
        COMMENTS = {}
        return false
    end

    -- 拼接为 XML 内容
    local xml = { '<?xml version="1.0" encoding="UTF-8"?><i>\n' }
    for _, d in ipairs(danmakus) do
       local time = d.time
       local type = d.type or 1
       local size = d.size or 25
       local color = Color.normalize(d.color) or ""
       local text = d.text or ""

       text = text:gsub("&", "&amp;")
                  :gsub("<", "&lt;")
                  :gsub(">", "&gt;")
                  :gsub("\"", "&quot;")
                  :gsub("'", "&apos;")

       table.insert(xml, string.format('<d p="%s,%s,%s,%s">%s</d>\n', time, type, size, color, text))
    end
    table.insert(xml, '</i>')

    -- 写入 XML 文件
    local file = io.open(danmaku_out, "w")
    if not file then
       show_message(i18n.t("无法写入目标 XML 文件"), 3)
       msg.info("无法写入目标 XML 文件: " .. danmaku_out)
       return false
    end
    file:write(table.concat(xml))
    file:close()
    show_message(i18n.t("转换 XML 弹幕成功： ") .. danmaku_out, 3)
    msg.info("转换 XML 弹幕成功： " .. danmaku_out)
    return true
end

local prepared_danmakus, prepared_sources
local geometry_cache, geometry_keys = {}, {}
-- Reuse text preparation across new canvases of one immutable VOD snapshot.
-- These are content-byte/entry limits, not a claim about total Lua memory.
local prepared_text_cache
local prepared_text_limit, prepared_text_bytes = 16384, 2 * 1024 * 1024
local function clear_prepared_layouts()
    prepared_danmakus, prepared_sources = nil, nil
    geometry_cache, geometry_keys = {}, {}
    prepared_text_cache = nil
end
mp.register_event('start-file', clear_prepared_layouts)
mp.register_event('end-file', clear_prepared_layouts)

function convert_danmaku_to_ass_events(force, geometry_only)
    local canvas = get_danmaku_canvas and get_danmaku_canvas() or {
        width=1920, height=1080, font_size=tonumber(options.fontsize) or 50,
        line_height=math.ceil((tonumber(options.fontsize) or 50) * 1.2
            + 2 * math.max(0, tonumber(options.outline) or 0) + 1), key='legacy'}
    local danmakus
    if geometry_only and prepared_sources == DANMAKU.sources and prepared_danmakus then
        if geometry_cache[canvas.key] then COMMENTS = geometry_cache[canvas.key]; return end
        danmakus = prepared_danmakus
    else
        clear_prepared_layouts()
        local per_source_lists = {}
        for url, source in pairs(DANMAKU.sources) do
            if not source.blocked and source.data then
                local get_cached_delay = make_delay_lookup(source)

                local list = {}
                for _, d in ipairs(source.data) do
                    local base_time = d.orig_time or d.time
                    if d.orig_time == nil then d.orig_time = base_time end
                    local adjusted_time = base_time + get_cached_delay(base_time)
                    local entry = {
                        orig_time = d.orig_time,
                        time = adjusted_time,
                        type = d.type,
                        size = d.size,
                        color = Color.normalize(d.color),
                        color_source = d,
                        text = d.text,
                        source = url,
                        live = source.live == true,
                        sequence = d.live_sequence,
                    }
                    if not is_blacklisted(d.text, black_patterns) then
                        table.insert(list, entry)
                    end
                end

                if #list > 0 then
                    table.sort(list, function(a, b) return a.time < b.time end)
                    per_source_lists[#per_source_lists + 1] = list
                end
            end
        end

        danmakus = {}

        local heap = new_min_heap()
        for li = 1, #per_source_lists do
            local lst = per_source_lists[li]
            if lst and #lst > 0 then
                heap.push({ time = lst[1].time, list_idx = li, pos = 1, entry = lst[1] })
            end
        end

        while true do
            local node = heap.pop()
            if not node then break end
            table.insert(danmakus, node.entry)
            local li = node.list_idx
            local next_pos = node.pos + 1
            local lst = per_source_lists[li]
            if lst and lst[next_pos] then
                heap.push({ time = lst[next_pos].time, list_idx = li, pos = next_pos, entry = lst[next_pos] })
            end
        end

        -- An incoming duplicate must not change the width/time of a live comment
        -- already crossing the screen. Ordinary video merging stays unchanged.
        local recorded, live = {}, {}
        for _, d in ipairs(danmakus) do
            local list = d.live and live or recorded
            list[#list + 1] = d
        end
        danmakus = merge_duplicate_danmaku(recorded, options.merge_tolerance)
        for _, d in ipairs(live) do danmakus[#danmakus + 1] = d end
        if #live > 0 then
            table.sort(danmakus, function(a, b)
                if a.time ~= b.time then return a.time < b.time end
                return (a.sequence or 0) < (b.sequence or 0)
            end)
        end

        prepared_danmakus, prepared_sources = danmakus, DANMAKU.sources
        -- Live batches keep their existing per-comment lane reservations.
        -- Never restore a cached snapshot over a newer live reservation set.
        for _, source in pairs(DANMAKU.sources) do
            if source.live then prepared_danmakus, prepared_sources = nil, nil; break end
        end
    end

    if #danmakus == 0 then
        if not force then
            show_message(i18n.t("该集弹幕内容为空，结束加载"), 3)
            msg.verbose("该集弹幕内容为空，结束加载")
        end
        COMMENTS = {}
        return
    end

    if not force then
        msg.info("已解析 " .. #danmakus .. " 条弹幕")
    end

    local fontsize, line_height = canvas.font_size, canvas.line_height
    local text_cache
    if prepared_danmakus == danmakus then
        if not prepared_text_cache or prepared_text_cache.mode ~= options.chConvert then
            prepared_text_cache = {mode=options.chConvert, texts={}, bytes=0}
        end
        text_cache = prepared_text_cache
        if not text_cache.widths or text_cache.fontsize ~= fontsize
            or text_cache.padding ~= canvas.width_padding
            or text_cache.outline ~= options.outline or text_cache.shadow ~= options.shadow then
            text_cache.widths, text_cache.spans = {}, {}
            text_cache.fontsize, text_cache.padding = fontsize, canvas.width_padding
            text_cache.outline, text_cache.shadow = options.outline, options.shadow
        end
    end
    local scrolltime = tonumber(options.scrolltime) or 15
    local fixtime = tonumber(options.fixtime) or 5

    local res_x, res_y = canvas.width, canvas.height
    local displayarea = math.max(0.01, math.min(1, tonumber(options.displayarea) or 1))
    local layout_res_y = math.max(line_height, math.floor(res_y * displayarea + line_height + 0.5))
    if canvas.max_layout_height then
        layout_res_y = math.min(layout_res_y, canvas.max_layout_height)
    end
    local live_layout_key = table.concat({canvas.key, scrolltime, fixtime, layout_res_y,
        canvas.layout_origin or 0}, ':')

    local lane_array = DanmakuArray:new(res_x, layout_res_y, line_height)
    canvas.layout_height = lane_array.rows * line_height

    -- 预处理弹幕，先计算时间段以便进行数量限制
    local pre_events = {}
    for _, d in ipairs(danmakus) do
        -- Keep the source timestamp and segment delay precise. Native ASS
        -- applies its own centisecond rounding when the track is serialized.
        local orig_time = d.orig_time
        local appear_time = d.time
        local danmaku_type = d.type

        local end_time = nil
        if danmaku_type >= 1 and danmaku_type <= 3 then
            end_time = appear_time + scrolltime
        elseif danmaku_type == 5 or danmaku_type == 4 then
            end_time = appear_time + fixtime
        end

        if end_time then
            table.insert(pre_events, {orig_time = orig_time, start_time = appear_time, end_time = end_time, danmaku = d})
        end
    end

    local ass_events = {}
    for i, ev in ipairs(pre_events) do
        local d = ev.danmaku
        local appear_time = ev.start_time
        local danmaku_type = d.type
        -- Supported event order is stable within prepared_danmakus. Live
        -- batches never use this cache or retain their source entries here.
        local clean_text, text_length, row_span
        if text_cache then
            clean_text = text_cache.texts[i]
            text_length = clean_text and text_cache.widths[i]
            row_span = clean_text and text_cache.spans[i]
            if not clean_text then
                clean_text = ch_convert_cached(decode_html_entities(d.text))
                if i <= prepared_text_limit
                    and text_cache.bytes + #clean_text <= prepared_text_bytes then
                    text_cache.texts[i] = clean_text
                    text_cache.bytes = text_cache.bytes + #clean_text
                end
            end
            if not text_length then
                text_length, row_span = estimate_text_size(clean_text, fontsize, canvas.width_padding)
                if text_cache.texts[i] then
                    text_cache.widths[i], text_cache.spans[i] = text_length, row_span
                end
            end
        else
            -- Keep the live path's original preparation work unchanged.
            clean_text = ch_convert_cached(decode_html_entities(d.text))
            text_length, row_span = estimate_text_size(clean_text, fontsize, canvas.width_padding)
        end
        local style, effect
        local pos, move = nil, nil
        local saved = d.live and d.color_source._live_layout
        if saved and saved.key ~= live_layout_key then saved = nil end
        local function live_y(array, length, choose)
            local y
            if saved then
                y = saved.y
                if y then array:set_time_length(math.floor((y - 1) / line_height) + 1,
                    appear_time, length, danmaku_type <= 3 and 'rolling' or 'fixed',
                    danmaku_type <= 3 and scrolltime or fixtime, row_span) end
            else
                y = choose()
                if d.live then d.color_source._live_layout = {key=live_layout_key, y=y or false} end
            end
            return y and y + (canvas.layout_origin or 0)
        end

        -- 滚动弹幕 (类型 1, 2, 3)
        if danmaku_type >= 1 and danmaku_type <= 3 then
            style = "R2L"
            local x1 = res_x + text_length / 2
            local x2 = -text_length / 2
            local y = live_y(lane_array, text_length, function()
                return get_position_y(line_height, appear_time, text_length, res_x, scrolltime, lane_array, row_span)
            end)
            if y then
                effect = string.format("{\\move(%d, %d, %d, %d)}", x1, y, x2, y)
                move = {x1, y, x2, y}
            end

        -- 顶部弹幕 (类型 5)
        elseif danmaku_type == 5 then
            style = "TOP"
            local x = res_x / 2
            local y = live_y(lane_array, 0, function()
                return get_fixed_y(line_height, appear_time, fixtime, lane_array, true, row_span)
            end)
            if y then
                effect = string.format("{\\pos(%d, %d)}", x, y)
                pos = {x, y}
            end

        -- 底部弹幕 (类型 4)
        elseif danmaku_type == 4 then
            style = "BTM"
            local x = res_x / 2
            local y = live_y(lane_array, 0, function()
                return get_fixed_y(line_height, appear_time, fixtime, lane_array, false, row_span)
            end)
            if y then
                effect = string.format("{\\pos(%d, %d)}", x, y)
                pos = {x, y}
            end
        end

        if style and effect then
            local text = ass_escape(clean_text)
                        :gsub("x(%d+)$", "{\\b1\\i1}x%1")

            local color = Color.resolve(d.color_source or d, options.smart_color,
                options.smart_color_percent, options.force_white)
            local color_text = Color.tag(color)
            text = effect .. color_text .. text
            local event = {
                orig_time = ev.orig_time,
                start_time = ev.start_time,
                end_time = ev.end_time,
                delay = ev.start_time - (ev.orig_time or ev.start_time),
                style = style,
                text = text,
                clean_text = clean_text,
                pos = pos,
                move = move,
                layer = (style == "R2L") and 0 or 1,
                source = d.source,
                color_source = d.color_source or d,
                render_color = color,
            }
            table.insert(ass_events, event)
        end
    end

    if options.max_screen_danmaku > 0 then
        ass_events = limit_danmaku(ass_events, options.max_screen_danmaku)
    end
    COMMENTS = ass_events
    COMMENTS.canvas = canvas
    if #geometry_keys >= 3 then
        geometry_cache[table.remove(geometry_keys, 1)] = nil
    end
    geometry_keys[#geometry_keys + 1] = canvas.key
    geometry_cache[canvas.key] = COMMENTS
end
