local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
-- auto_iso_loader.lua
-- 统一 ISO 自动播放入口

local mp = require 'mp'
local msg = require 'mp.msg'
local assdraw = require 'mp.assdraw'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    auto_local_menu = true,
}
options.read_options(o, 'auto_iso_loader')

local config_path = mp.command_native({
    'expand-path', '~~/script-opts/auto_iso_loader.conf',
})

local iso_path = nil       -- 当前播放的 ISO 原始路径
local iso_title = nil      -- ISO 文件名
local temporary_disc_menu = false
local previous_disc_menu = nil
local local_menu_autostart = false
local local_menu_autostart_timer = nil
local local_menu_autostart_attempt = 0
local local_menu_start_edition = nil
local local_menu_dvd_root_attempted = false
local local_menu_navigation_hint_shown = false
-- True only after a requested discnav jump has actually started.  This lets
-- the loading overlay cover Blu-ray First Play / BD-J initialization without
-- hiding the real menu once navigation has entered its transition.
local local_menu_navigation_started = false
local local_menu_initial_action = "menu"
local forced_local_menu_once = false
local forced_local_menu_action = nil
local current_local_menu_session = false
local disc_generation = 0
local remote_loading_overlay = nil
local remote_loading_timer = nil
local remote_loading_started = nil
local remote_loading_phase = "idle"
local remote_loading_elapsed_second = -1
local remote_loading_segment_progress = 0
local remote_loading_segment_direction = 1
local remote_loading_animation_last_frame = nil
local remote_loading_endpoint_hold_until = nil
local local_loading_overlay = nil
local local_loading_timer = nil
local local_loading_started = nil
local local_loading_phase = "idle"
local local_loading_elapsed_second = -1
local local_loading_expects_menu = true
local saved_stream_buffer_size = nil
local stream_buffer_changed = false

-- 远程原盘扫描会在 UDF 与 MPLS 元数据区之间频繁随机读取。mpv 默认
-- 128 KiB 流缓冲会把这些读取放大为大量 HTTP Range 往返；32 MiB 只对
-- 本次远程 ISO 新建的底层流生效，普通视频和全局配置会在起播后恢复。
local REMOTE_ISO_STREAM_BUFFER = 32 * 1024 * 1024
-- The overlay is small, so 60fps keeps the 590px traversal visually continuous
-- without touching the remote stream. Frame deltas are capped so a delayed Lua
-- callback resumes smoothly instead of jumping across the track.
local REMOTE_LOADING_RENDER_FPS = 60
local REMOTE_LOADING_RENDER_INTERVAL = 1 / REMOTE_LOADING_RENDER_FPS
local REMOTE_LOADING_LEG_DURATION = 2.0
local REMOTE_LOADING_ENDPOINT_HOLD = 0.12
local REMOTE_LOADING_MAX_FRAME_STEP = 1 / 30
-- Local libbluray startup can block Lua until the UDF/index scan has returned.
-- Chain the attempts instead of scheduling them all at once: an overdue timer
-- then produces one command, never a burst of several menu calls.
-- Some authored discs mask the Top Menu command during a studio-logo/First
-- Play segment. Keep retrying at a low rate long enough to cross that segment;
-- this does not add reads or delay the disc open itself.
local LOCAL_MENU_AUTOSTART_DELAYS = {0.35, 1.8, 3.5, 7, 12, 12}
local local_menu_preserve_intro = false
local local_menu_intro_started = 0
-- 本地 ISO 不需要额外扫描来估算进度。只按真实经过时间刷新说明文字，
-- 不读取镜像、不伪造百分比，也不参与 libbluray 的打开流程。
local LOCAL_LOADING_RENDER_INTERVAL = 0.5

local function publish_auto_menu_state()
    mp.set_property_bool(
        "user-data/auto-iso-loader/auto-local-menu", o.auto_local_menu == true)
    mp.set_property_bool(
        "user-data/auto-iso-loader/menu-session", current_local_menu_session)
end

local function persist_auto_menu_state()
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('[ISO] 无法保存原盘菜单启动设置：' .. tostring(config_path))
        return false
    end
    file:write(
        '# 本地蓝光 / DVD / ISO 是否在打开时自动进入原盘自带菜单。\n'
            .. '# yes：保持完整原盘导航；no：直接播放正片，仍可从“蓝光原盘菜单”手动载入菜单。\n'
            .. string.format('auto_local_menu=%s\n',
                o.auto_local_menu and 'yes' or 'no')
    )
    file:close()
    return true
end

local function parse_boolean(value)
    value = tostring(value or ''):lower()
    if value == 'yes' or value == 'true' or value == 'on' or value == '1' then
        return true
    end
    if value == 'no' or value == 'false' or value == 'off' or value == '0' then
        return false
    end
    return nil
end

if type(o.auto_local_menu) ~= 'boolean' then
    o.auto_local_menu = parse_boolean(o.auto_local_menu) ~= false
end

