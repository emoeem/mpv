-- sleep-timer.lua - 睡眠定时器
-- 只通过 input.conf 的显式绑定和 script-opts/sleep_timer.conf 配置，
-- 脚本内不注册裸键位，避免与 input.conf 的键位策略冲突。
--
-- 计时与显示分离：真正的截止时间由一次性 timeout 承载，另用一个 1 秒周期
-- timer 只负责刷新 OSD 和底栏徽标。若让周期 timer 参与计时，每秒回调的
-- 累积误差会让几十分钟后的触发点明显偏移。
-- 暂停感知（pause_aware）是两种计时模型里的特例，只能由周期 timer 递减，
-- 因此该模式下不使用一次性 timeout，避免与 tick 双重触发。

local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    -- 打开菜单时的默认分钟数，也是 input.conf 未指定参数时的回退值
    default_minutes = 30,
    -- quit / quit-watch-later / pause
    action = 'quit',
    -- 关闭时按墙钟计时（暂停也计入）；开启时只累计实际播放时间
    pause_aware = false,
    -- 进入最后多少秒后每秒刷新一次倒计时
    warn_seconds = 60,
    -- 是否向 uosc 注册底栏按钮数据
    button = true,
}
options.read_options(o, 'sleep_timer')

local ACTIONS = {
    quit = {
        label = '退出播放器',
        run = function() mp.commandv('quit') end,
    },
    ['quit-watch-later'] = {
        label = '退出并保存进度',
        run = function() mp.commandv('quit-watch-later') end,
    },
    pause = {
        label = '暂停播放',
        run = function() mp.set_property_native('pause', true) end,
    },
}

-- 菜单里需要固定顺序，pairs 遍历 ACTIONS 不稳定
local ACTION_ORDER = { 'quit', 'quit-watch-later', 'pause' }

local state = {
    active = false,
    total = 0,
    -- 非暂停感知模式下这是排程瞬间的剩余秒数，随 set_at 一起推算当前值
    remaining = 0,
    -- 暂停感知模式下这是唯一的时间来源，由 tick 递减
    set_at = 0,
    action = 'quit',
}

local action_timer = nil
local tick_timer = nil
local last_badge = nil
local uosc_available = false

local function action_label()
    local act = ACTIONS[state.action]
    return act and act.label or ACTIONS.quit.label
end

local function format_remaining(seconds)
    seconds = math.max(0, math.floor((seconds or 0) + 0.5))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format('%d:%02d:%02d', h, m, s)
    end
    return string.format('%02d:%02d', m, s)
end

local function current_remaining()
    if not state.active then return 0 end
    if o.pause_aware then
        return math.max(0, state.remaining)
    end
    return math.max(0, state.remaining - (mp.get_time() - state.set_at))
end

local function cancel_timers()
    if action_timer then
        action_timer:kill()
        action_timer = nil
    end
    if tick_timer then
        tick_timer:kill()
        tick_timer = nil
    end
end

local function publish()
    mp.set_property_bool('user-data/sleep-timer/active', state.active)
    mp.set_property_number('user-data/sleep-timer/remaining', math.floor(current_remaining()))
    mp.set_property('user-data/sleep-timer/action', state.action or '')
end

local function update_button()
    if not o.button then return end
    local data = {
        icon = 'timer',
        active = state.active,
        command = 'script-message-to sleep_timer open-menu',
        tooltip = state.active
            and ('睡眠定时器：' .. format_remaining(current_remaining()) .. ' 后' .. action_label())
            or '睡眠定时器：未启用',
    }
    if state.active then
        -- 徽标按分钟向上取整，避免最后一分钟显示 0
        data.badge = tostring(math.max(1, math.ceil(current_remaining() / 60)))
        data.secondary_command = 'script-message-to sleep_timer cancel'
    end
    mp.commandv('script-message-to', 'uosc', 'set-button', 'sleep_timer', utils.format_json(data))
end

local function clear_state(message, duration)
    cancel_timers()
    state.active = false
    state.total = 0
    state.remaining = 0
    last_badge = nil
    publish()
    update_button()
    if message then
        mp.osd_message(message, duration or 3)
    end
end

local function fire()
    local label = action_label()
    local run = (ACTIONS[state.action] or ACTIONS.quit).run
    -- 先清状态再执行动作：quit 之后脚本不会再有机会清理
    clear_state(nil)
    mp.osd_message('睡眠定时器：' .. label, 3)
    run()
end

local function tick()
    if not state.active then return end

    if o.pause_aware then
        if not mp.get_property_native('pause', false) then
            state.remaining = state.remaining - 1
        end
        if current_remaining() <= 0 then
            fire()
            return
        end
    end

    local remaining = current_remaining()

    if remaining <= o.warn_seconds then
        mp.osd_message(
            '睡眠定时器：' .. format_remaining(remaining) .. ' 后' .. action_label(),
            1.1
        )
    end

    -- 只在分钟数变化时重发按钮数据，避免每秒一次 script-message
    local minutes = math.ceil(remaining / 60)
    if minutes ~= last_badge then
        last_badge = minutes
        update_button()
    end
end

local function schedule()
    cancel_timers()
    if not state.active then return end
    if not o.pause_aware then
        action_timer = mp.add_timeout(current_remaining(), fire)
    end
    tick_timer = mp.add_periodic_timer(1, tick)
end

