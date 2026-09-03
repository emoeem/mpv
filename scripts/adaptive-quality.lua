-- Windows/D3D11 adaptive quality selector for a portable mpv package.
-- Keeps the existing HQ baseline on known medium/high and unknown GPUs,
-- reduces optional work on low-power GPUs, and only enables general-purpose
-- shaders when the detected GPU and source frame rate have enough headroom.

local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    enabled = true,
    tier = 'auto',                 -- auto|low|balanced|medium|high
    unknown_tier = 'balanced',
    superres_mode = 'off',         -- off|auto|performance|quality
    smooth_mode = 'off',           -- off|auto|performance|quality
    protect_4k_smooth = true,
    unprotected_4k_extra_frames = 16,
    auto_select_adapter = true,
    auto_shaders = true,
    auto_chroma = true,
    performance_guard = true,
    rife_clock_guard = true,
    rife_clock_guard_interval = 0.20,
    rife_clock_guard_start_delay = 3.0,
    rife_clock_guard_hard_hz = 1000,
    rife_clock_guard_hard_ratio = 8.0,
    rife_clock_guard_audio_change = 0.04,
    rife_clock_guard_avsync = 0.30,
    rife_clock_guard_bad_samples = 3,
    guard_auto_recover = false,
    smart_deband = true,
    show_osd = false,
    medium_fsrcnnx_max_fps = 30.5,
    medium_downscale_max_fps = 30.5,
    high_fsrcnnx_max_fps = 60.5,
    high_downscale_max_fps = 60.5,
    shader_max_fps = 60.5,
    medium_chroma_max_pixel_rate = 130000000,
    high_chroma_max_pixel_rate = 260000000,
    medium_rife_fsrcnnx_max_pixel_rate = 130000000,
    high_rife_fsrcnnx_max_pixel_rate = 150000000,
    upper_high_rife_fsrcnnx_max_pixel_rate = 300000000,
    medium_rife_display_max_pixel_rate = 260000000,
    high_rife_display_max_pixel_rate = 520000000,
    upper_high_rife_1440p_display_max_pixel_rate = 900000000,
    deband_max_bpppf = 0.060,
    guard_interval = 2.0,
    guard_start_delay = 8.0,
    guard_change_cooldown = 8.0,
    guard_high_ratio = 0.78,
    guard_low_ratio = 0.50,
    guard_bad_samples = 2,
    guard_good_samples = 15,
    guard_drop_delta = 2,
}
options.read_options(o, 'adaptive_quality')

local valid_enhancement_modes = {off = true, auto = true, performance = true, quality = true}
local function normalize_enhancement_mode(value)
    value = tostring(value or ''):lower()
    return valid_enhancement_modes[value] and value or 'auto'
end
o.superres_mode = normalize_enhancement_mode(o.superres_mode)
o.smooth_mode = normalize_enhancement_mode(o.smooth_mode)
o.unprotected_4k_extra_frames = math.max(0,
    math.min(64, math.floor(tonumber(o.unprotected_4k_extra_frames) or 16)))

local config_path = mp.command_native({'expand-path', '~~/script-opts/adaptive_quality.conf'})
mp.set_property_native('user-data/adaptive-quality/adapter-ready', 'no')
mp.set_property_native('user-data/video-enhancement/rife-spatial-compatible', 'waiting')
mp.set_property_native('user-data/video-enhancement/rife-spatial-detail',
    '等待原生空间画质基线')

local shader_spec_order = {
    'chroma', 'fsrcnnx_restore', 'fsrcnnx_upscale', 'superres', 'downscale',
}
local shader_specs = {
    chroma = {
        path = mp.command_native({'expand-path', '~~/shaders/igv/KrigBilateral.glsl'}),
        role = 'chroma', role_label = '色度重建', expected_hook = 'CHROMA',
    },
    superres = {
        path = mp.command_native({'expand-path', '~~/shaders/igv/SSimSuperRes.glsl'}),
        role = 'spatial-upscale', role_label = '轻量超分', expected_hook = 'POSTKERNEL',
    },
    downscale = {
        path = mp.command_native({'expand-path', '~~/shaders/igv/SSimDownscaler.glsl'}),
        role = 'spatial-downscale', role_label = '高质量缩小', expected_hook = 'POSTKERNEL',
    },
    fsrcnnx_restore = {
        path = mp.command_native({'expand-path', '~~/shaders/igv/FSRCNNX_x1_16-0-4-1_distort.glsl'}),
        role = 'spatial-restore', role_label = '细节修复', expected_hook = 'LUMA',
    },
    fsrcnnx_upscale = {
        path = mp.command_native({'expand-path', '~~/shaders/igv/FSRCNNX_x2_8-0-4-1.glsl'}),
        role = 'spatial-upscale', role_label = '高质量超分', expected_hook = 'LUMA',
    },
}
local shader_paths = {}
for name, spec in pairs(shader_specs) do shader_paths[name] = spec.path end
local shader_metadata = {}

local selected_gpu = nil
local selected_tier = 'balanced'
local last_auto_shader_key = nil
local apply_serial = 0
local runtime_variants = {{}}
local active_variant = 1
local guard_managed = false
local guard_ready_at = 0
local guard_bad_samples = 0
local guard_good_samples = 0
local guard_last_drops = 0
local guard_timer = nil
local shader_guard_managed = false
local smooth_guard_managed = false
local smooth_baseline = {
    video_sync = mp.get_property('video-sync', 'audio'),
    interpolation = mp.get_property_bool('interpolation', false),
    interpolation_threshold = mp.get_property_number('interpolation-threshold', 0.01) or 0.01,
    tscale = mp.get_property('tscale', 'oversample'),
    tscale_blur = mp.get_property_number('tscale-blur', 0) or 0,
}
local smooth_runtime_variants = {{enabled = false, algorithm = 'off'}}
local smooth_active_variant = 1
local smooth_effective = false
local smooth_result_kind = 'source'
local last_metrics = nil
local schedule_apply
local rife_clock_timer = nil
local rife_clock_active = false
local rife_clock_fallback = false
local rife_clock_ready_at = 0
local rife_clock_bad_samples = 0
local rife_clock_reference_fps = 0
local rife_display_alignment_active = false
local hwdec_extra_frames_baseline = mp.get_property('hwdec-extra-frames', 'auto')
local hwdec_extra_frames_adjusted = false

local function configure_4k_hwdec_pool(required)
    if required then
        local desired = o.unprotected_4k_extra_frames
        if desired <= 0 then return false end
        local current = tonumber(mp.get_property('hwdec-extra-frames', 'auto'))
        if current and current >= desired then return false end
        mp.set_property('hwdec-extra-frames', tostring(desired))
        hwdec_extra_frames_adjusted = true
        mp.set_property_native('user-data/video-enhancement/hwdec-extra-frames', desired)
        msg.info(string.format('4K smooth playback reserved %d extra hardware decode frames', desired))
        return true
    end
    if not hwdec_extra_frames_adjusted then return false end
    mp.set_property('hwdec-extra-frames', hwdec_extra_frames_baseline)
    hwdec_extra_frames_adjusted = false
    mp.set_property_native('user-data/video-enhancement/hwdec-extra-frames',
        hwdec_extra_frames_baseline)
    return true
end

local function trim(s)
    return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function set_native_if_changed(name, value)
    if mp.get_property_native(name) == value then return false end
    mp.set_property_native(name, value)
    return true
end

local function publish_rife_spatial_compatibility(compatible, detail)
    local value = compatible == true and 'yes'
        or compatible == false and 'no'
        or 'waiting'
    set_native_if_changed('user-data/video-enhancement/rife-spatial-compatible', value)
    set_native_if_changed('user-data/video-enhancement/rife-spatial-detail',
        detail or (value == 'yes' and 'RIFE 不降低当前空间画质基线'
            or value == 'no' and 'RIFE 会降低当前空间画质基线'
            or '等待原生空间画质基线'))
end

local function set_string_if_changed(name, value)
    value = tostring(value)
    if mp.get_property(name, '') == value then return false end
    mp.set_property(name, value)
    return true
end

local function set_bool_if_changed(name, value)
    value = value == true
    if mp.get_property_bool(name, false) == value then return false end
    mp.set_property_bool(name, value)
    return true
end

local function set_number_if_changed(name, value)
    value = tonumber(value) or 0
    local current = mp.get_property_number(name, value)
    if current and math.abs(current - value) < 0.000001 then return false end
    mp.set_property_number(name, value)
    return true
end

local enhancement_mode_labels = {
    off = '关闭',
    auto = '自动',
    performance = '性能优先',
    quality = '质量优先',
}

local function format_fps(value)
    value = tonumber(value) or 0
    if value <= 0 then return '未知' end
    local rounded = math.floor(value + 0.5)
    if math.abs(value - rounded) < 0.01 then return tostring(rounded) end
    return string.format('%.3f', value):gsub('0+$', ''):gsub('%.$', '')
end

