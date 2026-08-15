local M = {}

local ROOT_KEY = "_resolver_affinity"

local function source_key(query)
    local host = tostring(query or ""):match("^https?://([^/%?#]+)")
    if not host then return nil end

    host = host:lower():gsub("^.-@", ""):gsub(":%d+$", ""):gsub("^www%.", "")
    if host == "" then return nil end
    return host
end

function M.source_key(query)
    return source_key(query)
end

function M.get(history, directory, query)
    if type(history) ~= "table" or not directory then return nil end
    local key = source_key(query)
    if not key then return nil end

    local root = history[ROOT_KEY]
    local by_directory = type(root) == "table" and root[directory] or nil
    local record = type(by_directory) == "table" and by_directory[key] or nil
    if type(record) ~= "table" or type(record.server) ~= "string" or record.server == "" then
        return nil
    end
    return record
end

function M.set(history, directory, query, server, mode, updated_at)
    if type(history) ~= "table" or not directory or type(server) ~= "string" or server == "" then
        return false
    end
    if mode ~= "api" and mode ~= "fallback" then return false end

    local key = source_key(query)
    if not key then return false end

    history[ROOT_KEY] = type(history[ROOT_KEY]) == "table" and history[ROOT_KEY] or {}
    local root = history[ROOT_KEY]
    root[directory] = type(root[directory]) == "table" and root[directory] or {}
    root[directory][key] = {
        server = server:gsub("/+$", ""),
        mode = mode,
        updated_at = tonumber(updated_at) or os.time(),
    }
    return true
end

function M.clear(history, directory, query, expected_server)
    if type(history) ~= "table" or not directory then return false end
    local key = source_key(query)
    if not key then return false end

    local root = history[ROOT_KEY]
    local by_directory = type(root) == "table" and root[directory] or nil
    local record = type(by_directory) == "table" and by_directory[key] or nil
    if type(record) ~= "table" then return false end

    if expected_server and tostring(record.server):gsub("/+$", "") ~= tostring(expected_server):gsub("/+$", "") then
        return false
    end

    by_directory[key] = nil
    if next(by_directory) == nil then root[directory] = nil end
    if next(root) == nil then history[ROOT_KEY] = nil end
    return true
end

return M
