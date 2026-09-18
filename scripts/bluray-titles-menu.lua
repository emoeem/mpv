-- 蓝光 / UHD 原盘标题列表。
-- 只读取当前核心已经枚举的 edition-list，不接管 ISO 加载、DVD 回退或原盘菜单会话。
local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local MENU_TYPE = 'bluray_titles_menu'
local o = {
    title_format = 'full',
    osd_feedback = true,
    slow_feedback_delay = 3,
    slow_feedback_timeout = 12,
}
options.read_options(o, 'bluray_titles_menu')

local media_loaded = false
local pending_switch
local slow_feedback_timer
local timeout_feedback_timer
local health_timer

local function stop_timer(timer)
    if timer then timer:kill() end
end

local function publish_switch_state(state, target_id)
    mp.set_property('user-data/bluray-titles-menu/switch-state', state or 'idle')
    mp.set_property_number('user-data/bluray-titles-menu/switch-target-id',
        tonumber(target_id) or -1)
end

local function clear_pending_switch(state)
    stop_timer(slow_feedback_timer)
    stop_timer(timeout_feedback_timer)
    stop_timer(health_timer)
    slow_feedback_timer = nil
    timeout_feedback_timer = nil
    health_timer = nil
    pending_switch = nil
    publish_switch_state(state or 'idle', -1)
end

local function switch_label(target)
    return '蓝光标题 ' .. string.format('%02d', target.ordinal)
end

local function begin_pending_switch(target)
    clear_pending_switch()
    pending_switch = {
        id = target.id,
        ordinal = target.ordinal,
        confirmed = false,
    }
    publish_switch_state('switching', target.id)

    if o.osd_feedback then
        -- This must be visible before the synchronous native edition command.
        -- Cloud-drive mounts can block while libbluray seeks into another MPLS.
        mp.osd_message('正在切换到' .. switch_label(target) .. '…',
            math.max(2, tonumber(o.slow_feedback_delay) or 3))
    end

    -- Compare the transaction itself: A -> B -> A must not revive A's timers.
    local expected = pending_switch
    slow_feedback_timer = mp.add_timeout(
        math.max(1, tonumber(o.slow_feedback_delay) or 3), function()
            if pending_switch ~= expected then return end
            if o.osd_feedback then
                local prefix = pending_switch.confirmed and '已选定' or '正在切换到'
                mp.osd_message(prefix .. switch_label(pending_switch)
                    .. '，原盘画面读取中…', 6)
            end
        end)
    timeout_feedback_timer = mp.add_timeout(
        math.max(4, tonumber(o.slow_feedback_timeout) or 12), function()
            if pending_switch ~= expected then return end
            publish_switch_state('slow', expected.id)
            msg.warn(string.format(
                '[bluray-titles-menu] 标题 %02d 已请求，尚未确认播放恢复',
                pending_switch.ordinal))
            if o.osd_feedback then
                mp.osd_message(switch_label(pending_switch)
                    .. '读取较慢 · 请稍候，也可重新选择标题', 7)
            end
        end)
end

local function check_switch_health()
    local pending = pending_switch
    if not pending or not pending.restarted then return end
    if tonumber(mp.get_property_native('current-edition')) ~= pending.id
        or mp.get_property_native('seeking')
        or mp.get_property_native('eof-reached')
        or mp.get_property_native('idle-active')
        or mp.get_property_native('paused-for-cache') then return end

    local audio_selected = false
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'audio' and track.selected then audio_selected = true end
    end
    local position = mp.get_property_number('time-pos')
    local audio_pts = mp.get_property_number('audio-pts')
    if not position or (audio_selected and not audio_pts) then return end

    local paused = mp.get_property_native('pause')
    if not paused then
        -- A playback-restart may also occur with an empty audio decoder. Only
        -- accept progress after the new seek/restart, never the old title queue.
        local progressed = pending.position and position > pending.position + 0.05
        local audio_progressed = not audio_selected or
            (pending.audio_pts and audio_pts > pending.audio_pts + 0.05)
        pending.position, pending.audio_pts = position, audio_pts
        if not progressed or not audio_progressed then return end
    end
    clear_pending_switch('ready')
    msg.info(string.format('[bluray-titles-menu] 标题 %02d 已%s',
        pending.ordinal, paused and '就绪（暂停）' or '恢复播放'))
    if o.osd_feedback then
        mp.osd_message(switch_label(pending) .. (paused and '已就绪（暂停）' or '已开始播放'), 2)
    end
end

local function is_bluray_stream()
    local path = tostring(mp.get_property('path') or '')
    local stream = tostring(mp.get_property('stream-open-filename') or '')
    if path:match('^dvd://') or stream:match('^dvd://') then return false end
    return path:match('^bd://') ~= nil or stream:match('^bd://') ~= nil
end

local function is_bluray_active()
    return media_loaded and is_bluray_stream()
end

local function format_duration(raw)
    local hours, minutes, seconds = tostring(raw or ''):match(
        '(%d+):(%d%d):(%d%d)%.?%d*')
    if not hours then return nil end
    return string.format('%02d:%02d:%02d',
        tonumber(hours), tonumber(minutes), tonumber(seconds))
end

local function parse_title(edition)
    if type(edition) ~= 'table' then return nil end
    local source = tostring(edition.title
        or (edition.metadata and edition.metadata.TITLE) or '')
    local ordinal = source:lower():match('^%s*title:%s*(%d+)')
        or source:lower():match('^%s*title%s+(%d+)')
    local id = tonumber(edition.id)
    if not ordinal or id == nil then return nil end

    return {
        id = id,
        ordinal = tonumber(ordinal),
        duration = format_duration(source),
        playlist = source:lower():match('(%d+%.mpls)'),
    }
