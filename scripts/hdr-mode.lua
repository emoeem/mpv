local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
-- Copyright (c) 2025 dyphire <qimoge@gmail.com>
-- License: MIT
-- link: https://github.com/dyphire/mpv-scripts
-- Automatically switches the display's SDR and HDR modes for HDR passthrough
-- based on the content of the video being played by the mpv, only works on Windows 10 and later systems

--! Required for use with mpv-display-plugin: https://github.com/dyphire/mpv-display-plugin

local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    -- Specify the script working mode, value: noth, pass, switch. default: noth
    -- noth: Do nothing
    -- pass: Passing HDR signals for HDR content when the monitor is in HDR mode
    -- switch: Automatically switch between HDR displays and SDR displays
    -- on Windows 10 and later based on video specifications
    hdr_mode = "noth",
    -- auto: preserve the existing automatic HDR behavior.
    -- sdr: force this player to render SDR and tone-map HDR content without
    -- changing the Windows HDR switch.
    output_mode = "auto",
    -- auto keeps renderer/driver negotiation; full and limited are explicit
    -- compatibility overrides for a known GPU/display range mismatch.
    output_range = "auto",
    -- Specify whether to switch HDR mode only when the window is in fullscreen or window maximized
    -- only works with hdr_mode = "switch", default: false
    fullscreen_only = false,
    -- Maximum time to wait for the display HDR status to reach the requested state.
    -- The switch completes immediately when hdr-status changes; this is only a safety timeout.
    hdr_wait = 8,
     -- Specify the target peak of the HDR display, default: 0
    -- By default, the display peak information property provided by mpv-display-plugin 
    -- will be used: "user-data/display-info/max-luminance"
    -- Specific values can also be specified to override internal detection,
    -- but it must be the true peak brightness of the monitor,
    target_peak = "0",
    -- Specifies the measured contrast of the output display.
    -- Used in black point compensation during HDR tone-mapping and HDR passthrough.
    -- Must be the true contrast information of the display, e.g. 100000 means 100000:1 maximum contrast
    -- The default value auto will try to use the display black level attribute provided 
    -- by mpv-display-plugin to calculate the correct value: "user-data/display-info/min-luminance"
    -- OLED displays can specify the special value "inf" to apply infinite contrast
    target_contrast = "auto",
}
options.read_options(o, _, function() end)
o.output_mode = tostring(o.output_mode or "auto"):lower() == "sdr" and "sdr" or "auto"
do
    local value = tostring(o.output_range or "auto"):lower()
    o.output_range = (value == "full" or value == "limited") and value or "auto"
end
local config_path = mp.command_native({"expand-path", "~~/script-opts/hdr_mode.conf"})

local hdr_active = false
local hdr_supported = false
local hdr_switch_pending = false
local first_switch_check = true
local file_loaded = false
local file_generation = 0
local display_refresh_timer = nil
local switch_timer = nil
local switch_context = nil
local pause_write_expected = nil
local hdr_unsupported_warned = false
local hdr_check_disabled = false
-- Failed Windows HDR toggles are remembered only for this mpv process and
-- only for the display that actually failed the full status confirmation.
local hdr_toggle_unavailable = {}
local hdr_toggle_skip_logged = {}
local shutdown_watchdog_token = nil
local shutdown_watchdog_result = nil
local shutdown_watchdog_poll_timer = nil
local shutdown_restore_requested = false
local initial_hdr_status = nil
local display_hdr_owned = false
local last_observed_hdr_status = nil
local resolved_target_peak = tonumber(o.target_peak) or 0
local resolved_target_contrast = o.target_contrast
local manual_force = {
    active = false,
    restoring = false,
    saved = nil,
    applied = nil,
}

local state = {
    icc_profile = mp.get_property_native("icc-profile"),
    icc_profile_auto = mp.get_property_native("icc-profile-auto"),
    target_peak = mp.get_property_native("target-peak"),
    target_prim = mp.get_property_native("target-prim"),
    target_trc = mp.get_property_native("target-trc"),
    target_contrast = mp.get_property_native("target-contrast"),
    colorspace_hint = mp.get_property_native("target-colorspace-hint"),
    inverse_mapping = mp.get_property_native("inverse-tone-mapping")
}

local resolved_sdr_target_contrast = state.target_contrast
local sdr_target_contrast_source = "renderer-auto"

local manual_property_names = {
    "icc-profile",
    "icc-profile-auto",
    "target-peak",
    "target-prim",
    "target-trc",
    "target-colorspace-hint",
    "target-colorspace-hint-mode",
    "inverse-tone-mapping",
}

local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

local function bool_value(value)
    return value == true or value == 1 or value == "1" or
        value == "yes" or value == "true" or value == "on"
end

-- Dynamic HDR frame metadata can notify video-out-params many times each
-- second. Apply a policy only when its effective value changes; redundant
-- ICC/output writes still pass through the core renderer option machinery.
local function set_output_if_changed(name, value)
    local current = mp.get_property_native(name)
    local equal = current == value
    if not equal and (name == 'icc-profile-auto' or name == 'inverse-tone-mapping'
        or name == 'target-colorspace-hint') then
        equal = current ~= nil and bool_value(current) == bool_value(value)
    elseif not equal and current ~= nil and value ~= nil then
        equal = tostring(current) == tostring(value)
            or (tonumber(current) ~= nil and tonumber(current) == tonumber(value))
    end
    if not equal then mp.set_property_native(name, value) end
end

local function publish_if_changed(name, value)
    -- user-data 为字符串时 mp.get_property 读回带 JSON 引号，去重比较须用 native 值。
    -- 属性不存在时 get_property_native 返回 (nil, 错误描述)，先用局部变量收敛成单值。
    local current = mp.get_property_native(name)
    if tostring(current) ~= tostring(value) then
        mp.set_property(name, value)
    end
end

