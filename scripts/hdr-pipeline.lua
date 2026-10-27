-- hdr-pipeline.lua - HDR 处理链双模式：原生直通 / hdr-toys
--
-- 为什么用脚本而不是直接 include hdr-toys.conf：
-- 上游 conf 在顶层写 tone-mapping=clip、gamut-mapping-mode=clip、
-- target-colorspace-hint=no，与本配置常驻的 HDR2SDR（mpv.conf:309）以及
-- HDR / HDR-PASS 自动 profile 是替代关系而不是叠加关系。直接 include 会
-- 永久关闭原生直通链，且没有运行时切回的途径。
--
-- 这里的做法：
--   进入 toys 模式时快照被争抢的属性并接管，退出时按快照还原；
--   期间观察这些属性，把 input.conf 的 HDR 热键、uosc 的 target-peak 菜单、
--   [HDR] / [HDR-PASS] 自动 profile 写回的值纠正回来。
--   linux-video-policy.lua 另有让位判断，避免每次切文件都对打一轮。
--
-- hdr-toys 的 gamut-mapping/bottosson.glsl 按 BT.709 目标硬编码、假定工作空间
-- 是 BT.2020，所以只对 BT.2020 片源生效。非 BT.2020 的 PQ/HLG 以及线性图像
-- 自动回退到原生链，避免出现「内置映射被关闭、toys 链又不匹配」的裸 clip。

local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    -- 启动模式：native 或 toys。默认 native，保持现有直通链为默认行为。
    mode = 'native',
    -- 被接管的属性漂移后延迟多久纠正（秒）
    guard_delay = 0.08,
    -- 定期复查间隔（秒）；0 表示只依赖属性观察
    guard_interval = 1.0,
    -- 是否用 OSD 提示模式切换与回退
    osd = true,
}

options.read_options(o, 'hdr_pipeline')

local TOYS_ROOT = '~~/shaders/hdr-toys'

-- 进入 toys 后必须固定的基础属性。
-- target-peak / target-contrast 不在上游 conf 里显式设置（上游建议不要设），
-- 但 uosc 的 target-peak 菜单和 [HDR画质] profile 会写它们，而在 clip 模式下
-- 这些值会重新引入一层内置峰值决策，所以统一固定成 auto 并纳入守护。
local BASE_PROPS = {
    ['tone-mapping'] = 'clip',
    ['gamut-mapping-mode'] = 'clip',
    ['target-colorspace-hint'] = 'no',
    ['target-peak'] = 'auto',
    ['target-contrast'] = 'auto',
    ['icc-profile'] = '',
    ['icc-profile-auto'] = 'no',
    ['inverse-tone-mapping'] = 'no',
}

-- 每种片源对应的目标参数与着色器链，顺序来自上游 hdr-toys.conf
local CHAINS = {
    pq = {
        label = 'BT.2020 PQ',
        target = { ['target-prim'] = 'bt.2020', ['target-trc'] = 'pq' },
        shaders = {
            'utils/clip_both.glsl',
            'transfer-function/pq_inv.glsl',
            'tone-mapping/astra.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
        },
        -- astra 的自动曝光上限，对应上游的 glsl-shader-opts-append
        opts = 'astra/auto_exposure_limit_positive=1.02',
    },
    hlg = {
        label = 'BT.2020 HLG',
        target = { ['target-prim'] = 'bt.2020', ['target-trc'] = 'hlg' },
        shaders = {
            'utils/clip_both.glsl',
            'transfer-function/hlg_inv.glsl',
            'tone-mapping/astra.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
        },
        opts = 'astra/auto_exposure_limit_positive=1.02',
    },
    sdr2020 = {
        label = 'BT.2020 SDR',
        target = { ['target-prim'] = 'bt.2020', ['target-trc'] = 'bt.1886' },
        shaders = {
            'transfer-function/bt1886_inv.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
        },
        opts = '',
    },
}

-- 需要快照、还原与守护的属性。
-- target-peak / target-contrast 不在 toys 的显式设置里，但 uosc 菜单会写它们，
-- 留给「回退到原生」分支还原，所以一并纳入管理。
local MANAGED = {
    'tone-mapping',
    'gamut-mapping-mode',
    'target-colorspace-hint',
    'target-colorspace-hint-mode',
    'target-prim',
    'target-trc',
    'target-peak',
    'target-contrast',
    'icc-profile',
    'icc-profile-auto',
    'inverse-tone-mapping',
}

local state = {
    mode = 'native',
    engaged = false,
    kind = nil,          -- pq / hlg / sdr2020 / nil（回退）
    snapshot = {},
    guard_timer = nil,
    apply_timer = nil,
    last_notice = 0,
}

local function expand(path)
    return mp.command_native({ 'expand-path', path })
end

local function is_toys_shader(path)
    return type(path) == 'string' and path:find('/shaders/hdr%-toys/') ~= nil
