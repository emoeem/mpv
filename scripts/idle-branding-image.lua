local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    custom_enabled = false,
    custom_width = 0,
    custom_height = 0,
    custom_stride = 0,
    display_size = 168,
}
options.read_options(o, 'idle_branding')

-- mpv overlay IDs are limited to 0..63. Keep clear of thumbfast (42) and
-- startup-format-logos (50..52).
local overlay_id = 49
local custom_raw_path = mp.command_native({
    'expand-path',
    '~~/files/idle-branding-custom.bgra',
})
local default_raw_path = mp.command_native({
    'expand-path',
    '~~/script-assets/idle-branding/default-icon.bgra',
})
local default_image = {
    path = default_raw_path,
    width = 512,
    height = 512,
    stride = 2048,
}
local picker_path = mp.command_native({
    'expand-path',
    '~~/script-assets/idle-branding/select-image.ps1',
})
local picker_pending = false
local overlay_visible = false
local overlay_render_key = nil
local branding_state = nil
local refresh_timer = nil
local published = {}

local function clamp(minimum, value, maximum)
    return math.max(minimum, math.min(value, maximum))
end

local function round(value)
    return math.floor(value + 0.5)
end

local function set_published(name, value)
    value = tostring(value)
    if published[name] == value then return end
    published[name] = value
    mp.set_property('user-data/idle-branding-image/' .. name, value)
end

local function request_uosc_render()
    if refresh_timer then return end
    refresh_timer = mp.add_timeout(0, function()
        refresh_timer = nil
        mp.commandv('script-message-to', 'uosc', 'idle-branding-refresh')
    end)
end

local function valid_raw_image(path, width, height, stride)
    local info = path and utils.file_info(path)
    return width > 0 and height > 0 and stride == width * 4
        and info and info.is_file
        and (not info.size or info.size == stride * height)
end

local function custom_image()
    local image = {
        path = custom_raw_path,
        width = tonumber(o.custom_width) or 0,
        height = tonumber(o.custom_height) or 0,
        stride = tonumber(o.custom_stride) or 0,
    }
    if o.custom_enabled
        and valid_raw_image(image.path, image.width, image.height, image.stride) then
        return image
    end
end

local function current_image()
    local image = custom_image()
    if image then return image, 'custom' end
    if valid_raw_image(
        default_image.path,
        default_image.width,
        default_image.height,
        default_image.stride
    ) then
        return default_image, 'default'
    end
end

local function publish_mode()
    set_published('mode', custom_image() and 'custom' or 'default')
    mp.commandv('script-message-to', 'startup_window', 'image-ready')
end

local function persist_options()
    local config_path = mp.command_native({
        'expand-path',
        '~~/script-opts/idle_branding.conf',
    })
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('Could not persist idle branding image options')
        return false
    end
    file:write(string.format(
        '# mpv-Yaozhi 空闲启动页自定义图案\n'
            .. '# 通过“杳知 > 界面 > 选择启动页图片…”维护，请勿手工填写尺寸。\n'
            .. 'custom_enabled=%s\n'
            .. 'custom_width=%d\n'
            .. 'custom_height=%d\n'
            .. 'custom_stride=%d\n'
            .. '# 启动页图案在窗口中的最大逻辑尺寸；实际尺寸仍会随窗口自适应。\n'
            .. 'display_size=%d\n',
        o.custom_enabled and 'yes' or 'no',
        tonumber(o.custom_width) or 0,
        tonumber(o.custom_height) or 0,
        tonumber(o.custom_stride) or 0,
        tonumber(o.display_size) or 168
    ))
    file:close()
    return true
end

local function remove_overlay()
    if overlay_visible then
        pcall(mp.command_native, {'overlay-remove', overlay_id})
        overlay_visible = false
    end
    overlay_render_key = nil
    set_published('active', 'no')
    set_published('display-height', '0')
    set_published('center-y', '0')
end

local function branding_enabled()
    if branding_state ~= nil then return branding_state end
    return mp.get_property('user-data/uosc/idle-branding', 'yes') ~= 'no'
end

local function foreground_overlay_open()
    return mp.get_property_bool('user-data/file_browser/open', false)
        or mp.get_property_bool('user-data/yaozhi-donation/visible', false)
        or mp.get_property_native('user-data/uosc/menu/type') ~= nil
end

