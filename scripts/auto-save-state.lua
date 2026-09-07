-- Runs write-watch-later-config periodically

local options = require 'mp.options'
local msg = require 'mp.msg'

o = {
    save_interval = 60,
    percent_pos = 99,
    defer_while_playing = true,
    safe_pause_delay = 0.25,
}
options.read_options(o)

local can_delete = true
local can_save = true
local path = nil -- only set after file success load, reset to nil when file unload.
local timer = nil
local safe_save_timer = nil
local pending_periodic_save = false

local function cancel_safe_save()
    if safe_save_timer then
        safe_save_timer:kill()
        safe_save_timer = nil
    end
end

local function reset()
    cancel_safe_save()
    pending_periodic_save = false
    path = nil
end

-- set vars when file success load
local function init()
    path = mp.get_property("path")
end

local function passthrough_active()
    local format = mp.get_property("audio-out-params/format", "")
    return tostring(format):lower():find("spdif-", 1, true) == 1
end

local function safely_paused()
    return path ~= nil and mp.get_property_bool("pause", false)
        and not mp.get_property_bool("paused-for-cache", false)
end

local function save(force)
    if not can_save or path == nil then return false end
    if not force and passthrough_active() and not safely_paused() then
        msg.debug("deferring periodic state save during audio passthrough")
        return false
    end
    local watch_later_list = mp.get_property("watch-later-options", {})
    if mp.get_property_bool("save-position-on-quit") then
        msg.debug("saving state")
        if not watch_later_list:find("start") then
            mp.commandv("change-list", "watch-later-options", "append", "start")
        end
        mp.command("write-watch-later-config")
        pending_periodic_save = false
        return true
    end
    return false
end

local function schedule_safe_save()
    if not pending_periodic_save or not safely_paused() then return end
    cancel_safe_save()
    safe_save_timer = mp.add_timeout(math.max(0, o.safe_pause_delay), function()
        safe_save_timer = nil
        if pending_periodic_save and safely_paused() then save(false) end
    end)
end

local function periodic_save()
    if o.defer_while_playing and not safely_paused() then
        pending_periodic_save = true
        msg.debug("deferring periodic state save until playback is safely paused or unloaded")
        return
    end
    if not save(false) then pending_periodic_save = true end
end

local function handle_pause(_, pause)
    if pause then
        if timer then timer:stop() end
        schedule_safe_save()
    else
        cancel_safe_save()
        if timer then timer:resume() end
    end
end

-- save watch-later-config when file unloading
local function save_or_delete()
    if not can_delete then return end
    cancel_safe_save()
    local eof = mp.get_property_bool("eof-reached")
    local percent_pos = mp.get_property_number("percent-pos")
    if eof or percent_pos and (percent_pos == 0 or percent_pos >= o.percent_pos) then
        can_delete = true
        if path ~= nil then
            msg.debug("deleting state: percent_pos=0 or eof")
            mp.commandv("delete-watch-later-config", path)
        end
    elseif path ~= nil then
        save(true)
    end
    reset()
end

mp.register_script_message("skip-delete-state", function() can_delete = false end)

if o.save_interval > 0 then
    timer = mp.add_periodic_timer(math.max(1, o.save_interval), periodic_save)
end
mp.observe_property("pause", "bool", handle_pause)

-- Active playback never performs a synchronous watch-later write. A due save
-- is completed after a real user pause has settled, or forcibly during unload.
-- This preserves clean-exit resume state without risking periodic A/V stalls.

mp.register_event("file-loaded", init)
mp.add_hook("on_unload", 50, save_or_delete) -- after mpv saving state
