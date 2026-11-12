-- One bounded search generation; each source owns a separate request client.
local M = {}

local function array_length(value, item_type)
    if type(value) ~= 'table' then return nil end
    local count = #value
    for key, item in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key > count or key % 1 ~= 0
            or (item_type and type(item) ~= item_type) then return nil end
    end
    for index = 1, count do if value[index] == nil then return nil end end
    return count
end

function M.new(mp, request_factory)
    assert(type(request_factory) == 'function', 'request factory required')
    local self = {serial = 0, active = false, clients = {}}

    function self:cancel()
        self.serial = self.serial + 1
        self.active = false
        if self.state then self.state.cancelled = true end
        local clients = self.clients
        self.clients = {}
        for _, client in ipairs(clients) do pcall(client.cancel, client) end
    end

    function self:start(query, jobs, on_update)
        local count = array_length(jobs, 'table')
        if type(query) ~= 'string' or not count or count < 1 or count > 3
            or type(on_update) ~= 'function' then
            return nil, '字幕搜索参数无效'
        end
        local ids = {}
        for _, job in ipairs(jobs) do
            if type(job.id) ~= 'string' or job.id == '' or ids[job.id]
                or type(job.run) ~= 'function' then
                return nil, '字幕搜索源配置无效'
            end
            ids[job.id] = true
        end
        local path = mp.get_property('path')
        if not path or path == '' then return nil, '没有正在播放的媒体' end

        self:cancel()
        local serial = self.serial
        local state = {serial = serial, query = query, path = path,
            sources = {}, items = {}, pending = count, completed = 0}
        self.state, self.active = state, true
        for _, job in ipairs(jobs) do
            state.sources[#state.sources + 1] = {id = job.id, status = 'pending', items = {}}
        end

        local function current()
            if self.serial ~= serial or self.state ~= state or state.cancelled then return false end
            if mp.get_property('path') ~= path then self:cancel(); return false end
            return true
        end
        local function notify()
            local ok, err = pcall(on_update, state)
            if not ok then
                state.update_error = tostring(err)
                if current() then self:cancel() end
            end
        end
        notify()
        if not current() then return state end

        -- Build all source states and clients before any run can complete inline.
        local prepared, owned = {}, {}
        for index, job in ipairs(jobs) do
            if not current() then return state end
            local ok, client = pcall(request_factory, job.id)
            if not current() then
                if ok and type(client) == 'table' and type(client.cancel) == 'function' then
                    pcall(client.cancel, client)
                end
                return state
            end
            local entry = {source = state.sources[index], run = job.run}
            if not ok then
                entry.setup_error = '无法准备字幕请求：' .. tostring(client)
            elseif type(client) ~= 'table' or type(client.cancel) ~= 'function' or owned[client] then
                entry.setup_error = '字幕搜索源需要独立请求客户端'
            else
                entry.client = client
                owned[client] = true
                self.clients[#self.clients + 1] = client
            end
            prepared[#prepared + 1] = entry
        end

        for _, entry in ipairs(prepared) do
            if not current() then break end
            local source, settled = entry.source, false
            local function done(items, err, skipped)
                if settled or not current() then return end
                settled = true
                local results = items == nil and {} or items
                if skipped then
                    source.status, source.error = 'skipped', err and tostring(err) or nil
                elseif err ~= nil and err ~= false then
                    source.status, source.error = 'error', tostring(err)
                elseif not array_length(results, 'table') then
                    source.status, source.error = 'error', '字幕搜索结果格式异常'
                else
                    source.status, source.items = 'ok', results
                    for _, item in ipairs(source.items) do state.items[#state.items + 1] = item end
                end
                state.pending = state.pending - 1
                state.completed = state.completed + 1
                self.active = state.pending > 0
                notify()
            end
            if entry.setup_error then
                done(nil, entry.setup_error)
            else
                local ok, err = pcall(entry.run, entry.client, done)
                if not ok and not settled then
                    done(nil, '字幕搜索执行失败：' .. tostring(err))
                    pcall(entry.client.cancel, entry.client)
                end
            end
        end
        return state
    end

    return self
end

return M
