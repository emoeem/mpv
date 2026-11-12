-- A structured, bounded phone adapter. Candidates retain provider details only
-- inside this script; the cinema bridge receives labels and opaque handles.
local utils = require('mp.utils')
local TitleDisplay = require('modules/title_display')
local REMOTE_PROPERTY = 'user-data/uosc_danmaku/remote-state'
local MAX_ITEMS, MAX_CANDIDATES, MAX_TASKS = 1000, 3000, 8
local scope, generation, serial = nil, 0, 0
local candidates, candidate_order, tasks = {}, {}, {}
local active_load, last_selection
local phase, message, loading_since = 'unmatched', '', nil
local load_stage = 'unmatched'
local published, last_count = nil, 0
local published_inputs
local loaded_revision = 0

local function clean(value, limit)
    if type(value) ~= 'string' and type(value) ~= 'number' then return '' end
    local result = tostring(value):gsub('[%z\1-\31\127]', ' '):gsub('https?://%S+', '[链接]'):match('^%s*(.-)%s*$')
    local length = tonumber(limit) or 240
    if #result > length then
        while length > 0 do
            local next_byte = result:byte(length + 1)
            if not next_byte or next_byte < 128 or next_byte >= 192 then break end
            length = length - 1
        end
        result = result:sub(1, length)
    end
    return result
end

local function path() return mp.get_property('path') end
local function count() return type(COMMENTS) == 'table' and #COMMENTS or 0 end
local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function keyword()
    local ok, title = pcall(parse_title)
    if not ok or not title or title == '' then title = mp.get_property('filename/no-ext', '') end
    return clean(title, 480), ok
end

local function publish()
    -- Keep the 250 ms count/loading watchdog. Stable snapshots can avoid title
    -- parsing and JSON work; compare every input used by the actual parser,
    -- including relative-path normalization and configurable title replacement.
    local enabled = mp.get_property_bool(DANMAKU_SWITCH_ON, ENABLED == true)
    local actual_count = count()
    local live = DANMAKU.sources.__bilibili_live__ ~= nil
    local current_path = path()
    local filename = mp.get_property('filename/no-ext')
    local media_title = mp.get_property('media-title')
    local directory = mp.get_property('working-directory')
    local title_rules = options.title_replace
    local previous = published_inputs
    if previous and previous.enabled == enabled and previous.count == actual_count
        and previous.phase == phase and previous.message == message
        and previous.anime == DANMAKU.anime and previous.episode == DANMAKU.episode
        and previous.live == live and previous.path == current_path
        and previous.filename == filename and previous.media_title == media_title
        and previous.directory == directory and previous.title_rules == title_rules
        and previous.parser == parse_title then return end
    local keyword_text, keyword_stable = keyword()
    local data = {
        available = true,
        enabled = enabled,
        phase = phase, count = actual_count,
        anime = clean((TitleDisplay.anime(DANMAKU.anime))),
        episode = clean((TitleDisplay.episode(DANMAKU.episode))),
        message = clean(message), keyword = keyword_text,
        live = live,
    }
    local encoded = utils.format_json(data)
    -- A transient parser/encoder failure must be retried at the original rate.
    published_inputs = encoded and keyword_stable and {
        enabled=enabled, count=actual_count, phase=phase, message=message,
        anime=DANMAKU.anime, episode=DANMAKU.episode, live=live, path=current_path,
        filename=filename, media_title=media_title, directory=directory,
        title_rules=title_rules, parser=parse_title,
    } or nil
    if encoded ~= published then
        published = encoded
        mp.set_property_native(REMOTE_PROPERTY, data)
    end
end

-- Internal detail is richer than the phone's established four-phase contract.
-- Association metadata never proves a successfully parsed/renderable payload.
function get_danmaku_load_status()
    local actual_count = count()
    local stage = load_stage
    if stage == 'loaded' and actual_count == 0 then stage = 'empty' end
    return {phase = stage, count = actual_count, message = clean(message)}
end

