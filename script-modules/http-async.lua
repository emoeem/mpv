-- http-async.lua - 共享的异步 HTTP 请求模块
--
-- 用 curl 子进程 + mp.command_native_async，不阻塞播放线程；返回的句柄可以在
-- 切文件、取消搜索或脚本卸载时中止请求。实现与 skip-segments.lua 内部那套
-- curl + mp.abort_async_command 同源，抽成模块只是为了新脚本复用，
-- 已有调用方保持原样，不做改动。
--
-- 用法：
--   package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua;'}) .. package.path
--   local http = require 'http-async'
--   local handle = http.request({ url = ..., want_json = true }, function(err, data, status)
--       ...
--   end)
--   handle:kill()   -- 取消
--
-- 说明：curl 用 --fail 会在 4xx/5xx 时丢弃响应体，而 API 的错误信息往往就在
-- 响应体里，因此这里改为把 HTTP 状态码追加到 stdout 末尾再解析。

local mp = require 'mp'
local utils = require 'mp.utils'

local M = {}

local STATUS_MARK = '__HTTP_STATUS__'
local seq = 0

-- 只允许 http/https，并拒绝环回、私有和保留地址。
-- 这里的「地址」指请求目标；本地代理是通过 curl --proxy 传的，不受此限制，
-- 因此 127.0.0.1:7890 这类代理仍然可用。
local function split_url(url)
    local scheme, rest = tostring(url):match('^(%a[%w+.-]*)://(.+)$')
    if not scheme then return nil, nil end
    scheme = scheme:lower()
    local authority = rest:match('^([^/?#]*)') or ''
    authority = authority:gsub('^.*@', '')
    local host
    if authority:sub(1, 1) == '[' then
        host = authority:match('^%[([^%]]+)%]')
    else
        host = authority:match('^([^:]+)')
    end
    return scheme, host and host:lower() or nil
end

local function is_private_host(host)
    if host == nil or host == '' then return true end
    if host == 'localhost' or host:match('%.localhost$') or host:match('%.local$')
        or host:match('%.internal$') then
        return true
    end

    if host:find(':', 1, true) then
        -- IPv6 字面量：环回、未指定，以及 fc00::/7 与 fe80::/10
        if host == '::1' or host == '::' then return true end
        if host:match('^fc') or host:match('^fd') then return true end
        if host:match('^fe8') or host:match('^fe9')
            or host:match('^fea') or host:match('^feb') then
            return true
        end
        return false
    end

    local a, b = host:match('^(%d+)%.(%d+)%.')
    if a then
        a, b = tonumber(a), tonumber(b)
        if a == 0 or a == 10 or a == 127 then return true end
        if a == 169 and b == 254 then return true end
        if a == 172 and b and b >= 16 and b <= 31 then return true end
        if a == 192 and b == 168 then return true end
        if a >= 224 then return true end
    end
    return false
end