local function stop_local_menu_autostart()
    if local_menu_autostart_timer then
        local_menu_autostart_timer:kill()
        local_menu_autostart_timer = nil
    end
    local_menu_autostart = false
    local_menu_autostart_attempt = 0
    local_menu_start_edition = nil
    local_menu_dvd_root_attempted = false
end

local function publish_loading(value)
    mp.set_property_bool("user-data/auto-iso-loader/loading", value)
end

local function stop_remote_loading_timer()
    if remote_loading_timer then
        remote_loading_timer:kill()
        remote_loading_timer = nil
    end
end

local function restore_stream_buffer()
    if stream_buffer_changed and saved_stream_buffer_size
        and mp.get_property_native('stream-buffer-size') == REMOTE_ISO_STREAM_BUFFER then
        mp.set_property_native("stream-buffer-size", saved_stream_buffer_size)
    end
    saved_stream_buffer_size = nil
    stream_buffer_changed = false
end

local function prepare_remote_stream_buffer()
    restore_stream_buffer()

    local current = mp.get_property_native("stream-buffer-size")
    if type(current) ~= "number" then return end

    saved_stream_buffer_size = current
    if current < REMOTE_ISO_STREAM_BUFFER then
        mp.set_property_native("stream-buffer-size", REMOTE_ISO_STREAM_BUFFER)
        stream_buffer_changed = true
        msg.info(string.format(
            "[ISO] 远程原盘流缓冲临时提升: %d -> %d bytes",
            current, REMOTE_ISO_STREAM_BUFFER))
    end
end

local function hide_remote_loading(reason)
    stop_remote_loading_timer()

    if remote_loading_overlay then
        remote_loading_overlay:remove()
        remote_loading_overlay = nil
    end

    if remote_loading_started then
        msg.info(string.format("[ISO] 远程原盘扫描结束: %.1fs (%s)",
            mp.get_time() - remote_loading_started, reason or "unknown"))
        remote_loading_started = nil
    end

    remote_loading_phase = "idle"
    remote_loading_elapsed_second = -1
    remote_loading_segment_progress = 0
    remote_loading_segment_direction = 1
    remote_loading_animation_last_frame = nil
    remote_loading_endpoint_hold_until = nil
    publish_loading(false)
    mp.set_property("user-data/auto-iso-loader/loading-phase", "idle")
    mp.set_property_number("user-data/auto-iso-loader/loading-elapsed", 0)
    restore_stream_buffer()
end

local function render_remote_loading()
    if not remote_loading_overlay or not remote_loading_started then return end

    local now = mp.get_time()
    local elapsed = math.max(0, now - remote_loading_started)
    local elapsed_second = math.floor(elapsed)
    if elapsed_second ~= remote_loading_elapsed_second then
        remote_loading_elapsed_second = elapsed_second
        mp.set_property_number(
            "user-data/auto-iso-loader/loading-elapsed", elapsed_second)
    end

    local phase_text = remote_loading_phase == "first-frame"
        and "原盘结构已识别，正在准备首帧"
        or "正在读取原盘目录并定位正片"
    local estimate_text
    if elapsed_second < 30 then
        estimate_text = string.format(
            "已等待 %d 秒 · 通常约 15–30 秒", elapsed_second)
    else
        estimate_text = string.format(
            "已等待 %d 秒 · 当前线路较慢，仍在继续读取", elapsed_second)
    end

    -- The moving segment is deliberately indeterminate: libbluray performs
    -- remote random reads and exposes no trustworthy total, so a numeric rate or
    -- countdown would promise precision that the player does not have.
    local track_left, track_right = 570, 1350
    local segment_width = 190
    local travel = track_right - track_left - segment_width
    -- Advance from rendered frames rather than sampling a time formula. Whenever
    -- a leg crosses an endpoint, clamp it exactly and hold it long enough to be
    -- visibly rendered. This guarantees every pass touches both ends even when
    -- timer callbacks arrive with a different phase or are briefly delayed.
    local frame_step = 0
    if remote_loading_animation_last_frame then
        frame_step = math.min(REMOTE_LOADING_MAX_FRAME_STEP,
            math.max(0, now - remote_loading_animation_last_frame))
    end
    remote_loading_animation_last_frame = now

    if remote_loading_endpoint_hold_until and
            now >= remote_loading_endpoint_hold_until then
        remote_loading_endpoint_hold_until = nil
    end
    if not remote_loading_endpoint_hold_until and frame_step > 0 then
        local next_progress = remote_loading_segment_progress +
            remote_loading_segment_direction *
            (frame_step / REMOTE_LOADING_LEG_DURATION)
        if next_progress >= 1 then
            remote_loading_segment_progress = 1
            remote_loading_segment_direction = -1
            remote_loading_endpoint_hold_until = now +
                REMOTE_LOADING_ENDPOINT_HOLD
        elseif next_progress <= 0 then
            remote_loading_segment_progress = 0
            remote_loading_segment_direction = 1
            remote_loading_endpoint_hold_until = now +
                REMOTE_LOADING_ENDPOINT_HOLD
        else
            remote_loading_segment_progress = next_progress
        end
    end
    local segment_left = track_left + travel *
        remote_loading_segment_progress

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H17130F&\\1a&H18&\\p1}")
    ass:draw_start()
    ass:round_rect_cw(480, 365, 1440, 735, 26)
    ass:draw_stop()

    ass:new_event()
    ass:append("{\\an5\\pos(960,460)\\fnMFGA YouHei\\fs48\\b1" ..
        "\\bord0\\shad0\\1c&HFFFFFF&}正在打开网盘蓝光原盘")
    ass:new_event()
    ass:append("{\\an5\\pos(960,535)\\fnMFGA YouHei\\fs31" ..
        "\\bord0\\shad0\\1c&HD9D9D9&}" .. phase_text)

    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H4B4540&\\1a&H20&\\p1}")
    ass:draw_start()
    ass:round_rect_cw(track_left, 590, track_right, 608, 9)
    ass:draw_stop()
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&HE8B969&\\p1}")
    ass:draw_start()
    ass:round_rect_cw(segment_left, 590, segment_left + segment_width, 608, 9)
    ass:draw_stop()

    ass:new_event()
    ass:append("{\\an5\\pos(960,655)\\fnMFGA YouHei\\fs27" ..
        "\\bord0\\shad0\\1c&HCAC7C4&}" .. estimate_text)
    ass:new_event()
    ass:append("{\\an5\\pos(960,700)\\fnMFGA YouHei\\fs23" ..
        "\\bord0\\shad0\\1c&H918E8B&}无需操作 · 完成后会自动开始播放")

    remote_loading_overlay.data = ass.text
    remote_loading_overlay:update()
