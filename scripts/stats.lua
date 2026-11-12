i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
-- Display some stats.
--
-- Please consult the readme for information about usage and configuration:
-- https://github.com/Argon-/mpv-stats
--
-- Please note: not every property is always available and therefore not always
-- visible.


-- ============================================================
-- 以下是原版文件内容（保持不变）
-- ============================================================

local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'

local function load_stats_info(name)
    local candidates = {}
    local function add(path)
        if path and path ~= '' then candidates[#candidates + 1] = path end
    end
    add(mp.command_native({'expand-path', '~~/script-modules/' .. name .. '.lua'}))
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local script_dir = select(1, utils.split_path(source))
    local parent = ''
    for _ = 1, 4 do
        parent = parent .. '../'
        add(utils.join_path(script_dir, parent .. 'script-modules/' .. name .. '.lua'))
    end
    local last_error = ''
    for _, path in ipairs(candidates) do
        local ok, result = pcall(dofile, path)
        if ok and type(result) == 'table' then return result end
        last_error = tostring(result)
    end
    error('Unable to load ' .. name .. '.lua: ' .. last_error)
end

local AudioStatsInfo = load_stats_info('audio-stats-info')
local MediaFormatInfo = load_stats_info('media-format-info')
local release_path = mp.find_config_file('script-modules/emo-release.lua')
local release_ok, release_info = pcall(dofile, release_path or '')
local release = release_ok and type(release_info) == 'table' and release_info or nil
if release then mp.set_property_native('user-data/mpv-emo/release', release) end

-- Options
local o = {
    -- Default key bindings
    key_page_1 = "1",
    key_page_2 = "2",
    key_page_3 = "3",
    key_page_4 = "4",
    key_page_5 = "5",
    key_page_6 = "6",
    key_page_0 = "0",
    -- For pages which support scrolling
    key_scroll_up = "UP",
    key_scroll_down = "DOWN",
    key_help_prev = "LEFT",
    key_help_next = "RIGHT",
    key_search = "/",
    key_exit = "ESC",
    scroll_lines = 1,

    duration = 4,
    redraw_delay = 1,                -- acts as duration in the toggling case
    ass_formatting = true,
    persistent_overlay = false,      -- whether the stats can be overwritten by other output
    -- 外观开关：两项都为 no 时回到 9.2 旧版的纯文字外观。
    -- 只影响配色与底板，不增删任何统计项、也不改布局与徽标等新功能。
    panel_background = true,         -- 统计卡片背景底板（旧版无此项）
    accent_colors = true,            -- 标题/标签/滚动提示使用主题色（旧版无此项）
    filter_params_max_length = 100,  -- show one filter per line if list exceeds this length
    file_tag_max_length = 128,       -- only show file tags shorter than this length in bytes
    file_tag_max_count = 16,         -- only show the first x file tags
    show_frame_info = false,         -- whether to show the current frame info
    term_clip = true,
    track_info_selected_only = true, -- only show selected track info
    debug = false,

    -- Graph options and style
    plot_perfdata = false,
    plot_vsync_ratio = false,
    plot_vsync_jitter = false,
    plot_cache = true,
    plot_tonemapping_lut = false,
    skip_frames = 5,
    global_max = true,
    flush_graph_data = true,         -- clear data buffers when toggling
    plot_bg_border_color = "0000FF",
    plot_bg_color = "262626",
    plot_color = "FFFFFF",
    plot_bg_border_width = 1.25,

    -- Text style
    font = "",
    font_mono = "monospace",   -- monospaced digits are sufficient
    font_size = 20,
    font_color = "",
    border_size = 1.65,
    border_color = "",
    shadow_x_offset = math.huge,
    shadow_y_offset = math.huge,
    shadow_color = "",
    alpha = "11",
    vidscale = "auto",
    position_x = 15,
    position_y = 105,
    font_size_fullscreen = 0,
    border_size_fullscreen = 0,
    position_x_fullscreen = -1,
    position_y_fullscreen = -1,
    auto_layout = true,

    -- Custom header for ASS tags to style the text output.
    -- Specifying this will ignore the text style values above and just
    -- use this string instead.
    custom_header = "",

    -- Text formatting
    -- With ASS
    ass_nl = "\\N",
    ass_indent = "\\h\\h\\h\\h\\h",
    ass_prefix_sep = "\\h\\h",
    ass_b1 = "{\\b1}",
    ass_b0 = "{\\b0}",
    ass_it1 = "{\\i1}",
    ass_it0 = "{\\i0}",
    -- Without ASS
    no_ass_nl = "\n",
    no_ass_indent = "    ",
    no_ass_prefix_sep = " ",
    no_ass_b1 = "\027[1m",
    no_ass_b0 = "\027[0m",
    no_ass_it1 = "\027[3m",
    no_ass_it0 = "\027[0m",

    bindlist = "no",  -- print page 4 to the terminal on startup and quit mpv
}

local update_scale
require "mp.options".read_options(o, nil, function ()
    update_scale()
end)

local format = string.format
local max = math.max
local min = math.min

-- Scaled metrics
local font_size = o.font_size
local border_size = o.border_size
local shadow_x_offset = o.shadow_x_offset
local shadow_y_offset = o.shadow_y_offset
local position_x = o.position_x
local position_y = o.position_y
local plot_bg_border_width = o.plot_bg_border_width
-- Function used to record performance data
local recorder = nil
-- Timer used for redrawing (toggling) and clearing the screen (oneshot)
local display_timer = nil
-- Timer used to update cache stats.
local cache_recorder_timer
-- Current page and <page key>:<page function> mappings
local curr_page = o.key_page_1
local pages = {}
local scroll_bound = false
local searched_text
local tm_viz_prev = nil
-- Save these sequences locally as we'll need them a lot
local ass_start = mp.get_property_osd("osd-ass-cc/0")
local ass_stop = mp.get_property_osd("osd-ass-cc/1")
-- Ring buffers for the values used to construct a graph.
-- .pos denotes the current position, .len the buffer length
-- .max is the max value in the corresponding buffer
local vsratio_buf, vsjitter_buf
local function init_buffers()
    vsratio_buf = {0, pos = 1, len = 50, max = 0}
    vsjitter_buf = {0, pos = 1, len = 50, max = 0}
end
local cache_ahead_buf, cache_speed_buf
local perf_buffers = {}
local process_key_binding

-- Page 0 uses its own ASS overlay so every performance-data column can have
-- an independent position without changing the layout of the other pages.
local perf_page_overlay = mp.create_osd_overlay("ass-events")
local perf_page_overlay_visible = false
local release_overlay = mp.create_osd_overlay("ass-events")
local stats_overlay = mp.create_osd_overlay("ass-events")
local stats_scroll_overlay = mp.create_osd_overlay("ass-events")
local stats_background = mp.create_osd_overlay("ass-events")
stats_background.z = 99

-- 统计面板可见性，发布给装饰性叠加层避让用（启动页品牌图居中绘制，
-- 与统计文字的左上角区域重叠）。读方必须用 mp.get_property_native：
-- 字符串经 mp.get_property 读回会带 JSON 引号。
local function publish_stats_visible(visible)
    local value = visible and 'yes' or 'no'
    if mp.get_property_native('user-data/stats/visible') ~= value then
        mp.set_property('user-data/stats/visible', value)
    end
end
-- Distinguish the persistent toggle from a temporary/one-shot display. Remote
-- controls need the toggle even when no video window can render the overlay.
local function publish_stats_toggled(toggled)
    if mp.get_property_native('user-data/stats/toggled') ~= toggled then
        mp.set_property_bool('user-data/stats/toggled', toggled)
    end
end
publish_stats_visible(false)
publish_stats_toggled(false)
mp.register_event('shutdown', function()
    publish_stats_visible(false)
    publish_stats_toggled(false)
end)
-- Statistics are foreground controls, above ordinary subtitles and danmaku.
stats_overlay.z, perf_page_overlay.z, release_overlay.z = 100, 100, 101
stats_scroll_overlay.z = stats_overlay.z
-- Request synchronous libass bounds only when a panel actually needs them.
stats_overlay.compute_bounds, perf_page_overlay.compute_bounds = false, false
local overlay_submissions = {help_page=1}
local function submit_stats_overlay(overlay, hidden)
    overlay.hidden = hidden == true
    local previous = overlay_submissions[overlay]
    local key = table.concat({overlay.res_x, overlay.res_y, tostring(overlay.hidden),
        tostring(overlay.compute_bounds), overlay.data}, '\0')
    if previous and previous.key == key then return previous.bounds end
    local bounds = overlay:update()
    overlay_submissions[overlay] = {key=key, bounds=bounds}
    return bounds
end
local function hide_stats_overlay(overlay)
    -- Removing an ASS overlay destroys its renderer/font caches. Keep the few
    -- stats layers hidden between openings; shutdown releases them with mpv.
    if overlay_submissions[overlay] and not overlay.hidden then
        local bounds = overlay.compute_bounds
        overlay.compute_bounds = false
        submit_stats_overlay(overlay, true)
        overlay.compute_bounds = bounds
    end
end
local stats_measure = mp.create_osd_overlay("ass-events")
local stats_safe_bottom, stats_line_height, convert_osd_ass_controls, fit_overview, stats_page_footer
local stats_line_cache_key, stats_line_cache_value
local overview_layout
local overview_panels
stats_measure.compute_bounds, stats_measure.hidden = true, true
-- Prepare only the overview renderers while mpv is still loading the first
-- video. Creating each libass font provider during playback can hold the OSD
-- lock for tens of milliseconds; the on_preloaded hook precedes presentation.
mp.add_hook('on_preloaded', 50, function()
    if overlay_submissions.warmed or not o.ass_formatting or mp.get_property('vid') == 'no' then return end
    if overlay_submissions[stats_overlay] then overlay_submissions.warmed=true;return end
    local video = false
    for _,track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'video' and not track.albumart then video=true;break end
    end
    if not video then return end
    stats_overlay.res_x, stats_overlay.res_y = 512, 288
    stats_overlay.data = ''
    submit_stats_overlay(stats_overlay, true)
    stats_measure.res_x, stats_measure.res_y = 512, 288
    stats_measure.compute_bounds = false
    stats_measure:update()
    stats_measure.compute_bounds = true
    overlay_submissions.warmed = true
end)
local PERF_PAGE_RES_Y = 288
local PERF_PAGE_MAX_COLUMNS = 4
local PERF_PAGE_MIN_COLUMN_WIDTH = 112
local PERF_PAGE_COLUMN_GAP = 5
local PERF_PAGE_FOUR_COLUMN_FONT_SCALE_X = 90

local property_cache = {}

local function get_property_cached(name, def)
    if property_cache[name] ~= nil then
        return property_cache[name]
    end
    return def
end

local function graph_add_value(graph, value)
    graph.pos = (graph.pos % graph.len) + 1
    graph[graph.pos] = value
    graph.max = max(graph.max, value)
end

local function no_ASS(t)
    if not o.use_ass then
        return t
    elseif not o.persistent_overlay then
        -- mp.osd_message supports ass-escape using osd-ass-cc/{0|1}
        return ass_stop .. t .. ass_start
    else
        return mp.command_native({"escape-ass", tostring(t)})
    end
end


local function bold(t)
    return o.b1 .. t .. o.b0
end


local function it(t)
    return o.it1 .. t .. o.it0
end


local function text_style()
    if not o.use_ass then
        return ""
    end
    if o.custom_header and o.custom_header ~= "" then
        return o.custom_header
    else
        local style = "{\\r\\an7\\pos(" .. position_x .. "," .. position_y .. ")\\fs"
                      .. font_size .. "\\bord" .. border_size

        if o.font ~= "" then
            style = style .. "\\fn" .. o.font
        end

        if o.font_color ~= "" then
            style = style .. "\\1c&H" .. o.font_color .. "&\\1a&H" .. o.alpha .. "&"
        end

        if o.border_color ~= "" then
            style = style .. "\\3c&H" .. o.border_color .. "&\\3a&H" .. o.alpha .. "&"
        end

        if o.shadow_color ~= "" then
            style = style .. "\\4c&H" .. o.shadow_color .. "&\\4a&H" .. o.alpha .. "&"
        end

        if o.shadow_x_offset < math.huge then
            style = style .. "\\xshad" .. shadow_x_offset
        end

        if o.shadow_y_offset < math.huge then
            style = style .. "\\yshad" .. shadow_y_offset
        end

        return style .. "}"
    end
end


local function has_vo_window()
    return mp.get_property_native("vo-configured") and mp.get_property_native("video-osd")
end


-- Generate a graph from the given values.
-- Returns an ASS formatted vector drawing as string.
--
-- values: Array/table of numbers representing the data. Used like a ring buffer
--         it will get iterated backwards `len` times starting at position `i`.
-- i     : Index of the latest data value in `values`.
-- len   : The length/amount of numbers in `values`.
-- v_max : The maximum number in `values`. It is used to scale all data
--         values to a range of 0 to `v_max`.
-- v_avg : The average number in `values`. It is used to try and center graphs
--         if possible. May be left as nil
-- scale : A value that will be multiplied with all data values.
-- x_tics: Horizontal width multiplier for the steps
local function generate_graph(values, i, len, v_max, v_avg, scale, x_tics)
    -- Check if at least one value exists
    if not values[i] then
        return ""
    end

    local x_max = (len - 1) * x_tics
    local y_offset = border_size
    local y_max = font_size * 0.66
    local x = 0

    if v_max > 0 then
        -- try and center the graph if possible, but avoid going above `scale`
        if v_avg and v_avg > 0 then
            scale = min(scale, v_max / (2 * v_avg))
        end
        scale = scale * y_max / v_max
    end  -- else if v_max==0 then all values are 0 and scale doesn't matter

    local s = {format("m 0 0 n %f %f l ", x, y_max - scale * values[i])}
    i = ((i - 2) % len) + 1

    for _ = 1, len - 1 do
        if values[i] then
            x = x - x_tics
            s[#s+1] = format("%f %f ", x, y_max - scale * values[i])
        end
        i = ((i - 2) % len) + 1
    end

    s[#s+1] = format("%f %f %f %f", x, y_max, 0, y_max)

    local bg_box = format("{\\bord%f}{\\3c&H%s&}{\\1c&H%s&}m 0 %f l %f %f %f 0 0 0",
                          plot_bg_border_width, o.plot_bg_border_color, o.plot_bg_color,
                          y_max, x_max, y_max, x_max)
    return format("%s{\\rDefault}{\\pbo%f}{\\shad0}{\\alpha&H00}{\\p1}%s{\\p0}" ..
                  "{\\bord0}{\\1c&H%s}{\\p1}%s{\\p0}%s",
                  o.prefix_sep, y_offset, bg_box, o.plot_color, table.concat(s), text_style())
end


local function append(s, str, attr)
    if not str then
        return false
    end
    attr.prefix_sep = attr.prefix_sep or o.prefix_sep
    attr.indent = attr.indent or o.indent
    attr.nl = attr.nl or o.nl
    attr.suffix = attr.suffix or ""
    attr.prefix = attr.prefix or ""
    attr.no_prefix_markup = attr.no_prefix_markup or false
    attr.prefix = attr.no_prefix_markup and attr.prefix or bold(attr.prefix)

    local index = #s + (attr.nl == "" and 0 or 1)
    s[index] = s[index] or ""
    s[index] = s[index] .. format("%s%s%s%s%s%s", attr.nl, attr.indent,
                     attr.prefix, attr.prefix_sep, no_ASS(str), attr.suffix)
    return true
end


-- Format and append a property.
-- A property whose value is either `nil` or empty (hereafter called "invalid")
-- is skipped and not appended.
-- Returns `false` in case nothing was appended, otherwise `true`.
--
-- s      : Table containing strings.
-- prop   : The property to query and format (based on its OSD representation).
-- attr   : Optional table to overwrite certain (formatting) attributes for
--          this property.
-- exclude: Optional table containing keys which are considered invalid values
--          for this property. Specifying this will replace empty string as
--          default invalid value (nil is always invalid).
-- cached : If true, use get_property_cached instead of get_property_osd
local function append_property(s, prop, attr, excluded, cached)
    excluded = excluded or {[""] = true}
    local ret
    if cached then
        ret = get_property_cached(prop)
    else
        ret = mp.get_property_osd(prop)
    end
    if not ret or excluded[ret] then
        if o.debug then
            print("No value for property: " .. prop)
        end
        return false
    end
    return append(s, ret, attr)
end

local function sorted_keys(t, comp_fn)
    local keys = {}
    for k,_ in pairs(t) do
        keys[#keys+1] = k
    end
    table.sort(keys, comp_fn)
    return keys
end

local function scroll_hint(search)
    local hint = format("(hint: scroll with %s/%s", o.key_scroll_up, o.key_scroll_down)
    if search then
        hint = hint .. " and search with " .. o.key_search
    end
    hint = hint .. ")"
    if not o.use_ass then return " " .. hint end
    return format(" {\\fs%s}%s{\\fs%s}", font_size * 0.66, hint, font_size)
end

local function append_perfdata(header, s, dedicated_page)
    local vo_p = mp.get_property_native("vo-passes")
    if not vo_p then
        return
    end

    -- Sums of all last/avg/peak values
    local last_s, avg_s, peak_s = {}, {}, {}
    for frame, data in pairs(vo_p) do
        last_s[frame], avg_s[frame], peak_s[frame] = 0, 0, 0
        for _, pass in ipairs(data) do
            last_s[frame] = last_s[frame] + pass["last"]
            avg_s[frame]  = avg_s[frame]  + pass["avg"]
            peak_s[frame] = peak_s[frame] + pass["peak"]
        end
    end

    -- Pretty print measured time
    local function pp(i)
        -- rescale to microseconds for a saner display
        return format("%5d", i / 1000)
    end

    -- Format n/m with a font weight based on the ratio
    local function p(n, m)
        local i = 0
        if m > 0 then
            i = tonumber(n) / m
        end
        -- Calculate font weight. 100 is minimum, 400 is normal, 700 bold, 900 is max
        local w = (700 * math.sqrt(i)) + 200
        if not o.use_ass then
            local str = format("%3d%%", i * 100)
            return w >= 700 and bold(str) or str
        end
        return format("{\\b%d}%3d%%{\\b0}", w, i * 100)
    end

    local font_small = o.use_ass and format("{\\fs%s}", font_size * 0.66) or ""
    local font_normal = o.use_ass and format("{\\fs%s}", font_size) or ""
    local font = o.use_ass and format("{\\fn%s}", o.font) or ""
    local font_mono = o.use_ass and format("{\\fn%s}", o.font_mono) or ""
    local indent = o.use_ass and "\\h" or " "

    -- ensure that the fixed title is one element and every scrollable line is
    -- also one single element.
    local h = dedicated_page and header or s
    local overview_columns = not dedicated_page and o.use_ass and o.auto_layout
        and not (o.custom_header and o.custom_header ~= '')
    local readable_table = dedicated_page and o.use_ass and o.auto_layout
        and not (o.custom_header and o.custom_header ~= '')
    if readable_table then
        h[#h+1] = bold(i18n.t('渲染耗时（μs）：')) .. o.nl .. o.indent .. o.indent
            .. font_mono .. i18n.t(' 最近 /  平均 /  峰值 ') .. o.prefix_sep .. indent
            .. i18n.t('占比') .. font .. o.prefix_sep .. o.prefix_sep .. i18n.t('渲染步骤')
    elseif overview_columns then
        h[#h+1] = o.nl .. o.indent .. bold(i18n.t("渲染耗时：")) .. o.prefix_sep
            .. font_mono .. i18n.t(" 最近 /  平均 /  峰值  μs") .. font
    else
        h[#h+1] = format("%s%s%s%s%s%s%s%s",
                         dedicated_page and "" or o.nl, dedicated_page and "" or o.indent,
                         bold(i18n.t("渲染耗时：")), o.prefix_sep, font_small,
                         i18n.t("（最近/平均/峰值 μs）"), font_normal,
                         dedicated_page and scroll_hint() or "")
    end

    for index,frame in ipairs(sorted_keys(vo_p)) do  -- ensure fixed display order
        local data = vo_p[frame]
        local label = ({fresh=i18n.t("新帧（Fresh）"), redraw=i18n.t("重绘（Redraw）")})[frame]
            or frame:gsub("^%l", string.upper)
        local f = "%s%s%s%s%s / %s / %s %s%s%s%s%s%s"

        if dedicated_page then
            if readable_table and index>1 then s[#s+1]=o.nl end
            s[#s+1] = format("%s%s%s:", o.nl, o.indent,
                             bold(label))

            for _, pass in ipairs(data) do
                s[#s+1] = format(f, o.nl, o.indent, o.indent,
                                 font_mono, pp(pass["last"]),
                                 pp(pass["avg"]), pp(pass["peak"]),
                                 o.prefix_sep .. indent, p(pass["last"], last_s[frame]),
                                 font, o.prefix_sep, o.prefix_sep, pass["desc"])

                if o.plot_perfdata and o.use_ass then
                    -- use the same line that was already started for this iteration
                    s[#s] = s[#s] ..
                              generate_graph(pass["samples"], pass["count"],
                                             pass["count"], pass["peak"],
                                             pass["avg"], 0.9, 0.25)
                end
            end

            -- Print sum of timing values as "Total"
            s[#s+1] = format(f, o.nl, o.indent, o.indent,
                             font_mono, pp(last_s[frame]),
                             pp(avg_s[frame]), pp(peak_s[frame]),
                             o.prefix_sep, bold(i18n.t("合计")), font, "", "", "")
        else
            -- for the simplified view, we just print the sum of each pass
            local row = format(f, "", overview_columns and "" or o.indent,
                            overview_columns and "" or o.indent, font_mono,
                            pp(last_s[frame]), pp(avg_s[frame]), pp(peak_s[frame]),
                            "", "", font, o.prefix_sep, o.prefix_sep,
                            label)
            s[#s+1] = o.nl .. row
            if overview_columns then
                s.overview_value_rows = s.overview_value_rows or {}
                s.overview_value_rows[#s.overview_value_rows+1] = row
            end
        end
    end
end

-- command prefix tokens to strip - includes generic property commands
local cmd_prefixes = {
    osd_auto=1, no_osd=1, osd_bar=1, osd_msg=1, osd_msg_bar=1, raw=1, sync=1,
    async=1, expand_properties=1, repeatable=1, nonrepeatable=1, nonscalable=1,
    set=1, add=1, multiply=1, toggle=1, cycle=1, cycle_values=1, ["!reverse"]=1,
    change_list=1,
}
-- commands/writable-properties prefix sub-words (followed by -) to strip
local name_prefixes = {
    define=1, delete=1, enable=1, disable=1, dump=1, write=1, drop=1, revert=1,
    ab=1, hr=1, secondary=1, current=1,
}
-- extract a command "subject" from a command string, by removing all
-- generic prefix tokens and then returning the first interesting sub-word
-- of the next token. For target-script name we also check another token.
-- The tokenizer works fine for things we care about - valid mpv commands,
-- properties and script names, possibly quoted, white-space[s]-separated.
-- It's decent in practice, and worst case is "incorrect" subject.
local function cmd_subject(cmd)
    cmd = cmd:gsub(";.*", ""):gsub("%-", "_")  -- only first cmd, s/-/_/
    local TOKEN = '^%s*["\']?([%w_!]*)'  -- captures+ends before (maybe) final "
    local tok, sname, subw

    repeat tok, cmd = cmd:match(TOKEN .. '["\']?(.*)')
    until not cmd_prefixes[tok]
    -- tok is the 1st non-generic command/property name token, cmd is the rest

    sname = tok == "script_message_to" and cmd:match(TOKEN)
         or tok == "script_binding" and cmd:match(TOKEN .. "/")
    if sname and sname ~= "" then
        return "script: " .. sname
    end

    -- return the first sub-word of tok which is not a useless prefix
    repeat subw, tok = tok:match("([^_]*)_?(.*)")
    until tok == "" or not name_prefixes[subw]
    return subw:len() > 1 and subw or "[unknown]"
end

-- key names are valid UTF-8, ascii7 except maybe the last/only codepoint.
-- we count codepoints and ignore wcwidth. no need for grapheme clusters.
-- our error for alignment is at most one cell (if last CP is double-width).
-- (if k was valid but arbitrary: we'd count all bytes <0x80 or >=0xc0)
local function keyname_cells(k)
    local klen = k:len()
    if klen > 1 and k:byte(klen) >= 0x80 then  -- last/only CP is not ascii7
        repeat klen = klen-1
        until klen == 1 or k:byte(klen) >= 0xc0  -- last CP begins at klen
    end
    return klen
end

local function get_kbinfo_lines()
    -- active keys: only highest priority of each key, and not our (stats) keys
    local bindings = mp.get_property_native("input-bindings", {})
    local active = {}  -- map: key-name -> bind-info
    for _, bind in pairs(bindings) do
        if bind.priority >= 0 and (
               not active[bind.key] or
               (active[bind.key].is_weak and not bind.is_weak) or
               (bind.is_weak == active[bind.key].is_weak and
                bind.priority > active[bind.key].priority)
           ) and not bind.cmd:find("script-binding stats/__forced_", 1, true)
           and bind.section ~= "input_forced_console"
           and (
               searched_text == nil or
               (bind.key .. bind.cmd .. (bind.comment or "")):lower():find(searched_text, 1, true)
           )
        then
            active[bind.key] = bind
        end
    end

    -- make an array, find max key len, add sort keys (.subject/.mods[_count])
    local ordered = {}
    local kspaces = ""  -- as many spaces as the longest key name
    for _, bind in pairs(active) do
        bind.subject = cmd_subject(bind.cmd)
        if bind.subject ~= "ignore" then
            ordered[#ordered+1] = bind
            _,_, bind.mods = bind.key:find("(.*)%+.")
            _, bind.mods_count = bind.key:gsub("%+.", "")
            if bind.key:len() > kspaces:len() then
                kspaces = string.rep(" ", bind.key:len())
            end
        end
    end

    local function align_right(key)
        return kspaces:sub(keyname_cells(key)) .. key
    end

    -- sort by: subject, mod(ifier)s count, mods, key-len, lowercase-key, key
    table.sort(ordered, function(a, b)
        if a.subject ~= b.subject then
            return a.subject < b.subject
        elseif a.mods_count ~= b.mods_count then
            return a.mods_count < b.mods_count
        elseif a.mods ~= b.mods then
            return a.mods < b.mods
        elseif a.key:len() ~= b.key:len() then
            return a.key:len() < b.key:len()
        elseif a.key:lower() ~= b.key:lower() then
            return a.key:lower() < b.key:lower()
        else
            return a.key > b.key  -- only case differs, lowercase first
        end
    end)

    -- key/subject pre/post formatting for terminal/ass.
    -- key/subject alignment uses spaces (with mono font if ass)
    -- word-wrapping is disabled for ass, or cut at 79 for the terminal
    local LTR = string.char(0xE2, 0x80, 0x8E)  -- U+200E Left To Right mark
    local term = not o.use_ass
    local kpre = term and "" or format("{\\q2\\fn%s}%s", o.font_mono, LTR)
    local kpost = term and " " or format(" {\\fn%s}", o.font)
    local spre = term and kspaces .. "   "
                       or format("{\\q2\\fn%s}%s   {\\fn%s}{\\fs%.3f\\u1}",
                                 o.font_mono, kspaces, o.font, font_size)
    local spost = term and "" or "{\\u0}"

    -- create the display lines
    local info_lines = {}
    local subject = nil
    for _, bind in ipairs(ordered) do
        if bind.subject ~= subject then  -- new subject (title)
            subject = bind.subject
            append(info_lines, "", {})
            append(info_lines, "", { prefix = spre .. subject .. spost })
        end
        if bind.comment then
            bind.cmd = bind.cmd .. "  # " .. bind.comment
        end
        append(info_lines, bind.cmd, { prefix = kpre .. no_ASS(align_right(bind.key)) .. kpost })
    end
    return info_lines
end

local function format_perf_index(index, count)
    local width = max(2, #tostring(count))
    return format("%0" .. width .. "d", index)
end


local function append_general_perfdata(s)
    local perfdata = mp.get_property_native("perf-info") or {}
    for i, data in ipairs(perfdata) do
        append(s, data.text or data.value,
            {prefix="["..format_perf_index(i, #perfdata).."] "..data.name..":"})

        if o.plot_perfdata and o.use_ass and data.value then
            local buf = perf_buffers[data.name]
            if not buf then
                buf = {0, pos = 1, len = 50, max = 0}
                perf_buffers[data.name] = buf
            end
            graph_add_value(buf, data.value)
            s[#s] = s[#s] .. generate_graph(buf, buf.pos, buf.len, buf.max, nil, 0.8, 1)
        end
    end
end

local function append_display_sync(s)
    if not mp.get_property_bool("display-sync-active", false) then
        return
    end

    local vspeed = append_property(s, "video-speed-correction", {prefix="DS:"})
    if vspeed then
        append_property(s, "audio-speed-correction",
                        {prefix="/", nl="", indent=" ", prefix_sep=" ", no_prefix_markup=true})
    else
        append_property(s, "audio-speed-correction",
                        {prefix="DS:" .. o.prefix_sep .. " - / ", prefix_sep=""})
    end

    append_property(s, "mistimed-frame-count", {prefix="Mistimed:", nl="",
                                                indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "vo-delayed-frame-count", {prefix="Delayed:", nl="",
                                                  indent=o.prefix_sep .. o.prefix_sep})

    -- As we need to plot some graphs we print jitter and ratio on their own lines
    if not display_timer.oneshot and (o.plot_vsync_ratio or o.plot_vsync_jitter) and o.use_ass then
        local ratio_graph = ""
        local jitter_graph = ""
        if o.plot_vsync_ratio then
            ratio_graph = generate_graph(vsratio_buf, vsratio_buf.pos,
                                         vsratio_buf.len, vsratio_buf.max, nil, 0.8, 1)
        end
        if o.plot_vsync_jitter then
            jitter_graph = generate_graph(vsjitter_buf, vsjitter_buf.pos,
                                          vsjitter_buf.len, vsjitter_buf.max, nil, 0.8, 1)
        end
        append_property(s, "vsync-ratio", {prefix="VSync Ratio:",
                                           suffix=o.prefix_sep .. ratio_graph})
        append_property(s, "vsync-jitter", {prefix="VSync Jitter:",
                                            suffix=o.prefix_sep .. jitter_graph})
    else
        -- Since no graph is needed we can print ratio/jitter on the same line and save some space
        local vr = append_property(s, "vsync-ratio", {prefix="VSync Ratio:"})
        append_property(s, "vsync-jitter", {prefix="VSync Jitter:",
                            nl=vr and "" or o.nl,
                            indent=vr and o.prefix_sep .. o.prefix_sep})
    end
end


-- Summarize only this package's managed AI graph. Keep generic filters and
-- debug output intact; never decode or expose device binding data here.
local function ai_filter_summary(f, prop, source)
    if prop ~= 'vf' or f.label ~= 'yaozhi_ai' or f.name ~= 'vapoursynth'
        or type(f.params) ~= 'table' then return nil end
    local file = tostring(f.params.file or ''):gsub('\\', '/'):match('([^/]+)$')
    if file ~= 'yaozhi-rife.vpy' and file ~= 'yaozhi-rife-nvidia-hq.vpy' then return nil end
    local fields = {}
    for value in (tostring(f.params['user-data'] or '') .. 'x'):gmatch('(.-)x') do
        fields[#fields + 1] = value
        if #fields >= 12 then break end
    end
    local function property(name)
        return mp.get_property_native('user-data/video-enhancement/' .. name)
    end
    local function fps(value)
        value = tonumber(value)
        if not value or value ~= value or value <= 0 or value >= math.huge then return nil end
        return value
    end
    local function rate(value)
        return string.format('%.3f', value):gsub('0+$', ''):gsub('%.$', '')
    end
    local superres = file == 'yaozhi-rife-nvidia-hq.vpy' and fields[7] == '2'
    local backend = superres and 'AnimeJaNai TensorRT'
        or file == 'yaozhi-rife-nvidia-hq.vpy' and 'RIFE TensorRT' or 'RIFE Vulkan'
    local processing = superres and i18n.t('AI 超分') or fields[12] == '1' and i18n.t('普通 HDR 兼容')
        or fields[5] == '3' and 'HDR' or 'SDR'
    local state = property('ai-state')
    local status
    if f.enabled == false then
        status = i18n.t('已禁用')
    elseif state == 'starting' then
        status = i18n.t('初始化中')
    elseif superres and state == 'spatial' and property('hq-superres-active') == 'yes' then
        status = i18n.t('已启用')
    elseif not superres and state == 'active' and property('ai-active') == 'yes' then
        local source, result = fps(property('ai-source-fps')), fps(property('ai-result-fps'))
        status = source and result and math.abs(result / source - 2) <= 0.07
            and (rate(source) .. '→' .. rate(result) .. ' FPS') or i18n.t('帧率待确认')
    elseif state == 'failed' then
        status = i18n.t('已回退')
    elseif state == 'off' or state == 'protected' or state == 'native' or state == 'idle' then
        status = i18n.t('未生效')
    else
        status = i18n.t('状态待确认')
    end
    local inference
    if type(source) == 'table' and not superres and f.enabled ~= false
        and state == 'active' and property('ai-active') == 'yes' then
        local function dimension(value)
            if type(value) == 'string' and not value:match('^%d+$') then return nil end
            value = tonumber(value)
            if value and value > 0 and value < math.huge and value % 1 == 0 then return value end
        end
        local w, h = dimension(source.w), dimension(source.h)
        local max_w, max_h = dimension(fields[2]), dimension(fields[3])
        if w and h and max_w and max_h then
            -- Match both managed VS graphs: the actual filter caps are
            -- bounds, not the inference canvas (e.g. 3840x1600 -> 2560x1066).
            local scale = math.min(1, math.max(320, max_w) / w, math.max(180, max_h) / h)
            local iw = math.max(2, math.floor(w * scale / 2) * 2)
            local ih = math.max(2, math.floor(h * scale / 2) * 2)
            inference = format('%d×%d（%s）', iw, ih,
                (iw < w or ih < h) and i18n.t('降分辨率') or i18n.t('原分辨率'))
        end
    end
    return not o.debug and (backend .. ' · ' .. processing .. ' · ' .. status) or nil, inference
end

local function append_filters(s, prop, prefix)
    local length = 0
    local filters = {}

    for _,f in ipairs(mp.get_property_native(prop, {})) do
        local summary = ai_filter_summary(f, prop)
        if summary then
            length = length + #summary
            filters[#filters+1] = no_ASS(summary)
        else
            local n = f.name
            if f.enabled ~= nil and not f.enabled then
                n = n .. " (disabled)"
            end

            if f.label ~= nil then
                n = "@" .. f.label .. ": " .. n
            end

            local p = {}
            for _,key in ipairs(sorted_keys(f.params)) do
                p[#p+1] = key .. "=" .. f.params[key]
            end
            if #p > 0 then
                p = " [" .. table.concat(p, " ") .. "]"
            else
                p = ""
            end

            length = length + n:len() + p:len()
            filters[#filters+1] = no_ASS(n) .. it(no_ASS(p))
        end
    end

    if #filters > 0 then
        local ret
        if length < o.filter_params_max_length then
            ret = table.concat(filters, ", ")
        else
            local sep = o.nl .. o.indent .. o.indent
            ret = sep .. table.concat(filters, sep)
        end
        s[#s+1] = o.nl .. o.indent .. bold(prefix) .. o.prefix_sep .. ret
    end
end


local function add_header(s)
    s[#s+1] = text_style()
end


local function is_remote_path(path)
    return path:match("^%a[%w%+%.%-]*://") ~= nil
end


local function is_query_only_filename(filename)
    return filename:match("^%s*[?&][^/?#&=]+=") ~= nil
        or filename:match("^%s*[^/?#&=]+=[^/?#&]*&[^/?#&=]+=") ~= nil
end


local function get_safe_remote_title(media_title)
    if media_title == "" or is_query_only_filename(media_title)
        or is_remote_path(media_title) then
        return nil
    end
    return media_title
end


local function get_display_filename()
    local filename = mp.get_property_osd("filename") or ""
    local media_title = mp.get_property_osd("media-title") or ""
    local path = mp.get_property("path") or ""
    local remote = is_remote_path(path)

    -- Some signed remote URLs are exposed by mpv as a query-only filename,
    -- for example "&mid=...&threshold=...". Never show those credentials.
    if remote and is_query_only_filename(filename) then
        return get_safe_remote_title(media_title) or "Remote media", media_title
    end

    filename = filename:gsub("[?#].*$", ""):gsub(":[0-9]+$", "")
    if remote and filename == "" then
        filename = get_safe_remote_title(media_title) or "Remote media"
    end

    return filename, media_title
end


local function add_file(s, print_cache, print_tags)
    append(s, "", {prefix="File:", nl="", indent=""})
    local filename, media_title = get_display_filename()
    append(s, filename, {prefix_sep="", nl="", indent=""})
    if filename ~= media_title then
        append_property(s, "media-title", {prefix="Title:"})
    end

    if print_tags then
        append_property(s, "duration", {prefix="Duration:"})
        local tags = mp.get_property_native("display-tags")
        local tags_displayed = 0
        for _, tag in ipairs(tags) do
            local value = mp.get_property("metadata/by-key/" .. tag)
            if tag ~= "Title" and tags_displayed < o.file_tag_max_count
               and value and value:len() < o.file_tag_max_length then
                append(s, value, {prefix=string.gsub(tag, "_", " ") .. ":"})
                tags_displayed = tags_displayed + 1
            end
        end
    end

    local editions = mp.get_property_number("editions")
    local edition = mp.get_property_number("current-edition")
    local ed_cond = (edition and editions > 1)
    if ed_cond then
        append_property(s, "edition-list/" .. tostring(edition) .. "/title",
                       {prefix="Edition:"})
        append_property(s, "edition-list/count",
                        {prefix="(" .. tostring(edition + 1) .. "/", suffix=")", nl="",
                         indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end

    local ch_index = mp.get_property_number("chapter")
    if ch_index and ch_index >= 0 then
        append_property(s, "chapter-list/" .. tostring(ch_index) .. "/title", {prefix="Chapter:",
                        nl=ed_cond and "" or o.nl})
        append_property(s, "chapter-list/count",
                        {prefix="(" .. tostring(ch_index + 1) .. " /", suffix=")", nl="",
                         indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end

    local fs = append_property(s, "file-size", {prefix="Size:"})
    append_property(s, "file-format", {prefix="Format/Protocol:",
                                       nl=fs and "" or o.nl,
                                       indent=fs and o.prefix_sep .. o.prefix_sep})

    if not print_cache then
        return
    end

    local demuxer_cache = mp.get_property_native("demuxer-cache-state", {})
    if demuxer_cache["fw-bytes"] then
        demuxer_cache = demuxer_cache["fw-bytes"] -- returns bytes
    else
        demuxer_cache = 0
    end
    local demuxer_secs = mp.get_property_number("demuxer-cache-duration", 0)
    if demuxer_cache + demuxer_secs > 0 then
        append(s, utils.format_bytes_humanized(demuxer_cache), {prefix="Total Cache:"})
        append(s, format("%.1f", demuxer_secs), {prefix="(", suffix=" sec)", nl="",
               no_prefix_markup=true, prefix_sep="", indent=o.prefix_sep})
    end
end


local function crop_noop(w, h, r)
    return r["crop-x"] == 0 and r["crop-y"] == 0 and
           r["crop-w"] == w and r["crop-h"] == h
end


local function crop_equal(r, ro)
    return r["crop-x"] == ro["crop-x"] and r["crop-y"] == ro["crop-y"] and
           r["crop-w"] == ro["crop-w"] and r["crop-h"] == ro["crop-h"]
end


local function append_resolution(s, r, prefix, w_prop, h_prop, video_res)
    if not r then
        return
    end
    w_prop = w_prop or "w"
    h_prop = h_prop or "h"
    if append(s, r[w_prop], {prefix=prefix}) then
        append(s, r[h_prop], {prefix="x", nl="", indent=" ", prefix_sep=" ",
                           no_prefix_markup=true})
        if r["aspect"] ~= nil and not video_res then
            append(s, format("%.2f:1", r["aspect"]), {prefix="", nl="", indent="",
                                                      no_prefix_markup=true})
            append(s, r["aspect-name"], {prefix="(", suffix=")", nl="", indent=" ",
                                         prefix_sep="", no_prefix_markup=true})
        end
        if r["sar"] ~= nil and video_res then
            append(s, format("%.2f:1", r["sar"]), {prefix="", nl="", indent="",
                                                      no_prefix_markup=true})
            append(s, r["sar-name"], {prefix="(", suffix=")", nl="", indent=" ",
                                         prefix_sep="", no_prefix_markup=true})
        end
        if r["s"] then
            append(s, format("%.2f", r["s"]), {prefix="(", suffix="x)", nl="",
                                               indent=o.prefix_sep, prefix_sep="",
                                               no_prefix_markup=true})
        end
        -- We can skip crop if it is the same as video decoded resolution
        if r["crop-w"] and (not video_res or
                            not crop_noop(r[w_prop], r[h_prop], r)) then
            append(s, format("[x: %d, y: %d, w: %d, h: %d]",
                            r["crop-x"], r["crop-y"], r["crop-w"], r["crop-h"]),
                            {prefix="", nl="", indent="", no_prefix_markup=true})
        end
    end
end


local function pq_eotf(x)
    if not x then
        return x;
    end

    local PQ_M1 = 2610.0 / 4096 * 1.0 / 4
    local PQ_M2 = 2523.0 / 4096 * 128
    local PQ_C1 = 3424.0 / 4096
    local PQ_C2 = 2413.0 / 4096 * 32
    local PQ_C3 = 2392.0 / 4096 * 32

    x = x ^ (1.0 / PQ_M2)
    x = max(x - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * x)
    x = x ^ (1.0 / PQ_M1)
    x = x * 10000.0

    return x
end


local function append_hdr(s, hdr, video_out)
    if not hdr then
        return
    end

    local function has(val, target)
        return val and math.abs(val - target) > 1e-4
    end

    -- If we are printing video out parameters it is just display, not mastering
    local display_prefix = video_out and "Display:" or "Mastering display:"

    local indent = ""
    local has_dml = has(hdr["min-luma"], 0.203) or has(hdr["max-luma"], 203)
    local has_cll = hdr["max-cll"] and hdr["max-cll"] > 0
    local has_fall = hdr["max-fall"] and hdr["max-fall"] > 0

    if has_dml or has_cll or has_fall then
        append(s, "", {prefix=video_out and "" or "HDR10:", prefix_sep=video_out and "" or nil})
        if has_dml then
            -- libplacebo uses close to zero values as "defined zero"
            hdr["min-luma"] = hdr["min-luma"] <= 1e-6 and 0 or hdr["min-luma"]
            append(s, format("%.2g / %.0f", hdr["min-luma"], hdr["max-luma"]),
                {prefix=display_prefix, suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_cll then
            append(s, string.format("%.0f", hdr["max-cll"]), {prefix="MaxCLL:",
                                    suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_fall then
            append(s, hdr["max-fall"], {prefix="MaxFALL:", suffix=" cd/m²", nl="",
                                        indent=indent})
        end
    end

    indent = o.prefix_sep .. o.prefix_sep

    if hdr["scene-max-r"] or hdr["scene-max-g"] or
       hdr["scene-max-b"] or hdr["scene-avg"] then
        append(s, "", {prefix="HDR10+:"})
        append(s, format("%.1f / %.1f / %.1f", hdr["scene-max-r"] or 0,
                         hdr["scene-max-g"] or 0, hdr["scene-max-b"] or 0),
               {prefix="MaxRGB:", suffix=" cd/m²", nl="", indent=""})
        append(s, format("%.1f", hdr["scene-avg"] or 0),
               {prefix="Avg:", suffix=" cd/m²", nl="", indent=indent})
    end

    if hdr["max-pq-y"] and hdr["avg-pq-y"] then
        append(s, "", {prefix="PQ(Y):"})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["max-pq-y"]),
                         hdr["max-pq-y"] * 100), {prefix="Max:", nl="",
                         indent=""})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["avg-pq-y"]),
                         hdr["avg-pq-y"] * 100), {prefix="Avg:", nl="",
                         indent=indent})
    end
end


local function append_img_params(s, r, ro, show_superres)
    if not r then
        return
    end

    append_resolution(s, r, "Resolution:", "w", "h", true)
    local superres_active = show_superres and mp.get_property_native(
        "user-data/video-enhancement/superres-active") == "yes"
    if show_superres and not superres_active then
        local input = mp.get_property_native('video-params') or {}
        for _, f in ipairs(mp.get_property_native('vf', {})) do
            local _, inference = ai_filter_summary(f, 'vf', input)
            if inference then
                append(s, inference, {prefix="AI Inference:"})
                break
            end
            -- An earlier enabled filter may resize/crop the decoded source.
            -- Its output geometry is not exposed here; do not invent a canvas.
            if f.enabled ~= false then input = {} end
        end
    end
    if ro and (r["w"] ~= ro["dw"] or r["h"] ~= ro["dh"]) then
        if ro["crop-w"] and (crop_noop(r["w"], r["h"], ro) or crop_equal(r, ro)) then
            ro["crop-w"] = nil
        end
        append_resolution(s, ro, "Output Resolution:", "dw", "dh")
    end

    if show_superres then
        -- gpu-next shaders run after video-out-params, so mpv's native
        -- resolution fields cannot identify whether the final display upscale
        -- is using the managed SSim/FSRCNNX path. Reuse the publication that
        -- also drives the video-enhancement menu; this keeps both UIs truthful.
        local superres_effective = mp.get_property_native(
            "user-data/video-enhancement/superres-effective")
        local superres_detail = mp.get_property_native(
            "user-data/video-enhancement/superres-detail")
        local superres_status = superres_active and superres_detail or superres_effective
        if superres_status and superres_status ~= "" and superres_status ~= "等待视频" then
            append(s, i18n.status(superres_status), {prefix="Super Resolution:"})
        end
    end

    local indent = o.prefix_sep .. o.prefix_sep
    r = ro or r

    local pixel_format = r["hw-pixelformat"] or r["pixelformat"]
    append(s, pixel_format, {prefix="Format:"})
    append(s, r["colorlevels"], {prefix="Levels:", nl="", indent=indent})
    if r["chroma-location"] and r["chroma-location"] ~= "unknown" then
        append(s, r["chroma-location"], {prefix="Chroma Loc:", nl="", indent=indent})
    end

    -- Group these together to save vertical space
    append(s, r["colormatrix"], {prefix="Colormatrix:"})
    if r["prim-red-x"] or r["prim-red-y"] or
       r["prim-green-x"] or r["prim-green-y"] or
       r["prim-blue-x"] or r["prim-blue-y"] or
       r["prim-white-x"] or r["prim-white-y"] then
        append(s, string.format("[%.3f %.3f, %.3f %.3f, %.3f %.3f, %.3f %.3f]",
                                r["prim-red-x"] or 0, r["prim-red-y"] or 0,
                                r["prim-green-x"] or 0, r["prim-green-y"] or 0,
                                r["prim-blue-x"] or 0, r["prim-blue-y"] or 0,
                                r["prim-white-x"] or 0, r["prim-white-y"] or 0),
            {prefix="Primaries:", nl="", indent=indent})
        append(s, r["primaries"], {prefix=i18n.t("使用"), nl="", indent=" ", prefix_sep=" ",
                                   no_prefix_markup=true})
    else
        append(s, r["primaries"], {prefix="Primaries:", nl="", indent=indent})
    end
    append(s, r["gamma"], {prefix="Transfer:", nl="", indent=indent})
end


local function append_fps(s, prop, eprop)
    local fps = mp.get_property_osd(prop)
    local efps = mp.get_property_osd(eprop)
    local single = eprop == "" or (fps ~= "" and efps ~= "" and fps == efps)
    local unit = prop == "display-fps" and " Hz" or " fps"
    local suffix = single and "" or " (specified)"
    local esuffix = single and "" or " (estimated)"
    local prefix = prop == "display-fps" and "Refresh Rate:" or "Frame Rate:"
    local nl = o.nl
    local indent = o.indent

    if fps ~= "" and append(s, fps, {prefix=prefix, suffix=unit .. suffix}) then
        prefix = ""
        nl = ""
        indent = ""
    end

    if not single and efps ~= "" then
        append(s, efps,
               {prefix=prefix, suffix=unit .. esuffix, nl=nl, indent=indent})
    end
end


local function add_video_out(s)
    local vo = mp.get_property_native("current-vo")
    if not vo then
        return
    end

    append(s, "", {prefix="Display:", nl=o.nl .. o.nl, indent=""})
    append(s, vo, {prefix_sep="", nl="", indent=""})

    append_property(s, "display-names", {prefix_sep="", prefix="(", suffix=")",
                    no_prefix_markup=true, nl="", indent=" "}, nil, true)
    append(s, mp.get_property_native("current-gpu-context"),
           {prefix="Context:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "avsync", {prefix="A-V:"})
    append_fps(s, "display-fps", "estimated-display-fps")
    if append_property(s, "decoder-frame-drop-count",
                       {prefix="Dropped Frames:", suffix=" (decoder)"}) then
        append_property(s, "frame-drop-count", {suffix=" (output)", nl="", indent=""})
    end
    append_display_sync(s)
    append_perfdata(nil, s, false)

    if mp.get_property_native("deinterlace-active") then
        append_property(s, "deinterlace", {prefix="Deinterlacing:"})
    end

    local scale = nil
    if not mp.get_property_native("fullscreen") then
        scale = get_property_cached("current-window-scale")
    end

    local od = mp.get_property_native("osd-dimensions")
    local rt = mp.get_property_native("video-target-params")
    local r = rt or {}

    -- Add window scale
    r["s"] = scale
    r["crop-x"] = od["ml"]
    r["crop-y"] = od["mt"]
    r["crop-w"] = od["w"] - od["ml"] - od["mr"]
    r["crop-h"] = od["h"] - od["mt"] - od["mb"]

    if not rt then
        r["w"] = r["crop-w"]
        r["h"] = r["crop-h"]
        append_resolution(s, r, "Resolution:", "w", "h", true)
        return
    end

    append_img_params(s, r)
    append_hdr(s, r, true)
end


local function append_dolby_vision(s, dv)
    if not dv then return end
    -- Keep the structured metadata unchanged; give the displayed layer
    -- components the same breathing room as the surrounding detail fields.
    local details = dv.details ~= '' and dv.details:gsub('%+', ' + ') or 'DV'
    append(s, details, {prefix='Dolby Vision:'})
end


local function add_video(s)
    local r = mp.get_property_native("video-params")
    local ro = mp.get_property_native("video-out-params")
    -- in case of e.g. lavfi-complex there can be no input video, only output
    if not r then
        r = ro
    end
    if not r then
        return
    end

    local track = mp.get_property_native("current-tracks/video")
    local track_type = (track and track.image) and "Image:" or "Video:"
    append(s, "", {prefix=track_type, nl=o.nl .. o.nl, indent=""})
    if track and append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""}) then
        append(s, track["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
        append_property(s, "hwdec-current", {prefix="HW:", nl="",
                        indent=o.prefix_sep .. o.prefix_sep,
                        no_prefix_markup=false, suffix=""}, {no=true, [""]=true}, true)
    end
    local has_prefix = false
    if o.show_frame_info then
        if append_property(s, "estimated-frame-number", {prefix="Frame:"}) then
            append_property(s, "estimated-frame-count", {indent=" / ", nl="",
                                                        prefix_sep=""})
            has_prefix = true
        end
        local frame_info = mp.get_property_native("video-frame-info")
        if frame_info and frame_info["picture-type"] then
            local attrs = has_prefix and {prefix="(", suffix=")", indent=" ", nl="",
                                          prefix_sep="", no_prefix_markup=true}
                                      or {prefix="Picture Type:"}
            append(s, frame_info["picture-type"], attrs)
            has_prefix = true
        end
        if frame_info and frame_info["interlaced"] then
            local attrs = has_prefix and {indent=" ", nl="", prefix_sep=""}
                                      or {prefix="Picture Type:"}
            append(s, "Interlaced", attrs)
        end

        local timecodes = {
            ["gop-timecode"] = "GOP",
            ["smpte-timecode"] = "SMPTE",
            ["estimated-smpte-timecode"] = "Estimated SMPTE",
        }
        for prop, name in pairs(timecodes) do
            if frame_info and frame_info[prop] then
                local attrs = has_prefix and {prefix=name .. " Timecode:",
                                              indent=o.prefix_sep .. o.prefix_sep, nl=""}
                                          or {prefix=name .. " Timecode:"}
                append(s, frame_info[prop], attrs)
                break
            end
        end
    end

    if mp.get_property_native("current-tracks/video/image") == false then
        append_fps(s, "container-fps", "estimated-vf-fps")
    end
    append_img_params(s, r, ro, true)
    append_dolby_vision(s, MediaFormatInfo.collect().dolby_vision)
    append_hdr(s, ro)
    append_property(s, "video-bitrate", {prefix="Bitrate:"})
    append_filters(s, "vf", "Filters:")
end


local function add_audio(s)
    local r = mp.get_property_native("audio-params")
    -- in case of e.g. lavfi-complex there can be no input audio, only output
    local ro = mp.get_property_native("audio-out-params") or r
    r = r or ro
    if not r then
        return
    end

    local merge = function(rr, rro, prop)
        local a = rr[prop] or rro[prop]
        local b = rro[prop] or rr[prop]
        return (a == b or a == nil) and a or (a .. " ➜ " .. b)
    end

    append(s, "", {prefix="Audio:", nl=o.nl .. o.nl, indent=""})
    local track = mp.get_property_native("current-tracks/audio")
    local output_format = ro.format or r.format
    local passthrough = AudioStatsInfo.is_passthrough(output_format)
    if track then
        append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""})
        append(s, track["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
    end
    append_property(s, "current-ao", {prefix="AO:", nl="",
                                      indent=o.prefix_sep .. o.prefix_sep})
    local dev = append_property(s, "audio-device", {prefix="Device:"})
    local ao_mute = mp.get_property_native("ao-mute") and " (Muted)" or ""
    append_property(s, "ao-volume", {prefix="AO Volume:", suffix="%" .. ao_mute,
                                     nl=dev and "" or o.nl,
                                     indent=dev and o.prefix_sep .. o.prefix_sep})
    if math.abs(mp.get_property_native("audio-delay")) > 1e-6 then
        append_property(s, "audio-delay", {prefix="A-V delay:"})
    end
    local cc
    local format
    local samplerate
    if passthrough then
        -- IEC61937/SPDIF exposes its carrier as a 2-channel, often 192 kHz
        -- output.  The movie's actual bed layout and sample rate live on the
        -- selected demux track and must be shown instead.
        cc = append(s, AudioStatsInfo.source_channel_label(track) or "Unknown",
                    {prefix="Channels:"})
        format = AudioStatsInfo.passthrough_format_label(output_format, track)
        samplerate = AudioStatsInfo.source_samplerate(track)
    else
        cc = append(s, AudioStatsInfo.merge_channel_labels(r, ro) or "Unknown",
                    {prefix="Channels:"})
        format = merge(r, ro, "format")
        samplerate = merge(r, ro, "samplerate")
    end
    append(s, format, {prefix="Format:", nl=cc and "" or o.nl,
                       indent=cc and o.prefix_sep .. o.prefix_sep})
    append(s, samplerate, {prefix="Sample Rate:", suffix=" Hz"})
    append_property(s, "audio-bitrate", {prefix="Bitrate:"})
    append_filters(s, "af", "Filters:")
end


-- Determine whether ASS formatting shall/can be used and set formatting sequences
local function eval_ass_formatting()
    o.use_ass = o.ass_formatting and has_vo_window()
    if o.use_ass then
        o.nl = o.ass_nl
        o.indent = o.ass_indent
        o.prefix_sep = o.ass_prefix_sep
        o.b1 = o.ass_b1
        o.b0 = o.ass_b0
        o.it1 = o.ass_it1
        o.it0 = o.ass_it0
    else
        o.nl = o.no_ass_nl
        o.indent = o.no_ass_indent
        o.prefix_sep = o.no_ass_prefix_sep
        o.b1 = o.no_ass_b1
        o.b0 = o.no_ass_b0
        o.it1 = o.no_ass_it1
        o.it0 = o.no_ass_it0
    end
end

-- split str into a table
-- example: local t = split(s, "\n")
-- plain: whether pat is a plain string (default false - pat is a pattern)
local function split(str, pat, plain)
    local init = 1
    local r, i, find, sub = {}, 1, string.find, string.sub
    repeat
        local f0, f1 = find(str, pat, init, plain)
        r[i], i = sub(str, init, f0 and f0 - 1), i+1
        init = f0 and f1 + 1
    until f0 == nil
    return r
end

local function stats_page_entries(ass)
    local entries = {}
    for i,label in ipairs({i18n.t('概览'),i18n.t('渲染'),i18n.t('缓存'),i18n.t('快捷键'),i18n.t('轨道'),i18n.t('帮助')}) do
        local key = o['key_page_'..i]
        local text = format('%s %s',key,label)
        if ass then
            text = convert_osd_ass_controls(no_ASS(text))
            if key == curr_page then
                local active = o.accent_colors and '\\1c&HFFF070&' or ''
                local normal = o.accent_colors and '\\1c&H'..(o.font_color~='' and o.font_color or 'FFFFFF')..'&' or ''
                text = '{\\b1'..active..'}'..text..'{\\b0'..normal..'}'
            end
        end
        entries[#entries+1] = text
    end
    return entries
end

-- Composes the output with header and scrollable content
-- Returns string of the finished page and the actually chosen offset
--
-- header      : table of the header where each entry is one line
-- content     : table of the content where each entry is one line
-- apply_scroll: scroll the content
local function finalize_page(header, content, apply_scroll)
    pages[curr_page].render_scale = 1
    if o.use_ass and o.auto_layout and not (o.custom_header and o.custom_header ~= "") then
        -- Count physical ASS rows, not append fragments (one fragment may
        -- contain several rows). Keep font size and the title origin fixed.
        local title = convert_osd_ass_controls(table.concat(header))
        local body = convert_osd_ass_controls(table.concat(content))
        if body:sub(1, #o.nl) == o.nl then body = body:sub(#o.nl + 1) end
        local rows = split(body, o.nl, true)
        local header_rows = title:gsub('{[^}]*}', '') ~= '' and #split(title, o.nl, true) or 0
        local footer = pages[curr_page].idx~=0 and stats_page_footer(font_size,#rows)
        local footer_height = footer and max(footer.height,footer.size*1.3)+footer.border+2 or font_size*1.2
        local capacity = max(1, math.floor((stats_safe_bottom() - position_y - footer_height - border_size * 2)
            / stats_line_height()) - header_rows)
        local page = pages[curr_page]
        local max_offset = max(1, #rows - capacity + 1)
        -- Measured wraps may reduce capacity below the line-height estimate.
        -- Keep the requested row until that real capacity is known.
        local from = max(1, min(page.offset or 1, footer and #rows or max_offset))
        local function compose(count)
            return text_style() .. title .. (header_rows>0 and o.nl or '')
                .. table.concat(rows,o.nl,from,min(#rows,from+count-1))
        end
        local output = compose(capacity)
        if footer then
            -- A short line-height sample cannot account for automatic wraps
            -- and fallback fonts on a complete page. Check the bounded slice.
            local w,h=mp.get_osd_size()
            local bottom=stats_safe_bottom()-footer_height
            -- Do not infer a larger capacity from a short suffix: it would
            -- reset a valid scroll offset just before reaching the last row.
            capacity=min(capacity,#rows-from+1)
            local fit_key=table.concat({w,h,bottom,from,#rows,compose(capacity)},'\0')
            if page.fit_key==fit_key then
                capacity=page.fit_capacity
            else
                local function fits(count)
                    stats_measure.res_x,stats_measure.res_y=288*w/h,288
                    stats_measure.data=compose(count)
                    local b=stats_measure:update()
                    return not b or not b.y1 or b.y1<=bottom
                end
                if not fits(capacity) then
                    local lo,hi=1,capacity
                    while lo<hi do
                        local mid=math.floor((lo+hi+1)/2)
                        if fits(mid) then lo=mid else hi=mid-1 end
                    end
                    capacity=lo
                end
                page.fit_key,page.fit_capacity=fit_key,capacity
            end
            max_offset=max(1,#rows-capacity+1)
            output=compose(capacity)
        end
        page.offset, page.max_offset = from, max_offset
        page.visible_last, page.total_rows = min(#rows, from + capacity - 1), #rows
        return output, from
    end
    local term_height = mp.get_property_native("term-size/h", 24)
    local from, to = 1, #content
    if apply_scroll then
        -- Up to 40 lines for libass because it can put a big performance toll on
        -- libass to process many lines which end up outside (below) the screen.
        -- In the terminal reduce height by 2 for the status line (can be more then one line)
        local max_content_lines = (o.use_ass and 40 or term_height - 2) - #header
        -- in the terminal the scrolling should stop once the last line is visible
        local max_offset = o.use_ass and #content or #content - max_content_lines + 1
        from = max(1, min((pages[curr_page].offset or 1), max_offset))
        to = min(#content, from + max_content_lines - 1)
        pages[curr_page].offset = from
    end
    local output = table.concat(header) .. table.concat(content, "", from, to)
    if not o.use_ass and o.term_clip then
        local clip = mp.get_property("term-clip-cc")
        local t = split(output, "\n", true)
        output = clip .. table.concat(t, "\n" .. clip)
    end
    return output, from
end

-- Returns an ASS string with "normal" stats
local function default_stats()
    local stats = {}
    eval_ass_formatting()
    if o.use_ass and o.auto_layout and not (o.custom_header and o.custom_header ~= '') then
        -- add_file appends its first line without a newline to an existing
        -- row. Seed that row so the filename is not stored at Lua index 0.
        local sections = {{'',title=i18n.t('文件与系统')}, {title=i18n.t('显示与渲染')},
                          {title=i18n.t('视频信息')}, {title=i18n.t('音频输出')}}
        add_file(sections[1], true, false)
        add_video_out(sections[2])
        add_video(sections[3])
        add_audio(sections[4])
        return fit_overview(stats, sections)
    end
    add_header(stats)
    add_file(stats, true, false)
    add_video_out(stats)
    add_video(stats)
    add_audio(stats)
    append(stats, i18n.t("按键切页  ") .. table.concat(stats_page_entries(false),' · '), {indent=""})
    return finalize_page({}, stats, false)
end

-- Returns an ASS string with extended VO stats
local function vo_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    append(header, "", {prefix=pages[o.key_page_2].desc, nl="", indent=""})
    local readable = o.use_ass and o.auto_layout and not (o.custom_header and o.custom_header~='')
    if readable then header[#header+1]=o.nl end
    append(header, i18n.t("单位：微秒（μs），1000 μs = 1 ms。"), {indent=""})
    if readable then
        append(header, format(i18n.t('仅含 VO 渲染计时，非端到端延迟；详见 %s 帮助。'),o.key_page_6), {indent=''})
    else
        append(header, i18n.t("仅含视频输出（VO）的渲染计时，非端到端延迟。"), {indent=""})
        append(header, i18n.t("解码、补帧及系统合成成本未全覆盖。"), {indent=""})
        append(header, format(i18n.t("按 %s 查看统计说明与排障。"), o.key_page_6), {indent=""})
    end
    header[#header+1] = readable and o.nl..o.nl or o.nl
    append_perfdata(header, content, true)
    if not mp.get_property_native("vo-passes") then
        append(content, i18n.t("当前输出未提供渲染计时。"), {indent=""})
    end
    header = {table.concat(header)}
    return finalize_page(header, content, true)
end

-- Presentation guidance only: no additional polling, inference or counters.
local function troubleshooting_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    append(header, "", {prefix=pages[o.key_page_6].desc, nl="", indent=""})
    local topics={i18n.t('基本操作'),i18n.t('丢帧与同步'),i18n.t('渲染指标'),i18n.t('排障与限制')}
    local readable=o.use_ass and o.auto_layout and not (o.custom_header and o.custom_header~='')
    append(header, format(i18n.t('帮助 %d/4：%s'),overlay_submissions.help_page,topics[overlay_submissions.help_page]), {indent=""})
    if not readable then
        append(header, format(i18n.t('%s/%s 切换帮助子页。'),
            o.key_help_prev,o.key_help_next), {indent=""})
        append(header, format(i18n.t("%s/%s 滚动；I（Shift+i）常驻开关。"),
            o.key_scroll_up, o.key_scroll_down), {indent=""})
    end
    header[#header+1] = o.nl
    local sections = {
        {i18n.t("打开统计"), i18n.t("i：临时显示；I（Shift+i）：常驻开关。")},
        {i18n.t("关闭统计"), i18n.t("I（Shift+i）可关闭常驻统计。"),
            i18n.t("直接以常驻方式打开时，"),
            format(i18n.t("也可按 %s 关闭。"), o.key_exit)},
        {i18n.t("切换页面"), i18n.t("显示统计时按页面键切换："),
            format(i18n.t("%s 概览 · %s 渲染 · %s 缓存"), o.key_page_1, o.key_page_2, o.key_page_3),
            format(i18n.t("%s 快捷键 · %s 轨道 · %s 帮助 · %s 内部"),
                o.key_page_4, o.key_page_5, o.key_page_6, o.key_page_0)},
        {i18n.t("累计丢帧"), i18n.t("观察播放中是否持续增长。"),
            i18n.t("启动、跳转的历史值不等于持续卡顿。")},
        {i18n.t("解码与输出"), i18n.t("解码丢帧：检查硬解与片源负载。"),
            i18n.t("输出丢帧：结合渲染和呈现节奏排查。")},
        {i18n.t("刷新率与帧率"), i18n.t("显示器 Hz 不等于弹幕实际刷新。"),
            i18n.t("片源 FPS 不等于实际呈现频率。")},
        {i18n.t("渲染耗时"), i18n.t("单位：微秒（μs）；1000 μs = 1 ms。"),
            i18n.t("仅为视频输出（VO）的渲染阶段计时。"),
            i18n.t("不等于整帧端到端延迟。"),
            i18n.t("未覆盖解码、补帧和合成全部成本。")},
        {i18n.t("新帧与重绘"), i18n.t("Fresh / Redraw 的含义依渲染后端而异。"),
            i18n.t("不可简单相加作为总延迟。"),
            i18n.t("各项峰值之和并非同一帧峰值。")},
        {i18n.t("同步与抖动"), i18n.t("结合实际启用的同步模式判断。"),
            i18n.t("未启用显示同步时，估算值可能无效。"),
            i18n.t("单项抖动不能证明显卡性能不足。")},
        {i18n.t("逐项排查"), i18n.t("先看实际画面与音画同步。"),
            i18n.t("一次只改一项设置，比较前后表现。")},
        {i18n.t("缺失数据"), i18n.t("未提供的数据不代表零耗时。")},
    }
    local groups={{1,2,3},{4,5,6,9},{7,8},{10,11}}
    for order, index in ipairs(groups[overlay_submissions.help_page]) do
        local section=sections[index]
        if readable and order>1 then content[#content+1]=o.nl end
        append(content, "", {prefix=section[1], indent=""})
        for i=2,#section do
            append(content, section[i], readable and {indent=o.prefix_sep,prefix_sep=''} or {})
        end
    end
    return finalize_page({table.concat(header)}, content, true)
end

local kbinfo_lines = nil
local function keybinding_info(after_scroll, bindlist)
    local header = {}
    local page = pages[o.key_page_4]
    eval_ass_formatting()
    add_header(header)
    local prefix = bindlist and page.desc or page.desc .. ":" .. scroll_hint(true)
    append(header, "", {prefix=prefix, nl="", indent=""})
    header = {table.concat(header)}

    if not kbinfo_lines or not after_scroll then
        kbinfo_lines = get_kbinfo_lines()
    end

    return finalize_page(header, kbinfo_lines, not bindlist)
end

local function float2rational(x)
    local max_den = 100000
    local m00, m01, m10, m11 = 1, 0, 0, 1
    local a = math.floor(x)
    local frac = x - a
    while m10 * a + m11 <= max_den do
        local temp = m00 * a + m01
        m01 = m00
        m00 = temp
        temp = m10 * a + m11
        m11 = m10
        m10 = temp

        if frac == 0 then
            break
        end

        x = 1 / frac
        a = math.floor(x)
        frac = x - a
    end
    return m00, m10
end

local function add_track(c, t, i)
    if not t then
        return
    end

    local type = t.image and "Image" or t["type"]:sub(1, 1):upper() .. t["type"]:sub(2)
    append(c, "", {prefix=type .. ":", nl=o.nl .. o.nl, indent=""})
    append(c, t["title"], {prefix_sep="", nl="", indent=""})
    append(c, t["id"], {prefix="ID:"})
    append(c, t["src-id"], {prefix="Demuxer ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["program-id"], {prefix="Program ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["ff-index"], {prefix="FFmpeg Index:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["external-filename"], {prefix="File:"})
    append(c, "", {prefix="Flags:"})
    local flags = {"default", "forced", "dependent", "visual-impaired",
                   "hearing-impaired", "original", "commentary", "image",
                   "albumart", "external"}
    local any = false
    for _, flag in ipairs(flags) do
        if t[flag] then
            append(c, flag, {prefix=any and ", " or "", nl="", indent="", prefix_sep=""})
            any = true
        end
    end
    if not any then
        table.remove(c)
    end
    if append(c, t["codec-desc"], {prefix="Codec:"}) then
        append(c, t["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if t["codec"] ~= t["decoder"] then
            append(c, t["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
    end
    append(c, t["lang"], {prefix="Language:"})
    append(c, AudioStatsInfo.source_channel_label(t), {prefix="Channels:"})
    append(c, t["demux-channels"], {prefix="Channel Layout:"})
    append(c, t["demux-samplerate"], {prefix="Sample Rate:", suffix=" Hz"})
    local function B(b) return b and string.format("%.2f", b / 1024) end
    local bitrate = append(c, B(t["demux-bitrate"]), {prefix="Bitrate:", suffix=" kbps"})
    append(c, B(t["hls-bitrate"]), {prefix="HLS Bitrate:", suffix=" kbps",
                                    nl=bitrate and "" or o.nl,
                                    indent=bitrate and o.prefix_sep .. o.prefix_sep})
    append_resolution(c, {w=t["demux-w"], h=t["demux-h"], ["crop-x"]=t["demux-crop-x"],
                          ["crop-y"]=t["demux-crop-y"], ["crop-w"]=t["demux-crop-w"],
                          ["crop-h"]=t["demux-crop-h"]}, "Resolution:")
    if not t["image"] and t["demux-fps"] then
        append_fps(c, "track-list/" .. i .. "/demux-fps", "")
    end
    append(c, t["format-name"], {prefix="Format:"})
    append(c, t["demux-rotation"], {prefix="Rotation:"})
    if t["demux-par"] then
        local num, den = float2rational(t["demux-par"])
        append(c, string.format("%d:%d", num, den), {prefix="Pixel Aspect Ratio:"})
    end
    local track_rg = t["replaygain-track-peak"] ~= nil or t["replaygain-track-gain"] ~= nil
    local album_rg = t["replaygain-album-peak"] ~= nil or t["replaygain-album-gain"] ~= nil
    if track_rg or album_rg then
        append(c, "", {prefix="Replay Gain:"})
    end
    if track_rg then
        append(c, "", {prefix="Track:", indent=o.indent .. o.prefix_sep, prefix_sep=""})
        append(c, t["replaygain-track-gain"], {prefix="Gain:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
        append(c, t["replaygain-track-peak"], {prefix="Peak:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
    end
    if album_rg then
        append(c, "", {prefix="Album:", indent=o.indent .. o.prefix_sep, prefix_sep=""})
        append(c, t["replaygain-album-gain"], {prefix="Gain:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
        append(c, t["replaygain-album-peak"], {prefix="Peak:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
    end
    if t.type == 'video' then
        -- Current-frame metadata belongs only to the selected video track.
        local current = mp.get_property_native('current-tracks/video', {})
        local snapshot = {video_track = t}
        if current.type == 'video' and current.id ~= nil and current.id == t.id then
            snapshot.video_frame_info = mp.get_property_native('video-frame-info', {})
        end
        local dv = MediaFormatInfo.from_snapshot(snapshot).dolby_vision
        append_dolby_vision(c, dv)
    end
end

local function track_info()
    local h, c = {}, {}
    eval_ass_formatting()
    add_header(h)
    local desc = pages[o.key_page_5].desc
    append(h, "", {prefix=format("%s:%s", desc, scroll_hint()), nl="", indent=""})
    h = {table.concat(h)}
    table.insert(c, o.nl .. o.nl)
    add_file(c, false, true)
    for i, track in ipairs(mp.get_property_native("track-list")) do
        if track['selected'] or not o.track_info_selected_only then
            add_track(c, track, i - 1)
        end
    end
    return finalize_page(h, c, true)
end

local function perf_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    local page = pages[o.key_page_0]
    append(header, "", {prefix=format("%s:%s", page.desc, scroll_hint()), nl="", indent=""})
    append_general_perfdata(content)
    header = {table.concat(header)}
    return finalize_page(header, content, true)
end

local function hide_perf_page_overlay()
    if perf_page_overlay_visible then
        hide_stats_overlay(perf_page_overlay)
        perf_page_overlay_visible = false
    end
end

convert_osd_ass_controls = function(text)
    if o.persistent_overlay or ass_stop == "" or not text:find(ass_stop, 1, true) then
        return text
    end

    local output = {}
    local position = 1
    while true do
        local plain_start, stop_end = text:find(ass_stop, position, true)
        if not plain_start then
            output[#output + 1] = text:sub(position)
            break
        end

        output[#output + 1] = text:sub(position, plain_start - 1)
        local ass_start_pos, start_end = text:find(ass_start, stop_end + 1, true)
        if not ass_start_pos then
            output[#output + 1] = mp.command_native({"escape-ass", text:sub(stop_end + 1)})
            break
        end

        output[#output + 1] = mp.command_native({"escape-ass",
            text:sub(stop_end + 1, ass_start_pos - 1)})
        position = start_end + 1
    end
    return table.concat(output)
end

-- Keep statistics above the dock and its media badges, even while the dock is
-- transiently hovered (osc/margins only describes persistent controls).
stats_safe_bottom = function()
    local margins = mp.get_property_native('user-data/osc/margins') or {}
    local has_uosc = mp.get_property_native('user-data/uosc/dock-animation-mode') ~= nil
    return 288 * (1 - max(tonumber(margins.b) or 0, has_uosc and 0.18 or 0.025))
end

local function stats_danmaku_area()
    if mp.get_property_native('user-data/uosc_danmaku/has-danmaku') ~= true then return nil end
    local layout = mp.get_property_native('user-data/uosc_danmaku/layout')
    if type(layout) == 'table' and layout.visible == false then return nil end
    return type(layout) == 'table' and tonumber(layout.top) or 0
end

local function show_release_badge(compose)
    if not release or not o.use_ass or not has_vo_window() then
        hide_stats_overlay(release_overlay)
        return
    end
    local w, h = mp.get_osd_size()
    if not w or not h or h <= 0 then return end
    release_overlay.res_x, release_overlay.res_y = 288 * w / h, 288
    -- Independent upper-right label: no extra row in any statistics page.
    local x = release_overlay.res_x - max(position_x, 6)
    local y = position_y
    if mp.get_property_native('user-data/startup-format-logos/visible') == 'yes' then
        y = max(y, 288 * 0.15)
    end
    if w < h * 1.2 then y = max(4, position_y - font_size * 1.6) end
    local badge_panel
    if curr_page==o.key_page_1 and overview_panels then
        for _,panel in ipairs(overview_panels) do
            if not badge_panel or panel.column>badge_panel.column then badge_panel=panel end
        end
        if badge_panel then
            -- Scrolled body rows have no title lane. Do not cover a value
            -- with branding; it returns with the section heading.
            if not badge_panel.heading then hide_stats_overlay(release_overlay);return end
            x,y=badge_panel.x1-max(2,8*288/h),badge_panel.y0
        end
    end
    local label = mp.command_native({'escape-ass', tostring(release.name)..'  '..tostring(release.version)})
    local label_size = font_size * 1.05
    if curr_page == o.key_page_1 and o.auto_layout then label_size=max(label_size,16*288/h) end
    local badge_key=badge_panel and table.concat({x,y,label,label_size,border_size,o.font},':')
    local cached=badge_key and overview_layout and overview_layout.badge
    if cached and cached.key==badge_key then label,x=cached.label,cached.x end
    local measured=cached and cached.key==badge_key
    if badge_panel and not measured then
        local width=badge_panel.x1-badge_panel.x0
        stats_measure.res_x,stats_measure.res_y=release_overlay.res_x,288
        stats_measure.data=text_style():gsub('\\pos%b()','')..format('{\\pos(0,0)\\fs%.3f}',label_size)..label
        local b=stats_measure:update()
        if b and b.x1-b.x0 > width*.52 then
            label=mp.command_native({'escape-ass',tostring(release.version)})
        end
    end
    local badge_style = text_style():gsub('\\pos%b()', ''):gsub('\\an%d', '\\an9')
    if badge_panel and not measured then
        stats_measure.data=badge_style..format('{\\an9\\pos(%.2f,%.2f)\\fs%.2f\\b1\\bord%.3f}%s',
            x,y,label_size,max(border_size,288/h),label)
        local b=stats_measure:update()
        if b and b.x1 then x=x-max(0,b.x1-badge_panel.x1+288/h) end
        if overview_layout then overview_layout.badge={key=badge_key,label=label,x=x} end
    end
    release_overlay.data = badge_style
        .. format('{\\an9\\pos(%.2f,%.2f)\\fs%.2f\\b1%s\\bord%.3f}%s',
            x, y, label_size, o.accent_colors and '\\1c&HFFF070&\\1a&H00&' or '',
            max(border_size,288/h), label)
    if compose then
        hide_stats_overlay(release_overlay)
        return release_overlay.data
    end
    submit_stats_overlay(release_overlay)
end

stats_line_height = function()
    local w, h = mp.get_osd_size()
    local key = table.concat({w or 0, h or 0, font_size, border_size, o.font}, ':')
    if stats_line_cache_key ~= key then
        stats_measure.res_x, stats_measure.res_y = 288 * (w or 1280) / max(1, h or 720), 288
        stats_measure.data = text_style() .. i18n.t('统计 Ag')
        local single = stats_measure:update()
        stats_measure.data = text_style() .. i18n.t('统计 Ag') .. o.nl .. i18n.t('统计 Ag')
        local double = stats_measure:update()
        local advance = single and double and single.y1 and double.y1 and double.y1 - single.y1
        stats_line_cache_value = advance and advance > 0 and advance or font_size * 1.2
        stats_line_cache_key = key
    end
    return stats_line_cache_value
end

-- Share the footer measurement with each page's content-height budget.
-- Reserve the widest row counter so scrolling cannot move the panels.
stats_page_footer = function(size, rows)
    local w, h = mp.get_osd_size()
    local canvas = 288 * w / h
    local footer_size = max(font_size*.75, size*.8)
    local border = max(border_size, 288/h)
    local style = text_style():gsub('\\pos%b()', ''):gsub('\\an%d', '')
    local entries = stats_page_entries(true)
    local navigation = i18n.t('按键切页  ') .. table.concat(entries,' · ')
    local digits = string.rep('8', #tostring(max(1, rows)))
    local counter = format('↑/↓  %s–%s / %s', digits, digits, digits)
    local help_hint=curr_page==o.key_page_6 and convert_osd_ass_controls(no_ASS(
        format(i18n.t('帮助 %d/4  %s/%s 切页'),overlay_submissions.help_page,o.key_help_prev,o.key_help_next))) or ''
    if help_hint~='' then counter=help_hint..'    '..counter end
    local safe_bottom=stats_safe_bottom()
    local key = table.concat({w,h,position_x,safe_bottom,style,footer_size,border,navigation,help_hint,digits}, ':')
    local cached = overlay_submissions.page_footer
    if cached and cached.key == key then return cached end
    local function measure(text,y,x)
        y,x=y or 144,x or 0
        stats_measure.res_x, stats_measure.res_y = canvas, 288
        -- A bottom anchor at y=0 clips the preceding lines from bounds.
        stats_measure.data = style .. format('{\\q2\\an1\\pos(%.3f,%.3f)\\fs%.2f\\bord%.3f}',
            x,y,footer_size,border) .. text
        local bounds = stats_measure:update()
        return bounds and bounds.x1 and bounds.x1 - min(0,bounds.x0 or 0) or 0,
            bounds and bounds.y1 and bounds.y1-y or footer_size*1.3,
            bounds and bounds.y1 and bounds.y0 and bounds.y1-bounds.y0 or footer_size*1.3,bounds
    end
    local width = max(1,canvas-position_x*2-border*2)
    local help_separator='    '
    if help_hint~='' and measure(counter)>width then
        help_separator=o.nl
        counter=help_hint..help_separator..format('↑/↓  %s–%s / %s',digits,digits,digits)
    end
    -- Wrap complete key/name entries, retaining separators within each row.
    local lines, line = {}, i18n.t('按键切页  ')
    for _,entry in ipairs(entries) do
        local separator = line==i18n.t('按键切页  ') and '' or ' · '
        local candidate = line .. separator .. entry
        if measure(candidate)>width then
            lines[#lines+1],line = line,entry
        else
            line = candidate
        end
    end
    lines[#lines+1] = line
    navigation = table.concat(lines,o.nl)
    local separator = measure(navigation .. '    ' .. counter) > width and o.nl or '    '
    local function placement(text)
        local _,offset,height=measure(text)
        local y=safe_bottom-border-offset
        local bounds
        -- Check the actual bottom position as well: near the canvas edge,
        -- libass's raster bounds can differ from the centred font sample.
        for _=1,2 do
            local _,_,actual_height,b=measure(text,y,position_x)
            height,bounds=actual_height,b
            if not b or not b.y1 or b.y1<=safe_bottom-border then break end
            y=y-(b.y1-(safe_bottom-border))
        end
        return safe_bottom-border-y,
            bounds and bounds.y0 and safe_bottom-border-bounds.y0 or height
    end
    local scroll_bottom,scroll_height=placement(navigation..separator..counter)
    local bottom,height=placement(navigation..(help_hint~='' and separator..help_hint or ''))
    cached = {key=key,style=style,size=footer_size,border=border,navigation=navigation,help_hint=help_hint,
        separator=separator,help_separator=help_separator,bottom=bottom,scroll_bottom=scroll_bottom,
        height=max(height,scroll_height)}
    overlay_submissions.page_footer = cached
    return cached
end

-- A readable overview: reflow the data, never squeeze the complete canvas.
-- Columns and font depend only on the viewport, not changing measurements.
fit_overview = function(stats, sections)
    overview_panels = nil
    if not o.use_ass or not o.auto_layout or (o.custom_header and o.custom_header ~= '') then
        return finalize_page({}, stats, false)
    end
    local w, h = mp.get_osd_size()
    local canvas = 288 * w / h
    -- libass's nominal size includes font ascenders: 24 gives roughly 16 px
    -- of visible CJK text with the bundled Noto face in a small window.
    -- Viewport units own positioning; DPI only sets a readable minimum and
    -- physical padding. Do not multiply an already window-scaled font twice.
    local dpi = max(1, min(4, mp.get_property_number('display-hidpi-scale', 1) or 1))
    local pixel = 288 / h
    local logical_pixel = dpi * pixel
    local size = max(font_size, 24 * pixel, 20 * logical_pixel)
    local ratio = size / font_size
    local line_height = max(stats_line_height() * ratio, size * .90) * (h / dpi >= 720 and 1.10 or 1.02)
    local extra_bottom = (h / dpi >= 576 and 4 or 2) * logical_pixel
    local panel_bottom = 6 * logical_pixel + extra_bottom
    local gap = max(size * 1.6, 32 * logical_pixel)
    local edge = max(position_x, 12 * logical_pixel)
    local usable = max(size * 2, canvas - edge * 2)
    local columns = sections and usable >= size * 50 + gap and 2 or 1
    local width = min((usable - gap * (columns - 1)) / columns, size * 32)
    -- A capped reading width must be centred as a whole. Anchoring capped
    -- columns to the left creates a large empty right side on high-res screens.
    local origin_x = (canvas - columns * width - (columns - 1) * gap) / 2
    local label_width = min(width * .25, size * 5.6)
    local key = table.concat({w,h,size,border_size,position_x,position_y,width,dpi,o.font}, ':')
    if not overview_layout or overview_layout.key ~= key then
        overview_layout = {key=key, wraps={}, labels={}, cache_count=0}
    end
    local layout = overview_layout
    layout.columns, layout.font_pixels = columns, size * h / 288
    layout.width, layout.line_height = width, line_height
    layout.origin_x, layout.dpi = origin_x, dpi
    local style = text_style():gsub('\\pos%b()', '')
        .. format('{\\q2\\pos(0,0)\\fs%.4f}', size)
    local function clean(text)
        -- Graphs restore the regular style. Scale their font restoration as
        -- well, and let the row own its position after wrapping.
        return text:gsub('\\pos%b()', ''):gsub('\\fs([%d%.]+)', function(n)
            return format('\\fs%.4f', tonumber(n) * ratio)
        end)
    end
    local measured = {}
    local function measure(text)
        local cached = measured[text]
        if cached then return cached.width, cached.bounds end
        stats_measure.res_x, stats_measure.res_y = canvas, 288
        stats_measure.data = style .. text
        local b = stats_measure:update()
        -- Leading indentation has no ink, but still consumes layout width.
        local width = b and b.x1 and b.x0 and b.x1 - min(0,b.x0) or 0
        measured[text] = {width=width, bounds=b}
        return width, b
    end
    if not layout.reference_bottom then
        local _,b=measure(i18n.t('统计 Ag'))
        layout.reference_bottom=b and b.y1 or line_height
    end
    local function wrap(raw, inset)
        inset = inset or 0
        local cache_key = tostring(inset)..':'..raw
        local cached = layout.wraps[cache_key]
        if cached then return cached end
        local row = clean(raw)
        local result = {}
        local limit = max(size * 2, width - inset - border_size * 3)
        if measure(row) <= limit then
            result[1] = row
        else
            -- Treat ASS overrides/escapes and UTF-8 codepoints atomically.
            -- Drawing runs are indivisible; text around a graph may wrap.
            local tokens, i = {}, 1
            while i <= #row do
                local part = row:sub(i):match('^%b{}')
                if part and part:match('\\p[1-9]') then
                    local ending = row:find('{\\p0}', i + #part, true)
                    if ending then part = row:sub(i, ending + 4) end
                end
                part = part or row:sub(i):match('^\\[h{}\\]')
                    or row:sub(i):match('^[%z\1-\127\194-\244][\128-\191]*')
                    or row:sub(i,i)
                tokens[#tokens+1] = part
                i = i + #part
            end
            local from, carry = 1, ''
            while from <= #tokens do
                local lo, hi, best = from, #tokens, from
                local prefix = (#result > 0 and inset == 0 and o.indent or '') .. carry
                while lo <= hi do
                    local mid = math.floor((lo+hi)/2)
                    if measure(prefix .. table.concat(tokens,'',from,mid)) <= limit then
                        best, lo = mid, mid+1
                    else hi = mid-1 end
                end
                -- Prefer a nearby word/field boundary, retaining every byte.
                if best < #tokens then
                    for j=best,max(from, best-16),-1 do
                        if tokens[j]==' ' or tokens[j]=='\\h' or tokens[j]==',' then
                            if j > from then best=j; break end
                        end
                    end
                end
                local segment = table.concat(tokens,'',from,best)
                result[#result+1] = prefix .. segment
                for j=from,best do
                    local tag=tokens[j]
                    if tag:sub(1,1)=='{' and not tag:match('\\p%d') then carry = carry .. tag end
                end
                from = best+1
            end
        end
        for i,text in ipairs(result) do
            local ink_width,bounds=measure(text)
            local extra=max(0,(bounds and bounds.y1 or layout.reference_bottom)-layout.reference_bottom)
            result[i]={text=text,span=1+extra/line_height,width=ink_width}
        end
        -- Bound live numeric variants without clearing all cached rows on scroll.
        if layout.cache_count >= 512 then layout.wraps[next(layout.wraps)] = nil
        else layout.cache_count = layout.cache_count + 1 end
        layout.wraps[cache_key] = result
        return result
    end
    if not sections then sections = {{title=i18n.t('播放信息'), unpack(stats)}} end
    local data = {{}, {}}
    -- Match uosc menu text; values share one tone, labels use its foreground.
    local body_color = o.font_color ~= '' and o.font_color or 'F6F0E8'
    local function field(row)
        -- Split only the first displayed field. Keep all following ASS tags,
        -- graphs, inline fields and values intact, with a shared value column.
        local head, tail = row:match('^(.-:)(.*)$')
        local zh, ztail = row:match('^(.-：)(.*)$')
        if zh and (not head or #zh<#head) then head,tail=zh,ztail end
        if not head then return nil,row end
        local label=head:gsub('%b{}',''):gsub('\\h',' '):match('^%s*(.-)%s*$')
        if #label>60 or label:find('[\\/]') then return nil,row end
        tail=tail:gsub('^({\\b0})',''):gsub('^(\\h)+',''):gsub('^%s+','')
        -- Lua patterns cannot repeat a capture; consume ASS spacing directly.
        while tail:sub(1,2)=='\\h' do tail=tail:sub(3) end
        return label,tail
    end
    local function add_section(section, column)
        local body = convert_osd_ass_controls(table.concat(section))
        local value_rows = {}
        for _,row in ipairs(section.overview_value_rows or {}) do
            value_rows[convert_osd_ass_controls(row)] = true
        end
        local rows = split(body,o.nl,true)
        local target = data[column]
        local nonempty = false
        for _,row in ipairs(rows) do
            if row:gsub('%b{}',''):gsub('\\h',''):match('%S') then nonempty=true; break end
        end
        if not nonempty then return end
        if #target > 0 then
            target[#target+1] = {text='', spacer=true,
                span=max((h / dpi >= 720 and 1.15 or .9)+extra_bottom/line_height, (6*logical_pixel+panel_bottom+8*logical_pixel)/line_height)}
        end
        target[#target+1] = {text=section.title, heading=true,
            span=1.18+min(.5,(h / dpi >= 720 and 12 or 8)*logical_pixel/line_height)}
        for _,row in ipairs(rows) do
            if row:gsub('%b{}','') ~= '' then
                local label,value=field(row)
                local inset=(label or value_rows[row]) and label_width or 0
                if label and not layout.labels[label] then layout.labels[label]=measure(label) end
                if label and layout.labels[label]>label_width-size*.3 then
                    -- Long labels (e.g. Frame Timings) keep their own line.
                    target[#target+1]={text=label,label=label,value='',inset=0,span=1,width=layout.labels[label]}
                    label=nil;inset=label_width
                end
                for i,part in ipairs(wrap(label and value or (inset>0 and value or row),inset)) do
                    local visible_label=i==1 and label or nil
                    target[#target+1] = {text=(visible_label or '')..part.text,
                        label=visible_label,value=part.text,inset=inset,
                        span=part.span,width=part.width+inset}
                end
            end
        end
    end
    if columns == 2 then
        -- File and source video on the left, display and audio output on the
        -- right. Independent stacks use space without four rigid quadrants.
        add_section(sections[1],1); add_section(sections[3],1)
        add_section(sections[2],2); add_section(sections[4],2)
    else
        for _,section in ipairs(sections) do add_section(section,1) end
    end
    local page = pages[curr_page]
    page.render_scale = 1
    page.overview_font_size = size
    local total = max(#data[1],#data[2])
    local tallest=0
    for col=1,columns do
        local extent=0
        for _,row in ipairs(data[col]) do extent=extent+row.span*line_height end
        tallest=max(tallest,extent)
    end
    local origin_y = position_y
    local footer = stats_page_footer(size, total)
    local safe_bottom = stats_safe_bottom() - max(footer.height,footer.size*1.3)
        - footer.border - max(2,border_size*2)
    do
        -- Balance the complete overview inside the usable video area after
        -- the shared danmaku/dock insets. Cache this opening's anchor so live
        -- measurements and scrolling cannot move all four sections around.
        local dims = mp.get_property_native('osd-dimensions') or {}
        local pad_top = 6 * logical_pixel
        local region_top = max(position_y-pad_top, max(0,tonumber(dims.mt) or 0)*288/h)
        local region_bottom = min(safe_bottom,288-max(0,tonumber(dims.mb) or 0)*288/h)
        local anchor_key = table.concat({region_top,region_bottom,tostring(stats_danmaku_area()),
            mp.get_property('path','')},':')
        if not layout.anchor or layout.anchor.key ~= anchor_key then
            local footprint = tallest + pad_top + panel_bottom
            local balanced = region_top + (region_bottom-region_top-footprint)/2 + pad_top
            layout.anchor = {key=anchor_key,balanced=footprint<=region_bottom-region_top,y=footprint<=region_bottom-region_top
                and max(position_y,balanced) or position_y}
        end
        origin_y = layout.anchor.y
        layout.region = {top=region_top,bottom=region_bottom}
    end
    layout.origin_y = origin_y
    local available = (layout.anchor.balanced and layout.region.bottom or safe_bottom) - origin_y
        - (layout.anchor.balanced and panel_bottom or max(5,border_size*2,panel_bottom))
    page.max_offset=1
    for col=1,columns do
        local extent,first=0,#data[col]
        for i=#data[col],1,-1 do
            local step=data[col][i].span*line_height
            if extent+step>available and extent>0 then break end
            first,extent=i,extent+step
        end
        page.max_offset=max(page.max_offset,first)
    end
    page.offset = max(1,min(page.offset or 1,page.max_offset))
    page.visible_last, page.total_rows = page.offset,total
    layout.data, layout.capacity = data,math.floor(available/line_height)
    local output = {}
    -- Backgrounds follow section content, while the text grid stays fixed.
    -- Cache a rounded column envelope so live digits cannot make edges twitch.
    layout.panel_widths = {}
    overview_panels = {}
    for col=1,columns do
        local x = origin_x+(col-1)*(width+gap)
        local panel_width=width
        layout.panel_widths[col]=panel_width
        local panel
        local used=0
        for index=page.offset,#data[col] do
            local row = data[col][index]
            local step=row.span*line_height
            if used+step>available and index>page.offset then break end
            local y = origin_y+used
            used=used+step
            page.visible_last=max(page.visible_last,index)
            if row.spacer then
                panel=nil
            elseif row.text ~= '' then
                if not panel then
                    panel={x0=x,y0=y,x1=x+panel_width,y1=y+step,column=col,
                        pad_y=6*logical_pixel,pad_bottom=panel_bottom,heading=row.heading==true}
                    overview_panels[#overview_panels+1]=panel
                else panel.y1=y+step end
                local pos = format('{\\pos(%.4f,%.4f)}',x,y)
                -- 旧版外观：关闭主题色后标题与标签不再染色，继承 text_style 的 font_color。
                local heading_color = o.accent_colors and '\\1c&HFFF070&\\1a&H00&' or ''
                local label_color = o.accent_colors and '\\1c&HEDE7D8&' or ''
                local text = row.heading and
                    (format('{\\b1\\fs%.4f%s}',size*1.18,heading_color) .. mp.command_native({'escape-ass',row.text})) or row.text
                local base=style:gsub('\\pos%b()','')
                if row.heading then
                    output[#output+1]=base..pos..text
                else
                    if row.label then
                        output[#output+1]=base..pos..'{\\b0'..label_color..'}'..mp.command_native({'escape-ass',row.label})
                    end
                    if row.value and row.value~='' then
                        local value_pos=format('{\\pos(%.4f,%.4f)\\1c&H%s&}',x+(row.inset or 0),y,body_color)
                        output[#output+1]=base..value_pos..row.value
                    end
                end
            end
        end
    end
    return table.concat(output,'\n')
end


local function fit_stats_page(page, after_scroll)
    return pages[page].f(after_scroll)
end

local function trim_perf_line_prefix(line)
    if line:sub(1, #o.nl) == o.nl then
        line = line:sub(#o.nl + 1)
    end
    return convert_osd_ass_controls(line)
end

local function perf_page_style_at(x, y, size, scale_x)
    local style = text_style()
    local position_tag = "\\pos(" .. x .. "," .. y .. ")"
    local font_tag = "\\fs" .. size
    local scale_x_tag = "\\fscx" .. scale_x
    local position_replaced, font_replaced, scale_x_replaced
    style, position_replaced = style:gsub("\\pos%b()", position_tag, 1)
    style, font_replaced = style:gsub("\\fs[%d%.%-]+", font_tag, 1)
    style, scale_x_replaced = style:gsub("\\fscx[%d%.%-]+", scale_x_tag, 1)
    if position_replaced == 0 or font_replaced == 0 or scale_x_replaced == 0 then
        style = style .. "{" .. (position_replaced == 0 and "\\an7" .. position_tag or "")
            .. (font_replaced == 0 and font_tag or "")
            .. (scale_x_replaced == 0 and scale_x_tag or "") .. "}"
    end
    return style
end

-- Render page 0 in vertical columns. Entries fill the first column from top
-- to bottom before continuing in the next one, preserving their source order.
local function show_stats_background(overlay, panels, overlay_bounds)
    if not o.use_ass or not has_vo_window() then hide_stats_overlay(stats_background); return end
    -- 旧版外观：不画底板。这里只跳过绘制并清掉可能存在的旧底板，
    -- 统计项、布局居中、右上角版本徽标（独立图层）都不受影响。
    if not o.panel_background then hide_stats_overlay(stats_background); return end
    if not panels then
        -- Reuse libass bounds, including graphs and the performance columns.
        -- The submitting overlay already measures this content when it carries
        -- compute_bounds; only measure separately when no bounds are supplied.
        local b = overlay_bounds
        if not b or not b.x0 then
            stats_measure.res_x, stats_measure.res_y = overlay.res_x, overlay.res_y
            stats_measure.data = overlay.data
            b = stats_measure:update()
        end
        panels = b and b.x0 and b.x1 and {{x0=b.x0,y0=b.y0,x1=b.x1,y1=b.y1}} or {}
    end
    local _,h=mp.get_osd_size()
    local pad=12*overlay.res_y/max(1,h)
    local radius=8*overlay.res_y/max(1,h)
    local events={}
    for _,b in ipairs(panels) do
        local pad_y=b.pad_y or pad
        local x0,y0=max(0,b.x0-pad),max(0,b.y0-pad_y)
        local x1,y1=min(overlay.res_x,b.x1+pad),min(overlay.res_y,b.y1+(b.pad_bottom or pad_y))
        local r=min(radius,(x1-x0)/2,(y1-y0)/2)
        local c=r*.55228475
        if x1>x0 and y1>y0 then
            events[#events+1]=format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H3A2410&\\1a&H33&\\p1}'
                ..'m %.3f %.3f l %.3f %.3f b %.3f %.3f %.3f %.3f %.3f %.3f '
                ..'l %.3f %.3f b %.3f %.3f %.3f %.3f %.3f %.3f '
                ..'l %.3f %.3f b %.3f %.3f %.3f %.3f %.3f %.3f '
                ..'l %.3f %.3f b %.3f %.3f %.3f %.3f %.3f %.3f{\\p0}',
                x0+r,y0,x1-r,y0,x1-r+c,y0,x1,y0+r-c,x1,y0+r,
                x1,y1-r,x1,y1-r+c,x1-r+c,y1,x1-r,y1,
                x0+r,y1,x0+r-c,y1,x0,y1-r+c,x0,y1-r,
                x0,y0+r,x0,y0+r-c,x0+r-c,y0,x0+r,y0)
        end
    end
    stats_background.res_x,stats_background.res_y=overlay.res_x,overlay.res_y
    stats_background.data=table.concat(events,'\n')
    submit_stats_overlay(stats_background)
end

local function render_perf_page_overlay()
    eval_ass_formatting()
    if not o.use_ass then
        return false
    end

    local osd_width, osd_height = mp.get_osd_size()
    if not osd_width or not osd_height or osd_width <= 0 or osd_height <= 0 then
        return false
    end

    local content = {}
    append_general_perfdata(content)

    local content_font_size = font_size

    local res_x = math.floor(PERF_PAGE_RES_Y * osd_width / osd_height + 0.5)
    local right_margin = max(position_x, content_font_size * 2.5, 6)
    local usable_width = max(1, res_x - position_x - right_margin)
    local max_columns = max(1, min(PERF_PAGE_MAX_COLUMNS,
        math.floor((usable_width + PERF_PAGE_COLUMN_GAP) /
            (PERF_PAGE_MIN_COLUMN_WIDTH + PERF_PAGE_COLUMN_GAP))))

    local content_y = position_y + max(font_size, content_font_size) * 1.35
    local bottom_margin = max(6, border_size * 2)
    local row_height = stats_line_height()
    local rows_per_column = max(1,
        math.floor((stats_safe_bottom() - content_y - bottom_margin) / row_height))
    local capacity = max_columns * rows_per_column
    local page = pages[o.key_page_0]
    local max_offset = max(1, #content - capacity + 1)
    local from = max(1, min((page.offset or 1), max_offset))
    local to = min(#content, from + capacity - 1)
    page.offset, page.max_offset = from, max_offset

    local visible_count = max(0, to - from + 1)
    local columns = max(1, min(max_columns,
        math.ceil(visible_count / rows_per_column)))
    local rows_in_column = max(1, math.ceil(visible_count / columns))
    local column_width = (usable_width - PERF_PAGE_COLUMN_GAP * (columns - 1)) / columns
    local content_scale_x = columns == 4 and PERF_PAGE_FOUR_COLUMN_FONT_SCALE_X or 100

    local header = {}
    add_header(header)
    local range_text
    if #content == 0 then
        range_text = format(i18n.t("%s：共 0 条"), page.desc)
    else
        local scroll_text = #content > capacity and i18n.t("（使用 UP/DOWN）") or ""
        range_text = format(i18n.t("%s：显示 %d–%d / 共 %d 条%s"),
            page.desc, from, to, #content, scroll_text)
    end
    append(header, "", {prefix=range_text, nl="", indent=""})

    local events = {convert_osd_ass_controls(table.concat(header))}
    for column = 1, columns do
        local first = from + (column - 1) * rows_in_column
        if first > to then
            break
        end

        local lines = {}
        local last = min(to, first + rows_in_column - 1)
        for i = first, last do
            lines[#lines + 1] = trim_perf_line_prefix(content[i])
        end

        local x = position_x + (column - 1) * (column_width + PERF_PAGE_COLUMN_GAP)
        local column_style = perf_page_style_at(x, content_y, content_font_size, content_scale_x)
        events[#events + 1] = column_style .. table.concat(lines, o.nl)
    end

    perf_page_overlay.res_x = res_x
    perf_page_overlay.res_y = PERF_PAGE_RES_Y
    perf_page_overlay.data = table.concat(events, "\n")
    perf_page_overlay.compute_bounds = o.panel_background
    local perf_bounds = submit_stats_overlay(perf_page_overlay)
    show_stats_background(perf_page_overlay, nil, perf_bounds)
    perf_page_overlay_visible = true
    return true
end

local function opt_time(t)
    if type(t) == type(1.1) then
        return mp.format_time(t)
    end
    return "?"
end

-- Returns an ASS string with stats about the demuxer cache etc.
local function cache_stats()
    local stats = {}

    eval_ass_formatting()
    add_header(stats)
    append(stats, "", {prefix="Cache Info:", nl="", indent=""})

    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then
        append(stats, "Unavailable.", {})
        return finalize_page({}, stats, false)
    end

    local a = info["reader-pts"]
    local b = info["cache-end"]

    append(stats, opt_time(a) .. " - " .. opt_time(b), {prefix = "Packet Queue:"})

    local r = nil
    if a ~= nil and b ~= nil then
        r = b - a
    end

    local r_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        r_graph = generate_graph(cache_ahead_buf, cache_ahead_buf.pos,
                                 cache_ahead_buf.len, cache_ahead_buf.max,
                                 nil, 0.8, 1)
        r_graph = o.prefix_sep .. r_graph
    end
    append(stats, opt_time(r), {prefix = "Readahead:", suffix = r_graph})

    -- These states are not necessarily exclusive. They're about potentially
    -- separate mechanisms, whose states may be decoupled.
    local state = "reading"
    local seek_ts = info["debug-seeking"]
    if seek_ts ~= nil then
        state = "seeking (to " .. mp.format_time(seek_ts) .. ")"
    elseif info["eof"] == true then
        state = "eof"
    elseif info["underrun"] then
        state = "underrun"
    elseif info["idle"]  == true then
        state = "inactive"
    end
    append(stats, state, {prefix = "State:"})

    local speed = info["raw-input-rate"] or 0
    local speed_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        speed_graph = generate_graph(cache_speed_buf, cache_speed_buf.pos,
                                     cache_speed_buf.len, cache_speed_buf.max,
                                     nil, 0.8, 1)
        speed_graph = o.prefix_sep .. speed_graph
    end
    append(stats, utils.format_bytes_humanized(speed) .. "/s", {prefix="Speed:",
        suffix=speed_graph})

    append(stats, utils.format_bytes_humanized(info["total-bytes"]),
           {prefix = "Total RAM:"})
    append(stats, utils.format_bytes_humanized(info["fw-bytes"]),
           {prefix = "Forward RAM:"})

    local fc = info["file-cache-bytes"]
    if fc ~= nil then
        fc = utils.format_bytes_humanized(fc)
    else
        fc = "(disabled)"
    end
    append(stats, fc, {prefix = "Disk Cache:"})

    append(stats, info["debug-low-level-seeks"], {prefix = "Media Seeks:"})
    append(stats, info["debug-byte-level-seeks"], {prefix = "Stream Seeks:"})

    append(stats, "", {prefix="Ranges:", nl=o.nl .. o.nl, indent=""})

    append(stats, info["bof-cached"] and "yes" or "no",
           {prefix = "Start Cached:"})
    append(stats, info["eof-cached"] and "yes" or "no",
           {prefix = "End Cached:"})

    local ranges = info["seekable-ranges"] or {}
    for n, range in ipairs(ranges) do
        append(stats, mp.format_time(range["start"]) .. " - " ..
                      mp.format_time(range["end"]),
               {prefix = "Range " .. n .. ":"})
    end

    return finalize_page({}, stats, false)
end

-- Record 1 sample of cache statistics.
-- (Unlike record_data(), this does not return a function, but runs directly.)
local function record_cache_stats()
    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then
        return
    end

    local a = info["reader-pts"]
    local b = info["cache-end"]
    if a ~= nil and b ~= nil then
        graph_add_value(cache_ahead_buf, b - a)
    end

    graph_add_value(cache_speed_buf, info["raw-input-rate"] or 0)
end

cache_recorder_timer = mp.add_periodic_timer(0.25, record_cache_stats)
cache_recorder_timer:kill()

-- Current page and <page key>:<page function> mapping
curr_page = o.key_page_1
pages = {
    [o.key_page_1] = { idx = 1, f = default_stats, desc = i18n.t("播放概览"), scroll = true },
    [o.key_page_2] = { idx = 2, f = vo_stats, desc = i18n.t("渲染步骤与耗时"), scroll = true },
    [o.key_page_3] = { idx = 3, f = cache_stats, desc = i18n.t("缓存统计"), scroll = true },
    [o.key_page_4] = { idx = 4, f = keybinding_info, desc = i18n.t("当前快捷键"), scroll = true },
    [o.key_page_5] = { idx = 5, f = track_info, desc = i18n.t("媒体轨道"), scroll = true },
    [o.key_page_6] = { idx = 6, f = troubleshooting_stats, desc = i18n.t("统计说明与排障"), scroll = true },
    [o.key_page_0] = { idx = 0, f = perf_stats, desc = i18n.t("内部性能信息"), scroll = true },
}


-- Returns a function to record vsratio/jitter with the specified `skip` value
local function record_data(skip)
    init_buffers()
    skip = max(skip, 0)
    local i = skip
    return function()
        if i < skip then
            i = i + 1
            return
        else
            i = 0
        end

        if o.plot_vsync_jitter then
            local r = mp.get_property_number("vsync-jitter")
            if r then
                vsjitter_buf.pos = (vsjitter_buf.pos % vsjitter_buf.len) + 1
                vsjitter_buf[vsjitter_buf.pos] = r
                vsjitter_buf.max = max(vsjitter_buf.max, r)
            end
        end

        if o.plot_vsync_ratio then
            local r = mp.get_property_number("vsync-ratio")
            if r then
                vsratio_buf.pos = (vsratio_buf.pos % vsratio_buf.len) + 1
                vsratio_buf[vsratio_buf.pos] = r
                vsratio_buf.max = max(vsratio_buf.max, r)
            end
        end
    end
end

-- Call the function for `page` and print it to OSD
local function print_page(page, after_scroll)
    -- Read the current geometry before the first visible submission. Property
    -- observers can still be queued when the opening key is handled.
    update_scale(true)
    -- the page functions assume we start in ass-enabled mode.
    -- that's true for mp.set_osd_ass, but not for mp.osd_message.
    eval_ass_formatting()
    if o.use_ass and overlay_submissions.fallback then
        if overlay_submissions.fallback == 'persistent' then mp.set_osd_ass(0, 0, '')
        else mp.osd_message('', 0) end
        overlay_submissions.fallback = nil
    end
    -- All pages and text fallbacks share visibility, including the dedicated
    -- performance overlay which returns before the ordinary ASS submission.
    publish_stats_visible(has_vo_window())
    if page == o.key_page_0 then
        overview_panels=nil
        show_release_badge()
        hide_stats_overlay(stats_overlay)
        hide_stats_overlay(stats_scroll_overlay)
        local was_visible = perf_page_overlay_visible
        if render_perf_page_overlay() then
            if not was_visible then
                if o.persistent_overlay then
                    mp.set_osd_ass(0, 0, "")
                else
                    mp.osd_message("", 0)
                end
            end
            return
        end
    end

    hide_perf_page_overlay()
    overview_panels = nil
    local ass_content = fit_stats_page(page, after_scroll)
    local scale = pages[page].render_scale or 1
    local compose = page==o.key_page_1 and overview_panels and scale==1
    local badge = show_release_badge(compose)
    if o.use_ass and has_vo_window() then
        local w, h = mp.get_osd_size()
        stats_overlay.res_x, stats_overlay.res_y = 288 * w / h / scale, 288 / scale
        stats_overlay.data = convert_osd_ass_controls(ass_content)
        stats_overlay.compute_bounds = o.panel_background and not (page==o.key_page_1 and overview_panels)
        if badge then stats_overlay.data = stats_overlay.data .. '\n' .. badge end
        local state = pages[page]
        local navigation_footer = o.auto_layout and state.idx~=0
            and not (o.custom_header and o.custom_header~='')
        local scrolling = (state.max_offset or 1) > 1
        if navigation_footer or (o.auto_layout and scrolling) then
            local footer_size=page==o.key_page_1 and state.overview_font_size
                and max(font_size*.75,state.overview_font_size*.8) or font_size*.75
            stats_scroll_overlay.res_x, stats_scroll_overlay.res_y = stats_overlay.res_x, 288
            local footer_style = text_style():gsub('\\pos%b()', ''):gsub('\\an%d', '')
            local footer_border = max(border_size,288/h)
            local footer_text = format('↑/↓  %d–%d / %d',
                state.offset or 1, state.visible_last or 1, state.total_rows or 1)
            local footer_bottom
            if navigation_footer then
                local footer = stats_page_footer(page==o.key_page_1 and state.overview_font_size or font_size,state.total_rows)
                footer_style,footer_size,footer_border = footer.style,footer.size,footer.border
                if footer.help_hint~='' then
                    footer_text=footer.help_hint .. (scrolling and footer.help_separator..footer_text or '')
                end
                footer_text = footer.navigation .. ((scrolling or footer.help_hint~='') and footer.separator .. footer_text or '')
                footer_bottom = scrolling and footer.scroll_bottom or footer.bottom
            else
                local footer_key = table.concat({w,h,footer_style,footer_size,footer_border}, ':')
                if overlay_submissions.footer_key ~= footer_key then
                    stats_measure.res_x, stats_measure.res_y = stats_overlay.res_x, 288
                    stats_measure.data = footer_style
                        .. format('{\\an1\\pos(0,0)\\fs%.2f\\bord%.3f}↑/↓  0123456789–0123456789 / 0123456789',
                            footer_size, footer_border)
                    local b = stats_measure:update()
                    overlay_submissions.footer_bottom = b and b.y1 or footer_size
                    overlay_submissions.footer_key = footer_key
                end
                footer_bottom = overlay_submissions.footer_bottom
            end
            stats_scroll_overlay.data = footer_style
                .. format('{%s\\an1\\pos(%.2f,%.2f)\\fs%.2f%s\\bord%.3f}%s',
                    navigation_footer and '\\q2' or '', position_x, stats_safe_bottom() - footer_border - footer_bottom,
                    footer_size, not navigation_footer and o.accent_colors and '\\1c&HFFF070&\\1a&H00&' or '',
                    footer_border, footer_text)
            if compose then
                hide_stats_overlay(stats_scroll_overlay)
                stats_overlay.data = stats_overlay.data .. '\n' .. stats_scroll_overlay.data
            else
                submit_stats_overlay(stats_scroll_overlay)
            end
        else
            hide_stats_overlay(stats_scroll_overlay)
        end
        local stats_bounds = submit_stats_overlay(stats_overlay)
        show_stats_background(stats_overlay, page==o.key_page_1 and overview_panels or nil,
            stats_bounds)
    elseif o.persistent_overlay then
        hide_stats_overlay(stats_overlay)
        hide_stats_overlay(stats_scroll_overlay)
        hide_stats_overlay(stats_background)
        overlay_submissions.fallback = 'persistent'
        mp.set_osd_ass(0, 0, ass_content)
    else
        hide_stats_overlay(stats_overlay)
        hide_stats_overlay(stats_scroll_overlay)
        hide_stats_overlay(stats_background)
        overlay_submissions.fallback = 'message'
        mp.osd_message((o.use_ass and ass_start or "") .. ass_content,
                       display_timer.oneshot and o.duration or o.redraw_delay + 1)
    end
end

update_scale = function (suppress_redraw)
    local scale_with_video
    if o.vidscale == "auto" then
        -- Automatic stats layout follows the viewport, independently of the
        -- user's generic OSD scaling option. Explicit vidscale=yes/no remains
        -- available for custom/manual layouts.
        scale_with_video = o.auto_layout or mp.get_property_native("osd-scale-by-window")
    else
        scale_with_video = o.vidscale == "yes"
    end

    -- Calculate scaled metrics.
    -- Make font_size=n the same size as --osd-font-size=n.
    local scale = 288 / 720
    local osd_height = mp.get_property_native("osd-height")
    if not scale_with_video and osd_height > 0 then
        scale = 288 / osd_height
    end
    local fullscreen = mp.get_property_native("fullscreen")
    local raw_font_size = fullscreen and o.font_size_fullscreen > 0
                          and o.font_size_fullscreen or o.font_size
    local raw_border_size = fullscreen and o.border_size_fullscreen > 0
                            and o.border_size_fullscreen or o.border_size
    local raw_position_x = fullscreen and o.position_x_fullscreen >= 0
                           and o.position_x_fullscreen or o.position_x
    local raw_position_y = fullscreen and o.position_y_fullscreen >= 0
                           and o.position_y_fullscreen or o.position_y

    font_size = raw_font_size * scale
    border_size = raw_border_size * scale
    shadow_x_offset = o.shadow_x_offset * scale
    shadow_y_offset = o.shadow_y_offset * scale
    position_x = raw_position_x * scale
    position_y = raw_position_y * scale
    if o.auto_layout then
        local margins = mp.get_property_native('user-data/osc/margins') or {}
        local has_uosc = mp.get_property_native('user-data/uosc/dock-animation-mode') ~= nil
        position_y = max(4, 288 * max(tonumber(margins.t) or 0, has_uosc and 0.055 or 0) + 3)
        local top = stats_danmaku_area()
        if top ~= nil and top > 0 then
            -- Large/fullscreen danmaku areas cannot consume the entire stats
            -- viewport. Keep a useful foreground view in that configuration.
            position_y = max(position_y, min(0.35, top) * 288 + 3)
        end
        if mp.get_property_number('osd-width', 0) < mp.get_property_number('osd-height', 0) * 1.2 then
            position_y = max(position_y, font_size * 2.2 + 4)
        end
    end
    plot_bg_border_width = o.plot_bg_border_width * scale
    local dims = mp.get_property_native('osd-dimensions') or {}
    local geometry_key = table.concat({dims.w or 0, dims.h or 0, dims.mt or 0,
        dims.mb or 0, dims.ml or 0, dims.mr or 0, font_size, border_size,
        shadow_x_offset, shadow_y_offset, position_x, position_y, plot_bg_border_width,
        mp.get_property_number('display-hidpi-scale', 1), stats_safe_bottom(),
        tostring(stats_danmaku_area())}, ':')
    local changed = overlay_submissions.geometry_key ~= geometry_key
    overlay_submissions.geometry_key = geometry_key
    if changed and suppress_redraw ~= true and display_timer:is_enabled() then
        print_page(curr_page)
    end
end

-- 底栏动画和鼠标移动会让 margins 与停靠模式连续变化，每次都同步重排会引发
-- 一串完整重绘和阻塞式测量。首次变化立即应用，随后的变化在短窗口内合并。
local scale_refresh_timer, scale_refresh_queued = nil, false
local function schedule_scale_refresh()
    if scale_refresh_timer then
        scale_refresh_queued = true
        return
    end
    update_scale()
    scale_refresh_timer = mp.add_timeout(0.15, function()
        scale_refresh_timer = nil
        if scale_refresh_queued then
            scale_refresh_queued = false
            schedule_scale_refresh()
        end
    end)
end

local function clear_screen()
    if overview_layout then overview_layout.anchor = nil end
    overview_panels = nil
    publish_stats_visible(false)
    publish_stats_toggled(false)
    hide_stats_overlay(stats_background)
    hide_stats_overlay(stats_overlay)
    hide_stats_overlay(stats_scroll_overlay)
    hide_perf_page_overlay()
    hide_stats_overlay(release_overlay)
    -- stats_measure is permanently hidden; retain its font and row caches.
    if overlay_submissions.fallback == 'persistent' then mp.set_osd_ass(0, 0, '')
    elseif overlay_submissions.fallback == 'message' then mp.osd_message('', 0) end
    overlay_submissions.fallback = nil
    if o.persistent_overlay then mp.set_osd_ass(0, 0, "") else mp.osd_message("", 0) end
    -- 通知外部（uosc 底栏「统计信息」按钮的高亮状态）面板已关闭。
    -- 这里是唯一的关闭出口（toggle 关闭 / oneshot 到期），所以放在这里不会漏。
    mp.set_property_bool('user-data/mpv-emo/stats-visible', false)
end

local function scroll_delta(d)
    if display_timer.oneshot then display_timer:kill() ; display_timer:resume() end
    local page = pages[curr_page]
    page.offset = max(1, min(page.max_offset or math.huge, (page.offset or 1) + d))
    print_page(curr_page, true)
end
local function scroll_up() scroll_delta(-o.scroll_lines) end
local function scroll_down() scroll_delta(o.scroll_lines) end

local function reset_scroll_offsets()
    overlay_submissions.help_page=1
    for _, page in pairs(pages) do
        page.offset = nil
    end
end
local function bind_scroll()
    if not scroll_bound then
        mp.add_forced_key_binding(o.key_scroll_up, "__forced_" .. o.key_scroll_up,
                                  scroll_up, {repeatable=true})
        mp.add_forced_key_binding(o.key_scroll_down, "__forced_" .. o.key_scroll_down,
                                  scroll_down, {repeatable=true})
        scroll_bound = true
    end
end
local function unbind_scroll()
    if scroll_bound then
        mp.remove_key_binding("__forced_"..o.key_scroll_up)
        mp.remove_key_binding("__forced_"..o.key_scroll_down)
        scroll_bound = false
    end
end

local add_page_bindings
local remove_page_bindings

local function filter_bindings()
    input.get({
        prompt = "Filter bindings:",
        opened = function ()
            -- This is necessary to close the console if the oneshot
            -- display_timer expires without typing anything.
            searched_text = ""

            -- Must be re-bound to override the console.lua bindings.
            remove_page_bindings()
            bind_scroll()
        end,
        edited = function (text)
            reset_scroll_offsets()
            searched_text = text:lower()
            print_page(curr_page)
            if display_timer.oneshot then
                display_timer:kill()
                display_timer:resume()
            end
        end,
        closed = function ()
            searched_text = nil
            if display_timer:is_enabled() then
                add_page_bindings()
                print_page(curr_page)
                if display_timer.oneshot then
                    display_timer:kill()
                    display_timer:resume()
                end
            end
        end,
    })
end

local function bind_search()
    mp.add_forced_key_binding(o.key_search, "__forced_"..o.key_search, filter_bindings)
end

local function unbind_search()
    mp.remove_key_binding("__forced_"..o.key_search)
end

local function bind_exit()
    -- Don't bind in oneshot mode because if ESC is pressed right when the stats
    -- stop being displayed, it would unintentionally trigger any user-defined
    -- ESC binding.
    if not display_timer.oneshot then
        mp.add_forced_key_binding(o.key_exit, "__forced_" .. o.key_exit, function ()
            process_key_binding(false)
        end)
    end
end

local function unbind_exit()
    mp.remove_key_binding("__forced_" .. o.key_exit)
end

local function bind_help_pages(k)
    mp.remove_key_binding('__stats_help_prev')
    mp.remove_key_binding('__stats_help_next')
    if k~=o.key_page_6 then return end
    local function change(delta)
        local next_page=max(1,min(4,overlay_submissions.help_page+delta))
        if next_page==overlay_submissions.help_page then return end
        overlay_submissions.help_page=next_page
        pages[o.key_page_6].offset=1
        print_page(o.key_page_6)
        if display_timer.oneshot then display_timer:kill();display_timer:resume() end
    end
    mp.add_forced_key_binding(o.key_help_prev,'__stats_help_prev',function()change(-1)end)
    mp.add_forced_key_binding(o.key_help_next,'__stats_help_next',function()change(1)end)
end

local function update_scroll_bindings(k)
    bind_help_pages(k)
    if pages[k].scroll then
        bind_scroll()
    else
        unbind_scroll()
    end

    if k == o.key_page_4 then
        bind_search()
    else
        unbind_search()
    end
end

-- Add keybindings for every page
add_page_bindings = function()
    local function a(k)
        return function()
            reset_scroll_offsets()
            update_scroll_bindings(k)
            curr_page = k
            print_page(k)
            if display_timer.oneshot then display_timer:kill() ; display_timer:resume() end
        end
    end
    for k, _ in pairs(pages) do
        mp.add_forced_key_binding(k, "__forced_"..k, a(k), {repeatable=true})
    end
    update_scroll_bindings(curr_page)
    bind_exit()
end


-- Remove keybindings for every page
remove_page_bindings = function()
    for k, _ in pairs(pages) do
        mp.remove_key_binding("__forced_"..k)
    end
    unbind_scroll()
    bind_help_pages(nil)
    unbind_search()
    unbind_exit()
end


process_key_binding = function(oneshot)
    reset_scroll_offsets()
    -- Stats are already being displayed
    if display_timer:is_enabled() then
        -- Public display-page-* bindings can change the current page while
        -- an existing display remains active. Keep page-specific keys in sync.
        if display_timer.oneshot or oneshot then update_scroll_bindings(curr_page) end
        -- Previous and current keys were oneshot -> restart timer
        if display_timer.oneshot and oneshot then
            display_timer:kill()
            print_page(curr_page)
            display_timer:resume()
        -- Previous key was oneshot, current key toggles -> keep it on screen
        elseif display_timer.oneshot and not oneshot then
            display_timer:kill()
            if o.plot_vsync_jitter or o.plot_vsync_ratio then
                recorder = record_data(o.skip_frames)
                mp.observe_property("vsync-jitter", "none", recorder)
            end
            if o.plot_tonemapping_lut then
                tm_viz_prev = mp.get_property_native("tone-mapping-visualize")
                mp.set_property_native("tone-mapping-visualize", true)
            end
            cache_ahead_buf = {0, pos = 1, len = 50, max = 0}
            cache_speed_buf = {0, pos = 1, len = 50, max = 0}
            cache_recorder_timer:resume()
            display_timer.oneshot = false
            display_timer.timeout = o.redraw_delay
            print_page(curr_page)
            display_timer:resume()
        -- Previous and current keys were toggling -> end toggling
        elseif not display_timer.oneshot and not oneshot then
            display_timer:kill()
            cache_recorder_timer:stop()
            if tm_viz_prev ~= nil then
                mp.set_property_native("tone-mapping-visualize", tm_viz_prev)
                tm_viz_prev = nil
            end
            clear_screen()
            remove_page_bindings()
            if recorder then
                mp.unobserve_property(recorder)
                recorder = nil
            end
        end
    -- No stats are being displayed yet
    else
        if not oneshot and (o.plot_vsync_jitter or o.plot_vsync_ratio) then
            recorder = record_data(o.skip_frames)
            -- Rely on the fact that "vsync-ratio" is updated at the same time.
            -- Using "none" to get a sample any time, even if it does not change.
            -- Will stop working if "vsync-jitter" property change notification
            -- changes, but it's fine for an internal script.
            mp.observe_property("vsync-jitter", "none", recorder)
        end
        if not oneshot and o.plot_tonemapping_lut then
            tm_viz_prev = mp.get_property_native("tone-mapping-visualize")
            mp.set_property_native("tone-mapping-visualize", true)
        end
        if not oneshot then
            cache_ahead_buf = {0, pos = 1, len = 50, max = 0}
            cache_speed_buf = {0, pos = 1, len = 50, max = 0}
            cache_recorder_timer:resume()
        end
        display_timer:kill()
        display_timer.oneshot = oneshot
        display_timer.timeout = oneshot and o.duration or o.redraw_delay
        add_page_bindings()
        print_page(curr_page)
        display_timer:resume()
        -- 面板已经画在屏幕上，通知外部按钮进入高亮态。
        mp.set_property_bool('user-data/mpv-emo/stats-visible', true)
    end
    publish_stats_toggled(display_timer:is_enabled() and not display_timer.oneshot)
end


-- Create the timer used for redrawing (toggling) or clearing the screen (oneshot)
-- The duration here is not important and always set in process_key_binding()
display_timer = mp.add_periodic_timer(o.duration,
    function()
        if display_timer.oneshot then
            display_timer:kill() ; clear_screen() ; remove_page_bindings()
            -- Close the console only if it was opened for searching bindings.
            if searched_text then
                input.terminate()
            end
        else
            print_page(curr_page)
        end
    end)
display_timer:kill()

-- Single invocation key binding
mp.add_key_binding(nil, "display-stats", function() process_key_binding(true) end,
    {repeatable=true})

-- Toggling key binding
mp.add_key_binding(nil, "display-stats-toggle", function() process_key_binding(false) end,
    {repeatable=false})

for k, page in pairs(pages) do
    -- Single invocation key bindings for specific pages, e.g.:
    -- "e script-binding stats/display-page-2"
    mp.add_key_binding(nil, "display-page-" .. page.idx, function()
        curr_page = k
        process_key_binding(true)
    end, {repeatable=true})

    -- Key bindings to toggle a specific page, e.g.:
    -- "h script-binding stats/display-page-4-toggle".
    mp.add_key_binding(nil, "display-page-" .. page.idx .. "-toggle", function()
        curr_page = k
        process_key_binding(false)
    end, {repeatable=false})
end

-- Reprint stats immediately when VO was reconfigured, only when toggled
mp.register_event("video-reconfig",
    function()
        if display_timer:is_enabled() and not display_timer.oneshot then
            print_page(curr_page)
        end
    end)

if o.bindlist ~= "no" then
    -- This is a special mode to print key bindings to the terminal,
    -- Adjust the print format and level to make it print only the key bindings.
    mp.set_property("msg-level", "all=no,statusline=status")
    mp.set_property("term-osd", "force")
    mp.set_property_bool("msg-module", false)
    mp.set_property_bool("msg-time", false)
    -- wait for all other scripts to finish init
    mp.add_timeout(0, function()
        if o.bindlist:sub(1, 1) == "-" then
            o.no_ass_b0 = ""
            o.no_ass_b1 = ""
        end
        o.ass_formatting = false
        o.no_ass_indent = " "
        mp.osd_message(keybinding_info(false, true))
        -- wait for next tick to print status line and flush it without clearing
        mp.add_timeout(0, function()
            mp.command("flush-status-line no")
            mp.command("quit")
        end)
    end)
end

mp.observe_property("osd-height", "native", update_scale)
mp.observe_property("osd-width", "native", update_scale)
mp.observe_property("display-hidpi-scale", "native", update_scale)
mp.observe_property('osd-dimensions', 'native', update_scale)
mp.observe_property("osd-scale-by-window", "native", update_scale)
mp.observe_property("fullscreen", "native", update_scale)
mp.observe_property('user-data/uosc_danmaku/has-danmaku', 'native', update_scale)
mp.observe_property('user-data/uosc_danmaku/layout', 'native', update_scale)
mp.observe_property('user-data/osc/margins', 'native', schedule_scale_refresh)
mp.observe_property('user-data/uosc/dock-animation-mode', 'native', schedule_scale_refresh)
mp.observe_property('user-data/startup-format-logos/visible', 'native', update_scale)

local function update_property_cache(name, value)
    property_cache[name] = value
end

mp.observe_property('current-window-scale', 'native', update_property_cache)
mp.observe_property('display-names', 'string', update_property_cache)
mp.observe_property('hwdec-current', 'string', update_property_cache)





-- ============================================================
-- 自动翻译模块 - 全局替换版（yosh.wang_20260712）（QQ交流群：1097053691）
-- ============================================================

-- 通用词汇翻译表
local function auto_translate_text(text)
    if i18n.is_english() then return text end
    if not text or type(text) ~= "string" then
        return text
    end
    
    local translations = {
        -- ==================== 页面标题 ====================
        ["Default"] = "播放概览",
        ["Extended Frame Timings"] = "渲染步骤与耗时",
        ["Cache Statistics"] = "缓存统计",
        ["Active Key Bindings"] = "当前快捷键",
        ["Tracks Info"] = "媒体轨道",
        ["Internal Performance Info"] = "内部性能信息",
        
        -- ==================== 文件/媒体信息 ====================
        ["File:"] = "文件：",
        ["Title:"] = "标题：",
        ["Duration:"] = "时长：",
        ["Edition:"] = "版本：",
        ["Chapter:"] = "章节：",
        ["Size:"] = "大小：",
        ["Format/Protocol:"] = "格式/协议：",
        ["Total Cache:"] = "总缓存：",
        [" sec)"] = " 秒）",
        [" sec"] = " 秒",
        [" fps (specified)"] = " fps（指定）",
        [" fps (estimated)"] = " fps（估计）",
        [" fps"] = " fps",
        [" Hz (specified)"] = " Hz（指定）",
        [" Hz (estimated)"] = " Hz（估计）",
        [" Hz"] = " Hz",
        [" kbps"] = " kbps",
        [" (specified)"] = "（指定）",
        [" (estimated)"] = "（估计）",
        
        -- ==================== 视频/显示器信息 ====================
        ["Display:"] = "显示器：",
        ["Context:"] = "渲染后端：",
        ["A-V:"] = "音视频同步：",
        ["Refresh Rate:"] = "刷新率：",
        ["Frame Rate:"] = "帧率：",
        ["Dropped Frames:"] = "丢帧：",
        [" (decoder)"] = "（解码器）",
        [" (output)"] = "（输出）",
        ["Deinterlacing:"] = "去隔行：",
        ["Resolution:"] = "分辨率：",
        ["Output Resolution:"] = "输出分辨率：",
        ["AI Inference:"] = "补帧推理：",
        ["Super Resolution:"] = "超分：",
        ["Format:"] = "格式：",
        ["Levels:"] = "色彩范围：",
        ["Chroma Loc:"] = "色度位置：",
        ["Colormatrix:"] = "色彩矩阵：",
        ["Primaries:"] = "色域基色：",
        ["Transfer:"] = "传输函数：",
        ["Bitrate:"] = "码率：",
        ["Filters:"] = "滤镜：",
        ["HW:"] = "硬解：",
        ["AO:"] = "音频输出：",
        ["Device:"] = "设备：",
        ["AO Volume:"] = "音量：",
        [" (Muted)"] = "（静音）",
        ["A-V delay:"] = "音视频延迟：",
        ["Channels:"] = "声道数：",
        ["Sample Rate:"] = "采样率：",
        
        -- ==================== 显示同步 ====================
        ["DS:"] = "显示同步：",
        ["Mistimed:"] = "错时帧：",
        ["Delayed:"] = "延迟帧：",
        ["VSync Ratio:"] = "垂直同步比率：",
        ["VSync Jitter:"] = "垂直同步抖动：",
        
        -- ==================== HDR相关 ====================
        ["Mastering display:"] = "母版显示：",
        ["MaxCLL:"] = "最大内容亮度：",
        ["MaxFALL:"] = "最大帧平均亮度：",
        ["MaxRGB:"] = "最大RGB：",
        ["Avg:"] = "平均：",
        [" cd/m²"] = " cd/m²",
        ["HDR10:"] = "HDR10：",
        ["HDR10+:"] = "HDR10+：",
        ["PQ(Y):"] = "PQ(Y)：",
        ["Max:"] = "最大：",
        -- ["in"] = "使用",   -- 不启用：模糊匹配会破坏包含 "in" 的英文单词（Container, Vision 等）
        
        -- ==================== 视频轨道信息 ====================
        ["Video:"] = "视频：",
        ["Audio:"] = "音频：",
        ["Image:"] = "图像：",
        ["Frame:"] = "帧：",
        ["Picture Type:"] = "画面类型：",
        ["Interlaced"] = "隔行扫描",
        ["Timecode:"] = "时间码：",
        ["GOP"] = "GOP",
        ["SMPTE"] = "SMPTE",
        ["Estimated SMPTE"] = "估计SMPTE",
        ["GOP Timecode:"] = "GOP时间码：",
        ["SMPTE Timecode:"] = "SMPTE时间码：",
        ["Estimated SMPTE Timecode:"] = "估计SMPTE时间码：",
        
        -- ==================== 帧耗时页面 ====================
        ["Frame Timings:"] = "帧耗时：",
        ["Total"] = "总计",
        ["(last/average/peak μs)"] = "（最新/平均/峰值 微秒）",
        
        -- ==================== 缓存信息 ====================
        ["Cache Info:"] = "缓存信息：",
        ["Packet Queue:"] = "数据包队列：",
        ["Readahead:"] = "预读：",
        ["State:"] = "状态：",
        ["reading"] = "读取中",
        ["eof"] = "文件尾",
        ["underrun"] = "缓存不足",
        ["inactive"] = "空闲",
        ["seeking"] = "定位中",
        ["Speed:"] = "速度：",
        ["Total RAM:"] = "总内存：",
        ["Forward RAM:"] = "前向内存：",
        ["Disk Cache:"] = "磁盘缓存：",
        ["(disabled)"] = "（已禁用）",
        ["Media Seeks:"] = "媒体定位：",
        ["Stream Seeks:"] = "流定位：",
        ["Ranges:"] = "范围：",
        ["Start Cached:"] = "起始已缓存：",
        ["End Cached:"] = "结尾已缓存：",
        ["Range "] = "范围 ",
        ["Unavailable."] = "不可用。",
        ["Unknown"] = "未知",
        ["yes"] = "是",
        ["no"] = "否",
        
        -- ==================== 按键绑定页面 ====================
        ["script: "] = "脚本：",
        ["[unknown]"] = "[未知]",
        ["Filter bindings:"] = "过滤绑定：",
        ["(hint: scroll with "] = "（提示：使用 ",
        [" and search with "] = " 滚动，使用 ",
        
        -- ==================== 轨道信息页面 ====================
        ["ID:"] = "ID：",
        ["Demuxer ID:"] = "解复用器ID：",
        ["Program ID:"] = "节目ID：",
        ["FFmpeg Index:"] = "FFmpeg索引：",
        ["Flags:"] = "标志：",
        ["Codec:"] = "编解码器：",
        ["Language:"] = "语言：",
        ["Channel Layout:"] = "声道布局：",
        ["HLS Bitrate:"] = "HLS码率：",
        ["Rotation:"] = "旋转：",
        ["Pixel Aspect Ratio:"] = "像素宽高比：",
        ["Replay Gain:"] = "重放增益：",
        ["Track:"] = "音轨：",
        ["Album:"] = "专辑：",
        ["Gain:"] = "增益：",
        ["Peak:"] = "峰值：",
        ["Dolby Vision:"] = "杜比视界：",
        ["Profile:"] = "配置文件：",
        ["Level:"] = "级别：",
        ["default"] = "默认",
        ["forced"] = "强制",
        ["dependent"] = "依赖",
        ["visual-impaired"] = "视觉障碍",
        ["hearing-impaired"] = "听觉障碍",
        ["original"] = "原始",
        ["commentary"] = "解说",
        ["albumart"] = "专辑封面",
        ["external"] = "外部",
        
        -- ==================== 滤镜相关 ====================
        [" (disabled)"] = "（已禁用）",
    }
    
    -- 精确匹配
    local result = translations[text]
    if result then
        return result
    end
    
    -- 模糊匹配（跳过过短的键，防止破坏包含短英文单词的文本）
    for en, zh in pairs(translations) do
        if #en >= 4 and text:find(en, 1, true) then
            text = text:gsub(en, zh, 1)
        end
    end
    
    return text
end

-- ==================== 性能标签翻译 ====================
local perf_translations = {
    ["poll-time"] = "轮询耗时",
    ["demuxer/thread"] = "解封装/线程",
    ["main/iterations"] = "主循环/单次",
    ["main/thread"] = "主循环/线程",
    ["osd/osd-render/cpu"] = "OSD渲染/CPU",
    ["osd/osd-render/time"] = "OSD渲染/总时",
    ["osd/sub-render/cpu"] = "字幕渲染/CPU",
    ["osd/sub-render/time"] = "字幕渲染/总时",
    ["vo/iterations"] = "视频输出/单次",
    ["vo/video-draw/cpu"] = "视频输出/绘制/CPU",
    ["vo/video-draw/time"] = "视频输出/绘制/总时",
    ["vo/video-flip/cpu"] = "视频输出/提交/CPU",
    ["vo/video-flip/time"] = "视频输出/提交/总时",
}

-- 保存原始函数
local original_append_general_perfdata = append_general_perfdata

-- 重写性能数据函数
append_general_perfdata = function(s)
    local perfdata = mp.get_property_native("perf-info") or {}
    for i, data in ipairs(perfdata) do
        local display_name = not i18n.is_english() and perf_translations[data.name] or nil
        if not display_name and data.name:match("^script/") then
            display_name = data.name:gsub("^script/", i18n.t("脚本/"))
        elseif not display_name then
            display_name = data.name
        end
        
        append(s, data.text or data.value,
            {prefix="["..format_perf_index(i, #perfdata).."] "..display_name.."："})

        if o.plot_perfdata and o.use_ass and data.value then
            local buf = perf_buffers[data.name]
            if not buf then
                buf = {0, pos = 1, len = 50, max = 0}
                perf_buffers[data.name] = buf
            end
            graph_add_value(buf, data.value)
            s[#s] = s[#s] .. generate_graph(buf, buf.pos, buf.len, buf.max, nil, 0.8, 1)
        end
    end
end

-- ==================== 重写核心翻译函数 ====================
-- 保存原始函数
local original_append = append
local original_append_property = append_property
local original_scroll_hint = scroll_hint
local original_cmd_subject = cmd_subject

-- 重写 append
append = function(s, str, attr)
    if str and type(str) == "string" then
        str = auto_translate_text(str)
    end
    if attr then
        if attr.prefix then
            attr.prefix = auto_translate_text(attr.prefix)
        end
        if attr.suffix then
            attr.suffix = auto_translate_text(attr.suffix)
        end
    end
    return original_append(s, str, attr)
end

-- 重写 append_property
append_property = function(s, prop, attr, excluded, cached)
    if attr then
        if attr.prefix then
            attr.prefix = auto_translate_text(attr.prefix)
        end
        if attr.suffix then
            attr.suffix = auto_translate_text(attr.suffix)
        end
    end
    return original_append_property(s, prop, attr, excluded, cached)
end

-- 重写 scroll_hint
scroll_hint = function(search)
    local hint = original_scroll_hint(search)
    return auto_translate_text(hint)
end

-- 重写 cmd_subject
cmd_subject = function(cmd)
    local result = original_cmd_subject(cmd)
    return auto_translate_text(result)
end

-- ==================== 翻译页面描述 ====================
for k, page in pairs(pages) do
    if page.desc then
        page.desc = auto_translate_text(page.desc)
    end
end

-- ============================================================
-- 自动翻译模块结束
-- ============================================================



-- ============================================================
-- 系统 CPU / GPU 占用率获取模块（yosh.wang_20260712）（QQ交流群：1097053691）
-- ============================================================

local cpu_usage = "N/A"
local gpu_usages = {}
local cpu_name = nil
local gpu_names = {}
local hw_detected = false
local stats_refresh_timer = nil
local update_counter = 0
local sys_lang = nil
local nvidia_smi_usage = nil  -- nvidia-smi 最新返回的数值，用于 LUID 归属识别
local cpu_update_pending = false
local gpu_update_pending = false
local native_system
if mp.get_property('platform') == 'windows' then
    local ok, provider = pcall(dofile, mp.find_config_file('script-modules/stats-system.lua') or '')
    if ok and type(provider)=='table' then native_system = provider end
end
local system_samples = {generation=0, requests={}}
local function native_sample(method)
    if not native_system or not native_system[method] then return nil, 'unavailable' end
    local ok, value, status = pcall(native_system[method])
    if ok then return value, status end
    -- A missing DLL symbol or driver failure must not kill the entire stats UI.
    mp.msg.warn('Native stats provider failed (' .. method .. '); using fallback')
    native_system[method] = nil
    return nil, 'unavailable'
end
local function reset_system_samples()
    system_samples.generation = system_samples.generation + 1
    local requests = system_samples.requests
    system_samples.requests = {}
    for request in pairs(requests) do mp.abort_async_command(request) end
    cpu_update_pending, gpu_update_pending = false, false
    if system_samples.start_timer then
        system_samples.start_timer:kill()
        system_samples.start_timer = nil
    end
    native_sample('reset')
end
mp.register_event('shutdown', function()
    reset_system_samples()
    native_sample('close')
end)

-- 异步执行系统命令
local function run_async(cmd_args, callback)
    return mp.command_native_async({
        name = "subprocess",
        args = cmd_args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res)
        if callback then
            callback(success and res and res.status == 0,
                res and (res.stdout or "") or "", res and (res.stderr or "") or "")
        end
    end)
end

-- Each visible session owns its fallback chain. Aborted or late completions
-- cannot start another process or overwrite a newer session's samples.
local function run_sample_async(cmd_args, callback)
    if not display_timer:is_enabled() then return end
    local generation = system_samples.generation
    local request, completed
    request = run_async(cmd_args, function(...)
        completed = true
        if request then system_samples.requests[request] = nil end
        if generation == system_samples.generation and display_timer:is_enabled() then
            callback(...)
        end
    end)
    if request and not completed then system_samples.requests[request] = true end
    return request
end

-- Persistent statistics already redraw on display_timer. Hardware providers
-- finish independently (CPU, NVIDIA and integrated GPU); forcing a complete
-- layout for every callback caused multiple blocking ASS measurements per tick.
-- Only the short-lived one-shot page needs a coalesced asynchronous refresh.
local hardware_redraw_timer
local function refresh_display()
    if not display_timer or not display_timer:is_enabled() or not curr_page
        or not display_timer.oneshot then return end
    if not hardware_redraw_timer then
        hardware_redraw_timer = mp.add_timeout(.1, function()
            if display_timer:is_enabled() and display_timer.oneshot and curr_page then
                print_page(curr_page, false)
            end
        end, true)
    end
    if not hardware_redraw_timer:is_enabled() then hardware_redraw_timer:resume() end
end

-- 检测系统语言（缓存结果）
local function detect_sys_lang(callback)
    if sys_lang then
        callback(sys_lang)
        return
    end
    run_sample_async({"typeperf", "-q", "Processor"}, function(success, stdout)
        if success and stdout:match("Processor") then
            sys_lang = "en"
            callback("en")
            return
        end
        run_sample_async({"typeperf", "-q", "处理器"}, function(success2, stdout2)
            if success2 and stdout2:match("处理器") then
                sys_lang = "zh"
                callback("zh")
                return
            end
            sys_lang = "en"
            callback("en")
        end)
    end)
end

-- 判断是否为虚拟 GPU
local function is_virtual_gpu(name)
    if not name then return true end
    local lower = name:lower()
    local virtual_keywords = {
        "virtual", "remote", "hyper-v", "hyperv", "microsoft basic",
        "basic render", "standard vga", "vms3d", "vmware", "virtualbox",
        "parallels", "citrix", "rdp", "wddm", "render only",
        "oray", "orayldd", "sunflower", "向日葵"
    }
    for _, kw in ipairs(virtual_keywords) do
        if lower:find(kw, 1, true) then
            return true
        end
    end
    return false
end

-- 判断是否为集显（iGPU）
local function is_integrated_gpu(name)
    if not name then return false end
    local lower = name:lower()
    -- NVIDIA 始终是独显
    if lower:find("nvidia", 1, true) or lower:find("geforce", 1, true)
       or lower:find("rtx", 1, true) or lower:find("gtx", 1, true) then
        return false
    end
    -- Intel Arc 是独显
    if lower:find("arc", 1, true) then return false end
    -- AMD Radeon RX 系列是独显；Radeon 带 M 后缀或 "Graphics" 是集显
    if lower:find("radeon", 1, true) then
        if lower:find("rx ", 1, true) then return false end
        return true
    end
    -- Intel UHD / Iris / HD Graphics 是集显
    if lower:find("uhd", 1, true) or lower:find("iris", 1, true)
       or lower:find("hd graphics", 1, true) then
        return true
    end
    return false
end

-- 检测 CPU / GPU 硬件型号（只检测一次，缓存结果）
-- 注意：wmic 在 Windows 11 中已被移除，优先使用 PowerShell Get-CimInstance
local function detect_hardware()
    if hw_detected then return end
    hw_detected = true

    local os_name = mp.get_property("platform", "unknown")
    if os_name ~= "windows" then return end

    -- CPU 型号：优先 CIM，备用注册表
    run_async({"powershell", "-NoProfile", "-Command",
               "(Get-CimInstance Win32_Processor).Name"}, function(success, stdout)
        if success then
            local name = stdout:match("^(.-)[\r\n]*$")
            if name and #name > 0 then
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                cpu_name = name
                refresh_display()
                return
            end
        end
        -- 备用：注册表
        run_async({"reg", "query", "HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "/v", "ProcessorNameString"}, function(success2, stdout2)
            if success2 then
                local name2 = stdout2:match("ProcessorNameString%s+REG_SZ%s+(.-)[\r\n]")
                if name2 and #name2 > 0 then
                    name2 = name2:gsub("^%s+", ""):gsub("%s+$", "")
                    cpu_name = name2
                    refresh_display()
                end
            end
        end)
    end)

    -- GPU 型号：优先 CIM（收集所有真实 GPU），备用注册表
    run_async({"powershell", "-NoProfile", "-Command",
               "Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name"}, function(success, stdout)
        local found = {}
        if success then
            for name in stdout:gmatch("[^\r\n]+") do
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if #name > 0 and not is_virtual_gpu(name) then
                    local dup = false
                    for _, n in ipairs(found) do
                        if n == name then dup = true; break end
                    end
                    if not dup then
                        table.insert(found, name)
                    end
                end
            end
        end
        if #found > 0 then
            gpu_names = found
            -- 排序：集显在前，独显在后
            table.sort(gpu_names, function(a, b)
                local a_int = is_integrated_gpu(a)
                local b_int = is_integrated_gpu(b)
                if a_int ~= b_int then return a_int end
                return false
            end)
            for _, n in ipairs(gpu_names) do
                gpu_usages[n] = "N/A"
            end
            refresh_display()
            return
        end
        -- 备用：注册表（遍历 0000、0001、0002... 检测所有 GPU）
        local reg_base = "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}"
        local found_reg = {}
        local function probe_reg_gpu(idx)
            local subkey = string.format("%04d", idx)
            run_async({"reg", "query", reg_base .. "\\" .. subkey, "/v", "DriverDesc"}, function(success3, stdout3)
                if success3 then
                    local name3 = stdout3:match("DriverDesc%s+REG_SZ%s+(.-)[\r\n]")
                    if name3 and #name3 > 0 then
                        name3 = name3:gsub("^%s+", ""):gsub("%s+$", "")
                        if #name3 > 0 and not is_virtual_gpu(name3) then
                            local dup = false
                            for _, n in ipairs(found_reg) do
                                if n == name3 then dup = true; break end
                            end
                            if not dup then
                                table.insert(found_reg, name3)
                            end
                        end
                        probe_reg_gpu(idx + 1)
                        return
                    end
                end
                if #found_reg > 0 then
                    gpu_names = found_reg
                    -- 排序：集显在前，独显在后
                    table.sort(gpu_names, function(a, b)
                        local a_int = is_integrated_gpu(a)
                        local b_int = is_integrated_gpu(b)
                        if a_int ~= b_int then return a_int end
                        return false
                    end)
                    for _, n in ipairs(gpu_names) do
                        gpu_usages[n] = "N/A"
                    end
                    refresh_display()
                end
            end)
        end
        probe_reg_gpu(0)
    end)
end

-- ============================================================
-- CPU 占用率获取（Windows）
-- ============================================================

-- 方案1：CIM（兼容 Windows 10+，wmic 在 Win11 中已移除）
local function update_cpu_cim(callback)
    if native_system then
        local load, status = native_sample('cpu')
        if load then callback(string.format('%.0f', load)); return end
        if status == 'warming' then callback(nil, true); return end
    end
    run_sample_async({"powershell", "-NoProfile", "-Command",
               "(Get-CimInstance Win32_Processor).LoadPercentage"}, function(success, stdout)
        if success then
            local load = stdout:match("(%d+)")
            if load and tonumber(load) and tonumber(load) <= 100 then
                callback(load)
                return
            end
        end
        callback(nil)
    end)
end

-- 方案2：typeperf（稳定，支持中英文）
local function update_cpu_typeperf(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\处理器(_Total)\\%% 处理器时间"
            or "\\Processor(_Total)\\%% Processor Time"
        run_sample_async({"typeperf", counter, "-sc", "1"}, function(success, stdout)
            if success then
                local load = stdout:match(",\"(%d+%.?%d*)\"")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load)
                    return
                end
            end
            -- 再试另一种语言
            local counter2 = lang == "zh"
                and "\\Processor(_Total)\\%% Processor Time"
                or "\\处理器(_Total)\\%% 处理器时间"
            run_sample_async({"typeperf", counter2, "-sc", "1"}, function(success2, stdout2)
                if success2 then
                    local load2 = stdout2:match(",\"(%d+%.?%d*)\"")
                    if load2 and tonumber(load2) and tonumber(load2) <= 100 then
                        callback(load2)
                        return
                    end
                end
                callback(nil)
            end)
        end)
    end)
end

-- 方案3：PowerShell Get-Counter（最后备选）
local function update_cpu_powershell(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\处理器(_Total)\\% 处理器时间"
            or "\\Processor(_Total)\\% Processor Time"
        run_sample_async({"powershell", "-NoProfile", "-Command",
            "Get-Counter '" .. counter .. "' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Select-Object -ExpandProperty CookedValue"
        }, function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load)
                    return
                end
            end
            callback(nil)
        end)
    end)
end

-- ============================================================
-- GPU 占用率获取（Windows）
-- ============================================================

-- 方案1：nvidia-smi（只支持 NVIDIA 显卡，最准确）
local function update_gpu_nvidia(callback)
    if native_system then
        local load = native_sample('nvidia')
        if load then callback(tostring(load)); return end
    end
    run_sample_async({"nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"}, function(success, stdout)
        if success then
            local load = stdout:match("(%d+)")
            if load and tonumber(load) and tonumber(load) <= 100 then
                callback(load)
                return
            end
        end
        callback(nil)
    end)
end

-- 方案2：CIM GPU 性能计数器（兼容性最好，与系统语言无关，支持多 GPU 分组）
-- wmic 在 Win11 中已移除，改用 PowerShell Get-CimInstance
local function update_gpu_cim(callback)
    if native_system then
        local engines, status = native_sample('gpu_engines')
        if engines then callback(engines); return end
        if status == 'warming' then callback(nil, true); return end
    end
    run_sample_async({"powershell", "-NoProfile", "-Command",
               "Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | ForEach-Object { Write-Output ($_.Name + '|' + $_.UtilizationPercentage) }"},
              function(success, stdout)
        if success then
            -- 返回所有引擎的原始数据（key=完整引擎名，value=利用率）
            local engines = {}
            for line in stdout:gmatch("[^\r\n]+") do
                local name, util = line:match("^(.-)|(%d+)$")
                if name and util then
                    local val = tonumber(util)
                    if val and val >= 0 and val <= 100 then
                        name = name:gsub("^%s+", ""):gsub("%s+$", "")
                        engines[name] = val
                    end
                end
            end
            if next(engines) then
                callback(engines)
                return
            end
        end
        callback(nil)
    end)
end

-- 方案3：typeperf GPU 引擎（支持中英文，支持多 GPU 分组）
-- typeperf CSV 输出：
--   行1（表头）: "\\COMPUTER\GPU Engine(pid_..._engtype_3D)\Utilization Percentage",...
--   行2（数据）: "07/12/2026 15:30:45.123","0.000","15.000",...
--   行3（收尾）: "Exiting..." / "退出代码..."
-- 需要按列位置匹配表头与数据（跳过第1列=时间戳）
local function parse_typeperf_engines(stdout)
    if not stdout then return nil end
    local lines = {}
    for line in stdout:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
        if #lines >= 2 then break end
    end
    if #lines < 2 then return nil end
    -- 解析表头列（完整计数器路径）
    local headers = {}
    for h in lines[1]:gmatch('"([^"]*)"') do
        headers[#headers + 1] = h
    end
    -- 解析数据列（第1列为时间戳）
    local values = {}
    for v in lines[2]:gmatch('"([^"]*)"') do
        values[#values + 1] = v
    end
    -- 按列位置匹配，跳过第1列（表头标签/数据时间戳）
    local engines = {}
    for i = 2, #headers do
        local path = headers[i]
        local val_str = values[i]
        if path and val_str then
            local val = tonumber(val_str)
            if val and val >= 0 and val <= 100 then
                local engine_name = path:match("GPU[Ee]ngine%(([^)]+)%)")
                if engine_name then
                    engines[engine_name] = val
                end
            end
        end
    end
    return next(engines) and engines or nil
end

local function update_gpu_typeperf(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\GPU 引擎(*)\\利用率百分比"
            or "\\GPU Engine(*)\\Utilization Percentage"
        run_sample_async({"typeperf", counter, "-sc", "1"}, function(success, stdout)
            if success then
                local engines = parse_typeperf_engines(stdout)
                if engines then
                    callback(engines)
                    return
                end
            end
            -- 再试另一种语言
            local counter2 = lang == "zh"
                and "\\GPU Engine(*)\\Utilization Percentage"
                or "\\GPU 引擎(*)\\利用率百分比"
            run_sample_async({"typeperf", counter2, "-sc", "1"}, function(success2, stdout2)
                if success2 then
                    local engines = parse_typeperf_engines(stdout2)
                    if engines then
                        callback(engines)
                        return
                    end
                end
                callback(nil)
            end)
        end)
    end)
end

-- 方案4：PowerShell Get-Counter（最后备选，单值）
local function update_gpu_powershell(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\GPU 引擎(*)\\利用率百分比"
            or "\\GPU Engine(*)\\Utilization Percentage"
        local ps_cmd = "Get-Counter '" .. counter .. "' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | ForEach-Object { $_.CookedValue } | Sort-Object -Descending | Select-Object -First 1"
        run_sample_async({"powershell", "-NoProfile", "-Command", ps_cmd}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load)
                    return
                end
            end
            callback(nil)
        end)
    end)
end

-- ============================================================
-- 统一入口
-- ============================================================

-- 判断是否为 NVIDIA 显卡
local function is_nvidia_gpu(name)
    if not name then return false end
    local lower = name:lower()
    return lower:find("nvidia", 1, true)
        or lower:find("geforce", 1, true)
        or lower:find("rtx", 1, true)
        or lower:find("gtx", 1, true)
end

-- 把分组数据应用到 gpu_usages（跳过 NVIDIA 显卡，N 卡数据以 nvidia-smi 为准）
-- 引擎名格式：pid_X_luid_0xLOW_0xHIGH_phys_Y_eng_Z_engtype_TYPE
-- 引擎名不含显卡名称，而是用 LUID 标识 GPU，因此按 LUID 分组
-- 通过 nvidia-smi 的值匹配找出 NVIDIA 的 LUID 并跳过，其余 LUID 分配给非 N 卡
local function apply_gpu_usage_map(gpu_map, fmt)
    if not gpu_map then return false end
    local updated = false
    -- 按 LUID 分组，收集每个 LUID 的引擎数据
    local luid_data = {}      -- luid -> { max_val=0, val_3d=0, has_3d=false, eng_types={} }
    local luid_order = {}     -- 保持 LUID 出现顺序
    for engine_name, util in pairs(gpu_map) do
        local luid = engine_name:match("luid_(0x%x+_0x%x+)") or "unknown"
        if not luid_data[luid] then
            luid_data[luid] = { max_val = 0, val_3d = 0, has_3d = false, eng_types = {} }
            luid_order[#luid_order + 1] = luid
        end
        local val = tonumber(util)
        if val and val >= 0 and val <= 100 then
            if val > luid_data[luid].max_val then
                luid_data[luid].max_val = val
            end
            -- 记录引擎类型（用于过滤虚拟显卡：虚拟显卡只有 3D 引擎）
            local etype = engine_name:match("engtype_(.+)$")
            if etype then luid_data[luid].eng_types[etype:lower()] = true end
            -- 检查是否是 3D 引擎（engtype_3D）
            if engine_name:lower():find("engtype_3d", 1, true) then
                if not luid_data[luid].has_3d or val > luid_data[luid].val_3d then
                    luid_data[luid].has_3d = true
                    luid_data[luid].val_3d = val
                end
            end
        end
    end
    -- 过滤虚拟显卡 LUID（只有 3D 引擎、没有其他引擎类型的 LUID）
    -- 如 OrayIddDriver 等间接显示驱动只有 engtype_3D 实例
    local filtered_order = {}
    for _, luid in ipairs(luid_order) do
        local types = luid_data[luid].eng_types
        local non_3d = false
        for t, _ in pairs(types) do
            if t ~= "3d" then non_3d = true; break end
        end
        if non_3d or not next(types) then
            filtered_order[#filtered_order + 1] = luid
        end
    end
    luid_order = filtered_order
    if #luid_order == 0 then return false end

    -- 计算每个 LUID 的代表利用率（优先 3D 引擎，否则取最大值）
    local luid_utils = {}
    for i, luid in ipairs(luid_order) do
        local d = luid_data[luid]
        luid_utils[i] = {
            luid = luid,
            util = d.has_3d and d.val_3d or d.max_val,
        }
    end

    -- 通过 nvidia-smi 值识别 NVIDIA 的 LUID（取差值最小的，容差 ±15）
    local nvidia_luid_idx = nil
    -- 参考值：优先使用本轮 nvidia-smi 值，其次使用上一轮残留的 N 卡利用率
    local nv_ref = nvidia_smi_usage
    if not nv_ref then
        for gpu_index, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) and gpu_usages[gname] then
                local prev = tonumber(gpu_usages[gname]:match("(%d+)"))
                if prev then
                    nv_ref = prev
                    break
                end
            end
        end
    end
    if nv_ref and #luid_utils > 1 then
        local nv_val = tonumber(nv_ref)
        if nv_val then
            local best_diff = math.huge
            for i, lu in ipairs(luid_utils) do
                local diff = math.abs(lu.util - nv_val)
                if diff < best_diff then
                    best_diff = diff
                    nvidia_luid_idx = i
                end
            end
            if best_diff > 15 then
                nvidia_luid_idx = nil
            end
        end
    end
    -- 单 N 卡系统兜底：只有 1 个 LUID 且有 NVIDIA 显卡时，直接将该 LUID 分配给 N 卡
    if not nvidia_luid_idx and #luid_utils == 1 then
        for gpu_index, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) then
                nvidia_luid_idx = 1
                break
            end
        end
    end
    -- 兜底：有 N 卡但没能通过值匹配识别 LUID 时，跳过利用率最高的 LUID
    -- （mpv 硬解通常在 N 卡上，负载高于集显）
    if not nvidia_luid_idx and #luid_utils > 1 then
        local has_nv = false
        for gpu_index, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) then has_nv = true; break end
        end
        if has_nv then
            local max_util = -1
            for i, lu in ipairs(luid_utils) do
                if lu.util > max_util then
                    max_util = lu.util
                    nvidia_luid_idx = i
                end
            end
        end
    end

    -- 收集非 NVIDIA 显卡名称（按检测顺序）
    local non_nv_names = {}
    for gpu_index, gname in ipairs(gpu_names) do
        if not is_nvidia_gpu(gname) then
            non_nv_names[#non_nv_names + 1] = gname
        end
    end

    -- 将非 NVIDIA 的 LUID 分配给非 N 卡（按顺序）
    local non_nv_idx = 1
    for i, lu in ipairs(luid_utils) do
        if i == nvidia_luid_idx then
            -- 跳过 NVIDIA LUID（已由 nvidia-smi 更新）
        else
            if non_nv_idx <= #non_nv_names then
                local gname = non_nv_names[non_nv_idx]
                gpu_usages[gname] = fmt and string.format(fmt, lu.util)
                                   or (tostring(lu.util) .. "%")
                updated = true
                non_nv_idx = non_nv_idx + 1
            elseif #gpu_names == 0 then
                -- 没检测到型号，记个总的
                gpu_usages["__total__"] = fmt and string.format(fmt, lu.util)
                                        or (tostring(lu.util) .. "%")
                updated = true
            end
        end
    end
    return updated
end

-- 获取 CPU 占用率
local function update_cpu(done)
    local os_name = mp.get_property("platform", "unknown")

    local function finish()
        refresh_display()
        if done then done() end
    end

    if os_name == "windows" then
        -- 优先级：CIM → typeperf → powershell
        update_cpu_cim(function(load, warming)
            if warming then finish(); return end
            if load then
                cpu_usage = load .. "%"
                finish()
            else
                update_cpu_typeperf(function(load2)
                    if load2 then
                        cpu_usage = string.format("%.0f%%", tonumber(load2))
                        finish()
                    else
                        update_cpu_powershell(function(load3)
                            if load3 then
                                cpu_usage = string.format("%.0f%%", tonumber(load3))
                            else
                                cpu_usage = "N/A"
                            end
                            finish()
                        end)
                    end
                end)
            end
        end)
    elseif os_name == "linux" then
        run_sample_async({"sh", "-c", "top -bn1 | grep 'Cpu(s)' | awk '{print $2}'"}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                if load then
                    cpu_usage = load .. "%"
                else
                    cpu_usage = "N/A"
                end
            else
                cpu_usage = "N/A"
            end
            finish()
        end)
    elseif os_name == "darwin" then
        run_sample_async({"ps", "-A", "-o", "%cpu"}, function(success, stdout)
            if success then
                local total = 0
                for line in stdout:gmatch("[^\r\n]+") do
                    local num = line:match("^(%d+%.?%d*)")
                    if num then total = total + tonumber(num) end
                end
                if total > 0 then
                    cpu_usage = string.format("%.1f%%", total)
                else
                    cpu_usage = "N/A"
                end
            else
                cpu_usage = "N/A"
            end
            finish()
        end)
    else
        finish()
    end
end

-- 获取 GPU 占用率（CIM → typeperf → powershell 完整回退链）
local function update_gpu_full_fallback(done)
    update_gpu_cim(function(result, warming)
        if warming then
            if done then done() end
            return
        end
        if result and type(result) == "table" then
            apply_gpu_usage_map(result, "%.0f%%")
            refresh_display()
            if done then done() end
        else
            update_gpu_typeperf(function(result2)
                if result2 and type(result2) == "table" then
                    apply_gpu_usage_map(result2, "%.0f%%")
                    refresh_display()
                    if done then done() end
                else
                    update_gpu_powershell(function(load4)
                        if load4 then
                            -- 单值兜底：只给还没有有效数据的 GPU 设置值，不覆盖已有数据
                            for gpu_index, gname in ipairs(gpu_names) do
                                if not gpu_usages[gname] or gpu_usages[gname] == "N/A" then
                                    gpu_usages[gname] = string.format("%.0f%%", tonumber(load4))
                                end
                            end
                            if #gpu_names == 0 then
                                gpu_usages["__total__"] = string.format("%.0f%%", tonumber(load4))
                            end
                        else
                            -- 失败时也只清空那些本来就是 N/A 的，不覆盖已有数据
                            for gpu_index, gname in ipairs(gpu_names) do
                                if not gpu_usages[gname] or gpu_usages[gname] == "N/A" then
                                    gpu_usages[gname] = "N/A"
                                end
                            end
                            if #gpu_names == 0 then
                                gpu_usages["__total__"] = "N/A"
                            end
                        end
                        refresh_display()
                        if done then done() end
                    end)
                end
            end)
        end
    end)
end

-- 获取 GPU 占用率
local function update_gpu(done)
    local os_name = mp.get_property("platform", "unknown")

    if os_name == "windows" then
        -- 先尝试 nvidia-smi（快，只更新 N 卡），然后继续完整回退链更新所有 GPU
        update_gpu_nvidia(function(load)
            if load then
                -- 记录 nvidia-smi 数值，供 apply_gpu_usage_map 做 LUID 归属识别
                nvidia_smi_usage = tonumber(load) or nil
                -- nvidia-smi 返回单值，找 NVIDIA 显卡分配
                local found_nv = false
                for gpu_index, gname in ipairs(gpu_names) do
                    if is_nvidia_gpu(gname) then
                        gpu_usages[gname] = load .. "%"
                        found_nv = true
                    end
                end
                if not found_nv and #gpu_names == 0 then
                    -- 没检测到型号，记个总的
                    gpu_usages["__total__"] = load .. "%"
                end
                refresh_display()
            else
                nvidia_smi_usage = nil
            end
            -- 无论 nvidia-smi 是否成功，都继续完整回退链，确保所有 GPU（含 Intel/AMD 集显）都有数据
            update_gpu_full_fallback(done)
        end)
    elseif os_name == "linux" then
        run_sample_async({"nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+)")
                if load then
                    gpu_usages["__total__"] = load .. "%"
                    refresh_display()
                    if done then done() end
                    return
                end
            end
            run_sample_async({"sh", "-c", "radeontop --dump - | grep 'gpu' | awk '{print $2}' | head -1"}, function(success2, stdout2)
                if success2 then
                    local load2 = stdout2:match("(%d+%.?%d*)")
                    if load2 then
                        gpu_usages["__total__"] = string.format("%.0f%%", tonumber(load2))
                        refresh_display()
                        if done then done() end
                        return
                    end
                end
                run_sample_async({"sh", "-c", "intel_gpu_top -J | grep 'render' | head -1 | awk '{print $2}'"}, function(success3, stdout3)
                    if success3 then
                        local load3 = stdout3:match("(%d+%.?%d*)")
                        if load3 then
                            gpu_usages["__total__"] = string.format("%.0f%%", tonumber(load3))
                        else
                            gpu_usages["__total__"] = "N/A"
                        end
                    else
                        gpu_usages["__total__"] = "N/A"
                    end
                    refresh_display()
                    if done then done() end
                end)
            end)
        end)
    elseif os_name == "darwin" then
        run_sample_async({"sh", "-c", "ioreg -l | grep PerformanceStatistics | grep GPU | head -1"}, function(success, stdout)
            if success then
                local load = stdout:match("GPU Activity Factor = (%d+)")
                if load then
                    gpu_usages["__total__"] = load .. "%"
                else
                    gpu_usages["__total__"] = "N/A"
                end
            else
                gpu_usages["__total__"] = "N/A"
            end
            refresh_display()
            if done then done() end
        end)
    else
        if done then done() end
    end
end

-- 刷新统计数据
local last_stats_sample = -math.huge
local function refresh_stats()
    if not display_timer:is_enabled() then return end
    local now = mp.get_time()
    if now - last_stats_sample < .9 then return end
    last_stats_sample = now
    update_counter = update_counter + 1
    if (update_counter == 1 or update_counter % 3 == 0) and not gpu_update_pending then
        gpu_update_pending = true
        update_gpu(function()
            gpu_update_pending = false
        end)
    end
    if not cpu_update_pending then
        cpu_update_pending = true
        update_cpu(function()
            cpu_update_pending = false
        end)
    end
end

-- 修改 add_file
local original_add_file = add_file
add_file = function(s, print_cache, print_tags)
    original_add_file(s, print_cache, print_tags)

    if not hw_detected then
        detect_hardware()
    end

    local function device_label(name)
        return tostring(name or ''):gsub('%([Rr]%)',''):gsub('%([Tt][Mm]%)','')
            :gsub('^%s*[Cc][Pp][Uu]:%s*',''):gsub('^%s*[Gg][Pp][Uu]:%s*','')
            :gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
    end
    -- 显示 CPU（占用率 + 型号，百分比右对齐到 4 字符以对齐后续标签，兼容 100%）
    local cpu_display = cpu_usage ~= "N/A" and cpu_usage or "--%"
    local cpu_line = "CPU: " .. string.format("%4s", cpu_display)
    if cpu_name then
        cpu_line = cpu_line .. "  " .. device_label(cpu_name)
    end
    append(s, cpu_line, {nl=o.nl, prefix="", prefix_sep=""})

    -- 显示 GPU（每个 GPU 一行）
    if #gpu_names > 0 then
        for gpu_index, gname in ipairs(gpu_names) do
            local gutil = gpu_usages[gname] or "N/A"
            local gpu_display = gutil ~= "N/A" and gutil or "--%"
            local gpu_line = "GPU" .. (#gpu_names>1 and " "..gpu_index or "") .. ": " .. string.format("%4s", gpu_display) .. "  " .. device_label(gname)
            append(s, gpu_line, {nl=o.nl, prefix="", prefix_sep=""})
        end
    elseif gpu_usages["__total__"] then
        local gpu_display = gpu_usages["__total__"] ~= "N/A" and gpu_usages["__total__"] or "--%"
        local gpu_line = "GPU: " .. string.format("%4s", gpu_display)
        append(s, gpu_line, {nl=o.nl, prefix="", prefix_sep=""})
    else
        append(s, "GPU: " .. string.format("%4s", "--%"), {nl=o.nl, prefix="", prefix_sep=""})
    end
end

-- 页面激活时启动定时器
local original_process_key_binding = process_key_binding
process_key_binding = function(oneshot)
    original_process_key_binding(oneshot)

    if display_timer and display_timer:is_enabled() then
        if not stats_refresh_timer then
            stats_refresh_timer = mp.add_periodic_timer(1.0, refresh_stats)
            local generation = system_samples.generation
            system_samples.start_timer = mp.add_timeout(0.1, function()
                system_samples.start_timer = nil
                if generation == system_samples.generation then refresh_stats() end
            end)
        end
    else
        if stats_refresh_timer then
            stats_refresh_timer:stop()
            stats_refresh_timer = nil
            update_counter = 0
        end
    end
end

-- 退出时清理
local original_remove_page_bindings = remove_page_bindings
remove_page_bindings = function()
    original_remove_page_bindings()
    reset_system_samples()
    if hardware_redraw_timer then hardware_redraw_timer:kill() end
    last_stats_sample = -math.huge
    if stats_refresh_timer then
        stats_refresh_timer:stop()
        stats_refresh_timer = nil
        update_counter = 0
    end
end

-- 文件切换时重置
mp.register_event('start-file', reset_system_samples)
mp.register_event("file-loaded", function()
    reset_system_samples()
    last_stats_sample = -math.huge
    cpu_usage = "N/A"
    for k, _ in pairs(gpu_usages) do
        gpu_usages[k] = "N/A"
    end
    update_counter = 0
end)

-- ============================================================
-- 系统统计模块结束
-- ============================================================
