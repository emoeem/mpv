local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

local o = {
    enabled = true,
    auto_skip = false,
    anime_skip = true,
    introdb = true,
    season_fallback = true,
    season_fallback_episode = 1,
    anime_skip_url = 'https://api.anime-skip.com/graphql',
    anime_skip_client_id = 'ZGfO0sMF3eCwLYf8yMSCJjlynwNGRXWE',
    introdb_url = 'https://api.theintrodb.org/v3/media',
    tmdb_api_url = 'https://api.tmdb.org/3',
    tmdb_api_key_base64 = 'NmJmYjIxOTZkNzIyN2UyMTIzMGM3Y2YzZjQ4MDNkZGM=',
    timeout = 12,
    lookup_delay = 1.0,
    cache_days = 30,
    negative_cache_hours = 12,
    duration_tolerance = 180,
    cache_path = '~~/files/skip-segments-cache.json',
    manual_templates_path = '~~/files/skip-segments-manual.json',
    manual_template_scope = 'series',
    manual_correction_window = 90,
    danmaku_history_path = '~~/files/danmaku-history.json',
    skip_intro = true,
    skip_outro = true,
    autoplay_loaded_file = true,
    show_osd = true,
}

options.read_options(o, 'skip_segments')

local cache_path = mp.command_native({'expand-path', o.cache_path})
local manual_templates_path = mp.command_native({'expand-path', o.manual_templates_path})
local danmaku_history_path = mp.command_native({'expand-path', o.danmaku_history_path})
local config_path = mp.command_native({'expand-path', '~~/script-opts/skip_segments.conf'})

local generation = 0
local active_ranges = {}
local original_chapters = {}
local inserted_titles = {}
local abort_requests = {}
local lookup_running = false
local on_time_pos
local lookup_status = 'idle'
local current_info
local add_range
local edit_active = false
local edit_kind
local edit_source
local edit_override = false
local edit_was_paused
local mark_overlay = mp.create_osd_overlay('ass-events')
local status_overlay = mp.create_osd_overlay('ass-events')
local mark_overlay_timer
local status_overlay_timer
local mark_overlay_text
local mark_overlay_persistent = false
mark_overlay.z = 2200
status_overlay.z = 2100

local function decode_base64(value)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local bits = tostring(value or ''):gsub('[^' .. alphabet .. '=]', ''):gsub('.', function(char)
        if char == '=' then return '' end
        local index = alphabet:find(char, 1, true)
        if not index then return '' end
        local number, result = index - 1, ''
        for bit_index = 5, 0, -1 do
            result = result .. (number % 2 ^ (bit_index + 1) >= 2 ^ bit_index and '1' or '0')
        end
        return result
    end)
    return bits:gsub('%d%d%d?%d?%d?%d?%d?%d?', function(byte)
        if #byte ~= 8 then return '' end
        local number = 0
        for index = 1, 8 do
            if byte:sub(index, index) == '1' then number = number + 2 ^ (8 - index) end
        end
        return string.char(number)
    end)
end

local function read_json(path)
    local file = io.open(path, 'rb')
    if not file then return {} end
    local content = file:read('*a')
    file:close()
    return utils.parse_json(content) or {}
end

local function write_json(path, value)
    local file = io.open(path, 'wb')
    if not file then
        msg.error('无法写入缓存：' .. tostring(path))
        return false
    end
    file:write(utils.format_json(value))
    file:close()
    return true
end

local function persist_option(name, value)
    local file = io.open(config_path, 'rb')
    local content = file and file:read('*a') or ''
    if file then file:close() end

    local serialized = type(value) == 'boolean' and (value and 'yes' or 'no') or tostring(value)
    local escaped_name = name:gsub('([^%w])', '%%%1')
    local replaced
    content, replaced = content:gsub(
        '^([ \t]*' .. escaped_name .. '[ \t]*=)[^\r\n]*',
        '%1' .. serialized,
        1
    )
    if replaced == 0 then
        content, replaced = content:gsub(
            '(\r?\n)([ \t]*' .. escaped_name .. '[ \t]*=)[^\r\n]*',
            '%1%2' .. serialized,
            1
        )
    end
    if replaced == 0 then
        local newline = content:find('\r\n', 1, true) and '\r\n' or '\n'
        if content ~= '' and not content:match('[\r\n]$') then content = content .. newline end
        content = content .. name .. '=' .. serialized .. newline
    end

    file = io.open(config_path, 'wb')
    if not file then
        msg.error('无法保存自动跳过设置：' .. tostring(config_path))
        return
    end
    file:write(content)
    file:close()
end

local function format_clock(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds / 60) % 60
    local secs = math.floor(seconds + 0.5) % 60
    if hours > 0 then return string.format('%d:%02d:%02d', hours, minutes, secs) end
    return string.format('%d:%02d', minutes, secs)
end

local function set_buttons()
    local enabled = o.auto_skip == true
    local count = #active_ranges
    local badge
    if lookup_status == 'loading' then
        badge = '…'
    elseif lookup_status == 'matched' then
        badge = tostring(count)
    elseif lookup_status == 'empty' or lookup_status == 'error' then
        badge = '0'
    end
    local status_text = ({
        idle = '等待加载视频',
        loading = '正在查询片头片尾',
        matched = string.format('已匹配 %d 个片段', count),
        empty = '当前视频没有可用片段数据',
        error = '片段查询失败',
    })[lookup_status] or ''
    local data = {
        icon = 'fast_forward',
        active = enabled,
        badge = badge,
        command = 'script-message-to skip_segments toggle-auto',
        tooltip = string.format(
            '自动跳过片头片尾：%s · %s',
            enabled and '开' or '关',
            status_text
        ),
    }
    mp.commandv('script-message-to', 'uosc', 'set-button', 'skip_segments', utils.format_json(data))

    local mark_data = {
        icon = edit_active and 'check' or 'content_cut',
        active = edit_active,
        command = edit_active
            and 'script-message-to skip_segments confirm-edit'
            or 'script-message-to skip_segments begin-edit',
        secondary_command = edit_active
            and 'script-message-to skip_segments cancel-edit'
            or 'script-message-to skip_segments undo-mark',
        tooltip = edit_active
            and '确认片头片尾范围 · 拖动两端手柄 · × 删除/忽略当前标记 · 右键取消'
            or '编辑片头片尾范围 · 右键删除本地/忽略网站标记',
    }
    mp.commandv(
        'script-message-to', 'uosc', 'set-button',
        'skip_segments_mark', utils.format_json(mark_data)
    )
    mp.set_property_bool('user-data/skip-segments/auto-skip', enabled)
end

