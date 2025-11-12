-- 手动触发manager更新的脚本
local msg = require "mp.msg"

function trigger_manager_update()
    msg.info("手动触发manager更新...")
    -- 尝试调用manager的update_all函数
    local success, result = pcall(function()
        local manager = require "manager"
        if manager and manager.update_all then
            manager.update_all()
            return true
        end
    end)
    
    if not success then
        msg.warn("无法直接调用manager，尝试通过按键绑定...")
        -- 尝试通过按键绑定触发
        mp.command("keypress manager-update-all")
    end
end

-- 添加一个按键绑定来触发更新
mp.add_key_binding("ctrl+alt+u", "manual-manager-update", trigger_manager_update)

msg.info("manager更新触发器已加载，使用 CTRL+ALT+U 来触发更新")
