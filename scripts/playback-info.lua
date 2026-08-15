-- playback-info.lua
-- Toggle playback info overlay
local mp = require 'mp'
local shown = false
local timer

local function fmt(k, v) return k .. ': ' .. (v or 'N/A') end

local function update()
    local lines = {
        fmt('File', mp.get_property('filename')),
        fmt('Resolution', mp.get_property('video-params/w') .. 'x' .. mp.get_property('video-params/h')),
        fmt('Video Codec', mp.get_property('video-format')),
        fmt('Audio Codec', mp.get_property('audio-codec-name')),
        fmt('FPS', mp.get_property('estimated-vf-fps')),
        fmt('Bitrate', mp.get_property('video-bitrate') and math.floor(tonumber(mp.get_property('video-bitrate')) / 1000) .. ' kbps' or nil),
        fmt('HW Dec', mp.get_property('hwdec')),
        fmt('VO', mp.get_property('current-vo')),
    }
    mp.osd_message(table.concat(lines, '\n'), 999999)
end

local function toggle()
    shown = not shown
    if shown then
        update()
        timer = mp.add_periodic_timer(1, update)
    else
        if timer then timer:kill() end
        mp.osd_message('', 0)
    end
end

mp.register_script_message('toggle-info', toggle)
