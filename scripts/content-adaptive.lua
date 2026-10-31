--[[
    content-adaptive.lua — Linux 原生内容自适应画质引擎

    按内容类型（动画/真人）× 分辨率分档（SD/HD/4K）× 帧率，在文件加载时自动
    挂载一组超分着色器（glsl-shaders 整列表替换，@auto: 标签）。HDR 与直播源
    不挂载，交给现有 HDR 链与低延迟链路。

    职责边界：
    - 手动让位：用户用 CTRL+0~9 / ALT+1~8 或其它途径改动 glsl-shaders 时，
      本文件内自动暂停（下个文件恢复）。
    - 掉帧降档：VO 掉帧速率超阈值时自动降档（重型组 → 轻量组 → 仅色度增强）。
    - uosc 契约：实现「超分与补帧」菜单的 set-superres / set-smooth / set-profile
      消息与 user-data/video-enhancement/* 状态（菜单条目已在 menus.lua 中改指本脚本）。
    - 不做补帧：AI 补帧运行时（vs-mlrt）未安装，smooth 档位仅记录意图，播放保持原生。
--]]

local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    enabled = true,
    -- 动画判定：文件名命中压制组/片源关键词，或路径命中目录关键词
    anime_keywords = 'VCB-Studio,LoliHouse,Snow-Raws,Nekomoe,SweetSub,Moozzi2,SubsPlease,' ..
        'Ohys-Raws,Leopard-Raws,DHR,Baha,B-Global,AT-X,NC-RAWS,Kamigami,SMthsMix,anime',
    anime_dir_keywords = 'anime,动漫,动画,番剧',
    sd_max_width = 1280,
    sd_max_height = 720,
    uhd_min_width = 3840,
    high_fps_threshold = 47,
    -- 掉帧降档：drop_window_s 秒窗口内 VO 掉帧超过 drop_limit 帧 → 降一档
    drop_window_s = 30,
    drop_limit = 60,
    degrade_cooldown_s = 60,
    degrade_max = 2,
    -- 预设着色器（逗号分隔为一组），可用 ~~ 前缀
    krig = '~~/shaders/igv/KrigBilateral.glsl',
    preset_anime_sd = '~~/shaders/igv/FSRCNNX_x1_16-0-4-1_distort.glsl',
    preset_anime_hd = '~~/shaders/Ani4k/Ani4Kv2_ArtCNN_C4F32_i2_CMP.glsl',
    preset_anime_hd_light = '~~/shaders/Anime4K/glsl/Restore/Anime4K_Restore_CNN_Soft_M.glsl,' ..
        '~~/shaders/Anime4K/glsl/Restore/Anime4K_Clamp_Highlights.glsl',
    preset_live_sd = '~~/shaders/igv/FSRCNNX_x2_8-0-4-1.glsl',
    preset_live_hd = '~~/shaders/igv/SSimSuperRes.glsl',
}
options.read_options(o, 'content_adaptive')

local MODE_LABEL = {
    off = '关闭', auto = '自动（推荐）',
    performance = '性能优先', quality = '画质优先',
}
local MODE_ORDER = { 'off', 'auto', 'performance', 'quality' }

local state = {
    mode = 'auto',            -- 持久化：off/auto/performance/quality
    smooth = 'off',           -- 持久化：仅记录意图（AI 补帧运行时未安装）
    content = 'live',         -- 本文件判定：anime/live
    res_class = 'hd',         -- sd/hd/uhd
    manual_content = nil,     -- 手动覆盖：anime/live/auto（nil=自动）
    paused = false,           -- 手动着色器接管，本文件内停用
    degrade = 0,              -- 降档级数 0..degrade_max
    last_degrade = 0,
    degrade_count = 0,
    self_write = false,
    gpu = '检测中',
    tier = 'medium',
    detail = '等待视频',
    samples = nil,            -- {t=clock, c=drop-frame-count}
    file_active = false,
}

local state_path = mp.command_native({ 'expand-path', '~~/script-opts/content_adaptive_state.json' })

local function expand(p)
    return mp.command_native({ 'expand-path', p })
end

local function split_csv(s)
    local out = {}
    for raw in (s or ''):gmatch('[^,]+') do
        local token = raw:match('^%s*(.-)%s*$')
        if token ~= '' then out[#out + 1] = token:lower() end
    end
    return out
end

local ANIME_KW = split_csv(o.anime_keywords)
local ANIME_DIR_KW = split_csv(o.anime_dir_keywords)

-- ---------------------------------------------------------------- 持久化

local function load_state()
    local f = io.open(state_path, 'r')
    if not f then return end
    local data = utils.parse_json(f:read('*a'))
    f:close()
    if type(data) ~= 'table' then return end
    if MODE_LABEL[data.mode] then state.mode = data.mode end
    if MODE_LABEL[data.smooth] then state.smooth = data.smooth end
end

local function save_state()
    local json, err = utils.format_json({ mode = state.mode, smooth = state.smooth })
    if not json then
        mp.msg.warn('状态序列化失败: ' .. tostring(err))
        return
    end
    local f = io.open(state_path, 'w')
    if f then
        f:write(json)
        f:close()
    end
end

-- ---------------------------------------------------------------- 发布状态

local function publish()
    mp.set_property_native('user-data/video-enhancement/superres-mode', state.mode)
    mp.set_property_native('user-data/video-enhancement/smooth-mode', state.smooth)
    mp.set_property_native('user-data/video-enhancement/superres-detail', state.detail)
    mp.set_property_native('user-data/video-enhancement/protect-4k', 'yes')
    mp.set_property_native('user-data/video-enhancement/hq-status',
        'AI 补帧运行时未安装（需 vapoursynth-plugin-mlrt），播放保持原生')
    mp.set_property_native('user-data/video-enhancement/ai-backend-restart-required', 'no')
    mp.set_property_native('user-data/video-enhancement/ai-backend-mode', 'auto')
    mp.set_property_native('user-data/video-enhancement/ai-backend-mode-label', '智能自动（推荐）')
    mp.set_property_native('user-data/video-enhancement/hq-processing-mode', 'native')
    mp.set_property_native('user-data/video-enhancement/hq-processing-mode-label', '原生尺寸安全增强')
    mp.set_property_native('user-data/adaptive-quality/gpu', state.gpu)
    mp.set_property_native('user-data/adaptive-quality/tier', state.tier)
    mp.set_property_native('user-data/content-adaptive/content-type', state.content)
    mp.set_property_native('user-data/content-adaptive/res-class', state.res_class)
    mp.set_property_native('user-data/content-adaptive/manual-override', state.manual_content or 'auto')
    mp.set_property_native('user-data/content-adaptive/paused', state.paused and 'yes' or 'no')
    mp.set_property_native('user-data/content-adaptive/degrade-level', state.degrade)
end

-- ---------------------------------------------------------------- 内容判定

local function detect_content()
    if state.manual_content == 'anime' or state.manual_content == 'live' then
        return state.manual_content
    end
    local path = (mp.get_property('stream-open-filename')
        or mp.get_property('path') or ''):lower()
    for _, kw in ipairs(ANIME_DIR_KW) do
        if path:find('/' .. kw .. '/', 1, true) then return 'anime' end
    end
    for _, kw in ipairs(ANIME_KW) do
        if path:find(kw, 1, true) then return 'anime' end
    end
    return 'live'
end

local function detect_res_class()
    local w = mp.get_property_number('video-params/w', 0) or 0
    local h = mp.get_property_number('video-params/h', 0) or 0
    if w <= 0 or h <= 0 then return nil end
    if w >= o.uhd_min_width or h >= 2160 then return 'uhd' end
    if w <= o.sd_max_width and h <= o.sd_max_height then return 'sd' end
    return 'hd'
end

local function source_fps()
    local fps = mp.get_property_number('container-fps', 0)
    if not fps or fps <= 0 then
        fps = mp.get_property_number('estimated-vf-fps', 0) or 0
    end
    return fps
end

local function is_live()
    if not mp.get_property_bool('demuxer-via-network', false) then return false end
    local d = mp.get_property_number('duration', -1)
    return not d or d <= 0
end

local function is_hdr()
    local gamma = (mp.get_property('video-params/gamma') or ''):lower()
    return gamma == 'pq' or gamma == 'hlg'
end

local function split_shaders(csv)
    local out = {}
    for raw in (csv or ''):gmatch('[^,]+') do
        out[#out + 1] = expand(raw:match('^%s*(.-)%s*$'))
    end
    return out
end

local function preset_group(key)
    local map = {
        anime_sd = o.preset_anime_sd,
        anime_hd = o.preset_anime_hd,
        anime_hd_light = o.preset_anime_hd_light,
        live_sd = o.preset_live_sd,
        live_hd = o.preset_live_hd,
    }
    local out = split_shaders(map[key])
    out[#out + 1] = expand(o.krig)
    return out
end

-- ---------------------------------------------------------------- 决策

-- 返回 shaders 列表与说明文字
local function compute()
    local krig = { expand(o.krig) }

    if state.mode == 'off' then
        return {}, '已关闭'
    end
    if state.paused then
        return {}, '手动接管（本文件自动暂停）'
    end
    if is_live() then
        return {}, '直播：性能优先，不挂超分'
    end
    if is_hdr() then
        return {}, 'HDR 源：交给 HDR 处理链'
    end

    local res = state.res_class
    local content = state.content
    local heavy_ok = source_fps() <= 0 or source_fps() <= o.high_fps_threshold
    local degrade = state.mode == 'quality' and 0 or state.degrade

    -- quality：HD 重组适用于一切分辨率；performance：一律轻量
    if state.mode == 'quality' and res == 'sd' then
        res = 'hd'
    end
    if state.mode == 'performance' then
        heavy_ok = false
    end

    local res_label = { sd = 'SD', hd = 'HD', uhd = '4K' }
    local prefix = content == 'anime' and '动画' or '真人'

    if res == 'uhd' then
        return krig, prefix .. ' · 4K · 仅色度增强，不做放大'
    end

    if content == 'anime' then
        if res == 'sd' then
            if heavy_ok then
                return preset_group('anime_sd'), prefix .. ' · SD · FSRCNNX 修复'
            end
            return krig, prefix .. ' · SD · 高帧率源，仅色度增强'
        end
        -- anime hd
        if degrade >= 2 then
            return krig, prefix .. ' · HD · 性能降档，仅色度增强'
        elseif degrade == 1 or not heavy_ok then
            return preset_group('anime_hd_light'), prefix .. ' · HD · Anime4K 轻量修复'
        end
        return preset_group('anime_hd'), prefix .. ' · HD · ArtCNN 超分'
    end

    -- live
    if res == 'sd' then
        if heavy_ok and degrade < 2 then
            return preset_group('live_sd'), prefix .. ' · SD · FSRCNNX 轻超分'
        end
        return krig, prefix .. ' · SD · 高帧率/降档，仅色度增强'
    end
    if degrade == 0 and heavy_ok then
        return preset_group('live_hd'), prefix .. ' · HD · SSimSuperRes 增强'
    end
    return krig, prefix .. ' · HD · 仅色度增强'
end

local function lists_equal(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function apply(why)
    if not o.enabled or not state.file_active then return end
    -- 手动让位期间绝不改写 glsl-shaders（参数变化等事件不得清空用户着色器）
    if state.paused and why ~= 'mode' then return end
    local shaders, detail = compute()
    state.detail = detail
    -- 目标列表与当前一致时不写入：避免 self_write 标志悬空吞掉下一次手动让位判定
    if lists_equal(mp.get_property_native('glsl-shaders'), shaders) then
        publish()
        return
    end
    state.self_write = true
    mp.set_property_native('glsl-shaders', shaders)
    -- 兜底：若属性值未变化导致 observer 未触发，超时后回收标志，防止悬空
    mp.add_timeout(0.5, function() state.self_write = false end)
    publish()
    if why and why ~= '' then
        mp.osd_message('内容自适应：' .. detail .. (why == 'degrade' and '\n（掉帧，已自动降档）' or ''), 2)
    end
end

-- ---------------------------------------------------------------- 手动让位

local glsl_observer = nil
glsl_observer = function(_, value)
    if state.self_write then
        state.self_write = false
        return
    end
    -- 用户手动改动了着色器：本文件内停用自动（off 模式本来就不管）
    if state.file_active and state.mode ~= 'off' and not state.paused then
        state.paused = true
        publish()
        mp.osd_message('检测到手动着色器调整\n自动增强本文件暂停，下个文件恢复', 2.5)
    end
end

-- ---------------------------------------------------------------- 掉帧降档

local function sample_drops()
    if not state.file_active then return end
    local mode_ok = state.mode == 'auto' or state.mode == 'performance'
    if not mode_ok or state.paused or state.degrade >= o.degrade_max then
        state.samples = nil
        return
    end
    if is_live() or is_hdr() then
        state.samples = nil
        return
    end
    local now = mp.get_time()
    local count = mp.get_property_number('drop-frame-count', 0) or 0
    local s = state.samples
    if not s then
        state.samples = { t = now, c = count }
        return
    end
    if now - s.t < o.drop_window_s then return end
    local drops = count - s.c
    state.samples = { t = now, c = count }
    if drops > o.drop_limit and now - state.last_degrade >= o.degrade_cooldown_s then
        state.degrade = state.degrade + 1
        state.degrade_count = state.degrade_count + 1
        state.last_degrade = now
        mp.msg.info(string.format('性能降档 L%d：%ds 内掉帧 %d', state.degrade, o.drop_window_s, drops))
        apply('degrade')
    end
end

-- ---------------------------------------------------------------- GPU 检测

local function detect_gpu()
    local cmd = mp.command_native({
        name = 'subprocess',
        args = { 'nvidia-smi', '--query-gpu=name', '--format=csv,noheader' },
        playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(done)
        if done and done.status == 0 and done.stdout and done.stdout ~= '' then
            state.gpu = (done.stdout:match('^%s*(.-)%s*$') or '')
            if state.gpu ~= '' then state.gpu = 'NVIDIA ' .. state.gpu end
        else
            state.gpu = '核显 / 未知'
        end
        publish()
    end)
    if not cmd then state.gpu = '核显 / 未知' end
end

-- ---------------------------------------------------------------- 消息接口

local function set_mode(mode, silent)
    if not MODE_LABEL[mode] then return end
    state.mode = mode
    -- 菜单/按键显式选档 = 重新接管（清除手动让位与降档状态）
    state.paused = false
    state.degrade = 0
    save_state()
    apply(mode == 'off' and '' or 'mode')
    if not silent then
        mp.osd_message('画面增强：' .. MODE_LABEL[mode], 2)
    end
end

local function set_smooth(mode, silent)
    if not MODE_LABEL[mode] then return end
    state.smooth = mode
    save_state()
    publish()
    if not silent and (mode == 'performance' or mode == 'quality') then
        mp.osd_message('补帧档位已记录\nAI 补帧运行时未安装，播放保持原生（插帧可用 ALT+i）', 3)
    end
end

-- uosc 菜单「档位预设」：balanced/clarity/ai_smooth → auto；off → off
local function set_profile(name)
    name = tostring(name or '')
    if name == 'off' then
        set_mode('off')
        set_smooth('off', true)
        mp.osd_message('视频增强：全部关闭', 2)
    elseif name == 'balanced' or name == 'clarity' or name == 'ai_smooth' then
        set_mode('auto')
        set_smooth('auto', true)
        mp.osd_message('视频增强档位：智能推荐', 2)
    end
end

local function set_content_mode(mode)
    -- 手动覆盖内容类型：anime/live/auto（auto=恢复关键词判定）
    if mode ~= 'anime' and mode ~= 'live' and mode ~= 'auto' then return end
    state.manual_content = mode == 'auto' and nil or mode
    state.content = detect_content()
    state.paused = false
    state.degrade = 0
    apply('mode')
    local label = mode == 'auto' and '自动判定' or (mode == 'anime' and '动画模式' or '真人模式')
    mp.osd_message('内容类型：' .. label, 2)
end

local function cycle_content_mode()
    local cur = state.manual_content or 'auto'
    local next_mode = cur == 'auto' and 'anime' or cur == 'anime' and 'live' or 'auto'
    set_content_mode(next_mode)
end

mp.register_script_message('set-superres', function(value) set_mode(tostring(value or '')) end)
mp.register_script_message('set-smooth', function(value) set_smooth(tostring(value or '')) end)
mp.register_script_message('set-profile', set_profile)
mp.register_script_message('set-protect-4k', function() publish() end)
mp.register_script_message('set-content-mode', function(v) set_content_mode(tostring(v or '')) end)
mp.register_script_message('cycle-content-mode', cycle_content_mode)
mp.register_script_message('refresh', apply)

-- ---------------------------------------------------------------- 生命周期

local function on_file_loaded()
    state.paused = false
    state.degrade = 0
    state.degrade_count = 0
    state.last_degrade = 0
    state.samples = nil
    state.manual_content = nil
    state.file_active = true
    state.res_class = detect_res_class()
    state.content = detect_content()
    apply('')
end

local function on_end_file()
    state.file_active = false
    state.samples = nil
end

if o.enabled then
    load_state()
    detect_gpu()

    mp.register_event('file-loaded', on_file_loaded)
    mp.register_event('end-file', on_end_file)
    mp.observe_property('video-params/w', 'native', function(_, val)
        if not val or not state.file_active then return end
        local res = detect_res_class()
        if res and res ~= state.res_class then
            state.res_class = res
            state.content = detect_content()
        end
        apply('')
    end)
    mp.observe_property('video-params/gamma', 'native', function()
        if state.file_active then apply('') end
    end)
    mp.observe_property('glsl-shaders', 'native', glsl_observer)
    mp.add_periodic_timer(5, sample_drops)
    publish()
end
