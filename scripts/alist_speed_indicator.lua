local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    show_mounted_drive_speed = true,
    mounted_drive_prefixes = 'X:,Y:,Z:',
}
options.read_options(opts, 'alist_speed_indicator')

local timer = nil
local last_cache_used = 0
local last_cache_time = 0
local last_speed_text = nil

local function set_speed_text(text)
    text = text or ''
    if text == last_speed_text then return end
    last_speed_text = text
    mp.set_property_native('user-data/alist/speed-text', text)
end

local function is_alist_playing()
    return mp.get_property_bool('user-data/alist/playing', false)
end

local function is_remote_path(path)
    if type(path) ~= 'string' or path == '' then return false end
    local lower = path:lower()
    return lower:match('^https?://') ~= nil
        or lower:match('^webdav[s]?://') ~= nil
        or lower:match('^dav[s]?://') ~= nil
        or lower:match('^s?ftp://') ~= nil
        or lower:match('^rtmp[s]?://') ~= nil
        or lower:match('^mms[t]?://') ~= nil
end

local function is_mounted_drive_path(path)
    if not opts.show_mounted_drive_speed then return false end
    if type(path) ~= 'string' or path == '' then return false end

    local normalized = path:gsub('/', '\\')
    if normalized:match('^\\\\') then return true end

    for prefix in tostring(opts.mounted_drive_prefixes or ''):gmatch('[^,;]+') do
        prefix = prefix:gsub('^%s+', ''):gsub('%s+$', '')
        if prefix ~= '' then
            local drive = prefix:match('^([A-Za-z]):?$')
            if drive and normalized:lower():match('^' .. drive:lower() .. ':[\\/]') then
                return true
            end
        end
    end

    return false
end

local function should_show_speed()
    if is_alist_playing() then return true end
    if mp.get_property_bool('demuxer-via-network', false) then return true end
    local path = mp.get_property('path', '')
    return is_remote_path(path) or is_mounted_drive_path(path)
end

local function format_speed(bytes_per_second)
    bytes_per_second = math.max(0, bytes_per_second or 0)
    local kb = bytes_per_second / 1024
    if kb >= 1024 then
        return string.format('%.1fMB/s', kb / 1024)
    end
    return string.format('%dKB/s', math.floor(kb + 0.5))
end

local function read_raw_input_rate()
    local cache_state = mp.get_property_native('demuxer-cache-state', {})
    if type(cache_state) ~= 'table' then return 0 end
    return tonumber(cache_state['raw-input-rate'] or cache_state.raw_input_rate) or 0
end

local function read_cache_delta_rate()
    local now = mp.get_time()
    local used = mp.get_property_number('cache-used', 0) or 0
    local rate = 0

    if last_cache_time > 0 and now > last_cache_time and used >= last_cache_used then
        rate = (used - last_cache_used) / (now - last_cache_time)
    end

    last_cache_used = used
    last_cache_time = now
    return rate
end

local function read_speed()
    local rate = read_raw_input_rate()
    if rate > 0 then return rate end

    rate = mp.get_property_number('cache-speed', 0) or 0
    if rate > 0 then return rate end

    return read_cache_delta_rate()
end

local function refresh()
    if not should_show_speed() then
        set_speed_text('')
        return
    end
    local speed = read_speed()
    if speed <= 0 then
        set_speed_text('0KB/s')
        return
    end
    set_speed_text(format_speed(speed))
end

local function stop_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function start_timer()
    if timer then return end
    last_cache_used = 0
    last_cache_time = 0
    refresh()
    timer = mp.add_periodic_timer(1, refresh)
end

local function update_active()
    if should_show_speed() then
        start_timer()
    else
        stop_timer()
        set_speed_text('')
    end
end

mp.observe_property('user-data/alist/playing', 'bool', update_active)
mp.observe_property('demuxer-via-network', 'bool', update_active)
mp.register_event('file-loaded', update_active)
mp.register_event('end-file', function()
    stop_timer()
    set_speed_text('')
end)

mp.add_timeout(0.2, update_active)
