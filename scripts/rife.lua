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
    scale = "1.0",    -- 光流处理分辨率，4K 建议 0.5
    model = "v4.6",   -- RIFE 模型版本
    fp16 = "yes",     -- Vulkan 半精度，RTX 显卡建议开启
    device_id = "0",  -- Vulkan 设备编号
    backend = "ort_cuda", -- 推理后端：ort_cuda / trt / ncnn
    threshold = "0.1",-- 场景切换检测阈值
}
opts.read_options(o)

local label = "rife"
local active = false
local enabled_at = 0

local model_map = {
    ["v4"] = 40, ["v4.2"] = 42, ["v4.3"] = 43, ["v4.4"] = 44,
    ["v4.5"] = 45, ["v4.6"] = 46, ["v4.7"] = 47, ["v4.8"] = 48,
    ["v4.9"] = 49, ["v4.11"] = 411,
}

local function vpy_path()
    -- 依次尝试可写位置：mpv 缓存目录 → XDG 缓存 → ~/.cache → /tmp 兜底，
    -- 避免缓存目录不可写时整个开关静默失败
    local candidates = {}
    local ok, expanded = pcall(function()
        return mp.command_native({ 'expand-path', '~~cache/rife.vpy' })
    end)
    if ok and type(expanded) == 'string' and expanded ~= '' then
        candidates[#candidates + 1] = expanded
    end
    local xdg = os.getenv("XDG_CACHE_HOME")
    if xdg and xdg ~= "" then
        candidates[#candidates + 1] = xdg .. "/mpv/rife.vpy"
    end
    local home = os.getenv("HOME")
    if home and home ~= "" then
        candidates[#candidates + 1] = home .. "/.cache/mpv/rife.vpy"
    end
    candidates[#candidates + 1] = "/tmp/mpv-rife.vpy"
    for _, path in ipairs(candidates) do
        local dir = path:match("^(.*/)")
        if dir then os.execute(("mkdir -p '%s'"):format(dir)) end
        local f = io.open(path, "w")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function build_vpy()
    local path = vpy_path()
    if not path then return nil end

    local model = model_map[o.model]
    if not model then
        msg.warn(("未知模型 '%s'，回退 v4.6"):format(o.model))
        model = 46
    end
    local fp16 = (o.fp16 == "yes") and "True" or "False"
    local threshold = tonumber(o.threshold) or 0.1
    -- 注意：vs-mlrt 官方说明 NCNN 后端不支持 RIFE（模型含 GridSample 算子），
    -- ncnn 选项仅作兼容保留；N 卡请用 ort_cuda（onnxruntime CUDA）或 trt（TensorRT）
    local backend_arg
    if o.backend == "trt" then
        backend_arg = ("Backend.TRT(device_id=%s, engine_folder=os.path.expanduser('~/.cache/vsmlrt'), "
            .. "num_streams=4, max_aux_streams=2, fp16=%s, force_fp16=%s, use_cuda_graph=True)"
            ):format(o.device_id, fp16, fp16)
    elseif o.backend == "ncnn" then
        backend_arg = ("Backend.NCNN_VK(fp16=%s, device_id=%s)"):format(fp16, o.device_id)
    else
        backend_arg = ("Backend.ORT_CUDA(fp16=%s, device_id=%s)"):format(fp16, o.device_id)
    end

    local script = ([[
import os
import sys

import vapoursynth as vs
from fractions import Fraction

# vsmlrt.py 安装在 vapoursynth 包的 plugins 子目录，不在默认 sys.path
_plugins = os.path.join(os.path.dirname(os.path.abspath(vs.__file__)), 'plugins')
if os.path.isdir(_plugins) and _plugins not in sys.path:
    sys.path.append(_plugins)

from vsmlrt import RIFE, Backend

core = vs.core
clip = video_in
_clip_in = clip
_out_matrix = None

def _mark_scene_change(_clip, _threshold):
    # 优先用 misc.SCDetect；未装 vapoursynth-misc 时用 std.PlaneStats 等效标记
    try:
        return _clip.misc.SCDetect(threshold=_threshold)
    except AttributeError:
        pass
    if _clip.format.color_family == vs.YUV:
        _gray = _clip.std.SplitPlanes()[0]
    else:
        _gray = _clip.resize.Bicubic(format=vs.GRAYS)
    _diff = _gray.std.PlaneStats(_gray.std.DuplicateFrames(0), prop='SC')

    def _apply(n, f):
        video, stats = f
        fout = video.copy()
        sc = stats.props.get('SCDiffAvg', 0) > _threshold
        fout.props['_SceneChangePrev'] = sc
        fout.props['_SceneChangeNext'] = sc
        return fout

    return core.std.ModifyFrame(_clip, [_clip, _diff], _apply)

if clip.format.color_family == vs.YUV:
    # mpv 初始化期不支持 get_frame()，矩阵按分辨率启发式推断
    # （SD <1000px 用 470bg，HD 用 709；极端情况可用 rife.conf 无法覆盖时可再调整）
    matrix = "709" if clip.width >= 1000 else "470bg"
    _out_matrix = matrix
    clip = _mark_scene_change(clip, %s)
    clip = clip.resize.Bicubic(format=vs.RGBS, matrix_in_s=matrix)
elif clip.format.color_family == vs.RGB:
    clip = clip.resize.Bicubic(format=vs.RGBS)
else:
    raise ValueError("rife.vpy: unsupported color family")

# v1 模型的 tile 对齐要求宽高被 32 整除（1080p/720p 等常见分辨率都不满足），
# 整帧补边到 32 的倍数再跑 RIFE，输出后裁回
_pad_w = (32 - clip.width %% 32) %% 32
_pad_h = (32 - clip.height %% 32) %% 32
if _pad_w or _pad_h:
    clip = clip.std.AddBorders(right=_pad_w, bottom=_pad_h)

clip = RIFE(
    clip,
    multi=Fraction(%s),
    scale=%s,
    model=%d,
    backend=%s,
    video_player=True,
)

if _pad_w or _pad_h:
    clip = clip.std.Crop(right=_pad_w, bottom=_pad_h)

# mpv 的 vf_vapoursynth 不接受 RGBS 输出，转回输入端的像素格式
if _clip_in.format.color_family == vs.YUV:
    clip = clip.resize.Bicubic(format=_clip_in.format.id, matrix_s=_out_matrix)
else:
    clip = clip.resize.Bicubic(format=_clip_in.format.id)
clip.set_output()
]]):format(threshold, o.multi, o.scale, model, backend_arg)

    local f = io.open(path, "w")
    if not f then
        msg.error("无法写入 " .. path)
        return nil
    end
    f:write(script)
    f:close()
    return path
end

-- 把状态发布到 user-data，供 uosc 时间轴胶囊等界面读取
local function publish_state()
    mp.set_property_native("user-data/rife", {
        active = active,
        model = o.model,
        multi = tonumber(o.multi) or 0,
    })
end

local function enable()
    local path = build_vpy()
    if not path then
        return false
    end
    mp.commandv("vf", "add", ("@%s:vapoursynth=%s"):format(label, path))
    active = true
    enabled_at = mp.get_time()
    publish_state()
    return true
end

local function disable()
    mp.commandv("vf", "remove", "@" .. label)
    active = false
    publish_state()
end

local function toggle()
    if active then
        disable()
        mp.osd_message("RIFE 补帧：关闭", 2)
    else
        if enable() then
            mp.osd_message(("RIFE 补帧：开启（%s ×%s，%s）"):format(o.model, o.multi, o.backend), 2)
        else
            mp.osd_message("RIFE 启动失败：无法写入脚本文件（详见终端）", 3)
        end
    end
end

mp.add_key_binding(nil, "toggle", toggle)  -- 对应 input.conf 的 script-binding rife/toggle

-- 滤镜可能因初始化失败被 mpv 自动移除，或经其他方式手动删除；
-- 监听 vf 链，一旦 @rife 消失就把内部状态同步为关闭
mp.observe_property('vf', 'native', function(_, filters)
	if not active then return end
	local found = false
	if type(filters) == 'table' then
		for _, f in ipairs(filters) do
			if type(f) == 'table' and f.label == label then
				found = true
				break
			end
		end
	end
	if not found then
		local just_failed = (mp.get_time() - enabled_at) < 6
		active = false
		publish_state()
		if just_failed then
			msg.error("RIFE 滤镜初始化失败，已被 mpv 移除：请查看终端中 VapourSynth/vulkan 相关报错")
			mp.osd_message("RIFE 初始化失败，滤镜已被移除（详见终端日志）", 4)
		else
			msg.info("RIFE 滤镜已不在滤镜链中，状态已同步为关闭")
		end
	end
end)

mp.register_event("file-loaded", function()
	if o.enabled == "yes" and not active then
		if enable() then
            msg.info("RIFE 补帧已自动开启")
        end
    end
end)

publish_state()
