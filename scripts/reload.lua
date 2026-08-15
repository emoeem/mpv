-- mpv-reload: 按 Ctrl+r 重新加载当前文件
local key = "Ctrl+r"

mp.add_key_binding(key, "reload", function()
    local path = mp.get_property("path")
    if path and path ~= "" then
        mp.commandv("loadfile", path, "replace")
    end
end)
