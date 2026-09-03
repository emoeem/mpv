-- ontop_mode.lua
-- 三态置顶图钉按钮：取消置顶 / 播放时置顶 / 始终置顶
-- 独立悬浮版：不依赖 uosc.conf，不需要快捷键
-- 显示逻辑：鼠标越靠近右上角越明显；鼠标悬停按钮时显示类似系统按钮的反馈底色

local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    -- 由 uosc 顶栏统一绘制图钉；本脚本只保留三态置顶逻辑。
    integrated_top_bar = true,

    -- 按钮位置：固定在播放器窗口右上角，不跟随视频画面缩放/黑边变化
    -- right 越大越往左；top 越大越往下
    right = 198,
    top = 6,
    width = 44,
    height = 40,
    icon_size = 18,

    -- 全屏专用位置：双击全屏后右上角按钮布局会变化，所以单独微调
    -- fs_right 越大越往左；fs_top 越大越往下
    fs_right = 238,
    fs_top = 6,
    fs_width = 44,
    fs_height = 40,
    fs_icon_size = 18,

    -- 渐显范围：鼠标越靠近右上角，图标越明显
    fade_right_start = 360,
    fade_right_full = 210,
    fade_top_start = 95,
    fade_top_full = 45,

    -- 取消置顶状态下图标稍淡；播放时置顶/始终置顶为正常亮度
    off_opacity = 0.48,
    active_opacity = 1.00,

    -- 悬停反馈：鼠标放到图钉上时，显示类似右侧窗口按钮的浅色底
    hover_bg_opacity = 0.92,
    hover_icon_opacity = 1.00,

    -- 顶栏中央状态提示：与 uosc 的 36px 顶栏共用视觉中线。
    feedback_top_bar_size = 36,
    feedback_font_size = 18,
    feedback_width = 196,
    feedback_height = 30,

    show_in_fullscreen = true,
}
options.read_options(opts, 'ontop_mode')

local modes = {
    { id = 'always',  label = '始终置顶'   },
    { id = 'playing', label = '播放时置顶' },
    { id = 'off',     label = '取消置顶'   },
}

-- 默认：播放时置顶
local index = 2
local mouse_binding_active = false

local overlay = nil
local overlay_ok = pcall(function()
    overlay = mp.create_osd_overlay('ass-events')
    overlay.z = 1000
end)

local feedback_overlay = nil
local feedback_overlay_ok = pcall(function()
    feedback_overlay = mp.create_osd_overlay('ass-events')
    feedback_overlay.z = 3000
end)
local feedback_timer = nil

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function smoothstep(t)
    t = clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

local function ass_alpha(opacity)
    opacity = clamp(opacity, 0, 1)
    local a = math.floor(255 - opacity * 255 + 0.5)
    return string.format('&H%02X&', a)
end

local function current()
    return modes[index]
end

local function get_osd_size()
    local w, h = mp.get_osd_size()
    if not w or not h or w <= 0 or h <= 0 then
        local dim = mp.get_property_native('osd-dimensions')
        if dim then
            w = dim.w or dim.width or 0
            h = dim.h or dim.height or 0
        end
    end
    return w or 0, h or 0
end

local function get_mouse()
    return mp.get_property_native('mouse-pos')
end

local function get_layout()
    if mp.get_property_bool('fullscreen', false) then
        return {
            right = opts.fs_right,
            top = opts.fs_top,
            width = opts.fs_width,
            height = opts.fs_height,
            icon_size = opts.fs_icon_size,
        }
    end

    return {
        right = opts.right,
        top = opts.top,
        width = opts.width,
        height = opts.height,
        icon_size = opts.icon_size,
    }
end

local function button_rect()
    local osd_w, osd_h = get_osd_size()
    if osd_w <= 0 or osd_h <= 0 then return nil end

    local layout = get_layout()
    local x1 = osd_w - layout.right
    local y1 = layout.top
    return {
        x1 = x1,
        y1 = y1,
        x2 = x1 + layout.width,
        y2 = y1 + layout.height,
        w = layout.width,
        h = layout.height,
    }
end

local function mouse_in_rect(rect)
    local mouse = get_mouse()
    if not mouse or not mouse.x or not mouse.y then return false end
    return mouse.x >= rect.x1 and mouse.x <= rect.x2 and mouse.y >= rect.y1 and mouse.y <= rect.y2
end

