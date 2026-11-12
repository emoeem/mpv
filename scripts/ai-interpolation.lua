local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
-- Portable video-enhancement policy and fail-safe manager for mpv-Yaozhi.
-- It never installs Python/VapourSynth system-wide. HDR10/HDR10+ can use a
-- metadata-preserving BT.2020/PQ path. HDR Vivid requires an explicit ordinary
-- HDR-base compatibility choice; Dolby Vision, HLG,
-- optical-disc/ISO, VFR, high-frame-rate and non-1x playback retain a safe
-- fallback. WebDAV/OpenAlist and bitstream audio are supported when the
-- video-only RIFE path can keep the original audio clock.

local mp = require 'mp'
local msg = require 'mp.msg'
local persistence = dofile(mp.command_native({'expand-path', '~~/script-modules/yaozhi-persistence.lua'}))
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    enabled = true,
    backend_mode = 'auto',
    hq_processing_mode = 'native',
    hdr_vivid_mode = 'preserve',
    gpu_id = -1,
    gpu_thread = 1,
    medium_auto_width = 768,
    medium_auto_height = 432,
    medium_quality_width = 854,
    medium_quality_height = 480,
    balanced_quality_width = 640,
    balanced_quality_height = 360,
    high_auto_width = 1280,
    high_auto_height = 720,
    high_quality_width = 1600,
    high_quality_height = 900,
    upper_high_quality_width = 1920,
    upper_high_quality_height = 1080,
    flagship_quality_width = 2560,
    flagship_quality_height = 1440,
    medium_auto_max_fps = 24.5,
    quality_max_fps = 30.5,
    high_auto_max_fps = 30.5,
    source_max_pixels = 2100000,
    vfr_tolerance = 0.018,
    start_delay = 0.35,
    startup_gate = true,
    startup_gate_timeout = 7.0,
    startup_verify_interval = 0.15,
    startup_quality_timeout = 0.8,
    startup_ready_hold = 1.2,
    startup_notice = true,
    background_prepare_timeout = 300,
    auto_enable_prepared = true,
    verify_timeout = 12.0,
    guard_interval = 2.0,
    guard_start_delay = 8.0,
    guard_drop_delta = 3,
    guard_mistimed_delta = 5,
    guard_bad_samples = 2,
    guard_drop_only_bad_samples = 5,
    guard_avsync = 0.20,
    guard_progress_ratio = 0.82,
    guard_presentation_cooldown = 6.0,
    -- Keep older personal configs readable. Runtime graph downgrades and new
    -- learned-cap writes are disabled regardless of these legacy values.
    learning_settle_time = 30.0,
    adaptive_learning = true,
    max_runtime_downgrades = 0,
    show_osd = false,
}
options.read_options(o, 'ai_interpolation')
local schedule_evaluate
local preparation_spec
local on_background_failure
local background
local generation = 0
local prepared_generation = -1
local prepared_backend = nil
local prepared_specs = {}
local prepared_benchmarks = {}
local prepared_device_identities = {}
local prepared_devices = {}
local auto_retry_disabled_specs = {}
local active_auto_key = nil
local canceled_generation = -1
local preparation_watch = nil
-- An exact prepared spec authorizes at most one automatic graph per file.
-- Throughput eligibility is independent of the native sync compatibility policy.
local prepared_auto_pending = nil
local prepared_auto_attempted_generation = -1
local prepared_auto_external_generation = -1
local function invalidate_prepared_auto_pending()
    prepared_auto_pending = nil
end
local function publish_auto_status(value)
    local property = 'user-data/video-enhancement/ai-auto-status'
    if mp.get_property_native(property) ~= value then mp.set_property_native(property, value) end
end
publish_auto_status('idle')
local function positive_finite(value)
    local number = tonumber(value)
    return number and number == number and number > 0 and number < math.huge and number or nil
end
local function probe_verdict(spec, data)
    if data and data.format_supported == false then return 'unsupported' end
    if not data or data.format_supported ~= true then return 'unknown' end
    local measured = positive_finite(data and data.benchmark_fps)
    local reported_target = positive_finite(data and data.required_fps)
    local target = positive_finite(spec.required_fps)
    if not measured or not reported_target or not target
        or math.abs(reported_target-target) > math.max(0.001, target*0.0001) then return 'unknown' end
    if measured < target then return 'insufficient' end
    -- Three times the target remains a conservative diagnostic signal. A
    -- measured real-time graph below that margin can still try once after a stable window.
    return data.auto_safe == true and measured >= target*3 and 'safe' or 'slow'
end
local function preparation_key(spec)
    return table.concat({
        tostring(spec.backend), tostring(spec.runtime), tostring(spec.graph),
        tostring(spec.width), tostring(spec.height), tostring(spec.hdr),
        tostring(spec.user_data), tostring(spec.source_format),
        tostring(spec.buffered_frames), tostring(spec.concurrent_frames),
        string.format('%.3f', tonumber(spec.required_fps) or 0),
        tostring(spec.target_gpu_name), tostring(spec.gpu_id_requested),
    }, '|')
end
local function publish_prepared_device(key)
    local device = prepared_devices[key]
    mp.set_property_native('user-data/video-enhancement/ai-backend-device-ordinal', device and device.ordinal or 'unknown')
    mp.set_property_native('user-data/video-enhancement/ai-backend-device-name', device and device.name or 'unknown')
    mp.set_property_native('user-data/video-enhancement/ai-backend-device-identity', device and device.identity or 'unknown')
end
background = dofile(mp.command_native({'expand-path', '~~/script-modules/ai-background.lua'})).new({
    helper = mp.command_native({'expand-path', '~~/vs/prepare-ai.py'}),
    timeout = math.max(15, math.min(900, o.background_prepare_timeout)),
    key = preparation_key,
    on_start = function(spec)
        preparation_watch = {
            spec=spec, time=mp.get_time(),
            position=mp.get_property_number('time-pos', nil),
            drops=mp.get_property_number('frame-drop-count', 0) or 0,
        }
    end,
    on_ready = function(spec, data)
        preparation_watch = nil
        prepared_generation = generation
        prepared_backend = spec.backend
        local verdict = probe_verdict(spec, data)
        local safe = verdict == 'safe'
        local supported = verdict ~= 'unsupported'
        local key = preparation_key(spec)
        local device = data and data.device
        local identity = type(device) == 'table' and device.identity
        local verified_identity = type(identity) == 'string' and #identity <= 160
            and (identity:match('^uuid:[%w_-]+$') or identity:match('^pci:[%x:.]+$'))
        local ordinal = type(device) == 'table' and tonumber(device.ordinal)
        local resolved = ordinal and ordinal == ordinal and ordinal >= 0
            and ordinal < math.huge and ordinal == math.floor(ordinal)
            and type(device.name) == 'string' and device.name ~= '' and verified_identity
        prepared_device_identities[key] = resolved and identity or nil
        prepared_devices[key] = resolved and {ordinal=ordinal,
            name=device.name:gsub('[%c]', ''):sub(1,160), identity=identity} or nil
        if spec.backend == 'nvidia_hq' and not resolved then verdict='unknown'; safe=false end
        prepared_specs[key] = verdict
        auto_retry_disabled_specs[key] = nil
        local measured = positive_finite(data and data.benchmark_fps) or 0
        local required = positive_finite(spec.required_fps) or 0
        local ratio = required > 0 and measured / required or 0
        prepared_benchmarks[key] = string.format('%.2f / %.2f FPS（%.2f×）',
            measured, required, ratio)
        mp.set_property_native('user-data/video-enhancement/ai-probe',
            prepared_benchmarks[key])
        mp.set_property_native('user-data/video-enhancement/ai-warmup-phase',
            'deferred')
        msg.info(string.format('AI background probe: %.2f fps measured, %.2f fps required, margin %.2fx, format=%s, verdict=%s',
            measured, required, ratio, supported and 'supported' or 'unsupported',
            verdict == 'slow' and 'limited' or verdict))
        mp.set_property_native('user-data/video-enhancement/ai-auto-safe',
            safe and 'yes' or 'no')
        mp.set_property_native('user-data/video-enhancement/ai-probe-verdict',
            verdict == 'slow' and 'limited' or verdict)
        publish_prepared_device(key)
        -- A ready exact spec may make one protected attempt on this file;
        -- native display-clock compatibility is a separate policy.
        if not o.auto_enable_prepared then return false end
        if verdict == 'safe' or verdict == 'slow' then
            if schedule_evaluate then schedule_evaluate(0.05) end
            return safe and 'prepared-auto-pending' or 'prepared-auto-limited'
        end
        return not supported and 'deferred-unsupported'
            or verdict == 'insufficient' and 'deferred-insufficient'
            or verdict == 'unknown' and 'deferred-unknown'
            or safe and 'deferred' or 'deferred-slow'
    end,
    on_failure = function(spec, code)
        preparation_watch = nil
        prepared_benchmarks[preparation_key(spec)] = nil
        prepared_device_identities[preparation_key(spec)] = nil
        prepared_devices[preparation_key(spec)] = nil
        if code ~= 'busy' then prepared_specs[preparation_key(spec)] = 'failed' end
        if on_background_failure then on_background_failure(spec, code) end
    end,
})

local valid_backend_modes = {auto = true, vulkan = true, nvidia_hq = true}
local backend_mode_labels = {
    auto = '智能自动（推荐）',
    vulkan = 'RIFE Vulkan（基础包）',
    nvidia_hq = 'RIFE TensorRT FP16（高端扩展）',
}

local valid_hq_processing_modes = {
    native = true,
    uhd_2k = true,
    ai_superres = true,
}
local hq_processing_mode_labels = {
    native = '原生尺寸安全增强',
    uhd_2k = '4K→2K 高性能补帧',
    ai_superres = 'AnimeJaNai TensorRT AI 超分',
}

local function normalize_backend_mode(value)
    value = tostring(value or ''):lower()
    return valid_backend_modes[value] and value or 'auto'
end

o.backend_mode = normalize_backend_mode(o.backend_mode)

local function normalize_hq_processing_mode(value)
    value = tostring(value or ''):lower()
    return valid_hq_processing_modes[value] and value or 'native'
end

o.hq_processing_mode = normalize_hq_processing_mode(o.hq_processing_mode)

-- Keep source identification separate from processing permission. This is
-- ordinary PQ-base interpolation on the verified gpu-next path, not a Vivid
-- renderer or a promise about the display's eventual HDR/SDR output.
local hdr_policy = {}
function hdr_policy.normalize(value)
    return value == 'hdr10' and 'hdr10' or 'preserve'
end
o.hdr_vivid_mode = hdr_policy.normalize(o.hdr_vivid_mode)
function hdr_policy.source_format()
    local value = mp.get_property('video-params/hw-pixelformat', '')
    if value == '' then value = mp.get_property('video-params/pixelformat', '') end
    return value:lower()
end
function hdr_policy.startup_candidate()
    local format = hdr_policy.source_format()
    return o.hdr_vivid_mode == 'hdr10'
        and mp.get_property('current-vo', '') == 'gpu-next'
        and mp.get_property('video-params/gamma', ''):lower() == 'pq'
        and mp.get_property('video-params/primaries', ''):lower() == 'bt.2020'
        and mp.get_property('video-params/colormatrix', ''):lower() == 'bt.2020-ncl'
        and (format == 'yuv420p10' or format == 'yuv420p10le'
            or format == 'p010' or format == 'p010le')
end
function hdr_policy.startup_status(value, detail)
    for name, text in pairs({['ai-startup-format-state']=value,
        ['ai-startup-format-detail']=detail or ''}) do
        local key = 'user-data/video-enhancement/' .. name
        if mp.get_property_native(key) ~= text then mp.set_property_native(key, text) end
    end
end
function hdr_policy.reset_startup(tracking)
    hdr_policy.tracking = tracking
    hdr_policy.first_frame = false
    hdr_policy.target_vivid = false
    hdr_policy.replanned = false
    hdr_policy.stable_signature = nil
    hdr_policy.stable_since = nil
    hdr_policy.startup_status('idle')
end
function hdr_policy.observe_frame()
    if not hdr_policy.tracking or hdr_policy.first_frame then return end
    local frame = mp.get_property_native('video-frame-info')
    if type(frame) == 'table' and next(frame) ~= nil then
        hdr_policy.first_frame = true
        hdr_policy.stable_since = nil
        if schedule_evaluate then schedule_evaluate(0.05) end
    end
end
function hdr_policy.startup_wait()
    hdr_policy.observe_frame()
    if not hdr_policy.first_frame then
        hdr_policy.startup_status('waiting-frame', '等待真实首帧与 HDR 元数据，当前普通播放')
        return true
    end
    if hdr_policy.target_vivid and not mp.get_property_bool('video-params/hdr-vivid', false) then
        -- An absent per-frame flag during opening must not start a second
        -- ordinary-HDR worker after this file already identified as Vivid.
        hdr_policy.stable_since = nil
        hdr_policy.startup_status('settling', '已识别 HDR Vivid，等待帧元数据稳定，当前普通播放')
        return true
    end
    local signature = table.concat({
        tostring(mp.get_property_number('video-params/w', 0)),
        tostring(mp.get_property_number('video-params/h', 0)),
        hdr_policy.source_format(), mp.get_property('video-params/gamma', ''),
        mp.get_property('video-params/primaries', ''), mp.get_property('video-params/colormatrix', ''),
        tostring(mp.get_property_bool('video-params/hdr-vivid', false)),
        mp.get_property('current-vo', ''),
    }, '|')
    local now = mp.get_time()
    if signature ~= hdr_policy.stable_signature or not hdr_policy.stable_since then
        hdr_policy.stable_signature, hdr_policy.stable_since = signature, now
    end
    local remaining = 0.5 - (now - hdr_policy.stable_since)
    if remaining > 0.001 then
        hdr_policy.startup_status('settling', '正在确认首帧 HDR 格式，稳定后按当前规格准备 AI')
        schedule_evaluate(remaining)
        return true
    end
    hdr_policy.startup_status('ready')
    return false
end
function hdr_policy.check()
    local profile = math.max(
        mp.get_property_number('user-data/media-format/dolby-vision-profile', 0) or 0,
        mp.get_property_number('current-tracks/video/dolby-vision-profile', 0) or 0,
        mp.get_property_number('video-params/dolby-vision-profile', 0) or 0)
    local matrix = mp.get_property('video-params/colormatrix', ''):lower()
    if profile > 0 or matrix == 'dolbyvision' then
        local name = profile > 0 and string.format('Dolby Vision P%d', profile) or 'Dolby Vision'
        local chain = profile == 7 and 'BL/EL（如存在）及 RPU'
            or profile == 5 and 'P5 专属色彩及 RPU' or 'DV 色彩及 RPU'
        return 'dv-protected', name .. ' 暂不启用 AI 补帧：当前链路未适配'
            .. chain .. '；保持原有处理，与显卡性能无关'
    end
    local gamma = mp.get_property('video-params/gamma', ''):lower()
    if gamma == 'hlg' then
        return 'hlg-protected', 'HLG 暂不启用 AI 补帧：当前链路未适配场景光处理，保持原有画质'
    end
    if not mp.get_property_bool('video-params/hdr-vivid', false) then
        if hdr_policy.target_vivid and not hdr_policy.startup_candidate() then
            return 'vivid-unverified', '本片已识别 HDR Vivid，当前色彩或输出参数未通过兼容检查，保持原有处理'
        end
        return 'normal', ''
    end
    if o.hdr_vivid_mode ~= 'hdr10' then
        return 'vivid-protected', 'HDR Vivid 默认不启用 AI 补帧：保持原有处理；可主动选择普通 HDR 基底兼容补帧'
    end
    local format = hdr_policy.source_format()
    local ten_bit = format == 'yuv420p10' or format == 'yuv420p10le'
        or format == 'p010' or format == 'p010le'
    if gamma ~= 'pq' or mp.get_property('video-params/primaries', ''):lower() ~= 'bt.2020'
        or matrix ~= 'bt.2020-ncl' or not ten_bit then
        return 'vivid-unverified', 'HDR Vivid 兼容补帧未启用：需确认 10-bit / PQ / BT.2020-NCL，保持原有处理'
    end
    if mp.get_property('current-vo', '') ~= 'gpu-next' then
        return 'vivid-unverified', 'HDR Vivid 兼容补帧仅验证 gpu-next 输出，当前保持原有处理'
    end
    return 'vivid-hdr10', '按普通 HDR 基底补帧；保留 10-bit / PQ / BT.2020，不应用 Vivid 专属动态映射；最终输出沿显示设置'
end
function hdr_policy.publish()
    local status, detail = hdr_policy.check()
    for name, value in pairs({['hdr-vivid-mode']=o.hdr_vivid_mode,
        ['ai-format-status']=status, ['ai-format-detail']=detail}) do
        local key = 'user-data/video-enhancement/' .. name
        if mp.get_property_native(key) ~= value then mp.set_property_native(key, value) end
    end
end
function hdr_policy.matches(plan)
    local status = hdr_policy.check()
    return plan and (status == 'normal' and not plan.vivid_compat and not hdr_policy.target_vivid
        or status == 'vivid-hdr10' and plan.vivid_compat == true)
end

local extension_root = mp.command_native({
    'expand-path', '~~/experimental/video-enhancement/rife-ncnn-vulkan'
})
local runtime_root = extension_root .. '\\runtime'
local hq_extension_root = mp.command_native({
    'expand-path', '~~/experimental/video-enhancement/rife-nvidia-tensorrt'
})
-- Installed profiles keep optional packs outside replaceable version trees.
-- Retain the portable pack location for existing installations and ZIP users.
local personal_hq_root = mp.command_native({
    'expand-path', '~~/extensions/video-enhancement/rife-nvidia-tensorrt'
})
if utils.file_info(personal_hq_root .. '/extension.conf') then
    hq_extension_root = personal_hq_root