local function persist_option(name, value)
    local file = config_path and io.open(config_path, "rb") or nil
    if not file then
        msg.error("Could not read HDR configuration: " .. tostring(config_path))
        return false
    end
    local data = file:read("*a") or ""
    file:close()
    local replacement = name .. "=" .. value
    local replaced = false
    data = data:gsub("([\r\n]?)" .. name .. "%s*=[^\r\n]*", function(prefix)
        if replaced then return prefix .. replacement end
        replaced = true
        return prefix .. replacement
    end)
    if not replaced then
        if data ~= "" and not data:match("[\r\n]$") then data = data .. "\n" end
        data = data .. replacement .. "\n"
    end
    file = io.open(config_path, "wb")
    if not file then
        msg.error("Could not write HDR configuration: " .. tostring(config_path))
        return false
    end
    file:write(data)
    file:close()
    return true
end

local function get_display_hdr_capability()
    local supported = mp.get_property_native("user-data/display-info/hdr-supported")
    local status = tostring(mp.get_property_native("user-data/display-info/hdr-status") or "")
    if supported == false or supported == "false" or status == "unsupported" then
        return false, status
    end
    if bool_value(supported) or status == "on" or status == "off" then
        return true, status
    end
    return nil, status
end

local function get_display_uid()
    local uid = mp.get_property_native("user-data/display-info/uid")
    uid = uid ~= nil and tostring(uid) or ""
    return uid ~= "" and uid ~= "unknown" and uid or nil
end

local function params_are_hdr(params)
    local gamma = params and tostring(params["gamma"] or ""):lower() or ""
    return gamma == "pq" or gamma == "hlg"
end

local function publish_manual_force_state()
    mp.set_property("user-data/hdr-mode/manual-force", manual_force.active and "yes" or "no")
end

local function publish_output_mode()
    mp.set_property("user-data/hdr-mode/output-mode", o.output_mode)
    mp.set_property("user-data/hdr-mode/output-mode-label",
        o.output_mode == "sdr" and "播放器 HDR→SDR" or "自动选择 HDR/SDR")
    mp.set_property("user-data/hdr-mode/system-hdr-control",
        o.output_mode == "sdr" and "unchanged" or "automatic")
end

local output_range_labels = {
    auto = "自动协商（推荐）",
    full = "RGB Full（0–255）",
    limited = "Limited（16–235）",
}

local function range_label(value)
    value = tostring(value or "unknown"):lower()
    if value == "full" then return "Full" end
    if value == "limited" then return "Limited" end
    return "未知"
end

local function publish_black_level_state()
    local source_params = mp.get_property_native("video-params", {})
    local target_params = mp.get_property_native("video-target-params", {})
    if type(source_params) ~= "table" then source_params = {} end
    if type(target_params) ~= "table" then target_params = {} end
    local source_range = type(source_params) == "table"
        and source_params.colorlevels or "unknown"
    local target_range = type(target_params) == "table"
        and target_params.colorlevels or "unknown"
    local source_trc = type(source_params) == "table"
        and source_params.gamma or "unknown"
    local target_trc = type(target_params) == "table"
        and target_params.gamma or "unknown"
    local target_format = type(target_params) == "table"
        and target_params.pixelformat or "unknown"
    local hdr_to_sdr = params_are_hdr(source_params) and not params_are_hdr(target_params)
    local quantization = tostring(target_format)
    if quantization:match("10") then
        quantization = "10-bit（" .. quantization .. "）"
    elseif quantization:match("16f") then
        quantization = "16-bit float（" .. quantization .. "）"
    elseif quantization == "rgba" or quantization == "bgra"
        or quantization:match("8") then
        quantization = "8-bit（" .. quantization .. "）"
    end
    quantization = quantization .. " · dither="
        .. mp.get_property("dither-depth", "auto")
    local brightness = mp.get_property_number("brightness", 0) or 0
    local contrast = mp.get_property_number("contrast", 0) or 0
    local gamma = mp.get_property_number("gamma", 0) or 0
    local manual_equalizer = math.abs(brightness) > 0.0001
        or math.abs(contrast) > 0.0001 or math.abs(gamma) > 0.0001
    local reason_code = manual_equalizer and "manual-equalizer"
        or o.output_range == "full" and "explicit-full"
        or o.output_range == "limited" and "explicit-limited"
        or source_range == "limited" and target_range == "full" and "legal-to-full"
        or source_range == target_range and source_range ~= "unknown" and "range-matched"
        or target_range == "unknown" and "detecting"
        or "automatic-negotiation"
    local detail = string.format(
        "源 %s/%s → 目标 %s/%s · %s / %s",
        range_label(source_range), tostring(source_trc),
        range_label(target_range), tostring(target_trc),
        mp.get_property("current-vo", mp.get_property("vo", "unknown")),
        mp.get_property("current-gpu-context", "unknown"))
    if manual_equalizer then
        detail = detail .. string.format(" · 手动画面校正 B/C/G=%.2f/%.2f/%.2f",
            brightness, contrast, gamma)
    end
    publish_if_changed("user-data/black-level/output-range-mode", o.output_range)
    publish_if_changed("user-data/black-level/output-range-mode-label",
        output_range_labels[o.output_range])
    publish_if_changed("user-data/black-level/source-range", tostring(source_range))
    publish_if_changed("user-data/black-level/target-range", tostring(target_range))
    publish_if_changed("user-data/black-level/reason-code", reason_code)
    publish_if_changed("user-data/black-level/detail", detail)
    publish_if_changed("user-data/black-level/manual-equalizer",
        manual_equalizer and "yes" or "no")
    publish_if_changed("user-data/black-level/hdr-to-sdr",
        hdr_to_sdr and "yes" or "no")
    publish_if_changed("user-data/black-level/black-point-policy",
        hdr_to_sdr and sdr_target_contrast_source or "native-source")
    publish_if_changed("user-data/black-level/quantization", quantization)
end

local function apply_output_range()
    if mp.get_property("video-output-levels", "auto") ~= o.output_range then
        mp.set_property("video-output-levels", o.output_range)
    end
    mp.add_timeout(0, publish_black_level_state)
    mp.add_timeout(0.2, publish_black_level_state)
end

local function refresh_black_level_menu(requested)
    if requested ~= "refresh" then return end
    mp.add_timeout(0.05, function()
        mp.commandv("script-message", "codex-open-black-level-menu")
    end)