end

local function set_remote_loading_phase(phase)
    if not remote_loading_started then return end
    remote_loading_phase = phase
    mp.set_property("user-data/auto-iso-loader/loading-phase", phase)
    render_remote_loading()
end

local function show_remote_loading()
    hide_remote_loading("restart")

    -- A previously opened console hides normal playback OSD and looks like a
    -- stalled terminal. Remote ISO loading should always return to playback UI.
    mp.commandv("script-message-to", "console", "disable")

    remote_loading_overlay = mp.create_osd_overlay("ass-events")
    remote_loading_overlay.res_x = 1920
    remote_loading_overlay.res_y = 1080
    remote_loading_overlay.z = 2000
    remote_loading_started = mp.get_time()
    remote_loading_phase = "scanning"
    remote_loading_elapsed_second = -1
    remote_loading_segment_progress = 0
    remote_loading_segment_direction = 1
    remote_loading_animation_last_frame = remote_loading_started
    remote_loading_endpoint_hold_until = remote_loading_started +
        REMOTE_LOADING_ENDPOINT_HOLD
    publish_loading(true)
    mp.set_property("user-data/auto-iso-loader/loading-phase", "scanning")
    render_remote_loading()
    remote_loading_timer = mp.add_periodic_timer(
        REMOTE_LOADING_RENDER_INTERVAL, render_remote_loading)
end

local function stop_local_loading_timer()
    if local_loading_timer then
        local_loading_timer:kill()
        local_loading_timer = nil
    end
end

local function hide_local_loading(reason)
    stop_local_loading_timer()

    if local_loading_overlay then
        local_loading_overlay:remove()
        local_loading_overlay = nil
    end

    if local_loading_started then
        msg.info(string.format("[ISO] 本地原盘等待结束: %.1fs (%s)",
            mp.get_time() - local_loading_started, reason or "unknown"))
        local_loading_started = nil
    end

    local_loading_phase = "idle"
    local_loading_elapsed_second = -1
    publish_loading(false)
    mp.set_property("user-data/auto-iso-loader/loading-phase", "idle")
    mp.set_property_number("user-data/auto-iso-loader/loading-elapsed", 0)
end

