-- Delay the no-file startup window until GPU selection and idle UI scripts
-- are ready. This prevents force-window=immediate from creating a window on
-- the system-default adapter before adaptive-quality switches to the selected
-- adapter and rebuilds the video output.

local mp = require 'mp'
local msg = require 'mp.msg'

local fallback_seconds = 3
local window_requested = false
local adapter_ready =
    mp.get_property('user-data/adaptive-quality/adapter-ready') == 'yes'
local uosc_ready = mp.get_property('user-data/uosc/idle-branding') ~= nil
local image_ready = mp.get_property('user-data/idle-branding-image/mode') ~= nil
local fallback_timer = nil

local function publish_state(value)
    mp.set_property_native('user-data/startup-window/state', value)
end

local function request_window(reason)
    if window_requested then return end
    window_requested = true

    if fallback_timer then
        fallback_timer:kill()
        fallback_timer = nil
    end

    local ok, err = pcall(mp.set_property, 'force-window', 'immediate')
    if not ok then
        publish_state('failed')
        msg.error('Unable to create startup window: ' .. tostring(err))
        return
    end

    publish_state(reason or 'ready')
end

local function maybe_request_window()
    if adapter_ready and uosc_ready and image_ready then
        request_window('ready')
    end
end

mp.register_script_message('adapter-ready', function()
    adapter_ready = true
    maybe_request_window()
end)

mp.register_script_message('uosc-ready', function()
    uosc_ready = true
    maybe_request_window()
end)

mp.register_script_message('image-ready', function()
    image_ready = true
    maybe_request_window()
end)

maybe_request_window()

fallback_timer = mp.add_timeout(fallback_seconds, function()
    fallback_timer = nil
    if not window_requested then
        msg.warn('Startup readiness timed out; creating window with available settings')
        request_window('fallback')
    end
end)

publish_state('waiting')

mp.register_event('shutdown', function()
    if fallback_timer then
        fallback_timer:kill()
        fallback_timer = nil
    end
end)