end

local function strip_toys(list)
    local out = {}
    for _, path in ipairs(list or {}) do
        if not is_toys_shader(path) then
            out[#out + 1] = path
        end
    end
    return out
end

local function detect_kind()
    local prim = tostring(mp.get_property('video-params/primaries', '') or ''):lower()
    local gamma = tostring(mp.get_property('video-params/gamma', '') or ''):lower()
    if prim ~= 'bt.2020' then
        return nil, prim, gamma
    end
    if gamma == 'pq' then return 'pq', prim, gamma end
    if gamma == 'hlg' then return 'hlg', prim, gamma end
    if gamma == 'bt.1886' then return 'sdr2020', prim, gamma end
    return nil, prim, gamma
end

local function publish(chain, reason)
    mp.set_property_bool('user-data/hdr-pipeline/active', state.mode == 'toys')
    mp.set_property('user-data/hdr-pipeline/mode', state.mode)
    mp.set_property('user-data/hdr-pipeline/chain', chain or '')
    mp.set_property('user-data/hdr-pipeline/reason', reason or '')
end

local function notice(text)
    if not o.osd then return end
    mp.osd_message(text, 3)
end

local function snapshot()
    if state.engaged then return end
    state.snapshot = {}
    for _, prop in ipairs(MANAGED) do
        state.snapshot[prop] = mp.get_property(prop)
    end
    state.engaged = true
    msg.verbose('hdr-pipeline: 已快照托管属性')
end

local function restore()
    if not state.engaged then return end
    for _, prop in ipairs(MANAGED) do
        local value = state.snapshot[prop]
        if value ~= nil and value ~= '' then
            mp.set_property(prop, value)
        end
    end
    -- 着色器列表按「剔除 toys 项」恢复，不用快照，
    -- 否则用户在 toys 期间手动开关的着色器会被一起回滚
    local list = strip_toys(mp.get_property_native('glsl-shaders'))
    mp.set_property_native('glsl-shaders', list)
    mp.set_property('glsl-shader-opts', '')
    state.engaged = false
    state.snapshot = {}
    msg.verbose('hdr-pipeline: 已还原托管属性')
end

-- 回退分支使用的原生基线。
-- 不能直接用快照：快照是进入 toys 那一刻取的，切换片源后可能残留上一支片子的
-- 目标参数（例如上一支是宽色域 SDR，[SDR-gamut] 把 gamut-mapping-mode 设成了
-- clip）。这里改成固定的原生默认值，与 HDR2SDR / linux-video-policy 的意图一致；
-- ICC 相关项仍从快照取，避免抹掉用户手动启用的 ICC 方案。
local FALLBACK_PROPS = {
    ['tone-mapping'] = 'auto',
    ['gamut-mapping-mode'] = 'auto',
    ['target-colorspace-hint'] = 'auto',
    ['target-prim'] = 'auto',
    ['target-trc'] = 'auto',
    ['target-peak'] = 'auto',
    ['target-contrast'] = 'auto',
}

-- 回退时从快照继承、不强行改写的属性。
-- inverse-tone-mapping 在 [HDR-PASS] 里是 no、全局配置里是 yes，
-- 只有快照知道当前片源该用哪个；ICC 两项同理，避免抹掉用户手动启用的方案。
local FALLBACK_FROM_SNAPSHOT = {
    'inverse-tone-mapping', 'icc-profile', 'icc-profile-auto',
}

local function fallback_props()
    local want = {}
    for prop, value in pairs(FALLBACK_PROPS) do want[prop] = value end
    for _, prop in ipairs(FALLBACK_FROM_SNAPSHOT) do
        local value = state.snapshot[prop]
        if value ~= nil and value ~= '' then want[prop] = value end
    end
    return want
end

local function expected_props()
    if state.mode ~= 'toys' then return nil end
    if state.kind then
        local want = {}
        for prop, value in pairs(BASE_PROPS) do want[prop] = value end
        for prop, value in pairs(CHAINS[state.kind].target) do want[prop] = value end
        return want
    end
    return fallback_props()
end

local function apply_toys(kind)
    local chain = CHAINS[kind]
    for prop, value in pairs(BASE_PROPS) do
        mp.set_property(prop, value)
    end
    for prop, value in pairs(chain.target) do
        mp.set_property(prop, value)
    end

    local list = strip_toys(mp.get_property_native('glsl-shaders'))
    for _, rel in ipairs(chain.shaders) do
        list[#list + 1] = expand(TOYS_ROOT .. '/' .. rel)
    end
    mp.set_property_native('glsl-shaders', list)
    mp.set_property('glsl-shader-opts', chain.opts or '')
end

local function apply_native_values()
    local want = fallback_props()
    for prop, value in pairs(want) do
        mp.set_property(prop, value)
    end
    mp.set_property_native('glsl-shaders', strip_toys(mp.get_property_native('glsl-shaders')))
    mp.set_property('glsl-shader-opts', '')
end

-- 把被其他写入方改掉的属性纠正回来
local function reassert()
    local want = expected_props()
    if not want then return end
    local fixed = {}
    for prop, value in pairs(want) do
        if mp.get_property(prop) ~= value then
            mp.set_property(prop, value)
            fixed[#fixed + 1] = prop
        end
    end

    -- toys 链被整体替换（例如手动应用了着色器配置组）时补回
    if state.kind then
        local list = mp.get_property_native('glsl-shaders') or {}
        local have = false
        for _, path in ipairs(list) do
            if is_toys_shader(path) then have = true break end
        end
        if not have then
            apply_toys(state.kind)
            fixed[#fixed + 1] = 'glsl-shaders'
        end
    end

    if #fixed > 0 then
        msg.verbose('hdr-pipeline: 纠正被改写的属性 ' .. table.concat(fixed, ','))
        -- 用户主动按键触发的改写，提示一次就够，避免每次纠正都刷屏
        local now = mp.get_time()
        if now - state.last_notice > 5 then
            state.last_notice = now
            notice('hdr-toys 模式：已恢复被改写的色彩参数')
        end
    end
end

local function schedule_reassert()
    if state.mode ~= 'toys' then return end
    if state.apply_timer then return end
    state.apply_timer = mp.add_timeout(o.guard_delay, function()
        state.apply_timer = nil
        reassert()
    end)
end

local function apply_now(show_osd)
    if state.mode ~= 'toys' then
        restore()
        publish('', 'native')
        return
    end

    snapshot()
    local kind, prim, gamma = detect_kind()
    if kind then
        apply_toys(kind)
        state.kind = kind
        publish(kind, string.format('toys/%s', kind))
        if show_osd then
            notice(string.format('hdr-toys：使用 %s 链路', CHAINS[kind].label))
        end
    else
        apply_native_values()
        state.kind = nil
        publish('fallback', string.format('toys 回退原生（primaries=%s gamma=%s）',
            prim ~= '' and prim or '?', gamma ~= '' and gamma or '?'))
        if show_osd then
            notice('hdr-toys：当前片源不是 BT.2020，已回退原生链')
        end
    end
end

local function set_mode(mode)
    mode = tostring(mode or ''):lower()
    if mode ~= 'native' and mode ~= 'toys' then
        mp.osd_message('hdr-pipeline：未知模式 ' .. tostring(mode), 3)
        return
    end
    if state.mode == mode then
        notice('hdr-toys 模式：' .. (mode == 'toys' and '已启用' or '已关闭'))
        return
    end
    state.mode = mode
    state.kind = nil
    apply_now(true)
    if mode == 'native' then
        notice('HDR 处理链：原生直通')
    end
end

local function toggle()
    set_mode(state.mode == 'toys' and 'native' or 'toys')
end

-- ===== 事件与守护 =====

for _, prop in ipairs(MANAGED) do
    mp.observe_property(prop, 'string', function()
        if state.mode == 'toys' then
            schedule_reassert()
        end
    end)
end

mp.observe_property('glsl-shaders', 'native', function()
    if state.mode == 'toys' then
        schedule_reassert()
    end
end)

mp.register_event('file-loaded', function()
    mp.add_timeout(0.05, function()
        if state.mode == 'toys' then
            apply_now(false)
        end
    end)
end)

-- 片源属性变化（例如切换章节后色彩参数刷新）时重新选链
for _, prop in ipairs({ 'video-params/primaries', 'video-params/gamma' }) do
    mp.observe_property(prop, 'string', function()
        if state.mode == 'toys' then
            mp.add_timeout(0.05, function()
                if state.mode == 'toys' then apply_now(false) end
            end)
        end
    end)
end

if (tonumber(o.guard_interval) or 0) > 0 then
    state.guard_timer = mp.add_periodic_timer(o.guard_interval, function()
        if state.mode == 'toys' then reassert() end
    end)
end

mp.register_event('end-file', function()
    state.kind = nil
end)

mp.register_event('shutdown', function()
    if state.guard_timer then state.guard_timer:kill() end
    if state.apply_timer then state.apply_timer:kill() end
end)

mp.register_script_message('toggle', toggle)
mp.register_script_message('set-mode', set_mode)
mp.register_script_message('status', function()
    mp.osd_message(string.format('HDR 处理链：%s · %s',
        state.mode, state.kind and CHAINS[state.kind].label or '回退原生'), 3)
end)
mp.add_key_binding(nil, 'toggle', toggle)

-- 启动时按配置决定初始模式
if tostring(o.mode):lower() == 'toys' then
    mp.add_timeout(0.5, function()
        state.mode = 'toys'
        apply_now(false)
    end)
else
    publish('', 'native')
end
