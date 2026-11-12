-- Publish demuxer-confirmed media metadata that mpv does not expose through
-- track-list/video-params for every container.  Raw UHD Blu-ray M2TS is the
-- important case: FFmpeg reports the Dolby Vision configuration record, but
-- the selected track can still look like ordinary HEVC + PQ to Lua.

local mp = require 'mp'
local msg = require 'mp.msg'

local root = 'user-data/media-format/'
local current_profile = 0
local current_level = 0
local current_source = ''
local active = false
local loading = false
local session_path = ''
local selected_key
local pending

local function set_if_changed(name, value)
    local property = root .. name
    if mp.get_property_native(property) == value then return end
    mp.set_property_native(property, value)
end

local function publish()
    set_if_changed('dolby-vision-profile', current_profile)
    set_if_changed('dolby-vision-level', current_level)
    set_if_changed('dolby-vision-source', current_source)
end

local function set_current(profile, level, source)
    current_profile = tonumber(profile) or 0
    current_level = tonumber(level) or 0
    current_source = current_profile > 0 and (source or '') or ''
    publish()
end

local function selected_video()
    local current = mp.get_property_native('current-tracks/video', {})
    if type(current) ~= 'table' then current = {} end
    local tracks = mp.get_property_native('track-list', {})
    local count, selected = 0, nil
    for _, track in ipairs(type(tracks) == 'table' and tracks or {}) do
        if type(track) == 'table' and track.type == 'video' and not track.albumart then
            count = count + 1
            if track.selected == true or (current.id ~= nil and current.id == track.id) then
                selected = track
            end
        end
    end
    if current.type == 'video' then
        -- Do not reuse a stale track-list copy after the native selection resets.
        selected = current
    end
    local vid = mp.get_property_native('vid')
    if vid == false or vid == 'no' then selected = nil end
    local key = selected and selected.id ~= nil and tostring(selected.id) or nil
    return selected or {}, key, count
end

local function refresh()
    if not active or loading or mp.get_property('path', '') ~= session_path then
        set_current(0, 0, '')
        return
    end
    local track, key, count = selected_video()
    local profile = tonumber(track['dolby-vision-profile']) or 0
    if profile > 0 then
        set_current(profile, track['dolby-vision-level'], 'track')
    elseif pending and count == 1 and key ~= nil
        and (pending.key == nil or pending.key == key) then
        -- An unindexed demux log can only be attributed to a single video track.
        pending.key = key
        set_current(pending.profile, pending.level, 'demuxer')
    else
        set_current(0, 0, '')
    end
    selected_key = key
end

local function start_file()
    active, loading = true, true
    session_path = mp.get_property('path', '')
    selected_key, pending = nil, nil
    set_current(0, 0, '')
end

local function end_file()
    active, loading = false, false
    session_path = ''
    selected_key, pending = nil, nil
    set_current(0, 0, '')
end

local function selection_changed()
    local _, key, count = selected_video()
    if count > 1 then pending = nil end
    if selected_key ~= nil and selected_key ~= key then pending = nil end
    selected_key = key
    refresh()
end

local function on_log_message(event)
    -- Only trust libavformat's own probe result.  Never infer P7 from a second
    -- HEVC track, PID order, resolution, file extension or filename.
    if tostring(event and event.prefix or '') ~= 'lavf' then return end
    -- Once loading ends, old queued logs and later seeks cannot replace the
    -- selected track's metadata. Native track properties remain authoritative.
    if not active or not loading or mp.get_property('path', '') ~= session_path then return end
    local text = tostring(event and event.text or '')
    local profile, level = text:match(
        'Found Dolby Vision config record:%s*profile%s+(%d+)%s+level%s+(%d+)'
    )
    profile, level = tonumber(profile), tonumber(level)
    if not profile or profile <= 0 then return end
    local _, key, count = selected_video()
    if count > 1 then return end
    pending = {profile = profile, level = level or 0, key = key}
end

mp.enable_messages('v')
mp.register_event('start-file', start_file)
mp.register_event('end-file', end_file)
mp.register_event('file-loaded', function()
    loading = false
    refresh()
    if current_source == 'demuxer' then
        msg.info(string.format('demuxer-confirmed Dolby Vision P%d level %d',
            current_profile, current_level))
    end
end)
mp.register_event('log-message', on_log_message)
mp.observe_property('vid', 'native', selection_changed)
mp.observe_property('current-tracks/video', 'native', selection_changed)
mp.observe_property('track-list', 'native', selection_changed)
mp.observe_property('current-edition', 'native', function()
    pending = nil
    selection_changed()
end)
set_current(0, 0, '')

