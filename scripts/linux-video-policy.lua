-- Linux video policy: HDR/SDR normalization + optional RIFE admission.
-- The policy never invents a RIFE runtime. If the existing local RIFE script and
-- VapourSynth dependency are unavailable, it reports that fact and keeps mpv's
-- native gpu-next interpolation/shader pipeline untouched.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    enabled = true,
    rife = 'auto', -- auto|off|always
    rife_max_fps = 30.5,
    rife_max_width = 1920,
    rife_max_height = 1080,
    rife_min_fps = 20,
    hdr_mode = 'auto',
}
options.read_options(o, 'linux_video_policy')

local function exists(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close(); return true
end

local function set(key, value)
    mp.set_property_native('user-data/linux-video-policy/' .. key, value)
end

local function detect_rife()
    local script = mp.command_native({'expand-path', '~~/scripts/rife.lua'})
    local vapoursynth = false
    local result = mp.command_native({name='subprocess', playback_only=false,
        capture_stdout=true, capture_stderr=true,
        args={'bash','-lc','command -v vapoursynth >/dev/null 2>&1'}})
    vapoursynth = type(result) == 'table' and tonumber(result.status) == 0
    local py = mp.command_native({name='subprocess', playback_only=false,
        capture_stdout=true, capture_stderr=true,
        args={'bash','-lc','python3 -c "import importlib.util as u; raise SystemExit(0 if u.find_spec(\'vapoursynth\') and u.find_spec(\'k7sfunc\') else 1)"'}})
    local k7 = type(py) == 'table' and tonumber(py.status) == 0
    return exists(script) and vapoursynth and k7
end

local rife_available = detect_rife()

local function apply_color_policy()
    if o.hdr_mode ~= 'auto' then return end
    local gamma = tostring(mp.get_property('video-params/gamma', '') or ''):lower()
    local prim = tostring(mp.get_property('video-params/primaries', '') or ''):lower()
    local hdr = gamma == 'pq' or gamma == 'hlg' or prim == 'bt.2020'
    if hdr then
        mp.set_property('target-colorspace-hint', 'auto')
        mp.set_property('target-trc', 'auto')
        mp.set_property('target-prim', 'auto')
        mp.set_property('inverse-tone-mapping', 'no')
        set('dynamic-range', 'HDR')
        set('hdr-action', 'preserve-source-and-display-auto')
    else
        mp.set_property('target-colorspace-hint', 'auto')
        mp.set_property('target-trc', 'auto')
        mp.set_property('target-prim', 'auto')
        set('dynamic-range', 'SDR')
        set('hdr-action', 'normal-sdr')
    end
end

local function apply_rife_policy()
    local w = mp.get_property_number('video-params/w', 0) or 0
    local h = mp.get_property_number('video-params/h', 0) or 0
    local fps = mp.get_property_number('container-fps', 0) or 0
    local mode = tostring(o.rife):lower()
    local eligible = rife_available and w > 0 and h > 0 and fps >= o.rife_min_fps
        and fps <= o.rife_max_fps and w <= o.rife_max_width and h <= o.rife_max_height
    local reason = not rife_available and 'RIFE 依赖未安装，保持原生策略'
        or mode == 'off' and '用户关闭 RIFE'
        or not eligible and string.format('当前 %dx%d %.3ffps 不在自动 RIFE 安全范围', w,h,fps)
        or 'RIFE 具备自动准入条件'
    set('rife-available', rife_available and 'yes' or 'no')
    set('rife-request', eligible and mode ~= 'off' and 'yes' or 'no')
    set('rife-reason', reason)
    -- Do not call the legacy rife.lua automatically: it uses a separate
    -- manually-generated VPy and its configured backend may be incompatible
    -- with the installed Linux runtime. This policy is an admission controller
    -- until a verified k7sfunc/vs-mlrt package is present.
end

local function evaluate()
    if not o.enabled or not mp.get_property_native('vid') then return end
    apply_color_policy()
    apply_rife_policy()
end

mp.register_event('file-loaded', function() mp.add_timeout(0.2, evaluate) end)
for _, p in ipairs({'video-params/w','video-params/h','video-params/gamma','video-params/primaries','container-fps'}) do
    mp.observe_property(p, 'native', function() if mp.get_property_native('vid') then mp.add_timeout(0.15, evaluate) end end)
end
set('rife-available', rife_available and 'yes' or 'no')
set('rife-backend', 'k7sfunc/VapourSynth admission only')
