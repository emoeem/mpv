-- Keep slow Ainan/CatPaw proxy startup sequential. Never open another reader.
local mp = require 'mp'
local options = { fast_start = true }
require('mp.options').read_options(options, 'external-player')

local function loopback_http(path)
    local authority = tostring(path or ''):lower():match('^https?://([^/]+)')
    if not authority then return false end
    authority = authority:match('([^@]+)$') or authority
    local host = authority:match('^%[([^%]]+)%]') or authority:match('^([^:?#]+)')
    return host == 'localhost' or host == 'localhost.' or host == '::1'
        or (host and host:match('^127%.%d+%.%d+%.%d+$') ~= nil)
end

mp.add_hook('on_load', 40, function()
    if not options.fast_start then return end
    local ipc = mp.get_property('input-ipc-server', ''):lower()
    if not ipc:find('catpaw_mpv_ext_', 1, true) then return end
    local path = mp.get_property('stream-open-filename', '')
    if path == '' then path = mp.get_property('path', '') end
    if not loopback_http(path) then return end

    -- Older cores silently retain their normal path. Explicit command-line
    -- and per-file choices win, and mpv restores the option at end-file.
    local name = 'demuxer-mkv-read-tail-tags'
    local info = mp.get_property_native('option-info/' .. name)
    if not info or info['set-from-commandline'] or info['set-locally'] then return end
    if mp.set_property_native('file-local-options/' .. name, false) then
        mp.msg.verbose('Ainan proxy: optional MKV tail tags disabled; seek index retained')
    end
end)
