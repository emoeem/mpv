-- A bounded recovery transaction for premature network EOF after changing aid.
-- Never stores URLs or authentication options outside this Lua state.
local M = {}
local function ui_translator(mp)
    local ok, module = pcall(function()
        return dofile(mp.command_native({'expand-path', '~~/script-modules/yaozhi-i18n.lua'}))
    end)
    return ok and module or {text=function(value) return value end, t=function(value, ...) return string.format(value, ...) end}
end

function M.new(mp, msg)
    local i18n = ui_translator(mp)
    local function ui_message(text, seconds) mp.osd_message(i18n.text(text), seconds) end
    local id, loaded, armed, ending, pending, retry, start_owner
    local watching, observe_retry_position
    local auth = {'http-header-fields', 'user-agent', 'referrer', 'cookies',
        'cookies-file', 'http-proxy', 'tls-verify', 'tls-ca-file',
        'tls-cert-file', 'tls-key-file', 'force-media-title'}
    local function number(v)
        return type(v) == 'number' and v == v and v >= 0 and v < 1e15 and v or nil
    end
    local function duration_now()
        local value = number(mp.get_property_native('duration'))
        return value and value > 0 and value or nil
    end
    local function same(a, b) return a ~= nil and b ~= nil and tostring(a) == tostring(b) end
    local function copy(v)
        if type(v) ~= 'table' then return v end
        local out = {}; for k, value in pairs(v) do out[k] = copy(value) end; return out
    end
    local function get(key) return mp.get_property_native(key) end
    -- The Emby bridge owns source renegotiation, position and the sole retry
    -- budget for its logical entries. Never race it with a second reload.
    local function emby_managed()
        local path = get('path')
        local owner = get('user-data/emby/recovery-owner')
        return type(path) == 'string' and path:match('^emby://') ~= nil
            and get('user-data/emby/managed') == true and type(owner) == 'table'
            and owner.uri == path and same(owner.entryId, id)
    end
    local function local_path(path)
        if type(path) ~= 'string' or path == '' then return nil end
        if path:match('^[/\\][/\\]') then return false end
        local scheme = path:match('^([%a][%w+.-]*):')
        if not scheme or (#scheme == 1 and path:match('^%a:[/\\]')) then return true end
        if scheme:lower() == 'file' then
            local host = path:lower():match('^file://([^/]*)')
            local location = path:lower():match('^file://[^/]*(.*)$') or ''
            if location:gsub('%%5c', '\\'):gsub('%%2f', '/'):match('^[/\\][/\\]') then return false end
            return not host or host == '' or host:lower() == 'localhost'
        end
        return false
    end
    local function is_local_source()
        if get('demuxer-via-network') == true then return false end
        local a, b = local_path(get('path')), local_path(get('stream-open-filename'))
        return a ~= false and b ~= false and (a == true or b == true)
    end
    local function is_network_source()
        if get('demuxer-via-network') == true then return true end
        for _, key in ipairs({'path', 'stream-open-filename'}) do
            local path = get(key)
            if type(path) == 'string' then
                if path:match('^[/\\][/\\]') then return true end
                local scheme = path:lower():match('^([%a][%w+.-]*):')
                if scheme and ((' http https ftp ftps smb sftp dav davs webdav webdavs rtsp rtsps rtmp rtmps udp tcp tls mmsh mmst '):find(' ' .. scheme .. ' ', 1, true)
                    or (scheme == 'file' and local_path(path) == false)) then return true end
            end
        end
        return false
    end
    local function full_playback()
        return get('seekable') == true
            and mp.get_property('play-direction', 'forward') == 'forward'
            and mp.get_property_bool('options/rebase-start-time', true)
            and mp.get_property('options/end', 'none') == 'none'
            and mp.get_property('options/length', 'none') == 'none'
            and mp.get_property('options/frames', 'all') == 'all'
            and mp.get_property_number('ab-loop-a') == nil
            and mp.get_property_number('ab-loop-b') == nil
    end
    local function early(pos, duration)
        return number(pos) and number(duration) and duration > 0
            and pos < duration - math.max(5, math.min(30, duration * .02))
    end
    local function entry_index(expected)
        local list = get('playlist') or {}
        for i, item in ipairs(list) do
            if same(item.id, expected) then return i - 1, item end
        end
    end
    local function still_current(expected)
        local index, item = entry_index(expected)
        return index ~= nil and same(id, expected)
            and get('playlist-current-pos') == index, index, item
    end
    local function restore_start()
        local owner = start_owner; start_owner = nil
        if owner and same(id, owner.id)
            and tostring(get('options/start')) == tostring(owner.value) then
            mp.set_property_native('file-local-options/start', owner.before)
        end
    end
    local function clear_retry()
        if retry and retry.timer then retry.timer:kill() end
        if watching then mp.unobserve_property(observe_retry_position); watching = false end
        retry = nil
    end
    local function stop_failed()
        clear_retry(); armed, ending, pending = nil, nil, nil
        restore_start()
        mp.commandv('stop', 'keep-playlist')
        msg.warn('network audio switch recovery failed; automatic advance blocked')
        ui_message('切换音轨后网络读取失败，已阻止自动跳集。请从 Emby 或原目录重新打开本集。', 8)
    end
    local function complete_if_ready()
        if not retry or not retry.loaded or not retry.restarted or not still_current(retry.id)
            or get('seeking') ~= false or get('eof-reached') == true then return end
        local pos = number(get('time-pos'))
        local was_ready = retry.ready_at_target
        if pos and math.abs(pos - retry.position) <= 5 then retry.ready_at_target = true end
        if pos and retry.ready_at_target
            and (was_ready or get('pause') == true or pos >= retry.position + .25) then
            local completed = retry
            restore_start(); clear_retry()
            completed.retried = true; armed = completed
        end
    end
    local function snapshot_options(target)
        target.options = {}
        for _, key in ipairs(auth) do
            local value = get('options/' .. key)
            if value ~= nil then target.options[key] = copy(value) end
        end
        for _, key in ipairs({'aid', 'sid', 'pause', 'speed'}) do
            local value = get(key)
            if value ~= nil then target.options[key] = copy(value) end
        end
    end
    local function arm(aid)
        local previous = armed
        armed = nil
        if emby_managed() then clear_retry(); return end
        if retry or not loaded or not still_current(id) or not is_network_source()
            or not full_playback() then return end
        if previous and (not same(previous.id, id)
            or mp.get_time() - previous.started > previous.window) then previous = nil end
        local pos = number(get('time-pos')) or (previous and previous.position)
        local duration = duration_now() or (previous and previous.duration)
        if not early(pos, duration) then return end
        local timeout = number(get('options/network-timeout')) or 10
        armed = {id=id, position=pos, duration=duration, started=mp.get_time(), aid=aid,
            window=math.max(15, math.min(120, timeout + 5))}
    end
    mp.register_event('start-file', function(event)
        id, loaded, armed, ending, pending = event.playlist_entry_id, false, nil, nil, nil
        if retry and not same(retry.id, id) then clear_retry() end
        if retry then retry.loaded, retry.restarted, retry.ready_at_target = false, false, false end
        start_owner = nil
    end)
    observe_retry_position = function() complete_if_ready() end
    mp.register_event('file-loaded', function()
        loaded = true
        if retry and same(retry.id, id) then retry.loaded = true end
    end)
    mp.register_event('playback-restart', function()
        if retry and same(retry.id, id) then retry.restarted = true end
        complete_if_ready()
    end)
    mp.add_hook('on_unload', 1, function()
        ending = nil
        if emby_managed() then
            loaded, armed, start_owner = false, nil, nil
            clear_retry()
            return
        end
        local current = still_current(id)
        local pos = number(get('time-pos'))
        if current and retry and same(retry.id, id) then
            if not retry.loaded or early(pos or retry.position, duration_now() or retry.duration) then
                ending = {id=id, failed=true}
            end
        elseif current and armed and mp.get_time() - armed.started <= armed.window
            and full_playback() and is_network_source()
            and early(pos or armed.position, duration_now() or armed.duration) then
            if armed.retried then ending = {id=id, failed=true}
            else
                ending = armed
                ending.position = pos or armed.position
                snapshot_options(ending)
            end
        end
        loaded, armed = false, nil
        restore_start()
    end)
    mp.register_event('end-file', function(event)
        if ending and same(event.playlist_entry_id, ending.id)
            and (event.reason == 'eof' or event.reason == 'error') then
            pending = ending
        else
            pending = nil; clear_retry()
        end
        ending = nil
    end)
    -- This barrier runs before the core chooses the next playlist entry.
    mp.add_hook('on_after_end_file', 1, function()
        local target = pending; pending = nil
        local path = get('path')
        if type(path) == 'string' and path:match('^emby://') then
            if target and not emby_managed() then stop_failed() else clear_retry() end
            return
        end
        if not target then return end
        local current, index = still_current(target.id)
        if not current then clear_retry(); return end
        if target.failed then stop_failed(); return end
        clear_retry(); retry = target
        watching = true; mp.observe_property('time-pos', 'native', observe_retry_position)
        retry.timer = mp.add_timeout(target.window, function()
            if retry == target and still_current(target.id) then stop_failed() end
        end)
        msg.warn('premature network EOF after audio switch; reopening current entry once')
        ui_message('切换音轨后网络读取中断，正在恢复本集…', 3)
        -- Old backups were already restored; a preserve-options flag here
        -- would leave the entry's reload flag set across later file changes.
        mp.commandv('playlist-play-index', tostring(index))
    end)
    mp.add_hook('on_load', 1, function()
        if emby_managed() then return end
        if not retry or not still_current(retry.id) then return end
        for key, value in pairs(retry.options or {}) do
            mp.set_property_native('file-local-options/' .. key, copy(value))
        end
    end)
    mp.add_hook('on_load', 99, function()
        if emby_managed() then return end
        if not retry or not still_current(retry.id) then return end
        local value = tostring(retry.position)
        local before = get('options/start')
        mp.set_property_native('file-local-options/start', value)
        start_owner = {id=id, before=before, value=get('options/start')}
        if retry.aid ~= nil then mp.set_property_native('file-local-options/aid', retry.aid) end
    end)
    return {is_local_source=is_local_source, arm=arm}
end
return M
