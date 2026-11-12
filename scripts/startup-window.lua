-- Delay the no-file startup window until GPU selection and idle UI scripts
-- are ready. This prevents force-window=immediate from creating a window on
-- the system-default adapter before adaptive-quality switches to the selected
-- adapter and rebuilds the video output.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- Window preferences are separate from playback/watch-later state. Only the
-- normal client size and maximized state are remembered, never fullscreen,
-- minimized/PiP geometry or a monitor-dependent absolute position.
local window_memory
pcall(function()
    local ffi = require 'ffi'
    ffi.cdef[[
        typedef struct { long left, top, right, bottom; } YaoMemoryRect;
        typedef struct { unsigned long size; YaoMemoryRect monitor, work; unsigned long flags; } YaoMemoryMonitor;
        typedef int (__stdcall *YaoMemoryEnumWindow)(void *, intptr_t);
        unsigned long GetWindowThreadProcessId(void *, unsigned long *);
        int IsWindow(void *); int IsWindowVisible(void *); int IsIconic(void *); int IsZoomed(void *);
        void *GetParent(void *); int GetClassNameA(void *, char *, int);
        int EnumWindows(YaoMemoryEnumWindow, intptr_t);
        int GetWindowRect(void *, YaoMemoryRect *); int GetClientRect(void *, YaoMemoryRect *);
        void *MonitorFromWindow(void *, unsigned long); int GetMonitorInfoA(void *, YaoMemoryMonitor *);
        int SetWindowPos(void *, void *, int, int, int, int, unsigned int);
        int MultiByteToWideChar(unsigned int, unsigned long, const char *, int, wchar_t *, int);
        int CreateDirectoryW(const wchar_t *, void *);
        unsigned long GetFileAttributesW(const wchar_t *);
        int MoveFileExW(const wchar_t *, const wchar_t *, unsigned long);
    ]]
    local user, kernel = ffi.load('user32'), ffi.load('kernel32')
    local owner = mp.get_property_number('pid', 0)
    if owner <= 0 then return end
    -- Query before changing options: runtime writes may alter this metadata.
    for _, name in ipairs({'geometry','autofit','autofit-larger','autofit-smaller',
        'window-scale','hidpi-window-scale','screen','fullscreen','window-maximized',
        'window-minimized','auto-window-resize','wid'}) do
        if mp.get_property_native('option-info/' .. name .. '/set-from-commandline') == true then return end
    end
    if mp.get_property_number('wid', -1) ~= -1 then return end
    local directory = utils.join_path(mp.command_native({'expand-path','~~/'}), 'state')
    local path = utils.join_path(directory, 'window-player-v1.json')
    local function wide(value)
        local count = kernel.MultiByteToWideChar(65001, 8, value, #value, nil, 0)
        if count <= 0 then error('invalid window preference path') end
        local result = ffi.new('wchar_t[?]', count + 1)
        kernel.MultiByteToWideChar(65001, 8, value, #value, result, count)
        return result
    end
    local function ordinary(value)
        local attributes = tonumber(kernel.GetFileAttributesW(wide(value)))
        return attributes == 4294967295 or math.floor(attributes / 1024) % 2 == 0
    end
    local function number(value, low, high)
        return type(value) == 'number' and value == value and value >= low and value <= high
    end
    local remembered
    if ordinary(directory) and ordinary(path) then
        local file = io.open(path, 'rb')
        if file then
            local data = file:read(4097); file:close()
            local value = data and #data <= 4096 and utils.parse_json(data) or nil
            if type(value) == 'table' and value.version == 1 and number(value.width,160,16384)
                and number(value.height,90,16384) and number(value.scale,0.5,8)
                and type(value.maximized) == 'boolean' then remembered = value end
        end
    end
    if remembered then
        -- Size is ready before the delayed force-window request; keep the
        -- configured initial position. Native work-area clamping follows once
        -- the real VO handle and its DPI are available.
        local position = mp.get_property('geometry',''):match('([+-].*)$') or ''
        mp.set_property('geometry', ('%dx%d%s'):format(remembered.width, remembered.height, position))
        mp.set_property_bool('auto-window-resize', false)
    end
    local function owns(window)
        if window == nil or window == ffi.NULL or user.IsWindow(window) == 0
            or user.GetParent(window) ~= nil then return false end
        local pid = ffi.new('unsigned long[1]')
        user.GetWindowThreadProcessId(window, pid)
        if tonumber(pid[0]) ~= owner then return false end
        local name = ffi.new('char[128]')
        return user.GetClassNameA(window,name,128) > 0 and ffi.string(name):lower() == 'mpv'
    end
    local handle, initialized, last, stable, last_written = nil, false, remembered, nil, nil
    local blocked_until = 0
    local function find_window()
        if owns(handle) then return handle end
        local id = mp.get_property_number('window-id', 0)
        if id > 0 and owns(ffi.cast('void *',id)) then handle = ffi.cast('void *',id); return handle end
        local callback = ffi.cast('YaoMemoryEnumWindow',function(window)
            if owns(window) then handle=window; return 0 end
            return 1
        end)
        user.EnumWindows(callback,0); callback:free()
        return owns(handle) and handle or nil
    end
    local function scale()
        local value = mp.get_property_number('display-hidpi-scale',1)
        return number(value,0.5,8) and value or 1
    end
    local function temporary()
        return mp.get_property_bool('fullscreen',false) or mp.get_property_bool('window-minimized',false)
            or mp.get_property_bool('user-data/pip/active',false)
    end
    local function write()
        if not last or not ordinary(directory) or not ordinary(path) then return end
        local data = utils.format_json(last)
        if data == last_written then return end
        kernel.CreateDirectoryW(wide(directory),nil)
        local temporary_path = path .. '.' .. owner .. '.tmp'
        if not ordinary(temporary_path) then return end
        local file = io.open(temporary_path,'wb')
        if not file then return end
        local written = file:write(data); local closed = file:close()
        if written and closed and kernel.MoveFileExW(wide(temporary_path),wide(path),9) ~= 0 then
            last_written = data
        else os.remove(temporary_path) end
    end
    local function tick()
        local window = find_window()
        if not window or user.IsWindowVisible(window) == 0 then return end
        if temporary() or user.IsIconic(window) ~= 0 then stable=nil; return end
        local now = mp.get_time()
        if now < blocked_until then return end
        local outer, client = ffi.new('YaoMemoryRect'), ffi.new('YaoMemoryRect')
        if user.GetWindowRect(window,outer) == 0 or user.GetClientRect(window,client) == 0 then return end
        if not initialized then
            initialized = true
            if remembered then
                local monitor = ffi.new('YaoMemoryMonitor'); monitor.size=ffi.sizeof(monitor)
                if user.GetMonitorInfoA(user.MonitorFromWindow(window,2),monitor) ~= 0 then
                    local work = monitor.work
                    local ratio = scale() / remembered.scale
                    local frame_w, frame_h = outer.right-outer.left-client.right, outer.bottom-outer.top-client.bottom
                    local width = math.min(work.right-work.left, math.floor(remembered.width*ratio+0.5)+frame_w)
                    local height = math.min(work.bottom-work.top, math.floor(remembered.height*ratio+0.5)+frame_h)
                    local x = math.max(work.left,math.min(outer.left,work.right-width))
                    local y = math.max(work.top,math.min(outer.top,work.bottom-height))
                    user.SetWindowPos(window,nil,x,y,width,height,0x214)
                end
                if remembered.maximized then mp.set_property_bool('window-maximized',true) end
                blocked_until=now+0.5; return
            end
        end
        if user.IsZoomed(window) ~= 0 then
            if last then last.maximized=true; write() end
            stable=nil; return
        end
        local width, height = tonumber(client.right), tonumber(client.bottom)
        if not number(width,160,16384) or not number(height,90,16384) then return end
        local value = {version=1,width=width,height=height,scale=scale(),maximized=false}
        local key = utils.format_json(value)
        if stable == key then last=value; write() else stable=key end
    end
    -- Suppress in-flight PiP/fullscreen exit geometry until normal bounds have
    -- settled. In particular, pip.lua clears its active flag during shutdown.
    for _, name in ipairs({'fullscreen','user-data/pip/active','window-minimized'}) do
        mp.observe_property(name,'bool',function() blocked_until=mp.get_time()+0.5; stable=nil end)
    end
    local timer = mp.add_periodic_timer(0.25,function()
        local ok, error = pcall(tick)
        if not ok then msg.debug('Window preference sampling skipped: ' .. tostring(error)) end
    end)
    window_memory = function() timer:kill(); pcall(write) end
end)

local fallback_seconds = 3
local window_requested = false
local adapter_ready =
    mp.get_property_native('user-data/adaptive-quality/adapter-ready') == 'yes'
local uosc_ready = mp.get_property_native('user-data/uosc/idle-branding') ~= nil
local image_ready = mp.get_property_native('user-data/idle-branding-image/mode') ~= nil
local fallback_timer = nil

local function publish_state(value)
    mp.set_property_native('user-data/startup-window/state', value)
end

local function request_window(reason)
    if window_requested then return end
    window_requested = true

    if fallback_timer then
        fallback_timer:kill()
        fallback_timer = nil
    end

    local ok, err = pcall(mp.set_property, 'force-window', 'immediate')
    if not ok then
        publish_state('failed')
        msg.error('Unable to create startup window: ' .. tostring(err))
        return
    end

    publish_state(reason or 'ready')
end

local function maybe_request_window()
    if adapter_ready and uosc_ready and image_ready then
        request_window('ready')
    end
end

mp.register_script_message('adapter-ready', function()
    adapter_ready = true
    maybe_request_window()
end)

mp.register_script_message('uosc-ready', function()
    uosc_ready = true
    maybe_request_window()
end)

mp.register_script_message('image-ready', function()
    image_ready = true
    maybe_request_window()
end)

maybe_request_window()

fallback_timer = mp.add_timeout(fallback_seconds, function()
    fallback_timer = nil
    if not window_requested then
        msg.warn('Startup readiness timed out; creating window with available settings')
        request_window('fallback')
    end
end)

publish_state('waiting')

mp.register_event('shutdown', function()
    if window_memory then window_memory() end
    if fallback_timer then
        fallback_timer:kill()
        fallback_timer = nil
    end
end)