local function build_args(opts)
    local args = {
        'curl', '-s', '-L', '--max-redirs', '5',
        '--connect-timeout', tostring(opts.connect_timeout or 10),
        '--max-time', tostring(opts.timeout or 30),
    }
    if opts.proxy and opts.proxy ~= '' then
        args[#args + 1] = '--proxy'
        args[#args + 1] = opts.proxy
    end
    if opts.user_agent and opts.user_agent ~= '' then
        args[#args + 1] = '--user-agent'
        args[#args + 1] = opts.user_agent
    end
    for _, header in ipairs(opts.headers or {}) do
        args[#args + 1] = '-H'
        args[#args + 1] = header
    end
    if opts.method and opts.method ~= 'GET' then
        args[#args + 1] = '-X'
        args[#args + 1] = opts.method
    end
    if opts.body then
        args[#args + 1] = '--data-binary'
        args[#args + 1] = opts.body
    end
    if opts.output then
        args[#args + 1] = '-o'
        args[#args + 1] = opts.output
    end
    args[#args + 1] = '-w'
    args[#args + 1] = '\n' .. STATUS_MARK .. '%{http_code}'
    args[#args + 1] = opts.url
    return args
end

-- opts:
--   url            必需
--   method         'GET'（默认）或 'POST'
--   headers        { 'Name: value', ... }
--   body           POST 请求体
--   timeout        总超时秒数，默认 30
--   connect_timeout 连接超时秒数，默认 10
--   proxy          代理地址，空字符串表示不使用
--   user_agent     User-Agent
--   want_json      为真时把响应体解析成 Lua 表
--   output         写入文件路径（配合 download 使用）
--
-- callback(err, data, status)
--   err     成功时为 nil，失败为错误描述
--   data    解析后的表（want_json）或字符串响应体
--   status  HTTP 状态码（可能为 nil）
function M.request(opts, callback)
    seq = seq + 1
    local handle = {
        name = 'http_async_' .. tostring(seq),
        killed = false,
    }

    -- 先用同步方式完成 URL 校验，失败时仍返回可 :kill() 的句柄
    local scheme, host = split_url(opts.url)
    local reject
    if scheme ~= 'http' and scheme ~= 'https' then
        reject = '只允许 http/https 请求：' .. tostring(opts.url)
    elseif is_private_host(host) then
        reject = '拒绝访问本地或私有地址：' .. tostring(host)
    end
    if reject then
        function handle:kill() self.killed = true end
        -- 保持异步回调的语义，不让调用方在 request 返回前就拿到结果
        mp.add_timeout(0, function()
            if not handle.killed then callback(reject, nil, nil) end
        end)
        return handle
    end

    local command_id
    command_id = mp.command_native_async({
        name = 'subprocess',
        args = build_args(opts),
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, result, error)
        if handle.killed then return end
        if not success then
            callback(error or 'curl 调用失败', nil, nil)
            return
        end

        local stdout = (result and result.stdout) or ''
        local stderr = (result and result.stderr) or ''

        -- 从末尾拆出 HTTP 状态码，剩余部分才是响应体
        local body, status = stdout, nil
        local mark_at = stdout:find(STATUS_MARK, 1, true)
        if mark_at then
            body = stdout:sub(1, mark_at - 2)
            status = tonumber(stdout:sub(mark_at + #STATUS_MARK))
        end

        local exit_code = result and result.status or 1
        if exit_code ~= 0 then
            callback(stderr ~= '' and stderr or ('curl 退出码 ' .. tostring(exit_code)), nil, status)
            return
        end

        if status and (status < 200 or status >= 300) then
            callback('HTTP ' .. tostring(status), nil, status)
            return
        end

        if opts.want_json then
            -- 坏 JSON 不应该让整个脚本抛错，parse_json 要包 pcall
            local ok, decoded = pcall(utils.parse_json, body)
            if not ok or type(decoded) ~= 'table' then
                callback('响应不是有效 JSON', nil, status)
                return
            end
            callback(nil, decoded, status)
            return
        end

        callback(nil, body, status)
    end)

    handle.command_id = command_id

    function handle:kill()
        self.killed = true
        if self.command_id then
            pcall(mp.abort_async_command, self.command_id)
        end
    end

    return handle
end

-- 下载到文件：curl 对空响应也会返回 0，必须自己确认文件确实写出来了
function M.download(url, dest, opts, callback)
    local merged = {}
    for key, value in pairs(opts or {}) do
        merged[key] = value
    end
    merged.url = url
    merged.output = dest
    merged.want_json = false

    return M.request(merged, function(err, _, status)
        if err then
            -- 失败时 curl 可能已经把错误响应体写进了目标文件，留着会被当成字幕加载
            os.remove(dest)
            callback(err, status)
            return
        end

        local file = io.open(dest, 'rb')
        if not file then
            callback('下载失败：目标文件不存在')
            return
        end
        local size = file:seek('end')
        file:close()
        if not size or size <= 0 then
            os.remove(dest)
            callback('下载失败：文件为空')
            return
        end

        callback(nil, status)
    end)
end

return M
