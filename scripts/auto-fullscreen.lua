local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    enabled = false,
    delay = 0.08,
    show_osd = true,
}
options.read_options(o, 'auto_fullscreen')

local config_path = mp.command_native({
    'expand-path',
    '~~/script-opts/auto_fullscreen.conf',
})

local apply_timer = nil
local applied_for_file = false

local function normalize_bool(value)
    if value == true then return true end
    value = tostring(value or ''):lower()
    return value == 'yes' or value == 'true' or value == '1' or value == 'on'
end

local function normalize_number(value, default)
    value = tonumber(value)
    if not value or value < 0 then return default end
    return value
end

o.enabled = normalize_bool(o.enabled)
o.delay = normalize_number(o.delay, 0.08)
o.show_osd = normalize_bool(o.show_osd)

local function has_real_video()
    if mp.get_property_bool('idle-active', true) then return false end
    local vid = mp.get_property_native('vid')
    if not vid or vid == 'no' then return false end
    local track = mp.get_property_native('current-tracks/video')
    return not (track and track.albumart)
end

local function publish_state()
    mp.set_property('user-data/auto-fullscreen/enabled', o.enabled and 'yes' or 'no')
    mp.set_property('user-data/auto-fullscreen/label', o.enabled and '已开启' or '已关闭')
end

local function persist_config()
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('Failed to save auto fullscreen config: ' .. tostring(config_path))
        return false
    end
    file:write(
        '# Auto fullscreen on video start\n'
            .. '# yes: enter fullscreen when a real video starts.\n'
            .. '# no: keep the current window/fullscreen behavior.\n'
            .. string.format('enabled=%s\n\n', o.enabled and 'yes' or 'no')
            .. '# Delay value is in seconds. Usually no need to change it.\n'
            .. string.format('delay=%s\n', o.delay)
            .. string.format('show_osd=%s\n', o.show_osd and 'yes' or 'no')
    )
    file:close()
    return true
end

local function cancel_apply_timer()
    if apply_timer then
        apply_timer:kill()
        apply_timer = nil
    end
end

local function apply_fullscreen_once()
    apply_timer = nil
    if applied_for_file or not o.enabled or not has_real_video() then return end
    applied_for_file = true
    if not mp.get_property_native('fullscreen') then
        mp.set_property_native('fullscreen', true)
    end
end

local function schedule_apply(delay)
    cancel_apply_timer()
    apply_timer = mp.add_timeout(delay or o.delay, apply_fullscreen_once)
end

local function set_enabled(value, show_osd)
    o.enabled = normalize_bool(value)
    persist_config()
    publish_state()

    if o.enabled and has_real_video() then
        applied_for_file = false
        schedule_apply(0)
    end

    if show_osd and o.show_osd then
        mp.osd_message(o.enabled and '起播自动全屏已开启' or '起播自动全屏已关闭', 2.2)
    end
end

mp.register_script_message('set', function(value)
    set_enabled(value, true)
end)

mp.register_script_message('toggle', function()
    set_enabled(not o.enabled, true)
end)

mp.register_event('start-file', function()
    applied_for_file = false
    cancel_apply_timer()
end)

mp.register_event('file-loaded', function()
    schedule_apply(o.delay)
end)

mp.register_event('end-file', function()
    applied_for_file = false
    cancel_apply_timer()
end)

mp.add_timeout(0, publish_state)
