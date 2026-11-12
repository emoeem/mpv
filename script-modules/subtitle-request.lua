-- Bounded asynchronous requests owned by the current media and menu operation.
local M = {}

function M.new(mp, utils, options)
    local self = {serial = 0}
    local function http_url(value)
        return type(value) == 'string' and value:match('^https?://[^/%s]+')
            and not value:find('[%z\r\n]')
    end
    function self:cancel()
        self.serial = self.serial + 1
        local job = self.active
        self.active = nil
        if job then
            if job.handle then pcall(mp.abort_async_command, job.handle) end
            if job.cleanup then job.cleanup() end
        end
    end
    function self:spawn(args, callback, cleanup)
        self:cancel()
        local job = {serial = self.serial, path = mp.get_property('path'), cleanup = cleanup}
        self.active = job
        local function current()
            return self.serial == job.serial and job.path ~= nil
                and mp.get_property('path') == job.path
        end
        local ok, handle = pcall(mp.command_native_async, {
            name = 'subprocess', args = args, playback_only = true,
            capture_stdout = true, capture_stderr = true, capture_size = 2097152,
        }, function(success, result)
            if self.active == job then self.active = nil end
            if not current() then if cleanup then cleanup() end; return end
            if not success or type(result) ~= 'table' or result.status ~= 0 then
                if cleanup then cleanup() end
                local code = type(result) == 'table' and result.status or nil
                callback(nil, code == 28 and '请求超时，请稍后重试'
                    or code == 22 and '字幕服务返回HTTP错误，请稍后重试'
                    or '网络请求失败，请检查网络或代理', current)
                return
            end
            callback(result, nil, current)
        end)
        if not ok then
            if self.active == job then self.active = nil end
            if cleanup then cleanup() end
            callback(nil, '无法启动字幕请求', current)
        else job.handle = handle end
        return job
    end
    function self:args(timeout)
        local args = {'curl', '-sS', '--fail', '-L', '--max-redirs', '5',
            '--proto', '=http,https', '--proto-redir', '=http,https',
            '--connect-timeout', '10', '--max-time', tostring(timeout),
            '--user-agent', 'mpv'}
        if options.proxy and options.proxy ~= '' then
            args[#args + 1] = '-x'; args[#args + 1] = options.proxy
        end
        return args
    end
    function self:text(url, callback)
        if not http_url(url) then callback(nil, '字幕服务地址无效'); return end
        local args = self:args(30)
        args[#args + 1] = '--max-filesize'; args[#args + 1] = '2097152'
        args[#args + 1] = '--'; args[#args + 1] = url
        return self:spawn(args, function(result, err)
            if not result then callback(nil, err); return end
            callback(result.stdout or '')
        end)
    end
    function self:http(url, callback)
        return self:text(url, function(body, err)
            if not body then callback(nil, err); return end
            local data = utils.parse_json(body)
            if type(data) ~= 'table' then callback(nil, '字幕服务返回格式异常'); return end
            callback(data)
        end)
    end
    function self:download(url, temporary, callback, cleanup)
        if not http_url(url) then if cleanup then cleanup() end; callback(nil, '字幕下载地址无效'); return end
        local args = self:args(60)
        args[#args + 1] = '--max-filesize'; args[#args + 1] = '20971520'
        args[#args + 1] = '-o'; args[#args + 1] = temporary
        args[#args + 1] = '--'; args[#args + 1] = url
        return self:spawn(args, callback, cleanup)
    end
    return self
end

return M