local function persist_mode_option(name, value)
    local file = config_path and io.open(config_path, 'rb') or nil
    if not file then
        msg.error('无法读取自适应画质配置：' .. tostring(config_path))
        return false
    end
    local data = file:read('*a') or ''
    file:close()

    local replacement = name .. '=' .. value
    local pattern = '([\r\n]?)' .. name .. '%s*=[^\r\n]*'
    local replaced = false
    data = data:gsub(pattern, function(prefix)
        if replaced then return prefix .. replacement end
        replaced = true
        return prefix .. replacement
    end)
    if not replaced then
        if data ~= '' and not data:match('[\r\n]$') then data = data .. '\n' end
        data = data .. replacement .. '\n'
    end

    file = io.open(config_path, 'wb')
    if not file then
        msg.error('无法保存自适应画质配置：' .. tostring(config_path))
        return false
    end
    file:write(data)
    file:close()
    return true
end

local function publish_requested_modes()
    mp.set_property_native('user-data/video-enhancement/superres-mode', o.superres_mode)
    mp.set_property_native('user-data/video-enhancement/superres-mode-label',
        enhancement_mode_labels[o.superres_mode])
    mp.set_property_native('user-data/video-enhancement/smooth-mode', o.smooth_mode)
    mp.set_property_native('user-data/video-enhancement/smooth-mode-label',
        enhancement_mode_labels[o.smooth_mode])
    mp.set_property_native('user-data/video-enhancement/protect-4k',
        o.protect_4k_smooth and 'yes' or 'no')
end

