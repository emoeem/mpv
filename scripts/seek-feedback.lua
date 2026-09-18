local mp = require 'mp'

local uosc_options = {
    color = 'match=55E6F2'
}
local danmaku_options = {
    displayarea = 0.11,
    fontname = 'Microsoft YaHei',
    fontsize = 30,
    message_x = 30,
    message_y = 48,
}

local function read_selected_options(filename, target)
    local path = mp.command_native({'expand-path', '~~/script-opts/' .. filename})
    local file = path and io.open(path, 'r') or nil
    if not file then return end

    for line in file:lines() do
        if not line:match('^%s*#') then
            local key, value = line:match('^%s*([^=]+)%s*=%s*(.-)%s*$')
            if key and target[key] ~= nil then
                if type(target[key]) == 'number' then
                    target[key] = tonumber(value) or target[key]
                else
                    target[key] = value
                end
            end
        end
    end
    file:close()
end

read_selected_options('uosc.conf', uosc_options)
read_selected_options('uosc_danmaku.conf', danmaku_options)

local overlay = mp.create_osd_overlay('ass-events')
overlay.z = 3200

local visible = false
local accumulated = 0
local displayed_position = 0
local last_shown_at = 0
local reset_window = 0.65
local has_visible_danmaku = false
local danmaku_state_property = 'user-data/uosc_danmaku/has-danmaku'

local theme = {
    match = 'F2E655',
    outline = '160B04',
}

local function rgb_to_ass(value)
    if type(value) ~= 'string' then return nil end
    local rgb = value:match('^#?(%x%x%x%x%x%x)$')
    if not rgb then return nil end
    return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

for item in tostring(uosc_options.color):gmatch('[^,]+') do
    local name, value = item:match('^%s*([^=]+)%s*=%s*([^%s]+)%s*$')
    local converted = rgb_to_ass(value)
    if name and converted and theme[name] then
        theme[name] = converted
    end
end

local function stop_and_clear()
    visible = false
    accumulated = 0
    overlay:remove()
end

local hide_timer = mp.add_timeout(1.65, stop_and_clear)
hide_timer:kill()

local render
local sync_timer = mp.add_timeout(0.08, function()
    if not visible then return end
    displayed_position = mp.get_property_number('time-pos', displayed_position)
    render()
end)
sync_timer:kill()

local function format_delta(value)
    local absolute = math.abs(value)
    if absolute == math.floor(absolute) then
        return tostring(math.floor(absolute))
    end
    return string.format('%.2f', absolute):gsub('0+$', ''):gsub('%.$', '')
end

local function format_time(value)
    value = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
    local hours = math.floor(value / 3600)
    local minutes = math.floor(value % 3600 / 60)
    local seconds = value % 60
    if hours > 0 then
        return string.format('%d:%02d:%02d', hours, minutes, seconds)
    end
    return string.format('%02d:%02d', minutes, seconds)
end

local function get_danmaku_bottom(width, height)
    local ratio = width / math.max(1, height)
    local render_height = 1080
    local font_size = tonumber(danmaku_options.fontsize) or 30
    if 1920 / 1080 < ratio then
        render_height = 1920 / ratio
        font_size = font_size - ratio * 2
    end
    local line_height = math.max(1, font_size * height / render_height)
    return height * (tonumber(danmaku_options.displayarea) or 0.11) + line_height
end

render = function()
    if not visible then return end

    local width, height = mp.get_osd_size()
    if width <= 0 or height <= 0 then return end

    local dimensions = mp.get_property_native('osd-dimensions') or {}
    local dpi_scale = mp.get_property_number('display-hidpi-scale', 1)
    local canvas_scale = math.min(width / 1280, height / 720)
    local visual_scale = math.max(dpi_scale, canvas_scale)
    local fullscreen = mp.get_property_native('fullscreen') == true
    local compact_window = has_visible_danmaku and not fullscreen and height < 720
    local font_size = math.max(18, math.floor(17 * visual_scale + 0.5))
    local border = math.max(2, math.floor(2.4 * visual_scale + 0.5))
    local lane_gap = compact_window
        and math.max(5, math.floor(6 * math.max(0.75, canvas_scale) + 0.5))
        or math.max(6, math.floor(8 * visual_scale + 0.5))
    local picture_left = tonumber(dimensions.ml) or 0
    local picture_top = tonumber(dimensions.mt) or 0
    local left = math.floor((tonumber(danmaku_options.message_x) or 30) * visual_scale + 0.5)
    if fullscreen then
        left = math.max(left, math.floor(picture_left + lane_gap + 0.5))
    end
    local top
    if has_visible_danmaku then
        top = math.max(
            math.floor(picture_top + lane_gap + 0.5),
            math.floor(get_danmaku_bottom(width, height) + lane_gap + 0.5)
        )
    else
        top = math.max(
            math.floor(8 * visual_scale + 0.5),
            math.floor((tonumber(danmaku_options.message_y) or 48) * visual_scale + 0.5)
        )
    end

    local duration = mp.get_property_number('duration', 0)
    local position = math.max(0, displayed_position or 0)
    if duration > 0 then position = math.min(position, duration) end
    local percent = duration > 0 and math.max(0, math.min(100, position / duration * 100)) or 0
    local direction = accumulated >= 0 and '▶' or '◀'
    local delta_text = direction .. '  ' .. format_delta(accumulated) .. ' 秒'
    local progress_text = duration > 0 and string.format(
        '%s / %s  ·  %d%%', format_time(position), format_time(duration), math.floor(percent + 0.5)
    ) or format_time(position)

    local text_x = math.floor(left + 0.5)
    local text_y = math.floor(top + 0.5)

    overlay.res_x = width
    overlay.res_y = height
    overlay.data = string.format(
        '{\\an7\\pos(%d,%d)\\fn%s\\fs%d\\fsp0\\b1\\bord%d\\blur0.35\\shad0\\1c&H%s&\\3c&H%s&}' ..
        '%s  ·  %s',
        text_x, text_y, tostring(danmaku_options.fontname), font_size, border,
        theme.match, theme.outline, delta_text, progress_text
    )
    overlay:update()
end

local function show(delta)
    delta = tonumber(delta)
    if not delta or delta == 0 then return end

    local now = mp.get_time()
    if visible and now - last_shown_at <= reset_window and accumulated * delta > 0 then
        accumulated = accumulated + delta
    else
        accumulated = delta
    end

    displayed_position = mp.get_property_number('time-pos', displayed_position)
    visible = true
    last_shown_at = now
    hide_timer:kill()
    hide_timer:resume()
    sync_timer:kill()
    sync_timer:resume()
    render()
end

mp.register_script_message('show', show)
mp.observe_property('osd-dimensions', 'native', render)
mp.observe_property(danmaku_state_property, 'bool', function(_, value)
    has_visible_danmaku = value == true
    render()
end)
mp.register_event('playback-restart', function()
    if not visible then return end
    displayed_position = mp.get_property_number('time-pos', displayed_position)
    render()
end)
mp.register_event('start-file', function()
    has_visible_danmaku = false
    hide_timer:kill()
    sync_timer:kill()
    stop_and_clear()
end)
