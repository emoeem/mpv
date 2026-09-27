local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    mode = 'off',
    show_osd = true,
    reload_current = true,
    passthrough_audio_buffer = 1.0,
}
options.read_options(o, 'audio_passthrough')

local startup_audio_buffer = mp.get_property('audio-buffer', '0.2')

local config_path = mp.command_native({
    'expand-path',
    '~~/script-opts/audio_passthrough.conf',
})

local modes = {
    off = {
        label = '关闭',
        detail = '普通音频输出',
        spdif = '',
        exclusive = 'no',
        channels = 'auto-safe',
    },
    home = {
        label = '开启直通',
        detail = '推荐',
        spdif = 'ac3,eac3,truehd,dts,dts-hd',
        exclusive = 'yes',
        channels = '7.1,5.1,stereo',
    },
    dolby = {
        label = '仅 Dolby',
        detail = '兼容',
        spdif = 'ac3,eac3,truehd',
        exclusive = 'yes',
        channels = '7.1,5.1,stereo',
    },
    dts = {
        label = '仅 DTS',
        detail = '兼容',
        spdif = 'dts,dts-hd',
        exclusive = 'yes',
        channels = '7.1,5.1,stereo',
    },
}

local function normalize_mode(mode)
    mode = tostring(mode or ''):lower()
    return modes[mode] and mode or 'off'
end

local function mode_data(mode)
    return modes[normalize_mode(mode)] or modes.off
end

local function media_loaded()
    return not mp.get_property_bool('idle-active', true)
        and mp.get_property('path', '') ~= ''
end

local function output_device_label()
    local device = mp.get_property('audio-device', 'auto')
    if device == 'auto' or device == '' then
        return 'PipeWire 默认'
    end
    local list = mp.get_property_native('audio-device-list') or {}
    for _, item in ipairs(list) do
        if item.name == device then
            return item.description or device
        end
    end
    return device
end

