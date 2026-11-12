local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    mode = 'auto',
    peak = 203,
}
options.read_options(o, 'image_subs_brightness')

local config_path = mp.command_native({
    'expand-path',
    '~~/script-opts/image_subs_brightness.conf',
})

local apply_timer

local function normalize_peak(value)
    local peak = tonumber(value)
    if not peak then return nil end
    return math.floor(math.max(10, math.min(10000, peak)) + 0.5)
end

local function normalize_mode(value)
    value = tostring(value or ''):lower()
    if value == 'auto' or value == 'video' or value == 'sdr' then return value end
    return nil
end

local function label_for_peak(peak)
    if peak == 150 then return i18n.t('柔和 · 150 nits') end
    if peak == 203 then return i18n.t('标准 · 203 nits') end
    if peak == 250 then return i18n.t('明亮 · 250 nits') end
    if peak == 300 then return i18n.t('高亮 · 300 nits') end
    if peak == 400 then return i18n.t('较强 · 400 nits') end
    return string.format('%d nits', peak)
end

local function label_for_mode(mode)
    if mode == 'video' then return i18n.t('随视频（HDR 原生）') end
    if mode == 'sdr' then return 'SDR / sRGB' end
    return i18n.t('自动判断')
end

local function core_supported()
    return mp.get_property('image-subs-colorspace', '') ~= ''
end

local function selected_track(track_type)
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == track_type and track.selected then return track end
    end
end

local function image_subtitle_kind(track)
    local codec = tostring(track and track.codec or ''):lower()
    if codec:find('pgs', 1, true) or codec == 'hdmv_pgs_subtitle' then return 'PGS' end
    if codec:find('vobsub', 1, true) or codec == 'dvd_subtitle' then return 'VobSub' end
    if codec:find('dvb', 1, true) then return 'DVB' end
end

local function source_is_hdr(video_track)
    local gamma = mp.get_property('video-params/gamma', ''):lower()
    if gamma == 'pq' or gamma == 'hlg' then return true end

    local profile = tonumber(video_track and video_track['dolby-vision-profile'])
    return profile ~= nil and profile > 0
end

local function source_is_uhd(video_track)
    local width = tonumber(mp.get_property_native('video-params/w'))
        or tonumber(video_track and video_track['demux-w'])
        or 0
    local height = tonumber(mp.get_property_native('video-params/h'))
        or tonumber(video_track and video_track['demux-h'])
        or 0
    return width >= 3000 and height >= 1600
end

local function resolve_mode()
    local requested = normalize_mode(o.mode) or 'auto'
    if requested ~= 'auto' then
        return requested, i18n.t('手动指定')
    end

    local subtitle = selected_track('sub')
    local kind = image_subtitle_kind(subtitle)
    local video = selected_track('video')
    local hdr = source_is_hdr(video)

    -- PGS 没有可供播放器可靠判断 HDR/SDR 的标准色彩元数据。
    -- UHD HDR/DV 正片中的内封 PGS 通常按正片 PQ/BT.2020 调色板制作，
    -- 应随视频进入同一色彩管理链；外置 PGS、VobSub 与 DVB 则保守按 SDR 处理。
    if hdr and kind == 'PGS' and subtitle and not subtitle.external and source_is_uhd(video) then
        return 'video', i18n.t('UHD HDR/DV 内封 PGS')
    end
    if hdr and kind then
        return 'sdr', (subtitle and subtitle.external and i18n.t('HDR 外置 ') or 'HDR ') .. kind
    end

    return 'video', kind and ('SDR ' .. kind) or i18n.t('非 HDR 或无图形字幕')
end

-- 状态由 video-params/track-list 驱动，在 HDR 片源播放期间会被反复触发。
-- 无去重时每次都提交相同内容，仅增加属性系统与日志负担；比较须用 native 值，
-- 因为 user-data 字符串经 mp.get_property 读回会带 JSON 引号。
-- 属性不存在时 get_property_native 会返回 (nil, "property not found")，必须先用
-- 局部变量收敛成单值，否则内层 tonumber 会把这句错误描述当成第二个实参。
local function set_if_changed(name, value)
    local current = mp.get_property_native(name)
    if tostring(current) ~= tostring(value) then
        mp.set_property(name, value)
    end
end

local function set_number_if_changed(name, value)
    local target = tonumber(value)
    if not target then return end
    local current = mp.get_property_native(name)
    if tonumber(current) ~= target then
        mp.set_property_number(name, target)
    end
end

-- Core image-subtitle options can invalidate renderer state even when the
-- effective value is unchanged.  Dynamic DV/HDR metadata used to make the
-- aggregate video-params observer submit the same two options many times per
-- second.  Keep the core write path idempotent as a second line of defence.
local function set_core_if_changed(name, value)
    local target = tostring(value)
    local current = mp.get_property_native(name)
    if current ~= nil and tostring(current) == target then
        return true, nil
    end
    return pcall(mp.set_property, name, target)