local function fade_opacity()
    if mp.get_property_bool('fullscreen', false) and not opts.show_in_fullscreen then
        return 0
    end

    local osd_w, osd_h = get_osd_size()
    if osd_w <= 0 or osd_h <= 0 then return 0 end

    local mouse = get_mouse()
    if not mouse or not mouse.x or not mouse.y then return 0 end

    -- dx 越小越靠近右边；dy 越小越靠近顶部
    local dx = osd_w - mouse.x
    local dy = mouse.y

    local rx = (opts.fade_right_start - dx) / math.max(1, opts.fade_right_start - opts.fade_right_full)
    local ry = (opts.fade_top_start - dy) / math.max(1, opts.fade_top_start - opts.fade_top_full)

    return smoothstep(math.min(rx, ry))
end

local function path_scaled(points, scale)
    local out = {}
    for _, p in ipairs(points) do
        if type(p) == 'string' then
            table.insert(out, p)
        else
            table.insert(out, string.format('%.2f %.2f', p[1] * scale, p[2] * scale))
        end
    end
    return table.concat(out, ' ')
end

local function clear_button()
    if overlay_ok and overlay then
        overlay.data = ''
        overlay:update()
    else
        mp.set_osd_ass(0, 0, '')
    end
end

local function set_ass(osd_w, osd_h, ass)
    if overlay_ok and overlay then
        overlay.res_x = osd_w
        overlay.res_y = osd_h
        overlay.data = ass
        overlay:update()
    else
        mp.set_osd_ass(osd_w, osd_h, ass)
    end
end

local function clear_feedback()
    if feedback_overlay_ok and feedback_overlay then
        feedback_overlay.data = ''
        feedback_overlay:update()
    end
end

local function show_feedback(text)
    local osd_w, osd_h = get_osd_size()
    if not feedback_overlay_ok or not feedback_overlay or osd_w <= 0 or osd_h <= 0 then
        mp.osd_message(text, 1.2)
        return
    end

    -- uosc scales its top bar with display-hidpi-scale. Use the same factor so
    -- the feedback stays vertically centered at 100%, 125%, 150% DPI, etc.
    local ui_scale = mp.get_property_number('display-hidpi-scale', 1) or 1
    local top_bar_size = opts.feedback_top_bar_size * ui_scale
    local cx = osd_w / 2
    local cy = top_bar_size / 2
    local width = opts.feedback_width * ui_scale
    local height = math.min(opts.feedback_height * ui_scale, top_bar_size - 4 * ui_scale)
    local font_size = opts.feedback_font_size * ui_scale
    local ax, ay = cx - width / 2, cy - height / 2
    local bx, by = cx + width / 2, cy + height / 2
    local radius = math.min(7 * ui_scale, height / 2)
    local background = string.format(
        '{\\an7\\pos(0,0)\\p1\\bord%.1f\\blur%.1f\\1c&H3A2410&\\3c&H6A4A2D&\\1a&H38&\\3a&H68&}'
        .. 'm %.1f %.1f l %.1f %.1f '
        .. 'b %.1f %.1f %.1f %.1f %.1f %.1f '
        .. 'l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f '
        .. 'l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f '
        .. 'l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f{\\p0}',
        ui_scale, 0.5 * ui_scale,
        ax + radius, ay, bx - radius, ay,
        bx - radius / 2, ay, bx, ay + radius / 2, bx, ay + radius,
        bx, by - radius,
        bx, by - radius / 2, bx - radius / 2, by, bx - radius, by,
        ax + radius, by,
        ax + radius / 2, by, ax, by - radius / 2, ax, by - radius,
        ax, ay + radius,
        ax, ay + radius / 2, ax + radius / 2, ay, ax + radius, ay
    )
    local label = string.format(
        '{\\an5\\pos(%.1f,%.1f)\\fs%.1f\\fn%s\\b1\\bord1\\shad0\\1c&HF6F0E8&\\3c&H2E1B0D&}%s',
        cx, cy, font_size, 'Microsoft YaHei UI', text
    )

    feedback_overlay.res_x = osd_w
    feedback_overlay.res_y = osd_h
    feedback_overlay.data = background .. '\n' .. label
    feedback_overlay:update()

    if feedback_timer then feedback_timer:kill() end
    feedback_timer = mp.add_timeout(1.2, clear_feedback)
end