local function current_audio_label()
    local track = mp.get_property_native('current-tracks/audio')
    if not track then return '未加载音轨' end
    local codec = track.codec or mp.get_property('audio-codec-name', '')
    local channels = track['audio-channels'] or track['demux-channel-count']
    local parts = {}
    if codec and codec ~= '' then parts[#parts + 1] = tostring(codec) end
    if channels then parts[#parts + 1] = tostring(channels) .. 'ch' end
    return #parts > 0 and table.concat(parts, ' · ') or '当前音轨'
end

local function current_passthrough_codec()
    local track = mp.get_property_native('current-tracks/audio')
    local codec = track and track.codec or mp.get_property('audio-codec-name', '')
    codec = tostring(codec or ''):lower()

    if codec:find('truehd', 1, true) or codec:find('mlp', 1, true) then return 'truehd' end
    if codec:find('eac3', 1, true) or codec:find('e-ac-3', 1, true) then return 'eac3' end
    if codec:find('ac3', 1, true) or codec:find('ac-3', 1, true) then return 'ac3' end
    if codec:find('dts', 1, true) or codec:find('dca', 1, true) then return 'dts' end
    return nil
end

local function mode_accepts_current_codec(mode)
    local codec = current_passthrough_codec()
    if not codec then return false, nil end

    local enabled = ',' .. mode_data(mode).spdif .. ','
    return enabled:find(',' .. codec .. ',', 1, true) ~= nil, codec
end

local function is_passthrough_format(format)
    return tostring(format or ''):lower():find('spdif-', 1, true) == 1
end

local function set_property_if_changed(name, value)
    local current = mp.get_property(name, '')
    if name == 'audio-buffer' then
        if tonumber(current) == tonumber(value) then return end
    elseif tostring(current) == tostring(value) then
        return
    end
    mp.set_property(name, tostring(value))
end

local function publish_state(mode)
    mode = normalize_mode(mode)
    local preset = mode_data(mode)
    mp.set_property('user-data/audio-passthrough/mode', mode)
    mp.set_property('user-data/audio-passthrough/label', preset.label)
    mp.set_property('user-data/audio-passthrough/detail', preset.detail)
    mp.set_property('user-data/audio-passthrough/enabled', mode ~= 'off' and 'yes' or 'no')
    mp.set_property('user-data/audio-passthrough/device', output_device_label())
    mp.set_property('user-data/audio-passthrough/audio', current_audio_label())
end

local function persist_mode(mode)
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('无法保存音频直通设置：' .. tostring(config_path))
        return false
    end
    file:write(
        '# 音频直通：off/home/dolby/dts\n'
            .. '# home=开启直通，dolby=仅 Dolby，dts=仅 DTS。\n'
            .. '# 通过“杳知 > 音频直通”维护；请确保 PipeWire 默认输出设备为 HDMI/eARC 回音壁或功放。\n'
            .. string.format('mode=%s\n', mode)
            .. string.format('show_osd=%s\n', o.show_osd and 'yes' or 'no')
            .. string.format('reload_current=%s\n', o.reload_current and 'yes' or 'no')
            .. '# 直通专用软件缓冲（秒）：提高 HDMI/eARC + WASAPI 独占输出对瞬时调度抖动的容忍度\n'
            .. string.format('passthrough_audio_buffer=%s\n', tostring(o.passthrough_audio_buffer))
    )
    file:close()
    return true
end

local reload_timers = {}
local reapply_timer = nil
local passthrough_check_timer = nil
local passthrough_check_empty_count = 0
local passthrough_check_not_before = 0
local run_passthrough_check
local fallback_to_pcm
local audio_switch_sync_timer = nil
local audio_switch_sync_ready = false
local last_aid = nil
local pending_audio_switch = nil

local function clear_passthrough_check()
    if passthrough_check_timer then
        passthrough_check_timer:kill()
        passthrough_check_timer = nil
    end
    passthrough_check_empty_count = 0
end

local function mark_passthrough_settling(delay)
    passthrough_check_not_before = math.max(
        passthrough_check_not_before,
        mp.get_time() + (delay or 0.8)
    )
end

local function schedule_passthrough_check(delay)
    if normalize_mode(o.mode) == 'off' then return end
    if passthrough_check_timer then passthrough_check_timer:kill() end

    local wait = math.max(delay or 0.2, passthrough_check_not_before - mp.get_time())
    passthrough_check_timer = mp.add_timeout(wait, function()
        passthrough_check_timer = nil
        run_passthrough_check()
    end)
end

run_passthrough_check = function()
    local mode = normalize_mode(o.mode)
    if mode == 'off' or not media_loaded() then return end

    local eligible, codec = mode_accepts_current_codec(mode)
    if not eligible then return end

    local output_format = mp.get_property('audio-out-params/format', '')
    if output_format == '' then
        passthrough_check_empty_count = passthrough_check_empty_count + 1
        if passthrough_check_empty_count <= 4 then
            schedule_passthrough_check(0.25)
        end
        return
    end

    passthrough_check_empty_count = 0
    if is_passthrough_format(output_format) then
        msg.verbose('audio passthrough active: ' .. output_format)
        return
    end

    fallback_to_pcm(codec, output_format)
end

local function clear_reload_timers()
    for _, timer in ipairs(reload_timers) do
        timer:kill()
    end
    reload_timers = {}
end

local function schedule_reload_step(delay, fn)
    reload_timers[#reload_timers + 1] = mp.add_timeout(delay, function()
        fn()
    end)
end

local function command_quiet(...)
    local ok, err = pcall(mp.commandv, ...)
    if not ok then msg.verbose('audio passthrough reload step skipped: ' .. tostring(err)) end
end

local function valid_aid(value)
    return value ~= nil and value ~= false and tostring(value) ~= '' and tostring(value) ~= 'no'
end

local function clear_audio_switch_sync()
    if audio_switch_sync_timer then
        audio_switch_sync_timer:kill()
        audio_switch_sync_timer = nil
    end
    pending_audio_switch = nil
end

local function arm_audio_switch_sync(aid)
    clear_audio_switch_sync()
    pending_audio_switch = {
        aid = tostring(aid),
        started = mp.get_time(),
    }
    audio_switch_sync_timer = mp.add_timeout(0.01, function()
        audio_switch_sync_timer = nil
        local pending = pending_audio_switch
        pending_audio_switch = nil
        if not pending or not media_loaded() then return end

        local current = mp.get_property_native('aid')
        if not valid_aid(current) or tostring(current) ~= pending.aid then return end
        if not mp.get_property_bool('seekable', false)
            or mp.get_property_bool('seeking', false)
        then
            return
        end

        -- With demuxer readahead, mpv's internal track refresh seek can be
        -- rejected after a manual audio switch. The newly selected track then
        -- starts at the cache head and mpv waits for the video clock to catch
        -- up, causing several seconds of silence. A zero-distance exact seek
        -- is the same resync the user currently gets by nudging the timeline.
        msg.verbose('manual audio track switch: realigning at current position')
        command_quiet('seek', '0', 'relative+exact')
    end)
end

local function reload_audio_chain()
    if not o.reload_current or not media_loaded() then return end
    clear_reload_timers()

    local track = mp.get_property_native('current-tracks/audio')
    local aid = track and track.id

    command_quiet('ao-reload')
    if aid then
        command_quiet('audio-reload', tostring(aid))
        command_quiet('set', 'aid', 'no')
        schedule_reload_step(0.05, function()
            command_quiet('set', 'aid', tostring(aid))
        end)
        schedule_reload_step(0.12, function()
            command_quiet('seek', '0', 'relative+exact')
        end)
        schedule_reload_step(0.18, function()
            command_quiet('ao-reload')
        end)
    else
        schedule_reload_step(0.05, function()
            command_quiet('audio-reload')
        end)
    end
end

local function apply_mode(mode, show_osd, reload_now)
    mode = normalize_mode(mode)
    local preset = mode_data(mode)

    if mode == 'off' then
        clear_passthrough_check()
        passthrough_check_not_before = 0
    elseif reload_now then
        mark_passthrough_settling(0.8)
    end

    set_property_if_changed('audio-spdif', preset.spdif)
    set_property_if_changed('audio-exclusive', preset.exclusive)
    set_property_if_changed('audio-channels', preset.channels)
    if mode == 'off' then
        set_property_if_changed('audio-buffer', startup_audio_buffer)
    else
        set_property_if_changed('audio-buffer', o.passthrough_audio_buffer)
    end
    publish_state(mode)

    if reload_now then
        reload_audio_chain()
    end

    if mode ~= 'off' then
        schedule_passthrough_check(reload_now and 0.8 or 0.25)
    end

    if show_osd and o.show_osd then
        if mode == 'off' then
            mp.osd_message('音频直通已关闭 · 普通输出', 2.4)
        else
            mp.osd_message('音频直通已开启 · ' .. preset.label, 2.4)
        end
    end
end

fallback_to_pcm = function(codec, output_format)
    if normalize_mode(o.mode) == 'off' then return end

    clear_passthrough_check()
    clear_reload_timers()
    if reapply_timer then
        reapply_timer:kill()
        reapply_timer = nil
    end

    o.mode = 'off'
    persist_mode('off')
    apply_mode('off', false, true)

    msg.warn(string.format(
        'passthrough failed for %s: audio output is %s; switched to PCM',
        tostring(codec or 'unknown'),
        tostring(output_format or 'unavailable')
    ))
    if o.show_osd then
        mp.osd_message('当前设备不支持此音轨直通，已自动切回普通输出', 3.5)
    end
end

local function schedule_reapply(delay, reload_now)
    if reapply_timer then
        reapply_timer:kill()
        reapply_timer = nil
    end
    reapply_timer = mp.add_timeout(delay or 0.05, function()
        reapply_timer = nil
        apply_mode(normalize_mode(o.mode), false, reload_now)
    end)
end

mp.register_script_message('set', function(mode)
    mode = normalize_mode(mode)
    o.mode = mode
    persist_mode(mode)
    apply_mode(mode, true, true)
end)

mp.register_script_message('toggle', function()
    local mode = normalize_mode(o.mode) == 'off' and 'home' or 'off'
    o.mode = mode
    persist_mode(mode)
    apply_mode(mode, true, true)
end)

mp.observe_property('audio-device', 'native', function()
    publish_state(normalize_mode(o.mode))
end)

mp.observe_property('current-tracks/audio', 'native', function()
    publish_state(normalize_mode(o.mode))
    if normalize_mode(o.mode) ~= 'off' then
        mark_passthrough_settling(0.8)
        schedule_passthrough_check(0.8)
    end
end)

mp.observe_property('audio-out-params/format', 'string', function(_, format)
    if normalize_mode(o.mode) ~= 'off' and format and format ~= '' then
        schedule_passthrough_check(0.25)
    end
end)

mp.observe_property('aid', 'native', function(_, value)
    local previous = last_aid
    last_aid = value
    if not audio_switch_sync_ready then return end

    if valid_aid(previous) and valid_aid(value)
        and tostring(previous) ~= tostring(value)
    then
        arm_audio_switch_sync(value)
    else
        clear_audio_switch_sync()
    end
end)

mp.register_event('start-file', function()
    audio_switch_sync_ready = false
    last_aid = nil
    clear_audio_switch_sync()
    if normalize_mode(o.mode) ~= 'off' then
        mark_passthrough_settling(1.0)
    end
    schedule_reapply(0.05, false)
end)

mp.register_event('file-loaded', function()
    last_aid = mp.get_property_native('aid')
    if normalize_mode(o.mode) ~= 'off' then
        mark_passthrough_settling(0.6)
    end
    schedule_reapply(0.15, false)
end)

mp.register_event('playback-restart', function()
    audio_switch_sync_ready = true
    schedule_passthrough_check(0.2)
end)

mp.add_timeout(0, function()
    o.mode = normalize_mode(o.mode)
    apply_mode(o.mode, false, false)
end)