local function set_edit_properties(active, kind, start_time, end_time, source, deletable)
    mp.set_property_bool('user-data/skip-segments/edit-active', active == true)
    mp.set_property('user-data/skip-segments/edit-kind', kind or '')
    mp.set_property('user-data/skip-segments/edit-source', source or '')
    mp.set_property_bool('user-data/skip-segments/edit-deletable', deletable == true)
    if start_time then
        mp.set_property_number('user-data/skip-segments/edit-start', start_time)
    end
    if end_time then
        mp.set_property_number('user-data/skip-segments/edit-end', end_time)
    end
end

local function show_message(text, duration)
    if not o.show_osd then return end
    if status_overlay_timer then
        status_overlay_timer:kill()
        status_overlay_timer = nil
    end

    local width, height = mp.get_osd_size()
    if not width or width <= 0 or not height or height <= 0 then
        mp.osd_message(text, duration or 2)
        return
    end
    local scale = mp.get_property_number('display-hidpi-scale', 1)
    local y = math.max(40, height - math.floor(148 * scale + 0.5))
    local escaped = tostring(text)
        :gsub('\\', '\\\\')
        :gsub('{', '\\{')
        :gsub('}', '\\}')
        :gsub('\n', '\\N')
    status_overlay.res_x = width
    status_overlay.res_y = height
    status_overlay.data = string.format(
        '{\\an2\\pos(%d,%d)\\fs%d\\b1\\c&HF2E655&\\3c&H221507&'
            .. '\\3a&H30&\\bord%d\\blur0.4\\shad0}%s',
        math.floor(width / 2),
        y,
        math.max(17, math.floor(17 * scale + 0.5)),
        math.max(2, math.floor(2.4 * scale + 0.5)),
        escaped
    )
    status_overlay:update()
    status_overlay_timer = mp.add_timeout(duration or 2, function()
        status_overlay.data = ''
        status_overlay:update()
        status_overlay_timer = nil
    end)
end

local function estimate_mark_text_width(text, font_size)
    local units = 0
    for char in tostring(text):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if #char == 1 then
            units = units + (char:match('%s') and 0.32 or 0.58)
        else
            units = units + 1
        end
    end
    return units * font_size
end

local function show_mark_message(text, duration, persistent)
    if not o.show_osd then return end
    if mark_overlay_timer then
        mark_overlay_timer:kill()
        mark_overlay_timer = nil
    end
    mark_overlay.z = 2200
    mark_overlay_text = text
    mark_overlay_persistent = persistent == true

    local width, height = mp.get_osd_size()
    if not width or width <= 0 or not height or height <= 0 then
        show_message(text, duration)
        return
    end
    local scale = mp.get_property_number('display-hidpi-scale', 1)
    -- Use 1280x720 as the design canvas and scale by the smaller axis, so the
    -- badge keeps the same visual proportion on 720p, 1080p, 2K, 4K and
    -- ultrawide displays. DPI remains a lower bound for high-density desktops.
    local canvas_scale = math.min(width / 1280, height / 720)
    local visual_scale = math.max(scale, canvas_scale)
    local bottom_offset = persistent and 168 or 112
    local y = math.max(
        math.floor(40 * visual_scale + 0.5),
        height - math.floor(bottom_offset * visual_scale + 0.5)
    )
    local escaped = tostring(text)
        :gsub('\\', '\\\\')
        :gsub('{', '\\{')
        :gsub('}', '\\}')
        :gsub('\n', '\\N')
    local styled_escaped = escaped
    if persistent then
        local heading, details = escaped:match('^(.-：)(.*)$')
        if heading then
            styled_escaped = '{\\b1\\c&HEDE7D8&}' .. heading
                .. '{\\b0\\c&HD0C8BA&}' .. details
        end
    end
    mark_overlay.res_x = width
    mark_overlay.res_y = height
    local font_size = math.max(18, math.floor(16 * visual_scale + 0.5))
    local horizontal_padding = math.floor(14 * visual_scale + 0.5)
    local vertical_padding = math.floor(5 * visual_scale + 0.5)
    local estimated_width = math.min(
        width - math.floor(40 * visual_scale),
        math.max(
            math.floor(250 * visual_scale),
            estimate_mark_text_width(text, font_size) + horizontal_padding * 2
        )
    )
    local capsule_height = font_size + vertical_padding * 2
    local capsule_left = math.floor((width - estimated_width) / 2)
    local capsule_top = math.floor(y - capsule_height)
    local capsule_right = capsule_left + estimated_width
    local capsule_bottom = y
    local capsule_center_y = math.floor((capsule_top + capsule_bottom) / 2)
    mark_overlay.data = string.format(
        -- Persistent editor mode badge: midnight-blue translucent capsule,
        -- ice-cyan border, and ice-white text.
        '{\\an7\\pos(0,0)\\p1\\bord1\\blur0.5\\1c&H221507&\\1a&H42&'
            .. '\\3c&HF2E655&\\3a&H68&}'
            .. 'm %d %d l %d %d l %d %d l %d %d'
            .. '{\\p0}\n'
            .. '{\\an5\\pos(%d,%d)\\fs%d\\b0\\c&HD0C8BA&\\3c&H221507&'
            .. '\\3a&H08&\\bord%d\\blur0.4\\shad0}%s',
        capsule_left, capsule_top,
        capsule_right, capsule_top,
        capsule_right, capsule_bottom,
        capsule_left, capsule_bottom,
        math.floor(width / 2),
        capsule_center_y,
        font_size,
        math.max(1, math.floor(1.0 * visual_scale + 0.5)),
        styled_escaped
    )
    mark_overlay:update()
    if not persistent then
        mark_overlay_timer = mp.add_timeout(duration or 3, function()
            mark_overlay.data = ''
            mark_overlay:update()
            mark_overlay_timer = nil
            mark_overlay_text = nil
            mark_overlay_persistent = false
        end)
    end
end

local function refresh_persistent_mark_overlay()
    if mark_overlay_persistent and mark_overlay_text then
        show_mark_message(mark_overlay_text, nil, true)
    end
end

local function abort_all_requests()
    for _, id in ipairs(abort_requests) do
        pcall(mp.abort_async_command, id)
    end
    abort_requests = {}
    lookup_running = false
end