function danmaku_remote_status(next_phase, text)
    local phases = {matching='loading', downloading='loading', loading='loading',
        loaded='loaded', empty='error', error='error', unmatched='unmatched'}
    if not phases[next_phase] then return end
    if next_phase == 'loaded' and count() == 0 then
        next_phase, text = 'empty', '没有可显示的弹幕，请重试或手动搜索'
    end
    load_stage = next_phase == 'loading' and 'downloading' or next_phase
    phase, message = phases[next_phase], text or ''
    loading_since = phase == 'loading' and mp.get_time() or nil
    if phase == 'loaded' then loaded_revision = loaded_revision + 1 end
    last_count = count()
    publish()
end

local function reply(request, ok, data, error_text)
    mp.commandv('script-message-to', 'cinema', 'cinema-danmaku-result', utils.format_json({
        id = request.id, ok = ok, data = data, error = error_text,
    }))
end

local function current(task)
    return not task.done and tasks[task.key] == task and scope == task.scope
        and generation == task.generation and path() == task.path
end

local function abort_processes(task)
    for handle in pairs(task.processes) do pcall(mp.abort_async_command, handle) end
    task.processes = {}
end

local function finish(task, ok, data, error_text)
    if task.done then return end
    task.done = true
    if tasks[task.key] == task then tasks[task.key] = nil end
    if task.timer then task.timer:kill() end
    abort_processes(task)
    if active_load == task then active_load = nil end
    reply(task.request, ok, data, error_text)
end

local function restore(task)
    local previous = task.previous
    if not previous or path() ~= task.path then return end
    -- A desktop selection that supersedes this request owns the current data.
    if task.selected_anime and DANMAKU.anime ~= task.selected_anime then return end
    if task.selected_episode and DANMAKU.episode ~= task.selected_episode then return end
    DANMAKU.sources = previous.sources
    DANMAKU.anime, DANMAKU.episode = previous.anime, previous.episode
    DANMAKU.source, DANMAKU.extra = previous.source, previous.extra
    DANMAKU.api_server = previous.api_server
    ENABLED = previous.enabled
    if ENABLED then load_danmaku(true, true) else hide_danmaku_func() end
    toggle_danmaku_switch(ENABLED and 'on' or 'off')
end

local function cancel(task, text, restore_previous)
    if not task or task.done then return end
    if active_load == task then
        -- Only an explicit phone load owns engine-wide association work.
        invalidate_danmaku_requests()
        if restore_previous then restore(task) end
        phase = count() > 0 and 'loaded' or 'unmatched'
        load_stage = phase
        message, loading_since = '', nil
    end
    finish(task, false, nil, text or '请求已取消')
    publish()
end

function danmaku_remote_desktop_selection()
    if active_load then cancel(active_load, '已在电脑端更换弹幕选择', false) end
end

local function request(task, args, callback)
    if not current(task) then return end
    if type(args) ~= 'table' then callback('invalid_request') return end
    local handle
    handle = mp.command_native_async({name = 'subprocess', args = args,
        capture_stdout = true, capture_stderr = true, playback_only = true}, function(success, result)
        if handle then task.processes[handle] = nil end
        if not current(task) then return end
        if not success or type(result) ~= 'table' or result.status ~= 0 then
            callback('request_failed')
        elseif type(result.stdout) ~= 'string' or #result.stdout > 8 * 1024 * 1024 then
            callback('invalid_response')
        else
            callback(nil, result.stdout)
        end
    end)
    if handle and not task.done then task.processes[handle] = true end
end

local function new_task(request_data)
    local size = 0
    for _ in pairs(tasks) do size = size + 1 end
    if size >= MAX_TASKS then reply(request_data, false, nil, '弹幕请求较多，请稍后重试') return end
    local key = tostring(request_data.request_id or request_data.id)
    if tasks[key] then reply(request_data, false, nil, '该弹幕请求仍在处理中') return end
    local task = {key = key, request = request_data, scope = scope, generation = generation,
        media = request_data.media, path = path(), processes = {}, started = mp.get_time()}
    tasks[key] = task
    task.timer = mp.add_timeout(28, function()
        if not current(task) then return end
        local loading = active_load == task
        cancel(task, '弹幕服务响应超时，请重试或更换来源', true)
        if loading then danmaku_remote_status('error', '弹幕服务响应超时，请重试或更换来源') end
    end)
    return task
