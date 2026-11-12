-- Small synchronous transactions for player-owned settings and history.
-- LockFileEx is non-blocking and the OS releases the lock on process exit.
-- Never remove the destination before replacement; failed writes keep it intact.
-- Several UI modules can load this file in one script's Lua state.
if package.loaded['yaozhi.persistence.v1'] then return package.loaded['yaozhi.persistence.v1'] end
local M = {}
local ffi_ok, ffi = pcall(require, 'ffi')
local available, unavailable
local serial = 0
local MAX_BYTES = 128 * 1024 * 1024
if ffi_ok and ffi.os == 'Windows' then
    available, unavailable = pcall(ffi.cdef, [[
        typedef struct {
            uintptr_t Internal;
            uintptr_t InternalHigh;
            unsigned long Offset;
            unsigned long OffsetHigh;
            void *hEvent;
        } YaozhiPersistenceOverlapped;
        int __stdcall YaozhiPersist_MultiByteToWideChar(unsigned int, unsigned long,
            const char *, int, wchar_t *, int) __asm__("MultiByteToWideChar");
        void *__stdcall YaozhiPersist_CreateFileW(const wchar_t *, unsigned long, unsigned long,
            void *, unsigned long, unsigned long, void *) __asm__("CreateFileW");
        int __stdcall YaozhiPersist_ReadFile(void *, void *, unsigned long, unsigned long *, void *) __asm__("ReadFile");
        int __stdcall YaozhiPersist_WriteFile(void *, const void *, unsigned long, unsigned long *, void *) __asm__("WriteFile");
        int __stdcall YaozhiPersist_FlushFileBuffers(void *) __asm__("FlushFileBuffers");
        int __stdcall YaozhiPersist_CloseHandle(void *) __asm__("CloseHandle");
        int __stdcall YaozhiPersist_LockFileEx(void *, unsigned long, unsigned long,
            unsigned long, unsigned long, YaozhiPersistenceOverlapped *) __asm__("LockFileEx");
        int __stdcall YaozhiPersist_UnlockFileEx(void *, unsigned long, unsigned long,
            unsigned long, YaozhiPersistenceOverlapped *) __asm__("UnlockFileEx");
        int __stdcall YaozhiPersist_MoveFileExW(const wchar_t *, const wchar_t *, unsigned long) __asm__("MoveFileExW");
        int __stdcall YaozhiPersist_DeleteFileW(const wchar_t *) __asm__("DeleteFileW");
        unsigned long __stdcall YaozhiPersist_GetLastError(void) __asm__("GetLastError");
        unsigned long __stdcall YaozhiPersist_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
    ]])
end

local function error_text(operation, code)
    return operation .. ' failed (Windows error ' .. tostring(code) .. ')'
end

local function wide(path)
    if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then
        return nil, 'Invalid persistence path'
    end
    local length = ffi.C.YaozhiPersist_MultiByteToWideChar(65001, 8, path, -1, nil, 0)
    if length == 0 then return nil, 'Persistence path is not valid UTF-8' end
    local value = ffi.new('wchar_t[?]', length)
    if ffi.C.YaozhiPersist_MultiByteToWideChar(65001, 8, path, -1, value, length) == 0 then
        return nil, 'Could not convert persistence path'
    end
    return value
end

local function ready()
    if available then return true end
    return nil, 'Reliable persistence is unavailable: ' .. tostring(unavailable or 'Windows LuaJIT FFI required'), 'unsupported'
end

local function valid_handle(handle)
    return handle ~= nil and handle ~= ffi.cast('void *', -1)
end

