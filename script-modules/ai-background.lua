-- Background preparation owns no player pause/filter state.
local mp, utils = require 'mp', require 'mp.utils'
local M = {}
function M.new(settings)
    local self = {ticket=0, key=nil, status='idle', approved=false, failure_code=nil}
    local function key_for(spec)
        return settings.key and settings.key(spec) or utils.format_json(spec)
    end
    local function publish(status)
        self.status = status
        mp.set_property_native('user-data/video-enhancement/ai-prepare-state', status)
    end
    function self:cancel(status)
        self.ticket = self.ticket + 1
        self.approved=false
        if self.request then mp.abort_async_command(self.request); self.request=nil end
        if self.timer then self.timer:kill(); self.timer=nil end
        publish(status or 'idle')
    end
    function self:reset()
        self:cancel(); self.key=nil; self.approved=false; self.failure_code=nil
    end
    function self:allow(spec)
        local key = key_for(spec)
        if self.key ~= key then self:reset(); self.key=key end
        if self.approved then return true end
        if self.status ~= 'idle' then return false end
        publish('preparing')
        if settings.on_start then settings.on_start(spec) end
        local ticket = self.ticket
        local args = {spec.runtime .. '/python.exe', settings.helper, '--spec', utils.format_json(spec)}
        self.request = mp.command_native_async({name='subprocess', args=args,
            playback_only=false, capture_stdout=true, capture_stderr=true}, function(ok, result)
            if ticket ~= self.ticket then return end
            self.request=nil
            if self.timer then self.timer:kill(); self.timer=nil end
            local line = result and (result.stdout or ''):match('([^\r\n]+)[\r\n]*$')
            local data = line and utils.parse_json(line)
            if ok and result.status == 0 and data and data.ok then
                publish('ready')
                local ready_action = settings.on_ready and settings.on_ready(spec, data)
                if ready_action == 'deferred' then
                    mp.osd_message('AI 后台准备完成；符合条件的下个视频片头会尝试启用\n当前视频可在“杳知 → 超分与补帧”中手动启用', 5)
                elseif ready_action == 'deferred-slow' then
                    mp.osd_message('AI 已准备，但实时余量不足；后续同规格视频保持普通播放\n如需尝试，可在菜单中手动启用', 5)
                elseif ready_action then
                    mp.osd_message('AI 后台准备完成，正在自动启用', 3)
                else
                    mp.osd_message('AI 已准备好，可在“杳知 → 超分与补帧”中启用\n当前继续正常播放', 6)
                end
            else
                self.failure_code = data and data.code or 'prepare_failed'
                publish(data and data.code == 'busy' and 'busy' or 'failed')
                mp.osd_message(self.failure_code == 'cuda-driver-too-old'
                    and 'NVIDIA 驱动与 AI 运行库不兼容，正在检查兼容方案'
                    or data and data.code == 'busy'
                    and '另一窗口正在准备 AI，当前正常播放'
                    or 'AI 暂未准备成功，当前继续正常播放', 4)
                if settings.on_failure then settings.on_failure(spec, self.failure_code) end
            end
        end)
        self.timer=mp.add_timeout(settings.timeout, function()
            if ticket ~= self.ticket then return end
            self:cancel('timeout')
            self.failure_code='timeout'
            if settings.on_failure then settings.on_failure(spec, 'timeout') end
            mp.osd_message('AI 后台准备超时，已停止准备；当前继续正常播放', 4)
        end)
        mp.osd_message('AI 正在后台准备，当前正常播放\n可在“杳知 → 超分与补帧”中取消', 4)
        return false
    end
    function self:enable()
        if self.status ~= 'ready' then return false end
        self.approved=true; publish('enabled');return true
    end
    -- Restore only a tested-spec verdict, never a graph, old plan or approval.
    -- This keeps the manual action available on later files without rerunning
    -- the worker. The caller is responsible for checking the current spec.
    function self:restore(spec)
        local key = key_for(spec)
        if self.key ~= key then self:reset(); self.key=key end
        if self.status == 'idle' then publish('ready') end
    end
    function self:retry()
        self:cancel(); self.approved=false; self.failure_code=nil
    end
    publish('idle')
    return self
end
return M