end
local hq_runtime_root = hq_extension_root .. '\\runtime'
local hq_manifest_path = hq_extension_root .. '\\extension.conf'
local hq_superres_model_path = hq_runtime_root
    .. '\\vs-plugins\\models\\superres\\animejanai-v2-l1-x2-fp16.onnx'
local config_path = mp.command_native({'expand-path', '~~/script-opts/ai_interpolation.conf'})
local filter_label = '@yaozhi_ai'
local blocked_generation = -1
local blocked_reason = nil
local blocked_protected = false
local loaded = false
local active = false
-- `active` is published as soon as the graph proves a real 2x output so the
-- downstream shader/display budget can be applied before playback continues.
-- The runtime guard must not consume counters until that handshake and its
-- baseline have actually completed, otherwise graph warm-up drops can be
-- mistaken for sustained overload during a live refresh.
local activation_committed = false
local active_source_fps = 0
local active_plan = nil
-- An installed VF owns the current graph until an explicit policy/geometry
-- transition or a safety fallback.  `active` alone is false during verification.
local graph_state = 'absent'
local graph_signature = nil
local graph_revision = 0
local graph_token = nil
local graph_source_width = 0
local graph_source_height = 0
local graph_smooth_mode = nil
local graph_hq_mode = nil
local state = 'idle'
local evaluate_timer = nil
local evaluate_due_at = nil
local verify_timer = nil
local guard_ready_at = 0
local guard_bad_samples = 0
local guard_drop_only_samples = 0
local last_drops = 0
local last_mistimed = 0
local last_progress_wall = nil
local last_progress_pos = nil
local runtime_environment_backend = nil
local vsscript_preload = nil
local fps_settle_until = 0
local validated_cfr_generation = -1
local validated_source_fps = 0
local startup_gate_owned = false
local startup_gate_timer = nil
local startup_quality_timer = nil
local startup_gate_generation = -1
local cadence_safe_requested = false
local last_publication_key = nil
local seek_recovery = false
local seek_recovery_started = nil
local observed_pause = nil
local startup_ready_release_at = 0
local activation_started_at = 0
local graph_build_seconds = 0
local fail_current_file
local hq_restart_required = false
local hq_driver_incompatible = false
local hq_prepare_failure_generation = -1
local hq_prepare_failure_reason = nil

local function hq_runtime_failure()
    if hq_driver_incompatible then
        return 'NVIDIA 驱动版本低于当前 CUDA 运行库要求；请更新驱动并重启播放器'
    end
    if hq_prepare_failure_generation == generation then
        return hq_prepare_failure_reason or 'TensorRT 后台准备失败'
    end
    return nil
end

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

-- The portable RIFE backend is Vulkan, so native 1080p admission must not be
-- restricted to a small desktop-NVIDIA name whitelist.  GPU names are used
-- only to identify modern GPU families worth trying; startup validation and
-- the live overload guard remain the actual capability test. Legacy non-Arc
-- integrated GPUs and older families keep their measured conservative caps.
local function native_1080_capability(gpu_name, tier)
    if tier ~= 'medium' and tier ~= 'high' then return false, nil end

    local gpu_lower = trim(gpu_name):lower()
    local rtx = tonumber(gpu_lower:match('rtx%s*(%d%d%d%d)'))
    if rtx and gpu_lower:find('nvidia', 1, true) then
        local generation = math.floor(rtx / 1000)
        if generation >= 2 then return true, 'NVIDIA RTX' end
    end

    local rx = tonumber(gpu_lower:match('rx%s*(%d%d%d%d)'))
    if rx and (gpu_lower:find('amd', 1, true)
        or gpu_lower:find('radeon', 1, true)) then
        if rx >= 5000 then return true, 'AMD Radeon RX' end
    end

    if gpu_lower:find('intel', 1, true)
        and gpu_lower:find('arc', 1, true) then
        return true, 'Intel Arc'
    end
    return false, nil
end

local function file_exists(path)
    local file = type(path) == 'string' and io.open(path, 'rb') or nil
    if not file then return false end
    file:close()
    return true
end

local function read_key_value_file(path)
    local result = {}
    local file = type(path) == 'string' and io.open(path, 'rb') or nil
    if not file then return result end
    for line in file:lines() do
        local key, value = line:match('^%s*([%w_.-]+)%s*=%s*(.-)%s*$')
        if key and not key:match('^#') then result[key:lower()] = value end
    end
    file:close()
    return result
end

local function persist_options(changes)
    local ok, err = persistence.update_options(config_path, changes)
    if not ok then
        msg.error('AI 补帧设置未保存，原配置已保留：' .. tostring(err))
        mp.osd_message(i18n.t('AI 补帧设置未保存，已保持原设置'), 4)
    elseif err then msg.warn(tostring(err)) end
    return ok == true
end

local function persist_ai_option(name, value)
    return persist_options({[name] = tostring(value)})
end

local function persist_backend_mode(value)
    return persist_ai_option('backend_mode', value)
end

local function persist_hq_processing_mode(value)
    return persist_ai_option('hq_processing_mode', value)
end

local function learning_cache_path()
    local temp = trim(os.getenv('TEMP') or os.getenv('TMP'))
    -- v7 deliberately ignores v6: the former policy could persist a cap from
    -- the short overload burst immediately after startup or an exact seek.
    -- Only a settled live window may now affect a later file.
    return temp ~= '' and (temp .. '\\mpv_yaozhi_rife_gpu_v7.txt') or nil
end

local function cache_key(gpu, backend)
    return trim(backend):lower() .. '|' .. trim(gpu):lower()
end

local function read_learned_caps()
    local path = learning_cache_path()
    local file = path and io.open(path, 'rb') or nil
    if not file then return {} end
    local machine = trim(file:read('*l')):lower()
    if machine ~= trim(os.getenv('COMPUTERNAME')):lower() then
        file:close()
        return {}
    end
    local caps = {}
    for line in file:lines() do
        local gpu, pixels = line:match('^(.-)\t(%d+)$')
        if gpu and tonumber(pixels) then caps[gpu] = tonumber(pixels) end
    end
    file:close()
    return caps
end

local function write_learned_cap(gpu, backend, pixels, min_pixels)
    if not o.adaptive_learning or trim(gpu) == '' or not learning_cache_path() then return end
    local key = cache_key(gpu, backend)
    pixels = math.max(tonumber(min_pixels) or 0, tonumber(pixels) or 0)
    local caps = read_learned_caps()
    local old = tonumber(caps[key])
    caps[key] = old and math.max(tonumber(min_pixels) or 0, math.min(old, pixels)) or pixels
    local file = io.open(learning_cache_path(), 'wb')
    if not file then return end
    file:write(trim(os.getenv('COMPUTERNAME')), '\n')
    local names = {}
    for name in pairs(caps) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        file:write(name, '\t', tostring(math.floor(caps[name])), '\n')
    end
    file:close()
end

local function apply_learned_cap(gpu, backend, max_width, max_height, min_width, min_height)
    if not o.adaptive_learning then return max_width, max_height, false end
    local cap = tonumber(read_learned_caps()[cache_key(gpu, backend)])
    local pixels = max_width * max_height
    if not cap or cap <= 0 or cap >= pixels then return max_width, max_height, false end
    cap = math.max(cap, math.max(2, min_width) * math.max(2, min_height))
    local scale = math.sqrt(cap / pixels)
    return math.max(min_width, math.floor(max_width * scale / 2) * 2),
        math.max(min_height, math.floor(max_height * scale / 2) * 2), true
end

local function backend_spec(backend)
    if backend == 'nvidia_hq' then
        local plugins = hq_runtime_root .. '\\vs-plugins'
        return {
            id = 'nvidia_hq',
            label = 'RIFE v4.6 · NVIDIA TensorRT FP16',
            runtime_root = hq_runtime_root,
            vsscript_path = hq_runtime_root .. '\\VSScript.dll',
            script = '~~/vs/yaozhi-rife-nvidia-hq.vpy',
            buffered_frames = 8,
            concurrent_frames = 2,
            extra_dll_paths = {plugins, plugins .. '\\vsmlrt-cuda'},
            required_files = {
                hq_runtime_root .. '\\VSScript.dll',
                hq_runtime_root .. '\\python.exe',
                hq_runtime_root .. '\\python3.dll',
                hq_runtime_root .. '\\python314.dll',
                hq_runtime_root .. '\\portable.vs',
                hq_runtime_root .. '\\Lib\\site-packages\\vsmlrt.py',
                plugins .. '\\akarin.dll',
                plugins .. '\\vstrt.dll',
                plugins .. '\\vsmlrt-cuda\\trtexec.exe',
                plugins .. '\\vsmlrt-cuda\\nvinfer_10.dll',
                plugins .. '\\vsmlrt-cuda\\nvinfer_plugin_10.dll',
                plugins .. '\\vsmlrt-cuda\\nvonnxparser_10.dll',
                plugins .. '\\vsmlrt-cuda\\nvinfer_builder_resource_ptx_10.dll',
                plugins .. '\\vsmlrt-cuda\\nvinfer_builder_resource_sm89_10.dll',
                plugins .. '\\vsmlrt-cuda\\nvinfer_builder_resource_sm120_10.dll',
                plugins .. '\\vsmlrt-cuda\\nvrtc64_130_0.dll',
                plugins .. '\\vsmlrt-cuda\\nvrtc-builtins64_130.dll',
                plugins .. '\\vsmlrt-cuda\\cudart64_13.dll',
                plugins .. '\\models\\rife_v2\\rife_v4.6.onnx',
                mp.command_native({'expand-path', '~~/vs/yaozhi-rife-nvidia-hq.vpy'}),
            },
        }
    end
    return {
        id = 'vulkan',
        label = 'RIFE v4.6 · Vulkan',
        runtime_root = runtime_root,
        vsscript_path = runtime_root .. '\\Lib\\site-packages\\vapoursynth\\vsscript.dll',
        script = '~~/vs/yaozhi-rife.vpy',
        buffered_frames = 4,
        concurrent_frames = 1,
        extra_dll_paths = {},
        required_files = {
            runtime_root .. '\\Lib\\site-packages\\vapoursynth\\vsscript.dll',
            runtime_root .. '\\python.exe',
            runtime_root .. '\\python3.dll',
            runtime_root .. '\\python312.dll',
            runtime_root .. '\\libvapoursynth.dll',
            runtime_root .. '\\plugins\\librife.dll',
            runtime_root .. '\\plugins\\MiscFilters.dll',
            runtime_root .. '\\models\\rife-v4.6\\flownet.bin',
            mp.command_native({'expand-path', '~~/vs/yaozhi-rife.vpy'}),
        },
    }
end

local function runtime_ready(backend)
    local spec = backend_spec(backend or 'vulkan')
    for _, path in ipairs(spec.required_files) do
        if not file_exists(path) then return false, path end
    end
    return true
end

local function hq_pack_present()
    -- New packages carry an explicit capability manifest. Keep recognizing the
    -- already-built 2026.08.24 candidate by its VSScript entry point so an
    -- in-place upgrade never turns a valid installation invisible.
    return file_exists(hq_manifest_path)
        or file_exists(hq_runtime_root .. '\\VSScript.dll')
end

local function manifest_has_capability(manifest, capability)
    local capabilities = ',' .. tostring(manifest.capabilities or ''):lower() .. ','
    return capabilities:find(',' .. tostring(capability):lower() .. ',', 1, true) ~= nil
end

local function hq_full_pack_ready(rife_ready, missing, manifest)
    -- Optional inputs are fresh values from this same publication, never a
    -- retained capability cache. Activation callers still probe on demand.
    if rife_ready == nil then rife_ready, missing = runtime_ready('nvidia_hq') end
    if not rife_ready then return false, missing end
    if not file_exists(hq_superres_model_path) then
        return false, hq_superres_model_path
    end
    manifest = manifest or read_key_value_file(hq_manifest_path)
    if not manifest_has_capability(manifest, 'rife-tensorrt-fp16')
        or not manifest_has_capability(manifest, 'superres-tensorrt-fp16')
        or not manifest_has_capability(manifest, 'uhd-2k-rife') then
        return false, hq_manifest_path
    end
    return true
end

local function hq_gpu_support()
    local gpu_name = trim(mp.get_property_native(
        'user-data/adaptive-quality/gpu') or '')
    local gpu_lower = gpu_name:lower()
    local rtx = tonumber(gpu_lower:match('rtx%s*(%d%d%d%d)'))
    local generation_class = rtx and math.floor(rtx / 1000) or 0
    local performance_class = rtx and (rtx % 100) or 0
    local supported = rtx ~= nil
        and gpu_lower:find('nvidia', 1, true) ~= nil
        and (generation_class == 4 or generation_class == 5)
        and performance_class >= 50
    if supported then return true, gpu_name end
    if gpu_name == '' or gpu_name == '检测中' then
        return false, '等待显卡识别'
    end
    if not gpu_lower:find('nvidia', 1, true) or not rtx then
        return false, '当前不是 NVIDIA RTX 显卡'
    end
    return false, '完整依赖仅支持具有配套 TensorRT 架构资源的 RTX 40/50 系列'
end

local function desired_backend()
    if o.backend_mode == 'vulkan' then return 'vulkan' end
    if hq_runtime_failure() then return 'vulkan' end
    local supported = hq_gpu_support()
    local ready = runtime_ready('nvidia_hq')
    if supported and ready then return 'nvidia_hq' end
    return 'vulkan'
end

