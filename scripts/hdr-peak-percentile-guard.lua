local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    enabled = true,
    normal_percentile = 99.995,
    low_average_percentile = 99.8,
}
options.read_options(o, 'hdr_peak_percentile_guard')

-- Keep the existing low-average-light HDR policy without making auto_profiles
-- depend directly on video-params/avg-pq-y.  That value is dynamic metadata and
-- may change many times per second on DV/HDR sources.  We sample at a bounded
-- rate and publish only threshold-state transitions.
local ENTER_LOW = 0.205
local EXIT_LOW = 0.215
local SAMPLE_INTERVAL = 0.50

local loaded = false
local low_average = false
local latest_avg = nil
local sample_timer = nil

local function source_is_pq()
    return tostring(mp.get_property('video-params/gamma', '')):lower() == 'pq'
end

local function set_user_data_if_changed(name, value)
    local current = mp.get_property_native(name)
    if current ~= value then mp.set_property_native(name, value) end
end

local function apply_percentile()
    if not loaded or not source_is_pq() then return end
    if not o.enabled then return end
    local percentile = low_average and o.low_average_percentile or o.normal_percentile
    local current = mp.get_property_number('hdr-peak-percentile', nil)
    if current == nil or math.abs(current - percentile) > 0.0001 then
        mp.set_property_native('hdr-peak-percentile', percentile)
    end
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/enabled', o.enabled)
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/percentile', percentile)
end

local function publish_state(value, avg)
    if low_average == value then
        apply_percentile()
        return
    end
    low_average = value
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/low-average', value)
    msg.verbose(string.format(
        'low-average HDR peak percentile %s (avg-pq-y=%s)',
        value and 'enabled' or 'disabled',
        avg and string.format('%.4f', avg) or 'n/a'))
    apply_percentile()
end

local function evaluate()
    sample_timer = nil
    if not loaded or not source_is_pq() then
        publish_state(false, latest_avg)
        return
    end

    local avg = tonumber(latest_avg)
    if not avg or avg ~= avg then
        publish_state(false, nil)
        return
    end

    if low_average then
        if avg > EXIT_LOW then publish_state(false, avg) end
    elseif avg < ENTER_LOW then
        publish_state(true, avg)
    else
        apply_percentile()
    end
end

local function schedule_sample(delay)
    if not loaded then return end
    if sample_timer then return end
    sample_timer = mp.add_timeout(delay or SAMPLE_INTERVAL, evaluate)
end

mp.observe_property('video-params/avg-pq-y', 'native', function(_, value)
    latest_avg = tonumber(value)
    schedule_sample(SAMPLE_INTERVAL)
end)

mp.observe_property('video-params/gamma', 'string', function()
    schedule_sample(0.05)
end)

mp.register_script_message('hdr-peak-percentile-guard-toggle', function()
    o.enabled = not o.enabled
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/enabled', o.enabled)
    if o.enabled then
        evaluate()
    else
        mp.set_property_native('hdr-peak-percentile', o.normal_percentile)
        set_user_data_if_changed('user-data/hdr-peak-percentile-guard/percentile', o.normal_percentile)
    end
    msg.info('HDR peak percentile guard: ' .. (o.enabled and 'enabled' or 'disabled'))
end)

mp.register_event('file-loaded', function()
    loaded = true
    latest_avg = mp.get_property_number('video-params/avg-pq-y', nil)
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/low-average', false)
    low_average = false
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/enabled', o.enabled)
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/low-average', false)
    schedule_sample(0.10)
end)

mp.register_event('end-file', function()
    loaded = false
    latest_avg = nil
    if sample_timer then
        sample_timer:kill()
        sample_timer = nil
    end
    publish_state(false, nil)
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/low-average', false)
end)

mp.add_timeout(0, function()
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/enabled', o.enabled)
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/low-average', false)
    set_user_data_if_changed('user-data/hdr-peak-percentile-guard/percentile', o.normal_percentile)
end)
