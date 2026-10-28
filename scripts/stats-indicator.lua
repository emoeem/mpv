--[[
    stats-indicator.lua

    让底栏「统计信息」按钮反映 mpv 内置 stats.lua 的真实显示状态：
      · 面板开着 → 按钮高亮（uosc 的 active 态：紫底 + 深色图标），tooltip 变「关闭统计信息」
      · 面板关着 → 按钮恢复常态，tooltip 变「统计信息」
      · 左键单击 = 开关（toggle），不再是一次性闪现

    设计约束：
      1. 不改 uosc 上游代码。uosc 官方提供了 `set-button` script-message 扩展点
         （lib/buttons.lua），sleep-timer / skip-segments 都是这么用的，这里沿用同一模式。
      2. 状态来源只有 stats.lua 写的一个属性 `user-data/mpv-emo/stats-visible`。
         因为写在 stats.lua 的 clear_screen() 与显示分支里，所以键盘（Shift+I）、
         右键菜单、其他脚本调用都能同步，不会出现「按钮亮着但面板已经关了」。
      3. uosc 尚未加载时发消息会丢。这里用 uosc 加载后必定发布的
         `user-data/uosc/dock-animation-mode` 作为就绪信号，另加两档超时兜底，
         保证冷启动时按钮不会停在「未初始化」占位图标。
]]

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local BUTTON_NAME = 'stats_toggle'
local VISIBLE_PROP = 'user-data/mpv-emo/stats-visible'
local UOSC_READY_PROP = 'user-data/uosc/dock-animation-mode'

local visible = false
local last_payload = nil
local uosc_ready = false

local function build_button_data(is_visible)
    return {
        icon = 'analytics',
        active = is_visible,
        -- 左键：开 / 关面板。stats.lua 的 display-stats-toggle 语义是
        -- 「显示中 → 关闭，未显示 → 常驻显示」，正好对应这里的需求。
        command = 'script-binding stats/display-stats-toggle',
        -- 右键：一次性闪现（保留原来的 display-stats 行为，长按预览不打断常驻态）。
        secondary_command = 'script-binding stats/display-stats',
        tooltip = is_visible and '关闭统计信息（Shift+I）' or '统计信息（Shift+I）',
    }
end

---@param force boolean|nil 忽略去重，强制重发（用于 uosc 就绪后的补发）
local function update_button(force)
    local payload = utils.format_json(build_button_data(visible))
    if not force and payload == last_payload then return end
    last_payload = payload
    mp.commandv('script-message-to', 'uosc', 'set-button', BUTTON_NAME, payload)
end

mp.observe_property(VISIBLE_PROP, 'bool', function(_, value)
    visible = (value == true)
    update_button()
end)

-- uosc 就绪信号：main.lua 顶层就会 publish 这个属性。
mp.observe_property(UOSC_READY_PROP, 'native', function(_, value)
    if value == nil or uosc_ready then return end
    uosc_ready = true
    update_button(true)
end)

-- 冷启动兜底：万一 uosc 版本更旧、没有那个属性，也不能让按钮停在占位图标。
mp.add_timeout(1.0, function() update_button(true) end)
mp.add_timeout(3.0, function() update_button(true) end)

-- 换片后按钮状态不随文件重置（stats 面板本身也跨文件保留），但重新确认一次，
-- 防止 stats 在切文件时被外部清屏而 uosc 侧仍是旧值。
mp.register_event('file-loaded', function() update_button(true) end)

update_button()
msg.verbose('stats-indicator: 已接管底栏按钮 ' .. BUTTON_NAME)