local function publish_superres_state(shaders, manual, reason)
    shaders = shaders or {}
    local active_roles, active_stages = {}, {}
    local seen_roles, seen_stages = {}, {}
    for _, path in ipairs(shaders) do
        local metadata = shader_metadata[path]
        local role = metadata and metadata.role_label or '外部 Shader'
        local stages = metadata and metadata.hooks or '未知阶段'
        if not seen_roles[role] then
            seen_roles[role] = true
            active_roles[#active_roles + 1] = role
        end
        if not seen_stages[stages] then
            seen_stages[stages] = true
            active_stages[#active_stages + 1] = stages
        end
    end
    set_native_if_changed('user-data/video-enhancement/shader-ownership',
        manual and 'user' or #shaders > 0 and 'system' or 'none')
    set_native_if_changed('user-data/video-enhancement/shader-active-roles',
        #active_roles > 0 and table.concat(active_roles, ' / ') or '无')
    set_native_if_changed('user-data/video-enhancement/shader-active-stages',
        #active_stages > 0 and table.concat(active_stages, ' / ') or '无')
    if mp.get_property_native(
        'user-data/video-enhancement/hq-superres-active') == 'yes' then
        local effective = 'AnimeJaNai TensorRT AI x2'
        local detail = mp.get_property_native(
            'user-data/video-enhancement/hq-superres-detail') or effective
        mp.set_property_native('user-data/video-enhancement/superres-effective', effective)
        mp.set_property_native('user-data/video-enhancement/superres-detail', detail)
        mp.set_property_native('user-data/video-enhancement/superres-active', 'yes')
        set_native_if_changed('user-data/video-enhancement/spatial-requested', o.superres_mode)
        set_native_if_changed('user-data/video-enhancement/spatial-effective-backend',
            'animejanai-tensorrt')
        set_native_if_changed('user-data/video-enhancement/spatial-reason-code', 'active-ai-superres')
        set_native_if_changed('user-data/video-enhancement/spatial-reason-detail', detail)
        return
    end
    local effective = '关闭'
    local active = false
    for _, path in ipairs(shaders) do
        if path == shader_paths.fsrcnnx_upscale then
            effective = 'FSRCNNX 高质量'
            active = true
            break
        elseif path == shader_paths.fsrcnnx_restore then
            effective = 'FSRCNNX 修复'
            active = true
        elseif path == shader_paths.superres and not active then
            effective = 'SSim 轻量'
            active = true
        end
    end

    if manual then
        effective = '手动着色器'
    elseif not active and o.superres_mode ~= 'off' then
        effective = reason or '当前无需放大'
    end

    local detail = effective
    if last_metrics and last_metrics.w > 0 and last_metrics.h > 0 then
        if active and last_metrics.display_w > 0 and last_metrics.display_h > 0 then
            detail = string.format('%d×%d → %d×%d · %s',
                last_metrics.w, last_metrics.h,
                last_metrics.display_w, last_metrics.display_h, effective)
        else
            detail = string.format('%d×%d · %s',
                last_metrics.w, last_metrics.h, effective)
        end
    end
    if active and reason then detail = detail .. ' · ' .. reason end
    mp.set_property_native('user-data/video-enhancement/superres-effective', effective)
    mp.set_property_native('user-data/video-enhancement/superres-detail', detail)
    mp.set_property_native('user-data/video-enhancement/superres-active', active and 'yes' or 'no')
    local backend = manual and 'user-shader'
        or effective:find('FSRCNNX', 1, true) and 'fsrcnnx'
        or effective:find('SSim', 1, true) and 'ssim'
        or 'none'
    local reason_code = manual and 'manual-owner'
        or active and reason and reason:find('补帧协同', 1, true)
            and 'active-coordinated-light'
        or active and 'active-managed-shader'
        or o.superres_mode == 'off' and 'user-disabled'
        or effective == '当前无需放大' and 'not-needed'
        or 'policy-fallback'
    set_native_if_changed('user-data/video-enhancement/spatial-requested', o.superres_mode)
    set_native_if_changed('user-data/video-enhancement/spatial-effective-backend', backend)
    set_native_if_changed('user-data/video-enhancement/spatial-reason-code', reason_code)
    set_native_if_changed('user-data/video-enhancement/spatial-reason-detail', detail)
end

local function publish_smooth_state(effective, detail, active, result_kind)
    smooth_effective = active == true
    smooth_result_kind = result_kind or (smooth_effective and 'native-display' or 'source')
    set_native_if_changed('user-data/video-enhancement/smooth-effective', effective or '关闭')
    set_native_if_changed('user-data/video-enhancement/smooth-detail', detail or effective or '关闭')
    set_native_if_changed('user-data/video-enhancement/smooth-active', smooth_effective and 'yes' or 'no')
    set_native_if_changed('user-data/video-enhancement/smooth-result-kind', smooth_result_kind)
    set_native_if_changed('user-data/video-enhancement/smooth-guard-level', smooth_active_variant - 1)
    local detail_text = tostring(detail or effective or '')
    local temporal_backend = smooth_result_kind == 'ai-fps' and 'rife'
        or smooth_effective and 'mpv-interpolation'
        or 'none'
    local reason_code = smooth_result_kind == 'ai-fps' and 'active-rife'
        or smooth_effective and 'active-display-resample'
        or o.smooth_mode == 'off' and 'user-disabled'
        or detail_text:find('音频直通保护', 1, true) and 'passthrough-guard'
        or detail_text:find('4K', 1, true) and 'uhd-guard'
        or detail_text:find('倍速', 1, true) and 'speed-guard'
        or detail_text:find('等待', 1, true) and 'detecting'
        or detail_text:find('帧率', 1, true) and 'cadence-not-needed'
        or detail_text:find('性能', 1, true) and 'runtime-budget'
        or 'policy-fallback'
    set_native_if_changed('user-data/video-enhancement/temporal-requested', o.smooth_mode)
    set_native_if_changed('user-data/video-enhancement/temporal-effective-backend',
        temporal_backend)
    set_native_if_changed('user-data/video-enhancement/temporal-reason-code', reason_code)
    set_native_if_changed('user-data/video-enhancement/temporal-reason-detail', detail_text)
end

local function file_exists(path)
    if type(path) ~= 'string' or path == '' then return false end
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

local function parse_shader_metadata(spec)
    local file = io.open(spec.path, 'rb')
    if not file then
        return {state = 'missing', role = spec.role, role_label = spec.role_label,
            hooks = '', directives = 0}
    end
    local values = {HOOK = {}, BIND = {}, WHEN = {}, WIDTH = {}, HEIGHT = {}, SAVE = {}}
    local seen = {HOOK = {}, BIND = {}, WHEN = {}, WIDTH = {}, HEIGHT = {}, SAVE = {}}
    local directives = 0
    for line in file:lines() do
        local key, value = line:match('^//!([A-Z]+)%s+(.+)%s*$')
        if key and values[key] then
            directives = directives + 1
            value = trim(value)
            if value ~= '' and not seen[key][value] then
                seen[key][value] = true
                values[key][#values[key] + 1] = value
            end
        end
    end
    file:close()
    local hooks = table.concat(values.HOOK, '+')
    local expected = spec.expected_hook
    local valid_hook = expected == nil or seen.HOOK[expected] == true
    return {
        state = #values.HOOK > 0 and valid_hook and 'ready' or 'invalid-stage',
        role = spec.role,
        role_label = spec.role_label,
        hooks = hooks,
        directives = directives,
        bind_count = #values.BIND,
        when_count = #values.WHEN,
        size_rule_count = #values.WIDTH + #values.HEIGHT,
        save_count = #values.SAVE,
    }
end

local function publish_shader_capabilities()
    local registry, missing, invalid = {}, 0, 0
    shader_metadata = {}
    for _, name in ipairs(shader_spec_order) do
        local spec = shader_specs[name]
        local metadata = parse_shader_metadata(spec)
        shader_metadata[spec.path] = metadata
        if metadata.state == 'missing' then missing = missing + 1 end
        if metadata.state == 'invalid-stage' then invalid = invalid + 1 end
        registry[#registry + 1] = string.format(
            '%s=%s|role:%s|hook:%s|directives:%d',
            name, metadata.state, metadata.role,
            metadata.hooks ~= '' and metadata.hooks or 'none', metadata.directives)
    end
    local state = missing > 0 and 'missing'
        or invalid > 0 and 'invalid-stage'
        or 'ready'
    local detail = state == 'ready'
        and string.format('%d 个受管 Shader 已按 HOOK/BIND/WHEN/尺寸规则建档', #shader_spec_order)
        or string.format('Shader 能力异常：缺失 %d，阶段不匹配 %d', missing, invalid)
    set_native_if_changed('user-data/video-enhancement/shader-capability-state', state)
    set_native_if_changed('user-data/video-enhancement/shader-capability-detail', detail)
    set_native_if_changed('user-data/video-enhancement/shader-registry',
        table.concat(registry, ';'))
end

local function classify_gpu(name)
    local n = tostring(name or ''):lower()
    if n == '' or n:find('microsoft basic', 1, true) or n:find('remote display', 1, true) then
        return 'low', 0
    end

    if n:find('nvidia', 1, true) then
        local rtx = tonumber(n:match('rtx%s*(%d%d%d%d)'))
        if rtx then
            local class = rtx % 100
            if class >= 60 then return 'high', 4000 + rtx end
            return 'medium', 3000 + rtx
        end

        local gtx = tonumber(n:match('gtx%s*(%d%d%d%d?)'))
        if gtx then
            if gtx >= 1600 then return 'medium', 2600 + gtx end
            if gtx >= 1080 then return 'high', 2800 + gtx end
            if gtx >= 1060 then return 'medium', 2500 + gtx end
            if gtx >= 970 then return 'medium', 2300 + gtx end
            return 'low', 1200 + gtx
        end

        if n:match('%f[%a]mx%s*%d') or n:match('%f[%a]gt%s*%d') then
            return 'low', 1300
        end
        return 'medium', 2400
    end

    if n:find('amd', 1, true) or n:find('radeon', 1, true) then
        local rx = tonumber(n:match('rx%s*(%d%d%d%d?)'))
        if rx then
            if rx >= 5000 then
                if (rx % 1000) >= 600 then return 'high', 3800 + rx end
                return 'medium', 2800 + rx
            end
            if rx >= 570 then return 'medium', 2400 + rx end
            return 'low', 1400 + rx
        end

        local vega = tonumber(n:match('vega%s*(%d+)'))
        if vega and vega >= 56 then return 'high', 3500 + vega end
        if n:find('vega', 1, true) or n:find('radeon%(tm%) graphics') or
            n:match('radeon%s+%d+m') then
            return 'low', 1500
        end
        return 'balanced', 2000
    end

    if n:find('intel', 1, true) then
        local arc = n:find('arc', 1, true) and
            (tonumber(n:match('%f[%a]a%s*(%d+)')) or tonumber(n:match('arc.-(%d+)')))
        if arc then
            if arc >= 500 then return 'high', 3600 + arc end
            return 'medium', 2600 + arc
        end
        if n:find('arc', 1, true) then return 'medium', 2600 end
        return 'low', 1000
    end

    return o.unknown_tier, 1800
end

local function cache_path()
    local temp = trim(os.getenv('TEMP') or os.getenv('TMP'))
    if temp == '' then return nil end
    return temp .. '\\mpv_adaptive_quality_gpu_v2.txt'
end

local function read_gpu_cache()
    local path = cache_path()
    local file = path and io.open(path, 'rb') or nil
    if not file then return nil end

    local machine = trim(file:read('*l'))
    if machine == '' or machine:lower() ~= trim(os.getenv('COMPUTERNAME')):lower() then
        file:close()
        return nil
    end

    local result = {}
    for line in file:lines() do
        local name, ram = line:match('^(.-)\t(%d+)$')
        if name and name ~= '' then
            result[#result + 1] = {
                name = name,
                ram = tonumber(ram) or 0,
                index = #result,
            }
        end
    end
    file:close()
    return #result > 0 and result or nil
end

local function write_gpu_cache(gpus)
    local path = cache_path()
    local file = path and io.open(path, 'wb') or nil
    if not file then return end
    file:write(trim(os.getenv('COMPUTERNAME')), '\n')
    for _, gpu in ipairs(gpus) do
        file:write(tostring(gpu.name), '\t', tostring(gpu.ram or 0), '\n')
    end
    file:close()
end

local function query_windows_gpus()
    local cached = read_gpu_cache()
    if cached then return cached end

    local ps = [[$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $all = @(Get-CimInstance Win32_VideoController); $pci = @($all | Where-Object { $_.PNPDeviceID -like "PCI\*" }); $items = if ($pci.Count -gt 0) { $pci } else { $all }; $items | ForEach-Object { $n = ($_.Name -replace "[`r`n`t|]", " "); Write-Output ($n + "`t" + [string]([uint64]$_.AdapterRAM)) }]]
    local result = mp.command_native({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {'powershell', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ps},
    })

    if type(result) ~= 'table' or result.status ~= 0 then
        msg.warn('GPU detection failed: ' .. tostring(result and result.stderr or 'unknown error'))
        return nil
    end

    local gpus = {}
    for line in tostring(result.stdout or ''):gmatch('[^\r\n]+') do
        local name, ram = line:match('^(.-)\t(%d+)$')
        if name and trim(name) ~= '' then
            gpus[#gpus + 1] = {
                name = trim(name),
                ram = tonumber(ram) or 0,
                index = #gpus,
            }
        end
    end
    if #gpus > 0 then write_gpu_cache(gpus) end
    return #gpus > 0 and gpus or nil
end

local function choose_gpu(gpus)
    local best = nil
    for _, gpu in ipairs(gpus or {}) do
        local tier, score = classify_gpu(gpu.name)
        gpu.tier = tier
        gpu.score = score + math.min((gpu.ram or 0) / (1024 * 1024 * 1024), 4)
        if not best or gpu.score > best.score then best = gpu end
    end
    return best
end

local function publish_state(profile, shaders)
    mp.set_property_native('user-data/adaptive-quality/gpu', selected_gpu and selected_gpu.name or 'unknown')
    mp.set_property_native('user-data/adaptive-quality/gpu-index',
        selected_gpu and selected_gpu.index or -1)
    mp.set_property_native('user-data/adaptive-quality/gpu-memory',
        selected_gpu and selected_gpu.ram or 0)
    mp.set_property_native('user-data/adaptive-quality/tier', selected_tier)
    mp.set_property_native('user-data/adaptive-quality/profile', profile or '')
    mp.set_property_native('user-data/adaptive-quality/shaders', shaders or '')
end

local function initialize_gpu()
    local override = trim(o.tier):lower()
    local gpus = query_windows_gpus()
    selected_gpu = choose_gpu(gpus)
    selected_tier = override ~= '' and override ~= 'auto'
        and override
        or (selected_gpu and selected_gpu.tier or o.unknown_tier)

    if selected_tier ~= 'low' and selected_tier ~= 'balanced' and
        selected_tier ~= 'medium' and selected_tier ~= 'high' then
        selected_tier = 'balanced'
    end

    if o.auto_select_adapter and selected_gpu and mp.get_property('gpu-api', 'auto') == 'd3d11' then
        mp.set_property('d3d11-adapter', selected_gpu.name)
    end

    publish_shader_capabilities()
    publish_state('waiting', '')
    publish_requested_modes()
    publish_superres_state({}, false, '等待视频')
    publish_smooth_state('等待视频', '等待视频与显示器信息', false)
    mp.set_property_native('user-data/adaptive-quality/adapter-ready', 'yes')
    mp.commandv('script-message-to', 'startup_window', 'adapter-ready')
    msg.info(string.format('GPU=%s, adaptive tier=%s', selected_gpu and selected_gpu.name or 'unknown', selected_tier))
end

local function shader_key(list)
    return table.concat(list or {}, '\31')
end

local function current_shader_key()
    local shaders = mp.get_property_native('glsl-shaders', {})
    if type(shaders) ~= 'table' then return tostring(shaders or '') end
    return shader_key(shaders)
end

local function shader_label(path)
    if path == shader_paths.chroma then return 'KrigBilateral' end
    if path == shader_paths.superres then return 'SSimSuperRes' end
    if path == shader_paths.downscale then return 'SSimDownscaler' end
    if path == shader_paths.fsrcnnx_restore then return 'FSRCNNX-Restore' end
    if path == shader_paths.fsrcnnx_upscale then return 'FSRCNNX-x2' end
    return path:match('([^/\\]+)$') or path
end

local function shader_names(shaders)
    local names = {}
    for _, path in ipairs(shaders or {}) do
        names[#names + 1] = path:match('([^/\\]+)$') or path
    end
    return table.concat(names, ';')
end

local function profile_for(shaders, variant)
    local profile = selected_tier
    for _, path in ipairs(shaders or {}) do
        profile = profile .. '+' .. shader_label(path)
    end
    if variant and variant > 1 then
        profile = profile .. '+guard' .. tostring(variant - 1)
    end
    return profile
end

local function append_unique(list, value)
    for _, item in ipairs(list) do
        if item == value then return end
    end
    list[#list + 1] = value
end

local function build_variants(full, is_upscale)
    local variants = {}
    local seen = {}
    local function add_variant(source)
        local copy = {}
        for _, path in ipairs(source) do copy[#copy + 1] = path end
        local key = shader_key(copy)
        if not seen[key] then
            seen[key] = true
            variants[#variants + 1] = copy
        end
    end

    add_variant(full)

    -- First sacrifice the subtle chroma refinement while retaining the main
    -- luma scaler/restoration shader.
    local without_chroma = {}
    for _, path in ipairs(full) do
        if path ~= shader_paths.chroma then without_chroma[#without_chroma + 1] = path end
    end
    add_variant(without_chroma)

    -- If FSRCNNX is too expensive during a real workload, retain the lighter
    -- SSim correction when the image is actually being enlarged.
    local light = {}
    for _, path in ipairs(without_chroma) do
        if path == shader_paths.superres then
            append_unique(light, path)
        elseif (path == shader_paths.fsrcnnx_restore or path == shader_paths.fsrcnnx_upscale)
            and is_upscale then
            append_unique(light, shader_paths.superres)
        end
    end
    add_variant(light)
    add_variant({})
    return variants
end

local function automatic_fsrcnnx_is_baseline(w, h, fps, meaningful_upscale)
    if not o.auto_shaders or not meaningful_upscale or o.superres_mode == 'off'
        or o.superres_mode == 'performance' or selected_tier == 'low'
        or selected_tier == 'balanced' then
        return false, 0
    end
    local tier_limit = selected_tier == 'high' and o.high_fsrcnnx_max_fps
        or o.medium_fsrcnnx_max_fps
    if fps <= 0 or fps > tier_limit or fps > o.shader_max_fps then
        return false, tier_limit
    end
    local is_sd = w > 0 and h > 0 and w <= 1280 and h <= 720
    if o.superres_mode == 'quality' then
        return is_sd or (w <= 1920 and h <= 1080), tier_limit
    end
    return o.superres_mode == 'auto' and is_sd, tier_limit
end

local function set_auto_shaders(shaders)
    local current = current_shader_key()
    local user_overrode = last_auto_shader_key ~= nil
        and current ~= last_auto_shader_key
        or last_auto_shader_key == nil and current ~= ''
    if user_overrode then
        publish_state('manual', current)
        return false
    end

    local valid = {}
    for _, path in ipairs(shaders) do
        if file_exists(path) then valid[#valid + 1] = path end
    end
    mp.set_property_native('glsl-shaders', valid)
    last_auto_shader_key = current_shader_key()
    return true
end

local function drop_count()
    return mp.get_property_number('frame-drop-count', 0) or 0
end

local function publish_guard(ratio, state)
    mp.set_property_native('user-data/adaptive-quality/guard-level',
        (active_variant - 1) + (smooth_active_variant - 1))
    mp.set_property_native('user-data/adaptive-quality/guard-state', state or 'stable')
    mp.set_property_native('user-data/adaptive-quality/render-ratio', ratio or 0)
    mp.set_property_native('user-data/video-enhancement/smooth-guard-level', smooth_active_variant - 1)
end

local function reset_guard_window(delay)
    guard_bad_samples = 0
    guard_good_samples = 0
    guard_last_drops = drop_count()
    guard_ready_at = mp.get_time() + math.max(delay or 0, 0)
end

local function apply_variant(index, reason)
    index = math.max(1, math.min(index, #runtime_variants))
    local shaders = runtime_variants[index] or {}
    local managed = set_auto_shaders(shaders)
    shader_guard_managed = managed
    guard_managed = shader_guard_managed or smooth_guard_managed
    if not managed then
        publish_superres_state({}, true)
        if not smooth_guard_managed then publish_guard(0, 'manual') end
        return false
    end

    active_variant = index
    publish_state(profile_for(shaders, index), shader_names(shaders))
    local spatial_detail = tostring(mp.get_property_native(
        'user-data/video-enhancement/rife-spatial-detail') or '')
    local ai_state = mp.get_property_native(
        'user-data/video-enhancement/ai-state') or 'idle'
    local shader_list = shader_key(shaders)
    local light_only = shader_list:find(shader_paths.superres, 1, true)
        and not shader_list:find(shader_paths.fsrcnnx_restore, 1, true)
        and not shader_list:find(shader_paths.fsrcnnx_upscale, 1, true)
    local coordinated_reason = (ai_state == 'starting' or ai_state == 'active')
        and light_only and spatial_detail:find('补帧协同', 1, true)
        and '补帧协同：重型超分已切换轻量增强' or nil
    publish_superres_state(shaders, false,
        index > 1 and '性能保护已降级' or coordinated_reason)
    publish_guard(0, index == 1 and 'full' or 'reduced')
    reset_guard_window(o.guard_change_cooldown)

    if reason and reason ~= 'initial' then
        msg.info(string.format('performance guard %s: level=%d, profile=%s',
            reason, index - 1, profile_for(shaders, index)))
    end

    if o.show_osd and reason and reason ~= 'initial' then
        local action = reason == 'recovered' and '恢复一级' or '降低一级'
        mp.osd_message(string.format('自适应画质：%s\n%s', action, profile_for(shaders, index)), 2)
    end
    return true
end

local function apply_smart_deband(w, h, fps, is_8k)
    local bitrate = mp.get_property_number('video-bitrate', 0) or 0
    local average_bpp = mp.get_property_number('video-params/average-bpp', 999) or 999
    local format = (mp.get_property('video-params/pixelformat', '') .. ' ' ..
        mp.get_property('video-params/hw-pixelformat', '')):lower()
    local gamma = mp.get_property('video-params/gamma', ''):lower()
    local high_depth = format:find('p010', 1, true) or format:find('p012', 1, true) or
        format:find('10', 1, true) or format:find('12', 1, true) or format:find('16', 1, true)
    local bpppf = 0
    if bitrate > 0 and w > 0 and h > 0 and fps > 0 then
        bpppf = bitrate / (w * h * fps)
    end

    local enabled = o.smart_deband and selected_tier ~= 'low' and not is_8k and
        gamma ~= 'pq' and gamma ~= 'hlg' and not high_depth and average_bpp < 24 and
        bpppf > 0 and bpppf <= o.deband_max_bpppf

    mp.set_property_bool('deband', enabled)
    if enabled then
        mp.set_property_number('deband-iterations', 1)
        mp.set_property_number('deband-threshold', 48)
        mp.set_property_number('deband-range', 16)
        mp.set_property_number('deband-grain', 16)
    end
    mp.set_property_native('user-data/adaptive-quality/deband', enabled and 'low-bitrate' or 'off')
    mp.set_property_native('user-data/adaptive-quality/deband-bpppf', bpppf)
end

local function restore_smooth_properties()
    set_string_if_changed('video-sync', smooth_baseline.video_sync)
    set_bool_if_changed('interpolation', smooth_baseline.interpolation)
    set_number_if_changed('interpolation-threshold', smooth_baseline.interpolation_threshold)
    set_string_if_changed('tscale', smooth_baseline.tscale)
    set_number_if_changed('tscale-blur', smooth_baseline.tscale_blur)
end

local function audio_is_passthrough()
    local enabled = mp.get_property_native('user-data/audio-passthrough/enabled')
    if enabled == true or enabled == 'yes' then return true end
    local format = mp.get_property('audio-params/format', ''):lower()
    return format:find('spdif-', 1, true) == 1 or format:find('iec61937', 1, true) ~= nil
end

local function reset_rife_clock_guard()
    rife_clock_active = false
    rife_clock_fallback = false
    rife_clock_ready_at = 0
    rife_clock_bad_samples = 0
    rife_clock_reference_fps = 0
    rife_display_alignment_active = false
    mp.set_property_native('user-data/video-enhancement/rife-clock-guard', 'idle')
    mp.set_property_native('user-data/video-enhancement/rife-clock-detail', '')
end

local function arm_rife_clock_guard()
    if rife_clock_active then return end
    rife_clock_active = true
    rife_clock_ready_at = mp.get_time() + math.max(0, o.rife_clock_guard_start_delay)
    rife_clock_bad_samples = 0
    rife_clock_reference_fps = mp.get_property_number('display-fps', 0) or 0
    mp.set_property_native('user-data/video-enhancement/rife-clock-guard',
        rife_clock_fallback and 'protected' or 'stable')
end

local function trip_rife_clock_guard(reason)
    if rife_clock_fallback then return end
    rife_clock_fallback = true
    rife_clock_bad_samples = 0
    restore_smooth_properties()
    mp.set_property_native('user-data/video-enhancement/rife-clock-guard', 'protected')
    mp.set_property_native('user-data/video-enhancement/rife-clock-detail', reason)
    msg.warn('RIFE display clock protection: ' .. reason)
    if schedule_apply then schedule_apply() end
end

local function monitor_rife_clock()
    if not o.rife_clock_guard or not rife_clock_active or rife_clock_fallback
        or audio_is_passthrough() then
        return
    end
    if mp.get_property_bool('pause', false)
        or mp.get_property_bool('paused-for-cache', false)
        or mp.get_property_bool('seeking', false) then
        rife_clock_bad_samples = 0
        rife_clock_ready_at = mp.get_time() + 1
        return
    end
    if mp.get_time() < rife_clock_ready_at then return end

    local display_fps = mp.get_property_number('display-fps', 0) or 0
    local estimated_fps = mp.get_property_number('estimated-display-fps', 0) or 0
    local hard_hz = tonumber(o.rife_clock_guard_hard_hz) or 1000
    local hard_ratio = tonumber(o.rife_clock_guard_hard_ratio) or 8
    local reference_fps = rife_clock_reference_fps > 0 and rife_clock_reference_fps or display_fps
    local extreme_ratio = reference_fps > 0 and estimated_fps / reference_fps >= hard_ratio
    if display_fps >= hard_hz or estimated_fps >= hard_hz or extreme_ratio then
        trip_rife_clock_guard(string.format(
            '显示刷新率估算异常（%.3fHz，参考 %.3fHz），当前文件保持原始音频时钟',
            estimated_fps, reference_fps))
        return
    end

    if display_fps > 0 and reference_fps > 0
        and math.abs(display_fps - reference_fps) / reference_fps >= 0.05 then
        rife_clock_reference_fps = display_fps
        rife_clock_bad_samples = 0
        rife_clock_ready_at = mp.get_time() + math.max(0, o.rife_clock_guard_start_delay)
        return
    elseif rife_clock_reference_fps <= 0 and display_fps > 0 then
        rife_clock_reference_fps = display_fps
    end

    local correction = mp.get_property_number('audio-speed-correction', 1) or 1
    local avsync = math.abs(mp.get_property_number('avsync', 0) or 0)
    local correction_bad = correction > 0 and
        math.abs(correction - 1) >= math.max(0.001, o.rife_clock_guard_audio_change)
    local avsync_bad = avsync >= math.max(0.05, o.rife_clock_guard_avsync)
    if correction_bad or avsync_bad then
        rife_clock_bad_samples = rife_clock_bad_samples + 1
    else
        rife_clock_bad_samples = math.max(0, rife_clock_bad_samples - 1)
    end
    if rife_clock_bad_samples >= math.max(1, math.floor(o.rife_clock_guard_bad_samples)) then
        trip_rife_clock_guard(string.format(
            '音频时钟校正异常（校正 %.4f，A-V %.3fs），当前文件保持原始音频时钟',
            correction, avsync))
    end
end

local function build_smooth_variants(algorithm, video_sync)
    video_sync = video_sync or 'display-resample'
    local clock_safe = video_sync == 'display-vdrop'
    local variants = {{
        enabled = true,
        algorithm = algorithm,
        video_sync = video_sync,
        clock_safe = clock_safe,
    }}
    if algorithm ~= 'oversample' then
        variants[#variants + 1] = {
            enabled = true,
            algorithm = 'oversample',
            video_sync = video_sync,
            clock_safe = clock_safe,
        }
    end
    variants[#variants + 1] = {enabled = false, algorithm = 'off'}
    return variants
end

local function smooth_detail(variant)
    local fps = last_metrics and last_metrics.fps or 0
    local display_fps = last_metrics and last_metrics.display_fps or 0
    local algorithm = variant.algorithm
    local algorithm_label = algorithm == 'sphinx'
        and 'Sphinx 时间重采样'
        or 'Oversample 时间重采样'
    local suffix = algorithm_label
    if variant.clock_safe then
        suffix = suffix .. ((last_metrics and last_metrics.is_hdr)
            and ' · HDR 安全 · 原始音频时钟'
            or ' · 原始音频时钟')
    end
    return string.format('未生成 AI 中间帧 · %sfps 源帧率 · %sHz 显示 · %s',
        format_fps(fps), format_fps(display_fps), suffix)
end

local function apply_smooth_variant(index, reason)
    index = math.max(1, math.min(index, #smooth_runtime_variants))
    local variant = smooth_runtime_variants[index] or {enabled = false, algorithm = 'off'}
    smooth_active_variant = index

    if variant.enabled then
        set_string_if_changed('video-sync', variant.video_sync or 'display-resample')
        set_bool_if_changed('interpolation', true)
        -- A managed smooth mode is an explicit request. Disable mpv's dynamic
        -- interpolation threshold so transient display-fps estimates cannot
        -- silently toggle temporal interpolation while the menu still says on.
        set_number_if_changed('interpolation-threshold', -1)
        set_string_if_changed('tscale', variant.algorithm)
        set_number_if_changed('tscale-blur', variant.algorithm == 'sphinx' and 0.65 or 0)
        smooth_guard_managed = true
        local effective = variant.clock_safe and last_metrics and last_metrics.is_hdr
                and 'HDR 时间重采样（非 AI 补帧）'
            or variant.algorithm == 'sphinx' and '时间重采样（非 AI 补帧）'
            or '轻量时间重采样（非 AI 补帧）'
        publish_smooth_state(effective, smooth_detail(variant), true,
            variant.clock_safe and 'native-clock-safe' or 'native-display')
    else
        restore_smooth_properties()
        smooth_guard_managed = #smooth_runtime_variants > 1
        publish_smooth_state(reason == 'overload' and '性能保护已关闭' or '关闭',
            reason == 'overload' and '实时负载超出帧预算，已恢复普通播放' or '关闭', false)
    end

    guard_managed = shader_guard_managed or smooth_guard_managed
    publish_guard(0, index == 1 and 'full' or 'reduced')
    reset_guard_window(o.guard_change_cooldown)

    if reason and reason ~= 'initial' then
        msg.info(string.format('smooth playback guard %s: level=%d, algorithm=%s',
            reason, index - 1, variant.algorithm))
        if o.show_osd then
            mp.osd_message(reason == 'recovered'
                and '平滑播放：恢复一级'
                or variant.enabled and '平滑播放：降低为轻量模式'
                or '平滑播放：性能不足，已安全关闭', 2)
        end
    end
end

local function suppress_smooth(reason, detail)
    smooth_runtime_variants = {{enabled = false, algorithm = 'off'}}
    smooth_active_variant = 1
    smooth_guard_managed = false
    restore_smooth_properties()
    guard_managed = shader_guard_managed
    detail = detail or reason
    local source_fps = last_metrics and last_metrics.fps or 0
    if source_fps > 0 and not tostring(detail):find('→', 1, true) then
        detail = string.format('%sfps → 原帧率 · %s', format_fps(source_fps), detail)
    end
    publish_smooth_state(reason, detail, false, 'source')
end

local function configure_smooth_playback(fps, display_fps, speed)
    local ai_state = mp.get_property_native('user-data/video-enhancement/ai-state') or 'idle'
    if ai_state ~= 'active' then
        rife_clock_active = false
        rife_clock_bad_samples = 0
        rife_display_alignment_active = false
    end
    if ai_state == 'detecting' or ai_state == 'starting' then
        suppress_smooth('AI 检测中', mp.get_property_native(
            'user-data/video-enhancement/ai-detail') or '正在确认 RIFE 安全边界')
        return
    end
    if ai_state == 'active' then
        local passthrough = audio_is_passthrough()
        local display_pixel_rate = 0
        if last_metrics then
            display_pixel_rate = math.max(0, last_metrics.display_w or 0)
                * math.max(0, last_metrics.display_h or 0)
                * math.max(0, display_fps or 0)
        end
        local display_limit = selected_tier == 'high'
                and math.max(0, tonumber(o.high_rife_display_max_pixel_rate) or 0)
            or selected_tier == 'medium'
                and math.max(0, tonumber(o.medium_rife_display_max_pixel_rate) or 0)
            or 0
        local gpu_name = tostring(mp.get_property_native(
            'user-data/adaptive-quality/gpu')
            or (selected_gpu and selected_gpu.name) or ''):lower()
        local rtx = tonumber(gpu_name:match('rtx%s*(%d%d%d%d)'))
        local upper_high_rtx = rtx and math.floor(rtx / 1000) >= 4
            and (rtx % 100) >= 80
        local output_at_most_1440p = last_metrics
            and math.max(last_metrics.display_w or 0, last_metrics.display_h or 0) <= 2560
            and math.min(last_metrics.display_w or 0, last_metrics.display_h or 0) <= 1440
        if selected_tier == 'high' and upper_high_rtx and output_at_most_1440p then
            -- 50 fps on a 240 Hz panel repeats with a 4.8-frame cadence and is
            -- visibly uneven even though RIFE itself is healthy. RTX 4080/5080
            -- class GPUs have a separate 1440p high-refresh budget; the runtime
            -- guards still shed this optional alignment first if real drops rise.
            display_limit = math.max(display_limit,
                tonumber(o.upper_high_rife_1440p_display_max_pixel_rate) or 0)
        end
        local display_budget_exceeded = display_pixel_rate > 0
            and (display_limit <= 0 or display_pixel_rate > display_limit)
        local keep_audio_clock = passthrough or rife_clock_fallback or display_budget_exceeded
        rife_display_alignment_active = not keep_audio_clock
        if keep_audio_clock then
            rife_clock_active = false
            rife_clock_bad_samples = 0
            if display_budget_exceeded then
                mp.set_property_native('user-data/video-enhancement/rife-clock-guard', 'protected')
                mp.set_property_native('user-data/video-enhancement/rife-clock-detail',
                    '高分辨率高刷预算已预先关闭二次显示插值')
            end
        else
            arm_rife_clock_guard()
        end
        smooth_runtime_variants = {{enabled = not keep_audio_clock, algorithm = 'oversample'}}
        smooth_active_variant = 1
        if keep_audio_clock then
            -- RIFE already produces real 2x video frames. Keep the original
            -- audio clock untouched for bitstream or a detected clock anomaly.
            restore_smooth_properties()
        else
            set_string_if_changed('video-sync', 'display-resample')
            set_bool_if_changed('interpolation', true)
            set_number_if_changed('interpolation-threshold', -1)
            set_string_if_changed('tscale', 'oversample')
            set_number_if_changed('tscale-blur', 0)
        end
        smooth_guard_managed = false
        guard_managed = shader_guard_managed
        local detail = mp.get_property_native('user-data/video-enhancement/ai-detail')
            or 'RIFE AI 中间帧'
        if passthrough then
            detail = detail .. ' · 音频直通保持原始时钟'
        elseif rife_clock_fallback then
            detail = detail .. ' · 性能/时钟保护保持原始音频基准'
        elseif display_budget_exceeded then
            local rife_result_fps = mp.get_property_number(
                'user-data/video-enhancement/ai-result-fps', fps) or fps
            detail = detail .. string.format(
                ' · 高分辨率高刷保护：保留真实 %sfps，关闭 %s→%sHz 二次显示插值',
                format_fps(rife_result_fps), format_fps(rife_result_fps),
                format_fps(display_fps))
        else
            detail = detail .. ' · 显示器节奏对齐'
        end
        publish_smooth_state('RIFE AI 2×', detail, true, 'ai-fps')
        return
    end
    if o.smooth_mode == 'off' then
        suppress_smooth('关闭', '用户已关闭轻量补帧')
        return
    end
    local passthrough = audio_is_passthrough()
    if passthrough then
        -- RIFE active above is safe because it creates real 2x video frames
        -- while retaining the bitstream audio clock.  If RIFE was rejected,
        -- failed or is unavailable, however, display-vdrop + Sphinx is not a
        -- safe substitute: it can accumulate mistimed/delayed frames, and OSD
        -- redraws caused by mouse movement make that unstable clock path more
        -- visible.  Restore ordinary playback until real AI frames are ready.
        suppress_smooth('音频直通保护',
            '未生成 AI 中间帧 · 位流直通保持原始音视频时钟，已恢复普通播放')
        return
    end
    local is_4k = last_metrics and
        (last_metrics.w >= 3000 or last_metrics.h >= 1600)
    if o.protect_4k_smooth and is_4k then
        suppress_smooth('4K 保护', '4K 片源保护：不启用补帧')
        return
    end
    if is_4k and configure_4k_hwdec_pool(true) then
        suppress_smooth('4K 初始化保护', '正在扩展硬解帧池，稍后按显卡性能尝试')
        mp.add_timeout(0.45, function()
            if schedule_apply then schedule_apply() end
        end)
        return
    elseif not is_4k then
        configure_4k_hwdec_pool(false)
    end
    if fps <= 0 or display_fps <= 0 then
        suppress_smooth('等待检测', '等待片源帧率与显示器刷新率')
        return
    end
    if o.smooth_mode == 'auto' and (speed < 0.96 or speed > 1.04) then
        suppress_smooth('倍速保护', '自动模式在非 1× 播放时保持原始时钟，恢复 1× 后自动启用')
        return
    end

    local effective_fps = fps * math.max(speed or 1, 0.01)
    if effective_fps >= display_fps * 0.98 then
        suppress_smooth('当前无需补帧', '片源有效帧率已接近显示器刷新率')
        return
    end
    if o.smooth_mode == 'auto' and effective_fps >= 49 then
        suppress_smooth('当前无需补帧', '自动模式不处理 50/60fps 高帧率片源')
        return
    end
    if effective_fps > 60.5 then
        suppress_smooth('当前无需补帧', '有效帧率超过轻量补帧范围')
        return
    end

    local ratio = display_fps / effective_fps
    local nearest = math.floor(ratio + 0.5)
    if o.smooth_mode ~= 'quality'
        and nearest >= 1 and math.abs(ratio - nearest) <= 0.012 then
        suppress_smooth('刷新率已整除', string.format('%sfps 与 %sHz 已是整数倍节奏',
            format_fps(effective_fps), format_fps(display_fps)))
        return
    end

    local algorithm = 'oversample'
    if o.smooth_mode == 'quality' or
        (o.smooth_mode == 'auto' and (selected_tier == 'medium' or selected_tier == 'high')) then
        algorithm = 'sphinx'
    end
    smooth_runtime_variants = build_smooth_variants(algorithm, 'display-resample')
    smooth_active_variant = 1
    apply_smooth_variant(1, 'initial')
end

local function apply_quality()
    if not o.enabled or not mp.get_property_native('vid') then return end

    local source_w = mp.get_property_number('video-params/w', 0) or 0
    local source_h = mp.get_property_number('video-params/h', 0) or 0
    local output = mp.get_property_native('video-out-params') or {}
    -- Shaders run after VapourSynth, so use the real filter output geometry.
    -- Portable/native policies keep it at source size; the explicit full-pack
    -- UHD policy may intentionally return a 2K canvas and TensorRT super-res may
    -- return a larger one. This post-filter measurement keeps gpu-next budgets,
    -- menu status and diagnostics tied to the canvas that is actually rendered.
    local w = tonumber(output.w) or source_w
    local h = tonumber(output.h) or source_h
    local fps = mp.get_property_number('estimated-vf-fps', 0) or 0
    if fps <= 0 then fps = mp.get_property_number('container-fps', 0) or 0 end
    local display_w = mp.get_property_number('display-width', 0) or 0
    local display_h = mp.get_property_number('display-height', 0) or 0
    local display_fps = mp.get_property_number('display-fps', 0) or 0
    if display_fps <= 0 then
        display_fps = mp.get_property_number('estimated-display-fps', 0) or 0
    end
    local speed = mp.get_property_number('speed', 1) or 1
    local effective_fps = fps * math.max(speed, 0.01)
    local ai_state = mp.get_property_native('user-data/video-enhancement/ai-state') or 'idle'
    -- During RIFE startup estimated-vf-fps still reports the source cadence.
    -- Budget the pending 2x output now; otherwise 1080p -> 4K FSRCNNX remains
    -- active until RIFE succeeds, while that same combined load can prevent the
    -- first interpolated frame from reaching the startup gate at all.
    local rife_budget_fps = ai_state == 'starting' and effective_fps * 2
        or effective_fps
    local gamma = tostring(output.gamma
        or mp.get_property('video-params/gamma', '')):lower()
    local is_8k = source_w > 7000 or source_h > 3000
    local is_sd = w > 0 and h > 0 and w <= 1280 and h <= 720
    local fit_scale = 1
    if w > 0 and h > 0 and display_w > 0 and display_h > 0 then
        fit_scale = math.min(display_w / w, display_h / h)
    end
    local target_w = w > 0 and math.floor(w * fit_scale + 0.5) or display_w
    local target_h = h > 0 and math.floor(h * fit_scale + 0.5) or display_h
    local is_downscale = fit_scale < 0.999
    local is_upscale = fit_scale > 1.001
    local upscale_ratio = is_upscale and fit_scale or 1
    local meaningful_upscale = is_upscale and upscale_ratio >= 1.12
    local render_w = math.max(w, target_w)
    local render_h = math.max(h, target_h)
    local pixel_rate = render_w * render_h * rife_budget_fps
    local rife_fsrcnnx_limit = selected_tier == 'high'
            and math.max(0, tonumber(o.high_rife_fsrcnnx_max_pixel_rate) or 0)
        or selected_tier == 'medium'
            and math.max(0, tonumber(o.medium_rife_fsrcnnx_max_pixel_rate) or 0)
        or 0
    local budget_gpu_name = tostring(mp.get_property_native(
        'user-data/adaptive-quality/gpu') or ''):lower()
    local budget_rtx = tonumber(budget_gpu_name:match('rtx%s*(%d%d%d%d)'))
    local budget_desktop = not budget_gpu_name:find('laptop', 1, true)
        and not budget_gpu_name:find('max%-q')
    local upper_high_desktop = budget_rtx and budget_desktop
        and math.floor(budget_rtx / 1000) >= 4 and (budget_rtx % 100) >= 80
    local target_at_most_1440p = math.max(target_w, target_h) <= 2560
        and math.min(target_w, target_h) <= 1440
    if selected_tier == 'high' and upper_high_desktop and target_at_most_1440p then
        rife_fsrcnnx_limit = math.max(rife_fsrcnnx_limit,
            tonumber(o.upper_high_rife_fsrcnnx_max_pixel_rate) or 0)
    end
    -- RIFE inference itself must never be smaller than the decoded source.
    -- Display-upscale shaders are a separate, coordinated budget: if managed
    -- FSRCNNX and true RIFE 2x cannot coexist, keep source-native RIFE and swap
    -- only that secondary upscale stage to SSim. User-owned shaders are never
    -- changed automatically.
    local spatial_source_fps = effective_fps
    if ai_state == 'active' then
        local published_source_fps = mp.get_property_number(
            'user-data/video-enhancement/ai-source-fps', 0) or 0
        if published_source_fps > 0 then
            spatial_source_fps = published_source_fps * math.max(speed, 0.01)
        end
    end
    local current_shader = current_shader_key()
    local manual_shader = last_auto_shader_key ~= nil
            and current_shader ~= last_auto_shader_key
        or last_auto_shader_key == nil and current_shader ~= ''
    local baseline_fsrcnnx, spatial_fsrcnnx_limit = automatic_fsrcnnx_is_baseline(
        w, h, spatial_source_fps, meaningful_upscale)
    if manual_shader then baseline_fsrcnnx = false end
    local predicted_rife_fps = spatial_source_fps * 2
    local predicted_rife_pixel_rate = render_w * render_h * predicted_rife_fps
    local rife_keeps_fsrcnnx = predicted_rife_fps > 0
        and predicted_rife_fps <= spatial_fsrcnnx_limit
        and predicted_rife_fps <= o.shader_max_fps
        and predicted_rife_pixel_rate > 0
        and rife_fsrcnnx_limit > 0
        and predicted_rife_pixel_rate <= rife_fsrcnnx_limit
    local explicit_hq_tradeoff = mp.get_property_native(
        'user-data/video-enhancement/hq-spatial-tradeoff') == 'explicit'
    local coordinated_light_fallback = baseline_fsrcnnx and not rife_keeps_fsrcnnx
        and not manual_shader
        and (o.smooth_mode == 'auto' or o.smooth_mode == 'quality')
    if explicit_hq_tradeoff then
        publish_rife_spatial_compatibility(true,
            '完整依赖显式性能档：用户允许 4K 等比降至 2K 后补帧；状态栏持续披露尺寸变化')
    elseif coordinated_light_fallback then
        publish_rife_spatial_compatibility(true, string.format(
            '补帧协同：RIFE %sfps 启动时将重型 FSRCNNX 切为 SSim 轻量增强，源分辨率不变',
            format_fps(predicted_rife_fps)))
    elseif baseline_fsrcnnx and not rife_keeps_fsrcnnx then
        publish_rife_spatial_compatibility(false,
            '自定义空间链无法安全降负载，已保持现有画质处理')
    else
        publish_rife_spatial_compatibility(true,
            manual_shader and '手动着色器保持不变，不由 RIFE 自动降级'
                or baseline_fsrcnnx and 'RIFE 可保留 FSRCNNX 空间画质基线'
                or '当前空间链不会因 RIFE 降级')
    end
    -- RIFE and FSRCNNX share the same GPU. Select the lighter SSim path before
    -- playback starts missing deadlines instead of waiting for the reactive
    -- guard to accumulate several seconds of drops first. This keeps true RIFE
    -- 2x active; only the secondary display-upscale shader is reduced.
    local rife_pipeline_pending = ai_state == 'starting' or ai_state == 'active'
    local rife_fsrcnnx_fps_limit = selected_tier == 'high'
            and math.max(0, tonumber(o.high_fsrcnnx_max_fps) or 0)
        or selected_tier == 'medium'
            and math.max(0, tonumber(o.medium_fsrcnnx_max_fps) or 0)
        or 0
    local rife_fsrcnnx_over_budget = rife_pipeline_pending and meaningful_upscale
        and (rife_fsrcnnx_fps_limit <= 0 or rife_budget_fps > rife_fsrcnnx_fps_limit
            or pixel_rate <= 0 or rife_fsrcnnx_limit <= 0
            or pixel_rate > rife_fsrcnnx_limit)
    last_metrics = {
        w = w,
        h = h,
        display_w = target_w,
        display_h = target_h,
        fps = fps,
        display_fps = display_fps,
        speed = speed,
        is_hdr = gamma == 'pq' or gamma == 'hlg',
    }

    if selected_tier == 'low' then
        mp.set_property('scale', 'lanczos')
        mp.set_property('dscale', 'mitchell')
        mp.set_property_number('hdr-contrast-recovery', 0)
        mp.set_property_bool('deband', false)
    else
        -- Preserve the package's original HQ baseline on the owner's GTX 1060,
        -- known faster GPUs, and unknown hardware where quality must not regress.
        mp.set_property('scale', 'ewa_lanczossharp')
        mp.set_property('dscale', 'lanczos')
        mp.set_property_number('hdr-contrast-recovery', 0.30)
    end

    apply_smart_deband(w, h, effective_fps, is_8k)

    local shaders = {}
    if o.auto_shaders and not is_8k and effective_fps > 0 and effective_fps <= o.shader_max_fps then
        local chroma_limit = selected_tier == 'medium' and o.medium_chroma_max_pixel_rate
            or selected_tier == 'high' and o.high_chroma_max_pixel_rate
            or 0
        if o.auto_chroma and not is_downscale and pixel_rate <= chroma_limit then
            -- Spend modest GPU headroom on 4:2:0 chroma reconstruction. Unlike
            -- sharpening, KrigBilateral only runs when a lower-resolution CHROMA
            -- plane exists, so RGB/4:4:4 sources are left untouched.
            shaders[#shaders + 1] = shader_paths.chroma
        end

        if meaningful_upscale and o.superres_mode ~= 'off' then
            local tier_limit = selected_tier == 'high' and o.high_fsrcnnx_max_fps
                or o.medium_fsrcnnx_max_fps
            if o.superres_mode == 'performance' or selected_tier == 'low'
                or selected_tier == 'balanced' then
                shaders[#shaders + 1] = shader_paths.superres
            elseif o.superres_mode == 'quality' then
                if rife_fsrcnnx_over_budget then
                    shaders[#shaders + 1] = shader_paths.superres
                elseif is_sd and effective_fps <= tier_limit then
                    shaders[#shaders + 1] = shader_paths.fsrcnnx_restore
                elseif w <= 1920 and h <= 1080 and effective_fps <= tier_limit then
                    shaders[#shaders + 1] = shader_paths.fsrcnnx_upscale
                else
                    shaders[#shaders + 1] = shader_paths.superres
                end
            elseif is_sd and effective_fps <= tier_limit and not rife_fsrcnnx_over_budget then
                -- Auto mode keeps the proven restoration model for SD sources;
                -- heavier x2 inference remains an explicit quality choice.
                shaders[#shaders + 1] = shader_paths.fsrcnnx_restore
            else
                shaders[#shaders + 1] = shader_paths.superres
            end
        end

        if selected_tier == 'medium' then
            if is_downscale and effective_fps <= o.medium_downscale_max_fps then
                shaders[#shaders + 1] = shader_paths.downscale
            end
        elseif selected_tier == 'high' then
            if is_downscale and effective_fps <= o.high_downscale_max_fps then
                shaders[#shaders + 1] = shader_paths.downscale
            end
        end
    end

    runtime_variants = build_variants(shaders, is_upscale)
    active_variant = 1
    local managed = apply_variant(1, 'initial')
    configure_smooth_playback(fps, display_fps, speed)
    guard_ready_at = mp.get_time() + math.max(o.guard_start_delay, 0)

    if o.show_osd then
        mp.osd_message(string.format('自适应画质：%s\n%s', selected_tier,
            managed and profile_for(runtime_variants[1], 1) or '手动着色器'), 2)
    end
end

local function render_ratio()
    local fps = mp.get_property_number('estimated-vf-fps', 0) or 0
    if fps <= 0 then fps = mp.get_property_number('container-fps', 0) or 0 end
    local speed = mp.get_property_number('speed', 1) or 1
    fps = fps * math.max(speed, 0.01)
    -- RIFE can stay active during bitstream passthrough, but in that mode it
    -- deliberately keeps the source audio clock and does not render at the
    -- display cadence.  Budget the guard against the real AI output fps.
    local use_display_budget = smooth_effective
        and (smooth_result_kind ~= 'ai-fps' or rife_display_alignment_active)
    if use_display_budget then
        local display_fps = mp.get_property_number('display-fps', 0) or 0
        if display_fps <= 0 then
            display_fps = mp.get_property_number('estimated-display-fps', 0) or 0
        end
        if display_fps > 0 then fps = display_fps end
    end
    if fps <= 0 then return nil end

    local passes = mp.get_property_native('vo-passes')
    local fresh = type(passes) == 'table' and passes.fresh or nil
    if type(fresh) ~= 'table' or #fresh == 0 then return nil end

    local total = 0
    for _, pass in ipairs(fresh) do
        total = total + (tonumber(pass.avg) or tonumber(pass.last) or 0)
    end
    if total <= 0 then return nil end
    return total / (1000000000 / fps)
end

local function monitor_guard()
    if not o.performance_guard or not guard_managed or not mp.get_property_native('vid') then return end

    if shader_guard_managed and current_shader_key() ~= last_auto_shader_key then
        shader_guard_managed = false
        guard_managed = smooth_guard_managed
        publish_state('manual', mp.get_property('glsl-shaders', ''))
        publish_superres_state({}, true)
        if not guard_managed then
            publish_guard(0, 'manual')
            return
        end
    end

    local drops = drop_count()
    if mp.get_property_native('pause') or mp.get_property_native('seeking') or
        mp.get_property_native('core-idle') then
        guard_bad_samples = 0
        guard_good_samples = 0
        guard_last_drops = drops
        return
    end

    local now = mp.get_time()
    if now < guard_ready_at then
        guard_last_drops = drops
        return
    end

    local ratio = render_ratio()
    if not ratio then return end
    local drop_delta = math.max(0, drops - guard_last_drops)
    guard_last_drops = drops
    local bad = ratio >= o.guard_high_ratio or drop_delta >= o.guard_drop_delta
    local good = o.guard_auto_recover and ratio <= o.guard_low_ratio and drop_delta == 0
    publish_guard(ratio, bad and 'pressure' or (good and 'headroom' or 'stable'))

    if bad then
        guard_bad_samples = guard_bad_samples + 1
        guard_good_samples = 0
    elseif good then
        guard_good_samples = guard_good_samples + 1
        guard_bad_samples = 0
    else
        guard_bad_samples = 0
        guard_good_samples = 0
    end

    if guard_bad_samples >= math.max(1, o.guard_bad_samples) then
        if shader_guard_managed and active_variant < #runtime_variants then
            apply_variant(active_variant + 1, 'overload')
        elseif smooth_guard_managed and smooth_active_variant < #smooth_runtime_variants then
            apply_smooth_variant(smooth_active_variant + 1, 'overload')
        end
    elseif o.guard_auto_recover and guard_good_samples >= math.max(1, o.guard_good_samples) then
        if smooth_guard_managed and smooth_active_variant > 1 then
            apply_smooth_variant(smooth_active_variant - 1, 'recovered')
        elseif shader_guard_managed and active_variant > 1 then
            apply_variant(active_variant - 1, 'recovered')
        end
    end
end

schedule_apply = function()
    apply_serial = apply_serial + 1
    local serial = apply_serial
    mp.add_timeout(0.25, function()
        if serial == apply_serial then apply_quality() end
    end)
end

local function set_enhancement_mode(kind, value)
    value = normalize_enhancement_mode(value)
    if kind == 'superres' then
        o.superres_mode = value
        persist_mode_option('superres_mode', value)
    elseif kind == 'smooth' then
        o.smooth_mode = value
        persist_mode_option('smooth_mode', value)
    else
        return
    end
    publish_requested_modes()
    schedule_apply()
    mp.osd_message(string.format('%s：%s',
        kind == 'superres' and '超分' or '补帧', enhancement_mode_labels[value]), 2)
end

local function set_enhancement_profile(superres, smooth, silent)
    superres = normalize_enhancement_mode(superres)
    smooth = normalize_enhancement_mode(smooth)
    local changed = o.superres_mode ~= superres or o.smooth_mode ~= smooth
    o.superres_mode = superres
    o.smooth_mode = smooth
    if changed then
        persist_mode_option('superres_mode', superres)
        persist_mode_option('smooth_mode', smooth)
    end
    publish_requested_modes()
    schedule_apply()
    if tostring(silent or ''):lower() ~= 'silent' then
        mp.osd_message(string.format('视频增强：超分 %s · 补帧 %s',
            enhancement_mode_labels[superres], enhancement_mode_labels[smooth]), 3)
    end
end

local function set_4k_protection(value)
    value = tostring(value or ''):lower()
    local enabled
    if value == 'toggle' then
        enabled = not o.protect_4k_smooth
    elseif value == 'yes' or value == 'on' or value == 'true' or value == '1' then
        enabled = true
    elseif value == 'no' or value == 'off' or value == 'false' or value == '0' then
        enabled = false
    else
        return
    end
    -- Raise the D3D11 surface pool before a live 4K pipeline starts retaining
    -- interpolation frames.  This property change safely rebuilds the decoder.
    local is_4k = last_metrics and
        (last_metrics.w >= 3000 or last_metrics.h >= 1600)
    if not enabled and is_4k then configure_4k_hwdec_pool(true) end
    o.protect_4k_smooth = enabled
    persist_mode_option('protect_4k_smooth', o.protect_4k_smooth and 'yes' or 'no')
    publish_requested_modes()
    schedule_apply()
    if enabled then
        -- First let apply_quality disable 4K interpolation, then shrink back to
        -- the user's original decode-pool setting.
        mp.add_timeout(0.55, function()
            if o.protect_4k_smooth then configure_4k_hwdec_pool(false) end
        end)
    end
    mp.commandv('script-message-to', 'ai_interpolation', 'refresh')
    mp.osd_message(o.protect_4k_smooth
        and '4K 补帧保护：开启（推荐）'
        or '4K 补帧保护：关闭（将按显卡性能尝试）', 3)
end

if o.enabled then
    mp.register_event('file-loaded', function()
        reset_rife_clock_guard()
        schedule_apply()
    end)
    mp.register_script_message('refresh', function()
        publish_shader_capabilities()
        schedule_apply()
    end)
    mp.register_script_message('prepare-rife-ready', function(token)
        -- The RIFE filter is already producing true 2x, but its startup gate is
        -- still holding playback. Apply the final shader/sync budget now so the
        -- first visible frame cannot inherit an over-budget FSRCNNX + high-Hz
        -- display-resample chain.
        apply_serial = apply_serial + 1
        apply_quality()
        if mp.get_property_native(
            'user-data/video-enhancement/rife-spatial-compatible') == 'no' then
            mp.commandv('script-message-to', 'ai_interpolation',
                'rife-spatial-blocked', mp.get_property_native(
                    'user-data/video-enhancement/rife-spatial-detail')
                    or '空间画质不得倒退')
        else
            mp.commandv('script-message-to', 'ai_interpolation',
                'rife-quality-ready', tostring(token or ''))
        end
    end)
    mp.register_script_message('set-superres', function(value)
        set_enhancement_mode('superres', value)
    end)
    mp.register_script_message('set-smooth', function(value)
        set_enhancement_mode('smooth', value)
    end)
    mp.register_script_message('set-profile', set_enhancement_profile)
    mp.register_script_message('set-protect-4k', set_4k_protection)
    mp.register_script_message('rife-clock-safe', function(reason)
        trip_rife_clock_guard(trim(reason) ~= '' and reason
            or '高刷显示对齐超出实时帧预算，当前文件保留 RIFE 真实 2×')
    end)
    mp.register_event('seek', function() reset_guard_window(o.guard_change_cooldown) end)
    mp.register_event('end-file', function()
        guard_managed = false
        shader_guard_managed = false
        smooth_guard_managed = false
        runtime_variants = {{}}
        smooth_runtime_variants = {{enabled = false, algorithm = 'off'}}
        active_variant = 1
        smooth_active_variant = 1
        reset_rife_clock_guard()
        restore_smooth_properties()
        configure_4k_hwdec_pool(false)
        publish_superres_state({}, false, '等待视频')
        publish_smooth_state('等待视频', '等待下一段视频', false)
        publish_rife_spatial_compatibility(nil, '等待下一段视频的空间画质基线')
        publish_guard(0, 'idle')
    end)
    initialize_gpu()
    for _, property in ipairs({
        'display-width',
        'display-height',
        'display-fps',
        'video-out-params/w',
        'video-out-params/h',
        'speed',
        'audio-params',
        'user-data/audio-passthrough/enabled',
        'user-data/video-enhancement/ai-state',
        'user-data/video-enhancement/hq-superres-active',
        'user-data/video-enhancement/hq-spatial-tradeoff',
    }) do
        mp.observe_property(property, 'native', function()
            if mp.get_property_native('vid') then schedule_apply() end
        end)
    end
    local presentation_values = {}
    local function presentation_signature(property, value)
        if property == 'osd-dimensions' and type(value) == 'table' then
            return table.concat({
                tostring(value.w or ''), tostring(value.h or ''),
                tostring(value.ml or ''), tostring(value.mr or ''),
                tostring(value.mt or ''), tostring(value.mb or ''),
            }, 'x')
        end
        return tostring(value)
    end
    for _, property in ipairs({'fullscreen', 'window-maximized', 'osd-dimensions'}) do
        mp.observe_property(property, 'native', function(_, value)
            local signature = presentation_signature(property, value)
            local previous = presentation_values[property]
            presentation_values[property] = signature
            if previous ~= nil and previous ~= signature then
                -- Swapchain recreation and size-dependent shader compilation
                -- are presentation transients, not sustainable render load.
                reset_guard_window(o.guard_change_cooldown)
                reset_rife_clock_guard()
            end
        end)
    end
    if o.performance_guard then
        guard_timer = mp.add_periodic_timer(math.max(0.5, o.guard_interval), monitor_guard)
    end
    if o.rife_clock_guard then
        rife_clock_timer = mp.add_periodic_timer(
            math.max(0.10, o.rife_clock_guard_interval), monitor_rife_clock)
    end
    -- A file passed on the command line can finish loading while the first
    -- PowerShell hardware probe is running. Cover that first-launch race.
    if mp.get_property_native('vid') then schedule_apply() end
else
    publish_shader_capabilities()
    publish_state('disabled', '')
    publish_requested_modes()
    publish_superres_state({}, false, '功能已禁用')
    publish_smooth_state('功能已禁用', '自适应增强脚本已禁用', false)
    publish_rife_spatial_compatibility(true, '自适应着色器未接管，不存在自动空间降级')
    mp.set_property_native('user-data/adaptive-quality/adapter-ready', 'yes')
    mp.commandv('script-message-to', 'startup_window', 'adapter-ready')
end
