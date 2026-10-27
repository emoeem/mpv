-- system-monitor.lua - 系统监控 OSD（CPU/GPU 温度、功耗、内存、电池）
--
-- 对照 Mpv∞ 的 Stats Page 6 的桌面等价物：stats.lua 管播放器内部的帧/缓存，
-- 这里管机器本身的温度与供电。数据只读 sysfs 与 nvidia-smi，不做任何写入。
--
-- 采样策略：sysfs 用同步 io.open（微秒级，不影响播放）；nvidia-smi 是子进程，
-- 走异步并在本地缓存上次结果，首次渲染允许暂时缺 GPU 行。
--
-- CTRL+ALT+y 开/关；显示期间每 interval 秒刷新，关闭即停表，不常驻采样。

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    -- 刷新间隔（秒）
    interval = 2,
    -- 左下角边距（按 osd 高度的百分比）
    margin = 4,
    font_size = 16,
    show_gpu = true,
    show_ram = true,
    show_battery = true,
}
options.read_options(o, 'system_monitor')

local overlay = nil
local refresh_timer = nil
local visible = false

-- nvidia-smi 结果缓存：异步回调写入，渲染时直接读
local nvidia_cache = nil

local function read_number(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local v = tonumber(f:read('*l'))
    f:close()
    return v
end

local function read_line(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local v = f:read('*l')
    f:close()
    return v
end

-- CPU 温度：thermal_zone 按 type 优先级挑，都没有再看 hwmon（coretemp/k10temp）
local function cpu_temp()
    local priority = { 'x86_pkg_temp', 'k10temp', 'cpu_thermal', 'acpitz' }
    local zones = {}
    local i = 0
    while i < 32 do
        local base = '/sys/class/thermal/thermal_zone' .. i
        local typ = read_line(base .. '/type')
        if not typ then break end
        zones[#zones + 1] = { type = typ, path = base }
        i = i + 1
    end
    for _, want in ipairs(priority) do
        for _, z in ipairs(zones) do
            if z.type == want then
                local t = read_number(z.path .. '/temp')
                if t and t > 0 then return t / 1000 end
            end
        end
    end
    for _, name in ipairs({ 'coretemp', 'k10temp', 'zenpower' }) do
        local h = 0
        while h < 32 do
            local base = '/sys/class/hwmon/hwmon' .. h
            local n = read_line(base .. '/name')
            if not n then break end
            if n == name then
                local t = read_number(base .. '/temp1_input')
                if t and t > 0 then return t / 1000 end
            end
            h = h + 1
        end
    end
    return nil
end

-- AMD iGPU/dGPU 温度：第一个有温度读数的 amdgpu card
local function amd_gpu_temp()
    for c = 0, 4 do
        local card = '/sys/class/drm/card' .. c
        if read_line(card .. '/device/uevent') then
            local h = 0
            while h < 16 do
                local base = card .. '/device/hwmon/hwmon' .. h
                local t = read_number(base .. '/temp1_input')
                if t and t > 0 then return t / 1000 end
                h = h + 1
            end
        end
    end
    return nil
end

local function query_nvidia()
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = { 'nvidia-smi',
            '--query-gpu=temperature.gpu,utilization.gpu,power.draw,power.limit',
            '--format=csv,noheader,nounits' },
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            nvidia_cache = false -- 明确标记不可用，避免每轮重试渲染等待
            return
        end
        local t, u, p, lim = result.stdout:match('^(%S+),%s*(%S+),%s*(%S+),%s*(%S+)')
        if t then
            nvidia_cache = {
                temp = tonumber(t),
                util = tonumber(u),
                power = tonumber(p),
                limit = tonumber(lim),
            }
        else
            nvidia_cache = false
        end
    end)
end

local function battery()
    for i = 0, 2 do
        local base = '/sys/class/power_supply/BAT' .. i
        local cap = read_number(base .. '/capacity')
        if cap then
            local status = read_line(base .. '/status') or '?'
            return cap, status
        end
    end
    return nil, nil
end

local function ram_used_gb()
    local total, available
    for line in io.lines('/proc/meminfo') do
        local kb = tonumber(line:match('^%S+:?%s+(%d+)'))
        if line:match('^MemTotal:') then total = kb end
        if line:match('^MemAvailable:') then available = kb end
        if total and available then break end
    end
    if not total or not available then return nil end
    return (total - available) / 1048576, total / 1048576
end

local function fmt_temp(t)
    return t and string.format('%d°C', t) or '—'
end

local function collect_lines()
    local lines = {}

    local ct = cpu_temp()
    lines[#lines + 1] = string.format('CPU %s', fmt_temp(ct))

    if o.show_gpu then
        if type(nvidia_cache) == 'table' then
            local n = nvidia_cache
            local util = n.util and (n.util .. '%') or '—'
            local pwr
            if n.power then
                -- 上限读不到（部分驱动返回 [N/A]）时只显示当前功耗，不要 3/0W
                pwr = n.limit
                    and string.format('%.0f/%.0fW', n.power, n.limit)
                    or string.format('%.0fW', n.power)
            else
                pwr = '—'
            end
            lines[#lines + 1] = string.format('GPU %s · %s · %s', fmt_temp(n.temp), util, pwr)
        end
        local at = amd_gpu_temp()
        if at then
            lines[#lines + 1] = string.format('iGPU %s', fmt_temp(at))
        end
    end

    if o.show_ram then
        local used, total = ram_used_gb()
        if used then
            lines[#lines + 1] = string.format('RAM %.1f/%.1fG', used, total)
        end
    end

    if o.show_battery then
        local cap, status = battery()
        if cap then
            -- libass 没有 emoji 回退（见 README），充电状态用文字表达
            local tag = (status == 'Charging' or status == 'Full') and '充电中' or '电池'
            lines[#lines + 1] = string.format('%s %d%%', tag, cap)
        end
    end

    return lines
end

local function render()
    if not overlay then return end
    local lines = collect_lines()
    if #lines == 0 then
        overlay.data = ''
        overlay:update()
        return
    end

    local w, h = mp.get_osd_size()
    -- osd_overlay 的画布默认与实际 OSD 尺寸无关（1280x720 基准），
    -- 不显式同步的话 \pos 坐标会被缩放，面板会画错位置
    overlay.res_x = w
    overlay.res_y = h

    local margin = math.floor(h * (o.margin / 100))
    local fs = math.max(11, math.floor(o.font_size * (h / 1080)))

    local parts = {}
    for _, line in ipairs(lines) do
        parts[#parts + 1] = string.format(
            '{\\fnMFGA YouHei\\fs%d\\c&HCDD6F4&\\3c&H11111B&\\alpha&H30&\\bord1.2\\shad0}\\h%s\\N',
            fs, line)
    end
    -- 整块放在一个 an1 定位事件里（左下角锚点），行间用 \N
    local ass = string.format('{\\an1\\pos(%d,%d)}%s', margin, h - margin,
        table.concat(parts):gsub('\\N$', ''))
    overlay.data = ass
    overlay:update()
end

local function tick()
    if not visible then return end
    if o.show_gpu and nvidia_cache == nil then
        query_nvidia()
    end
    render()
end

local function stop()
    visible = false
    if refresh_timer then
        refresh_timer:kill()
        refresh_timer = nil
    end
    if overlay then
        overlay:remove()
    end
end

local function toggle()
    if visible then
        stop()
        mp.osd_message('系统监控已关闭', 2)
        return
    end
    if not overlay then
        overlay = mp.create_osd_overlay('ass-events')
        overlay.z = 2500
    end
    visible = true
    nvidia_cache = (o.show_gpu and nvidia_cache == nil) and nil or nvidia_cache
    tick()
    refresh_timer = mp.add_periodic_timer(math.max(1, o.interval), tick)
    msg.verbose('系统监控已开启')
end

mp.register_script_message('toggle', toggle)
mp.add_key_binding(nil, 'toggle', toggle)

mp.register_event('shutdown', stop)
