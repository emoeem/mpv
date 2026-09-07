-- Publish demuxer-confirmed media metadata that mpv does not expose through
-- track-list/video-params for every container.  Raw UHD Blu-ray M2TS is the
-- important case: FFmpeg reports the Dolby Vision configuration record, but
-- the selected track can still look like ordinary HEVC + PQ to Lua.

local mp = require 'mp'
local msg = require 'mp.msg'

local root = 'user-data/media-format/'
local current_profile = 0
local current_level = 0

local function set_if_changed(name, value)
    local property = root .. name
    if mp.get_property_native(property) == value then return end
    mp.set_property_native(property, value)
end

local function publish()
    set_if_changed('dolby-vision-profile', current_profile)
    set_if_changed('dolby-vision-level', current_level)
    set_if_changed('dolby-vision-source', current_profile > 0 and 'demuxer' or '')
end

local function clear()
    current_profile = 0
    current_level = 0
    publish()
end

local function on_log_message(event)
    -- Only trust libavformat's own probe result.  Never infer P7 from a second
    -- HEVC track, PID order, resolution, file extension or filename.
    if tostring(event and event.prefix or '') ~= 'lavf' then return end
    local text = tostring(event and event.text or '')
    local profile, level = text:match(
        'Found Dolby Vision config record:%s*profile%s+(%d+)%s+level%s+(%d+)'
    )
    profile, level = tonumber(profile), tonumber(level)
    if not profile or profile <= 0 then return end
    if current_profile == profile and current_level == (level or 0) then return end
    current_profile = profile
    current_level = level or 0
    publish()
    msg.info(string.format(
        'demuxer-confirmed Dolby Vision P%d level %d',
        current_profile, current_level
    ))
end

mp.enable_messages('v')
mp.register_event('start-file', clear)
mp.register_event('log-message', on_log_message)
clear()

