-- Private sibling output and atomic commit for subtitle download/export.
local utils = require 'mp.utils'
local M = {}
local temporary_files = {}
local temporary_id = 0

function M.reserve(path, extension, owner)
    local directory = utils.split_path(path)
    repeat
        temporary_id = temporary_id + 1
        -- A valid final basename may already fill the filesystem component limit.
        local temporary = utils.join_path(directory, '.mpv-' .. owner .. '-'
            .. tostring(utils.getpid()) .. '-' .. temporary_id .. extension)
        if not utils.file_info(temporary) then
            local file, err = io.open(temporary, 'wb')
            if not file then return nil, err end
            local closed, close_error = file:close()
            if not closed then os.remove(temporary); return nil, close_error end
            temporary_files[temporary] = true
            return temporary
        end
    until temporary_id > 1000000
    return nil, 'Could not reserve temporary subtitle output'
end

function M.discard(path)
    os.remove(path)
    temporary_files[path] = nil
end

function M.commit(temporary, path)
    local ok, err = os.rename(temporary, path)
    if ok then return true end
    if package.config:sub(1, 1) ~= '\\' then return nil, err end
    local ffi_ok, ffi = pcall(require, 'ffi')
    if not ffi_ok then return nil, err end
    ffi.cdef[[
        int __stdcall MultiByteToWideChar(unsigned int, unsigned long,
            const char *, int, wchar_t *, int);
        int __stdcall MoveFileExW(const wchar_t *, const wchar_t *, unsigned long);
        unsigned long __stdcall GetLastError(void);
    ]]
    local function wide(value)
        local size = ffi.C.MultiByteToWideChar(65001, 0, value, -1, nil, 0)
        if size <= 0 then return nil end
        local buffer = ffi.new('wchar_t[?]', size)
        if ffi.C.MultiByteToWideChar(65001, 0, value, -1, buffer, size) <= 0 then return nil end
        return buffer
    end
    local source, target = wide(temporary), wide(path)
    if source and target and ffi.C.MoveFileExW(source, target, 1) ~= 0 then return true end
    return nil, 'Could not replace subtitle output (Windows error '
        .. tostring(tonumber(ffi.C.GetLastError())) .. ')'
end

mp.register_event('shutdown', function()
    for path in pairs(temporary_files) do os.remove(path) end
end)

return M
