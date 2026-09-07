-- Only normalize local UTF-16 STRM files that native autodetection rejects.
-- UTF-8, remote playlists, HLS and authentication retain the native path.
local mp = require 'mp'
local utils = require 'mp.utils'
local MAX_BYTES = 256 * 1024

local function utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xc0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then return string.char(0xe0 + math.floor(cp / 4096),
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64) end
    return string.char(0xf0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function decode(text, little)
    if #text % 2 ~= 0 then return nil end
    local out, high = {}, nil
    for i = 3, #text, 2 do
        local a, b = text:byte(i, i + 1)
        local cp = little and a + b * 256 or a * 256 + b
        if high then
            if cp < 0xdc00 or cp > 0xdfff then return nil end
            out[#out + 1] = utf8(0x10000 + (high - 0xd800) * 1024 + cp - 0xdc00)
            high = nil
        elseif cp >= 0xd800 and cp <= 0xdbff then
            high = cp
        elseif cp == 0 or (cp >= 0xdc00 and cp <= 0xdfff) then
            return nil
        else
            out[#out + 1] = utf8(cp)
        end
    end
    return not high and table.concat(out) or nil
end

mp.add_hook('on_load', 4, function()
    local path = mp.get_property('stream-open-filename') or ''
    if path == '' then path = mp.get_property('path') or '' end
    if not path:lower():match('%.strm$') or path:match('^%a[%w+.-]*://') then return end
    local parent = mp.get_property('playlist-path', '') or ''
    if parent:match('^%a[%w+.-]*://') then return end
    local file = io.open(path, 'rb')
    if not file then return end
    local bom = file:read(2)
    if bom ~= '\255\254' and bom ~= '\254\255' then file:close(); return end
    local body = file:read(MAX_BYTES + 1) or ''
    file:close()
    local text = #body <= MAX_BYTES and decode(bom .. body, bom == '\255\254')
    if not text then
        mp.msg.error('STRM 的 UTF-16 编码无效或文件超过 256 KiB，未加载')
        return
    end
    local directory = utils.split_path(path)
    local lines = {'#EXTM3U'}
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        line = line:match('^%s*(.-)%s*$')
        if line ~= '' then
            if line:sub(1, 1) ~= '#' and not line:match('^%a[%w+.-]*://')
                and not line:match('^[/\\]') and not line:match('^%a:') then
                line = utils.join_path(directory, line)
            end
            lines[#lines + 1] = line
        end
    end
    mp.set_property('stream-open-filename', 'memory://' .. table.concat(lines, '\n') .. '\n')
end)