local function curl_request(method, url, headers, body, callback, allow_http_errors)
    local args = {
        'curl', '-sS', '--location', '--max-time', tostring(o.timeout),
        '--ssl-no-revoke', '-X', method, url,
    }
    if not allow_http_errors then table.insert(args, 3, '--fail') end
    for key, value in pairs(headers or {}) do
        args[#args + 1] = '-H'
        args[#args + 1] = key .. ': ' .. value
    end
    if body then
        args[#args + 1] = '--data-binary'
        args[#args + 1] = utils.format_json(body)
    end

    local request_id
    request_id = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        for index, id in ipairs(abort_requests) do
            if id == request_id then
                table.remove(abort_requests, index)
                break
            end
        end
        if not success or not result or result.status ~= 0 then
            local detail = error or (result and result.stderr) or 'unknown error'
            callback('HTTP 请求失败：' .. tostring(detail), nil)
            return
        end
        local data = utils.parse_json(result.stdout or '')
        if not data then
            callback('接口返回了无效 JSON', nil)
            return
        end
        callback(nil, data)
    end)
    abort_requests[#abort_requests + 1] = request_id
end

local function graphql(query, variables, callback)
    curl_request('POST', o.anime_skip_url, {
        ['Content-Type'] = 'application/json',
        ['X-Client-ID'] = o.anime_skip_client_id,
    }, {query = query, variables = variables}, function(error, data)
        if error then return callback(error, nil) end
        if data.errors and data.errors[1] then
            return callback(data.errors[1].message or 'GraphQL 请求失败', nil)
        end
        callback(nil, data.data)
    end)
end

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function normalize_title(value)
    return trim(value):lower()
        :gsub('%b[]', ' ')
        :gsub('%b()', ' ')
        :gsub('%b{}', ' ')
        :gsub('[%._%-]+', ' ')
        :gsub('%s+', ' ')
end

local function title_tokens(value)
    local tokens = {}
    for token in normalize_title(value):gmatch('[%w\128-\255]+') do
        if #token > 1 and not token:match('^20%d%d$') then tokens[token] = true end
    end
    return tokens
end

local function title_score(left, right)
    local a, b = normalize_title(left), normalize_title(right)
    if a == '' or b == '' then return 0 end
    if a == b then return 1 end
    if a:find(b, 1, true) or b:find(a, 1, true) then return 0.9 end
    local at, bt = title_tokens(a), title_tokens(b)
    local intersection, union = 0, 0
    for token in pairs(at) do
        union = union + 1
        if bt[token] then intersection = intersection + 1 end
    end
    for token in pairs(bt) do if not at[token] then union = union + 1 end end
    return union > 0 and intersection / union or 0
end

local function clean_title(value)
    local title = tostring(value or '')
    title = title:gsub('%.[^%.\\/]+$', '')
    title = title:gsub('^%s*%b[]%s*', '')
    title = title:gsub('%s*%(%s*20%d%d%s*%)', ' ')
    title = title:gsub('%s*（%s*20%d%d%s*）', ' ')
    title = title:gsub('[Ss]%d+[%.%-%s:]?[Ee]%d+.*$', '')
    title = title:gsub('%d+[xX]%d+.*$', '')
    title = title:gsub('%s+%-%s+%d+[%s%._%-].*$', '')
    title = title:gsub('%s+%-%s+%d+$', '')
    title = title:gsub('第%s*%d+%s*[季部].*第%s*%d+%s*[话集回].*$', '')
    title = title:gsub('[%._]+', ' ')
    title = title:gsub('%b[]', ' '):gsub('%b{}', ' ')
    title = title:gsub('%s+', ' ')
    return trim(title)
end

local function parse_episode(value)
    local text = tostring(value or '')
    local season, episode = text:match('[Ss](%d+)[%.%-%s:]?[Ee](%d+)')
    if not episode then season, episode = text:match('(%d+)[xX](%d+)') end
    if not episode then
        season, episode = text:match('第%s*(%d+)%s*[季部].-第%s*(%d+)%s*[话集回]')
    end
    if not episode then episode = text:match('[^%a][Ee][Pp]?[%s%._%-]*(%d+)') end
    if not episode then episode = text:match('%s+%-%s+(%d+)%s*$') end
    return tonumber(season) or 1, tonumber(episode)
end

local function parent_directory(path)
    if not path or path:find('^%a[%w.+-]-://') then return nil end
    local dir = utils.split_path(path)
    return dir
end

local function find_history_title(path)
    local dir = parent_directory(path)
    if not dir then return nil end
    local history = read_json(danmaku_history_path)
    local candidates = {
        dir,
        dir:gsub('[\\/]$', ''),
        dir:gsub('[\\/]?$', package.config:sub(1, 1)),
    }
    for _, key in ipairs(candidates) do
        local item = history[key]
        if type(item) == 'table' and item.animeTitle then
            return clean_title(item.animeTitle)
        end
    end
end

local function metadata_id(names)
    local metadata = mp.get_property_native('metadata') or {}
    for key, value in pairs(metadata) do
        local lower = tostring(key):lower()
        for _, name in ipairs(names) do
            if lower == name then return tostring(value) end
        end
    end
end

local function unique_titles(values)
    local result, seen = {}, {}
    for _, value in ipairs(values) do
        local cleaned = clean_title(value)
        local key = normalize_title(cleaned)
        if cleaned ~= '' and not seen[key] then
            seen[key] = true
            result[#result + 1] = cleaned
        end
    end
    return result
end

local function media_info()
    local path = mp.get_property('path', '')
    local filename = mp.get_property('filename/no-ext', '')
    local media_title = mp.get_property('media-title', '')
    local parse_source = filename
    if path:find('^%a[%w.+-]-://') or filename == '' then parse_source = media_title end
    local season, episode = parse_episode(parse_source)
    if not episode then season, episode = parse_episode(media_title) end

    local dir = parent_directory(path)
    local parent_name = dir and dir:gsub('[\\/]$', ''):match('([^\\/]+)$') or nil
    local title_values = {}
    local function add_title(value)
        if value and value ~= '' then title_values[#title_values + 1] = value end
    end
    add_title(find_history_title(path))
    -- 网络流（AList）用目录名作主标题，跨集共享模板
    if path:find('^%a[%w.+-]-://') then
        add_title(parent_name)
        add_title(media_title)
    else
        add_title(media_title)
        add_title(parse_source)
        add_title(parent_name)
    end
    local titles = unique_titles(title_values)

    local all_text = table.concat({path, filename, media_title, parent_name or ''}, ' ')
    local year = tonumber(all_text:match('[^%d](20%d%d)[^%d]') or all_text:match('^(20%d%d)[^%d]'))
    local tmdb_id = all_text:match('[Tt][Mm][Dd][Bb][Ii][Dd][%s_%-:=]*(%d+)')
        or all_text:match('[Tt][Mm][Dd][Bb][%s_%-:=]*(%d+)')
        or metadata_id({'tmdb', 'tmdb_id', 'tmdbid'})
    local imdb_id = all_text:match('(tt%d+)')
        or metadata_id({'imdb', 'imdb_id', 'imdbid'})
    local duration = mp.get_property_number('duration', 0)

    return {
        path = path,
        titles = titles,
        season = season,
        episode = episode,
        tmdb_id = tmdb_id,
        imdb_id = imdb_id,
        duration = duration,
        year = year,
    }
end

local function range_key(info)
    return table.concat({
        normalize_title(info.titles[1] or info.path),
        tostring(info.season or ''),
        tostring(info.episode or ''),
        tostring(math.floor((info.duration or 0) / 5 + 0.5) * 5),
        tostring(info.tmdb_id or info.imdb_id or ''),
    }, '|')
end

local function manual_template_key(info)
    local parent_name = parent_directory(info.path)
    if not parent_name and info.path:find('^%a[%w.+-]-://') then
        parent_name = info.path:match('/([^/]+)/[^/]+%?') or info.path:match('/([^/]+)/[^/]+$')
    end
    if parent_name then parent_name = parent_name:gsub('[\\/]$', ''):match('([^\\/]+)$') or parent_name end
    local title = normalize_title(parent_name or info.titles[1] or '')
    if title == '' then title = normalize_title(info.path) end
    if o.manual_template_scope == 'season' then
        return title .. '|season:' .. tostring(info.season or 1)
    end
    return title
end

local function read_manual_templates()
    local data = read_json(manual_templates_path)
    if type(data) ~= 'table' or data.version ~= 1 or type(data.templates) ~= 'table' then
        return {version = 1, templates = {}}
    end
    return data
end

local function has_ignored_kinds(template)
    if type(template) ~= 'table' or type(template.ignored) ~= 'table' then return false end
    return template.ignored.intro == true or template.ignored.outro == true
end

local function manual_ignored_kinds(info)
    local data = read_manual_templates()
    local template = data.templates[manual_template_key(info)]
    local ignored = {}
    if type(template) == 'table' and type(template.ignored) == 'table' then
        ignored.intro = template.ignored.intro == true
        ignored.outro = template.ignored.outro == true
    end
    return ignored
end

local function manual_ranges(info)
    local data = read_manual_templates()
    local template_key = manual_template_key(info)
    local template = data.templates[template_key]
    if type(template) ~= 'table' then return {} end

    local ranges = {}
    if o.skip_intro and type(template.intro) == 'table' then
        add_range(
            ranges, 'intro',
            template.intro.start, template.intro['end'],
            'manual-template', template.intro.override and 100 or 1
        )
        if ranges[#ranges] then
            ranges[#ranges].template_key = template_key
            ranges[#ranges].override = template.intro.override == true
        end
    end
    if o.skip_outro and type(template.outro) == 'table' then
        local duration = tonumber(info.duration) or 0
        local end_from_end = tonumber(template.outro.end_from_end) or 0
        local end_time = duration - end_from_end
        if end_from_end < 0.05 then end_time = duration - 0.05 end
        add_range(
            ranges, 'outro',
            duration - (tonumber(template.outro.start_from_end) or 0),
            end_time,
            'manual-template', template.outro.override and 100 or 1
        )
        if ranges[#ranges] then
            ranges[#ranges].template_key = template_key
            ranges[#ranges].override = template.outro.override == true
        end
    end
    return ranges
end

local function save_manual_range(info, range)
    local data = read_manual_templates()
    local key = manual_template_key(info)
    if key == '' then return false end

    local template = data.templates[key] or {}
    template.title = info.titles[1] or ''
    template.scope = o.manual_template_scope
    template.updated_at = os.time()
    template.reference_duration = info.duration
    if type(template.ignored) == 'table' then
        template.ignored[range.kind] = nil
        if not has_ignored_kinds(template) then template.ignored = nil end
    end
    if range.kind == 'intro' then
        template.intro = {
            start = range.start,
            ['end'] = range['end'],
            override = range.override == true,
        }
    else
        template.outro = {
            start_from_end = info.duration - range.start,
            end_from_end = info.duration - range['end'],
            override = range.override == true,
        }
    end
    data.templates[key] = template
    return write_json(manual_templates_path, data)
end

local function remove_manual_range(info, kind, exact_key)
    local data = read_manual_templates()
    local key = exact_key or manual_template_key(info)
    local template = data.templates[key]
    if type(template) ~= 'table' or type(template[kind]) ~= 'table' then return false end
    template[kind] = nil
    template.updated_at = os.time()
    if not template.intro and not template.outro and not has_ignored_kinds(template) then
        data.templates[key] = nil
    end
    return write_json(manual_templates_path, data)
end

local function set_ignored_range(info, kind, ignored)
    if kind ~= 'intro' and kind ~= 'outro' then return false end
    local data = read_manual_templates()
    local key = manual_template_key(info)
    if key == '' then return false end

    local template = data.templates[key] or {}
    template.title = info.titles[1] or template.title or ''
    template.scope = o.manual_template_scope
    template.updated_at = os.time()
    template.reference_duration = info.duration
    template.ignored = type(template.ignored) == 'table' and template.ignored or {}
    template.ignored[kind] = ignored == true or nil
    if not has_ignored_kinds(template) then template.ignored = nil end

    if template.intro or template.outro or has_ignored_kinds(template) then
        data.templates[key] = template
    else
        data.templates[key] = nil
    end
    return write_json(manual_templates_path, data)
end

local function filter_ignored_remote_ranges(info, ranges)
    local ignored = manual_ignored_kinds(info)
    if not ignored.intro and not ignored.outro then return ranges or {} end

    local filtered = {}
    for _, range in ipairs(ranges or {}) do
        if range.source == 'manual-template' or not ignored[range.kind] then
            filtered[#filtered + 1] = range
        end
    end
    return filtered
end

local function valid_range(start_time, end_time, duration, kind, source)
    start_time, end_time = tonumber(start_time), tonumber(end_time)
    if not start_time or not end_time or end_time <= start_time then return false end
    if start_time < 0 or end_time > duration + 5 then return false end
    local length = end_time - start_time
    local max_length = source == 'manual-template' and kind == 'outro'
        and duration or 360
    return length >= 5 and length <= max_length
end

add_range = function(ranges, kind, start_time, end_time, source, priority)
    if not valid_range(
        start_time, end_time, mp.get_property_number('duration', 0), kind, source
    ) then return end
    ranges[#ranges + 1] = {
        kind = kind,
        start = start_time,
        ['end'] = end_time,
        source = source,
        priority = priority or 0,
    }
end

local function choose_ranges(ranges)
    table.sort(ranges, function(a, b)
        if a.kind == b.kind then return (a.priority or 0) > (b.priority or 0) end
        return a.start < b.start
    end)
    local chosen, has_kind = {}, {}
    for _, range in ipairs(ranges) do
        if not has_kind[range.kind] then
            has_kind[range.kind] = true
            chosen[#chosen + 1] = range
        end
    end
    table.sort(chosen, function(a, b) return a.start < b.start end)
    return chosen
end

local function is_autoskip_chapter_title(title)
    return tostring(title or ''):lower():find('^%[autoskip') ~= nil
end

local function get_chapters_without_inserted_ranges()
    local chapters = mp.get_property_native('chapter-list') or {}
    local kept = {}
    for _, chapter in ipairs(chapters) do
        if not inserted_titles[chapter.title] and not is_autoskip_chapter_title(chapter.title) then
            kept[#kept + 1] = chapter
        end
    end
    inserted_titles = {}
    return kept
end

local function remove_inserted_chapters()
    local kept = get_chapters_without_inserted_ranges()
    mp.set_property_native('chapter-list', kept)
end

local function sync_range_chapters()
    local chapters = get_chapters_without_inserted_ranges()
    if o.auto_skip then
        for index, range in ipairs(active_ranges) do
            local id = string.format('%d-%d-%d', generation, index, math.floor(range.start * 1000))
            local label = range.kind == 'intro' and 'Intro' or 'Outro'
            local source = range.source == 'manual-template' and 'manual' or 'website'
            local start_title = string.format('[AutoSkip:%s] %s Start (%s)', source, label, id)
            local end_title = string.format('[AutoSkip:%s] %s End (%s)', source, label, id)
            inserted_titles[start_title], inserted_titles[end_title] = true, true
            chapters[#chapters + 1] = {time = range.start, title = start_title}
            chapters[#chapters + 1] = {time = range['end'], title = end_title}
        end
    end

    table.sort(chapters, function(a, b)
        if a.time == b.time then return tostring(a.title or '') < tostring(b.title or '') end
        return a.time < b.time
    end)
    mp.set_property_native('chapter-list', chapters)
end

local function apply_ranges(ranges)
    active_ranges = {}

    for _, range in ipairs(ranges or {}) do
        active_ranges[#active_ranges + 1] = {
            kind = range.kind,
            start = range.start,
            ['end'] = range['end'],
            source = range.source,
            priority = range.priority or 0,
            template_key = range.template_key,
            override = range.override == true,
            skipped = false,
        }
    end

    sync_range_chapters()
    mp.set_property_number('user-data/skip-segments/count', #active_ranges)
    if #active_ranges > 0 then
        lookup_status = 'matched'
        msg.info(string.format('已加载 %d 个片头片尾片段', #active_ranges))
        if o.auto_skip then
            mp.add_timeout(0, function()
                on_time_pos(nil, mp.get_property_number('time-pos'))
            end)
        end
    else
        if lookup_status ~= 'error' then lookup_status = 'empty' end
    end
    set_buttons()
end

local function remove_active_range_now(source, kind)
    local kept = {}
    for _, range in ipairs(active_ranges) do
        local range_source = range.source == 'manual-template' and 'manual' or 'website'
        if not (range.kind == kind and range_source == source) then
            kept[#kept + 1] = range
        end
    end
    apply_ranges(kept)
end

local function without_autoskip_chapters(chapters)
    local kept = {}
    for _, chapter in ipairs(chapters or {}) do
        if not is_autoskip_chapter_title(chapter.title) then kept[#kept + 1] = chapter end
    end
    return kept
end

local function process_anime_timestamps(timestamps, duration)
    table.sort(timestamps, function(a, b) return (a.at or 0) < (b.at or 0) end)
    local ranges = {}
    for index, timestamp in ipairs(timestamps) do
        local name = timestamp.type and timestamp.type.name or ''
        local next_timestamp = timestamps[index + 1]
        local end_time = next_timestamp and next_timestamp.at or duration
        if (name == 'Intro' or name == 'New Intro') and o.skip_intro then
            add_range(ranges, 'intro', timestamp.at, end_time, 'anime-skip', 20)
        elseif (name == 'Credits' or name == 'New Credits') and o.skip_outro then
            add_range(ranges, 'outro', timestamp.at, end_time, 'anime-skip', 20)
        end
    end
    return ranges
end

local function query_anime_skip(info, callback)
    if not o.anime_skip or not info.episode or #info.titles == 0 then
        return callback(nil, {})
    end

    local search_query = [[
        query SearchShows($search: String!) {
            searchShows(search: $search, limit: 8) { id name }
        }
    ]]
    local episodes_query = [[
        query Episodes($showId: ID!) {
            findEpisodesByShowId(showId: $showId) {
                id season number absoluteNumber baseDuration name
            }
        }
    ]]
    local timestamps_query = [[
        query Timestamps($episodeId: ID!) {
            findTimestampsByEpisodeId(episodeId: $episodeId) {
                at type { name }
            }
        }
    ]]

    local searches, seen_searches = {}, {}
    local function add_search(query, match_title)
        local key = normalize_title(query)
        if key ~= '' and not seen_searches[key] then
            seen_searches[key] = true
            searches[#searches + 1] = {query = query, match_title = match_title}
        end
    end
    for _, title in ipairs(info.titles) do
        local first_word = title:match('^([%w]+)')
        if first_word and #first_word >= 4 then add_search(first_word, title) end
        add_search(title, title)
    end

    local title_index = 1
    local function try_title()
        local search = searches[title_index]
        if not search then return callback(nil, {}) end
        graphql(search_query, {search = search.query}, function(error, data)
            if error or not data or not data.searchShows or #data.searchShows == 0 then
                title_index = title_index + 1
                return try_title()
            end

            local best_show, best_score
            for _, show in ipairs(data.searchShows) do
                local score = title_score(search.match_title, show.name)
                if not best_score or score > best_score then
                    best_show, best_score = show, score
                end
            end
            if not best_show or best_score < 0.34 then
                title_index = title_index + 1
                return try_title()
            end

            graphql(episodes_query, {showId = best_show.id}, function(episode_error, episode_data)
                if episode_error or not episode_data then return callback(episode_error, {}) end
                local selected
                for _, episode in ipairs(episode_data.findEpisodesByShowId or {}) do
                    local same_season = tonumber(episode.season) == tonumber(info.season)
                    local same_episode = tonumber(episode.number) == tonumber(info.episode)
                    if same_season and same_episode then
                        selected = episode
                        break
                    end
                end
                if not selected then
                    for _, episode in ipairs(episode_data.findEpisodesByShowId or {}) do
                        if tonumber(episode.absoluteNumber) == tonumber(info.episode) then
                            selected = episode
                            break
                        end
                    end
                end
                if not selected then
                    title_index = title_index + 1
                    return try_title()
                end

                local base_duration = tonumber(selected.baseDuration)
                if base_duration and info.duration > 0
                    and math.abs(base_duration - info.duration) > o.duration_tolerance then
                    title_index = title_index + 1
                    return try_title()
                end
                graphql(timestamps_query, {episodeId = selected.id}, function(timestamp_error, timestamp_data)
                    if timestamp_error or not timestamp_data then return callback(timestamp_error, {}) end
                    local ranges = process_anime_timestamps(
                        timestamp_data.findTimestampsByEpisodeId or {},
                        info.duration
                    )
                    if #ranges == 0 then
                        title_index = title_index + 1
                        return try_title()
                    end
                    msg.info(string.format(
                        'Anime Skip 匹配：%s S%sE%s',
                        best_show.name, tostring(info.season), tostring(info.episode)
                    ))
                    callback(nil, ranges)
                end)
            end)
        end)
    end
    try_title()
end

local function url_encode(value)
    return tostring(value):gsub('([^%w%-_%.~])', function(char)
        return string.format('%%%02X', string.byte(char))
    end)
end

local function resolve_tmdb(info, callback)
    if info.tmdb_id or info.imdb_id or not info.titles[1] then
        return callback(nil, info)
    end
    local api_key = decode_base64(o.tmdb_api_key_base64)
    if api_key == '' then return callback(nil, info) end

    local title = info.titles[1]
    local url = string.format(
        '%s/search/tv?api_key=%s&query=%s&language=zh-CN&include_adult=false',
        o.tmdb_api_url, url_encode(api_key), url_encode(title)
    )
    curl_request('GET', url, {Accept = 'application/json'}, nil, function(error, data)
        if error or not data or type(data.results) ~= 'table' then
            return callback(error, info)
        end
        local best, best_score
        for _, result in ipairs(data.results) do
            local result_title = result.name or result.original_name or ''
            local score = title_score(title, result_title)
            local result_year = tonumber(tostring(result.first_air_date or ''):match('^(%d%d%d%d)'))
            if info.year and result_year == info.year then score = score + 0.25 end
            if not best_score or score > best_score then
                best, best_score = result, score
            end
        end
        if best and best.id and (best_score or 0) >= 0.5 then
            info.tmdb_id = tostring(best.id)
            msg.info(string.format(
                'TMDb 匹配：%s (%s) -> %s',
                best.name or best.original_name or title,
                tostring(best.first_air_date or ''):sub(1, 4),
                info.tmdb_id
            ))
        end
        callback(nil, info)
    end)
end

local function query_introdb(info, callback)
    if not o.introdb then
        return callback(nil, {})
    end
    resolve_tmdb(info, function(resolve_error, resolved_info)
        if resolve_error then msg.warn(resolve_error) end
        if not resolved_info.tmdb_id and not resolved_info.imdb_id then
            return callback(nil, {})
        end
        local function build_url(episode)
            local params = {}
            if resolved_info.tmdb_id then
                params[#params + 1] = 'tmdb_id=' .. url_encode(resolved_info.tmdb_id)
            else
                params[#params + 1] = 'imdb_id=' .. url_encode(resolved_info.imdb_id)
            end
            if resolved_info.season then
                params[#params + 1] = 'season=' .. tostring(resolved_info.season)
            end
            if episode then params[#params + 1] = 'episode=' .. tostring(episode) end
            if resolved_info.duration > 0 then
                params[#params + 1] = 'duration_ms=' .. tostring(math.floor(resolved_info.duration * 1000 + 0.5))
            end
            return o.introdb_url .. '?' .. table.concat(params, '&')
        end

        local function parse_ranges(data, source, priority)
            local ranges = {}
            if not data or data.error then return ranges end
            if o.skip_intro then
                for _, segment in ipairs(data.intro or {}) do
                    add_range(ranges, 'intro',
                        (tonumber(segment.start_ms) or 0) / 1000,
                        tonumber(segment.end_ms) and segment.end_ms / 1000 or nil,
                        source, priority)
                end
            end
            if o.skip_outro then
                for _, key in ipairs({'credits', 'preview'}) do
                    for _, segment in ipairs(data[key] or {}) do
                        add_range(ranges, 'outro',
                            tonumber(segment.start_ms) and segment.start_ms / 1000 or nil,
                            tonumber(segment.end_ms) and segment.end_ms / 1000 or resolved_info.duration,
                            source, key == 'credits' and priority or math.max(1, priority - 5))
                    end
                end
            end
            return ranges
        end

        curl_request('GET', build_url(resolved_info.episode), nil, nil, function(error, data)
            if error then return callback(error, {}) end
            local ranges = parse_ranges(data, 'theintrodb', 10)
            local fallback_episode = tonumber(o.season_fallback_episode) or 1
            if #ranges > 0 or not o.season_fallback
                or not resolved_info.episode or resolved_info.episode == fallback_episode then
                return callback(nil, ranges)
            end

            curl_request('GET', build_url(fallback_episode), nil, nil, function(fallback_error, fallback_data)
                if fallback_error then return callback(fallback_error, {}) end
                local fallback_ranges = parse_ranges(
                    fallback_data,
                    'theintrodb-season-fallback',
                    5
                )
                if #fallback_ranges > 0 then
                    msg.info(string.format(
                        'TheIntroDB 当前集无记录，使用 S%sE%s 作为同季片段模板',
                        tostring(resolved_info.season or 1),
                        tostring(fallback_episode)
                    ))
                end
                callback(nil, fallback_ranges)
            end, true)
        end, true)
    end)
end

local function save_cache(key, ranges)
    local cache = read_json(cache_path)
    cache[key] = {version = 2, saved_at = os.time(), ranges = ranges}
    write_json(cache_path, cache)
end

local function load_cache(key)
    local item = read_json(cache_path)[key]
    if type(item) ~= 'table' or item.version ~= 2 or type(item.ranges) ~= 'table' then return nil end
    local max_age
    if #item.ranges == 0 then
        max_age = math.max(0, tonumber(o.negative_cache_hours) or 0) * 3600
    else
        max_age = math.max(0, tonumber(o.cache_days) or 0) * 86400
    end
    if max_age > 0 and os.time() - (tonumber(item.saved_at) or 0) > max_age then return nil end
    return item.ranges
end

local function lookup()
    if not o.enabled or lookup_running then return end
    local info = media_info()
    current_info = info
    local manual = manual_ranges(info)
    if info.duration < 60
        or (#manual == 0 and not info.episode and not info.tmdb_id and not info.imdb_id) then
        msg.verbose('没有足够的剧集标识，跳过片头片尾查询')
        lookup_status = 'empty'
        set_buttons()
        return
    end

    local key = range_key(info)
    local cached = load_cache(key)
    if cached then
        local combined = {}
        for _, range in ipairs(manual) do combined[#combined + 1] = range end
        for _, range in ipairs(filter_ignored_remote_ranges(info, cached)) do
            combined[#combined + 1] = range
        end
        apply_ranges(choose_ranges(combined))
        return
    end

    if #manual > 0 then
        apply_ranges(choose_ranges(manual))
    end

    lookup_running = true
    lookup_status = 'loading'
    set_buttons()
    local current_generation = generation
    local pending, collected = 2, {}
    local had_error = false
    local function finish(error, ranges)
        if current_generation ~= generation then return end
        if error then
            had_error = true
            msg.warn(error)
        end
        for _, range in ipairs(ranges or {}) do collected[#collected + 1] = range end
        pending = pending - 1
        if pending > 0 then return end
        lookup_running = false
        local remote_chosen = choose_ranges(collected)
        save_cache(key, remote_chosen)
        local combined = {}
        for _, range in ipairs(manual) do combined[#combined + 1] = range end
        for _, range in ipairs(filter_ignored_remote_ranges(info, remote_chosen)) do
            combined[#combined + 1] = range
        end
        local chosen = choose_ranges(combined)
        if #chosen == 0 and had_error then lookup_status = 'error' end
        apply_ranges(chosen)
        if #chosen == 0 and o.auto_skip then
            show_message(had_error and '片头片尾查询失败' or '未找到片头片尾数据')
        end
    end

    query_anime_skip(info, finish)
    query_introdb(info, finish)
end

on_time_pos = function(_, position)
    if edit_active or not o.auto_skip or not position then
        return
    end
    for _, range in ipairs(active_ranges) do
        if not range.skipped and position >= range.start - 0.15 and position < range['end'] - 0.2 then
            range.skipped = true
            local label = range.kind == 'intro' and '片头' or '片尾'
            show_message('已自动跳过' .. label, 1.8)
            local duration = mp.get_property_number('duration', 0)
            if range.kind == 'outro' and range['end'] >= duration - 1 then
                local current_generation = generation
                local current_path = mp.get_property('path')
                mp.set_property_bool('pause', false)
                mp.command('script-binding uosc/next')
                mp.add_timeout(0.2, function()
                    if generation == current_generation
                        and mp.get_property('path') == current_path then
                        mp.commandv('seek', duration, 'absolute+exact')
                    end
                end)
            else
                mp.commandv('seek', range['end'] + 0.05, 'absolute+exact')
            end
            return
        end
    end
end

local function toggle_auto()
    o.auto_skip = not o.auto_skip
    persist_option('auto_skip', o.auto_skip)
    sync_range_chapters()
    set_buttons()
    show_message(o.auto_skip and '自动跳过片头片尾：开启' or '自动跳过片头片尾：关闭')
    if o.auto_skip then on_time_pos(nil, mp.get_property_number('time-pos')) end
end

local function refresh_current()
    abort_all_requests()
    lookup_running = false
    remove_inserted_chapters()
    active_ranges = {}
    lookup_status = 'idle'
    lookup()
end

local function cancel_edit(show_feedback)
    local restore_pause = edit_was_paused
    edit_active = false
    edit_kind = nil
    edit_source = nil
    edit_override = false
    edit_was_paused = nil
    set_edit_properties(false)
    if restore_pause ~= nil then mp.set_property_bool('pause', restore_pause) end
    set_buttons()
    mark_overlay.data = ''
    mark_overlay:update()
    mark_overlay_text = nil
    mark_overlay_persistent = false
    if show_feedback then show_mark_message('已取消片段编辑', 2) end
end

local function begin_edit()
    local info = current_info or media_info()
    local position = mp.get_property_number('time-pos')
    local is_alist = mp.get_property_bool('user-data/alist/playing', false)
    if not position or (not is_alist and (info.duration or 0) < 60) or (not is_alist and #info.titles == 0) then
        show_mark_message('当前视频无法编辑片头片尾', 2)
        return
    end

    local by_kind = {}
    for _, range in ipairs(active_ranges) do by_kind[range.kind] = range end
    local window = math.max(0, tonumber(o.manual_correction_window) or 90)
    local selected
    for _, range in ipairs(active_ranges) do
        if position >= range.start - window and position <= range['end'] + window then
            selected = range
            break
        end
    end
    local duration = mp.get_property_number('duration', 0) or info.duration or 0
    if not selected then
        edit_kind = position < duration / 2 and 'intro' or 'outro'
        if by_kind[edit_kind] then
            local range = by_kind[edit_kind]
            if position >= range.start - window and position <= range['end'] + window then
                selected = range
            end
        end
    end

    local start_time, end_time
    if selected then
        edit_kind = selected.kind
        edit_source = selected.source == 'manual-template' and 'manual' or 'website'
        edit_override = selected.source ~= 'manual-template' or selected.override == true
        start_time, end_time = selected.start, selected['end']
    else
        edit_source = nil
        edit_override = false
        start_time = position
        end_time = edit_kind == 'outro'
            and duration - 0.05
            or math.min(duration - 0.05, position + 90)
    end

    edit_active = true
    edit_was_paused = mp.get_property_bool('pause', false)
    mp.set_property_bool('pause', true)
    set_edit_properties(true, edit_kind, start_time, end_time, edit_source, selected ~= nil)
    set_buttons()
    show_mark_message(
        selected
            and '编辑片头片尾：拖动手柄 · × 删除/忽略 · ✓ 确认'
            or '编辑片头片尾：拖动手柄 · ✓ 确认 · 右键取消',
        nil,
        true
    )
end

local function confirm_edit()
    if not edit_active then return begin_edit() end
    local info = current_info or media_info()
    local duration = mp.get_property_number('duration', 0) or info.duration or 0
    local start_time = mp.get_property_number('user-data/skip-segments/edit-start')
    local end_time = mp.get_property_number('user-data/skip-segments/edit-end')
    if not start_time or not end_time or end_time - start_time < 1 then
        show_mark_message('范围无效：结束位置必须晚于开始位置', 3)
        return
    end

    local range = {
        kind = edit_kind,
        start = start_time,
        ['end'] = math.min(end_time, duration - 0.05),
        source = 'manual-template',
        priority = edit_override and 100 or 1,
        override = edit_override,
    }
    if not save_manual_range(info, range) then
        show_mark_message('本地片段纠错保存失败', 3)
        return
    end
    if not o.auto_skip then
        o.auto_skip = true
        persist_option('auto_skip', true)
    end

    local combined = {}
    for _, active in ipairs(active_ranges) do
        if active.kind ~= range.kind then combined[#combined + 1] = active end
    end
    combined[#combined + 1] = range
    apply_ranges(choose_ranges(combined))
    local corrected = edit_override
    local kind = edit_kind
    cancel_edit(false)
    show_mark_message(string.format(
        '%s%s范围已保存：%s–%s',
        corrected and '已纠正网站' or '本地',
        kind == 'outro' and '片尾' or '片头',
        format_clock(range.start),
        kind == 'outro' and '视频结尾' or format_clock(range['end'])
    ), 1.5)
end

local function undo_manual_mark()
    local info = current_info or media_info()
    local position = mp.get_property_number('time-pos', 0)
    local local_ranges = manual_ranges(info)
    local active_local_ranges = {}
    for _, range in ipairs(active_ranges) do
        if range.source == 'manual-template' then
            active_local_ranges[#active_local_ranges + 1] = range
        end
    end
    if #active_local_ranges > 0 then local_ranges = active_local_ranges end
    local kind
    local template_key
    if #local_ranges == 1 then
        kind = local_ranges[1].kind
        template_key = local_ranges[1].template_key
    else
        for _, range in ipairs(local_ranges) do
            if position >= range.start - 0.5 and position <= range['end'] + 0.5 then
                kind = range.kind
                template_key = range.template_key
                break
            end
        end
        if not kind then
            kind = position < (info.duration or 0) / 2 and 'intro' or 'outro'
        end
    end
    if remove_manual_range(info, kind, template_key) then
        show_mark_message(
            '已删除本剧的手动' .. (kind == 'intro' and '片头' or '片尾') .. '模板',
            2
        )
        refresh_current()
    else
        local ignored = manual_ignored_kinds(info)
        if ignored[kind] and set_ignored_range(info, kind, false) then
            show_mark_message(
                '已恢复网站' .. (kind == 'intro' and '片头' or '片尾') .. '标记',
                2
            )
            refresh_current()
            return
        end
        local website_range
        for _, range in ipairs(active_ranges) do
            if range.kind == kind and range.source ~= 'manual-template' then
                website_range = range
                break
            end
        end
        if website_range and set_ignored_range(info, kind, true) then
            show_mark_message(
                '已忽略网站' .. (kind == 'intro' and '片头' or '片尾') .. '标记',
                2
            )
            refresh_current()
        else
            show_mark_message('当前半段没有可撤销的本地标记', 2)
        end
    end
end

local function remove_range(source, kind, start_time, end_time)
    local info = current_info or media_info()
    kind = kind == 'outro' and 'outro' or 'intro'
    source = source == 'manual' and 'manual' or 'website'
    start_time = tonumber(start_time)
    end_time = tonumber(end_time)

    local best, best_score
    for _, range in ipairs(active_ranges) do
        local range_source = range.source == 'manual-template' and 'manual' or 'website'
        if range.kind == kind and range_source == source then
            local score = 0
            if start_time then score = score + math.abs((range.start or 0) - start_time) end
            if end_time then score = score + math.abs((range['end'] or 0) - end_time) end
            if not best_score or score < best_score then
                best, best_score = range, score
            end
        end
    end

    if not best then
        if source == 'website' then
            if set_ignored_range(info, kind, true) then
                cancel_edit(false)
                remove_active_range_now(source, kind)
                show_mark_message(
                    '已忽略网站' .. (kind == 'intro' and '片头' or '片尾') .. '标记',
                    2
                )
                refresh_current()
            else
                show_mark_message('网站标记忽略失败', 2)
            end
            return
        elseif source == 'manual' then
            if remove_manual_range(info, kind) then
                cancel_edit(false)
                remove_active_range_now(source, kind)
                show_mark_message(
                    '已删除手动' .. (kind == 'intro' and '片头' or '片尾') .. '标记',
                    2
                )
                refresh_current()
            else
                show_mark_message('手动标记删除失败', 2)
            end
            return
        end
        show_mark_message('没有找到要清除的片段标记', 2)
        return
    end

    if source == 'manual' then
        if remove_manual_range(info, kind, best.template_key) then
            cancel_edit(false)
            remove_active_range_now(source, kind)
            show_mark_message(
                '已删除手动' .. (kind == 'intro' and '片头' or '片尾') .. '标记',
                2
            )
            refresh_current()
        else
            show_mark_message('手动标记删除失败', 2)
        end
    else
        if set_ignored_range(info, kind, true) then
            cancel_edit(false)
            remove_active_range_now(source, kind)
            show_mark_message(
                '已忽略网站' .. (kind == 'intro' and '片头' or '片尾') .. '标记',
                2
            )
            refresh_current()
        else
            show_mark_message('网站标记忽略失败', 2)
        end
    end
end

mp.register_script_message('toggle-auto', toggle_auto)
mp.register_script_message('begin-edit', begin_edit)
mp.register_script_message('confirm-edit', confirm_edit)
mp.register_script_message('cancel-edit', function() cancel_edit(true) end)
mp.register_script_message('undo-mark', undo_manual_mark)
mp.register_script_message('remove-range', remove_range)
mp.register_script_message('refresh', refresh_current)
mp.register_script_message('uosc-version', set_buttons)

mp.observe_property('time-pos', 'number', on_time_pos)
mp.observe_property('osd-dimensions', 'native', function()
    if edit_active then mp.add_timeout(0, refresh_persistent_mark_overlay) end
end)
mp.observe_property('fullscreen', 'bool', function()
    if edit_active then mp.add_timeout(0, refresh_persistent_mark_overlay) end
end)
mp.observe_property('display-hidpi-scale', 'number', function()
    if edit_active then mp.add_timeout(0, refresh_persistent_mark_overlay) end
end)

mp.register_event('file-loaded', function()
    generation = generation + 1
    abort_all_requests()
    inserted_titles = {}
    active_ranges = {}
    lookup_status = 'idle'
    edit_active = false
    edit_kind = nil
    edit_source = nil
    edit_override = false
    edit_was_paused = nil
    set_edit_properties(false)
    current_info = nil
    original_chapters = without_autoskip_chapters(mp.get_property_native('chapter-list') or {})
    mp.set_property_number('user-data/skip-segments/count', 0)
    set_buttons()
    if o.autoplay_loaded_file then
        mp.add_timeout(0, function() mp.set_property_bool('pause', false) end)
    end
    mp.add_timeout(math.max(0, tonumber(o.lookup_delay) or 0.1), lookup)
end)

mp.add_hook('on_unload', 5, function()
    if edit_active and edit_was_paused ~= nil then
        mp.set_property_bool('pause', edit_was_paused)
    end
    generation = generation + 1
    abort_all_requests()
    active_ranges = {}
    inserted_titles = {}
    original_chapters = {}
    lookup_status = 'idle'
    edit_active = false
    edit_kind = nil
    edit_source = nil
    edit_override = false
    edit_was_paused = nil
    set_edit_properties(false)
    current_info = nil
    if mark_overlay_timer then
        mark_overlay_timer:kill()
        mark_overlay_timer = nil
    end
    mark_overlay.data = ''
    mark_overlay:update()
    mark_overlay_text = nil
    mark_overlay_persistent = false
    if status_overlay_timer then
        status_overlay_timer:kill()
        status_overlay_timer = nil
    end
    status_overlay.data = ''
    status_overlay:update()
    mp.set_property_number('user-data/skip-segments/count', 0)
    set_buttons()
end)

set_buttons()
mp.add_timeout(0.5, set_buttons)