end

local function snapshot_manual_properties()
    local saved = {}
    for _, name in ipairs(manual_property_names) do
        saved[name] = mp.get_property_native(name)
    end
    return saved
end

local function restore_manual_properties()
    if not manual_force.saved then return end
    manual_force.restoring = true
    for _, name in ipairs(manual_property_names) do
        local value = manual_force.saved[name]
        if value ~= nil and manual_force.applied[name] ~= nil
            and mp.get_property_native(name) == manual_force.applied[name] then
            mp.set_property_native(name, value)
        end
    end
    manual_force.restoring = false
end

local function disable_manual_force(show_message)
    if not manual_force.active then return false end
    restore_manual_properties()
    manual_force.active = false
    manual_force.saved = nil
    manual_force.applied = nil
    publish_manual_force_state()
    if show_message then
        mp.osd_message(i18n.t("强制 HDR 已关闭，已恢复自动输出"), 2)
    end
    msg.info("Manual HDR override disabled; restored previous target settings")
    return true
end

local function reject_manual_force(message)
    mp.osd_message(message, 3)
    msg.warn("Manual HDR override rejected: " .. message)
    return false
end

local function enable_manual_force()
    if o.output_mode == "sdr" then
        return reject_manual_force("已选择播放器 HDR→SDR；请先恢复自动输出")
    end
    local supported, status = get_display_hdr_capability()
    local params = mp.get_property_native("video-params")
    local target_params = mp.get_property_native("video-target-params")
    if not params_are_hdr(params) then
        return reject_manual_force("当前片源不是 PQ/HLG HDR，未执行强制输出")
    end

    if supported == false and not params_are_hdr(target_params) then
        return reject_manual_force("当前屏幕不支持 HDR；请使用播放器 HDR→SDR")
    end

    local display_confirmed = (supported == true and status == "on") or params_are_hdr(target_params)
    if not display_confirmed then
        msg.warn(string.format(
            "Manual HDR override enabled despite display detection (supported=%s, status=%s)",
            tostring(supported), tostring(status)
        ))
    end

    manual_force.saved = snapshot_manual_properties()
    manual_force.active = true
    publish_manual_force_state()
    mp.set_property_native("icc-profile", "")
    mp.set_property_native("icc-profile-auto", false)
    mp.set_property_native("target-prim", "bt.2020")
    mp.set_property_native("target-trc", "pq")
    mp.set_property_native("target-colorspace-hint", "yes")
    mp.set_property_native("target-colorspace-hint-mode", "target")
    mp.set_property_native("inverse-tone-mapping", false)
    manual_force.applied = snapshot_manual_properties()
    -- Peak is owned only after the user selects a manual peak in this mode.
    manual_force.applied['target-peak'] = nil
    if display_confirmed then
        mp.osd_message(i18n.t("强制 HDR 已开启（仅当前视频）"), 2)
    else
        mp.osd_message(i18n.t("强制 HDR 已开启（屏幕检测异常，请留意显示效果）"), 3)
    end
    msg.warn("Manual HDR override enabled for current PQ/HLG video")
    return true
end

local function refresh_peak_menu(requested)
    if requested ~= "refresh" then return end
    mp.add_timeout(0.05, function()
        mp.commandv("script-message", "codex-open-peak-menu")
    end)
end

local function set_manual_peak(value)
    if not manual_force.active then
        if not enable_manual_force() then return end
    end
    if value == "auto" then
        mp.set_property("target-peak", "auto")
        manual_force.applied['target-peak'] = mp.get_property_native('target-peak')
        mp.osd_message(i18n.t("HDR 峰值亮度：自动"), 2)
        return
    end
    local peak = tonumber(value)
    if not peak or peak ~= peak or peak < 10 or peak > 1000000 then
        mp.osd_message(i18n.t("无效的 HDR 峰值亮度"), 2)
        return
    end
    mp.set_property_number("target-peak", peak)
    manual_force.applied['target-peak'] = mp.get_property_native('target-peak')
    mp.osd_message(string.format(i18n.t("HDR 峰值亮度：%d nits"), math.floor(peak + 0.5)), 2)
end

local function normalized_hdr_status(value)
    local status = tostring(value or "")
    return (status == "on" or status == "off") and status or nil
end

local function remember_initial_hdr_status(status)
    if initial_hdr_status == nil and not hdr_switch_pending and status then
        initial_hdr_status = status
        msg.info("Initial display HDR state: " .. status)
    end
end

local function query_hdr_state()
    hdr_supported = select(1, get_display_hdr_capability())
    local status = normalized_hdr_status(
        mp.get_property_native("user-data/display-info/hdr-status")
    )
    remember_initial_hdr_status(status)
    hdr_active = status == "on"
    if status == "off" and not hdr_switch_pending then
        display_hdr_owned = false
    end
    return status
end