local function set_timer(minutes)
    minutes = tonumber(minutes)
    if not minutes or minutes <= 0 then
        mp.osd_message('睡眠定时器：分钟数无效', 3)
        return
    end
    cancel_timers()
    state.active = true
    state.total = minutes * 60
    state.remaining = state.total
    state.set_at = mp.get_time()
    state.action = ACTIONS[o.action] and o.action or 'quit'
    last_badge = nil
    schedule()
    publish()
    update_button()
    mp.osd_message(
        string.format('睡眠定时器：%d 分钟后%s', minutes, action_label()),
        4
    )
end

local function extend(minutes)
    minutes = tonumber(minutes)
    if not state.active then
        set_timer(minutes or o.default_minutes)
        return
    end
    if not minutes or minutes <= 0 then return end
    if o.pause_aware then
        state.remaining = state.remaining + minutes * 60
    else
        -- 把已流逝的时间折进剩余量再重新排程，否则 set_at 之前的消耗会被重算
        state.remaining = current_remaining() + minutes * 60
        state.set_at = mp.get_time()
    end
    state.total = state.total + minutes * 60
    if state.total < 0 then state.total = 0 end
    last_badge = nil
    schedule()
    publish()
    update_button()
    mp.osd_message(
        string.format('睡眠定时器：延长 %d 分钟，剩余 %s', minutes, format_remaining(current_remaining())),
        3
    )
end

local function set_action(id)
    if not ACTIONS[id] then
        mp.osd_message('睡眠定时器：未知动作 ' .. tostring(id), 3)
        return
    end
    state.action = id
    publish()
    update_button()
    mp.osd_message('睡眠定时器动作：' .. action_label(), 3)
end

-- 自定义分钟数走 uosc 的可搜索菜单，而不是 mp.input：
-- 本构建的 mp.input 依赖 console 且实际为 nil，直接调用会在用户操作时抛错。
-- uosc 会把搜索框内容作为 on_search 命令的最后一个参数回传（Menu.lua:1394）。
local function ask_custom()
    if not uosc_available then
        mp.osd_message('睡眠定时器：uosc 未加载，请用 CTRL+ALT+m 的预设分钟数', 4)
        return
    end
    local menu = {
        type = 'sleep_timer_input',
        title = '睡眠定时器：输入分钟数',
        search_style = 'palette',
        search_debounce = 'submit',
        search_suggestion = tostring(o.default_minutes),
        on_search = { 'script-message-to', 'sleep_timer', 'apply-custom' },
        footnote = '输入分钟数后按 Enter，Esc 返回',
        items = {
            {
                title = '输入 1 以上的整数分钟数，例如 25',
                value = 'ignore',
                selectable = false,
                muted = true,
                align = 'center',
            },
        },
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
end

local function apply_custom(text)
    local minutes = tonumber(text)
    if not minutes or minutes <= 0 then
        mp.osd_message('睡眠定时器：请输入 1 以上的分钟数', 3)
        return
    end
    set_timer(minutes)
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'sleep_timer_input')
end

local function build_menu_items()
    local items = {}

    if state.active then
        items[#items + 1] = {
            title = '剩余 ' .. format_remaining(current_remaining()),
            hint = '动作：' .. action_label(),
            muted = true,
            selectable = false,
        }
        items[#items + 1] = { title = '---', separator = true }
    end

    for _, minutes in ipairs({ 15, 30, 45, 60, 90, 120 }) do
        items[#items + 1] = {
            title = string.format('%d 分钟', minutes),
            value = string.format('script-message-to sleep_timer set %d', minutes),
            active = state.active and state.total == minutes * 60,
        }
    end

    items[#items + 1] = {
        title = '自定义分钟数…',
        value = 'script-message-to sleep_timer ask-custom',
    }

    items[#items + 1] = { title = '---', separator = true }

    for _, id in ipairs(ACTION_ORDER) do
        items[#items + 1] = {
            title = '到点动作：' .. ACTIONS[id].label,
            value = 'script-message-to sleep_timer set-action ' .. id,
            active = state.action == id,
            keep_open = false,
        }
    end

    if state.active then
        items[#items + 1] = { title = '---', separator = true }
        items[#items + 1] = {
            title = '取消定时',
            value = 'script-message-to sleep_timer cancel',
        }
    end

    return items
end

local function open_menu()
    if not uosc_available then
        -- 本配置以 uosc 为硬依赖，没有 uosc 时不假装提供列表菜单，
        -- 只把可用的预设分钟数告诉用户，避免静默无响应。
        mp.osd_message(
            '睡眠定时器：uosc 未加载。可用 script-message sleep_timer set <分钟> 设置',
            4
        )
        return
    end

    local menu = {
        type = 'sleep_timer',
        title = '睡眠定时器',
        min_width = 420,
        items = build_menu_items(),
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
end

mp.register_script_message('open-menu', open_menu)
mp.register_script_message('set', set_timer)
mp.register_script_message('extend', extend)
mp.register_script_message('set-action', set_action)
mp.register_script_message('ask-custom', ask_custom)
mp.register_script_message('apply-custom', apply_custom)
mp.register_script_message('cancel', function()
    if not state.active then
        mp.osd_message('睡眠定时器未启用', 2)
        return
    end
    clear_state('睡眠定时器已取消', 3)
end)
mp.register_script_message('toggle', function()
    if state.active then
        clear_state('睡眠定时器已取消', 3)
    else
        set_timer(o.default_minutes)
    end
end)
mp.register_script_message('uosc-version', function()
    uosc_available = true
    update_button()
end)

mp.add_key_binding(nil, 'toggle', function()
    if state.active then
        clear_state('睡眠定时器已取消', 3)
    else
        set_timer(o.default_minutes)
    end
end)

mp.register_event('shutdown', function()
    cancel_timers()
end)