local function render_local_loading()
    if not local_loading_overlay or not local_loading_started then return end

    local now = mp.get_time()
    local elapsed_second = math.floor(math.max(
        0, now - local_loading_started))

    if elapsed_second ~= local_loading_elapsed_second then
        local_loading_elapsed_second = elapsed_second
        mp.set_property_number(
            "user-data/auto-iso-loader/loading-elapsed", elapsed_second)
    end

    local title = "正在打开蓝光原盘"
    local phase_text = local_loading_expects_menu
        and "正在读取光盘目录与菜单"
        or "正在读取光盘目录并定位正片"
    local elapsed_text = string.format(
        "已等待 %d 秒 · 大型原盘首次打开可能需要几十秒", elapsed_second)
    local footer_text = local_loading_expects_menu
        and "无需操作 · 完成后会自动进入蓝光主菜单"
        or "无需操作 · 完成后会直接播放主标题"

    if local_loading_expects_menu and local_loading_phase == "menu-wait" then
        phase_text = "原盘已识别，正在等待自带菜单显示"
        footer_text = "部分原盘会先执行自带片头或菜单初始化"
    elseif local_loading_expects_menu and
            local_loading_phase == "menu-transition" then
        phase_text = "原盘菜单正在切换，等待导航完成"
        footer_text = "无需操作 · 菜单显示后会自动关闭等待界面"
    elseif local_loading_phase == "dvd-fallback" then
        phase_text = "未识别为蓝光原盘，正在尝试 DVD 影碟模式"
        footer_text = "无需操作 · 播放器会自动选择可用方式"
    elseif local_loading_expects_menu and
            local_loading_phase == "menu-unresponsive" then
        title = "蓝光菜单暂未响应"
        phase_text = "原盘仍在读取，或自带菜单没有正常显示"
        elapsed_text = string.format(
            "已等待 %d 秒 · 可以继续等待或手动重试", elapsed_second)
        footer_text = "右键 → Emo → 蓝光原盘菜单，可重新进入"
    elseif elapsed_second >= 30 then
        phase_text = local_loading_expects_menu
            and "正在继续读取，并等待原盘自带菜单响应"
            or "正在继续读取，并定位原盘主标题"
        elapsed_text = string.format(
            "已等待 %d 秒 · 这张原盘的内容或菜单较复杂", elapsed_second)
        footer_text = local_loading_expects_menu
            and "可继续等待 · 也可右键打开“蓝光原盘菜单”"
            or "当前为正片直达模式 · 菜单可稍后手动载入"
    end

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H17130F&\\1a&H18&\\p1}")
    ass:draw_start()
    ass:round_rect_cw(480, 365, 1440, 735, 26)
    ass:draw_stop()

    ass:new_event()
    ass:append("{\\an5\\pos(960,460)\\fnMFGA YouHei\\fs48\\b1" ..
        "\\bord0\\shad0\\1c&HFFFFFF&}" .. title)
    ass:new_event()
    ass:append("{\\an5\\pos(960,535)\\fnMFGA YouHei\\fs31" ..
        "\\bord0\\shad0\\1c&HD9D9D9&}" .. phase_text)
    ass:new_event()
    ass:append("{\\an5\\pos(960,620)\\fnMFGA YouHei\\fs27" ..
        "\\bord0\\shad0\\1c&HCAC7C4&}" .. elapsed_text)
    ass:new_event()
    ass:append("{\\an5\\pos(960,685)\\fnMFGA YouHei\\fs23" ..
        "\\bord0\\shad0\\1c&H918E8B&}" .. footer_text)

    local_loading_overlay.data = ass.text
    local_loading_overlay:update()
end

local function set_local_loading_phase(phase)
    if not local_loading_started then return end
    local_loading_phase = phase
    mp.set_property("user-data/auto-iso-loader/loading-phase", phase)
    render_local_loading()
end

local function show_local_loading(expects_menu)
    hide_local_loading("restart")
    local_loading_expects_menu = expects_menu == true

    -- 控制台会遮住正常 OSD；打开本地原盘时始终回到播放界面显示状态。
    mp.commandv("script-message-to", "console", "disable")

    local_loading_overlay = mp.create_osd_overlay("ass-events")
    local_loading_overlay.res_x = 1920
    local_loading_overlay.res_y = 1080
    -- uosc 菜单使用 2000；加载状态放在其下方，保证黑屏时仍可右键操作。
    local_loading_overlay.z = 1900
    local_loading_started = mp.get_time()
    local_loading_phase = "scanning"
    local_loading_elapsed_second = -1
    publish_loading(true)
    mp.set_property("user-data/auto-iso-loader/loading-phase", "scanning")
    render_local_loading()
    local_loading_timer = mp.add_periodic_timer(
        LOCAL_LOADING_RENDER_INTERVAL, render_local_loading)
end

local function iso_url_path(path)
    if not path or path == "" then return "" end
    -- OpenList /d links append a sign query.  Match the URL path instead of
    -- requiring the whole string to end in .iso.
    if path:match('^%a[%w+.-]*://') then
        return path:gsub("[?#].*$", ""):gsub("%%2[eE]", ".")
    end
    return path
end

local function is_iso_file(path)
    return iso_url_path(path):lower():match("%.iso$") ~= nil
end

local function is_remote_iso(path)
    return is_iso_file(path) and path:lower():match("^https?://") ~= nil
end

local function is_disc_protocol(target)
    if not target or target == "" then return false end
    local protocol = target:match('^(%a+)://')
    return protocol == 'bd' or protocol == 'br' or protocol == 'bluray' or protocol == 'dvd'
end

