-- file-browser ISO 加载插件
-- 负责让 file-browser 识别 .iso 文件；实际播放改写统一交给 auto_iso_loader.lua。
--
-- 与 scripts/auto_iso_loader.lua 的协作：
--   - 本插件只把 .iso 纳入 file-browser 可播放扩展
--   - auto_iso_loader.lua 通过 on_load 钩子统一处理 file-browser、拖拽、命令行、最近播放等入口
--   - 保留真实 ISO 路径可避免正在播放 bd:// 时再次 loadfile bd:// 导致首次切换落到空闲

local mp = require 'mp'
local msg = require 'mp.msg'
local fb = require 'file-browser'

local isos = {
    name = 'iso-loader',
    priority = 20,
    api_version = '1.5'
}

function isos:setup()
    fb.add_default_extension('iso')
end

function isos:can_parse()
    return true
end

function isos:parse(directory, parse_state)
    return self:defer(directory, parse_state)
end

mp.add_hook('on_load_fail', 50, function()
    if mp.get_property('stream-open-filename') == 'bd://' then
        msg.info('failed to load bluray-device, attempting dvd-device')
        mp.set_property('stream-open-filename', 'dvd://')
    end
end)

return isos
