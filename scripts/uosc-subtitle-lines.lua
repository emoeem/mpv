local mp = require 'mp'
local utils = require 'mp.utils'

local MENU_TYPE = 'subtitle_lines'

local function format_time(time, duration)
    local format = math.max(time, duration) >= 60 * 60 and '%H:%M:%S' or '%M:%S'
    return mp.format_time(time, format)
end

local function add_item(items, text, start_time, duration)
    items[#items + 1] = {
        title = text ~= '' and text or '（空白字幕）',
        hint = format_time(start_time, duration),
        value = start_time,
    }
end

local function open_menu()
    local lines = mp.get_property_native('sub-lines')
    if type(lines) ~= 'table' or #lines == 0 then
        mp.osd_message('当前字幕无法读取字幕内容')
        return
    end

    local delay = mp.get_property_native('sub-delay') or 0
    local time_pos = (mp.get_property_native('time-pos') or 0) - delay
    local duration = mp.get_property_native('duration') or math.huge
    local items = {}
    local selected_index

    for _, line in ipairs(lines) do
        local start_time = tonumber(line.start) or 0
        if start_time <= time_pos then
            selected_index = #items + 1
        end

        local text = tostring(line.text or '')
        local has_text = false
        for part in text:gmatch('[^\r\n]+') do
            has_text = true
            add_item(items, part, start_time, duration)
        end
        if not has_text then
            add_item(items, '', start_time, duration)
        end
    end

    local menu = {
        type = MENU_TYPE,
        title = '字幕内容',
        search_style = 'on_demand',
        search_suggestion = '搜索字幕内容',
        fixed_columns = true,
        selected_index = selected_index or 1,
        callback = {mp.get_script_name(), 'menu-event'},
        items = items,
    }

    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
end

mp.register_script_message('open', open_menu)
mp.add_key_binding(nil, 'open', open_menu)

mp.register_script_message('menu-event', function(json)
    local event = utils.parse_json(json)
    if type(event) ~= 'table' or event.type ~= 'activate' or event.action then
        return
    end

    local target = tonumber(event.value)
    if not target then return end

    local delay = mp.get_property_native('sub-delay') or 0
    if mp.get_property_native('current-tracks/video/image') ~= false then
        delay = delay + 0.1
    end

    mp.commandv('seek', target + delay, 'absolute')
    mp.commandv('script-message-to', 'uosc', 'close-menu', MENU_TYPE)
end)