local function resolve_hdr_display_targets()
    local configured_peak = tonumber(o.target_peak) or 0
    local display_peak = tonumber((mp.get_property_native(
        "user-data/display-info/max-luminance")))
    if display_peak and not (display_peak >= 80 and display_peak <= 10000) then display_peak = nil end
    if not (configured_peak >= 0 and configured_peak <= 1000000) then configured_peak = 0 end
    resolved_target_peak = configured_peak
    if configured_peak <= 203 and hdr_supported == true
        and display_peak and display_peak > 203 then
        resolved_target_peak = math.floor(display_peak)
    end

    resolved_target_contrast = o.target_contrast
    local display_black = tonumber((mp.get_property_native(
        "user-data/display-info/min-luminance")))
    if tostring(o.target_contrast) == "auto" and resolved_target_peak > 203
        and display_black and display_black > 0 and display_black <= 5 then
        local reported_contrast = math.floor(resolved_target_peak / display_black)
        if reported_contrast >= 10 and reported_contrast <= 1000000 then
            resolved_target_contrast = reported_contrast
        end
    end


    -- For HDR -> SDR, use a reported LCD contrast only when display-info
    -- publishes a complete and plausible pair.  The contrast ratio is the
    -- physical display characteristic; target-peak remains the standard SDR
    -- 203 nits.  Missing, zero or implausible telemetry deliberately falls
    -- back to libplacebo's automatic model instead of inventing a black point.
    resolved_sdr_target_contrast = o.target_contrast == "auto"
        and state.target_contrast or o.target_contrast
    sdr_target_contrast_source = o.target_contrast == "auto"
        and "renderer-auto" or "configured"
    if tostring(o.target_contrast) == "auto" and display_peak
        and display_peak >= 80 and display_peak <= 1000
        and display_black and display_black > 0 and display_black <= 5 then
        local reported_contrast = math.floor(display_peak / display_black + 0.5)
        if reported_contrast >= 100 and reported_contrast <= 10000 then
            resolved_sdr_target_contrast = reported_contrast
            sdr_target_contrast_source = "reported-display"
        end
    end
    publish_if_changed("user-data/hdr-mode/resolved-target-peak",
        tostring(resolved_target_peak))
    publish_if_changed("user-data/hdr-mode/resolved-target-contrast",
        tostring(resolved_target_contrast))
    publish_if_changed("user-data/hdr-mode/resolved-sdr-target-contrast",
        tostring(resolved_sdr_target_contrast))
    publish_if_changed("user-data/hdr-mode/sdr-target-contrast-source",
        sdr_target_contrast_source)
end

local function disarm_shutdown_watchdog()
    if shutdown_watchdog_poll_timer then
        shutdown_watchdog_poll_timer:kill()
        shutdown_watchdog_poll_timer = nil
    end
    if shutdown_watchdog_token then
        os.remove(shutdown_watchdog_token)
        shutdown_watchdog_token = nil
    end
    if shutdown_watchdog_result then
        os.remove(shutdown_watchdog_result)
        shutdown_watchdog_result = nil
    end
    shutdown_restore_requested = false
end

local function poll_shutdown_watchdog_result()
    if not shutdown_watchdog_result then return end
    local result_file = io.open(shutdown_watchdog_result, "rb")
    if not result_file then return end
    local result = result_file:read("*a")
    result_file:close()
    if result == "" then return end

    if shutdown_watchdog_poll_timer then
        shutdown_watchdog_poll_timer:kill()
        shutdown_watchdog_poll_timer = nil
    end

    if result:find("^ok=1") then
        msg.info("HDR shutdown watchdog restored SDR: " .. result:gsub("%s+$", ""))
    else
        msg.error("HDR shutdown watchdog failed: " .. result:gsub("%s+$", ""))
        if hdr_active and o.hdr_mode == "switch" and o.output_mode ~= "sdr" then
            msg.warn("Falling back to display-info after HDR watchdog failure")
            mp.commandv("script-message", "toggle-hdr-display", "off")
        end
    end

    if shutdown_watchdog_token then
        os.remove(shutdown_watchdog_token)
        shutdown_watchdog_token = nil
    end
    os.remove(shutdown_watchdog_result)
    shutdown_watchdog_result = nil
    shutdown_restore_requested = false
end

local function request_shutdown_watchdog_restore()
    if not shutdown_watchdog_token then return false end

    local token_file = io.open(shutdown_watchdog_token, "wb")
    if not token_file then
        msg.warn("Could not signal the HDR shutdown watchdog to restore SDR")
        return false
    end
    token_file:write("restore")
    token_file:close()
    shutdown_restore_requested = true
    if shutdown_watchdog_poll_timer then
        shutdown_watchdog_poll_timer:kill()
    end
    shutdown_watchdog_poll_timer = mp.add_periodic_timer(0.1, poll_shutdown_watchdog_result)
    msg.verbose("Requested immediate SDR restoration from the HDR shutdown watchdog")
    return true
end

local function arm_shutdown_watchdog()
    if package.config:sub(1, 1) ~= "\\" then return false end

    local helper = mp.command_native({
        "expand-path",
        "~~/script-assets/hdr-mode/hdr-shutdown-restore.exe"
    })
    local helper_info = helper and utils.file_info(helper)
    local pid = mp.get_property_number("pid")
    local wid = mp.get_property_native("wid")
    if not helper_info or not helper_info.is_file or not pid or not wid then
        msg.warn("HDR shutdown watchdog is unavailable; falling back to the display plugin")
        return false
    end

    disarm_shutdown_watchdog()
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or mp.get_script_directory()
    local token = utils.join_path(temp_dir, string.format(
        "mpv-hdr-restore-%d-%d.token",
        pid,
        math.floor(mp.get_time() * 1000000)
    ))
    local result_path = token .. ".result"
    local token_file = io.open(token, "wb")
    if not token_file then
        msg.warn("Could not create HDR shutdown watchdog ownership token")
        return false
    end
    token_file:write("armed")
    token_file:close()

    local result = mp.command_native({
        name = "subprocess",
        playback_only = false,
        detach = true,
        args = {helper, tostring(math.floor(pid)), tostring(wid), token, result_path},
    })
    if type(result) == "table" and result.status and result.status < 0 then
        os.remove(token)
        msg.warn("Could not start HDR shutdown watchdog")
        return false
    end

    shutdown_watchdog_token = token
    shutdown_watchdog_result = result_path
    shutdown_restore_requested = false
    msg.verbose("Armed HDR shutdown watchdog")
    return true
end

local function switch_display_mode(enable)
    if enable == hdr_active then return false end
    if hdr_switch_pending then return false end
    hdr_switch_pending = true
    if enable then
        display_hdr_owned = true
        arm_shutdown_watchdog()
    end
    local arg = enable and "on" or "off"
    if not enable then
        -- The watchdog resolves the target while the mpv window is alive, so
        -- it remains usable after display-info has begun its teardown.
        if request_shutdown_watchdog_restore() then
            return true
        end
    end
    mp.commandv('script-message', 'toggle-hdr-display', arg)
    return true
end

