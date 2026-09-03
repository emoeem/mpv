-- Local Bilibili QR login and cookie management for mpv-Yaozhi.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

-- 42 is thumbfast, 49 is idle branding, 50..52 are startup format logos,
-- and 53 is the donation card. Keep this short-lived modal isolated at 54.
local OVERLAY_ID = 54
local MENU_TYPE = 'bilibili_account'
-- Linux port: see online-media.lua (runtime/bin/python3 venv)
local python_path = mp.command_native({'expand-path', '~~/online-media/runtime/bin/python3'})
local helper_path = mp.command_native({'expand-path', '~~/online-media/bilibili_qr_login.py'})
local cookie_path = mp.command_native({'expand-path', '~~/online-media/bilibili-cookies.txt'})
local qr_path = utils.join_path(
    os.getenv('TMPDIR') or '/tmp',
    'mpv-yaozhi-bilibili-login-' .. tostring(utils.getpid()) .. '.bgra'
)

local chrome = mp.create_osd_overlay('ass-events')
chrome.z = 3500

local state = {
    visible = false,
    ticket = 0,
    request = nil,
    status_request = nil,
    poll_timer = nil,
    clock_timer = nil,
    qrcode_key = nil,
    qr_width = 0,
    qr_height = 0,
    overlay_present = false,
    expires_at = 0,
    status = 'idle',
    message = '',
    account_status = 'checking',
    logged_in = false,
}

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function round(value)
    return math.floor(value + 0.5)
end

local function file_exists(path)
    local info = path and utils.file_info(path)
    return info and info.is_file == true
end

local function publish_account()
    mp.set_property_bool('user-data/bilibili-account/logged-in', state.logged_in)
    mp.set_property_native('user-data/bilibili-account/status', state.account_status)
end

local function hide_player_chrome(disabled)
    mp.commandv(
        'script-message-to', 'uosc', 'disable-elements', mp.get_script_name(),
        disabled and table.concat({
            'window_border', 'top_bar', 'timeline', 'controls', 'volume',
            'idle_indicator', 'audio_indicator', 'buffering_indicator',
            'pause_indicator',
        }, ',') or ''
    )
end

local function draw_box(ass, ax, ay, bx, by, radius, color, alpha)
    ass:new_event()
    ass:pos(0, 0)
    ass:append(string.format(
        '{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}', color, alpha or 0
    ))
    ass:draw_start()
    ass:round_rect_cw(ax, ay, bx, by, radius)
    ass:draw_stop()
end

local function add_text(ass, x, y, size, text, color, bold)
    ass:new_event()
    ass:append(string.format(
        '{\\an5\\pos(%d,%d)\\fnMicrosoft YaHei UI\\fs%d\\b%d'
            .. '\\bord0\\shad0\\1c&H%s&}%s',
        round(x), round(y), round(size), bold and 1 or 0,
        color or 'FFFFFF', tostring(text or '')
    ))
end

local function remove_overlay()
    if state.overlay_present then
        pcall(mp.command_native, {'overlay-remove', OVERLAY_ID})
    end
    state.overlay_present = false
    chrome:remove()
end

local function render()
    if not state.visible then return end
    local dimensions = mp.get_property_native('osd-dimensions')
    local width = dimensions and tonumber(dimensions.w) or 0
    local height = dimensions and tonumber(dimensions.h) or 0
    if width <= 0 or height <= 0 then return end

    local ui_scale = clamp(height / 1080, 0.82, 1.45)
    local qr_display = math.min(
        state.qr_width,
        clamp(round(math.min(width, height) * 0.43), 220, 430)
    )
    local card_width = clamp(qr_display + round(96 * ui_scale), 330, width - 24)
    local card_height = qr_display + round(190 * ui_scale)
    card_height = math.min(card_height, height - 24)
    local card_x = round((width - card_width) / 2)
    local card_y = round((height - card_height) / 2)
    local qr_x = round((width - qr_display) / 2)
    local qr_y = card_y + round(70 * ui_scale)

    local ass = assdraw.ass_new()
    draw_box(ass, 0, 0, width, height, 0, '100A05', 0x34)
    draw_box(ass, card_x, card_y, card_x + card_width, card_y + card_height,
        round(14 * ui_scale), '342619', 0x10)
    add_text(ass, width / 2, card_y + round(34 * ui_scale), 24 * ui_scale,
        '哔哩哔哩扫码登录', 'FAF1E7', true)

    if state.qr_width > 0 and file_exists(qr_path) then
        local ok = pcall(mp.command_native, {
            'overlay-add', OVERLAY_ID, qr_x, qr_y, qr_path, 0, 'bgra',
            state.qr_width, state.qr_height, state.qr_width * 4,
            qr_display, qr_display,
        })
        state.overlay_present = ok
    end

    local seconds = math.max(0, math.ceil(state.expires_at - mp.get_time()))
    local status_y = qr_y + qr_display + round(30 * ui_scale)
    local status_text = state.message
    if state.status == 'waiting_scan' or state.status == 'waiting_confirm' then
        status_text = status_text .. string.format('  ·  %d 秒', seconds)
    end
    add_text(ass, width / 2, status_y, 19 * ui_scale, status_text, 'F6EADC', false)
    add_text(ass, width / 2, status_y + round(32 * ui_scale), 16 * ui_scale,
        state.status == 'expired'
            and '按 Enter 刷新二维码  ·  Esc / 右键关闭'
            or '请使用哔哩哔哩 App 扫码并在手机确认  ·  Esc / 右键关闭',
        'C3B19C', false)

    chrome.res_x = width
    chrome.res_y = height
    chrome.data = ass.text
    chrome:update()
