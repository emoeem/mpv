-- Headless, bounded subtitle jobs. URLs and download actions stay in this script.
local M = {}
local sources = {all=true, assrt=true, xunlei=true, subtitlecat=true}
local labels = {assrt='Assrt', xunlei='迅雷', subtitlecat='字幕猫'}
local function clean(value, limit)
    value = tostring(value or ''):gsub('[%z\1-\31\127]', ' '):gsub('https?://%S+', '[链接]')
    if #value > (limit or 600) then value = value:sub(1, limit or 600):gsub('[\194-\244][\128-\191]*$', '') end
    return value
end
local function query_ok(value)
    if type(value) ~= 'string' or #value > 480 or value:find('[%z\1-\31\127]') then return false end
    local count = 0
    for _ in value:gmatch('[^\128-\191]') do count = count + 1 end
    return count <= 120
end
local function id_ok(value)
    return type(value)=='string' and #value>=1 and #value<=80 and value:match('^[%w_-]+$')
end

function M.new(env)
    local mp = assert(env.mp)
    local self = {scope='', media=nil, serial=0, actions={}, records={}, order={}, tombstones={}, tombstone_order={}}
    local client = env.request_factory()
    local aggregate = env.session_factory(env.request_factory)
    local task, state, path, created, updated, cancelled = nil, nil, nil, 0, 0, false
    local action_counter, total_results = 0, 0
    -- File selection has its own view; retain the originating result page and
    -- exactly one live continuation independently of that view.
    local results, cursor = nil, ''
    local function now() return mp.get_time() end
    local function current()
        return not cancelled and state ~= nil and path ~= nil and path == mp.get_property('path')
            and (not env.active or env.active())
    end
    local function snapshot()
        if not state then
            return {task='',phase='done',view='results',query=clean(env.keyword(),480),source='all',
                title='搜索下载字幕',message='输入关键词后搜索',items={},sources={},more=''}
        end
        return state
    end
    local function remember(request_id, fingerprint)
        self.records[request_id] = {fingerprint=fingerprint, state=state, time=now()}
        self.order[#self.order+1] = request_id
        while #self.order > 16 do self.records[table.remove(self.order,1)] = nil end
    end
    local function finish(phase, message)
        if not current() then return end
        state.phase, state.message, updated = phase, clean(message), now()
    end
    local function clear_actions()
        self.actions, action_counter, total_results = {}, 0, 0
        results,cursor = nil,''
    end
    function self:cancel(reason)
        client:cancel(); aggregate:cancel()
        if state and (state.phase=='searching' or state.phase=='details' or state.phase=='downloading') then
            state.phase, state.message = 'cancelled', clean(reason or '已取消字幕操作')
            for _, source in ipairs(state.sources) do
                if source.status=='pending' then source.status,source.message='skipped','已取消' end
            end
        end
        cancelled = true
    end
    function self:active() return current() end
    function self:media_changed()
        self:cancel('影片已变化，请重新搜索')
        state, task, path, self.media = nil, nil, nil, nil
        self.records,self.order = {},{}
        self.tombstones,self.tombstone_order = {},{}
        clear_actions()
    end
    local function add_action(title, hint, source, kind, value)
        if action_counter >= 600 then return nil end
        action_counter = action_counter + 1
        local id = 's'..self.serial..'_'..action_counter
        self.actions[id] = {kind=kind,value=value,source=source,title=clean(title)}
        return {id=id,title=clean(title),hint=clean(hint),source=source,kind=kind}
    end
    local function import_items(source, built)
        local items, seen = {}, {}
        for i=3,math.min(#built,102) do
            local item = built[i]
            local value = type(item)=='table' and item.value
            if type(value)=='table' then
                local command = value[3]
                local kind = (command=='fetch-details-event' or command=='cat-details-event') and 'details'
                    or (command=='download-xunlei-event' and 'download')
                if kind then
                    local key=table.concat(value,'\31')
                    if not seen[key] then
                        seen[key]=true
                        local entry=add_action(item.title,item.hint,source,kind,{command=command,args=value})
                        if entry then items[#items+1]=entry end
                    end
                end
            end
        end
        return items
    end
    local function bounded(value)
        local result={}
        if type(value)=='table' then for i=1,math.min(#value,100) do result[i]=value[i] end end
        return result
    end
    local function search_job(source, query, position)
        return {id=source,run=function(request,done)
            if source=='assrt' then
                if not env.assrt_enabled() then done({},'未配置 Token',true);return end
                request:http(env.assrt_url('search',query,position),function(res,err)
                    if not res or tonumber(res.status)~=0 then done(nil,err or '请求失败，请检查 Token 或配额');return end
                    local subs=type(res.sub)=='table' and res.sub.subs
                    local records=bounded(subs)
                    if sources[state.source] and state.source=='assrt' and #records>=15 and total_results<300 then
                        local entry=add_action('下一页','','assrt','more',{query=query,position=position+15})
                        cursor=entry and entry.id or ''
                        state.more=cursor
                    end
                    done(import_items(source,env.assrt_items(query,records,position)))
                end)
            elseif source=='xunlei' then
                request:http(env.xunlei_url(query),function(res,err)
                    if not res or tonumber(res.code)~=0 then done(nil,err or '请求失败');return end
                    done(import_items(source,env.xunlei_items(query,bounded(res.data))))
                end)
            else
                local url,why=env.cat.search_url(query,0)
                if not url then done(nil,why or '搜索地址无效');return end
                request:text(url,function(html,err)
                    if not html then done(nil,err);return end
                    local found,_,why=env.cat.parse_search(html,url,0)
                    if not found then done(nil,why or '网页格式异常');return end
                    local items={}
                    for _,entry in ipairs(found) do
                        local item=add_action(entry.title,entry.hint,source,'details',{command='cat-details-event',url=entry.url})
                        if item then items[#items+1]=item end
                    end
                    done(items)
                end)
            end
        end}
    end
    local function run_search(query, source, position, append)
        local base=append and results and results.items or {}
        cursor=''
        state.items,state.sources,state.more=base,{},''
        local jobs={}
        if source=='all' then for _,id in ipairs({'assrt','xunlei','subtitlecat'}) do jobs[#jobs+1]=search_job(id,query,0) end
        else jobs[1]=search_job(source,query,position or 0) end
        local serial=self.serial
        aggregate:start(query,jobs,function(result)
            if not current() or self.serial~=serial then return end
            local items={}
            for _,item in ipairs(base) do items[#items+1]=item end
            for _,item in ipairs(result.items) do
                if #items<300 then items[#items+1]=item end
            end
            state.items,state.sources=items,{}
            total_results=#items
            if total_results>=300 then cursor='' end
            state.more=cursor
            for _,source_state in ipairs(result.sources) do
                local message=source_state.error
                if message and (message:find('字幕搜索执行失败',1,true) or message:find('无法准备字幕请求',1,true)) then
                    message='字幕服务暂不可用，请稍后重试'
                end
                state.sources[#state.sources+1]={id=source_state.id,status=source_state.status,message=clean(message)}
            end
            updated=now()
            state.phase=result.pending>0 and 'searching' or 'done'
            state.message=result.pending>0 and '正在搜索字幕…' or (#items>0 and '选择结果查看文件或下载' or '未找到字幕，可修改关键词或更换来源')
            results={items=items,sources=state.sources,query=query,source=source,
                title=state.title,more=cursor,phase=state.phase,message=state.message}
        end)
    end
    local function begin(request_id,fingerprint,phase,view,keep)
        self:cancel()
        if env.takeover then env.takeover() end
        self.serial=self.serial+1
        path,task,created,updated,cancelled=mp.get_property('path'),request_id,now(),now(),false
        state={task=task,phase=phase,view=view,query=keep and keep.query or '',source=keep and keep.source or 'all',
            title=keep and keep.title or '搜索下载字幕',message='',items={},sources={},more=''}
        remember(request_id,fingerprint)
    end
    local function files_from_assrt(res)
        local sub=type(res)=='table' and type(res.sub)=='table' and type(res.sub.subs)=='table' and res.sub.subs[1]
        if type(sub)~='table' then finish('error','字幕详情为空');return end
        local files={}
        for _,file in ipairs(bounded(sub.filelist)) do
            if type(file)=='table' and type(file.f)=='string' and type(file.url)=='string' and env.file_allowed(file.f,file.url) then
                local item=add_action(file.f,env.fmt_size(file.s),'assrt','download',{url=file.url,name=file.f})
                if item then files[#files+1]=item end
            end
        end
        if #files==0 and type(sub.url)=='string' and env.file_allowed(sub.filename or 'subtitle',sub.url) then
            local item=add_action(sub.filename or 'subtitle',env.fmt_size(sub.size),'assrt','download',{url=sub.url,name=sub.filename or 'subtitle'})
            if item then files[1]=item end
        end
        table.sort(files,function(a,b)return env.sort(a.title,b.title)end)
        state.items=files
        finish(#files>0 and 'done' or 'error',#files>0 and '选择文件，下载并载入主字幕' or '该结果没有可直接载入的字幕文件')
    end
    local function run_details(action)
        local expected=self.serial
        local function owned() return current() and self.serial==expected end
        if action.source=='assrt' then
            client:http(env.assrt_url('detail',action.value.args[4]),function(res,err)
                if not owned() then return end
                if not res or tonumber(res.status)~=0 then finish('error',err or '字幕详情请求失败');return end
                files_from_assrt(res)
            end)
        else
            local url=action.value.url or action.value.args[4]
            if not env.cat.is_detail_url(url) then finish('error','字幕详情地址无效');return end
            client:text(url,function(html,err)
                if not owned() then return end
                local files,why
                if html then files,why=env.cat.parse_details(html,url) end
                state.items={}
                for _,file in ipairs(files or {}) do
                    if env.cat.is_download_url(file.url) then
                        local item=add_action(file.title or file.language or file.filename,
                            file.original and '原上传字幕 · SRT' or '已有译文 · SRT','subtitlecat','download',
                            {url=file.url,name=file.filename,ext='srt'})
                        if item then state.items[#state.items+1]=item end
                    end
                end
                finish(#state.items>0 and 'done' or 'error',#state.items>0 and '选择已有文件，下载并载入主字幕'
                    or err or why or '没有可下载的现成字幕；不会自动翻译')
            end)
        end
    end
    function self:request(payload)
        if type(payload)~='table' then return nil,'字幕操作参数无效' end
        local action=payload.action
        if action=='reset' then
            if payload.scope=='' then
                self:media_changed();self.scope=''
                return snapshot()
            end
            if type(payload.scope)~='string' or #payload.scope~=16 or not payload.scope:match('^[a-f0-9]+$') then return nil,'字幕授权无效' end
            self:media_changed();self.scope,self.media=payload.scope,payload.media
            return snapshot()
        end
        if self.scope=='' or payload.scope~=self.scope or not env.active() then return nil,'字幕连接已变化，请重新打开' end
        if self.media==nil then self.media=payload.media end
        if payload.media~=self.media then return nil,'影片已变化，请重新搜索' end
        if action=='cancel' then
            if id_ok(payload.target) and not self.tombstones[payload.target] then
                self.tombstones[payload.target]=true
                self.tombstone_order[#self.tombstone_order+1]=payload.target
                while #self.tombstone_order>128 do self.tombstones[table.remove(self.tombstone_order,1)]=nil end
            end
            if payload.target==task then self:cancel('已取消字幕操作') end
            return snapshot()
        end
        if action=='context' then return {available=true,keyword=clean(env.keyword(),480),source='all'} end
        if action=='status' then
            local record=self.records[payload.target]
            return record and record.state or nil,record and nil or '字幕操作已过期，请重新搜索'
        end
        if not id_ok(payload.request_id) then return nil,'字幕任务标识无效' end
        if not mp.get_property('path') then return nil,'请先播放视频，再搜索字幕' end
        local value=payload.value
        local fingerprint
        if action=='search' then
            if type(value)~='table' or not query_ok(value.query) or not sources[value.source] then return nil,'字幕搜索参数无效' end
            value.query=value.query:gsub('^%s+',''):gsub('%s+$','')
            if value.query=='' then return nil,'请输入字幕搜索关键词' end
            fingerprint='search\31'..value.source..'\31'..value.query
        elseif action=='details' or action=='download' or action=='more' then
            if type(value)~='string' then return nil,'字幕结果已失效，请重新搜索' end
            fingerprint=action..'\31'..value
        else return nil,'不支持的字幕操作' end
        local previous=self.records[payload.request_id]
        if previous then
            if previous.fingerprint~=fingerprint then return nil,'字幕任务标识已使用，请重新操作' end
            return previous.state
        end
        if self.tombstones[payload.request_id] then return nil,'字幕操作已取消，请重新操作' end
        if action=='search' then
            clear_actions()
            begin(payload.request_id,fingerprint,'searching','results',{query=value.query,source=value.source})
            run_search(value.query,value.source)
        else
            local selected=self.actions[value]
            if not selected or selected.kind~=action or path~=mp.get_property('path') or now()-updated>600 then return nil,'字幕结果已失效，请重新搜索' end
            local previous_state=state
            if action=='more' then
                if cursor~=value or not results or #results.items>=300 then return nil,'已达到本次结果上限，请缩小关键词' end
                begin(payload.request_id,fingerprint,'searching','results',results)
                run_search(selected.value.query,'assrt',selected.value.position,true)
            elseif action=='details' then
                begin(payload.request_id,fingerprint,'details','files',previous_state)
                state.title=clean(selected.title or '选择字幕文件')
                state.message='正在读取字幕文件…'
                run_details(selected)
            else
                begin(payload.request_id,fingerprint,'downloading',previous_state.view,previous_state)
                state.items,state.sources,state.more=previous_state.items,previous_state.sources,previous_state.more
                state.message='正在下载字幕…'
                local expected=self.serial
                local expected_task,expected_path=task,path
                local function owned()
                    return current() and self.serial==expected and task==expected_task and path==expected_path
                end
                local detail=selected.value
                if detail.command=='download-xunlei-event' then
                    detail={url=detail.args[4],name=detail.args[5],ext=detail.args[6]}
                end
                env.download(client,detail.url,detail.name,selected.source,detail.ext,function(message,done,ok)
                    if not owned() then return end
                    state.message=clean(message)
                    if done then state.phase=ok and 'done' or 'error' end
                    updated=now()
                end,owned)
            end
        end
        return snapshot()
    end
    function self:expire()
        local time=now()
        if state and current() and (state.phase=='searching' or state.phase=='details' or state.phase=='downloading') and time-created>120 then
            self:cancel('字幕操作已超时，请重试')
        end
        if state and time-updated>600 then self:media_changed() end
        for key,record in pairs(self.records) do if time-record.time>600 then self.records[key]=nil end end
    end
    return self
end
return M