local function apply_hdr_settings()
    set_output_if_changed("icc-profile", "")
    set_output_if_changed("icc-profile-auto", false)
    set_output_if_changed("target-prim", "bt.2020")
    set_output_if_changed("target-trc", "pq")
    set_output_if_changed("target-peak",
        resolved_target_peak > 203 and resolved_target_peak or "auto")
    set_output_if_changed("target-contrast", resolved_target_contrast)
    set_output_if_changed("target-colorspace-hint", "yes")
    set_output_if_changed("inverse-tone-mapping", "no")
end

local function apply_sdr_settings(content_is_hdr)
    if content_is_hdr == nil then
        content_is_hdr = params_are_hdr(mp.get_property_native("video-out-params"))
    end
    set_output_if_changed("icc-profile", state.icc_profile)
    set_output_if_changed("icc-profile-auto", state.icc_profile_auto)
    set_output_if_changed("target-peak", "203")
    set_output_if_changed("target-contrast", content_is_hdr
        and resolved_sdr_target_contrast or state.target_contrast)
    set_output_if_changed("target-colorspace-hint", "no")
    if o.output_mode == "sdr" then
        -- This is an mpv-only output policy. Explicit BT.709/gamma2.2 keeps
        -- HDR sources on the SDR tone-mapping path even when Windows HDR is
        -- currently enabled, without sending toggle-hdr-display.
        set_output_if_changed("target-prim", "bt.709")
        set_output_if_changed("target-trc", "gamma2.2")
        set_output_if_changed("inverse-tone-mapping", "no")
    else
        if state.target_prim ~= "bt.2020" then
            set_output_if_changed("target-prim", state.target_prim)
        else
            set_output_if_changed("target-prim", "auto")
        end
        if state.target_trc ~= "pq" then
            set_output_if_changed("target-trc", state.target_trc)
        else
            set_output_if_changed("target-trc", "auto")
        end
    end
    mp.add_timeout(0, publish_black_level_state)
end

local function reset_target_settings()
    mp.set_property_native("target-peak", state.target_peak)
    mp.set_property_native("target-prim", state.target_prim)
    mp.set_property_native("target-trc", state.target_trc)
    mp.set_property_native("target-contrast", state.target_contrast)
    mp.set_property_native("target-colorspace-hint", state.colorspace_hint)
    mp.set_property_native("inverse-tone-mapping", state.inverse_mapping)
end

local function set_pause_from_script(value)
    pause_write_expected = value
    mp.set_property_native("pause", value)
end

local function pause_if_needed()
    local paused = mp.get_property_native("pause")
    if not paused then
        set_pause_from_script(true)
        return true
    end
    return false
end

local function resume_if_needed(paused_by_script, user_pause_override)
    if not paused_by_script or user_pause_override then return end
    if mp.get_property_native("pause") then
        set_pause_from_script(false)
    end
end

local function on_pause_change(_, value)
    if value == nil then return end
    if pause_write_expected ~= nil then
        if value == pause_write_expected then
            pause_write_expected = nil
            return
        end
        pause_write_expected = nil
    end
    if switch_context and switch_context.paused_by_script then
        switch_context.user_pause_override = true
        msg.verbose("Pause changed externally during HDR switching; preserving the new pause state")
    end
end

local function cancel_pending_timers(resume_playback)
    if switch_timer then
        switch_timer:kill()
        switch_timer = nil
    end
    local context = switch_context
    switch_context = nil
    hdr_switch_pending = false
    if resume_playback and context then
        resume_if_needed(context.paused_by_script, context.user_pause_override)
    end
end

local function handle_hdr_logic(paused_before, target_peak, target_prim, target_trc)
    query_hdr_state()
    if hdr_active then
        apply_hdr_settings()
        resume_if_needed(paused_before)
    elseif (tonumber(target_peak) ~= 203 or target_prim == "bt.2020" or
        target_trc == "pq") then
        apply_sdr_settings()
        resume_if_needed(paused_before)
    end
end

local function handle_sdr_logic(paused_before, target_peak, target_prim, target_trc)
    query_hdr_state()
    if not hdr_active then
        local target_contrast = mp.get_property_native("target-contrast")
        if not state.inverse_mapping and (tonumber(target_peak) ~= 203 or
            target_prim == "bt.2020" or target_trc == "pq" or
            tostring(target_contrast) ~= tostring(state.target_contrast)) then
            apply_sdr_settings(false)
        elseif state.inverse_mapping then
            reset_target_settings()
        end
        resume_if_needed(paused_before)
    elseif o.hdr_mode == "pass" and state.inverse_mapping then
        reset_target_settings()
    end
end

local function switch_target_reached(context, status)
    return status == (context.expected_hdr and "on" or "off")
end

local function apply_switch_settings(context)
    query_hdr_state()
    if context.content_is_hdr then
        if hdr_active then
            apply_hdr_settings()
        else
            apply_sdr_settings()
        end
    elseif hdr_active then
        -- SDR content with the display still in HDR needs explicit SDR output
        -- settings, not HDR passthrough settings intended for HDR content.
        apply_sdr_settings()
    else
        handle_sdr_logic(false, context.target_peak, context.target_prim, context.target_trc)
    end
end

local function finish_display_switch(context, failure_reason, timed_out)
    if switch_context ~= context then return end
    if switch_timer then
        switch_timer:kill()
        switch_timer = nil
    end

    if context.generation ~= file_generation or mp.get_property("path") ~= context.path then
        switch_context = nil
        hdr_switch_pending = false
        resume_if_needed(context.paused_by_script, context.user_pause_override)
        return
    end

    local status = tostring(mp.get_property_native("user-data/display-info/hdr-status") or "unknown")
    if timed_out and context.expected_hdr and status == "off"
        and bool_value(mp.get_property_native("user-data/display-info/hdr-supported")) then
        local uid = get_display_uid()
        if uid and uid == context.display_uid then
            hdr_toggle_unavailable[uid] = true
            msg.warn("HDR switch timeout: actual status still off; display " .. uid
                .. " cannot auto-toggle HDR again in this session")
            msg.info("Fallback to SDR output for the current HDR content")
        else
            msg.warn("HDR switch timeout: display identity changed or is unavailable; "
                .. "not caching the failure")
        end
    elseif context.expected_hdr and status == "on" then
        msg.info("HDR switch confirmed: on")
    end
    if status == "off" then
        display_hdr_owned = false
        if not shutdown_restore_requested then
            disarm_shutdown_watchdog()
        end
    elseif status == "on" and context.expected_hdr then
        display_hdr_owned = true
    end
    if failure_reason and not switch_target_reached(context, status) then
        msg.warn(string.format(
            "HDR switch to %s ended by %s (actual status: %s); applying the actual display state",
            context.expected_hdr and "on" or "off", failure_reason, status
        ))
    end

    apply_switch_settings(context)
    local time = mp.get_property_number("time-pos")
    if time and time > 0 and not is_protocol(context.path) and mp.get_property_native("pause") then
        mp.commandv("frame-back-step")
    end

    switch_context = nil
    hdr_switch_pending = false
    resume_if_needed(context.paused_by_script, context.user_pause_override)
