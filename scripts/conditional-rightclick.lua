-- 鼠标位于当前可见的 uosc 控件带时，把右键留给按钮 secondary_command。
-- 控件带隐藏或鼠标位于其他区域时，右键打开 uosc 主菜单。
local mp = require('mp')

local function is_over_visible_controls(mouse)
    if not mouse or type(mouse.y) ~= 'number' then return false end
    local margins = mp.get_property_native('user-data/osc/margins')
    local bottom = type(margins) == 'table' and tonumber(margins.b) or nil
    if not bottom or bottom <= 0 then return false end

    local osd_h = mp.get_property_number('osd-height', 1080) or 1080
    bottom = math.max(0, math.min(1, bottom))
    local controls_top = osd_h * (1 - bottom)
    return mouse.y >= controls_top and mouse.y <= osd_h
end

local function on_right_click(info)
    if info and info.event == 'up' then return end
    local mouse = mp.get_property_native('mouse-pos')
    if is_over_visible_controls(mouse) then return end
    mp.commandv('script-message-to', 'uosc', 'menu-blurred')
end

mp.add_forced_key_binding('MBTN_Right', 'conditional-rightclick', on_right_click, {complex = true})
