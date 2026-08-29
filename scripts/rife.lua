-- RIFE 补帧（VapourSynth + vs-mlrt NCNN/Vulkan 后端）
-- 依赖：vapoursynth-plugin-mlrt-ncnn-runtime（emoeem 仓库提供，
--       含 libvsncnn 插件、vsmlrt.py 与 RIFE v4.6 模型）
-- 用法：CTRL+ALT+r 开/关；参数见 script-opts/rife.conf
-- 说明：对 YUV 输入先做场景切换检测再转 RGBS 交给 RIFE；
--       切换场景时由 _SceneChange 属性回退到真实帧，避免跨场景插帧

local msg = require 'mp.msg'
local opts = require 'mp.options'

local o = {
    enabled = "no",   -- 加载文件时自动开启
    multi = "2",      -- 补帧倍数，支持小数（内部用 Fraction）
    scale = "1.0",    -- 光流处理分辨率，4K 建议 0.5（32/scale 必须为整数）
    model = "v4.6",   -- RIFE 模型版本
    fp16 = "yes",     -- Vulkan 半精度，RTX 显卡建议开启
    device_id = "0",  -- Vulkan 设备编号
    threshold = "0.1",-- 场景切换检测阈值
}
opts.read_options(o)

local label = "rife"
local active = false

local model_map = {
    ["v4"] = 40, ["v4.2"] = 42, ["v4.3"] = 43, ["v4.4"] = 44,
    ["v4.5"] = 45, ["v4.6"] = 46, ["v4.7"] = 47, ["v4.8"] = 48,
    ["v4.9"] = 49, ["v4.11"] = 411,
}

local function vpy_path()
    local cache = os.getenv("XDG_CACHE_HOME")
    if not cache or cache == "" then
        cache = os.getenv("HOME") .. "/.cache"
    end
    return cache .. "/mpv/rife.vpy"
end

local function build_vpy()
    local path = vpy_path()
    local dir = path:match("^(.*/)")
    if dir then
        os.execute(("mkdir -p '%s'"):format(dir))
    end

    local model = model_map[o.model]
    if not model then
        msg.warn(("未知模型 '%s'，回退 v4.6"):format(o.model))
        model = 46
    end
    local fp16 = (o.fp16 == "yes") and "True" or "False"
    local threshold = tonumber(o.threshold) or 0.1

    local script = ([[
import vapoursynth as vs
from fractions import Fraction

from vsmlrt import RIFE, Backend

core = vs.core
clip = video_in

if clip.format.color_family == vs.YUV:
    matrix = {
        0: "gbr", 1: "709", 4: "470c", 5: "470bg",
        6: "170m", 7: "240m", 9: "2020ncl", 10: "2020cl",
    }.get(clip.get_frame(0).props.get("_Matrix"))
    if matrix is None:
        matrix = "709" if clip.width >= 1000 else "470bg"
    clip = clip.misc.SCDetect(threshold=%s)
    clip = clip.resize.Bicubic(format=vs.RGBS, matrix_in_s=matrix)
elif clip.format.color_family == vs.RGB:
    clip = clip.resize.Bicubic(format=vs.RGBS)
else:
    raise ValueError("rife.vpy: unsupported color family")

clip = RIFE(
    clip,
    multi=Fraction(%s),
    scale=%s,
    model=%d,
    backend=Backend.NCNN_VK(fp16=%s, device_id=%s),
    video_player=True,
)
clip.set_output()
]]):format(threshold, o.multi, o.scale, model, fp16, o.device_id)

    local f = io.open(path, "w")
    if not f then
        msg.error("无法写入 " .. path)
        return nil
    end
    f:write(script)
    f:close()
    return path
end

local function enable()
    local path = build_vpy()
    if not path then
        return false
    end
    mp.commandv("vf", "add", ("@%s:vapoursynth=@%s"):format(label, path))
    active = true
    return true
end

local function disable()
    mp.commandv("vf", "remove", "@" .. label)
    active = false
end

local function toggle()
    if active then
        disable()
        mp.osd_message("RIFE 补帧：关闭", 2)
    else
        if enable() then
            mp.osd_message(("RIFE 补帧：开启（%s ×%s，NCNN Vulkan）"):format(o.model, o.multi), 2)
        end
    end
end

mp.add_key_binding(nil, "rife-toggle", toggle)

mp.register_event("file-loaded", function()
    if o.enabled == "yes" and not active then
        if enable() then
            msg.info("RIFE 补帧已自动开启")
        end
    end
end)