local hq_publish_timer
local function publish_hq_state(defer_static)
    -- Source safety is synchronous, including late HDR/DV recognition. Only
    -- installation/display work may be coalesced within one event batch.
    hdr_policy.publish()
    if defer_static then
        if not hq_publish_timer then
            hq_publish_timer = mp.add_timeout(0, function()
                hq_publish_timer = nil
                publish_hq_state()
            end)
        end
        return
    end
    if hq_publish_timer then hq_publish_timer:kill(); hq_publish_timer = nil end
    local present = hq_pack_present()
    local vulkan_ready = runtime_ready('vulkan')
    local rife_ready, rife_missing = runtime_ready('nvidia_hq')
    local manifest = read_key_value_file(hq_manifest_path)
    local ready, missing = hq_full_pack_ready(rife_ready, rife_missing, manifest)
    local supported, gpu_reason = hq_gpu_support()
    local version = manifest.version or (present and '兼容旧包' or '')
    local runtime_failure = hq_runtime_failure()
    local status
    if not present then
        status = '未安装'
    elseif not ready then
        local missing_name = tostring(missing or '运行文件'):match('[^\\]+$') or '运行文件'
        status = '安装不完整 · 缺少 ' .. missing_name
    elseif not supported then
        status = '已安装 · ' .. tostring(gpu_reason)
    elseif runtime_failure then
        status = '扩展暂不可用 · ' .. runtime_failure
    elseif hq_restart_required then
        status = '设置已保存 · 重启播放器后切换 VF 后端'
    else
        status = '扩展已就绪'
    end
    mp.set_property_native('user-data/video-enhancement/hq-pack-installed',
        present and 'yes' or 'no')
    mp.set_property_native('user-data/video-enhancement/hq-pack-ready',
        ready and 'yes' or 'no')
    mp.set_property_native('user-data/video-enhancement/hq-rife-ready',
        rife_ready and 'yes' or 'no')
    mp.set_property_native('user-data/video-enhancement/hq-pack-version', version)
    mp.set_property_native('user-data/video-enhancement/hq-gpu-supported',
        supported and 'yes' or 'no')
    mp.set_property_native('user-data/video-enhancement/hq-status', status)
    local capability_code = not present and 'not-installed'
        or not ready and (rife_ready and 'missing-full-dependency' or 'missing-runtime')
        or not supported and 'unsupported-gpu'
        or runtime_failure and (hq_driver_incompatible and 'driver-incompatible' or 'runtime-failure')
        or hq_restart_required and 'restart-required'
        or 'ready'
    local available_backends = {}
    if vulkan_ready then available_backends[#available_backends + 1] = 'vulkan' end
    if rife_ready and supported and not runtime_failure then
        available_backends[#available_backends + 1] = 'nvidia_hq'
    end
    mp.set_property_native('user-data/video-enhancement/hq-capability-code', capability_code)
    mp.set_property_native('user-data/video-enhancement/hq-capability-detail', status)
    mp.set_property_native('user-data/video-enhancement/ai-available-backends',
        #available_backends > 0 and table.concat(available_backends, ',') or 'none')
    mp.set_property_native('user-data/video-enhancement/ai-backend-mode', o.backend_mode)
    mp.set_property_native('user-data/video-enhancement/ai-backend-mode-label',
        backend_mode_labels[o.backend_mode])
    mp.set_property_native('user-data/video-enhancement/hq-processing-mode',
        o.hq_processing_mode)
    mp.set_property_native('user-data/video-enhancement/hq-processing-mode-label',
        hq_processing_mode_labels[o.hq_processing_mode])
    mp.set_property_native('user-data/video-enhancement/ai-backend-restart-required',
        hq_restart_required and 'yes' or 'no')
end

-- VSScript R79 can locate its colocated Python 3.12 runtime by itself.  Only a
-- process-local environment variable is needed; use the wide Windows API so a
-- portable_config path containing CJK characters remains valid.
local ffi_ok, ffi = pcall(require, 'ffi')
local kernel32 = nil
if ffi_ok then
    pcall(function()
        ffi.cdef([[
            int __stdcall MultiByteToWideChar(unsigned int, unsigned long,
                const char *, int, unsigned short *, int);
            int __stdcall SetEnvironmentVariableW(
                const unsigned short *, const unsigned short *);
            int __stdcall SetDllDirectoryW(const unsigned short *);
        ]])
        kernel32 = ffi.load('kernel32')
    end)
end

local function utf8_to_wide(value)
    if not kernel32 then return nil end
    value = tostring(value or '')
    local length = kernel32.MultiByteToWideChar(65001, 0, value, #value, nil, 0)
    if length <= 0 then return nil end
    local buffer = ffi.new('unsigned short[?]', length + 1)
    if kernel32.MultiByteToWideChar(65001, 0, value, #value, buffer, length) <= 0 then
        return nil
    end
    buffer[length] = 0
    return buffer
end

local function set_process_environment(name, value)
    local wide_name = utf8_to_wide(name)
    local wide_value = utf8_to_wide(value)
    return wide_name ~= nil and wide_value ~= nil
        and kernel32.SetEnvironmentVariableW(wide_name, wide_value) ~= 0
end

local function configure_runtime_environment(backend)
    local spec = backend_spec(backend or 'vulkan')
    if runtime_environment_backend then
        -- VSScript embeds one Python runtime in the mpv process. Switching
        -- Python 3.12/3.14 after the DLL was loaded is unsafe; with the HQ pack
        -- installed, all eligible RTX clips consistently choose TensorRT.
        return runtime_environment_backend == spec.id
    end
    local current_path = os.getenv('PATH') or ''
    local runtime_paths = {spec.runtime_root}
    for _, path in ipairs(spec.extra_dll_paths or {}) do runtime_paths[#runtime_paths + 1] = path end
    local runtime_path = table.concat(runtime_paths, ';')
        .. (current_path ~= '' and (';' .. current_path) or '')
    local wide_runtime = utf8_to_wide(spec.runtime_root)
    local configured = set_process_environment('VSSCRIPT_PATH', spec.vsscript_path)
        and (spec.id ~= 'nvidia_hq'
            or set_process_environment('YAOZHI_RIFE_NVIDIA_RUNTIME', spec.runtime_root))
        and set_process_environment('PYTHONNOUSERSITE', '1')
        and set_process_environment('PYTHONDONTWRITEBYTECODE', '1')
        and set_process_environment('PATH', runtime_path)
        and wide_runtime ~= nil
        and kernel32.SetDllDirectoryW(wide_runtime) ~= 0
    if configured then
        local loaded_ok, library = pcall(ffi.load, spec.vsscript_path, true)
        configured = loaded_ok and library ~= nil
        if configured then
            vsscript_preload = library
            runtime_environment_backend = spec.id
        else
            msg.error('VSScript preload failed: ' .. tostring(library))
        end
    end
    return configured
end

local function cancel_timer(timer)
    if timer then timer:kill() end
end

local function release_startup_gate(reason)
    cancel_timer(startup_gate_timer)
    startup_gate_timer = nil
    if not startup_gate_owned then return end
    startup_gate_owned = false
    if mp.get_property_bool('pause', false) then
        msg.info('RIFE startup gate released: ' .. tostring(reason or 'ready'))
        mp.set_property_bool('pause', false)
        if o.startup_notice then
            local ready = tostring(reason or ''):find('AI ready', 1, true) ~= nil
            local spatial = active_plan and active_plan.pipeline_kind == 'superres'
            mp.osd_message(ready
                and (spatial and i18n.t('TensorRT AI 超分已就绪，正在自动播放')
                    or i18n.t('RIFE AI 2× 已就绪，正在自动播放'))
                or i18n.t('视频增强预热已结束，正在恢复播放'), 1.8)
        end
    end
end

local function acquire_startup_gate(plan)
    -- Background preparation has already evaluated real output frames. When
    -- the user enables it during playback, keep the clock running: pausing here
    -- freezes estimated-vf-fps on the old stream history and cannot prove 2x.
    -- Verification and the runtime guard still reject an unready/slow graph.
    if background.approved or (o.auto_enable_prepared
        and generation > prepared_generation
        and prepared_backend == plan.backend) then return end
    if not o.startup_gate or startup_gate_generation == generation then return end
    -- One warm-up gate per file is enough. Repeated explicit mode changes must
    -- not repeatedly interrupt playback, and an existing user pause already gives
    -- VapourSynth a safe window without transferring pause ownership to us.
    startup_gate_generation = generation
    if mp.get_property_bool('pause', false) then return end
    startup_gate_owned = true
    mp.set_property_bool('pause', true)
    msg.info('RIFE startup gate acquired')
    if o.startup_notice then
        mp.osd_message(i18n.t('AI 视频增强正在安全预热…\n完成后将自动继续播放，无需手动操作\n首次建模稍慢，同规格后续会复用本机缓存'), 30)
    end
end

local function arm_startup_gate_timeout()
    if not startup_gate_owned then return end
    cancel_timer(startup_gate_timer)
    local serial = graph_token
    startup_gate_timer = mp.add_timeout(math.max(1, o.startup_gate_timeout), function()
        startup_gate_timer = nil
        if serial ~= graph_token or not loaded or not startup_gate_owned then return end
        -- Never let an unfinished VapourSynth graph continue warming up after
        -- playback resumes. That produces the visible slow-motion/fast-catchup
        -- sequence this gate exists to prevent. A slow machine safely falls
        -- back for this file; the next file gets a clean retry.
        if fail_current_file then
            fail_current_file('AI 预热超时；为避免先慢后快已安全回退')
        else
            release_startup_gate('timeout')
        end
    end)
end

local function audio_is_passthrough()
    local format = mp.get_property('audio-out-params/format', ''):lower()
    if format == '' then format = mp.get_property('audio-params/format', ''):lower() end
    return format:find('spdif-', 1, true) == 1 or format:find('iec61937', 1, true) ~= nil
end

local function mode()
    local value = trim(mp.get_property_native(
        'user-data/video-enhancement/smooth-mode') or 'off'):lower()
    if value == 'off' or value == 'auto' or value == 'performance' or value == 'quality' then
        return value
    end
    return 'off'
end


local function hq_processing_requested(kind)
    if o.hq_processing_mode ~= kind then return false end
    local full_ready = hq_full_pack_ready()
    local supported = hq_gpu_support()
    return full_ready and supported and desired_backend() == 'nvidia_hq'
end

local function format_fps(value)
    value = tonumber(value) or 0
    if value <= 0 then return '未知' end
    local rounded = math.floor(value + 0.5)
    return math.abs(value - rounded) < 0.01 and tostring(rounded)
        or string.format('%.3f', value):gsub('0+$', ''):gsub('%.$', '')
end

local function bounded_dimensions(width, height, max_width, max_height)
    local scale = math.min(1, max_width / width, max_height / height)
    return math.max(2, math.floor(width * scale / 2) * 2),
        math.max(2, math.floor(height * scale / 2) * 2)
end

local function spatial_quality_regresses(source_width, source_height,
        inference_width, inference_height)
    return (tonumber(inference_width) or 0) < (tonumber(source_width) or 0)
        or (tonumber(inference_height) or 0) < (tonumber(source_height) or 0)
end

local function spatial_quality_reason(source_width, source_height,
        inference_width, inference_height)
    return string.format(
        '空间画质不得倒退：当前 RIFE 原生片源安全上限为 %d×%d，片源 %d×%d 已超出；不降采样，已保留源分辨率与原有超分质量',
        tonumber(inference_width) or 0, tonumber(inference_height) or 0,
        tonumber(source_width) or 0, tonumber(source_height) or 0)
end

local function refresh_native_fallback()
    mp.commandv('script-message-to', 'adaptive_quality', 'refresh')
end

local function set_native_if_changed(name, value)
    if mp.get_property_native(name) == value then return false end
    mp.set_property_native(name, value)
    return true
end

local function ai_safety_limit_label(selected_mode)
    if not o.enabled then return 'AI 扩展已关闭' end
    if selected_mode == 'off' then return '补帧已关闭 · 开启后按显卡与策略显示' end
    if selected_mode == 'performance' then return '性能优先不使用 RIFE AI' end
    if mp.get_property_native('user-data/adaptive-quality/adapter-ready') ~= 'yes' then
        return '等待显卡与策略检测'
    end

    if hq_processing_requested('uhd_2k') then
        return '完整依赖显式性能档：4K 可等比降至≤2560×1440 后 RIFE 2×'
    elseif hq_processing_requested('ai_superres') then
        return '完整依赖 AI 超分：SDR ≤1920×1080，AnimeJaNai x2'
    end

    local tier = trim(mp.get_property_native(
        'user-data/adaptive-quality/tier') or 'balanced')
    if tier == 'low' then return '入门显卡使用原生轻量平滑' end
    if selected_mode == 'auto' and tier == 'balanced' then
        return '均衡显卡自动档使用原生轻量平滑'
    end

    local gpu_name = trim(mp.get_property_native(
        'user-data/adaptive-quality/gpu') or '')
    local gpu_lower = gpu_name:lower()
    local desktop_gpu = not gpu_lower:find('laptop', 1, true)
        and not gpu_lower:find('max%-q')
    local rtx = tonumber(gpu_lower:match('rtx%s*(%d%d%d%d)'))
    local generation_class = rtx and math.floor(rtx / 1000) or 0
    local performance_class = rtx and (rtx % 100) or 0
    local native_1080_capable = native_1080_capability(gpu_name, tier)

    local max_fps = o.quality_max_fps
    local max_width, max_height = o.balanced_quality_width, o.balanced_quality_height
    if tier == 'high' then
        max_width = selected_mode == 'quality' and o.high_quality_width or o.high_auto_width
        max_height = selected_mode == 'quality' and o.high_quality_height or o.high_auto_height
        if selected_mode == 'auto' then max_fps = o.high_auto_max_fps end
    elseif tier == 'medium' then
        max_width = selected_mode == 'quality' and o.medium_quality_width or o.medium_auto_width
        max_height = selected_mode == 'quality' and o.medium_quality_height or o.medium_auto_height
        if selected_mode == 'auto' then max_fps = o.medium_auto_max_fps end
    end

    if selected_mode == 'quality' and tier == 'high' and desktop_gpu then
        if generation_class >= 4 and performance_class >= 90 then
            max_width = math.max(max_width, o.flagship_quality_width)
            max_height = math.max(max_height, o.flagship_quality_height)
        elseif generation_class >= 4 and performance_class >= 80 then
            max_width = math.max(max_width, o.upper_high_quality_width)
            max_height = math.max(max_height, o.upper_high_quality_height)
        end
    end

    if native_1080_capable then
        max_width = math.max(max_width, o.upper_high_quality_width)
        max_height = math.max(max_height, o.upper_high_quality_height)
        max_fps = math.max(max_fps, o.quality_max_fps)
    end

    local display_fps = math.max(1, math.floor(max_fps + 0.001))
    local protect_4k = mp.get_property_native(
        'user-data/video-enhancement/protect-4k') ~= 'no'
    if protect_4k and (max_width * max_height > o.source_max_pixels
        or math.max(max_width, max_height) > 1920) then
        return string.format(
            '保护开启：≤1920×1080 / %dfps；关闭后≤%d×%d',
            display_fps, max_width, max_height)
    end
    return string.format('原生源≤%d×%d / %dfps · %s超出不降采样',
        max_width, max_height, display_fps,
        native_1080_capable and '实时验证，过载自动回退 · ' or '')
end

local function publish_ai_safety_limit(selected_mode)
    set_native_if_changed('user-data/video-enhancement/ai-safety-limit',
        ai_safety_limit_label(selected_mode))
end

local function publish_seek_recovery(recovering, detail)
    seek_recovery = recovering == true
    if not seek_recovery then seek_recovery_started = nil end
    set_native_if_changed('user-data/video-enhancement/ai-seek-state',
        seek_recovery and 'recovering' or 'idle')
    set_native_if_changed('user-data/video-enhancement/ai-seek-detail',
        seek_recovery and (detail or '正在精准定位并恢复 AI 帧窗口') or '')
end

local function classify_ai_reason(new_state, detail, temporal_active, superres_active)
    local text = tostring(detail or '')
    if temporal_active then return 'active-rife' end
    if superres_active then return 'active-ai-superres' end
    if new_state == 'off' then return 'user-disabled' end
    if text:find('配套', 1, true) or text:find('设备模块', 1, true) then return 'device-contract-mismatch' end
    if text:find('CUDA 运行库', 1, true) then return 'driver-incompatible' end
    if new_state == 'detecting' or text:find('等待', 1, true) then return 'detecting' end
    if new_state == 'unavailable' or text:find('运行库', 1, true)
        or text:find('VSScript', 1, true) or text:find('缺少', 1, true) then
        return 'missing-dependency'
    end
    if text:find('Dolby Vision', 1, true) or text:find('EL/FEL', 1, true) then
        return 'dolby-vision-guard'
    end
    if text:find('HDR', 1, true) or text:find('HLG', 1, true)
        or text:find('BT.2020', 1, true) or text:find('Vivid', 1, true) then
        return 'hdr-guard'
    end
    if text:find('空间画质', 1, true) then return 'spatial-quality-guard' end
    if text:find('4K', 1, true) then return 'uhd-guard' end
    if text:find('VFR', 1, true) then return 'vfr-guard' end
    if text:find('帧率', 1, true) or text:find('fps', 1, true) then return 'fps-guard' end
    if text:find('倍速', 1, true) or text:find('播放速度', 1, true) then return 'speed-guard' end
    if text:find('ISO', 1, true) or text:find('蓝光', 1, true)
        or text:find('DVD', 1, true) or text:find('归档', 1, true)
        or text:find('图片', 1, true) then
        return 'media-guard'
    end
    if text:find('过载', 1, true) or text:find('丢帧', 1, true)
        or text:find('mistimed', 1, true) or text:find('超时', 1, true) then
        return 'runtime-overload'
    end
    if new_state == 'native' then return 'native-fallback' end
    if new_state == 'failed' then return 'runtime-failure' end
    if new_state == 'protected' then return 'policy-guard' end
    return 'idle'
end

local function publish(new_state, effective, detail, is_active)
    state = new_state
    active = is_active == true
    local gpu = mp.get_property_native('user-data/adaptive-quality/gpu') or '检测中'
    local ready = (runtime_ready('vulkan') or runtime_ready('nvidia_hq')) and 'yes' or 'no'
    local temporal_active = active and active_plan ~= nil
        and active_plan.temporal ~= false
    local superres_active = active and active_plan ~= nil
        and active_plan.pipeline_kind == 'superres'
    local hdr_compat_active = temporal_active and active_plan.vivid_compat == true
    set_native_if_changed('user-data/video-enhancement/ai-hdr-compat-active',
        hdr_compat_active and 'yes' or 'no')
    local active_label = temporal_active and 'yes' or 'no'
    local effective_label = effective or '关闭'
    local detail_label = detail or effective or '关闭'
    local source_fps = temporal_active and active_source_fps or 0
    local result_fps = temporal_active
        and active_source_fps * (active_plan.fps_multiplier or 2) or 0
    local requested_smooth = mode()
    local effective_backend = active_plan and tostring(active_plan.backend or 'unknown')
        or new_state == 'native' and 'mpv-native'
        or 'none'
    local reason_code = classify_ai_reason(
        new_state, detail_label, temporal_active, superres_active)
    local publication_key = table.concat({
        state, active_label, effective_label, detail_label, tostring(gpu), ready,
        tostring(source_fps), tostring(result_fps), superres_active and 'yes' or 'no',
        active_plan and tostring(active_plan.pipeline_kind or 'rife') or 'none',
        o.backend_mode, o.hq_processing_mode, tostring(requested_smooth),
        effective_backend, reason_code, hdr_compat_active and 'hdr10' or 'original',
    }, '\31')
    if publication_key == last_publication_key then return false end
    last_publication_key = publication_key
    set_native_if_changed('user-data/video-enhancement/ai-state', state)
    set_native_if_changed('user-data/video-enhancement/ai-active', active_label)
    set_native_if_changed('user-data/video-enhancement/ai-effective', effective_label)
    set_native_if_changed('user-data/video-enhancement/ai-detail', detail_label)
    set_native_if_changed('user-data/video-enhancement/ai-requested-backend', o.backend_mode)
    set_native_if_changed('user-data/video-enhancement/ai-requested-processing',
        o.hq_processing_mode)
    set_native_if_changed('user-data/video-enhancement/ai-requested-smooth-mode',
        tostring(requested_smooth))
    set_native_if_changed('user-data/video-enhancement/ai-effective-backend',
        effective_backend)
    set_native_if_changed('user-data/video-enhancement/ai-reason-code', reason_code)
    set_native_if_changed('user-data/video-enhancement/ai-reason-detail', detail_label)
    local backend_label = active_plan and active_plan.backend_label
        or (runtime_ready('nvidia_hq') and 'RIFE v4.6 · Vulkan / NVIDIA TensorRT 可选' or 'RIFE v4.6 · Vulkan')
    set_native_if_changed('user-data/video-enhancement/ai-backend', backend_label)
    set_native_if_changed('user-data/video-enhancement/ai-gpu', gpu)
    set_native_if_changed('user-data/video-enhancement/ai-ready', ready)
    set_native_if_changed('user-data/video-enhancement/ai-source-fps', source_fps)
    set_native_if_changed('user-data/video-enhancement/ai-result-fps', result_fps)
    set_native_if_changed('user-data/video-enhancement/hq-superres-active',
        superres_active and 'yes' or 'no')
    set_native_if_changed('user-data/video-enhancement/hq-superres-detail',
        superres_active and detail_label or '')
    set_native_if_changed('user-data/video-enhancement/hq-spatial-tradeoff',
        active and active_plan and active_plan.allow_spatial_tradeoff and 'explicit' or 'none')
    set_native_if_changed('user-data/video-enhancement/hq-pipeline-kind',
        active and active_plan and tostring(active_plan.pipeline_kind or 'rife') or 'none')
    set_native_if_changed('user-data/video-enhancement/ai-spatial-protection',
        new_state == 'protected'
            and detail_label:find('空间画质不得倒退', 1, true) ~= nil
            and 'protected' or 'clear')
    publish_hq_state()
    refresh_native_fallback()
    return true
end

local function filter_present()
    return tostring(mp.get_property('vf', '')):find(filter_label, 1, true) ~= nil
end

local function remove_filter()
    cancel_timer(verify_timer)
    verify_timer = nil
    cancel_timer(startup_quality_timer)
    startup_quality_timer = nil
    startup_ready_release_at = 0
    activation_committed = false
    publish_seek_recovery(false)
    release_startup_gate('filter removed')
    local had_filter = filter_present()
    if had_filter then pcall(mp.commandv, 'vf', 'remove', filter_label) end
    if had_filter then fps_settle_until = mp.get_time() + 2.5 end
    graph_state = 'absent'
    graph_signature = nil
    graph_token = nil
    set_native_if_changed('user-data/video-enhancement/ai-graph-token', '')
    graph_source_width, graph_source_height = 0, 0
    graph_smooth_mode, graph_hq_mode = nil, nil
    active = false
    active_source_fps = 0
    active_plan = nil
end

local function selected_video_is_image()
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'video' and track.selected and track.image then return true end
    end
    return false
end

local function protected_path()
    local raw_path = trim(mp.get_property('path', '')):lower()
    if raw_path == '' then return '等待文件路径', true, false end
    if raw_path:find('bd://', 1, true) == 1 or raw_path:find('dvd://', 1, true) == 1 then
        return 'ISO / 蓝光 / DVD 不启用 AI 补帧', false, false
    end
    local archive_inner = mp.get_property_native('user-data/alist/archive-inner')
    if archive_inner == true or archive_inner == 'yes' or archive_inner == '1'
        or raw_path:find('archive://', 1, true) == 1
        or raw_path:find('alist%-archive://') == 1 then
        return '顺序归档流不启用 AI 补帧', false, true
    end
    local path = raw_path:gsub('/', '\\')
    if path:match('%.iso[%?#]?$') or path:find('\\bdmv\\', 1, true)
        or path:find('\\video_ts\\', 1, true) then
        return 'ISO / 蓝光 / DVD 不启用 AI 补帧', false, false
    end
    return nil, false, raw_path:find('://', 1, true) ~= nil
end

local function plan_for_current_video(ignore_filtered_fps)
    local selected_mode = mode()
    local wants_hq_superres = o.hq_processing_mode == 'ai_superres'
    local wants_uhd_2k = o.hq_processing_mode == 'uhd_2k'
    local hq_failure = hq_runtime_failure()
    publish_ai_safety_limit(selected_mode)
    if not o.enabled then return nil, 'AI 扩展已关闭', false end
    if selected_mode == 'off' and not wants_hq_superres then
        return nil, '用户已关闭补帧', false
    end
    if selected_mode == 'performance' and not wants_hq_superres then
        return nil, '性能优先使用 mpv 原生平滑', false
    end

    if mp.get_property_native('user-data/adaptive-quality/adapter-ready') ~= 'yes' then
        return nil, '等待显卡检测', true
    end
    if (wants_hq_superres or wants_uhd_2k) and not hq_full_pack_ready() then
        return nil, '完整超分补帧依赖包未就绪，已保持内置兼容方案', false
    end
    if (wants_hq_superres or wants_uhd_2k) and not hq_gpu_support() then
        return nil, '当前显卡未进入完整依赖高性能方案验证范围', false
    end
    if hq_failure and (wants_hq_superres or runtime_environment_backend == 'nvidia_hq') then
        return nil, hq_failure, false
    end

    local path_reason, transient, remote_source = protected_path()
    if path_reason then return nil, path_reason, transient end
    if selected_video_is_image() then return nil, '图片不启用 AI 补帧', false end

    local speed = mp.get_property_number('speed', 1) or 1
    if speed < 0.96 or speed > 1.04 then return nil, '倍速播放自动回退', false end
    if mp.get_property_bool('seeking', false) then return nil, '等待跳转完成', true end

    local format_status, format_detail = hdr_policy.check()
    if format_status ~= 'normal' and format_status ~= 'vivid-hdr10' then
        return nil, format_detail, false
    end
    local vivid_compat = format_status == 'vivid-hdr10'
    local gamma = mp.get_property('video-params/gamma', ''):lower()
    local primaries = mp.get_property('video-params/primaries', ''):lower()
    if primaries == 'bt.2020' and gamma ~= 'pq' then
        return nil, 'BT.2020 广色域保持原始色彩链', false
    end
    local colormatrix = mp.get_property('video-params/colormatrix', ''):lower()
    if gamma == 'pq' and colormatrix ~= 'bt.2020-ncl' then
        -- Falling through to the HD/SD heuristic would feed PQ code values
        -- through a BT.709/601 matrix and can visibly corrupt HDR colours.
        return nil, 'HDR10 色彩矩阵未稳定，保持原始色彩链', false
    end
    local matrix_id = gamma == 'pq' and colormatrix == 'bt.2020-ncl' and 3
        or colormatrix == 'bt.709' and 1
        or (colormatrix == 'bt.601' or colormatrix == 'bt.470bg'
            or colormatrix == 'smpte-170m') and 2
        or 0

    local w = mp.get_property_number('video-params/w', 0) or 0
    local h = mp.get_property_number('video-params/h', 0) or 0
    if w <= 0 or h <= 0 then return nil, '等待视频参数', true end
    if hq_failure and wants_uhd_2k and (w > 2560 or h > 1440) then
        return nil, hq_failure .. '；4K→2K 方案已安全停用', false
    end
    -- Dolby Vision, HLG and non-opted-in HDR Vivid were rejected above. PQ +
    -- BT.2020-NCL source is HDR10/HDR10+ and can use the explicit 2K motion
    -- inference path: authored HDR frames stay source-native while generated
    -- middle frames are restored to source geometry with copied frame props.
    local explicit_uhd_2k = wants_uhd_2k and desired_backend() == 'nvidia_hq'
        and (gamma ~= 'pq' or matrix_id == 3) and (w > 2560 or h > 1440)
    local protect_4k = mp.get_property_native(
        'user-data/video-enhancement/protect-4k') ~= 'no'
    if protect_4k and not explicit_uhd_2k
        and (w * h > o.source_max_pixels or math.max(w, h) > 1920) then
        return nil, '超过 1080p，保持硬解与原始画质', false
    end
    if mp.get_property_bool('video-frame-info/interlaced', false) then
        return nil, '隔行片源保持原始处理链', false
    end

    local container_fps = mp.get_property_number('container-fps', 0) or 0
    local estimated_fps = mp.get_property_number('estimated-vf-fps', 0) or 0
    local reuse_validated_cfr = not ignore_filtered_fps
        and validated_cfr_generation == generation and validated_source_fps > 0
    if not ignore_filtered_fps and not reuse_validated_cfr and estimated_fps <= 0 then
        return nil, '等待 CFR 帧率确认', true
    end
    local source_fps = ignore_filtered_fps and active_source_fps
        or reuse_validated_cfr and validated_source_fps
        or estimated_fps
    if source_fps <= 0 then source_fps = container_fps end
    if container_fps <= 0 or source_fps <= 0 then return nil, '等待 CFR 帧率确认', true end
    if not ignore_filtered_fps and not reuse_validated_cfr and estimated_fps > 0
        and math.abs(estimated_fps - container_fps) / container_fps > o.vfr_tolerance then
        if mp.get_time() < fps_settle_until then
            return nil, '等待滤镜帧率稳定', true
        end
        return nil, '检测到 VFR 风险，已回退', false
    end

    local tier = trim(mp.get_property_native('user-data/adaptive-quality/tier') or 'balanced')
    local gpu_name = trim(mp.get_property_native('user-data/adaptive-quality/gpu') or '')
    local gpu_requested = tonumber(o.gpu_id) or -1
    if gpu_requested ~= gpu_requested or math.abs(gpu_requested) == math.huge then gpu_requested=-1 end
    gpu_requested = math.max(-1, math.floor(gpu_requested))
    local gpu_index = gpu_requested
    if gpu_index < 0 then
        gpu_index = tonumber(mp.get_property_native('user-data/adaptive-quality/gpu-index')) or -1
    end
    if gpu_index < 0 and (runtime_environment_backend or desired_backend()) ~= 'nvidia_hq' then
        return nil, '无法绑定目标显卡，已回退', false
    end
    if tier == 'low' then return nil, '入门显卡保持轻量平滑', false end
    if selected_mode == 'auto' and tier == 'balanced' then
        return nil, '均衡显卡自动档保持轻量平滑', false
    end

    local gpu_lower = gpu_name:lower()
    local desktop_gpu = not gpu_lower:find('laptop', 1, true)
        and not gpu_lower:find('max%-q')
    local rtx = tonumber(gpu_lower:match('rtx%s*(%d%d%d%d)'))
    local generation_class = rtx and math.floor(rtx / 1000) or 0
    local performance_class = rtx and (rtx % 100) or 0
    local native_1080_capable, native_1080_family =
        native_1080_capability(gpu_name, tier)

    local max_fps = o.quality_max_fps
    local max_width, max_height = o.balanced_quality_width, o.balanced_quality_height
    local min_width, min_height = 640, 360
    if tier == 'high' then
        max_width = selected_mode == 'quality' and o.high_quality_width or o.high_auto_width
        max_height = selected_mode == 'quality' and o.high_quality_height or o.high_auto_height
        if selected_mode == 'auto' then max_fps = o.high_auto_max_fps end
    elseif tier == 'medium' then
        max_width = selected_mode == 'quality' and o.medium_quality_width or o.medium_auto_width
        max_height = selected_mode == 'quality' and o.medium_quality_height or o.medium_auto_height
        if selected_mode == 'auto' then max_fps = o.medium_auto_max_fps end
    end
    local flagship_quality = false
    if selected_mode == 'quality' and tier == 'high' and desktop_gpu then
        if generation_class >= 4 and performance_class >= 90 then
            flagship_quality = true
            max_width = math.max(max_width, o.flagship_quality_width)
            max_height = math.max(max_height, o.flagship_quality_height)
            -- RTX 4090/5090 quality mode means 2K-class inference. If this
            -- cannot run in real time, return to native smoothing instead of
            -- degrading through 1720p/1410p to a visibly blurred ~1K graph.
            min_width, min_height = max_width, max_height
        elseif generation_class >= 4 and performance_class >= 80 then
            max_width = math.max(max_width, o.upper_high_quality_width)
            max_height = math.max(max_height, o.upper_high_quality_height)
            min_width, min_height = max_width, max_height
        end
    end
    if explicit_uhd_2k then
        -- This is the only policy that may intentionally reduce spatial samples.
        -- It mirrors the verified reference graph's H_Pre=1440 contract and is
        -- never selected by the portable/default path.
        max_width, max_height = o.flagship_quality_width, o.flagship_quality_height
        min_width, min_height = max_width, max_height
    end
    -- Modern NVIDIA RTX, AMD Radeon RX and Intel Arc adapters may attempt a
    -- native-size 1080p graph.  The old desktop-NVIDIA/super-resolution-off
    -- exception rejected many capable GPUs before VapourSynth was even tried.
    -- This is admission, not a performance claim: the graph must still pass
    -- startup validation and sustained drop/mistimed/A-V/progress guards.
    -- Pinning the quality floor to the exact source also guarantees that
    -- learning or a runtime downgrade can never turn this into a blurry
    -- 1080p -> 720p -> display path.
    local native_1080_trial = native_1080_capable
        and math.max(w, h) <= math.max(o.upper_high_quality_width,
            o.upper_high_quality_height)
        and math.min(w, h) <= math.min(o.upper_high_quality_width,
            o.upper_high_quality_height)
    if native_1080_trial then
        max_width = math.max(max_width, o.upper_high_quality_width)
        max_height = math.max(max_height, o.upper_high_quality_height)
        max_fps = math.max(max_fps, o.quality_max_fps)
    end
    if source_fps > max_fps then
        return nil, string.format('%sfps 超出当前显卡 AI 安全范围', format_fps(source_fps)), false
    end
    -- VSScript embeds one Python runtime per mpv process. A backend preference
    -- changed after the first graph has loaded is persisted for the next
    -- process, while the current process keeps its already-initialized runtime.
    -- This prevents a live Python 3.12/3.14 swap from corrupting the VF chain.
    local backend = runtime_environment_backend or desired_backend()
    -- Windows/WMI adapter order is not CUDA device order. The NVIDIA graph
    -- resolves an automatic request by exact target name inside CUDA itself.
    if backend == 'nvidia_hq' then gpu_index = gpu_requested end
    local spec = backend_spec(backend)
    local ready, missing = runtime_ready(backend)
    if not ready then
        msg.warn('RIFE runtime is incomplete: ' .. tostring(missing))
        return nil, 'RIFE 运行库不完整，已回退', false
    end
    if not kernel32 then return nil, '无法初始化便携 VSScript，已回退', false end
    if not ignore_filtered_fps and not reuse_validated_cfr then
        validated_cfr_generation = generation
        validated_source_fps = source_fps
    end

    if wants_hq_superres then
        if backend ~= 'nvidia_hq' then
            return nil, 'AI 超分需要完整 NVIDIA TensorRT 依赖包；当前保持 GLSL 画质链', false
        end
        if gamma == 'pq' or primaries == 'bt.2020' then
            return nil, 'AI 超分当前仅处理 SDR；HDR 保持原始色彩与元数据链', false
        end
        if w > 1920 or h > 1200 then
            return nil, string.format(
                'AI 超分输入上限为 1920×1200；当前 %d×%d 保持原始空间链', w, h), false
        end
        local display_width = mp.get_property_number('display-width', 0) or 0
        local display_height = mp.get_property_number('display-height', 0) or 0
        if display_width <= 0 or display_height <= 0 then
            return nil, '等待显示尺寸以规划 AI 超分输出', true
        end
        local scale = math.min(2, display_width / w, display_height / h)
        if scale < 1.12 then
            return nil, '当前显示尺寸无需 AI 放大，保留原始画质链', false
        end
        local output_width = math.max(2, math.floor(w * scale / 2) * 2)
        local output_height = math.max(2, math.floor(h * scale / 2) * 2)
        return {
            fps = source_fps,
            fps_multiplier = 1,
            temporal = false,
            pipeline_kind = 'superres',
            gpu_id = gpu_index,
            max_width = w,
            max_height = h,
            min_width = w,
            min_height = h,
            gpu_thread = performance_class >= 80 and 2 or 1,
            tier = tier,
            gpu_name = gpu_name,
            source_width = w,
            source_height = h,
            inference_width = w,
            inference_height = h,
            output_width = output_width,
            output_height = output_height,
            matrix_id = matrix_id,
            backend = backend,
            backend_label = 'AnimeJaNai V2 L1 x2 · NVIDIA TensorRT FP16',
            script = spec.script,
            buffered_frames = 4,
            concurrent_frames = 2,
            superres_model = hq_superres_model_path,
            learned = false,
            remote_source = remote_source,
            hdr_pq = false,
        }, nil, false
    end

    if h > w then
        max_width, max_height = max_height, max_width
        min_width, min_height = min_height, min_width
    end
    if native_1080_trial then
        min_width, min_height = w, h
    end
    local learned
    if explicit_uhd_2k then
        -- The explicit 2K contract is fixed and never inherits an older learned
        -- native cap. Real overload falls back instead of silently reducing the
        -- user-approved quality floor.
        learned = false
    elseif native_1080_trial then
        -- A stale conservative cap must not veto the new per-file capability
        -- trial, and there is no legal lower native size to learn here.
        learned = false
    else
        max_width, max_height, learned = apply_learned_cap(
            gpu_name, backend, max_width, max_height, min_width, min_height)
    end

    local inference_width, inference_height = bounded_dimensions(
        w, h, max_width, max_height)

    -- Portable/native hard red line: neither quality mode, GPU learning nor a
    -- backend branch may feed RIFE fewer samples than the decoded source. The
    -- only exception is the complete-pack `uhd_2k` policy selected explicitly
    -- by the user. For HDR10/HDR10+, only generated motion frames use the 2K
    -- inference canvas; authored source frames and output geometry stay native.
    local allow_spatial_tradeoff = explicit_uhd_2k and backend == 'nvidia_hq'
    if spatial_quality_regresses(w, h, inference_width, inference_height)
        and not allow_spatial_tradeoff then
        return nil, spatial_quality_reason(
            w, h, inference_width, inference_height), false
    end
    local spatial_compatibility = trim(mp.get_property_native(
        'user-data/video-enhancement/rife-spatial-compatible') or ''):lower()
    if spatial_compatibility == '' or spatial_compatibility == 'waiting' then
        return nil, '等待原生空间画质基线确认', true
    end
    if spatial_compatibility == 'no' and not allow_spatial_tradeoff then
        return nil, mp.get_property_native(
            'user-data/video-enhancement/rife-spatial-detail')
            or '空间画质不得倒退：已保留原有超分质量并改用原生安全平滑', false
    end

    local gpu_thread = math.max(1, math.min(4, math.floor(o.gpu_thread)))
    if backend == 'nvidia_hq' then
        -- RTX 4050/4060/4070-class devices use one TensorRT stream to avoid
        -- VRAM/compute contention. 80/90-class devices use the measured bounded
        -- dual-stream graph; startup and sustained guards remain authoritative.
        gpu_thread = performance_class >= 80 and 2 or 1
    elseif backend == 'vulkan' and not desktop_gpu then
        -- Mobile/Max-Q Vulkan drivers commonly lose throughput when two NCNN
        -- GPU workers compete. Keep one worker and let the bounded VS request
        -- queue below absorb pipeline bubbles.
        gpu_thread = 1
    elseif (selected_mode == 'quality' or native_1080_trial) and tier == 'high' then
        -- Quality mode must keep the portable Vulkan GPU fed. The plugin uses
        -- gpu_thread as a semaphore for parallel frame requests, so one slot on
        -- a high-tier adapter can leave throughput on the table instead of
        -- reducing work. Bound ordinary high-tier cards
        -- to two slots and desktop 4090/5090 Vulkan graphs to four.
        local quality_threads = flagship_quality and backend == 'vulkan' and 4 or 2
        gpu_thread = math.max(gpu_thread, quality_threads)
    end

    local buffered_frames = spec.buffered_frames
    local concurrent_frames = spec.concurrent_frames
    local uhd_mode = false
    if (selected_mode == 'quality' or native_1080_trial) and backend == 'vulkan' then
        if tier == 'medium' then
            -- Medium-tier adapters keep one RIFE worker, while two queued
            -- VapourSynth requests reduce pipeline bubbles without duplicating it.
            -- Keep one GPU worker and add only bounded frame-level prefetch.
            buffered_frames = math.max(buffered_frames, 6)
            concurrent_frames = math.max(concurrent_frames, 2)
        elseif tier == 'high' then
            buffered_frames = math.max(buffered_frames, flagship_quality and 8 or 6)
            concurrent_frames = math.max(concurrent_frames,
                flagship_quality and 4 or 2)
        end
    end
    if flagship_quality and backend == 'vulkan' and (w > 2560 or h > 1440) then
        -- Keep the public RIFE input/output at the 2K quality floor, but let the
        -- plugin estimate optical flow through its UHD half-resolution path.
        uhd_mode = true
    end

    return {
        fps = source_fps,
        gpu_id = gpu_index,
        max_width = math.max(320, math.floor(max_width)),
        max_height = math.max(180, math.floor(max_height)),
        min_width = math.max(320, math.floor(min_width)),
        min_height = math.max(180, math.floor(min_height)),
        gpu_thread = gpu_thread,
        tier = tier,
        gpu_name = gpu_name,
        source_width = w,
        source_height = h,
        inference_width = inference_width,
        inference_height = inference_height,
        output_width = matrix_id == 3 and w or inference_width,
        output_height = matrix_id == 3 and h or inference_height,
        matrix_id = matrix_id,
        backend = backend,
        backend_label = spec.label,
        script = spec.script,
        buffered_frames = buffered_frames,
        concurrent_frames = concurrent_frames,
        uhd_mode = uhd_mode,
        fps_multiplier = 2,
        temporal = true,
        pipeline_kind = allow_spatial_tradeoff and 'rife_uhd_2k' or 'rife_native',
        allow_spatial_tradeoff = allow_spatial_tradeoff,
        learned = learned,
        native_1080_trial = native_1080_trial,
        native_1080_family = native_1080_family,
        remote_source = remote_source,
        hdr_pq = gamma == 'pq',
        vivid_compat = vivid_compat,
    }, nil, false
end

local activate

fail_current_file = function(reason)
    publish_auto_status('blocked')
    background:revoke()
    if active_auto_key then
        prepared_specs[active_auto_key] = 'slow'
        auto_retry_disabled_specs[active_auto_key] = true
        active_auto_key = nil
    end
    blocked_generation = generation
    blocked_reason = reason or 'RIFE 初始化或实时性能不足'
    blocked_protected = false
    remove_filter()
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'failed')
    if activation_started_at > 0 then
        set_native_if_changed('user-data/video-enhancement/ai-warmup-seconds',
            string.format('%.3f', math.max(0, mp.get_time() - activation_started_at)))
    end
    publish('failed', 'AI 已回退', blocked_reason, false)
    if o.show_osd then mp.osd_message(i18n.t('RIFE AI：已安全回退\n') .. i18n.status(tostring(reason)), 3) end
    msg.warn('RIFE fallback: ' .. tostring(reason))
end

local function protect_current_file(reason)
    publish_auto_status('blocked')
    background:revoke()
    if active_auto_key then
        prepared_specs[active_auto_key] = 'slow'
        auto_retry_disabled_specs[active_auto_key] = true
        active_auto_key = nil
    end
    blocked_generation = generation
    blocked_reason = reason or '空间画质不得倒退：已保留原有画质链'
    blocked_protected = true
    remove_filter()
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'protected')
    publish('protected', '空间画质保护', blocked_reason, false)
    if o.show_osd then
        mp.osd_message(i18n.t('空间画质保护：已保留原有画质链\n补帧改用原生安全方案'), 3)
    end
    msg.info('RIFE spatial quality protection: ' .. tostring(blocked_reason))
end

local function fallback_after_overload(reason)
    -- Rebuilding with a lower inference size in the middle of playback causes
    -- a visible interruption. A sustained failure is terminal for this file;
    -- the next file gets a fresh plan rather than inheriting this graph.
    fail_current_file(reason .. '；本集保持普通播放，避免运行中重新建图')
end

local function reset_progress_guard()
    last_progress_wall = mp.get_time()
    last_progress_pos = mp.get_property_number('time-pos', nil)
end

local function reset_guard_for_presentation_change(reason)
    if not loaded then return end
    local now = mp.get_time()
    guard_bad_samples = 0
    guard_drop_only_samples = 0
    last_drops = mp.get_property_number('frame-drop-count', 0) or 0
    last_mistimed = mp.get_property_number('mistimed-frame-count', 0) or 0
    reset_progress_guard()
    guard_ready_at = math.max(guard_ready_at,
        now + math.max(0, o.guard_presentation_cooldown, o.guard_interval * 2))
    if state == 'active' then
        msg.info('RIFE guard presentation cooldown: ' .. tostring(reason))
    end
end

local function complete_activation(serial, reason)
    if serial ~= graph_token or not loaded or not active or not filter_present() then return end
    if mode() ~= graph_smooth_mode or o.hq_processing_mode ~= graph_hq_mode
        or not hdr_policy.matches(active_plan) then
        schedule_evaluate(0.05)
        return
    end
    cancel_timer(startup_quality_timer)
    startup_quality_timer = nil
    startup_ready_release_at = 0
    release_startup_gate(reason or 'AI ready')
    local now = mp.get_time()
    local start_delay = math.max(0, o.guard_start_delay)
    if background.approved and active_plan
        and prepared_specs[preparation_key(preparation_spec(active_plan))] == 'insufficient' then
        -- Only an explicitly accepted, already measured slow trial starts
        -- sampling earlier. The existing sustained guard and all seek/pause/
        -- presentation cooldowns still own their normal thresholds/windows.
        start_delay = math.min(start_delay, math.max(0, o.guard_interval))
    end
    guard_ready_at = math.max(guard_ready_at, now + start_delay)
    guard_bad_samples = 0
    guard_drop_only_samples = 0
    last_drops = mp.get_property_number('frame-drop-count', 0) or 0
    last_mistimed = mp.get_property_number('mistimed-frame-count', 0) or 0
    reset_progress_guard()
    activation_committed = true
    background:commit()
    publish_auto_status(active_auto_key and 'active' or 'manual')
    local warmup_seconds = activation_started_at > 0
        and math.max(0, now - activation_started_at) or 0
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'ready')
    set_native_if_changed('user-data/video-enhancement/ai-warmup-seconds',
        string.format('%.3f', warmup_seconds))
    set_native_if_changed('user-data/video-enhancement/ai-graph-build-seconds',
        string.format('%.3f', graph_build_seconds))
    msg.info(string.format(
        'RIFE warm-up completed in %.3fs (graph %.3fs, ready %.3fs)',
        warmup_seconds, graph_build_seconds,
        math.max(0, warmup_seconds - graph_build_seconds)))
    if o.show_osd then
        mp.osd_message(active_plan and active_plan.pipeline_kind == 'superres'
            and i18n.t('TensorRT AI 超分已启用') or active_plan and active_plan.vivid_compat
            and i18n.t('普通 HDR 兼容补帧已启用\n不应用 Vivid 专属动态映射') or i18n.t('RIFE AI 2× 已启用'), 3)
    end
end

local function finish_activation(serial, reason)
    if serial ~= graph_token or not loaded or not active or not filter_present() then return end
    cancel_timer(startup_quality_timer)
    startup_quality_timer = nil
    local delay = math.max(0, startup_ready_release_at - mp.get_time())
    if delay > 0.01 then
        -- `estimated-vf-fps == 2x` proves the graph format, not that the bounded
        -- request queue and final renderer are already settled. Keep the one
        -- startup-only pause for a short fill window so weak GPUs do not expose
        -- the burst that used to appear immediately after the first AI frame.
        startup_quality_timer = mp.add_timeout(delay, function()
            startup_quality_timer = nil
            complete_activation(serial, reason or 'AI ready')
        end)
        return
    end
    complete_activation(serial, reason)
end

local function graph_user_data(plan, expected_identity)
    local pipeline_code = plan.pipeline_kind == 'rife_uhd_2k' and 1
        or plan.pipeline_kind == 'superres' and 2 or 0
    local user_data = string.format('%dx%dx%dx%dx%dx%dx%dx%dx%d',
        plan.gpu_id, plan.max_width, plan.max_height, plan.gpu_thread,
        plan.matrix_id or 0, plan.uhd_mode and 1 or 0, pipeline_code,
        plan.output_width or plan.source_width, plan.output_height or plan.source_height)
    if plan.backend == 'nvidia_hq' then
        local target_hex = tostring(plan.gpu_name or ''):gsub('.', function(byte)
            return string.format('%02x', byte:byte())
        end)
        user_data = user_data .. 'x' .. target_hex
        if expected_identity or plan.vivid_compat then
            user_data = user_data .. 'x' .. tostring(expected_identity or ''):gsub('.', function(byte)
                return string.format('%02x', byte:byte())
            end)
        end
    end
    if plan.vivid_compat then
        if plan.backend ~= 'nvidia_hq' then user_data = user_data .. 'xx' end
        user_data = user_data .. 'x1'
    end
    return user_data
end

local function graph_filter_for(plan)
    local identity = plan.backend == 'nvidia_hq'
        and prepared_device_identities[preparation_key(preparation_spec(plan))] or nil
    local user_data = graph_user_data(plan, identity)
    local filter = string.format(
        '%s:vapoursynth=file=%s:buffered-frames=%d:concurrent-frames=%d:user-data=%s',
        filter_label, plan.script,
        plan.buffered_frames or 4, plan.concurrent_frames or 1, user_data)
    -- Source geometry and cadence matter even when the serialized VF options
    -- happen to be identical. Shader/display properties do not belong here.
    local signature = table.concat({filter, tostring(plan.backend),
        tostring(plan.source_width), tostring(plan.source_height),
        string.format('%.3f', tonumber(plan.fps) or 0)}, '\31')
    return filter, signature
end

local function verify_activation(serial, deadline)
    if serial ~= graph_token or not loaded then return end
    if mode() ~= graph_smooth_mode or o.hq_processing_mode ~= graph_hq_mode
        or not hdr_policy.matches(active_plan) then
        schedule_evaluate(0.05)
        return
    end
    if not filter_present() then
        fail_current_file('AI 滤镜未进入视频链')
        return
    end
    local filtered_fps = mp.get_property_number('estimated-vf-fps', 0) or 0
    -- Respect a user pause while waiting for output cadence; no automatic
    -- unpause or false timeout merely because the user has stopped the clock.
    if (background.approved or (o.auto_enable_prepared
        and generation > prepared_generation
        and prepared_backend == (active_plan or {}).backend))
        and mp.get_property_bool('pause', false) then
        verify_timer = mp.add_timeout(0.2, function()
            verify_activation(serial, mp.get_time() + math.max(2, o.verify_timeout))
        end)
        return
    end
    local plan = active_plan or {}
    local target = active_source_fps * (plan.fps_multiplier or 2)
    if target > 0 and math.abs(filtered_fps - target) / target <= 0.035 then
        cancel_timer(startup_gate_timer)
        startup_gate_timer = nil
        -- The short queue-fill hold is useful only while playback is already
        -- paused (by this script or by the user). A live manual refresh has no
        -- gate to hold; delaying the commit there merely leaves a window where
        -- its warm-up drops can be sampled. The normal guard cooldown still
        -- starts after the final quality handshake in both cases.
        local can_fill_while_paused = startup_gate_owned
            or mp.get_property_bool('pause', false)
        startup_ready_release_at = mp.get_time() + (can_fill_while_paused
            and math.max(0, tonumber(o.startup_ready_hold) or 1.2) or 0)
        local inference_width = plan.inference_width or plan.max_width or 0
        local inference_height = plan.inference_height or plan.max_height or 0
        local geometry = plan.pipeline_kind == 'superres'
            and string.format('AI 超分 %d×%d → %d×%d',
                plan.source_width or 0, plan.source_height or 0,
                plan.output_width or 0, plan.output_height or 0)
            or string.format('RIFE 合成 %d×%d', inference_width, inference_height)
        if plan.uhd_mode then
            geometry = geometry .. string.format(
                ' · 光流估计 %d×%d（UHD，合成尺寸不变）',
                math.max(1, math.floor(inference_width / 2)),
                math.max(1, math.floor(inference_height / 2)))
        end
        local detail = string.format('%sfps → %sfps · %s%s',
            format_fps(active_source_fps), format_fps(target),
            geometry,
            plan.learned and ' · 已应用本机学习档' or '')
        if plan.vivid_compat then
            detail = detail .. string.format(
                ' · 普通 HDR 兼容补帧 %d×%d；10-bit/PQ/BT.2020，不应用 Vivid 专属动态映射',
                plan.output_width or plan.source_width or 0,
                plan.output_height or plan.source_height or 0)
        elseif plan.hdr_pq then
            detail = detail .. string.format(
                ' · HDR10/HDR10+ 输出 %d×%d、元数据保留',
                plan.output_width or plan.source_width or 0,
                plan.output_height or plan.source_height or 0)
        end
        detail = detail .. ' · ' .. tostring(plan.backend_label or 'RIFE v4.6')
        if plan.native_1080_trial then
            detail = detail .. ' · ' .. tostring(plan.native_1080_family
                or '当前显卡') .. ' 原生 1080p 实时验证'
        end
        if plan.allow_spatial_tradeoff then
            if plan.hdr_pq then
                detail = detail .. string.format(
                    ' · HDR 基底仅将运动推理降至 %d×%d，原始帧与最终输出保持 %d×%d',
                    inference_width, inference_height,
                    plan.source_width or 0, plan.source_height or 0)
            else
                detail = detail .. string.format(
                    ' · 用户显式允许 %d×%d → %d×%d 后补帧',
                    plan.source_width or 0, plan.source_height or 0,
                    inference_width, inference_height)
            end
        end
        if plan.remote_source then detail = detail .. ' · WebDAV/OpenAlist' end
        if plan.runtime_downgraded then detail = detail .. ' · 本文件实时降档' end
        if plan.pipeline_kind == 'superres' then
            publish('spatial', 'AnimeJaNai AI 超分', detail, true)
            mp.commandv('script-message-to', 'adaptive_quality', 'refresh')
            finish_activation(serial, 'AI ready')
            return
        end
        publish('active', 'RIFE AI 2×', detail, true)
        -- Keep the startup pause until adaptive-quality has replaced any
        -- over-budget FSRCNNX/display-resample layer. This prevents the first
        -- visible second from compiling a new renderer chain while playback is
        -- already running and avoids counting that setup burst as real overload.
        cancel_timer(startup_quality_timer)
        startup_quality_timer = mp.add_timeout(
            math.max(0.2, tonumber(o.startup_quality_timeout) or 0.8), function()
                startup_quality_timer = nil
                finish_activation(serial, 'AI ready (quality fallback)')
            end)
        mp.commandv('script-message-to', 'adaptive_quality',
            'prepare-rife-ready', tostring(serial))
        return
    end
    if mp.get_time() >= deadline then
        fail_current_file(string.format('输出帧率未达到 2×（当前 %s）', format_fps(filtered_fps)))
        return
    end
    verify_timer = mp.add_timeout(
        math.max(0.05, tonumber(o.startup_verify_interval) or 0.15), function()
        verify_activation(serial, deadline)
    end)
end

activate = function(plan)
    if plan.backend == 'nvidia_hq'
        and not prepared_device_identities[preparation_key(preparation_spec(plan))] then
        fail_current_file('CUDA 设备物理身份未通过后台核验；请重新准备 AI 后再启用')
        return
    end
    local filter, signature = graph_filter_for(plan)
    if graph_state ~= 'absent' or filter_present() then
        if graph_signature == signature then return end
        msg.warn('RIFE graph already owned by current video; refusing duplicate vf add')
        return
    end
    if spatial_quality_regresses(plan.source_width, plan.source_height,
        plan.inference_width, plan.inference_height)
        and not plan.allow_spatial_tradeoff then
        protect_current_file(spatial_quality_reason(
            plan.source_width, plan.source_height,
            plan.inference_width, plan.inference_height))
        return
    end
    if mp.get_property_native(
        'user-data/video-enhancement/rife-spatial-compatible') == 'no'
        and not plan.allow_spatial_tradeoff then
        protect_current_file(mp.get_property_native(
            'user-data/video-enhancement/rife-spatial-detail')
            or '空间画质不得倒退：已保留原有超分质量')
        return
    end
    -- The worker has already proved this exact graph. Bind the process-local
    -- VSScript runtime only now, so a failed TensorRT probe can still use the
    -- independent Vulkan runtime in this player process.
    if not configure_runtime_environment(plan.backend) then
        fail_current_file('无法初始化便携 VSScript，已回退')
        return
    end
    graph_state = 'building'
    graph_signature = signature
    graph_revision = graph_revision + 1
    graph_token = tostring(generation) .. ':' .. tostring(graph_revision)
    set_native_if_changed('user-data/video-enhancement/ai-graph-token', graph_token)
    graph_source_width, graph_source_height = plan.source_width, plan.source_height
    graph_smooth_mode, graph_hq_mode = mode(), o.hq_processing_mode
    activation_committed = false
    activation_started_at = mp.get_time()
    graph_build_seconds = 0
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'building')
    set_native_if_changed('user-data/video-enhancement/ai-warmup-seconds', '')
    set_native_if_changed('user-data/video-enhancement/ai-graph-build-seconds', '')
    active_source_fps = plan.fps
    active_plan = plan
    local starting_label = plan.pipeline_kind == 'superres'
        and 'AI 超分初始化中' or 'RIFE 初始化中'
    local starting_detail = string.format('绑定 %s · %s · %s',
        mp.get_property_native('user-data/adaptive-quality/gpu') or '目标显卡',
        plan.backend_label or 'RIFE v4.6', plan.gpu_id < 0
            and 'CUDA 设备自动核验' or string.format('GPU %d', plan.gpu_id))
    if plan.native_1080_trial then
        starting_detail = starting_detail .. string.format(
            ' · 原生 %d×%d 实时验证',
            plan.inference_width or 0, plan.inference_height or 0)
    end
    publish('starting', starting_label, starting_detail, false)
    acquire_startup_gate(plan)
    local graph_started_at = mp.get_time()
    local ok, result = pcall(mp.commandv, 'vf', 'add', filter)
    if not ok or result == false then
        fail_current_file('无法创建 VapourSynth 滤镜：' .. tostring(result))
        return
    end
    publish_prepared_device(preparation_key(preparation_spec(plan)))
    graph_state = 'installed'
    -- vf add initializes VapourSynth synchronously. TensorRT's first engine
    -- build can block the Lua event loop for tens of seconds, so a timer armed
    -- before this call cannot interrupt it: the overdue callback would run only
    -- after a successful graph build and incorrectly remove the fresh filter.
    -- Start the readiness deadline only after synchronous graph creation ends.
    graph_build_seconds = math.max(0, mp.get_time() - graph_started_at)
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'verifying')
    set_native_if_changed('user-data/video-enhancement/ai-graph-build-seconds',
        string.format('%.3f', graph_build_seconds))
    msg.info(string.format('RIFE graph created in %.3fs', graph_build_seconds))
    arm_startup_gate_timeout()
    local serial = graph_token
    verify_timer = mp.add_timeout(
        math.max(0.05, tonumber(o.startup_verify_interval) or 0.15), function()
        verify_activation(serial, mp.get_time() + math.max(2, o.verify_timeout))
    end)
end

preparation_spec = function(plan)
    local backend = backend_spec(plan.backend)
    -- Hardware decoding reports d3d11/cuda as the surface type. The probe
    -- needs the underlying pixel layout to decide whether its synthetic
    -- frames represent the current source faithfully.
    local source_format = hdr_policy.source_format()
    return {
        backend=plan.backend,
        runtime=backend.runtime_root,
        graph=mp.command_native({'expand-path', plan.script}),
        width=plan.source_width, height=plan.source_height,
        hdr=plan.matrix_id == 3,
        user_data=graph_user_data(plan),
        target_gpu_name=plan.backend == 'nvidia_hq' and plan.gpu_name or nil,
        gpu_id_requested=plan.backend == 'nvidia_hq' and plan.gpu_id or nil,
        source_format=source_format,
        source_fps=plan.fps,
        buffered_frames=plan.buffered_frames or 4,
        concurrent_frames=plan.concurrent_frames or 1,
        required_fps=plan.fps * (plan.fps_multiplier or 2),
    }
end

local function try_prepared_auto(plan, key, verdict)
    local clock = mp.get_property_native('user-data/video-enhancement/native-clock-guard')
    local protected = clock == 'protected' or clock == 'preprotected'
    local owner = mp.get_property_native('user-data/video-enhancement/sync-managed')
    local sync = mp.get_property('video-sync', 'audio')
    local interpolation = mp.get_property_bool('interpolation', false)
    local managed_clock = owner == 'yes' and ((sync == 'audio' and not interpolation)
        or (sync == 'display-resample' and interpolation))
    local ordinary_audio = owner ~= 'yes' and sync == 'audio' and not interpolation
    local timing_allowed = owner ~= 'external' and clock ~= 'external'
        and (protected and owner == 'yes' and sync == 'audio' and not interpolation
            or not protected and (managed_clock or ordinary_audio))
    local selected_mode = mode()
    local eligible = o.auto_enable_prepared and timing_allowed
        and (selected_mode == 'auto' or selected_mode == 'quality')
        and prepared_auto_attempted_generation ~= generation
        and prepared_auto_external_generation ~= generation
        and graph_state == 'absent' and not filter_present()
        and blocked_generation ~= generation and canceled_generation ~= generation
        and (verdict == 'safe' or verdict == 'slow') and not auto_retry_disabled_specs[key]
        and background.status == 'ready' and background.key == key
        and (plan.backend ~= 'nvidia_hq' or prepared_device_identities[key] ~= nil)
    if not eligible then
        invalidate_prepared_auto_pending()
        local automatic = o.auto_enable_prepared and (selected_mode == 'auto' or selected_mode == 'quality')
        publish_auto_status(not automatic and 'off' or background.status == 'ready' and 'blocked' or 'idle')
        return false
    end
    local speed = positive_finite(mp.get_property_number('speed', nil))
    if not speed or math.abs(speed - 1) > 0.001
        or mp.get_property_bool('pause', false)
        or mp.get_property_bool('paused-for-cache', false)
        or mp.get_property_bool('seeking', false)
        or mp.get_property_bool('core-idle', false) then
        invalidate_prepared_auto_pending()
        publish_auto_status('suspended')
        -- Property changes resume evaluation; do not poll a suspended video.
        return true
    end
    local now = mp.get_time()
    local signature = table.concat({tostring(generation), key, selected_mode,
        o.hq_processing_mode, clock or 'idle', owner or 'none', sync, tostring(interpolation), verdict,
        plan.backend == 'nvidia_hq' and prepared_device_identities[key] or 'vulkan'}, '\31')
    if not prepared_auto_pending or prepared_auto_pending.signature ~= signature then
        prepared_auto_pending = {generation=generation, key=key,
            signature=signature, ready_at=now + 1.0}
    end
    if now < prepared_auto_pending.ready_at then
        publish_auto_status('waiting')
        schedule_evaluate(prepared_auto_pending.ready_at - now)
        return true
    end
    -- Reaching here means the current generation/spec and every live policy
    -- condition survived another evaluation. Never clear a failed/canceled
    -- generation as the explicit manual trial is allowed to do.
    local pending = prepared_auto_pending
    invalidate_prepared_auto_pending()
    if pending.generation ~= generation or pending.key ~= key then return true end
    if not background:enable() then return true end
    prepared_auto_attempted_generation = generation
    active_auto_key = key
    publish_auto_status('trying')
    msg.info('Prepared AI auto trial: trying the ' .. (verdict == 'safe' and 'ample' or 'limited')
        .. ' exact-spec graph once for this file')
    activate(plan)
    return true
end

local function evaluate()
    if not loaded then return end
    hdr_policy.publish()
    local format_status, format_detail = hdr_policy.check()
    if hdr_policy.tracking and mp.get_property_bool('video-params/hdr-vivid', false) then
        hdr_policy.target_vivid = true
    end
    -- A seek/pause may postpone ordinary replanning, but must never postpone
    -- revoking a graph whose source or explicit colour permission changed.
    if graph_state ~= 'absent' and active_plan and not hdr_policy.matches(active_plan) then
        local opening_vivid = not active and state == 'starting'
            and not activation_committed and not hdr_policy.replanned
            and not active_plan.vivid_compat and active_plan.hdr_pq
            and (format_status == 'vivid-hdr10' or format_status == 'normal' and hdr_policy.target_vivid)
            and hdr_policy.startup_candidate()
            and active_plan.source_width == mp.get_property_number('video-params/w', 0)
            and active_plan.source_height == mp.get_property_number('video-params/h', 0)
            and not mp.get_property_bool('seeking', false) and not seek_recovery
            and canceled_generation ~= generation and blocked_generation ~= generation
            and prepared_auto_external_generation ~= generation
            and mp.get_property_native('user-data/video-enhancement/sync-managed') ~= 'external'
            and mp.get_property_native('user-data/video-enhancement/native-clock-guard') ~= 'external'
            and mode() == graph_smooth_mode and o.hq_processing_mode == graph_hq_mode
            and math.abs((mp.get_property_number('speed', 1) or 1) - 1) <= 0.001
        invalidate_prepared_auto_pending()
        remove_filter()
        background:reset()
        if opening_vivid then
            -- This graph never committed. Revoke its token/approval and make
            -- one new exact-spec preparation, not a runtime-failure retry.
            hdr_policy.replanned = true
            hdr_policy.stable_since = nil
            hdr_policy.stable_signature = nil
            prepared_auto_attempted_generation = -1
            active_auto_key = nil
            set_native_if_changed('user-data/video-enhancement/ai-probe', '')
            set_native_if_changed('user-data/video-enhancement/ai-probe-verdict', 'unknown')
            publish_auto_status('idle')
            hdr_policy.startup_status('replanning', '首帧确认 HDR Vivid，正在按兼容规格重新准备一次')
            publish('native', '普通播放', '起播识别到 HDR Vivid，撤销未完成的旧图，稳定后重新准备一次', false)
            schedule_evaluate(0.05)
            return
        end
        blocked_generation = generation
        blocked_reason = format_detail ~= '' and format_detail or 'HDR 处理格式已改变'
        blocked_protected = true
        hdr_policy.startup_status('blocked', '格式条件改变，已停止本片自动接入')
        publish_auto_status('blocked')
        publish('protected', '格式保护', blocked_reason .. '；本集保持普通播放', false)
        return
    end
    if canceled_generation == generation then
        invalidate_prepared_auto_pending()
        hdr_policy.startup_status('blocked', '已取消本片 AI 自动接入，当前普通播放')
        publish_auto_status('blocked')
        publish('native', '普通播放', '已取消 AI 准备，本集继续普通播放', false)
        return
    end
    if o.enabled and graph_state == 'absent' and blocked_generation ~= generation
        and (mode() == 'auto' or mode() == 'quality')
        and (format_status == 'normal' or format_status == 'vivid-hdr10')
        and hdr_policy.startup_candidate() then
        if hdr_policy.startup_wait() then
            -- Source changes also cancel old workers before the stable window.
            if background.status == 'preparing' or background.status == 'ready' then
                background:reset()
            end
            invalidate_prepared_auto_pending()
            publish_auto_status('suspended')
            publish('native', '普通播放', mp.get_property_native(
                'user-data/video-enhancement/ai-startup-format-detail'), false)
            return
        end
    elseif graph_state == 'absent' then
        hdr_policy.startup_status('idle')
    end
    local prepared_verdict = prepared_specs[background.key]
    if graph_state == 'absent' and background.status == 'ready' and o.auto_enable_prepared
        and (format_status == 'normal' or format_status == 'vivid-hdr10')
        and (prepared_verdict == 'safe' or prepared_verdict == 'slow')
        and blocked_generation ~= generation and not auto_retry_disabled_specs[background.key]
        and (mode() == 'auto' or mode() == 'quality') then
        if mp.get_property_native('user-data/video-enhancement/sync-managed') == 'external'
            or mp.get_property_native('user-data/video-enhancement/native-clock-guard') == 'external' then
            prepared_auto_external_generation = generation
            invalidate_prepared_auto_pending()
            publish_auto_status('blocked')
            return
        end
        local speed = positive_finite(mp.get_property_number('speed', nil))
        if not speed or math.abs(speed - 1) > 0.001
            or mp.get_property_bool('pause', false)
            or mp.get_property_bool('paused-for-cache', false)
            or mp.get_property_bool('seeking', false)
            or mp.get_property_bool('core-idle', false) then
            invalidate_prepared_auto_pending()
            publish_auto_status('suspended')
            return
        end
    end
    -- A user seek resets the inner VapourSynth queue, but it does not require
    -- removing and re-adding the managed filter entry. A previously queued
    -- property evaluation could observe transient `seeking`, tear down the
    -- whole output chain, then trigger a second RIFE initialization. Keep the
    -- filter entry and public active policy stable until mpv reports a real
    -- playback restart at the new position.
    if active and (seek_recovery or mp.get_property_bool('seeking', false)) then
        return
    end
    if graph_state ~= 'absent' and not filter_present() then
        fail_current_file('AI 滤镜已从视频链消失；本集保持普通播放')
        return
    end
    local graph_installed = graph_state ~= 'absent'
    local source_width = mp.get_property_number('video-params/w', 0) or 0
    local source_height = mp.get_property_number('video-params/h', 0) or 0
    local source_changed = graph_installed and source_width > 0 and source_height > 0
        and (source_width ~= graph_source_width or source_height ~= graph_source_height)
    local policy_changed = graph_installed
        and (mode() ~= graph_smooth_mode or o.hq_processing_mode ~= graph_hq_mode)
    local plan, reason, transient = plan_for_current_video(graph_installed)
    source_changed = source_changed or graph_installed and plan and active_plan
        and (plan.vivid_compat == true) ~= (active_plan.vivid_compat == true)
    if graph_installed then
        if not plan and transient and not source_changed then return end
        if not plan then
            remove_filter()
            background:reset()
            publish('native', '普通播放',
                (reason or '当前片源不再满足 AI 条件')
                    .. '；本集不在播放中重新挂载 AI', false)
            return
        end
        local _, signature = graph_filter_for(plan)
        if signature == graph_signature then
            graph_smooth_mode, graph_hq_mode = mode(), o.hq_processing_mode
            return
        end
        if source_changed then
            -- A new source size invalidates the old VS graph.  Its throughput
            -- verdict must be measured separately, so do not attach it after
            -- the current video's first frame has already been shown.
            remove_filter()
            background:reset()
            blocked_generation = generation
            publish('native', '普通播放',
                '片源分辨率或 HDR 处理格式已改变；本集保持普通播放，下个视频重新评估 AI', false)
            return
        end
        if policy_changed then
            -- A user-selected AI mode may require a genuinely different graph.
            -- Same-parameter menu clicks were handled by the signature check.
            remove_filter()
            if plan.backend == 'nvidia_hq'
                and not prepared_device_identities[preparation_key(preparation_spec(plan))] then
                -- This explicit pipeline has a different exact spec. Prepare
                -- it outside mpv instead of treating missing proof as a graph
                -- initialization failure or reusing the previous device proof.
                background:reset()
            else
                activate(plan)
                return
            end
        else
            -- Adaptive quality and presentation changes only own shader/sync
            -- budget; they cannot replace a running VapourSynth graph.
            return
        end
    end
    if not plan then
        invalidate_prepared_auto_pending()
        if not transient and (background.status == 'preparing' or background.status == 'ready') then
            background:reset()
        end
        if active or filter_present() then
            remove_filter()
            -- A click authorizes one activation, not another pipeline rebuild
            -- after a temporary policy change during the same video.
            background:reset()
        end
        local current_mode = mode()
        local automatic = o.auto_enable_prepared and (current_mode == 'auto' or current_mode == 'quality')
        publish_auto_status(not automatic and 'off' or 'blocked')
        local native_fallback = reason and reason:find('原生平滑', 1, true) ~= nil
        local spatial_protection = reason
            and reason:find('空间画质不得倒退', 1, true) ~= nil
        local new_state = current_mode == 'off' and 'off'
            or current_mode == 'performance' and 'native'
            or native_fallback and 'native'
            or transient and 'detecting'
            or reason and (reason:find('运行库', 1, true) or reason:find('VSScript', 1, true))
                and 'unavailable'
            or 'protected'
        publish(new_state,
            new_state == 'native' and '原生轻量平滑'
                or new_state == 'detecting' and '检测中'
                or spatial_protection and '空间画质保护'
                or 'AI 未启用',
            reason or '使用第一阶段补帧策略', false)
        if transient then
            local serial = generation
            evaluate_timer = mp.add_timeout(0.6, function()
                if serial == generation then evaluate() end
            end)
        end
        return
    end
    if active or (state == 'starting' and filter_present()) then return end
    if blocked_generation == generation then
        invalidate_prepared_auto_pending()
        publish_auto_status('blocked')
        publish(blocked_protected and 'protected' or 'failed',
            blocked_protected and '空间画质保护' or 'AI 已回退',
            (blocked_reason or '本文件已触发性能保护') .. '；可在菜单手动重试', false)
        return
    end
    -- Cache only an exact-spec throughput verdict, never a graph or approval.
    -- Each file computes its own plan and waits for stable live trial conditions.
    local spec = preparation_spec(plan)
    local key = preparation_key(spec)
    local verdict = prepared_specs[key]
    if verdict == 'safe' or verdict == 'slow' or verdict == 'unsupported'
        or verdict == 'insufficient' or verdict == 'unknown' then
        background:restore(spec)
        mp.set_property_native('user-data/video-enhancement/ai-auto-safe',
            verdict == 'safe' and 'yes' or 'no')
        mp.set_property_native('user-data/video-enhancement/ai-probe-verdict',
            verdict == 'slow' and 'limited' or verdict)
        publish_prepared_device(key)
    end
    set_native_if_changed('user-data/video-enhancement/ai-probe',
        prepared_benchmarks[key] or '')
    if (verdict == 'insufficient' or verdict == 'unknown') and not background.approved then
        invalidate_prepared_auto_pending()
        publish_auto_status('blocked')
        set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'skipped')
        publish('native', '普通播放', verdict == 'insufficient'
            and 'AI 模型已准备，但当前规格测速低于目标帧率；已保持普通播放，可手动试跑'
            or 'AI 模型已准备，但实时性能结果未确认；已保持普通播放，可重新检测或手动试跑', false)
        return
    elseif verdict == 'unsupported' and not background.approved then
        invalidate_prepared_auto_pending()
        publish_auto_status('blocked')
        set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'skipped')
        publish('native', '普通播放',
            '当前视频像素格式未通过后台验证，自动补帧已跳过；可手动尝试', false)
        return
    elseif (verdict == 'safe' or verdict == 'slow')
        and auto_retry_disabled_specs[key] and not background.approved then
        invalidate_prepared_auto_pending()
        publish_auto_status('blocked')
        set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'skipped')
        publish('native', '普通播放',
            '该规格自动补帧曾回退，后续保持普通播放；可手动重新尝试', false)
        return
    elseif (verdict == 'failed' or verdict == 'interrupted') and not background.approved then
        invalidate_prepared_auto_pending()
        publish_auto_status('blocked')
        set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'skipped')
        publish('native', '普通播放',
            verdict == 'interrupted'
                and '后台检测出现播放压力，已停止；后续同规格保持普通播放，可手动重新检测'
                or '该规格 AI 准备曾失败，已保持普通播放；可在高级设置重新检测', false)
        return
    end
    if not background.approved and try_prepared_auto(plan, key, verdict) then return end
    local allowed = background:allow(spec)
    if not allowed then
        local preparation_details = {
            ready=o.auto_enable_prepared
                and 'AI 已准备好；当前自动条件未满足，可查看诊断或手动试跑'
                or 'AI 已准备好，等待启用',
            preparing='AI 后台准备期间保持普通播放',
            canceled='已取消 AI 准备，继续普通播放',
            interrupted='后台检测出现播放压力，已停止并保持普通播放',
            timeout='AI 准备超时，继续普通播放；可在菜单重试',
            busy='另一窗口正在准备 AI，继续普通播放',
            failed=background.failure_code == 'cuda-driver-too-old'
                and 'NVIDIA 驱动与 CUDA 运行库不兼容；当前继续普通播放'
                or 'AI 暂未准备成功，继续普通播放；可在菜单重试',
        }
        publish('native', '普通播放', preparation_details[background.status]
            or '当前继续普通播放', false)
        return
    end
    remove_filter()
    activate(plan)
