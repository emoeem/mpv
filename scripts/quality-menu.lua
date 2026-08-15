-- quality-menu: 按 `Ctrl+q` 切换视频质量
-- 完整版请从开源仓库下载

mp.add_key_binding("Ctrl+q", "quality-menu", function()
    local w = mp.get_property("width")
    local h = mp.get_property("height")
    mp.osd_message("当前分辨率: " .. (w or "?") .. "x" .. (h or "?"), 3)
end)