end

local function get_titles()
    local result = {}
    local editions = mp.get_property_native('edition-list')
    for _, edition in ipairs(type(editions) == 'table' and editions or {}) do
        local title = parse_title(edition)
        if title then result[#result + 1] = title end
    end
    table.sort(result, function(left, right)
        if left.ordinal == right.ordinal then return left.id < right.id end
        return left.ordinal < right.ordinal
    end)
    return result
end

local function publish_state(titles)
    local active = is_bluray_active()
    local current_edition = mp.get_property_native('current-edition')
    titles = active and (titles or get_titles()) or {}
    mp.set_property_bool('user-data/bluray-titles-menu/active', active)
    mp.set_property_number('user-data/bluray-titles-menu/count', #titles)
    mp.set_property_number('user-data/bluray-titles-menu/current-id',
        active and (tonumber(current_edition) or -1) or -1)
end

local function format_title(ordinal)
    if o.title_format == 'index' then
        return string.format('%02d', ordinal)
    end
    return string.format('标题 %02d', ordinal)
end

local function status_item(title, hint)
    return {
        title = title,
        hint = hint,
        selectable = false,
        muted = true,
        interaction_role = 'status',
    }
end

local function open_menu()
    local active = is_bluray_active()
    local titles = active and get_titles() or {}
    local current_edition = mp.get_property_native('current-edition')
    local current_id = tonumber(current_edition)
    local items = {}
    local selected_index

    if not active then
        items[1] = status_item('当前未打开蓝光原盘',
            '请先打开本地或网盘蓝光 / UHD ISO')
    elseif #titles == 0 then
        items[1] = status_item('当前原盘没有可切换标题',
            '标题仍在读取时可稍后重新打开此页面')
    else
        for _, title in ipairs(titles) do
            local hint = title.duration or '时长未知'
            items[#items + 1] = {
                title = format_title(title.ordinal),
                hint = hint,
                value = title.id,
                active = title.id == current_id,
            }
            if title.id == current_id then selected_index = #items end
        end
    end

    publish_state(titles)
    local menu = {
        type = MENU_TYPE,
        title = '蓝光标题列表',
        fixed_columns = true,
        uniform_title_size = true,
        min_width = 380,
        search_style = #items > 12 and 'on_demand' or 'disabled',
        selected_index = selected_index or 1,
        callback = {mp.get_script_name(), 'menu-event'},
        footnote = active
            and '选择标题后直接切换 · 不重新扫描或重载 ISO'
            or '仅读取当前原盘信息，不接管 ISO 加载与 DVD 回退',
        items = items,
    }
    local current_type = mp.get_property_native('user-data/uosc/menu/type')
    mp.commandv('script-message-to', 'uosc',
        current_type == MENU_TYPE and 'update-menu' or 'open-menu',
        utils.format_json(menu))
end

local function switch_title(id)
    id = tonumber(id)
    if id == nil or not is_bluray_active() then return end

    local selected
    for _, title in ipairs(get_titles()) do
        if title.id == id then
            selected = title
            break
        end
    end
    if not selected then
        mp.osd_message('该蓝光标题已不可用', 3)
        return
    end

    mp.commandv('script-message-to', 'uosc', 'close-menu', MENU_TYPE)
    if not pending_switch and
        tonumber(mp.get_property_native('current-edition')) == selected.id then
        clear_pending_switch('ready')
        if o.osd_feedback then
            mp.osd_message('当前已是' .. switch_label(selected), 2)
        end
        return
    end

    begin_pending_switch(selected)
    local ok, err = pcall(mp.commandv, 'set', 'edition', tostring(selected.id))
    if not ok then
        clear_pending_switch('failed')
        msg.error('[bluray-titles-menu] 原生标题切换失败：' .. tostring(err))
        if o.osd_feedback then
            mp.osd_message(switch_label(selected) .. '切换失败', 4)
        end
    end
end

mp.register_script_message('open', open_menu)
mp.add_key_binding(nil, 'open', open_menu)
mp.register_script_message('menu-event', function(json)
    local event = utils.parse_json(json)
    if type(event) ~= 'table' or event.type ~= 'activate' or event.action then
        return
    end
    switch_title(event.value)
end)

mp.register_event('start-file', function()
    clear_pending_switch()
    media_loaded = false
    publish_state({})
end)
mp.register_event('file-loaded', function()
    media_loaded = true
    publish_state()
end)
mp.register_event('end-file', function()
    clear_pending_switch()
    media_loaded = false
    publish_state({})
end)
mp.register_event('seek', function()
    if not pending_switch then return end
    pending_switch.saw_seek = true
    pending_switch.restarted = false
    pending_switch.position, pending_switch.audio_pts = nil, nil
end)
mp.register_event('playback-restart', function()
    if not pending_switch or not pending_switch.saw_seek then return end
    if tonumber(mp.get_property_native('current-edition')) ~= pending_switch.id then return end
    pending_switch.restarted = true
    if not health_timer then health_timer = mp.add_periodic_timer(0.25, check_switch_health) end
    check_switch_health()
end)
mp.observe_property('current-edition', 'native', function(_, value)
    if pending_switch and tonumber(value) == pending_switch.id
        and not pending_switch.confirmed then
        pending_switch.confirmed = true
        publish_switch_state('confirmed', pending_switch.id)
        msg.info(string.format('[bluray-titles-menu] 核心已选定标题 %02d，等待播放恢复',
            pending_switch.ordinal))
    end
    publish_state()
end)
mp.observe_property('edition-list', 'native', function()
    publish_state()
end)

publish_state()
publish_switch_state('idle', -1)
msg.info('[bluray-titles-menu] 已加载：使用原生 edition-list，不接管原盘加载流程')
