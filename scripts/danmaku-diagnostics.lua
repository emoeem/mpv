-- Opt-in field diagnostics. Never changes playback, cadence, render or logging options.
local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local opts = {enabled = false, duration = 120, gpu_samples = false}
require('mp.options').read_options(opts, 'danmaku-diagnostics')

local timer, started, last_tick, last_report, active = nil, 0, 0, 0, false
local armed, previous, changes, total_changes, intervals = opts.enabled, {}, {}, 0, {}
local events, callback_costs, sequence = {}, {}, 0
local cache, received, marker_count = {}, {}, 0
local duration = math.max(10, math.min(180, tonumber(opts.duration) or 120))
local counters = {'frame-drop-count', 'decoder-frame-drop-count',
    'mistimed-frame-count', 'vo-delayed-frame-count'}
local observed = {'pause', 'seeking', 'paused-for-cache', 'fullscreen',
    'video-sync', 'display-sync-active', 'interpolation', 'speed',
    'display-fps', 'osd-dimensions', 'user-data/uosc_danmaku/overlay-cadence',
    'user-data/uosc_danmaku/renderer', 'user-data/stats/visible'}
local record_changes = {}
for _, k in ipairs(observed) do record_changes[k] = true end
for _, k in ipairs(counters) do observed[#observed + 1] = k end
for _, k in ipairs({'time-pos', 'secondary-sub-ass-refresh-rate',
    'user-data/uosc_danmaku/danmaku-count', 'estimated-display-fps', 'estimated-vf-fps', 'container-fps'}) do
    observed[#observed + 1] = k
end
local env_keys = {'ASS_DIAGNOSTIC', 'ASS_TRACE', 'PRESENT_PLAN', 'PRESENT_GRID',
    'FIFO_PRESENT', 'DISPLAY_FORECAST', 'FIXED_FORECAST', 'SPLIT_BUDGET',
    'QUEUE_LEAD', 'QUEUE_STAGE', 'SPANS', 'GPU_MARKER'}

local function number(v)
    return type(v) == 'number' and v == v and math.abs(v) < math.huge and v or nil
end

local function quantiles(values)
    local v = {}
    for _, x in ipairs(values) do if number(x) then v[#v + 1] = x end end
    table.sort(v)
    if #v == 0 then return {n = 0} end
    local function q(f) return v[math.max(1, math.ceil(#v * f))] end
    return {n = #v, p50 = q(.50), p95 = q(.95), p99 = q(.99), max = v[#v]}
end

local function emit(kind, value)
    sequence = sequence + 1
    value.schema, value.kind, value.sequence = 'yaozhi-danmaku-field-v1', kind, sequence
    value.wall_seconds = mp.get_time()
    value.time_pos = cache['time-pos']
    msg.info('danmaku-diagnostic ' .. utils.format_json(value))
end

local function changed(name, value)
    if not active then return end
    cache[name], received[name] = value, true
    if not record_changes[name] then return end
    total_changes = total_changes + 1
    if #changes < 32 then
        changes[#changes + 1] = {property = name, value = value, wall_seconds = mp.get_time()}
    end
end

-- Observer callbacks are asynchronous; absence and false are different states.
-- Snapshots copy fixed scalar fields only and make no synchronous VO queries.
local timing_fields = {
    {'video_sync', 'video-sync', 'string'},
    {'display_sync_active', 'display-sync-active', 'boolean'},
    {'interpolation_option', 'interpolation', 'boolean'},
    {'speed', 'speed', 'number'},
    {'container_fps', 'container-fps', 'number'},
    {'display_hz_reported', 'display-fps', 'number'},
    {'display_hz_estimated', 'estimated-display-fps', 'number'},
    {'video_fps_estimated', 'estimated-vf-fps', 'number'},
    {'native_refresh_option', 'secondary-sub-ass-refresh-rate', 'number'},
}
local function timing_snapshot()
    local snapshot = {basis = 'latest_observer_cache_not_atomic',
        values_are_not_ASS_pose_or_physical_Display = true}
    for _, field in ipairs(timing_fields) do
        local value = cache[field[2]]
        local state = not received[field[2]] and 'pending'
            or value == nil and 'unavailable'
            or type(value) ~= field[3] and 'invalid'
            or field[3] == 'number' and not number(value) and 'invalid'
            or 'available'
        snapshot[field[1]] = {state = state}
        if state == 'available' then snapshot[field[1]].value = value end
    end
    return snapshot
end

local function passes_snapshot()
    -- Recent per-pass GPU timer samples, not synchronized whole-frame timings.
    if not opts.gpu_samples then return {available = false, reason = 'disabled_to_avoid_synchronous_VO_query'} end
    local raw = mp.get_property_native('vo-passes')
    if type(raw) ~= 'table' then return {available = false} end
    local out = {available = true, units = 'ms', scope = 'recent_per_pass_gpu_samples_not_frame_or_display'}
    for _, kind in ipairs({'fresh', 'redraw'}) do
        local list, sum, entries = raw[kind], 0, {}
        if type(list) == 'table' then
            for i, pass in ipairs(list) do
                if i > 128 then break end
                local samples = {}
                for j, ns in ipairs(type(pass.samples) == 'table' and pass.samples or {}) do
                    if j > 256 then break end
                    if number(ns) and ns >= 0 then samples[#samples + 1] = ns / 1e6 end
                end
                local avg = number(pass.avg)
                if avg then sum = sum + avg / 1e6 end
                entries[#entries + 1] = {desc = tostring(pass.desc or ''):sub(1, 160),
                    avg_ms = avg and avg / 1e6, last_ms = number(pass.last) and pass.last / 1e6,
                    recent = quantiles(samples)}
            end
        end
        out[kind] = {passes = entries, sum_avg_ms = sum, truncated = type(list) == 'table' and #list > 128}
    end
    return out
end

local function counter_snapshot()
    local out = {}
    for _, key in ipairs(counters) do
        local current = number(cache[key])
        local prior = previous[key]
        out[key] = {value = current, delta = current and prior and current >= prior and current - prior or nil,
            reset = current ~= nil and prior ~= nil and current < prior or false}
        previous[key] = current
    end
    return out
end

local function report(reason)
    local now = mp.get_time()
    local query_begin = now
    local data = {reason = reason, window_seconds = now - last_report,
        pause = cache['pause'], seeking = cache['seeking'],
        cache_paused = cache['paused-for-cache'],
        configured_cadence = cache['user-data/uosc_danmaku/overlay-cadence'],
        native_refresh_option = cache['secondary-sub-ass-refresh-rate'],
        renderer = cache['user-data/uosc_danmaku/renderer'],
        source_comment_count_not_active = cache['user-data/uosc_danmaku/danmaku-count'],
        display_hz_reported = cache['display-fps'],
        display_hz_estimated = cache['estimated-display-fps'],
        video_fps_estimated = cache['estimated-vf-fps'],
        timing_context = timing_snapshot(),
        counters = counter_snapshot(), gpu_passes = passes_snapshot(),
        lua_1s_timer_interval_ms_not_frame_pacing = quantiles(intervals),
        previous_callback_wall_ms = quantiles(callback_costs), changes = changes,
        change_count = total_changes, omitted_changes = math.max(0, total_changes - #changes),
        events = events, marker_count = marker_count,
        omitted_markers = math.max(0, marker_count - #events),
        actual_ASS_pose_and_Present_Ready_Display = 'unavailable_in_Lua_properties',
        ASS_OSD_CPU_duration = 'unavailable_in_Lua_properties'}
    data.property_query_wall_ms = (mp.get_time() - query_begin) * 1000
    emit('window', data)
    last_report = now
    changes, total_changes, events, intervals, callback_costs, marker_count = {}, 0, {}, {}, {}, 0
end

local function stop(reason)
    if active then
        report(reason or 'manual-stop')
        active = false
        timer:kill()
        mp.unobserve_property(changed)
        emit('stop', {reason = reason, elapsed_seconds = mp.get_time() - started})
    end
    armed = false
end

local function tick()
    if not active then return end
    local begin = mp.get_time()
    intervals[#intervals + 1] = (begin - last_tick) * 1000
    last_tick = begin
    if begin - started >= duration then stop('duration-limit'); return end
    if begin - last_report >= 15 then report('periodic') end
    callback_costs[#callback_costs + 1] = (mp.get_time() - begin) * 1000
end

local function start()
    if active then return end
    if mp.get_property_native('idle-active') then armed = true; return end
    active, armed = true, false
    started = mp.get_time()
    last_tick, last_report = started, started
    previous, changes, total_changes, events, intervals, callback_costs, cache, received, marker_count =
        {}, {}, 0, {}, {}, {}, {}, {}, 0
    local env = {}
    for _, k in ipairs(env_keys) do env[k] = os.getenv('MPV_NATIVE_' .. k) or 'unset' end
    local shaders = {}
    for _, p in ipairs(mp.get_property_native('glsl-shaders') or {}) do
        shaders[#shaders + 1] = tostring(p):match('[^/\\]+$') or ''
    end
    emit('start', {duration_limit_seconds = duration, version = mp.get_property('mpv-version'),
        native_environment = env, shaders = shaders, vo = mp.get_property('current-vo'),
        gpu = mp.get_property_native('user-data/adaptive-quality/gpu'),
        hwdec = mp.get_property('hwdec-current'), video = mp.get_property_native('video-params'),
        video_sync = mp.get_property('video-sync'), speed = mp.get_property_number('speed'),
        viewport = mp.get_property_native('osd-dimensions'),
        gpu_samples_enabled = opts.gpu_samples,
        collection = '1Hz_Lua_watchdog_15s_cached_property_summary_no_Display_measurement'})
    for _, name in ipairs(observed) do mp.observe_property(name, 'native', changed) end
    -- Initial observer values arrive asynchronously. First window deltas remain
    -- unknown rather than interpreting counts from before capture as new drops.
    if not timer then timer = mp.add_periodic_timer(1, tick) else timer:resume() end
end

mp.register_script_message('yaozhi-danmaku-diagnostics', function(action)
    if action == 'start' then start()
    elseif action == 'stop' then stop('manual-stop')
    elseif action == 'mark' and active then
        -- Coalesce markers; no immediate vo-passes query or draw on the hitch.
        marker_count = marker_count + 1
        if #events < 32 then events[#events + 1] = {kind = 'user-visible-hitch',
            wall_seconds = mp.get_time(), time_pos = cache['time-pos'],
            timing_context = timing_snapshot()} end
    end
end)
mp.register_event('file-loaded', function() if armed then start() end end)
mp.register_event('end-file', function() if active then stop('end-file') end end)
mp.register_event('shutdown', function() if active then stop('shutdown') end end)
-- Auto mode waits for file-loaded, not the false idle-active value during boot.