local function render_overlay()
    if not mp.get_property_bool('idle-active', false)
        or not branding_enabled()
        or foreground_overlay_open() then
        remove_overlay()
        publish_mode()
        request_uosc_render()
        return
    end

    local image, mode = current_image()
    if not image then
        remove_overlay()
        publish_mode()
        request_uosc_render()
        return
    end

    local dimensions = mp.get_property_native('osd-dimensions')
    local display_width = dimensions and tonumber(dimensions.w) or 0
    local display_height = dimensions and tonumber(dimensions.h) or 0
    if display_width <= 0 or display_height <= 0 then
        remove_overlay()
        return
    end

    local source_width = image.width
    local source_height = image.height
    local configured_size = math.max(56, tonumber(o.display_size) or 168)
    local smaller_side = math.min(display_width, display_height)
    local target_size = clamp(56, smaller_side * 0.18, configured_size)
    local scale = target_size / math.max(source_width, source_height)
    local width = math.max(1, round(source_width * scale))
    local height = math.max(1, round(source_height * scale))
    local center_x = display_width / 2
    local center_y = display_height / 2 - target_size * 0.16
    local x = round(center_x - width / 2)
    local y = round(center_y - height / 2)
    local render_key = table.concat({
        image.path, x, y, source_width, source_height, image.stride, width, height,
    }, ':')

    if not overlay_visible or overlay_render_key ~= render_key then
        local ok, err = pcall(mp.command_native, {
            'overlay-add',
            overlay_id,
            x,
            y,
            image.path,
            0,
            'bgra',
            source_width,
            source_height,
            image.stride,
            width,
            height,
        })
        if not ok then
            remove_overlay()
            msg.error('Unable to render idle branding image: ' .. tostring(err))
            request_uosc_render()
            return
        end
        overlay_visible = true
        overlay_render_key = render_key
    end

    set_published('active', 'yes')
    set_published('display-height', tostring(height))
    set_published('center-y', tostring(center_y))
    set_published('mode', mode)
    request_uosc_render()
end

local function on_branding_state_change(_, value)
    branding_state = tostring(value or 'yes') ~= 'no'
    render_overlay()
end

local function select_image()
    if picker_pending then
        mp.osd_message('启动页图片选择窗口已打开', 2)
        return
    end
    local picker_info = picker_path and utils.file_info(picker_path)
    if package.config:sub(1, 1) ~= '\\' or not picker_info or not picker_info.is_file then
        mp.osd_message('当前系统无法打开图片选择器', 3)
        return
    end

    picker_pending = true
    remove_overlay()
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            'powershell',
            '-NoLogo',
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            picker_path,
            '-OutputRaw',
            custom_raw_path,
        },
    }, function(success, result, error)
        picker_pending = false
        if not success or not result or result.status ~= 0 then
            msg.error('Idle branding image conversion failed: '
                .. tostring(result and result.stderr or error or 'unknown error'))
            mp.osd_message('启动页图片读取失败', 3)
            render_overlay()
            return
        end

        local data = utils.parse_json(result.stdout or '')
        if not data then
            msg.error('Idle branding image picker returned invalid data')
            mp.osd_message('启动页图片读取失败', 3)
            render_overlay()
            return
        end
        if data.cancelled then
            render_overlay()
            return
        end

        o.custom_enabled = true
        o.custom_width = tonumber(data.width) or 0
        o.custom_height = tonumber(data.height) or 0
        o.custom_stride = tonumber(data.stride) or o.custom_width * 4
        persist_options()
        publish_mode()
        render_overlay()
        mp.osd_message('启动页图片：已使用自定义图案', 2)
    end)
end

local function reset_image()
    o.custom_enabled = false
    persist_options()
    remove_overlay()
    publish_mode()
    render_overlay()
    mp.osd_message('启动页图片：已恢复默认图案', 2)
end

mp.register_script_message('select', select_image)
mp.register_script_message('reset', reset_image)
mp.register_script_message('refresh', render_overlay)
mp.register_script_message('branding-state', function(value)
    on_branding_state_change(nil, value)
end)

mp.observe_property('idle-active', 'bool', render_overlay)
mp.observe_property('osd-dimensions', 'native', render_overlay)
mp.observe_property('user-data/uosc/idle-branding', 'string', on_branding_state_change)
mp.observe_property('user-data/file_browser/open', 'bool', render_overlay)
mp.observe_property('user-data/yaozhi-donation/visible', 'bool', render_overlay)
mp.observe_property('user-data/uosc/menu/type', 'native', render_overlay)
mp.register_event('shutdown', remove_overlay)

publish_mode()
render_overlay()