end

local function publish_state(supported, peak, requested, effective, reason)
    local effective_peak = effective == 'video' and 'video' or tostring(peak)
    set_if_changed('user-data/image-subs-brightness/supported', supported and 'yes' or 'no')
    set_number_if_changed('user-data/image-subs-brightness/peak', peak)
    set_if_changed('user-data/image-subs-brightness/label', label_for_peak(peak))
    set_if_changed('user-data/image-subs-brightness/mode', requested)
    set_if_changed('user-data/image-subs-brightness/mode-label', label_for_mode(requested))
    set_if_changed('user-data/image-subs-brightness/effective-mode', effective)
    set_if_changed('user-data/image-subs-brightness/effective-label', label_for_mode(effective))
    set_if_changed('user-data/image-subs-brightness/effective-peak', effective_peak)
    set_if_changed('user-data/image-subs-brightness/reason', reason or '')
end

local function persist_settings()
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('无法保存图形字幕设置：' .. tostring(config_path))
        return false
    end
    file:write(
        '# HDR 图形字幕色彩与参考白；仅影响 PGS/VobSub/DVB，不影响视频、ASS 或 OSD。\n'
            .. '# mode=auto 自动区分 UHD HDR/DV 内封 PGS 与 SDR 图形字幕；必要时可在菜单手动覆盖。\n'
            .. '# 通过“Emo > HDR 图形字幕色彩与亮度”维护。\n'
            .. string.format('mode=%s\n', normalize_mode(o.mode) or 'auto')
            .. string.format('peak=%d\n', normalize_peak(o.peak) or 203)
    )
    file:close()
    return true
end

local function apply_settings(show_osd)
    local peak = normalize_peak(o.peak) or 203
    local requested = normalize_mode(o.mode) or 'auto'
    o.peak = peak
    o.mode = requested

    local supported = core_supported()
    local effective, reason = resolve_mode()

    if supported then
        local color_ok, color_err = set_core_if_changed('image-subs-colorspace', effective)
        local effective_peak = effective == 'video' and 'video' or tostring(peak)
        local peak_ok, peak_err = set_core_if_changed('image-subs-hdr-peak', effective_peak)
        if not color_ok or not peak_ok then
            supported = false
            msg.error('无法应用图形字幕设置：' .. tostring(color_err or peak_err))
        end
    end

    publish_state(supported, peak, requested, effective, reason)
    if show_osd then
        if supported then
            local mode_text = requested == 'auto'
                and string.format(i18n.t('自动 → %s（%s）'), label_for_mode(effective), reason)
                or label_for_mode(effective)
            local peak_text = effective == 'video' and i18n.t('峰值随视频') or label_for_peak(peak)
            mp.osd_message(string.format(i18n.t('HDR 图形字幕：%s；%s'), mode_text, peak_text), 3)
        else
            mp.osd_message(i18n.t('当前 mpv 核心不支持独立图形字幕色彩管理'), 3)
        end
    end
end

local function schedule_apply()
    if not apply_timer then
        apply_timer = mp.add_timeout(0.05, function()
            apply_timer = nil
            apply_settings(false)
        end)
    else
        apply_timer:kill()
        apply_timer:resume()
    end
end

mp.register_script_message('set', function(value)
    local peak = normalize_peak(value)
    if not peak then
        mp.osd_message(i18n.t('无效的图形字幕亮度'), 2)
        return
    end
    o.peak = peak
    -- A numeric reference-white preset only has meaning on the SDR/sRGB
    -- bitmap path. Make the menu action effective immediately instead of
    -- silently storing a value while auto/video mode continues to ignore it.
    o.mode = 'sdr'
    persist_settings()
    apply_settings(true)
end)

mp.register_script_message('set-mode', function(value)
    local mode = normalize_mode(value)
    if not mode then
        mp.osd_message(i18n.t('无效的图形字幕色彩模式'), 2)
        return
    end
    o.mode = mode
    persist_settings()
    apply_settings(true)
end)

mp.observe_property('track-list', 'native', schedule_apply)
-- Do not observe the aggregate video-params table: Dolby Vision/HDR dynamic
-- metadata can update it many times per second even though subtitle colour
-- policy has not changed.  Only the fields resolve_mode() actually consumes
-- are relevant here.
for _, property in ipairs({
    'video-params/gamma',
    'video-params/w',
    'video-params/h',
    'current-tracks/video/dolby-vision-profile',
}) do
    mp.observe_property(property, 'native', schedule_apply)
end
mp.register_event('file-loaded', schedule_apply)
mp.register_event('playback-restart', schedule_apply)

mp.add_timeout(0, function()
    apply_settings(false)
end)
