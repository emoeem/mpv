local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    pause_on_minimize = true,
    minimize_delay = 0.2,
    resume_delay = 0.5,
}
options.read_options(o, 'minimize_pause_resume')

local config_path = mp.command_native({
    'expand-path',
    '~~/script-opts/minimize_pause_resume.conf',
})

local resume_timer = nil
local minimize_timer = nil
local paused_by_minimize = false

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

o.pause_on_minimize = normalize_bool(o.pause_on_minimize)
o.minimize_delay = normalize_number(o.minimize_delay, 0.2)
o.resume_delay = normalize_number(o.resume_delay, 0.5)

local function publish_state()
    mp.set_property('user-data/minimize-pause-resume/pause-on-minimize', o.pause_on_minimize and 'yes' or 'no')
    mp.set_property('user-data/minimize-pause-resume/label', o.pause_on_minimize and '已开启' or '已关闭')
    mp.set_property('user-data/minimize-pause-resume/detail', o.pause_on_minimize and '最小化后暂停播放' or '最小化后继续播放')
end

local function persist_config()
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('Failed to save minimize pause config: ' .. tostring(config_path))
        return false
    end
    file:write(
        '# Minimize pause/resume\n'
            .. '# yes: pause video when the window is minimized, resume after restore.\n'
            .. '# no: keep video playing when the window is minimized.\n'
            .. string.format('pause_on_minimize=%s\n\n', o.pause_on_minimize and 'yes' or 'no')
            .. '# Delay values are in seconds. Usually no need to change them.\n'
            .. string.format('minimize_delay=%s\n', o.minimize_delay)
            .. string.format('resume_delay=%s\n', o.resume_delay)
    )
    file:close()
    return true
end

local function has_real_video()
    local vid = mp.get_property_native('vid')
    if not vid or vid == 'no' then return false end
    local track = mp.get_property_native('current-tracks/video')
    return not (track and track.albumart)
end

local function cancel_resume_timer()
    if resume_timer then
        resume_timer:kill()
        resume_timer = nil
    end
end

local function cancel_minimize_timer()
    if minimize_timer then
        minimize_timer:kill()
        minimize_timer = nil
    end
end

local function set_pause_on_minimize(value, show_osd)
    o.pause_on_minimize = normalize_bool(value)

    if not o.pause_on_minimize and paused_by_minimize then
        cancel_resume_timer()
        paused_by_minimize = false
        if mp.get_property_native('pause') then
            mp.set_property_native('pause', false)
        end
    end

    persist_config()
    publish_state()

    if show_osd then
        mp.osd_message(o.pause_on_minimize and '最小化自动暂停已开启' or '最小化自动暂停已关闭', 2.2)
    end
end

mp.register_script_message('set', function(value)
    set_pause_on_minimize(value, true)
end)

mp.register_script_message('toggle', function()
    set_pause_on_minimize(not o.pause_on_minimize, true)
end)

mp.observe_property('window-minimized', 'bool', function(_, minimized)
    if minimized then
        cancel_resume_timer()
        cancel_minimize_timer()
        minimize_timer = mp.add_timeout(o.minimize_delay, function()
            minimize_timer = nil
            if mp.get_property_native('window-minimized') then
                local music_bypass = mp.get_property_native('user-data/music-mode/minimize-bypass') == 'yes'
                paused_by_minimize = o.pause_on_minimize
                    and has_real_video()
                    and not music_bypass
                    and not mp.get_property_native('pause')
                if paused_by_minimize then
                    mp.set_property_native('pause', true)
                end
            end
        end)
        return
    end

    cancel_minimize_timer()
    if paused_by_minimize then
        cancel_resume_timer()
        resume_timer = mp.add_timeout(o.resume_delay, function()
            resume_timer = nil
            if paused_by_minimize and not mp.get_property_native('window-minimized') then
                mp.set_property_native('pause', false)
            end
            paused_by_minimize = false
        end)
    end
end)

mp.register_event('end-file', function()
    cancel_resume_timer()
    cancel_minimize_timer()
    paused_by_minimize = false
end)

mp.add_timeout(0, publish_state)