end

local function abort_request()
    if state.request then
        pcall(mp.abort_async_command, state.request)
        state.request = nil
    end
end

local function stop_timers()
    if state.poll_timer then state.poll_timer:kill(); state.poll_timer = nil end
    if state.clock_timer then state.clock_timer:kill(); state.clock_timer = nil end
end

local function remove_bindings()
    mp.remove_key_binding('bilibili-account-escape')
    mp.remove_key_binding('bilibili-account-right-click')
    mp.remove_key_binding('bilibili-account-left-click')
    mp.remove_key_binding('bilibili-account-refresh')
end

local close_modal

local function install_bindings()
    mp.add_forced_key_binding('ESC', 'bilibili-account-escape', function() close_modal() end)
    mp.add_forced_key_binding('MBTN_RIGHT', 'bilibili-account-right-click', function() close_modal() end)
    mp.add_forced_key_binding('MBTN_LEFT', 'bilibili-account-left-click', function() end)
    mp.add_forced_key_binding('ENTER', 'bilibili-account-refresh', function()
        if state.status == 'expired' or state.status == 'error' then
            mp.commandv('script-message-to', mp.get_script_name(), 'qr-login')
        end
    end)
end

close_modal = function()
    state.ticket = state.ticket + 1
    state.visible = false
    abort_request()
    stop_timers()
    remove_bindings()
    remove_overlay()
    hide_player_chrome(false)
    state.qrcode_key = nil
    state.qr_width = 0
    state.qr_height = 0
    os.remove(qr_path)
end

local function run_helper(args, callback)
    if not file_exists(python_path) or not file_exists(helper_path) then
        callback(nil, '登录组件缺失，请重新安装完整播放器')
        return nil
    end
    local command = {
        name = 'subprocess', playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = args,
    }
    return mp.command_native_async(command, function(_success, result)
        local data = result and utils.parse_json(result.stdout or '') or nil
        if type(data) ~= 'table' then
            callback(nil, '登录组件没有返回有效结果')
            return
        end
        callback(data, nil)
    end)
end

local open_menu

local function refresh_account_status(callback)
    if state.status_request then
        pcall(mp.abort_async_command, state.status_request)
        state.status_request = nil
    end
    state.account_status = 'checking'
    publish_account()
    if not file_exists(cookie_path) then
        state.logged_in = false
        state.account_status = 'missing'
        publish_account()
        if callback then callback() end
        return
    end
    state.status_request = run_helper({
        python_path, helper_path, 'status', '--cookie-file', cookie_path,
    }, function(data)
        state.status_request = nil
        state.logged_in = data and data.ok == true and data.logged_in == true or false
        state.account_status = data and tostring(data.status or 'invalid') or 'unavailable'
        publish_account()
        if callback then callback() end
    end)
end

open_menu = function(skip_refresh)
    local status_hint = '正在检测本机 Cookie…'
    if state.account_status ~= 'checking' then
        status_hint = state.logged_in and '已登录 · 可使用账号允许的清晰度'
            or (file_exists(cookie_path) and 'Cookie 已失效，请重新扫码' or '未登录 · 公开画质仍可播放')
    end
    local items = {
        {
            title = '账号状态', hint = status_hint,
            selectable = false, interaction_role = 'status',
        },
        {
            title = state.logged_in and '重新扫码登录' or '扫码登录 B站',
            hint = '打开播放器内二维码，手机确认后自动保存',
            icon = 'qr_code',
            value = {'script-message-to', mp.get_script_name(), 'qr-login'},
        },
    }
    if file_exists(cookie_path) then
        items[#items + 1] = {
            title = '退出登录并清除本机 Cookie',
            hint = '不会退出浏览器或手机 App',
            icon = 'logout',
            value = {'script-message-to', mp.get_script_name(), 'logout'},
        }
    end
    items[#items + 1] = {
        title = '隐私说明',
        hint = 'Cookie 仅保存在本机便携目录，不上传第三方',
        selectable = false, muted = true, interaction_role = 'status',
    }
    local menu = {
        type = MENU_TYPE,
        title = 'B站账号与画质权限',
        min_width = 520,
        search_style = 'disabled',
        items = items,
    }
    local current_type = mp.get_property_native('user-data/uosc/menu/type')
    mp.commandv('script-message-to', 'uosc',
        current_type == MENU_TYPE and 'update-menu' or 'open-menu', utils.format_json(menu))
    if not skip_refresh then
        refresh_account_status(function() open_menu(true) end)
    end