local function local_disc_directory(path)
    if path:match('^%a[%w+.-]*://') then return nil end
    local info = utils.file_info(path)
    if not info then return nil end
    local normalized = path:gsub('\\', '/'):gsub('/+$', '')
    local root = normalized
    if not info.is_dir then
        local name = normalized:match('([^/]+)$'):lower()
        if name ~= 'index.bdmv' and name ~= 'movieobject.bdmv' and name ~= 'video_ts.ifo' then return nil end
        root = normalized:match('^(.*)/[^/]+$') or ''
    end
    local leaf = (root:match('([^/]+)$') or ''):upper()
    if leaf == 'BDMV' or leaf == 'VIDEO_TS' then root = root:match('^(.*)/[^/]+$') or '' end
    local function header(relative, expected)
        local file = io.open(root .. '/' .. relative, 'rb')
        if not file then return false end
        local prefix = file:read(#expected)
        file:close()
        return prefix == expected
    end
    if header('BDMV/MovieObject.bdmv', 'MOBJ') then return root, 'bd://' end
    if header('VIDEO_TS/VIDEO_TS.IFO', 'DVDVIDEO-VMG') then return root, 'dvd://' end
end

local function is_current_local_disc()
    if is_remote_iso(iso_path) then return false end
    local stream_fn = mp.get_property("stream-open-filename") or ""
    local demuxer = mp.get_property("demuxer") or ""
    return is_disc_protocol(stream_fn) or demuxer == "disc"
end

local function local_root_navigation_started(navigation_seek)
    local target = mp.get_property("stream-open-filename") or ""
    if target:match("^dvd://") or local_menu_initial_action == "popup" then
        return false
    end
    if local_menu_autostart_attempt == 0 then return false end
    -- A same-title menu jump also goes through mpv's seek/resync path.
    -- Explicit user seeks should likewise take control from autostart.
    if navigation_seek == true then return true end
    local edition = mp.get_property_native("current-edition")
    return type(local_menu_start_edition) == "number"
        and local_menu_start_edition >= 0
        and type(edition) == "number"
        and edition >= 0 and edition ~= local_menu_start_edition
end

local function stop_started_root_navigation(navigation_seek)
    if not local_menu_autostart or not is_current_local_disc()
        or not local_root_navigation_started(navigation_seek) then return false end
    -- A Blu-ray menu can have a non-interactive intro. Its title changes
    -- before disc-menu-active becomes true; another Top Menu call restarts
    -- that intro. Once navigation has moved on, let the disc finish it.
    local_menu_navigation_started = true
    msg.info("[ISO] 原盘已开始切换，停止自动菜单重试，释放等待层给原盘菜单渲染")
    stop_local_menu_autostart()
    -- V18 kept the ASS loading overlay until the post-jump playback-restart.
    -- On BD-J/HDMV discs this can cover the window while libbluray is creating
    -- the real menu graphics plane, leaving the user looking at the menu
    -- background/title after the overlay disappears.  The navigation jump is
    -- already confirmed here, so release only our loading overlay now and let
    -- libbluray finish the menu transition without another artificial delay.
    hide_local_loading("menu-navigation-started")
    return true
end

local function schedule_local_menu_autostart()
    if not local_menu_autostart then return end
    if local_menu_autostart_timer then local_menu_autostart_timer:kill() end

    local delay = LOCAL_MENU_AUTOSTART_DELAYS[
        math.min(local_menu_autostart_attempt + 1,
            #LOCAL_MENU_AUTOSTART_DELAYS)]
    local generation = disc_generation
    local_menu_autostart_timer = mp.add_timeout(delay, function()
        if generation ~= disc_generation then return end
        local_menu_autostart_timer = nil
        if not local_menu_autostart or not is_current_local_disc() then
            stop_local_menu_autostart()
            return
        end
        if mp.get_property_native("disc-menu-active") == true then
            hide_local_loading("disc-menu-active")
            stop_local_menu_autostart()
            return
        end
        if stop_started_root_navigation() then return end

        local_menu_autostart_attempt = local_menu_autostart_attempt + 1
        local stream_fn = mp.get_property("stream-open-filename") or ""
        local is_dvd = stream_fn:match("^dvd://") ~= nil
        -- Automatic entry should let an authored short First Play finish.
        -- An explicit Home/menu request still takes effect immediately.
        -- Do not confuse a paused intro with a failed navigator.
        local duration = mp.get_property_number('duration', 0) or 0
        if not is_dvd and local_menu_preserve_intro
            and (mp.get_property_bool('pause', false)
                or (duration > 0 and duration <= 180
                    and not mp.get_property_bool('eof-reached', false)
                    and mp.get_time() - local_menu_intro_started < 180)) then
            local_menu_autostart_attempt = local_menu_autostart_attempt - 1
            schedule_local_menu_autostart()
            return
        end
        local action = local_menu_initial_action or "menu"
        if is_dvd and action == "menu" then
            -- Some authored DVDs expose no Root menu even though their Title
            -- menu is valid. libdvdnav then remains in a normal VTS title: the
            -- frame looks like a menu, but disc-menu-active stays false and
            -- navigation keys cannot work. Try Root once, then fall back to
            -- the DVD Title menu while retaining the bounded retry chain.
            if local_menu_dvd_root_attempted then
                action = "title-menu"
            else
                local_menu_dvd_root_attempted = true
            end
        end
        local action_label = action == "title-menu" and "标题菜单"
            or (action == "popup" and "播放快捷菜单" or "根菜单")
        msg.info(string.format(
            "[ISO] 自动进入%s（%s，第 %d/%d 次）",
            is_dvd and "DVD 菜单" or "蓝光主菜单",
            action_label,
            local_menu_autostart_attempt, #LOCAL_MENU_AUTOSTART_DELAYS))
        mp.commandv("discnav", action)

        if local_menu_autostart_attempt < #LOCAL_MENU_AUTOSTART_DELAYS then
            schedule_local_menu_autostart()
        else
            -- By this point any real video frame has already dismissed the
            -- loading card from the playback-restart handler.  Keep the
            -- diagnostic state only when no playable frame ever appeared.
            if local_loading_overlay then
                set_local_loading_phase("menu-unresponsive")
            end
            stop_local_menu_autostart()
        end
    end)
end

local function get_disc_iso_path()
    local bd_dev = mp.get_property("bluray-device") or ""
    local dvd_dev = mp.get_property("dvd-device") or ""

    local target = mp.get_property('stream-open-filename') or ''
    if target == '' then target = mp.get_property('path') or '' end
    local title, device = target:match('^%a+://([^/]*)(.*)$')
    if title == 'mpls' then device = device:match('^/[^/]+(.*)$') end
    if device and device:sub(1, 1) == '/' and #device > 1 then return device:sub(2) end
    if target:match('^dvd://') then return dvd_dev ~= '' and dvd_dev or nil end
    if bd_dev ~= '' then return bd_dev end
    if dvd_dev ~= '' then return dvd_dev end
    return nil
end

local function utf8_char_starts(value)
    local starts = {}
    local index = 1
    while index <= #value do
        starts[#starts + 1] = index
        local lead = value:byte(index)
        local width = 1
        if lead and lead >= 0xC2 and lead <= 0xDF then width = 2
        elseif lead and lead >= 0xE0 and lead <= 0xEF then width = 3
        elseif lead and lead >= 0xF0 and lead <= 0xF4 then width = 4 end
        if width > 1 then
            for offset = 1, width - 1 do
                local continuation = value:byte(index + offset)
                if not continuation or continuation < 0x80 or
                        continuation > 0xBF then
                    width = 1
                    break
                end
            end
        end
        index = index + width
    end
    return starts
end

-- 按 Unicode 字符而非 UTF-8 字节保留路径尾部，避免长中文文件名恰好
-- 截在多字节字符中间，短暂显示替换方框。扩展名与末尾发布信息仍保留。
local function short_path(p, n)
    p = tostring(p or '')
    n = n or 40
    local starts = utf8_char_starts(p)
    if #starts > n then
        local keep = math.max(0, n - 3)
        if keep == 0 then return '...' end
        local first = starts[#starts - keep + 1]
        return '...' .. p:sub(first)
    end
    return p
end

local function set_iso_state(path)
    iso_path = path
    iso_title = (mp.get_property("filename") or path)
    mp.set_property("user-data/auto-iso-loader/original-path", path)
    mp.set_property_bool("user-data/auto-iso-loader/remote", is_remote_iso(path))
end

-- Local discs must enter the native menu while the stream is being opened.
-- Changing disc-menu after file-loaded is too late for libbluray/libdvdnav;
-- discnav cannot safely convert an already title-mode stream. Preserve the
-- user's global option and restore it after this stream is initialized.
local function configure_temporary_local_menu(menu_enabled, initial_action)
    if temporary_disc_menu then return end
    local current = mp.get_property_native("disc-menu")
    if type(current) ~= "boolean" then
        current = mp.get_property("disc-menu") == "yes"
    end
    previous_disc_menu = current
    temporary_disc_menu = true
    current_local_menu_session = menu_enabled == true
    local_menu_autostart = current_local_menu_session
    local_menu_autostart_attempt = 0
    local_menu_dvd_root_attempted = false
    local_menu_initial_action = initial_action or "menu"
    local_menu_preserve_intro = initial_action == nil
    local_menu_intro_started = mp.get_time()
    local_menu_navigation_hint_shown = false
    local_menu_navigation_started = false
    -- Blu-ray's menu auxiliary PIDs can be misidentified as MP3 when lavf
    -- deeply probes streams after a PlayItem jump. Keep the local disc's
    -- stream list supplied by the navigator; do not affect ordinary media.
    mp.set_property('file-local-options/demuxer-lavf-probe-info', 'nostreams')
    mp.set_property_bool("disc-menu", current_local_menu_session)
    publish_auto_menu_state()
    if current_local_menu_session then
        msg.info("[ISO] 本地光盘将在打开阶段进入原盘菜单")
    else
        msg.info("[ISO] 已关闭自动原盘菜单，本次直接定位主标题")
    end
    -- Do not send discnav while the ISO is still being opened.  In particular,
    -- Warner BD-J First Play may be switching playlists asynchronously; a
    -- pre-file-loaded menu command can stop that Java session and make mpv
    -- return to the startup page.  The file-loaded handler below restarts the
    -- bounded chain once the native navigator is live.
end

local function restore_disc_menu_option()
    if not temporary_disc_menu then return end
    if mp.get_property_native('disc-menu') == current_local_menu_session then
        mp.set_property_bool("disc-menu", previous_disc_menu == true)
    end
    temporary_disc_menu = false
    previous_disc_menu = nil
end

local function clear_iso_state()
    disc_generation = disc_generation + 1
    hide_remote_loading("end-file")
    hide_local_loading("end-file")
    restore_disc_menu_option()
    stop_local_menu_autostart()
    local_menu_navigation_hint_shown = false
    local_menu_navigation_started = false
    local_menu_initial_action = "menu"
    current_local_menu_session = false
    iso_path = nil
    iso_title = nil
    mp.set_property("user-data/auto-iso-loader/original-path", "")
    mp.set_property_bool("user-data/auto-iso-loader/remote", false)
    publish_auto_menu_state()
end

local function consume_local_menu_request(target)
    local menu_enabled = o.auto_local_menu or forced_local_menu_once
    local action = forced_local_menu_action
    local title = tostring(target or ''):match('^%a+://([^/]*)')
    local edition = mp.get_property_native('edition')
    if forced_local_menu_once then
        mp.set_property('file-local-options/edition', 'auto')
    elseif type(edition) == 'number' and edition >= 0 then
        menu_enabled = false
    elseif title and title ~= '' then
        -- Explicit title/playlist/longest requests take precedence over the
        -- automatic preference; an explicit menu URI keeps its own intent.
        menu_enabled = title == 'menu'
    end
    forced_local_menu_once = false
    forced_local_menu_action = nil
    return menu_enabled, action
end

local function allow_local_strm_disc(path)
    -- Native local playlists restrict device protocols, including our bd://
    -- adapter. Permit that adapter only for an existing local disc referenced
    -- by an existing local STRM. Keep network playlist restrictions intact and
    -- let mpv restore this option at the end of this one entry.
    local parent = mp.get_property('playlist-path', '') or ''
    if not parent:lower():match('%.strm$') or parent:match('^%a[%w+.-]*://')
        or path:match('^%a[%w+.-]*://') then return end
    local parent_info, source_info = utils.file_info(parent), utils.file_info(path)
    if parent_info and parent_info.is_file and source_info
        and (source_info.is_file or source_info.is_dir) then
        mp.set_property('file-local-options/load-unsafe-playlists', 'yes')
    end
end

----------------------------------------------------------------------
-- on_load 钩子
----------------------------------------------------------------------
mp.add_hook("on_load", 30, function()
    local path = mp.get_property("path") or ""
    local stream_fn = mp.get_property("stream-open-filename") or ""
    disc_generation = disc_generation + 1
    if stream_fn ~= '' and stream_fn ~= path then path = stream_fn end

    if is_iso_file(path) then
        local display_path = iso_url_path(path)
        msg.info("[ISO] 拦截: " .. short_path(display_path, 50))

        set_iso_state(path)

        if is_remote_iso(path) then
            show_remote_loading()
            prepare_remote_stream_buffer()
        else
            allow_local_strm_disc(path)
            local menu_enabled, action = consume_local_menu_request(path)
            mp.osd_message("ISO: " .. short_path(display_path, 50), 2)
            show_local_loading(menu_enabled)
            configure_temporary_local_menu(menu_enabled, action)
        end

        mp.set_property("bluray-device", path)
        mp.set_property("dvd-device", path)
        mp.set_property("stream-open-filename", "bd://")
        return
    end

    if is_disc_protocol(path) or is_disc_protocol(stream_fn) then
        local disc_iso_path = get_disc_iso_path()
        if disc_iso_path then set_iso_state(disc_iso_path) end
        if not is_remote_iso(iso_path) then
            local menu_enabled, action = consume_local_menu_request(path)
            configure_temporary_local_menu(menu_enabled, action)
        end
        return
    end

    -- Native BDMV probing happens after on_load. Apply the same local menu
    -- policy before opening a directory/index, preserving the original entry.
    local directory, protocol = local_disc_directory(path)
    if directory then
        allow_local_strm_disc(directory)
        set_iso_state(directory)
        local menu_enabled, action = consume_local_menu_request(path)
        configure_temporary_local_menu(menu_enabled, action)
        show_local_loading(menu_enabled)
        mp.set_property(protocol == 'bd://' and 'bluray-device' or 'dvd-device', directory)
        mp.set_property('stream-open-filename', protocol)
        msg.info('[DISC] 已识别原盘目录；' .. (menu_enabled and '载入原盘菜单' or '播放主标题'))
        return
    end

    -- 普通文件：清状态
    forced_local_menu_once = false
    forced_local_menu_action = nil
    clear_iso_state()
end)

----------------------------------------------------------------------
-- on_load_fail
----------------------------------------------------------------------
mp.add_hook("on_load_fail", 45, function()
    local stream_fn = mp.get_property("stream-open-filename") or ""

    if stream_fn == "bd://" then
        if is_remote_iso(iso_path) then
            msg.error("[ISO] 远程蓝光打开失败；服务器必须支持稳定 HTTP Range")
            hide_remote_loading("open-failed")
            mp.osd_message(i18n.t("远程蓝光 ISO 打开失败：请检查服务器 Range 支持"), 6)
            -- Keep the remote marker until end-file. on_load_fail performs one
            -- retry after hooks return; clearing here could let a later failure
            -- fall through to the local-only DVD probe.
            return
        end
        msg.warn("[ISO] BD 失败，静默尝试 DVD")
        set_local_loading_phase("dvd-fallback")
        mp.set_property("stream-open-filename", "dvd://")
        return
    end

    if stream_fn == "dvd://" then
        msg.error("[ISO] BD/DVD 均失败")
        hide_local_loading("open-failed")
        mp.osd_message(i18n.t("ISO 播放失败，请检查镜像类型"), 5)
        clear_iso_state()
        return
    end
end)

mp.register_event("file-loaded", function()
    if iso_path and not is_remote_iso(iso_path) and is_current_local_disc()
            and current_local_menu_session then
        -- Opening a large image can take longer than every on-load fallback
        -- attempt. Restart the bounded chain only after libbluray has emitted
        -- file-loaded, when discnav is guaranteed to reach the live navigator.
        stop_local_menu_autostart()
        local_menu_autostart = true
        local_menu_autostart_attempt = 0
        local_menu_start_edition = mp.get_property_native("current-edition")
        set_local_loading_phase("menu-wait")
        schedule_local_menu_autostart()
    end
    restore_disc_menu_option()
    if is_remote_iso(iso_path) then
        set_remote_loading_phase("first-frame")
        -- The remote stream has already copied this setting. Restore the
        -- global option now, but keep the overlay until the first playback
        -- restart so the short decoder/renderer setup gap does not go black.
        restore_stream_buffer()
    end
end)

mp.register_script_message("set-auto-menu", function(value)
    local requested
    if tostring(value or ''):lower() == 'toggle' then
        requested = not o.auto_local_menu
    else
        requested = parse_boolean(value)
    end
    if requested == nil then
        mp.osd_message(i18n.t("原盘菜单启动设置无效"), 3)
        return
    end

    o.auto_local_menu = requested
    persist_auto_menu_state()
    publish_auto_menu_state()
    mp.osd_message(requested
        and i18n.t("自动进入原盘菜单：已开启（下次打开生效）")
        or i18n.t("自动进入原盘菜单：已关闭（下次打开直接播放正片）"), 4)
end)

mp.register_script_message("open-menu-once", function(action)
    action = tostring(action or 'menu')
    if action ~= 'menu' and action ~= 'title-menu' and action ~= 'popup' then
        action = 'menu'
    end
    if is_remote_iso(iso_path) then
        mp.osd_message(i18n.t("网盘 ISO 保持主标题模式，暂不载入原盘菜单"), 4)
        return
    end
    if current_local_menu_session and is_current_local_disc() then
        mp.commandv("discnav", action)
        return
    end

    local target = iso_path
    if not target or target == '' then
        local stream_fn = mp.get_property("stream-open-filename") or ""
        if is_disc_protocol(stream_fn) then target = stream_fn end
    end
    if not target or target == '' then
        mp.osd_message(i18n.t("当前原盘无法重新载入菜单"), 4)
        return
    end

    forced_local_menu_once = true
    forced_local_menu_action = action
    mp.osd_message(i18n.t("正在重新载入原盘菜单（仅本次）"), 3)
    mp.commandv("loadfile", target, "replace")
end)

mp.observe_property("current-edition", "number", function()
    stop_started_root_navigation()
end)

mp.register_event("seek", function()
    stop_started_root_navigation(true)
end)

mp.observe_property("disc-menu-active", "bool", function(_, active)
    if active ~= true then return end
    hide_local_loading("disc-menu-active")
    stop_local_menu_autostart()
    if local_menu_navigation_hint_shown then return end
    local_menu_navigation_hint_shown = true
    mp.osd_message(
        i18n.t("蓝光菜单：方向键选择 · Enter 确认 · Esc / Backspace 返回 · Home 回蓝光菜单根目录"),
        5)
end)

mp.register_event("playback-restart", function()
    if is_remote_iso(iso_path) then
        hide_remote_loading("playback-restart")
    elseif iso_path then
        -- The loading card represents "no usable picture yet", not "the disc
        -- menu is already interactive".  Some BD-J/DIY discs legitimately
        -- mask Top Menu during First Play; keeping the card until that mask
        -- clears leaves it visibly covering already-playing video and also
        -- regresses ordinary ISOs.  As soon as mpv reports a real playback
        -- restart, release only our blocking overlay.  The bounded discnav
        -- retry chain intentionally keeps running in the background and can
        -- still enter the authored menu later without covering the picture.
        hide_local_loading("playback-restart-video-ready")
    end
end)

mp.register_event("end-file", clear_iso_state)
mp.register_event("shutdown", function()
    hide_remote_loading("shutdown")
    hide_local_loading("shutdown")
end)

publish_auto_menu_state()
msg.info("[auto_iso_loader] 已就绪")