end

schedule_evaluate = function(delay, keep_earlier)
    local due = mp.get_time() + math.max(0.05, delay or 0.15)
    if keep_earlier and evaluate_timer and evaluate_due_at and evaluate_due_at <= due then return end
    cancel_timer(evaluate_timer)
    evaluate_due_at = due
    local serial = generation
    evaluate_timer = mp.add_timeout(math.max(0.05, delay or 0.15), function()
        evaluate_timer = nil
        evaluate_due_at = nil
        if serial == generation then evaluate() end
    end)
end

on_background_failure = function(spec, code)
    if spec.backend ~= 'nvidia_hq' or code == 'busy' then return end
    local current_plan = loaded and plan_for_current_video(false)
    local matches_current = current_plan
        and preparation_key(preparation_spec(current_plan)) == preparation_key(spec)
    if code == 'cuda-driver-too-old' then hq_driver_incompatible = true end
    if not matches_current then return end
    hq_prepare_failure_generation = generation
    hq_prepare_failure_reason = code == 'cuda-driver-too-old'
        and 'NVIDIA 驱动版本低于当前 CUDA 运行库要求；请更新驱动并重启播放器'
        or code == 'device-contract-mismatch'
        and 'AI 配套设备模块缺失或版本不一致；请成套更新 vs 目录后重启播放器'
        or code == 'cuda-device-request-invalid'
        and 'AI 设备参数未通过解析；请核对配套设备模块与所选设备，当前保持普通播放'
        or 'TensorRT 后台准备失败；本文件改用兼容方案'
    -- A loaded Python runtime cannot be swapped in-process. Before it is
    -- loaded, native RIFE can safely re-plan with the portable Vulkan backend.
    publish_hq_state()
    schedule_evaluate(0.05)
