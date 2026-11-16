-- 网络流下载速度徽标：demuxer-via-network 时经 uosc 底栏按钮显示 ↓ 速率。
-- 本地文件 / 无流量时自动隐藏；不依赖 alist_speed_indicator（其只覆盖 AList）。
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    update_interval = 1,  -- 刷新间隔（秒）
    min_speed = 10240,    -- 低于该字节数/秒视为无流量（10 KB/s）
}
options.read_options(o, 'network_speed')

local BUTTON_ID = 'network_speed'
local last_shown = nil  -- 上次发送的文本；nil 表示当前隐藏

local function format_speed(bytes)
    if bytes >= 1024 * 1024 * 1024 then
        return string.format('%.2f GB/s', bytes / 1024 ^ 3)
    elseif bytes >= 1024 * 1024 then
        return string.format('%.1f MB/s', bytes / 1024 ^ 2)
    elseif bytes >= 1024 then
        return string.format('%.0f KB/s', bytes / 1024)
    end
    return string.format('%.0f B/s', bytes)
end

local function set_button(json_text)
    mp.commandv('script-message-to', 'uosc', 'set-button', BUTTON_ID, json_text)
end

local function show(text)
    if last_shown == text then return end
    last_shown = text
    set_button(utils.format_json({
        title = text,
        tooltip = '下载速度',
        command = 'ignore',
    }))
end

local function hide()
    if last_shown == nil then return end
    last_shown = nil
    -- uosc 约定：传空串移除按钮。
    set_button('')
end

mp.add_periodic_timer(o.update_interval, function()
    local via_network = mp.get_property_bool('demuxer-via-network', false)
    local speed = via_network and mp.get_property_number('demuxer-cache-speed', 0) or 0
    if speed >= o.min_speed then
        show('↓ ' .. format_speed(speed))
    else
        hide()
    end
end)

mp.register_event('shutdown', hide)
