-- screenshot-directory.lua
-- Screenshot directory setting script

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- Screenshot directory setting
local screenshot_dir = "~/Pictures/mpv-screenshots"

-- Ensure directory exists
local function ensure_directory_exists(dir)
    -- Use os.getenv to get HOME directory and manually expand path
    local home_dir = os.getenv("HOME") or ""
    local expanded_dir = dir:gsub("~", home_dir)
    
    -- First check if directory already exists
    local check_result = utils.subprocess({
        args = {"test", "-d", expanded_dir}
    })
    
    if check_result.status == 0 then
        msg.info("Screenshot directory exists: " .. expanded_dir)
        return true
    end
    
    -- If not exists, try to create
    local result = utils.subprocess({
        args = {"mkdir", "-p", expanded_dir}
    })
    if result.status ~= 0 then
        msg.warn("Cannot create screenshot directory: " .. expanded_dir)
        return false
    else
        msg.info("Screenshot directory created: " .. expanded_dir)
        return true
    end
end

-- Set screenshot directory
mp.set_property("screenshot-directory", screenshot_dir)

-- Create directory
ensure_directory_exists(screenshot_dir)

-- Add shortcut hint
mp.add_key_binding("Ctrl+s", "screenshot", function()
    mp.command("screenshot")
    mp.osd_message("Screenshot saved to: " .. screenshot_dir)
end)

-- Show loading information
mp.osd_message("Screenshot directory set to: " .. screenshot_dir)
msg.info("Screenshot directory script loaded, screenshots will be saved to: " .. screenshot_dir)