end

local poll_once

local function schedule_poll(ticket, delay)
    if state.poll_timer then state.poll_timer:kill() end
    state.poll_timer = mp.add_timeout(delay or 1.6, function()
        state.poll_timer = nil
        if state.visible and state.ticket == ticket then poll_once(ticket) end
    end)
end

poll_once = function(ticket)
    if not state.visible or state.ticket ~= ticket or not state.qrcode_key then return end
    if mp.get_time() >= state.expires_at then
        state.status = 'expired'
        state.message = '二维码已过期'
        render()
        return
    end
    state.request = run_helper({
        python_path, helper_path, 'poll',
        '--qrcode-key', state.qrcode_key,
        '--cookie-file', cookie_path,
    }, function(data, error_message)
        state.request = nil
        if not state.visible or state.ticket ~= ticket then return end
        if not data or data.ok ~= true then
            state.status = 'error'
            state.message = error_message or (data and data.message) or '网络暂时不可用，正在重试'
            render()
            schedule_poll(ticket, 2.8)
            return
        end
        state.status = tostring(data.status or 'waiting_scan')
        state.message = tostring(data.message or '等待扫码')
        render()
        if state.status == 'success' then
            state.logged_in = true
            state.account_status = 'ready'
            publish_account()
            mp.osd_message('B站登录成功：下次解析将自动使用账号画质权限', 4)
            mp.add_timeout(0.8, function()
                if state.visible and state.ticket == ticket then close_modal() end
            end)
        elseif state.status ~= 'expired' and state.status ~= 'rejected' then
            schedule_poll(ticket, 1.6)
        end
    end)
end

local function start_qr_login()
    close_modal()
    mp.commandv('script-message-to', 'uosc', 'close-menu', MENU_TYPE)
    state.ticket = state.ticket + 1
    local ticket = state.ticket
    state.visible = true
    state.status = 'generating'
    state.message = '正在生成二维码…'
    hide_player_chrome(true)
    install_bindings()
    render()

    local dimensions = mp.get_property_native('osd-dimensions')
    local width = dimensions and tonumber(dimensions.w) or 1280
    local height = dimensions and tonumber(dimensions.h) or 720
    local requested_size = clamp(round(math.min(width, height) * 0.40), 260, 420)
    state.request = run_helper({
        python_path, helper_path, 'generate',
        '--qr-output', qr_path, '--size', tostring(requested_size),
    }, function(data, error_message)
        state.request = nil
        if not state.visible or state.ticket ~= ticket then return end
        if not data or data.ok ~= true then
            state.status = 'error'
            state.message = error_message or (data and data.message) or '二维码生成失败，请重试'
            render()
            return
        end
        state.qrcode_key = tostring(data.qrcode_key or '')
        state.qr_width = tonumber(data.width) or 0
        state.qr_height = tonumber(data.height) or state.qr_width
        state.expires_at = mp.get_time() + (tonumber(data.expires_in) or 180)
        state.status = 'waiting_scan'
        state.message = '等待扫码'
        render()
        state.clock_timer = mp.add_periodic_timer(1, render)
        schedule_poll(ticket, 0.4)
    end)
end

local function logout()
    close_modal()
    local existed = file_exists(cookie_path)
    local removed = not existed or os.remove(cookie_path)
    state.logged_in = false
    state.account_status = removed and 'missing' or 'invalid'
    publish_account()
    if removed then
        mp.osd_message('已清除播放器本机的 B站 Cookie', 3)
    else
        msg.error('Unable to remove Bilibili cookie file')
        mp.osd_message('Cookie 文件正在被占用，暂时无法清除', 4)
    end
    open_menu(true)
end

mp.register_script_message('open', function() open_menu(false) end)
mp.register_script_message('qr-login', start_qr_login)
mp.register_script_message('logout', logout)
mp.observe_property('osd-dimensions', 'native', render)
mp.register_event('shutdown', function()
    close_modal()
    if state.status_request then
        pcall(mp.abort_async_command, state.status_request)
        state.status_request = nil
    end
end)

refresh_account_status()
