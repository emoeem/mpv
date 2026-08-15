--- Copy screenshot to clipboard (Wayland/Linux).
--- Needs wl-clipboard (wl-copy) or xclip.

local mp = require("mp")
local utils = require("mp.utils")

local function copy_screenshot()
    local img = os.tmpname() .. ".png"
    mp.commandv("screenshot-to-file", img, "subtitles")
    mp.add_timeout(0.3, function()
        os.execute("wl-copy < " .. img .. " 2>/dev/null || xclip -selection clipboard -t image/png -i " .. img .. " 2>/dev/null")
        os.remove(img)
    end)
end

mp.add_key_binding(nil, "screenshot-to-clipboard", copy_screenshot)