end

local function start_display_switch(enable, context)
    context.expected_hdr = enable
    context.paused_by_script = pause_if_needed()
    context.user_pause_override = false
    switch_context = context

    if not switch_display_mode(enable) then
        switch_context = nil
        hdr_switch_pending = false
        resume_if_needed(context.paused_by_script, false)
        return false
    end
    if switch_context ~= context then return true end

    local status = tostring(mp.get_property_native("user-data/display-info/hdr-status") or "")
    if switch_target_reached(context, status) then
        finish_display_switch(context)
    elseif status == "unsupported" then
        finish_display_switch(context, "unsupported status")
    else
        local wait_seconds = math.max(1, tonumber(o.hdr_wait) or 8)
        switch_timer = mp.add_timeout(wait_seconds, function()
            switch_timer = nil
            finish_display_switch(context, string.format("%.1f second timeout", wait_seconds), true)
        end)
    end
    return true
end

local function should_switch_hdr(hdr_active, is_fullscreen)
    if hdr_switch_pending then return false end
    if o.output_mode == "sdr" then return false end
    if o.hdr_mode ~= "switch" then return false end
    if not hdr_active and (not o.fullscreen_only or is_fullscreen) then
        local uid = get_display_uid()
        if uid and hdr_toggle_unavailable[uid] then
            if not hdr_toggle_skip_logged[uid] then
                msg.info("Skipping repeated HDR auto-toggle for display " .. uid)
                hdr_toggle_skip_logged[uid] = true
            end
            return false
        end
        return true
    elseif hdr_active and o.fullscreen_only and not is_fullscreen then
        return true
    end
    return false
end

local function switch_hdr()
    if manual_force.active or manual_force.restoring then return end
    if hdr_check_disabled then return end
    local hdr_status = query_hdr_state()
    if hdr_switch_pending then return end
    local path = mp.get_property("path")
    local params = mp.get_property_native("video-out-params")
    local gamma = params and params["gamma"]
    local is_hdr = params_are_hdr(params)
    if not path or not gamma then return end
    local hdr_status_raw = tostring(
        mp.get_property_native("user-data/display-info/hdr-status") or ""
    )
    if o.output_mode ~= "sdr" and o.hdr_mode == "switch"
        and (hdr_supported == false or hdr_status_raw == "unsupported") then
        if not hdr_unsupported_warned then
            msg.warn("HDR display switching is unsupported by display-info; using safe HDR-to-SDR output")
            hdr_unsupported_warned = true
        end
        -- An SDR-only display cannot switch Windows HDR on, but gpu-next can
        -- still tone-map HDR correctly.  Keep the manager alive so the
        -- measured black point can be applied only to HDR -> SDR content.
        resolve_hdr_display_targets()
        if is_hdr then
            apply_sdr_settings(true)
        else
            handle_sdr_logic(false,
                mp.get_property_native("target-peak"),
                mp.get_property_native("target-prim"),
                mp.get_property_native("target-trc"))
        end
        return
    end
    if o.output_mode ~= "sdr" and o.hdr_mode == "switch" and not hdr_status then
        msg.verbose("Waiting for display-info to publish a definite HDR state")
        return
    end
    resolve_hdr_display_targets()

    local current_state = is_hdr and "hdr" or "sdr"
    local fullscreen = mp.get_property_native("fullscreen")
    local maximized = mp.get_property_native("window-maximized")
    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    local is_fullscreen = fullscreen or maximized
    local generation = file_generation
    local preserve_preexisting_hdr = initial_hdr_status == "on"
        and hdr_active and not display_hdr_owned

    local function new_switch_context()
        return {
            generation = generation,
            path = path,
            content_is_hdr = is_hdr,
            display_uid = get_display_uid(),
            target_peak = target_peak,
            target_prim = target_prim,
            target_trc = target_trc,
        }
    end

    if o.output_mode == "sdr" then
        -- Never alter the Windows HDR switch from the player SDR choice.
        -- Windows may be on or off; gpu-next still receives an explicit SDR
        -- target and tone-maps PQ/HLG content inside this process.
        apply_sdr_settings(is_hdr)
        return
    end

    if current_state == "hdr" then
        if first_switch_check and o.fullscreen_only and not is_fullscreen then
            first_switch_check = false
        elseif resolved_target_peak > 203 and should_switch_hdr(hdr_active, is_fullscreen) then
            if hdr_active and o.fullscreen_only and not is_fullscreen then
                msg.info("Switching to SDR output...")
                start_display_switch(false, new_switch_context())
            else
                msg.info("Switching to HDR output...")
                start_display_switch(true, new_switch_context())
            end
            return
        end

        handle_hdr_logic(false, target_peak, target_prim, target_trc)
    elseif current_state == "sdr" then
        if preserve_preexisting_hdr then
            -- The customer enabled Windows HDR before mpv started. Keep that
            -- system state stable, but keep SDR output parameters explicit so
            -- auto-profiles and this script cannot race back to HDR hints.
            apply_sdr_settings()
            return
        elseif hdr_active and o.hdr_mode == "switch" and (not o.fullscreen_only or is_fullscreen) then
            msg.info("Switching back to SDR output...")
            start_display_switch(false, new_switch_context())
            return
        end

        handle_sdr_logic(false, target_peak, target_prim, target_trc)
    end