end

local function monitor_background_pressure()
    local watch = preparation_watch
    if not watch or background.status ~= 'preparing' then
        preparation_watch = nil
        return
    end
    local now = mp.get_time()
    local position = mp.get_property_number('time-pos', nil)
    local drops = mp.get_property_number('frame-drop-count', 0) or 0
    if mp.get_property_bool('pause', false)
        or mp.get_property_bool('paused-for-cache', false)
        or mp.get_property_bool('seeking', false) then
        watch.time, watch.position, watch.drops = now, position, drops
        return
    end
    local elapsed = now - watch.time
    local progress = position and watch.position and position - watch.position
    local speed = math.max(0.01, mp.get_property_number('speed', 1) or 1)
    local pressure = drops - watch.drops >= 2
        or (elapsed >= 1 and progress and progress >= 0
            and progress < elapsed * speed * 0.65)
    if not pressure then return end
    prepared_specs[preparation_key(watch.spec)] = 'interrupted'
    preparation_watch = nil
    background:cancel('interrupted')
    publish('native', '普通播放', '后台检测出现播放压力，已停止并保持普通播放', false)
    mp.osd_message(i18n.t('已停止 AI 后台检测，优先保持当前播放流畅'), 3)
    msg.info('AI background probe stopped to protect playback')