local function draw_button()
    if opts.integrated_top_bar then
        clear_button()
        return
    end

    local reveal = fade_opacity()
    if reveal <= 0.01 then
        clear_button()
        return
    end

    local osd_w, osd_h = get_osd_size()
    local rect = button_rect()
    if not rect then
        clear_button()
        return
    end

    local mode = current()
    local hover = mouse_in_rect(rect)

    local base_opacity = (mode.id == 'off') and opts.off_opacity or opts.active_opacity
    local icon_opacity = reveal * base_opacity
    local icon_color = '&HFFFFFF&'

    local ass = {}

    -- 悬停反馈：模拟右上角窗口按钮的浅色高亮块
    -- ASS 的颜色格式是 BGR，&HF4F0F2& 接近浅白色
    if hover then
        local bg_opacity = reveal * opts.hover_bg_opacity
        table.insert(ass, string.format(
            '{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&HF4F0F2&\\alpha%s\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}',
            rect.x1, rect.y1, ass_alpha(bg_opacity), rect.w, rect.w, rect.h, rect.h
        ))

        -- 悬停时图标变成深色，更接近系统按钮反馈
        icon_opacity = reveal * opts.hover_icon_opacity
        icon_color = '&H202020&'
    end

    local layout = get_layout()
    local s = layout.icon_size / 24
    local cx = rect.x1 + rect.w / 2
    local cy = rect.y1 + rect.h / 2
    local icon_x = cx - 12 * s
    local icon_y = cy - 12 * s

    -- 简化 push_pin 矢量图标，旋转后接近系统按钮风格
    local points = {
        'm', {16,12}, 'l', {16,4}, 'l', {17,4}, 'l', {17,2},
        'l', {7,2}, 'l', {7,4}, 'l', {8,4}, 'l', {8,12},
        'l', {6,14}, 'l', {6,16}, 'l', {11.2,16}, 'l', {11.2,22},
        'l', {12.8,22}, 'l', {12.8,16}, 'l', {18,16}, 'l', {18,14},
        'l', {16,12},
    }

    table.insert(ass, string.format(
        '{\\an7\\pos(%.1f,%.1f)\\org(%.1f,%.1f)\\frz-45\\bord0\\shad0\\1c%s\\alpha%s\\p1}%s{\\p0}',
        icon_x, icon_y, cx, cy, icon_color, ass_alpha(icon_opacity), path_scaled(points, s)
    ))

    set_ass(osd_w, osd_h, table.concat(ass, '\n'))
end

local expected_ontop = nil

local function set_ontop_by_mode()
    local mode = current().id
    local target

    if mode == 'always' then
        target = true
    elseif mode == 'off' then
        target = false
    else
        local paused = mp.get_property_bool('pause', false)
        local idle = mp.get_property_bool('idle-active', false)
        target = not paused and not idle
    end

    expected_ontop = target
    mp.set_property_bool('ontop', target)
end

local state_path = nil
local function get_state_path()
    if not state_path then
        state_path = mp.command_native({"expand-path", "~~/files/ontop_mode_state"})
    end
    return state_path
end

local function save_state()
    local file = io.open(get_state_path(), "w")
    if file then
        file:write(current().id)
        file:close()
    end
end

local function load_state()
    local file = io.open(get_state_path(), "r")
    if not file then return nil end
    local saved = file:read("*a")
    file:close()
    if saved then
        for i, mode in ipairs(modes) do
            if mode.id == saved:match("^(%S+)") then return i end
        end
    end
    return nil
end

local initial_load_done = false

local function apply()
    set_ontop_by_mode()
    mp.set_property('user-data/ontop-mode', current().id)
    if initial_load_done then save_state() end
    draw_button()
end

local function cycle()
    index = index + 1
    if index > #modes then index = 1 end

    apply()
    show_feedback('置顶模式：' .. current().label)
end

mp.register_script_message('cycle', cycle)

-- uosc 顶栏按钮点击 → 三态循环
local function sync_from_ontop(_, value)
    if value == expected_ontop then return end
    cycle()
end

local function update_mouse_binding()
    local rect = button_rect()
    local inside_button = rect and fade_opacity() > 0.08 and mouse_in_rect(rect)

    if inside_button and not mouse_binding_active then
        mp.add_forced_key_binding('MBTN_LEFT', 'ontop_mode_mouse_click', function()
            cycle()
        end)
        mouse_binding_active = true
    elseif not inside_button and mouse_binding_active then
        mp.remove_key_binding('ontop_mode_mouse_click')
        mouse_binding_active = false
    end
end

mp.observe_property('pause', 'bool', apply)
mp.observe_property('idle-active', 'bool', apply)
mp.observe_property('fullscreen', 'bool', draw_button)
mp.observe_property('ontop', 'bool', sync_from_ontop)

mp.register_event('file-loaded', apply)
mp.register_event('end-file', apply)
mp.register_event('video-reconfig', draw_button)

if opts.integrated_top_bar then
    clear_button()
else
    mp.add_periodic_timer(0.03, function()
        draw_button()
        update_mouse_binding()
    end)
end

mp.msg.info('ontop_mode integrated top bar mode loaded')
mp.add_timeout(0.5, function()
    local saved = load_state()
    if saved then index = saved end
    initial_load_done = true
    apply()
    show_feedback('置顶模式：' .. current().label)
end)
