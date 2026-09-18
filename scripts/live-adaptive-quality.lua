-- Linux-safe adaptive live quality controller for online-media.lua.
-- It does not guess raw network bandwidth from OS interfaces. Instead it uses
-- mpv's actual demuxer cache runway/underrun signals and the resolver's real
-- quality list, then requests a bounded quality change through online-media.

local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    enabled = true,
    sample_interval = 2.0,
    low_cache_seconds = 5.0,
    critical_cache_seconds = 2.0,
    recover_cache_seconds = 18.0,
    upgrade_hold_seconds = 30.0,
    downgrade_cooldown = 8.0,
    max_switches_per_file = 8,
    prefer_quality = 'auto', -- auto|best|balanced
    show_osd = true,
}
options.read_options(o, 'live_adaptive_quality')

local timer
local generation = 0
local last_cache = nil
local last_sample = 0
local low_since = nil
local recover_since = nil
local last_switch = -math.huge
local switches = 0
local current_quality = ''

local function set_data(key, value)
    mp.set_property_native('user-data/live-adaptive-quality/' .. key, value)
end

local function publish(state, detail)
    set_data('state', state or 'idle')
    set_data('detail', detail or '')
    set_data('quality', current_quality)
    set_data('switches', switches)
end

local function reset()
    generation = generation + 1
    last_cache = nil
    last_sample = 0
    low_since = nil
    recover_since = nil
    last_switch = -math.huge
    switches = 0
    current_quality = ''
    publish('idle', '')
end

local function is_live()
    return mp.get_property_native('user-data/online-media/content-type') == 'live'
        and mp.get_property_native('user-data/online-media/matched') == true
end

local function quality_list()
    local raw = mp.get_property('user-data/online-media/quality-options-json', '')
    if raw == '' then return {} end
    local ok, value = pcall(utils.parse_json, raw)
    return ok and type(value) == 'table' and value or {}
end

local function candidates()
    local result = {}
    for _, item in ipairs(quality_list()) do
        if type(item) == 'table' and item.selectable ~= false and tostring(item.id or '') ~= '' then
            local height = tonumber(item.height or item.resolution_height or 0) or 0
            result[#result + 1] = { id = tostring(item.id), height = height,
                quality = tostring(item.quality or item.name or item.id) }
        end
    end
    table.sort(result, function(a, b)
        if a.height ~= b.height then return a.height < b.height end
        return a.id < b.id
    end)
    return result
end

local function sync_quality()
    current_quality = tostring(mp.get_property_native('user-data/online-media/quality-id') or '')
end

local function switch_to(index, reason)
    local list = candidates()
    if #list < 2 then return false end
    sync_quality()
    local current = 1
    for i, item in ipairs(list) do
        if item.id == current_quality then current = i; break end
    end
    index = math.max(1, math.min(#list, index))
    if index == current or switches >= math.max(1, o.max_switches_per_file) then return false end
    if mp.get_time() - last_switch < math.max(0, o.downgrade_cooldown) then return false end

    local target = list[index]
    switches = switches + 1
    last_switch = mp.get_time()
    set_data('pending-quality', target.id)
    publish('switching', string.format('%s → %s · %s',
        list[current].quality, target.quality, reason or '网络自适应'))
    mp.commandv('script-message-to', 'online-media', 'online-media-select-quality', target.id)
    if o.show_osd then
        mp.osd_message(string.format('直播画质：%s\n%s', target.quality, reason or '网络自适应'), 3)
    end
    return true
end

local function sample()
    if not is_live() then publish('idle', '当前不是直播'); return end
    sync_quality()
    local now = mp.get_time()
    local cache = mp.get_property_number('demuxer-cache-duration', -1)
    local cache_state = tostring(mp.get_property_native('demuxer-cache-state') or ''):lower()
    local paused_for_cache = mp.get_property_bool('paused-for-cache', false)
    local buffering = cache_state:find('buffer', 1, true) ~= nil
        or cache_state:find('underrun', 1, true) ~= nil
        or paused_for_cache

    if cache < 0 then
        publish('monitoring', '等待直播缓存数据')
        return
    end

    if last_cache ~= nil and now - last_sample > 0 then
        local delta = cache - last_cache
        set_data('cache-delta', delta)
    end
    last_cache, last_sample = cache, now

    local list = candidates()
    if #list < 2 then
        publish('monitoring', string.format('仅有 %d 个可切换画质档位', #list))
        return
    end

    local current = 1
    for i, item in ipairs(list) do if item.id == current_quality then current = i; break end end

    if buffering or cache <= tonumber(o.critical_cache_seconds) then
        low_since = low_since or now
        recover_since = nil
        if now - low_since >= 1.0 then
            if switch_to(current - 1, '缓存即将耗尽，自动降级') then
                low_since = nil
            end
        end
        publish('pressure', string.format('缓存 %.1fs · 当前 %s', cache, list[current].quality))
        return
    end

    if cache <= tonumber(o.low_cache_seconds) then
        low_since = low_since or now
        recover_since = nil
        if now - low_since >= 2.0 then
            if switch_to(current - 1, '缓存不足，自动降级') then low_since = nil end
        end
        publish('low', string.format('缓存 %.1fs · 当前 %s', cache, list[current].quality))
        return
    end

    low_since = nil
    if cache >= tonumber(o.recover_cache_seconds) and not buffering then
        recover_since = recover_since or now
        if o.prefer_quality ~= 'balanced' and now - recover_since >= tonumber(o.upgrade_hold_seconds) then
            if switch_to(current + 1, '缓存稳定，自动恢复画质') then recover_since = nil end
        end
    else
        recover_since = nil
    end
    publish('stable', string.format('缓存 %.1fs · %s', cache, list[current].quality))
end

mp.register_event('start-file', reset)
mp.observe_property('user-data/online-media/content-type', 'native', function() sync_quality() end)
mp.observe_property('user-data/online-media/quality-id', 'native', function() sync_quality() end)
mp.observe_property('user-data/online-media/quality-options-json', 'native', function() end)

if o.enabled then
    timer = mp.add_periodic_timer(math.max(0.5, tonumber(o.sample_interval) or 2), sample)
    publish('idle', '等待直播')
end