function M.read(path, limit)
    if limit ~= nil and (type(limit) ~= 'number' or limit ~= limit or limit < 1 or limit > MAX_BYTES) then
        return nil, 'Invalid persistence read limit', 'limit'
    end
    local supported, err, code = ready()
    if not supported then return nil, err, code end
    local target, conversion_error = wide(path)
    if not target then return nil, conversion_error, 'path' end
    local handle = ffi.C.YaozhiPersist_CreateFileW(target, 0x80000000, 7, nil, 3, 0x80, nil)
    if not valid_handle(handle) then
        local failure = tonumber(ffi.C.YaozhiPersist_GetLastError())
        return nil, error_text('Read open', failure), failure == 2 and 'missing' or 'read'
    end
    local buffer, received = ffi.new('uint8_t[65536]'), ffi.new('unsigned long[1]')
    local chunks, size = {}, 0
    local failure
    while true do
        if ffi.C.YaozhiPersist_ReadFile(handle, buffer, 65536, received, nil) == 0 then
            failure = error_text('Read', tonumber(ffi.C.YaozhiPersist_GetLastError()))
            break
        end
        local count = tonumber(received[0])
        if count == 0 then break end
        size = size + count
        if size > (limit or MAX_BYTES) then failure = limit and 'Persistence file exceeds the requested read limit' or 'Persistence file exceeds the 128 MiB safety limit'; break end
        chunks[#chunks + 1] = ffi.string(buffer, count)
    end
    local closed = ffi.C.YaozhiPersist_CloseHandle(handle)
    if failure then return nil, failure, 'read' end
    if closed == 0 then return nil, error_text('Read close', tonumber(ffi.C.YaozhiPersist_GetLastError())), 'close' end
    return table.concat(chunks)
end

local function reserve(path)
    local directory = path:match('^(.*[/\\])') or ''
    for _ = 1, 32 do
        serial = serial + 1
        local temporary = directory .. '.mpv-persist-' .. tostring(tonumber(ffi.C.YaozhiPersist_GetCurrentProcessId()))
            .. '-' .. tostring(serial) .. '.tmp'
        local target = wide(temporary)
        if not target then return nil, nil, nil, 'Invalid temporary persistence path' end
        local handle = ffi.C.YaozhiPersist_CreateFileW(target, 0x40000000, 0, nil, 1, 0x80, nil)
        if valid_handle(handle) then return handle, target, temporary end
        local failure = tonumber(ffi.C.YaozhiPersist_GetLastError())
        if failure ~= 80 and failure ~= 183 then return nil, nil, nil, error_text('Temporary open', failure) end
    end
    return nil, nil, nil, 'Could not reserve persistence output'
end

local function replace(path, bytes, expected, missing)
    if type(bytes) ~= 'string' then return nil, 'Persistence update must return bytes', 'transform' end
    if #bytes > MAX_BYTES then return nil, 'Persistence output exceeds the 128 MiB safety limit', 'write' end
    if bytes == expected and not missing then return true end
    local target, conversion_error = wide(path)
    if not target then return nil, conversion_error, 'path' end
    local handle, temporary, _, open_error = reserve(path)
    if not handle then return nil, open_error, 'write' end
    local failure, failure_code
    local offset, written = 0, ffi.new('unsigned long[1]')
    while offset < #bytes do
        local count = math.min(65536, #bytes - offset)
        if ffi.C.YaozhiPersist_WriteFile(handle, bytes:sub(offset + 1, offset + count), count, written, nil) == 0 then
            failure = error_text('Write', tonumber(ffi.C.YaozhiPersist_GetLastError())); break
        end
        local completed = tonumber(written[0])
        if completed <= 0 or completed > count then failure = 'Persistence write made no valid progress'; break end
        offset = offset + completed
    end
    if not failure and ffi.C.YaozhiPersist_FlushFileBuffers(handle) == 0 then
        failure = error_text('Flush', tonumber(ffi.C.YaozhiPersist_GetLastError()))
    end
    if ffi.C.YaozhiPersist_CloseHandle(handle) == 0 and not failure then
        failure = error_text('Write close', tonumber(ffi.C.YaozhiPersist_GetLastError()))
    end
    -- Check for a non-cooperating writer as well as cooperating locked writers.
    if not failure then
        local current, read_error, read_code = M.read(path)
        if current ~= expected or (current == nil and not (missing and read_code == 'missing')) then
            failure = read_error or 'Persistence file changed during the transaction'
            failure_code = 'conflict'
        end
    end
    if not failure and ffi.C.YaozhiPersist_MoveFileExW(temporary, target, 9) == 0 then
        failure = error_text('Atomic replace', tonumber(ffi.C.YaozhiPersist_GetLastError()))
        failure_code = 'replace'
    end
    if failure then ffi.C.YaozhiPersist_DeleteFileW(temporary); return nil, failure, failure_code or 'write' end
    return true
end

function M.update(path, transform)
    local supported, err, code = ready()
    if not supported then return nil, err, code end
    if type(transform) ~= 'function' then return nil, 'Persistence update requires a callback', 'transform' end
    local lock_path, conversion_error = wide(type(path) == 'string' and (path .. '.yaozhi.lock') or nil)
    if not lock_path then return nil, conversion_error, 'path' end
    local lock = ffi.C.YaozhiPersist_CreateFileW(lock_path, 0xC0000000, 3, nil, 4, 0x80, nil)
    if not valid_handle(lock) then return nil, error_text('Lock open', tonumber(ffi.C.YaozhiPersist_GetLastError())), 'lock' end
    local overlapped = ffi.new('YaozhiPersistenceOverlapped[1]')
    if ffi.C.YaozhiPersist_LockFileEx(lock, 3, 0, 1, 0, overlapped) == 0 then
        local failure = tonumber(ffi.C.YaozhiPersist_GetLastError())
        ffi.C.YaozhiPersist_CloseHandle(lock)
        return nil, error_text('Persistence lock', failure), failure == 33 and 'busy' or 'lock'
    end
    local ok, result, result_error, result_code = pcall(function()
        local previous, read_error, read_code = M.read(path)
        if previous == nil and read_code ~= 'missing' then return nil, read_error, read_code end
        local bytes, transform_error = transform(previous, read_code == 'missing')
        if type(bytes) ~= 'string' then return nil, transform_error or 'Persistence update was cancelled', 'transform' end
        return replace(path, bytes, previous, read_code == 'missing')
    end)
    local unlocked = ffi.C.YaozhiPersist_UnlockFileEx(lock, 0, 1, 0, overlapped)
    local unlock_error = unlocked == 0 and tonumber(ffi.C.YaozhiPersist_GetLastError()) or nil
    local closed = ffi.C.YaozhiPersist_CloseHandle(lock)
    if not ok then return nil, tostring(result), 'transform' end
    if not result then return nil, result_error, result_code end
    -- Replacement is already committed. Cleanup errors must not make callers
    -- report a failed save or leave their in-memory settings at the old value.
    if unlocked == 0 then return true, error_text('Unlock after commit', unlock_error), 'committed-cleanup' end
    if closed == 0 then return true, error_text('Lock close after commit', tonumber(ffi.C.YaozhiPersist_GetLastError())), 'committed-cleanup' end
    return true
end

function M.atomic_write(path, bytes)
    return M.update(path, function() return bytes end)
end

-- Merge only this user action's keys against the latest file, preserving other
-- instances' changes, comments, unknown keys, and every existing line ending.
function M.update_options(path, changes)
    if type(changes) ~= 'table' then return nil, 'Options update requires a table', 'transform' end
    for name, value in pairs(changes) do
        if type(name) ~= 'string' or not name:match('^[%w_.-]+$')
            or type(value) ~= 'string' or value:find('[%z\r\n]') then
            return nil, 'Invalid option update', 'transform'
        end
    end
    return M.update(path, function(previous, missing)
        if missing then return nil, 'The settings file is missing' end
        if previous:find('%z') then return nil, 'The settings file contains NUL bytes' end
        local found, output, position = {}, {}, 1
        while position <= #previous do
            local start, finish = previous:find('[\r\n]', position)
            local line, ending
            if start then
                line, ending = previous:sub(position, start - 1), previous:sub(start, finish)
                if ending == '\r' and previous:sub(finish + 1, finish + 1) == '\n' then
                    finish, ending = finish + 1, '\r\n'
                end
                position = finish + 1
            else line, ending, position = previous:sub(position), '', #previous + 1 end
            local prefix, key, spacing = line:match('^([ \t]*)([%w_.-]+)([ \t]*)=')
            if key and changes[key] ~= nil then
                line = prefix .. key .. spacing .. '=' .. changes[key]
                found[key] = true
            end
            output[#output + 1] = line .. ending
        end
        local newline = previous:find('\r\n', 1, true) and '\r\n' or '\n'
        local result, keys = table.concat(output), {}
        for key in pairs(changes) do if not found[key] then keys[#keys + 1] = key end end
        table.sort(keys)
        for _, key in ipairs(keys) do
            if result ~= '' and not result:match('[\r\n]$') then result = result .. newline end
            result = result .. key .. '=' .. changes[key] .. newline
        end
        return result
    end)
end

-- POSIX fallback (EmoPlay local adaptation): Linux has no LockFileEx in this
-- module, so instead of reporting 'unsupported' (which would make callers
-- silently lose persistence), transactions run on plain IO: same-directory
-- temporary file + os.rename for atomicity, plus the Windows path's re-read
-- conflict check before commit. There is no advisory lock, so cooperating
-- writers can still interleave; this is the documented single-instance path.
if not (ffi_ok and ffi.os == 'Windows') then
    local function posix_read(path, limit)
        if limit ~= nil and (type(limit) ~= 'number' or limit ~= limit or limit < 1 or limit > MAX_BYTES) then
            return nil, 'Invalid persistence read limit', 'limit'
        end
        local file = io.open(path, 'rb')
        if not file then return nil, 'Persistence file is missing', 'missing' end
        local chunks, size = {}, 0
        while true do
            local chunk = file:read(65536)
            if not chunk then break end
            size = size + #chunk
            if size > (limit or MAX_BYTES) then
                file:close()
                return nil, limit and 'Persistence file exceeds the requested read limit' or 'Persistence file exceeds the 128 MiB safety limit', 'read'
            end
            chunks[#chunks + 1] = chunk
        end
        file:close()
        return table.concat(chunks)
    end

    local function posix_replace(path, bytes, expected, missing)
        if type(bytes) ~= 'string' then return nil, 'Persistence update must return bytes', 'transform' end
        if #bytes > MAX_BYTES then return nil, 'Persistence output exceeds the 128 MiB safety limit', 'write' end
        if bytes == expected and not missing then return true end
        local directory = path:match('^(.*[/\\])') or ''
        local temporary, handle
        for _ = 1, 32 do
            serial = serial + 1
            temporary = directory .. '.mpv-persist-' .. tostring(serial) .. '.tmp'
            handle = io.open(temporary, 'wb')
            if handle then break end
            temporary = nil
        end
        if not handle then return nil, 'Could not reserve persistence output', 'write' end
        local written, write_error = pcall(function()
            handle:write(bytes)
            handle:close()
        end)
        if not written then
            os.remove(temporary)
            return nil, 'Write failed: ' .. tostring(write_error), 'write'
        end
        -- Check for a non-cooperating writer before the rename commits.
        local current, read_error, read_code = posix_read(path)
        if current ~= expected or (current == nil and not (missing and read_code == 'missing')) then
            os.remove(temporary)
            return nil, read_error or 'Persistence file changed during the transaction', 'conflict'
        end
        if not os.rename(temporary, path) then
            os.remove(temporary)
            return nil, 'Atomic replace failed', 'replace'
        end
        return true
    end

    function M.read(path, limit)
        local value, error_text, code = posix_read(path, limit)
        if value ~= nil then return value end
        return nil, error_text, code or 'read'
    end

    function M.update(path, transform)
        if type(transform) ~= 'function' then return nil, 'Persistence update requires a callback', 'transform' end
        local previous, read_error, read_code = posix_read(path)
        if previous == nil and read_code ~= 'missing' then return nil, read_error, read_code end
        local ok, result, transform_error = pcall(transform, previous, read_code == 'missing')
        if not ok then return nil, tostring(result), 'transform' end
        if type(result) ~= 'string' then return nil, transform_error or 'Persistence update was cancelled', 'transform' end
        return posix_replace(path, result, previous, read_code == 'missing')
    end
end

package.loaded['yaozhi.persistence.v1'] = M
return M