end

local function on_hdr_status_change(_, value)
    local raw_status = tostring(value or "")
    local status = normalized_hdr_status(value)
    local previous_status = last_observed_hdr_status
    if status then
        last_observed_hdr_status = status
    end

    local context = switch_context
    if context then
        if switch_target_reached(context, status) then
            finish_display_switch(context)
        elseif raw_status == "unsupported" then
            hdr_unsupported_warned = true
            finish_display_switch(context, "unsupported status")
        end
        return
    end

    local changed_externally = status
        and previous_status
        and status ~= previous_status
        and not hdr_switch_pending
        and file_loaded
        and mp.get_property("path") ~= nil
    if changed_externally then
        if o.output_mode == "sdr" then
            hdr_active = status == "on"
            display_hdr_owned = false
            disarm_shutdown_watchdog()
            hdr_check_disabled = false
            apply_sdr_settings(params_are_hdr(
                mp.get_property_native("video-out-params")))
            return
        end
        hdr_active = status == "on"
        display_hdr_owned = false
        disarm_shutdown_watchdog()
        hdr_check_disabled = true
        msg.info(string.format(
            "Display HDR changed externally from %s to %s; respecting the user override until the next file",
            previous_status,
            status
        ))

        local params = mp.get_property_native("video-out-params")
        if params_are_hdr(params) then
            if hdr_active then
                apply_hdr_settings()
            else
                apply_sdr_settings()
            end
        else
            apply_sdr_settings()
        end
        return
    end

    if status == "off" then
        hdr_active = false
        display_hdr_owned = false
        if not shutdown_restore_requested then
            disarm_shutdown_watchdog()
        end
        -- Shutdown/idle restoration uses switch_display_mode() directly and
        -- therefore has no per-file switch context to finish.
        if hdr_switch_pending then hdr_switch_pending = false end
    end
    switch_hdr()
end

local function check_paramet()
    if manual_force.active or manual_force.restoring then return end
    if hdr_check_disabled then return end
    if hdr_switch_pending then return end
    query_hdr_state()
    resolve_hdr_display_targets()
    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    local target_contrast = mp.get_property_native("target-contrast")
    local colorspace_hint = mp.get_property_native("target-colorspace-hint")
    local inverse_mapping = mp.get_property_native("inverse-tone-mapping")
    local params = mp.get_property_native("video-out-params")
    local gamma = params and params["gamma"]
    local is_hdr = params_are_hdr(params)
    if not gamma then return end

    if o.output_mode == "sdr" then
        local expected_contrast = is_hdr
            and resolved_sdr_target_contrast or state.target_contrast
        if tonumber(target_peak) ~= 203 or target_prim ~= "bt.709"
            or target_trc ~= "gamma2.2" or colorspace_hint ~= "no"
            or inverse_mapping
            or tostring(target_contrast) ~= tostring(expected_contrast) then
            apply_sdr_settings(is_hdr)
        end
        return
    end

    if is_hdr and hdr_active and o.hdr_mode ~= "noth" and resolved_target_peak > 203 then
        if tonumber(target_peak) ~= resolved_target_peak then
            mp.set_property_native("target-peak", resolved_target_peak)
        end
        if tostring(target_contrast) ~= tostring(resolved_target_contrast) then
            mp.set_property_native("target-contrast", resolved_target_contrast)
        end
        if target_prim ~= "bt.2020" then
            mp.set_property_native("target-prim", "bt.2020")
        end
        if target_trc ~= "pq" then
            mp.set_property_native("target-trc", "pq")
        end
        if colorspace_hint ~= "yes" then
            mp.set_property_native("target-colorspace-hint", "yes")
        end
        if inverse_mapping then
            mp.set_property_native("inverse-tone-mapping", "no")
        end
    end
end

local function on_display_capability_change()
    if display_refresh_timer then display_refresh_timer:kill() end
    local generation = file_generation
    display_refresh_timer = mp.add_timeout(0.05, function()
        display_refresh_timer = nil
        if generation ~= file_generation or not file_loaded then return end
        query_hdr_state()
        resolve_hdr_display_targets()
        if manual_force.active and hdr_supported == false then
            disable_manual_force(false)
            apply_sdr_settings(params_are_hdr(mp.get_property_native('video-out-params')))
            mp.osd_message(i18n.t('当前输出不支持 HDR，已恢复 SDR 映射'), 3)
        else
            switch_hdr()
        end
    end)
end

local function on_start()
    cancel_pending_timers(true)
    file_generation = file_generation + 1
    file_loaded = false
    disable_manual_force(false)
    hdr_unsupported_warned = false
    hdr_check_disabled = false
    if o.hdr_mode == "noth" and o.output_mode ~= "sdr" then
        return
    end
    local vo = mp.get_property("vo")
    if vo and vo ~= "gpu-next" then
        msg.warn("The current video output is not supported, please use gpu-next")
        return
    end
    file_loaded = true
    last_observed_hdr_status = query_hdr_state()
    mp.observe_property("video-out-params", "native", switch_hdr)
    mp.observe_property("target-peak", "native", check_paramet)
    mp.observe_property("target-prim", "native", check_paramet)
    mp.observe_property("target-trc", "native", check_paramet)
    mp.observe_property("target-contrast", "native", check_paramet)
    mp.observe_property("target-colorspace-hint", "native", check_paramet)
    mp.observe_property("user-data/display-info/hdr-status", "native", on_hdr_status_change)
    for _, name in ipairs({'uid', 'hdr-supported', 'max-luminance', 'min-luminance'}) do
        mp.observe_property('user-data/display-info/' .. name, 'native', on_display_capability_change)
    end
    if o.fullscreen_only then
        mp.observe_property("fullscreen", "native", switch_hdr)
        mp.observe_property("window-maximized", "native", switch_hdr)
    end
end