end

local function candidate(task, kind, private, item)
    serial = serial + 1
    local id = 'dm-' .. scope .. '-' .. string.format('%08x', serial)
    candidates[id] = {kind = kind, value = private, scope = scope, media = task.media,
        generation = generation, path = task.path}
    candidate_order[#candidate_order + 1] = id
    if #candidate_order > MAX_CANDIDATES then
        candidates[table.remove(candidate_order, 1)] = nil
    end
    item.id = id
    return item
end

local function get_candidate(request_data, kind)
    local entry = type(request_data.value) == 'string' and candidates[request_data.value]
    if not entry or entry.kind ~= kind or entry.scope ~= scope or entry.media ~= request_data.media
        or entry.generation ~= generation or entry.path ~= path() then return nil end
    return entry.value
end

local function year_of(value)
    return tostring(value or ''):match('([12]%d%d%d)')
end

local function season_of(value)
    local text = tostring(value or '')
    return text:match('第[^%s]+季') or text:match('[sS][eE][aA][sS][oO][nN]%s*%d+')
        or (text:match('[sS](%d+)[eE]%d+') and ('第' .. text:match('[sS](%d+)[eE]%d+') .. '季'))
end

local function configured_servers()
    local result, seen = {}, {}
    for _, server in ipairs(get_api_server_list(options.api_server) or {}) do
        if type(server) == 'string' and server:match('^https?://') and not seen[server] then
            seen[server] = true
            result[#result + 1] = server
            if #result >= 12 then break end
        end
    end
    return result
end

local function search(task, query)
    local sources = configured_servers()
    sources[#sources + 1] = false -- the existing 360 extension is also searched
    local rows, cursor, running, done, failed = {}, 1, 0, 0, 0
    local pump
    local function receive(index, server, err, output)
        if not current(task) then return end
        running, done = running - 1, done + 1
        local items = {}
        if err then failed = failed + 1
        elseif server == false then
            local ok, parsed = pcall(parse_extra_search_response, output)
            if ok and type(parsed) == 'table' then
                for _, raw in ipairs(parsed) do
                    local value = type(raw) == 'table' and raw.value
                    if type(value) == 'table' and value[3] == 'get-extra-event'
                        and value[2] == mp.get_script_name() and type(value[6]) == 'string'
                        and value[6]:match('^https?://') then
                        items[#items + 1] = {private = {provider = 'extra', class = value[4],
                            show_id = value[5], url = value[6], site = value[7], title = value[8], year = value[9]},
                            public = {title = clean(raw.title), year = year_of(value[9]),
                                season = clean(season_of(raw.title), 40), source = clean(TitleDisplay.source(value[7]))}}
                    end
                    if #items >= MAX_ITEMS then break end
                end
            else failed = failed + 1 end
        else
            local data = utils.parse_json(output)
            if type(data) ~= 'table' or type(data.animes) ~= 'table' then failed = failed + 1
            else
                for _, anime in ipairs(data.animes) do
                    if type(anime) == 'table' and type(anime.animeTitle) == 'string'
                        and (type(anime.bangumiId) == 'string' or type(anime.bangumiId) == 'number') then
                        local title, provider = TitleDisplay.anime(anime.animeTitle)
                        items[#items + 1] = {private = {provider = 'dandan', title = anime.animeTitle,
                            show_id = tostring(anime.bangumiId), server = server},
                            public = {title = clean(title), year = year_of(anime.animeTitle),
                                season = clean(season_of(anime.animeTitle), 40),
                                source = (provider and clean(provider) .. ' · ' or '')
                                    .. (server:find('api.dandanplay.net', 1, true) and '弹弹Play' or '备用弹幕源 ' .. index)}}
                    end
                    if #items >= MAX_ITEMS then break end
                end
            end
        end
        rows[index] = items
        pump()
    end
    pump = function()
        if not current(task) then return end
        if done == #sources then
            local items = {}
            for index = 1, #sources do
                for _, row in ipairs(rows[index] or {}) do
                    if #items < MAX_ITEMS then items[#items + 1] = candidate(task, 'anime', row.private, row.public) end
                end
            end
            if failed == #sources then finish(task, false, nil, '弹幕搜索服务暂不可用，请稍后重试')
            else finish(task, true, {items = items,
                notice = failed > 0 and '部分来源暂不可用，已显示可用结果' or (#items == MAX_ITEMS and '结果较多，请缩小关键词' or nil)}) end
            return
        end
        while running < 4 and cursor <= #sources and current(task) do
            local index, server = cursor, sources[cursor]
            cursor, running = cursor + 1, running + 1
            local args = server == false and make_extra_search_request_args(query, nil, 3, 7)
                or make_danmaku_request_args('GET', server .. '/api/v2/search/anime?keyword=' .. url_encode(query), nil, nil,
                    {connect_timeout = 3, max_time = 7, fail_http = true})
            request(task, args, function(err, output) receive(index, server, err, output) end)
        end
    end
    pump()
end

local function safe_link(value)
    return type(value) == 'string' and #value <= 4096 and value:match('^https?://') and not value:find('[%z\r\n]') and value or nil
end

local function episodes(task, anime)
    local function emit(rows, notice)
        if not current(task) then return end
        local items = {}
        for _, row in ipairs(rows or {}) do
            if #items >= MAX_ITEMS then break end
            local item = copy(anime)
            item.episode_id, item.number, item.episode_title, item.url = row.id, row.number, row.title, row.url or anime.url
            items[#items + 1] = candidate(task, 'episode', item, {title = clean(row.title), number = tonumber(row.number),
                source = anime.provider == 'extra' and clean(TitleDisplay.source(anime.site)) or '弹弹Play',
                year = year_of(anime.year or anime.title), season = clean(season_of(anime.title), 40)})
        end
        finish(task, true, {items = items, notice = notice})
    end
    if anime.provider == 'dandan' then
        local args = make_danmaku_request_args('GET', anime.server .. '/api/v2/bangumi/' .. url_encode(anime.show_id), nil, nil,
            {connect_timeout = 3, max_time = 10, fail_http = true})
        request(task, args, function(err, output)
            local data = not err and utils.parse_json(output)
            if type(data) ~= 'table' or type(data.bangumi) ~= 'table' or type(data.bangumi.episodes) ~= 'table' then
                finish(task, false, nil, '获取集数失败，请重试或更换来源') return
            end
            local rows = {}
            for _, row in ipairs(data.bangumi.episodes) do
                if type(row) == 'table' and tonumber(row.episodeId) and tonumber(row.episodeId) > 0 then
                    rows[#rows + 1] = {id = tonumber(row.episodeId), title = row.episodeTitle or ('第' .. tostring(row.episodeNumber or #rows + 1) .. '集'),
                        number = tonumber(row.episodeNumber)}
                end
                if #rows >= MAX_ITEMS then break end
            end
            emit(rows, #rows == MAX_ITEMS and '最多显示前1000集，请在电脑上处理更多集数' or nil)
        end)
        return
    end
    if anime.class == '电影' then emit({{title = '电影', number = 1, url = anime.url}}) return end
    local cached = get_extra_remote_episode_rows(anime.show_id, anime.site)
    if cached and #cached > 0 then
        local rows = {}
        for _, row in ipairs(cached) do
            if safe_link(row.url) then rows[#rows + 1] = {title = '第' .. row.index .. '集', number = tonumber(row.index), url = row.url} end
            if #rows >= MAX_ITEMS then break end
        end
        emit(rows) return
    end
    local cat = ({['电视剧'] = 2, ['动漫'] = 4, ['综艺'] = 3})[anime.class]
    if not cat then finish(task, false, nil, '此来源暂不支持获取集数，请更换搜索结果') return end
    local function get(url, callback)
        request(task, {'curl', '-s', '--connect-timeout', '3', '--max-time', '7', '--fail', url}, callback)
    end
    local function detail()
        local base = 'https://api.web.360kan.com/v1/detail?cat=' .. cat .. '&id=' .. url_encode(anime.show_id) .. '&site=' .. url_encode(anime.site)
        get(base, function(err, output)
            local parsed = not err and utils.parse_json(output)
            local total = type(parsed) == 'table' and type(parsed.data) == 'table' and type(parsed.data.allupinfo) == 'table' and tonumber(parsed.data.allupinfo[anime.site])
            if not total or total < 1 then finish(task, false, nil, '获取集数失败，请重试或更换来源') return end
            local rows, first = {}, 1
            local next_batch
            next_batch = function()
                local last = math.min(first + 199, total, MAX_ITEMS)
                get(base .. '&start=' .. first .. '&end=' .. last, function(batch_err, batch_output)
                    local result = not batch_err and utils.parse_json(batch_output)
                    local list = type(result) == 'table' and type(result.data) == 'table' and type(result.data.allepidetail) == 'table' and result.data.allepidetail[anime.site]
                    if type(list) ~= 'table' then
                        if #rows > 0 then emit(rows, '部分集数获取失败，请重新选择作品重试')
                        else finish(task, false, nil, '获取集数失败，请重试或更换来源') end
                        return
                    end
                    for _, row in ipairs(list) do
                        if type(row) == 'table' and safe_link(row.url) and tonumber(row.playlink_num) then
                            rows[#rows + 1] = {title = '第' .. row.playlink_num .. '集', number = tonumber(row.playlink_num), url = row.url}
                        end
                        if #rows >= MAX_ITEMS then break end
                    end
                    first = last + 1
                    if first <= math.min(total, MAX_ITEMS) then next_batch()
                    else emit(rows, total > MAX_ITEMS and '最多显示前1000集' or nil) end
                end)
            end
            next_batch()
        end)
    end
    local spec = utils.format_json({{cat_id = tostring(cat), ent_id = anime.show_id, site = anime.site}})
    get('https://api.so.360kan.com/episodesv2?v_ap=1&s=' .. url_encode(spec), function(err, output)
        local result = not err and utils.parse_json(output)
        local list = type(result) == 'table' and result.code == 0 and type(result.data) == 'table' and type(result.data[1]) == 'table'
            and type(result.data[1].seriesHTML) == 'table' and result.data[1].seriesHTML.seriesPlaylinks
        local rows = {}
        if type(list) == 'table' then
            for index, row in ipairs(list) do
                local url = safe_link(type(row) == 'table' and row.url or row)
                if url then rows[#rows + 1] = {title = '第' .. index .. '集', number = index, url = url} end
                if #rows >= MAX_ITEMS then break end
            end
        end
        if #rows > 0 then emit(rows) else detail() end
    end)
end

local function normalize_extra_url(url)
    if url:match('^.-%.html') then return url:match('^(.-%.html).*') end
    if url:match('^https?://v%.youku%.com/') and url:match('[?&]vid=') then
        return 'https://v.youku.com/v_show/id_' .. url:match('[?&]vid=([^&]+)') .. '.html'
    end
    return url:gsub('%?bsource=360ogvys$', ''):gsub('&.*$', '')
end

local function snapshot()
    local previous = copy(DANMAKU)
    previous.sources, previous.enabled = {}, ENABLED
    for url, source in pairs(DANMAKU.sources) do previous.sources[url] = copy(source) end
    return previous
end

local function start_load(task, selection)
    if active_load then cancel(active_load, '已切换到新的弹幕选择', true) end
    if cancel_danmaku_auto_load then cancel_danmaku_auto_load() end
    active_load, task.previous = task, snapshot()
    task.selection = selection
    last_selection = {value = selection, path = task.path, generation = generation, scope = scope, media = task.media}
    local function complete(success)
        if not current(task) or active_load ~= task then return end
        if success and count() > 0 then
            for url, source in pairs(task.previous.sources) do
                if source.association and not DANMAKU.sources[url] then remove_source_from_history(url) end
            end
            danmaku_remote_status('loaded', '弹幕加载成功')
            finish(task, true, {message = '弹幕加载成功'})
        else
            restore(task)
            danmaku_remote_status('error', count() > 0 and '所选弹幕暂不可用，已保留之前的弹幕' or '未加载到可显示的弹幕，请重试或更换来源')
            finish(task, false, nil, message)
        end
    end
    task.complete = complete
    ENABLED = true
    toggle_danmaku_switch('on')
    danmaku_remote_status('loading', '正在加载所选弹幕')
    if selection.provider == 'dandan' then
        DANMAKU.anime, DANMAKU.episode = selection.title, selection.episode_title
        task.selected_anime, task.selected_episode = DANMAKU.anime, DANMAKU.episode
        set_episode_id(selection.episode_id, true, selection.server, selection.number, {
            defer_history = true, recover_on_failure = false,
            is_current = function() return current(task) and active_load == task end,
            on_complete = complete,
        })
    else
        local url = normalize_extra_url(selection.url)
        begin_danmaku_association({defer_history = true})
        DANMAKU.sources[url] = {from = 'user_custom', association = true}
        DANMAKU.anime = selection.title .. (selection.year and (' (' .. selection.year .. ')') or '')
        DANMAKU.episode = selection.episode_title
        DANMAKU.source, DANMAKU.api_server = selection.site, nil
        DANMAKU.extra = {id = selection.show_id, site = selection.site, play_url = url,
            year = selection.year, class = selection.class, title = selection.title,
            number = selection.number, episodenum = selection.number}
        task.selected_anime, task.selected_episode = DANMAKU.anime, DANMAKU.episode
        add_danmaku_source_online(url, true, nil, true, function(success)
            if not current(task) or active_load ~= task then return end
            if success and count() > 0 then
                write_history()
                add_source_to_history(url, DANMAKU.sources[url])
            end
            complete(success)
        end)
    end
end

local function retry(task)
    if last_selection and last_selection.path == task.path and last_selection.generation == generation
        and last_selection.scope == scope and last_selection.media == task.media then
        start_load(task, last_selection.value) return
    end
    if active_load then cancel(active_load, '已重新匹配弹幕', true) end
    if cancel_danmaku_auto_load then cancel_danmaku_auto_load() end
    invalidate_danmaku_requests()
    task.previous, task.automatic, task.loaded_revision, active_load = snapshot(), true, loaded_revision, task
    ENABLED = true
    toggle_danmaku_switch('on')
    danmaku_remote_status('matching', '正在重新匹配弹幕')
    -- init reuses the engine's filename/history/local XML/online matching chain.
    -- Its callbacks remain protected by the engine generation and our deadline.
    init(task.path)
end

local function reset_all(restore_previous)
    local pending = {}
    for _, task in pairs(tasks) do pending[#pending + 1] = task end
    for _, task in ipairs(pending) do cancel(task, '播放内容或遥控会话已变化，请重试', restore_previous) end
    candidates, candidate_order, last_selection = {}, {}, nil
end

local function receive(json)
    if type(json) ~= 'string' or #json > 8192 then return end
    local value = utils.parse_json(json)
    if type(value) ~= 'table' or value.reply ~= 'cinema' or type(value.id) ~= 'string'
        or #value.id > 128 or not value.id:match('^[%w_%-]+$')
        or type(value.scope) ~= 'string' or #value.scope ~= 16 or not value.scope:match('^%x+$') then return end
    if value.action == 'reset' then
        reset_all(true)
        scope = value.scope
        publish()
        reply(value, true, {message = '弹幕遥控会话已更新'}) return
    end
    if value.scope ~= scope then reply(value, false, nil, '遥控会话已更新，请重新打开弹幕') return end
    if value.action == 'cancel' then
        local target = type(value.target) == 'string' and tasks[value.target]
        if target and target.scope == scope and target.media == value.media then cancel(target, '请求已取消', true) end
        reply(value, true, {message = '请求已取消'}) return
    end
    if not path() or path() == '' then reply(value, false, nil, '请先播放影片，再操作弹幕') return end
    if value.action == 'toggle' then
        if type(value.value) ~= 'boolean' then reply(value, false, nil, '弹幕开关参数无效') return end
        if value.value == false and active_load then cancel(active_load, '已关闭弹幕', true) end
        set_danmaku_enabled(value.value)
        publish()
        reply(value, true, {message = value.value and '弹幕已开启' or '弹幕已关闭'}) return
    end
    if value.action ~= 'search' and value.action ~= 'episodes' and value.action ~= 'load' and value.action ~= 'retry' then
        reply(value, false, nil, '不支持的弹幕操作') return
    end
    if value.action == 'search' then
        local query = type(value.value) == 'string' and value.value:match('^%s*(.-)%s*$')
        if not query or query == '' or #query > 480 or query:find('[%z\1-\31]') then
            reply(value, false, nil, '关键词过长或无效，请输入120字以内的影片名称') return
        end
        local task = new_task(value)
        if task then search(task, query) end
    elseif value.action == 'retry' then
        local task = new_task(value)
        if task then retry(task) end
    else
        local selected = get_candidate(value, value.action == 'episodes' and 'anime' or 'episode')
        if not selected then reply(value, false, nil, '该弹幕结果已过期，请重新搜索') return end
        local task = new_task(value)
        if task then
            if value.action == 'episodes' then episodes(task, selected) else start_load(task, selected) end
        end
    end
end

mp.register_script_message('cinema-remote', receive)
mp.register_event('start-file', function()
    reset_all(false)
    generation = generation + 1
    phase, message, loading_since, last_count = 'unmatched', '', nil, 0
    load_stage = 'unmatched'
    publish()
end)
mp.register_event('end-file', function()
    reset_all(false)
    generation = generation + 1
    phase, message, loading_since = 'unmatched', '', nil
    load_stage = 'unmatched'
    publish()
end)
mp.observe_property(DANMAKU_SWITCH_ON, 'bool', function(_, enabled)
    if enabled == false and active_load and mp.get_property_bool(DANMAKU_SWITCH_ON, true) == false then
        -- A desktop switch-off also owns the final display state. Restoring
        -- older comments after cancellation must not reopen their display.
        if active_load.previous then active_load.previous.enabled = false end
        cancel(active_load, '已关闭弹幕', true)
    end
    publish()
end)
mp.add_periodic_timer(0.25, function()
    local now, actual_count = mp.get_time(), count()
    local settle_delay = math.min(26, math.max(0.75, (tonumber(options.auto_load_delay) or 0) + 0.75))
    if active_load and active_load.automatic and current(active_load) and now - active_load.started > settle_delay
        and not is_async_running() then
        local task = active_load
        if actual_count > 0 and loaded_revision > task.loaded_revision then
            danmaku_remote_status('loaded', '弹幕加载成功')
            finish(task, true, {message = '弹幕加载成功'})
        else
            local failure = '未自动匹配到弹幕，请尝试手动搜索'
            cancel(task, failure, true)
            danmaku_remote_status('error', failure)
        end
    elseif not active_load and phase == 'loading' and loading_since and now - loading_since > settle_delay
        and not is_async_running() then
        phase, load_stage = 'error', 'error'
        message = actual_count > 0 and '自动加载未成功，已保留之前的弹幕' or '自动加载未成功，请重试或手动搜索'
        loading_since = nil
    elseif not active_load and actual_count ~= last_count and phase ~= 'loading' then
        phase = actual_count > 0 and 'loaded' or 'unmatched'
        load_stage = phase
        message = ''
    end
    last_count = actual_count
    publish()
end)
publish()

return {receive = receive}