end

local function monitor_guard()
    if (state ~= 'active' and state ~= 'spatial') or not active then return end
    local now = mp.get_time()
    local drops = mp.get_property_number('frame-drop-count', 0) or 0
    local mistimed = mp.get_property_number('mistimed-frame-count', 0) or 0
    if not activation_committed
        or mp.get_property_bool('paused-for-cache', false) or mp.get_property_bool('seeking', false)
        or mp.get_property_bool('pause', false) or now < guard_ready_at then
        -- Discard counters accumulated by model warm-up, seeks, decoder-pool
        -- rebuilds and cadence-policy changes. Carrying them into the first
        -- live sample can falsely downgrade an otherwise healthy GPU.
        guard_bad_samples = 0
        guard_drop_only_samples = 0
        if mp.get_property_bool('paused-for-cache', false)
            or mp.get_property_bool('seeking', false)
            or mp.get_property_bool('pause', false) then
            guard_ready_at = now + 2
        end
        last_drops, last_mistimed = drops, mistimed
        reset_progress_guard()
        return
    end
    local position = mp.get_property_number('time-pos', nil)
    local wall_delta = last_progress_wall and (now - last_progress_wall) or 0
    local position_delta = position and last_progress_pos and (position - last_progress_pos) or 0
    local speed = math.max(0.01, mp.get_property_number('speed', 1) or 1)
    local expected_progress = wall_delta * speed
    local progress_ratio = 1
    local progress_valid = position ~= nil and last_progress_pos ~= nil
        and wall_delta >= math.max(0.25, o.guard_interval * 0.45)
        and position_delta >= -0.05
        and position_delta <= expected_progress * 2.5 + 0.5
    if progress_valid and expected_progress > 0 then
        progress_ratio = math.max(0, position_delta / expected_progress)
    end
    last_progress_wall, last_progress_pos = now, position
    local drop_delta = math.max(0, drops - last_drops)
    local mistimed_delta = math.max(0, mistimed - last_mistimed)
    local avsync = math.abs(mp.get_property_number('avsync', 0) or 0)
    last_drops, last_mistimed = drops, mistimed
    local render_overload = drop_delta >= o.guard_drop_delta
        or mistimed_delta >= o.guard_mistimed_delta
    local clock_or_source_pressure = avsync >= o.guard_avsync
        or (progress_valid and progress_ratio < o.guard_progress_ratio)
    local drop_only = drop_delta >= o.guard_drop_delta
        and mistimed_delta < o.guard_mistimed_delta and not clock_or_source_pressure
    if drop_only then
        guard_drop_only_samples = guard_drop_only_samples + 1
        guard_bad_samples = 0
        if guard_drop_only_samples >= 2 then
            msg.info(string.format(
                'RIFE drop-only guard sample %d/%d: drop +%d, mistimed +%d, A-V %.3fs, progress %.0f%%, VO ratio %s',
                guard_drop_only_samples, math.max(2, o.guard_drop_only_bad_samples),
                drop_delta, mistimed_delta, avsync, progress_ratio * 100,
                tostring(mp.get_property_native('user-data/adaptive-quality/render-ratio') or '-')))
        end
    elseif render_overload or clock_or_source_pressure then
        guard_bad_samples = guard_bad_samples + 1
        guard_drop_only_samples = 0
    else
        guard_bad_samples, guard_drop_only_samples = 0, 0
    end
    if guard_bad_samples >= math.max(1, o.guard_bad_samples)
        or guard_drop_only_samples >= math.max(2, o.guard_drop_only_bad_samples) then
        local reason = string.format(
            '连续实时过载（drop +%d / mistimed +%d / A-V %.3fs / 进度 %.0f%%）',
            drop_delta, mistimed_delta, avsync, progress_ratio * 100)
        local clock_state = mp.get_property_native(
            'user-data/video-enhancement/rife-clock-guard') or 'idle'
        if not audio_is_passthrough() and clock_state ~= 'protected'
            and not cadence_safe_requested then
            -- RIFE has already produced real 2x frames. On a high-resolution
            -- On a 120/144 Hz desktop, the secondary display-resample pass can consume
            -- the remaining VO budget even when inference itself is healthy.
            -- Keep RIFE first, shed only that optional cadence-alignment layer,
            -- then use the normal sustained-failure fallback only if pressure remains.
            cadence_safe_requested = true
            guard_bad_samples, guard_drop_only_samples = 0, 0
            last_drops, last_mistimed = drops, mistimed
            reset_progress_guard()
            guard_ready_at = mp.get_time() + math.max(4, o.guard_interval * 2)
            mp.commandv('script-message-to', 'adaptive_quality', 'rife-clock-safe', reason)
            msg.warn('RIFE cadence protection requested: ' .. reason)
            if o.show_osd then
                mp.osd_message(i18n.t('RIFE 性能保护：保留真实 2×，关闭高刷二次对齐'), 3)
            end
            return
        end
        fallback_after_overload(reason)
    end