local function on_end(event)
    cancel_pending_timers(true)
    file_generation = file_generation + 1
    disable_manual_force(false)
    query_hdr_state()
    first_switch_check = true
    mp.unobserve_property(switch_hdr)
    mp.unobserve_property(on_hdr_status_change)
    mp.unobserve_property(check_paramet)
    mp.unobserve_property(on_display_capability_change)
    if display_refresh_timer then display_refresh_timer:kill(); display_refresh_timer = nil end
    if event["reason"] == "quit" and o.hdr_mode == "switch"
        and o.output_mode ~= "sdr" then
        if hdr_active and display_hdr_owned then
            msg.info("Restoring display to SDR on shutdown")
            switch_display_mode(false)
        end
    end
end

local function on_idle(_, active)
    if active and file_loaded and o.hdr_mode == "switch"
        and o.output_mode ~= "sdr" then
        file_loaded = false
        query_hdr_state()
        if hdr_active and display_hdr_owned then
            msg.info("Restoring display to SDR on shutdown")
            switch_display_mode(false)
        end
    end
end

mp.register_event("start-file", on_start)
mp.register_event("end-file", on_end)
mp.observe_property("idle-active", "native", on_idle)
mp.observe_property("pause", "native", on_pause_change)
mp.register_script_message("manual-force-toggle", function(refresh)
    if manual_force.active then
        disable_manual_force(true)
    else
        enable_manual_force()
    end
    refresh_peak_menu(refresh)
end)
mp.register_script_message("manual-force-peak", function(value, refresh)
    set_manual_peak(value)
    refresh_peak_menu(refresh)
end)
mp.register_script_message("set-output-mode", function(value, refresh)
    value = tostring(value or ""):lower()
    if value == "toggle" then
        value = o.output_mode == "sdr" and "auto" or "sdr"
    end
    if value ~= "auto" and value ~= "sdr" then return end

    cancel_pending_timers(true)
    disable_manual_force(false)
    o.output_mode = value
    persist_option("output_mode", value)
    publish_output_mode()
    hdr_check_disabled = false
    if value == "auto" then
        reset_target_settings()
    else
        -- Once player SDR is selected, do not retain ownership that could
        -- cause a later idle/quit path to write the Windows HDR switch.
        display_hdr_owned = false
        disarm_shutdown_watchdog()
    end
    if file_loaded then
        mp.add_timeout(0.05, switch_hdr)
    end
    mp.osd_message(value == "sdr"
        and i18n.t("播放器 HDR→SDR 已开启（未修改 Windows HDR）")
        or i18n.t("播放器输出：已恢复自动 HDR/SDR"), 3)
    refresh_peak_menu(refresh)
end)
mp.register_script_message("set-output-range", function(value, refresh)
    value = tostring(value or ""):lower()
    if value ~= "auto" and value ~= "full" and value ~= "limited" then return end
    o.output_range = value
    persist_option("output_range", value)
    apply_output_range()
    mp.osd_message(i18n.t("视频输出范围：") .. output_range_labels[value], 3)
    refresh_black_level_menu(refresh)
end)
mp.register_script_message("show-black-level-diagnostics", function()
    publish_black_level_state()
    local source_params = mp.get_property_native("video-params", {})
    local target_params = mp.get_property_native("video-target-params", {})
    if type(source_params) ~= "table" then source_params = {} end
    if type(target_params) ~= "table" then target_params = {} end
    local source_range = type(source_params) == "table"
        and source_params.colorlevels or "unknown"
    local target_range = type(target_params) == "table"
        and target_params.colorlevels or "unknown"
    local lines = {
        "黑位与输出链诊断",
        "范围：源 " .. range_label(source_range) .. " → 目标 " .. range_label(target_range)
            .. "（请求 " .. output_range_labels[o.output_range] .. "）",
        "色彩：" .. tostring(source_params.primaries or "unknown")
            .. " / " .. tostring(source_params.gamma or "unknown")
            .. " / " .. tostring(source_params.colormatrix or "unknown"),
        "输出：" .. mp.get_property("current-vo", mp.get_property("vo", "unknown"))
            .. " / " .. mp.get_property("current-gpu-context", "unknown")
            .. " / Windows HDR=" .. tostring(mp.get_property_native(
                "user-data/display-info/hdr-status") or "unknown"),
        "目标：" .. tostring(target_params.primaries or "unknown")
            .. " / " .. tostring(target_params.gamma or "unknown")
            .. " / peak=" .. mp.get_property("target-peak", "auto")
            .. " / contrast=" .. mp.get_property("target-contrast", "auto"),
        "HDR→SDR：" .. (mp.get_property_native("user-data/black-level/hdr-to-sdr", "no") == "yes"
            and ("已启用 · 黑点=" .. mp.get_property_native(
                "user-data/black-level/black-point-policy", "renderer-auto"))
            or "未启用（原生 SDR/HDR 输出不调整）"),
        "最终量化：" .. mp.get_property_native(
            "user-data/black-level/quantization", "等待输出目标"),
        string.format("手动画面校正：亮度 %.2f / 对比度 %.2f / Gamma %.2f",
            mp.get_property_number("brightness", 0) or 0,
            mp.get_property_number("contrast", 0) or 0,
            mp.get_property_number("gamma", 0) or 0),
        "决策：" .. mp.get_property_native("user-data/black-level/reason-code", "detecting"),
        "基准：10-bit HDR Limited 应为 64 纯黑，66 开始可见闪烁",
    }
    local text = table.concat(lines, "\n")
    mp.osd_message(text, 10)
    msg.info(text:gsub("\n", " | "))
end)
for _, property in ipairs({
    "video-params/colorlevels", "video-params/gamma", "video-params/primaries",
    "video-target-params/colorlevels", "video-target-params/gamma",
    "video-target-params/pixelformat", "dither-depth",
    "current-vo", "current-gpu-context", "brightness", "contrast", "gamma",
    "user-data/display-info/hdr-status",
}) do
    mp.observe_property(property, "native", publish_black_level_state)
end
mp.register_event("file-loaded", function()
    mp.add_timeout(0.1, publish_black_level_state)
    mp.add_timeout(0.6, publish_black_level_state)
end)
mp.register_event("video-reconfig", function()
    mp.add_timeout(0.05, publish_black_level_state)
end)
apply_output_range()
publish_manual_force_state()
publish_output_mode()
