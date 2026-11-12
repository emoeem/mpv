-- Complete public source responses, reusable for 24 hours. Never stores request cookies.
local utils = require 'mp.utils'
local M = {}
local cache_ttl = 24 * 3600
function M.path(site, id)
    if options.cookie_file and options.cookie_file ~= '' then return nil end
    if not id or #id > 128 or not id:match('^[%w_=%-]+$') then return nil end
    local dir = mp.command_native({'expand-path', '~~/cache'})
    local info = dir and utils.file_info(dir)
    if not info or not info.is_dir then return nil end
    return utils.join_path(dir, 'danmaku-' .. site .. '-' .. id .. '.json')
end
function M.read(path, id)
    local info = path and utils.file_info(path)
    if not info or not info.size or info.size > 16 * 1024 * 1024 then return nil end
    local f = io.open(path, 'rb')
    if not f then return nil end
    local raw = f:read('*a'); f:close()
    local data = raw and utils.parse_json(raw)
    local now = os.time()
    if type(data) ~= 'table' or data.version ~= 1 or data.vid ~= id
        or type(data.saved) ~= 'number' or data.saved ~= data.saved or now < data.saved
        or now - data.saved > cache_ttl or type(data.comments) ~= 'table'
        or #data.comments == 0 or #data.comments > 100000 then return nil end
    for _, d in ipairs(data.comments) do
        if type(d) ~= 'table' or type(d.time) ~= 'number' or d.time < 0
            or d.time ~= d.time or d.time == math.huge or type(d.text) ~= 'string'
            or (d.type ~= 1 and d.type ~= 4 and d.type ~= 5) or d.size ~= 25 then return nil end
    end
    return data.comments
end
function M.save_later(path, id, comments)
    if not path or #comments == 0 or #comments > 100000 then return end
    add_danmaku_timeout(0.5, function()
        local raw = utils.format_json({version = 1, vid = id,
            saved = os.time(), comments = comments})
        if not raw or #raw > 16 * 1024 * 1024 then return end
        local f = io.open(path, 'wb')
        if f then f:write(raw); f:close() end
    end)
end
return M