end

mp.register_event('file-loaded', function()
    hdr_policy.reset_startup(true)
    publish_auto_status('idle')
    local continuing_spec = background:next_file()
    mp.set_property_native('user-data/video-enhancement/ai-auto-safe', 'unknown')
    mp.set_property_native('user-data/video-enhancement/ai-probe-verdict', 'unknown')
    mp.set_property_native('user-data/video-enhancement/ai-backend-device-ordinal', 'unknown')
    mp.set_property_native('user-data/video-enhancement/ai-backend-device-name', 'unknown')
    mp.set_property_native('user-data/video-enhancement/ai-backend-device-identity', 'unknown')
    set_native_if_changed('user-data/video-enhancement/ai-probe', '')
    generation = generation + 1
    invalidate_prepared_auto_pending()
    prepared_auto_attempted_generation = -1
    prepared_auto_external_generation = -1
    set_native_if_changed('user-data/video-enhancement/ai-file-generation', generation)
    active_auto_key = nil
    hq_prepare_failure_generation = -1
    hq_prepare_failure_reason = nil
    blocked_generation = -1
    blocked_reason = nil
    blocked_protected = false
    validated_cfr_generation = -1
    validated_source_fps = 0
    startup_gate_generation = -1
    cadence_safe_requested = false
    guard_ready_at = 0
    last_progress_wall, last_progress_pos = nil, nil
    loaded = true
    remove_filter()
    activation_started_at = 0
    graph_build_seconds = 0
    local selected_mode = mode()
    local no_ai_policy = not o.enabled or (o.hq_processing_mode ~= 'ai_superres'
        and (selected_mode == 'off' or selected_mode == 'performance'))
    if no_ai_policy then
        background:reset()
        preparation_watch = nil
    elseif continuing_spec then
        -- Reset playback-pressure counters for this file without restarting
        -- the model builder. A different current spec cancels it in allow().
        preparation_watch = {
            spec=continuing_spec, time=mp.get_time(),
            position=mp.get_property_number('time-pos', nil),
            drops=mp.get_property_number('frame-drop-count', 0) or 0,
        }
    end
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase',
        no_ai_policy and 'idle' or 'waiting')
    set_native_if_changed('user-data/video-enhancement/ai-warmup-seconds', '')
    set_native_if_changed('user-data/video-enhancement/ai-graph-build-seconds', '')
    set_native_if_changed('user-data/video-enhancement/ai-safety-limit',
        '正在计算当前显卡与策略上限')
    if no_ai_policy then
        -- Disabled AI and basic smoothing need no AI admission check.
        -- Publishing `detecting` here briefly disables native smoothing on
        -- every file and can disturb the first frames and subtitle cadence.
        publish(not o.enabled and 'unavailable'
                or selected_mode == 'off' and 'off' or 'native',
            not o.enabled and 'AI 扩展已关闭'
                or selected_mode == 'off' and 'AI 未启用' or '原生轻量平滑',
            not o.enabled and 'AI 扩展已关闭'
                or selected_mode == 'off' and '用户已关闭补帧'
                or '性能优先使用 mpv 原生平滑', false)
        schedule_evaluate(0.05)
    else
        publish('detecting', '检测中', '确认 SDR、CFR、分辨率、帧率与显卡余量', false)
        schedule_evaluate(prepared_backend and 0.05 or o.start_delay)
    end
end)

mp.register_event('end-file', function()
    hdr_policy.reset_startup(false)
    publish_auto_status('idle')
    background:next_file()
    preparation_watch = nil
    generation = generation + 1
    invalidate_prepared_auto_pending()
    prepared_auto_attempted_generation = -1
    prepared_auto_external_generation = -1
    set_native_if_changed('user-data/video-enhancement/ai-file-generation', generation)
    loaded = false
    last_progress_wall, last_progress_pos = nil, nil
    remove_filter()
    set_native_if_changed('user-data/video-enhancement/ai-warmup-phase', 'idle')
    set_native_if_changed('user-data/video-enhancement/ai-safety-limit', '等待视频')
    publish('idle', '等待视频', '下一段视频将重新评估', false)
end)

mp.register_event('seek', function()
    invalidate_prepared_auto_pending()
    if state == 'starting' and filter_present() then
        -- Adding VapourSynth rebuilds the video chain and emits an internal
        -- seek. Keep the in-flight filter instead of mistaking it for a user
        -- jump and tearing it down before the first interpolated frame.
        return
    elseif active then
        -- The managed RIFE filter entry remains installed while mpv resets its
        -- inner VapourSynth frame queue. Publishing `starting` here used to
        -- make adaptive-quality disable and re-apply display-sync/upscaling;
        -- a queued evaluate could also remove/re-add the filter and cause a
        -- second initialization. Keep output policy intact and expose a
        -- separate transient state that has no effect on budgeting.
        cancel_timer(verify_timer)
        verify_timer = nil
        if not seek_recovery_started then seek_recovery_started = mp.get_time() end
        publish_seek_recovery(true, '正在精准定位并恢复 AI 帧窗口')
        local now = mp.get_time()
        guard_ready_at = now + math.max(0, o.guard_start_delay)
        guard_bad_samples = 0
        guard_drop_only_samples = 0
        last_drops = mp.get_property_number('frame-drop-count', 0) or 0
        last_mistimed = mp.get_property_number('mistimed-frame-count', 0) or 0
        reset_progress_guard()
    else
        schedule_evaluate(0.6)
    end
end)

mp.register_event('playback-restart', function()
    hdr_policy.observe_frame()
    if not seek_recovery then return end
    local recovery_seconds = seek_recovery_started
        and math.max(0, mp.get_time() - seek_recovery_started) or 0

    if not filter_present() then
        msg.warn('RIFE filter disappeared during seek; scheduling a safe recovery')
        remove_filter()
        publish('detecting', '检测中', '跳转后重新确认 RIFE 视频链', false)
        schedule_evaluate(0.1)
        return
    end

    publish_seek_recovery(false)
    local now = mp.get_time()
    guard_ready_at = now + math.max(0, o.guard_start_delay)
    guard_bad_samples = 0
    guard_drop_only_samples = 0
    last_drops = mp.get_property_number('frame-drop-count', 0) or 0
    last_mistimed = mp.get_property_number('mistimed-frame-count', 0) or 0
    reset_progress_guard()
    msg.info(string.format('RIFE seek recovered in %.3fs without filter-chain teardown',
        recovery_seconds))
end)

mp.observe_property('pause', 'bool', function(_, paused)
    local was_paused = observed_pause
    observed_pause = paused == true
    if startup_gate_owned and paused == false then
        -- The user (or another cache controller) resumed playback while the
        -- model was warming up. Relinquish ownership so a later verification
        -- callback can never re-toggle their pause choice.
        startup_gate_owned = false
        cancel_timer(startup_gate_timer)
        startup_gate_timer = nil
    end
    if was_paused == true and paused == false and activation_committed
        and active and filter_present() then
        -- Resuming after a user pause, timeline interaction or cache controller
        -- can recreate output textures and briefly release queued frames. Start
        -- a fresh live window at the resume edge instead of inheriting the last
        -- timer phase from the paused period (which could leave almost no grace).
        local now = mp.get_time()
        guard_ready_at = now + math.max(0, o.guard_start_delay)
        guard_bad_samples = 0
        guard_drop_only_samples = 0
        last_drops = mp.get_property_number('frame-drop-count', 0) or 0
        last_mistimed = mp.get_property_number('mistimed-frame-count', 0) or 0
        reset_progress_guard()
        msg.info('RIFE guard resume cooldown started')
    end
end)

