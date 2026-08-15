local msg = require('mp.msg')
local utils = require("mp.utils")

local function extract_url(url)
    local path = url:match("^https?://[^/]+(/[^%?]*)")
    return path
end

local function generateXSignature(url, time, appid, app_accept)
    local url_path = extract_url(url)
    if not url_path then
        return nil
    end

    local dataToHash = string.format("%s%d%s%s", AES.ECB.decrypt(KEY, Base64.decode(appid)),
    time, url_path, AES.ECB.decrypt(KEY, Base64.decode(app_accept)))
    local hash = Sha256(dataToHash)
    local base64Hash = Base64.encode(hex_to_bin(hash))
    return base64Hash
end

local function normalize_server(server)
    local normalized = tostring(server or ""):match("^%s*(.-)%s*$"):gsub("/+$", "")
    return normalized
end

local function same_server(a, b)
    return normalize_server(a) == normalize_server(b)
end

local function get_fallback_server_list(skip_server)
    local servers = {}
    for server in tostring(options.fallback_server or ""):gmatch("[^,]+") do
        server = normalize_server(server)
        if server ~= "" and not same_server(server, skip_server) then
            table.insert(servers, server)
        end
    end
    return servers
end

local function get_extcomment_server_list(skip_server)
    local filtered = {}
    for _, server in ipairs(get_api_server_list(options.api_server)) do
        if type(server) == "string" and not server:lower():find("dandanplay%.net") and
            not same_server(server, skip_server) then
            table.insert(filtered, normalize_server(server))
        end
    end
    return filtered
end

local function configured_resolver_mode(record)
    if type(record) ~= "table" or not record.server then return nil end
    for _, server in ipairs(get_extcomment_server_list()) do
        if same_server(server, record.server) then return "api" end
    end
    for _, server in ipairs(get_fallback_server_list()) do
        if same_server(server, record.server) then return "fallback" end
    end
    return nil
end

local function capture_resolver_context(query)
    if type(get_danmaku_resolver_context) == "function" then
        return get_danmaku_resolver_context(query)
    end
end

local function remember_resolver(query, server, mode, context)
    if type(write_danmaku_resolver_affinity) == "function" then
        write_danmaku_resolver_affinity(query, normalize_server(server), mode, context)
    end
end

local function forget_resolver(query, server, context)
    if type(clear_danmaku_resolver_affinity) == "function" then
        clear_danmaku_resolver_affinity(query, normalize_server(server), context)
    end
end

local function apply_resolver_data(data, query, from_menu, server, mode, context)
    if data and data.xml ~= nil and (type(data.xml) ~= "table" or #data.xml > 0) then
        DANMAKU.sources[query] = DANMAKU.sources[query] or {from = "user_custom"}
        DANMAKU.sources[query].data = data.xml
        remember_resolver(query, server, mode, context)
        load_danmaku(from_menu)
        return true
    end

    local count = data and data.comments and (tonumber(data.count) or #data.comments) or 0
    if data and data.comments and count > 1 then
        save_danmaku_data(data.comments, query, "user_custom")
        remember_resolver(query, server, mode, context)
        load_danmaku(from_menu)
        return true
    end
    return false
end

local function resolver_request_url(query, server, mode)
    if mode == "api" then
        return server .. "/api/v2/extcomment?url=" .. url_encode(query)
    end
    return server .. "/?ac=dm&url=" .. query
end

local function try_resolver_affinity(query, record, from_menu, context, callback)
    local mode = configured_resolver_mode(record)
    if not mode then
        callback(false, "removed")
        return
    end

    local server = normalize_server(record.server)
    local args = make_danmaku_request_args("GET", resolver_request_url(query, server, mode), nil, nil, {
        connect_timeout = 3,
        max_time = 6,
        fail_http = true,
    })
    fetch_danmaku_data(args, function(data, err)
        if not err and apply_resolver_data(data, query, from_menu, server, mode, context) then
            msg.info("优先使用上次成功的弹幕节点：" .. server)
            callback(true)
            return
        end
        callback(false, err or "no_data")
    end, {silent = true, callback_on_error = true})
end

-- 写入history.json
-- 读取episodeId获取danmaku
function set_episode_id(input, from_menu, api_server, episode_number)
    from_menu = from_menu or false
    DANMAKU.source = "dandanplay"
    local selected_server = api_server
    for url, source in pairs(DANMAKU.sources) do
        if source.from == "api_server" then
            if not source.from_history then
                DANMAKU.sources[url] = nil
            else
                DANMAKU.sources[url]["data"] = nil
            end
        end
    end

    if not api_server then
        if DANMAKU.api_server ~= nil then
            selected_server = DANMAKU.api_server
        else
            local servers = get_api_server_list(options.api_server)
            if servers and #servers > 0 then
                selected_server = servers[1]
            end
        end
    end

    DANMAKU.api_server = selected_server

    local episodeId = tonumber(input)
    write_history(episodeId, selected_server, episode_number)
    set_danmaku_button()
    fetch_danmaku(episodeId, from_menu, selected_server)
end

-- 回退使用额外的弹幕获取方式
function get_danmaku_fallback(query, skip_server, from_menu, resolver_context)
    if from_menu == nil then from_menu = true end
    resolver_context = resolver_context or capture_resolver_context(query)

    local function do_fallback()
        if options.fallback_server == "" then return end
        local servers = get_fallback_server_list(skip_server)

        local function try_server(index)
            local server = servers[index]
            if not server then
                msg.info("全部备用服务器均无数据或返回格式不正确")
                show_message("备用服务器无数据或返回格式不正确", 3)
                return
            end

            local url = resolver_request_url(query, server, "fallback")
            msg.verbose("尝试获取弹幕：" .. url)
            local args = make_danmaku_request_args("GET", url, nil, nil, {
                connect_timeout = 4,
                max_time = 12,
                fail_http = true,
            })
            if not args then
                try_server(index + 1)
                return
            end

            fetch_danmaku_data(args, function(data, err)
                if not err and apply_resolver_data(data, query, from_menu, server, "fallback", resolver_context) then
                    return
                end
                msg.info("备用服务器无数据，尝试下一节点：" .. server)
                try_server(index + 1)
            end, {silent = true, callback_on_error = true})
        end

        try_server(1)
    end

    if query:find('bilibili.com') or query:find('bilivideo.c[nom]+') then
        load_danmaku_for_bilibili(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('bahamut.akamaized.net') then
        load_danmaku_for_bahamut(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('mgtv.com') then
        load_danmaku_for_mgtv(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('iqiyi.com') then
        load_danmaku_for_iqiyi(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('v.qq.com') then
        load_danmaku_for_tencent(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('v.youku.com') then
        load_danmaku_for_youku(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    do_fallback()
end

-- 返回弹幕请求参数
function make_danmaku_request_args(method, url, headers, body, request_options)
    local args = {
        "curl",
        "-L",
        "-X",
        method,
        "-H",
        "Accept: application/json",
        "-H",
        "User-Agent: " .. options.user_agent,
    }

    if headers then
        for k, v in pairs(headers) do
            table.insert(args, '-H')
            table.insert(args, string.format('%s: %s', k, v))
        end
    end

    if body then
        table.insert(args, '-d')
        table.insert(args, utils.format_json(body))
        table.insert(args, '-H')
        table.insert(args, 'Content-Type: application/json')
    end

    if url:find("api%.dandanplay%.") then
        local time = os.time()
        local appid = "UgjRIH45lE1BBLNmir1WKw=="
        local app_accept = "SzuWlFZAPRMqeWf9qmfp8dcvYr3hvxuSrIRZuAeEfko="
        table.insert(args, '-H')
        table.insert(args, string.format('X-AppId: %s', AES.ECB.decrypt(KEY, Base64.decode(appid))))
        table.insert(args, '-H')
        table.insert(args, string.format('X-Signature: %s', generateXSignature(url, time, appid, app_accept)))
        table.insert(args, '-H')
        table.insert(args, string.format('X-Timestamp: %s', time))
    end

    if options.proxy ~= "" then
        table.insert(args, '-x')
        table.insert(args, options.proxy)
    end

    request_options = request_options or {}
    if request_options.connect_timeout then
        table.insert(args, "--connect-timeout")
        table.insert(args, tostring(request_options.connect_timeout))
    end
    if request_options.max_time then
        table.insert(args, "--max-time")
        table.insert(args, tostring(request_options.max_time))
    end
    if request_options.fail_http then
        table.insert(args, "--fail")
    end

    table.insert(args, url)

    return args
end

local function normalize_danmaku_response(d)
    if not d then return d end
    -- 已经是 comments/count 格式则直接返回
    if d.comments or d.count then return d end

    if d.danmuku and type(d.danmuku) == "table" then
        local out = {}
        for _, item in ipairs(d.danmuku) do
            -- item 预期为数组，索引: 1=time, 2=pos(right/top/bottom), 3=color(hex), 5=content
            local time = tonumber(item[1]) or 0
            local pos = item[2] or "right"
            local color = item[3] or ""
            local content = item[5] or item[4] or ""

            local mode = 1
            if pos == "right" then
                mode = 1
            elseif pos == "top" then
                mode = 4
            elseif pos == "bottom" then
                mode = 5
            end

            local colorDec = 16777215
            if type(color) == "number" then
                colorDec = color
            elseif type(color) == "string" then
                colorDec = hex_to_int_color(color)
            end

            local p = string.format("%.2f,%d,%d", time, mode, colorDec)
            table.insert(out, { p = p, m = content })
        end
        return { comments = out, count = tonumber(d.danum) or #out }
    end

    return d
end

local function get_matched_episode_number(match)
    if type(match) ~= "table" then return nil end
    local explicit = tonumber(match.episodeNumber)
    if explicit then return explicit end

    local title = tostring(match.episodeTitle or "")
    local episode = title:match("[sS]%d+[eE](%d+)")
        or title:match("[eE][pP]?(%d+)")
        or title:match("第%s*(%d+)%s*[话集回]")
        or title:match("^%s*(%d+)%s*$")
    return tonumber(episode)
end

-- 尝试通过解析文件名匹配剧集
local function match_episode(animeTitle, bangumiId, episode_num, api_server)
    local url = api_server .. "/api/v2/bangumi/" .. bangumiId
    local args = make_danmaku_request_args("GET", url)

    if args == nil then
        return
    end

    call_cmd_async(args, function(error, json)
        if error then
            show_message("HTTP 请求失败，打开控制台查看详情", 5)
            msg.error(error)
            return
        end

        local data = utils.parse_json(json)
        if not data or not data.bangumi or not data.bangumi.episodes then
            msg.info("无结果")
            return
        end

        for _, episode in ipairs(data.bangumi.episodes) do
            local ep_num = tonumber(episode.episodeNumber)
            if ep_num and ep_num == tonumber(episode_num) then
                DANMAKU.anime = animeTitle
                DANMAKU.episode = episode.episodeTitle
                set_episode_id(episode.episodeId, nil, api_server, ep_num)
                break
            end
        end
    end)
end

local function match_anime()
    local anime_type = "tvseries"
    local title, season_num, episode_num = parse_title()
    if not episode_num then
        msg.info("无法解析剧集信息")
        if type(auto_associate_extra_danmaku) == "function" then
            auto_associate_extra_danmaku()
        end
        return
    end

    if title:match("OVA") or title:match("OAD") then
        anime_type = "ova"
    end

    -- 并发在多个 api_server 上搜索，遇到第一个可接受的匹配就取消其余请求
    local encoded_query = url_encode(title)
    local servers = get_api_server_list(options.api_server)

    local matched = false
    local cancel_fn = nil

    local function clean_candidate_title(value)
        return tostring(value or "")
            :gsub("^%s*(.-)%s*$", "%1")
            :gsub("%s*【.-】.*$", "")
            :gsub("%s*%(.-%)%s*$", "")
    end

    local function is_tv_series_type(value)
        local kind = tostring(value or ""):lower()
        return kind == "tvseries" or kind == "tv" or kind == "series"
            or kind == "电视剧" or kind == "電視劇"
    end

    local function build_target_title()
        if season_num and tonumber(season_num) > 1 then
            return title .. " 第" .. number_to_chinese(season_num) .. "季"
        end
        return title
    end

    local function is_strict_anime_match(animeTitle)
        local target_title = build_target_title()
        local candidate_title = clean_candidate_title(animeTitle)
        if candidate_title == target_title or candidate_title == title then
            return true, 1
        end
        if candidate_title:match("第一[季部]") and tonumber(season_num) == 1 then
            target_title = title .. " 第一季"
        end
        local score = jaro_winkler(target_title, candidate_title)
        return score >= 0.88, score
    end

    local function build_args(server)
        local url = server .. "/api/v2/search/anime"
        local full_url = url .. "?keyword=" .. encoded_query
        return make_danmaku_request_args("GET", full_url)
    end

    local function per_response(server, err, out)
        if matched then return end
        if err then
            msg.debug(("search anime failed for %s: %s"):format(server, tostring(err)))
            return
        end
        local data = utils.parse_json(out)
        if not data or not data.animes then
            return
        end
        local local_candidates = {}
        for _, anime in ipairs(data.animes) do
            local type_matches = anime_type == "tvseries"
                and is_tv_series_type(anime.type)
                or tostring(anime.type or ""):lower() == anime_type
            if type_matches then
                table.insert(local_candidates, anime)
            end
        end
        if #local_candidates == 1 then
            local a = local_candidates[1]
            local ok, score = is_strict_anime_match(a.animeTitle)
            if ok then
                matched = true
                match_episode(a.animeTitle, a.bangumiId, episode_num, server)
                if cancel_fn then pcall(cancel_fn) end
            else
                msg.info(("唯一候选相似度不足，跳过自动关联: %s (score=%.2f)"):format(tostring(a.animeTitle), score or 0))
            end
            return
        end
        if #local_candidates > 1 and season_num then
            local best_match, best_score = nil, -1
            local target_title = build_target_title()
            for _, anime in ipairs(local_candidates) do
                local animeTitle = clean_candidate_title(anime.animeTitle)
                if animeTitle:match("第一[季部]") and tonumber(season_num) == 1 then
                    target_title = title .. " 第一季"
                end
                local score = jaro_winkler(target_title, animeTitle)
                msg.debug(("候选: %s -> 相似度 %.3f"):format(animeTitle, score))
                if score > best_score then
                    best_score = score
                    best_match = anime
                end
            end
            if best_match and best_score >= 0.88 then
                matched = true
                msg.info(("模糊匹配选中: %s (score=%.2f)"):format(best_match.animeTitle, best_score))
                match_episode(best_match.animeTitle, best_match.bangumiId, episode_num, server)
                if cancel_fn then pcall(cancel_fn) end
                return
            end
        end
        -- 未找到可接受匹配，继续等待其他服务器的返回
    end

    local function final_cb()
        if not matched then
            msg.info("没有找到合适的匹配结果")
            if type(auto_associate_extra_danmaku) == "function" then
                auto_associate_extra_danmaku()
            end
        end
    end

    cancel_fn = parallel_requests(servers, build_args, per_response, final_cb, { concurrency = 5, per_request_timeout = 15 })
end

-- 执行哈希匹配获取弹幕
local function match_file(file_path, file_name, callback)
    -- 计算文件哈希
    local hash = nil
    local file_info = utils.file_info(file_path)
    if file_info and file_info.size >= 16 * 1024 * 1024 then
        local file, error = io.open(normalize(file_path), 'rb')
        if file and not error then
            local m = MD5.new()
            for _ = 1, 16 * 1024 do
                local content = file:read(1024)
                if not content then
                    break
                end
                m:update(content)
            end
            file:close()
            hash = m:finish()
        end
    end

    if hash then msg.info('hash:', hash) end

    local title, season_num, episode_num = parse_title()
    if title and episode_num then
        if season_num then
            file_name = title .. " S" .. season_num .. "E" .. episode_num
        else
            file_name = title .. " E" .. episode_num
        end
    else
        file_name = title
    end

    local servers = get_api_server_list(options.api_server)

    local matched = false
    local cancel_fn = nil

    local function build_args(server)
        local url = server .. "/api/v2/match"
        return make_danmaku_request_args("POST", url, { ["Content-Type"] = "application/json" }, {
            fileName = file_name,
            fileHash = hash or "a1b2c3d4e5f67890abcd1234ef567890",
            matchMode = "hashAndFileName"
        })
    end

    local function per_response(server, err, out)
        if matched then return end
        if err then
            msg.debug(("match failed for %s: %s"):format(server, tostring(err)))
            return
        end
        local data = utils.parse_json(out)
        if not data or not data.isMatched or type(data.matches) ~= "table" or not data.matches[1] then
            return
        end

        local selected = data.matches[1]
        local expected_episode = tonumber(episode_num)
        local matched_episode = get_matched_episode_number(selected)
        if expected_episode and matched_episode ~= expected_episode then
            msg.warn(("自动匹配集数不一致，拒绝结果: 文件=E%s，接口=E%s，%s")
                :format(tostring(expected_episode), tostring(matched_episode or "?"), tostring(selected.episodeTitle or "")))
            return
        end
        matched = true
        DANMAKU.anime = selected.animeTitle
        DANMAKU.episode = selected.episodeTitle

        set_episode_id(selected.episodeId, nil, server, expected_episode or matched_episode)
        if cancel_fn then pcall(cancel_fn) end
        if callback then pcall(callback) end
    end

    local function final_cb()
        if not matched then
            callback("没有匹配的剧集")
        end
    end

    cancel_fn = parallel_requests(servers, build_args, per_response, final_cb, { concurrency = 5, per_request_timeout = 15 })
end

-- 异步获取弹幕数据
function fetch_danmaku_data(args, callback, request_options)
    request_options = request_options or {}
    call_cmd_async(args, function(error, json)
        if error then
            if not request_options.silent then show_message("获取数据失败", 3) end
            msg.error("HTTP 请求失败：" .. error)
            if request_options.callback_on_error then callback(nil, error) end
            return
        end
        local data = utils.parse_json(json)
        if data ~= nil then
            data = normalize_danmaku_response(data)
        else
            local danmaku = parse_xml_danmaku(json)
            if #danmaku > 0 then
                data = {}
                data["xml"] = danmaku
            end
        end
        callback(data, nil)
    end)
end

-- 保存弹幕数据
function save_danmaku_data(comments, query, danmaku_source)
    local danmaku_list = save_danmaku_to_list(comments)

    if DANMAKU.sources[query] ~= nil then
        DANMAKU.sources[query]["data"] = danmaku_list
    else
        DANMAKU.sources[query] = {from = danmaku_source, data = danmaku_list}
    end
end

function save_danmaku_xml(url, xml_string)
    local danmaku_list = parse_xml_danmaku(xml_string)

    if DANMAKU.sources[url] ~= nil then
        DANMAKU.sources[url]["data"] = danmaku_list
    else
        DANMAKU.sources[url] = {from = "user_custom", data = danmaku_list}
    end
end

function save_danmaku_json(url, json_string)
    local danmaku_list = parse_json_danmaku(json_string)

    if DANMAKU.sources[url] ~= nil then
        DANMAKU.sources[url]["data"] = danmaku_list
    else
        DANMAKU.sources[url] = {from = "user_custom", data = danmaku_list}
    end
end

function save_danmaku_downloaded(url, downloaded_file)
    local danmaku_list = parse_danmaku_file(downloaded_file)
    if file_exists(downloaded_file) then
        os.remove(downloaded_file)
    end
    if DANMAKU.sources[url] ~= nil then
        DANMAKU.sources[url]["data"] = danmaku_list
    else
        DANMAKU.sources[url] = {from = "user_custom", data = danmaku_list}
    end
end

-- 处理获取到的数据
function handle_fetched_danmaku(data, url, from_menu)
    if data and data["comments"] then
        if data["count"] == 0 then
            if DANMAKU.sources[url] == nil then
                DANMAKU.sources[url] = {from = "api_server"}
            end
            show_message("该集弹幕内容为空，结束加载", 3)
            msg.verbose("该集弹幕内容为空，结束加载")
            return
        end
        save_danmaku_data(data["comments"], url, "api_server")
        load_danmaku(from_menu)
    else
        show_message("无数据", 3)
        msg.info("无数据")
    end
end

-- 匹配弹幕库 comment, 仅匹配dandan本身弹幕库
-- 通过danmaku api（url）+id获取弹幕
function fetch_danmaku(episodeId, from_menu, api_server)
    local url = api_server .. "/api/v2/comment/" .. episodeId .. "?withRelated=true&chConvert=0"
    show_message("弹幕加载中...", 30)
    msg.verbose("尝试获取弹幕：" .. url)
    local args = make_danmaku_request_args("GET", url)

    if args == nil then
        return
    end

    fetch_danmaku_data(args, function(data)
        handle_fetched_danmaku(data, url, from_menu)
    end)
end

-- 从用户添加过的弹幕源添加弹幕
function addon_danmaku(dir, from_menu)
    if dir then
        local history_json = read_file(HISTORY_PATH)
        local history = utils.parse_json(history_json) or {}
        if history[dir] and history[dir].extra ~= nil then
            return
        end
    end
    for url, source in pairs(DANMAKU.sources) do
        if source.from ~= "api_server" then
            add_danmaku_source(url, from_menu)
        end
    end
end

--通过输入源url获取弹幕库
function add_danmaku_source(query, from_menu)
    if DANMAKU.sources[query] == nil then
        DANMAKU.sources[query] = {from = "user_custom"}
    end

    from_menu = from_menu or false
    if from_menu then
        add_source_to_history(query, DANMAKU.sources[query])
    end

    if is_protocol(query) then
        add_danmaku_source_online(query, from_menu)
    else
        add_danmaku_source_local(query, from_menu)
    end
end

function add_danmaku_source_local(query, from_menu)
    local path = normalize(query)
    if not file_exists(path) then
        msg.warn("无效的文件路径")
        return
    end
    if not (string.match(path, "%.xml$") or string.match(path, "%.json$")) then
        msg.warn("仅支持弹幕文件")
        return
    end

    if DANMAKU.sources[query] ~= nil then
        DANMAKU.sources[query]["from"] = "user_local"
        DANMAKU.sources[query]["data"] = parse_danmaku_file(path)
    else
        DANMAKU.sources[query] = {from = "user_local", data = parse_danmaku_file(path)}
    end

    set_danmaku_button()
    load_danmaku(from_menu)
end

--通过输入源url获取弹幕库
function add_danmaku_source_online(query, from_menu)
    from_menu = from_menu or false
    set_danmaku_button()
    show_message("弹幕加载中...", 30)
    msg.verbose("尝试获取弹幕：" .. query)

    local resolver_context = capture_resolver_context(query)

    local function run_regular_chain(skip_server)
        local servers = get_extcomment_server_list(skip_server)
        if #servers == 0 then
            get_danmaku_fallback(query, skip_server, from_menu, resolver_context)
            return
        end

        local matched = false
        local cancel_fn = nil

        local function build_args(server)
            local url = resolver_request_url(query, server, "api")
            return make_danmaku_request_args("GET", url, nil, nil, {
                connect_timeout = 4,
                max_time = 12,
                fail_http = true,
            })
        end

        local function per_response(server, err, out)
            if matched then return end
            if err then
                msg.debug(("extcomment failed for %s: %s"):format(server, tostring(err)))
                return
            end
            local data = normalize_danmaku_response(utils.parse_json(out))
            if not apply_resolver_data(data, query, from_menu, server, "api", resolver_context) then return end
            matched = true
            if cancel_fn then pcall(cancel_fn) end
        end

        local function final_cb()
            if not matched then
                msg.info("所有服务器均无有效弹幕，尝试备用服务器")
                get_danmaku_fallback(query, skip_server, from_menu, resolver_context)
            end
        end

        cancel_fn = parallel_requests(servers, build_args, per_response, final_cb,
            { concurrency = 3, per_request_timeout = 14 })
    end

    local affinity = type(read_danmaku_resolver_affinity) == "function" and
        read_danmaku_resolver_affinity(query, resolver_context) or nil
    if not affinity then
        run_regular_chain()
        return
    end

    local affinity_server = normalize_server(affinity.server)
    try_resolver_affinity(query, affinity, from_menu, resolver_context, function(success, reason)
        if success then return end
        msg.info(("上次成功的弹幕节点已失效，恢复完整回退：%s (%s)")
            :format(affinity_server, tostring(reason)))
        forget_resolver(query, affinity_server, resolver_context)
        run_regular_chain(affinity_server)
    end)
end

-- 将弹幕转换为 Lua table
function save_danmaku_to_list(comments)
    local danmaku_list = {}

    for _, comment in ipairs(comments) do
        local p = comment["p"]
        local shift = comment["shift"]
        if p then
            local fields = split(p, ",")
            if shift ~= nil then
                fields[1] = tonumber(fields[1]) + tonumber(shift)
            end
            local time = tonumber(fields[1])
            local type = tonumber(fields[2])
            local color = tonumber(fields[3]) or 0xFFFFFF
            local size = 25
            local m_value = comment["m"]
                            :gsub("[%z\1-\31]", "")
                            :gsub("\\", "")
                            :gsub("\"", "")
            table.insert(danmaku_list, {
                time = time,
                type = type,
                size = size,
                color = color,
                text = m_value
            })
        end
    end

    return danmaku_list
end

-- 通过文件前 16M 的 hash 值进行弹幕匹配
function get_danmaku_with_hash(file_name, file_path)
    if type(MD5) ~= "table" or not MD5.sum then
        msg.warn("MD5 模块不支持 Lua 5.1，回退到文件名匹配")
        match_anime()
        return
    end
    if is_protocol(file_path) then
        set_danmaku_button()
        local temp_file = "temp-" .. PID .. ".mp4"
        local arg = {
            "curl",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
            "--range",
            "0-16777215",
            "--user-agent",
            options.user_agent,
            "--output",
            utils.join_path(DANMAKU_PATH, temp_file),
            "-L",
            file_path,
        }

        if options.proxy ~= "" then
            table.insert(arg, '-x')
            table.insert(arg, options.proxy)
        end

        call_cmd_async(arg, function(error)
            file_path = utils.join_path(DANMAKU_PATH, temp_file)

            match_file(file_path, file_name, function(error)
                if error then
                    msg.error(error)
                    msg.info("尝试通过解析文件名获取弹幕")
                    match_anime()
                end
            end)
        end)
    else
        local dir = get_parent_directory(file_path)
        local excluded_path = utils.parse_json(options.excluded_path)
        if PLATFORM == "windows" then
            for i, path in pairs(excluded_path) do
                excluded_path[i] = path:gsub("/", "\\")
            end
        end
        if contains_any(excluded_path, dir) then
            match_anime()
            return
        end
        match_file(file_path, file_name, function(error)
            if error then
                msg.error(error)
                msg.info("尝试通过解析文件名获取弹幕")
                match_anime()
            end
        end)
    end
end