mp.register_script_message('refresh', function()
    if graph_state ~= 'absent' then
        -- Rechecking shader/adapter status must not revoke an already bound
        -- VF or its one-time preparation approval.
        publish_hq_state()
        if state ~= 'starting' then schedule_evaluate(0.1) end
        return
    end
    prepared_specs = {}
    prepared_benchmarks = {}
    prepared_device_identities = {}
    prepared_devices = {}
    auto_retry_disabled_specs = {}
    set_native_if_changed('user-data/video-enhancement/ai-probe', '')
    canceled_generation = -1
    background:reset()
    blocked_generation = -1
    blocked_reason = nil
    blocked_protected = false
    if filter_present() then remove_filter() end
    publish_hq_state()
    schedule_evaluate(0.1)
end)

mp.register_script_message('set-backend', function(value, silent)
    value = normalize_backend_mode(value)
    local quiet = tostring(silent or ''):lower() == 'silent'
    if value == 'nvidia_hq' then
        local ready = runtime_ready('nvidia_hq')
        local supported, reason = hq_gpu_support()
        if not hq_pack_present() or not ready then
            if not quiet then mp.osd_message(i18n.t('高端依赖包未完整安装，已保持当前安全后端'), 3) end
            publish_hq_state()
            return
        elseif not supported then
            if not quiet then mp.osd_message(i18n.status(tostring(reason)) .. i18n.t('，已保持当前安全后端'), 3) end
            publish_hq_state()
            return
        end
    end

    local previous_backend = desired_backend()
    local previous_hq_mode = o.hq_processing_mode
    local changes = {backend_mode=value}
    if value == 'vulkan' then changes.hq_processing_mode = 'native' end
    if next(changes) and not persist_options(changes) then return end
    o.backend_mode = value
    if changes.hq_processing_mode then o.hq_processing_mode = changes.hq_processing_mode end
    local target = desired_backend()
    if runtime_environment_backend and target ~= runtime_environment_backend then
        hq_restart_required = true
        publish_hq_state()
        if not quiet then
            mp.osd_message(i18n.t('VF 后端已保存：') .. i18n.t(backend_mode_labels[value])
                .. i18n.t('\n重启播放器后生效，当前播放链保持稳定'), 4)
        end
        return
    end

    hq_restart_required = false
    publish_hq_state()
    if not active and (target ~= previous_backend or o.hq_processing_mode ~= previous_hq_mode) then
        blocked_generation = -1
        blocked_reason = nil
        blocked_protected = false
        schedule_evaluate(0.1)
    end
    if not quiet then mp.osd_message(i18n.t('VF 后端：') .. i18n.t(backend_mode_labels[value]), 2.5) end
end)

mp.register_script_message('set-hq-mode', function(value, silent)
    value = normalize_hq_processing_mode(value)
    local quiet = tostring(silent or ''):lower() == 'silent'
    if value ~= 'native' then
        local ready, missing = hq_full_pack_ready()
        local supported, reason = hq_gpu_support()
        if not ready then
            local missing_name = tostring(missing or '运行文件'):match('[^\\]+$') or '运行文件'
            if not quiet then
                mp.osd_message(i18n.t('完整超分补帧依赖包未就绪：缺少 ') .. missing_name, 4)
            end
            publish_hq_state()
            return
        elseif not supported then
            if not quiet then mp.osd_message(i18n.status(tostring(reason)), 3) end
            publish_hq_state()
            return
        end
        -- Explicit full-package pipelines always use the TensorRT runtime.
        -- Persist both values as one user action; a loaded Vulkan/Python 3.12
        -- runtime is kept intact until the next process.
    end

    local changed = o.hq_processing_mode ~= value
    local changes = {hq_processing_mode=value}
    if value ~= 'native' then changes.backend_mode = 'nvidia_hq' end
    if next(changes) and not persist_options(changes) then return end
    if changes.backend_mode then o.backend_mode = changes.backend_mode end
    o.hq_processing_mode = value
    local target = desired_backend()
    if runtime_environment_backend and target ~= runtime_environment_backend then
        hq_restart_required = true
        publish_hq_state()
        if not quiet then
            mp.osd_message(i18n.t('完整依赖方案已保存：') .. i18n.t(hq_processing_mode_labels[value])
                .. i18n.t('\n重启播放器后生效，当前播放链保持稳定'), 4)
        end
        return
    end
    hq_restart_required = false
    publish_hq_state()
    if not changed then
        if not quiet then mp.osd_message(i18n.t('完整依赖方案：') .. i18n.t(hq_processing_mode_labels[value]), 3) end
        return
    end
    blocked_generation = -1
    blocked_reason = nil
    blocked_protected = false
    schedule_evaluate(0.1)
    if not quiet then
        mp.osd_message(i18n.t('完整依赖方案：') .. i18n.t(hq_processing_mode_labels[value]), 3)
    end
end)

mp.register_script_message('set-hdr-vivid-mode', function(value)
    value = hdr_policy.normalize(value)
    local changed = o.hdr_vivid_mode ~= value
    if not persist_ai_option('hdr_vivid_mode', value) then return end
    o.hdr_vivid_mode = value
    if changed and (mp.get_property_bool('video-params/hdr-vivid', false)
        or active_plan and active_plan.vivid_compat) then
        -- Explicit permission is separate from the AI mode and one-attempt
        -- budget. Revoke pending work/approval before accepting new policy;
        -- neither a canceled file nor a failed spec is silently retried.
        invalidate_prepared_auto_pending()
        background:reset()
        if active_plan and active_plan.vivid_compat then
            remove_filter()
            -- Observer traffic during decoder reconfiguration may postpone
            -- evaluation. A removed graph must stop claiming activity now.
            publish('protected', '格式保护', select(2, hdr_policy.check()), false)
        end
        set_native_if_changed('user-data/video-enhancement/ai-probe', '')
        set_native_if_changed('user-data/video-enhancement/ai-probe-verdict', 'unknown')
    end
    publish_hq_state()
    schedule_evaluate(0.05)
    mp.osd_message((value == 'hdr10'
        and i18n.t('已允许普通 HDR 基底兼容补帧\n不应用 Vivid 专属动态映射；需另行开启 AI 补帧')
        or i18n.t('HDR Vivid：保持原有处理，不启用 AI 补帧'))
, 5)
end)

mp.register_script_message('show-diagnostics', function()
    local plan = active_plan or {}
    local probe = trim(mp.get_property_native(
        'user-data/video-enhancement/ai-probe') or '')
    local source_w = mp.get_property_number('video-params/w', 0) or 0
    local source_h = mp.get_property_number('video-params/h', 0) or 0
    local output_w = mp.get_property_number('video-out-params/w', 0) or 0
    local output_h = mp.get_property_number('video-out-params/h', 0) or 0
    local filter_details = i18n.t('当前无托管 AI 滤镜')
    local filters = mp.get_property_native('vf')
    for _, filter in ipairs(type(filters) == 'table' and filters or {}) do
        if type(filter) == 'table' and filter.label == 'yaozhi_ai' then
            msg.info('AI 滤镜完整参数：' .. utils.format_json(filter))
            filter_details = i18n.t('完整内容已写入日志（AI 滤镜完整参数）')
        end
    end
    local lines = {
        i18n.t('视频增强诊断'),
        i18n.t('起播格式：') .. i18n.status(tostring(mp.get_property_native('user-data/video-enhancement/ai-startup-format-state') or 'idle'))
            .. ' · ' .. i18n.status(tostring(mp.get_property_native('user-data/video-enhancement/ai-startup-format-detail') or '')),
        i18n.t('HDR Vivid 选择：') .. (o.hdr_vivid_mode == 'hdr10' and i18n.t('允许普通 HDR 基底兼容补帧（不应用 Vivid 动态映射）')
            or i18n.t('默认保持原有处理')),
        i18n.t('格式处理：') .. i18n.status(select(2, hdr_policy.check())),
        i18n.t('普通 HDR 兼容补帧实际接入：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/ai-hdr-compat-active') or 'no')),
        i18n.t('依赖：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/hq-status') or i18n.t('未检测'))),
        i18n.t('能力码：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/hq-capability-code') or i18n.t('未检测'))),
        i18n.t('策略：') .. i18n.status(tostring(hq_processing_mode_labels[o.hq_processing_mode])),
        i18n.t('请求：后端=') .. tostring(o.backend_mode) .. i18n.t(' · 处理=') .. tostring(o.hq_processing_mode)
            .. i18n.t(' · 流畅=') .. mode(),
        i18n.t('实际后端：') .. i18n.status(tostring(plan.backend_label
            or mp.get_property_native('user-data/video-enhancement/ai-backend') or i18n.t('等待视频'))),
        i18n.t('滤镜参数：') .. filter_details,
        i18n.t('决策原因：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/ai-reason-code') or i18n.t('等待检测')))
            .. ' · ' .. i18n.status(tostring(mp.get_property_native(
                'user-data/video-enhancement/ai-reason-detail') or i18n.t('等待视频'))),
        string.format(i18n.t('尺寸：源 %d×%d → 推理 %d×%d → 输出 %d×%d'),
            source_w, source_h,
            plan.inference_width or source_w, plan.inference_height or source_h,
            output_w > 0 and output_w or (plan.output_width or source_w),
            output_h > 0 and output_h or (plan.output_height or source_h)),
        i18n.t('时间：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/smooth-detail') or i18n.t('等待视频'))),
        i18n.t('空间：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/superres-detail') or i18n.t('等待视频'))),
        'Shader：' .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/shader-ownership') or 'none'))
            .. ' · ' .. i18n.status(tostring(mp.get_property_native(
                'user-data/video-enhancement/shader-active-roles') or i18n.t('无')))
            .. ' · ' .. i18n.status(tostring(mp.get_property_native(
                'user-data/video-enhancement/shader-active-stages') or i18n.t('无'))),
        i18n.t('保护：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/ai-safety-limit') or i18n.t('等待检测'))),
        i18n.t('后台测速：') .. (probe ~= '' and probe or i18n.t('尚无当前规格结果')),
        i18n.t('预热：') .. i18n.status(tostring(mp.get_property_native(
            'user-data/video-enhancement/ai-warmup-phase') or 'idle'))
            .. i18n.t(' · 总计 ') .. i18n.status(tostring(mp.get_property_native(
                'user-data/video-enhancement/ai-warmup-seconds') or '-')) .. 's'
            .. i18n.t(' · 建图 ') .. i18n.status(tostring(mp.get_property_native(
                'user-data/video-enhancement/ai-graph-build-seconds') or '-')) .. 's',
    }
    local text = table.concat(lines, '\n')
    mp.osd_message(text, 8)
    msg.info(text:gsub('\n', ' | '))
end)

mp.register_script_message('enable-prepared', function()
    if not loaded or graph_state ~= 'absent' or filter_present() then return end
    if background:enable() then
        publish_auto_status('manual')
        -- An explicit manual action authorizes one new attempt after fallback.
        blocked_generation = -1
        blocked_reason = nil
        blocked_protected = false
        canceled_generation = -1
        schedule_evaluate(0.05)
    end
end)
mp.register_script_message('cancel-prepare', function()
    local opening = mp.get_property_native('user-data/video-enhancement/ai-startup-format-state')
    local pending_opening = o.enabled and loaded and graph_state == 'absent' and hdr_policy.startup_candidate()
        and (mode() == 'auto' or mode() == 'quality')
    if background.status ~= 'preparing' and background.status ~= 'ready'
        and opening ~= 'waiting-frame' and opening ~= 'settling' and opening ~= 'replanning'
        and not pending_opening then return end
    canceled_generation = generation
    publish_auto_status('blocked')
    invalidate_prepared_auto_pending()
    -- A completed worker has nothing to cancel. Keep its exact-spec result
    -- ready for an explicit manual trial while blocking this file's auto path.
    if background.status == 'preparing' then background:cancel('canceled') end
    schedule_evaluate(0.05)
end)
mp.register_script_message('retry-prepare', function()
    if graph_state ~= 'absent' or filter_present() then return end
    hq_prepare_failure_generation = -1
    hq_prepare_failure_reason = nil
    prepared_specs = {}
    prepared_benchmarks = {}
    prepared_device_identities = {}
    prepared_devices = {}
    auto_retry_disabled_specs = {}
    publish_auto_status('idle')
    set_native_if_changed('user-data/video-enhancement/ai-probe', '')
    canceled_generation = -1
    blocked_generation = -1
    blocked_reason = nil
    blocked_protected = false
    background:retry(); schedule_evaluate(0.05)
end)
mp.register_event('shutdown', function() background:reset() end)

mp.register_script_message('rife-quality-ready', function(token)
    if token == graph_token then finish_activation(token, 'AI ready') end
end)

mp.register_script_message('rife-spatial-blocked', function(reason, token)
    if token ~= graph_token then return end
    protect_current_file(trim(reason) ~= '' and reason
        or '空间画质不得倒退：已保留原有超分质量')
end)

for _, property in ipairs({
    'user-data/video-enhancement/smooth-mode',
    'user-data/video-enhancement/superres-mode',
    'user-data/adaptive-quality/adapter-ready',
    'user-data/adaptive-quality/tier',
    'user-data/adaptive-quality/gpu-index',
    'user-data/video-enhancement/protect-4k',
    'user-data/video-enhancement/rife-spatial-compatible',
    'user-data/alist/archive-inner',
    'speed',
    'audio-params',
    'audio-out-params',
    'user-data/audio-passthrough/enabled',
    -- Do not observe the aggregate video-params table. HDR10+ updates dynamic
    -- metadata throughout playback, and every parent-table notification used
    -- to republish the unchanged AI fallback and rebuild the display-sync path.
    'video-params/w',
    'video-params/h',
    'video-params/gamma',
    'video-params/primaries',
    'video-params/colormatrix',
    'video-params/hdr-vivid',
    'video-params/hw-pixelformat',
    'video-params/pixelformat',
    'current-vo',
    'video-params/dolby-vision-profile',
    'current-tracks/video/dolby-vision-profile',
    'user-data/media-format/dolby-vision-profile',
    'video-frame-info/interlaced',
    'container-fps',
    'estimated-vf-fps',
}) do
    mp.observe_property(property, 'native', function()
        if property == 'video-params/hdr-vivid' and hdr_policy.tracking
            and mp.get_property_bool(property, false) then hdr_policy.target_vivid = true end
        publish_hq_state(true)
        local policy_or_source_changed = property == 'user-data/video-enhancement/smooth-mode'
            or property == 'user-data/video-enhancement/superres-mode'
            or property == 'user-data/video-enhancement/protect-4k'
            or property == 'video-params/w' or property == 'video-params/h'
            or property == 'video-params/gamma' or property == 'video-params/primaries'
            or property == 'video-params/colormatrix' or property == 'video-params/hdr-vivid'
            or property == 'video-params/hw-pixelformat' or property == 'video-params/pixelformat'
            or property == 'current-vo' or property:find('dolby-vision-profile', 1, true) ~= nil
        if policy_or_source_changed or property == 'speed' then invalidate_prepared_auto_pending() end
        -- Most observer updates during VF creation are feedback from that same
        -- creation and must not recursively evaluate it. Explicit AI policy or
        -- real source geometry changes are different: a user may disable AI
        -- while the first graph is still verifying, and that choice must win.
        if loaded and (state ~= 'starting' or policy_or_source_changed) then
            if property == 'estimated-vf-fps' and o.auto_enable_prepared
                and background.status == 'ready'
                and (prepared_specs[background.key] == 'safe' or prepared_specs[background.key] == 'slow') then
                -- The validated CFR/exact spec is checked by evaluate.
                -- Ordinary per-frame estimator noise must neither restart
                -- the stable window nor postpone its already queued check.
                if not prepared_auto_pending then schedule_evaluate(0.2, true) end
                return
            end
            schedule_evaluate(property == 'video-params/hdr-vivid' and 0.05 or 0.2)
        end
    end)
end

-- Only the first real decoded-frame observation can wake a waiting opener;
-- later frame-info updates do not re-evaluate the AI policy on every frame.
mp.observe_property('video-frame-info', 'native', function()
    hdr_policy.observe_frame()
end)

-- Only changes which can authorize or interrupt the trial get an extra
-- observer. An outstanding stability check uses the one existing evaluate
-- timer, and a paused/cache-bound video waits for a real state change.
for _, property in ipairs({
    'user-data/video-enhancement/native-clock-guard',
    'user-data/video-enhancement/sync-managed',
    'video-sync', 'interpolation', 'pause', 'paused-for-cache', 'seeking', 'core-idle',
}) do
    mp.observe_property(property, 'native', function(_, value)
        if loaded and graph_state == 'absent' and value == 'external'
            and (property == 'user-data/video-enhancement/sync-managed'
                or property == 'user-data/video-enhancement/native-clock-guard') then
            -- Another script can later republish managed timing. That does not
            -- authorize a new automatic AI graph after this file's takeover.
            prepared_auto_external_generation = generation
        end
        invalidate_prepared_auto_pending()
        if loaded and graph_state == 'absent' then schedule_evaluate(0.2) end
    end)
end

-- A fullscreen/maximize/resize transition recreates the D3D swapchain and can
-- compile a new size-dependent upscale shader.  Those one-off output drops do
-- not measure RIFE throughput and must never rebuild the AI graph or poison its
-- learned GPU cap.  Track the actual OSD geometry as well as the window modes so
-- ordinary border resizing receives the same bounded protection.
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
            invalidate_prepared_auto_pending()
            if loaded and graph_state == 'absent' then schedule_evaluate(0.2) end
            reset_guard_for_presentation_change(property .. ' changed')
        end
    end)
end

mp.add_periodic_timer(math.max(0.5, o.guard_interval), monitor_guard)
mp.add_periodic_timer(0.25, monitor_background_pressure)
publish_seek_recovery(false)
publish_hq_state()
publish(o.enabled and 'idle' or 'unavailable',
    o.enabled and '等待视频' or 'AI 扩展已关闭',
    o.enabled and '便携 RIFE 运行库已就绪' or '使用第一阶段补帧策略', false)
