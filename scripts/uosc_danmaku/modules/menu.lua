local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
local msg = require('mp.msg')
local utils = require("mp.utils")
local unpack = unpack or table.unpack
local TitleDisplay = require('modules/title_display')

input_loaded, input = pcall(require, "mp.input")
uosc_available = false
latest_menu_anime = {}
local active_request_cancel = nil
local active_request_type = nil
local request_cancelled = false
local active_request_generation = 0
local SEARCH_CONNECT_TIMEOUT = 3
local SEARCH_REQUEST_TIMEOUT = 8
local SEARCH_UI_COALESCE = 0.12
local EXTRA_SEARCH_KEY = "__extra_search"

-- Keep the source choice in each menu callback, never in sticky global state.
local function search_ui(anime_only, include_extra)
    if anime_only then
        return i18n.t("动漫弹幕搜索"), i18n.t("动漫补充源；无结果时可返回普通弹幕搜索"), "search-anime-proxy-event"
    end
    return i18n.t("在此处输入片名"), include_extra
        and i18n.t("直接搜片名；|ds / |dy 可精确筛选电视剧或电影")
        or i18n.t("使用enter或ctrl+enter进行搜索"), "search-anime-event"
end

local function request_is_current(generation, menu_type)
    return not request_cancelled
        and generation == active_request_generation
        and (menu_type == nil or tostring(active_request_type) == tostring(menu_type))
end

-- 如果 latest_menu_anime 中存在首项为加载占位，移除它（兼容完整 menu props 或 items 数组）
local function strip_loading_from_latest_menu_anime()
    if not latest_menu_anime or #latest_menu_anime == 0 then return end
    local parsed = utils.parse_json(latest_menu_anime)
    if not parsed or type(parsed) ~= "table" then return end
    local function is_loading_item(it)
        if not it or type(it) ~= "table" then return false end
        if it.title == "加载数据中..." or it.title == i18n.t("加载数据中...") then return true end
        if it.italic == true and it.icon == "spinner" then return true end
        return false
    end
    if parsed.items and type(parsed.items) == "table" then
        if #parsed.items > 0 and is_loading_item(parsed.items[1]) then
            table.remove(parsed.items, 1)
            latest_menu_anime = utils.format_json(parsed)
        end
    else
        if #parsed > 0 and is_loading_item(parsed[1]) then
            table.remove(parsed, 1)
            latest_menu_anime = utils.format_json(parsed)
        end
    end
end

-- 统一取消并发请求：设置取消标志、剥离加载占位并调用实际取消函数
local function perform_cancel_active_request(expected_type)
    if expected_type and active_request_type
        and tostring(expected_type) ~= tostring(active_request_type) then
        return
    end
    if not active_request_cancel and not active_request_type then return end

    active_request_generation = active_request_generation + 1
    request_cancelled = true
    strip_loading_from_latest_menu_anime()
    if active_request_cancel then
        pcall(active_request_cancel)
    end
    active_request_cancel = nil
    active_request_type = nil
end

local function make_build_args(encoded_query)
    return function(server)
        local url = server .. "/api/v2/search/anime"
        local full_url = url .. "?keyword=" .. encoded_query
        local args = make_danmaku_request_args("GET", full_url)
        if not args then return nil end

        -- 搜索请求直接面向用户交互：限制连接与总时长，并让 HTTP 4xx/5xx
        -- 立即进入失败分支，避免失效节点拖住菜单最终收口。
        local url_index = #args
        table.insert(args, url_index, "--connect-timeout")
        table.insert(args, url_index + 1, tostring(SEARCH_CONNECT_TIMEOUT))
        table.insert(args, url_index + 2, "--max-time")
        table.insert(args, url_index + 3, tostring(SEARCH_REQUEST_TIMEOUT))
        table.insert(args, url_index + 4, "--fail")
        return args
    end
end

local function build_ordered_search_items(ctx)
    local items = {}
    for _, server in ipairs(ctx.server_order or {}) do
        local list = ctx.server_items and ctx.server_items[server]
        if list and type(list) == "table" then
            for _, item in ipairs(list) do table.insert(items, item) end
        end
    end
    return items
end

local function append_ready_search_sources(ctx)
    ctx.live_items = ctx.live_items or {}
    ctx.published_sources = ctx.published_sources or {}
    for _, server in ipairs(ctx.server_order or {}) do
        if ctx.source_done and ctx.source_done[server] and not ctx.published_sources[server] then
            ctx.published_sources[server] = true
            local list = ctx.server_items and ctx.server_items[server]
            if list and type(list) == "table" then
                for _, item in ipairs(list) do table.insert(ctx.live_items, item) end
            end
        end
    end
    return ctx.live_items
end

local function search_progress_footnote(ctx, complete)
    local base = tostring(ctx.footnote or "")
    if not ctx.total_servers or ctx.total_servers <= 1 then return base end
    local completed = math.min(ctx.total_servers, math.max(0, ctx.completed_count or 0))
    local progress = complete
        and string.format(i18n.t("搜索完成 %d/%d"), completed, ctx.total_servers)
        or string.format(i18n.t("搜索 %d/%d · 仍在继续"), completed, ctx.total_servers)
    return base ~= "" and (base .. "　｜　" .. progress) or progress
end

local function flush_stable_search_menu(ctx, complete)
    if not uosc_available or not request_is_current(ctx.generation, ctx.menu_type) then return nil end
    local live_items = append_ready_search_sources(ctx)
    -- 首批有效结果出现前继续保留单一加载占位，避免先闪出“空目录”。
    if #live_items == 0 and not complete then return nil end
    local on_close = complete and nil
        or { "script-message-to", mp.get_script_name(), "cancel-active-request", ctx.menu_type }
    local updated = update_menu_uosc(ctx.menu_type, ctx.menu_title, live_items,
        search_progress_footnote(ctx, complete), ctx.menu_cmd, ctx.query, nil, on_close, true)
    if updated then latest_menu_anime = updated end
    return updated
end

local function schedule_stable_search_flush(ctx)
    if not uosc_available or ctx.finalized or ctx.flush_timer then return end
    ctx.flush_timer = mp.add_timeout(SEARCH_UI_COALESCE, function()
        ctx.flush_timer = nil
        flush_stable_search_menu(ctx, false)
    end)
end

local function finalize_search_menu(ctx)
    if ctx.finalized then return end
    ctx.finalized = true
    if ctx.flush_timer then
        ctx.flush_timer:kill()
        ctx.flush_timer = nil
    end

    local final_items = build_ordered_search_items(ctx)
    if not request_is_current(ctx.generation, ctx.menu_type) then return end
    if uosc_available then
        -- 当前可见目录保持已经发布的相对顺序；迟到来源只追加。
        -- 另存一份按既有来源优先级排序的完整目录，显式返回时再使用。
        flush_stable_search_menu(ctx, true)
        latest_menu_anime = build_menu_uosc_json(ctx.menu_type, ctx.menu_title, final_items,
            search_progress_footnote(ctx, true), ctx.menu_cmd, ctx.query)
    else
        latest_menu_anime = utils.format_json(final_items)
        if not ctx.first_opened.val and input_loaded and #final_items > 0 then
            ctx.first_opened.val = true
            show_message("", 0)
            input.terminate()
            mp.add_timeout(0.1, function()
                -- 上游 #433 同类守卫：0.1s 窗口内已切新搜索则丢弃过期目录。
                if not request_is_current(ctx.generation, ctx.menu_type) then return end
                open_menu_select(final_items)
            end)
        end
    end
end

local function make_handle_response(ctx)
    return function(server, err, out)
        if not request_is_current(ctx.generation, ctx.menu_type) then
            ctx.remaining.n = math.max(0, ctx.remaining.n - 1)
            return
        end

        if err then
            msg.debug(("search anime failed for %s: %s"):format(server, tostring(err)))
            ctx.server_items[server] = ctx.server_items[server] or {}
        elseif server == ctx.extra_key then
            local ok, extra_items = pcall(parse_extra_search_response, out)
            if not ok or type(extra_items) ~= "table" then
                msg.debug("360 search response parse failed: " .. tostring(extra_items))
                extra_items = {}
            end
            ctx.server_items[server] = extra_items
            ctx.total_count = (ctx.total_count or 0) + #extra_items
        else
            local data = utils.parse_json(out)
            if not data or not data.animes then
                ctx.server_items[server] = ctx.server_items[server] or {}
            else
                for _, anime in ipairs(data.animes) do
                    local item_key = anime.bangumiId or
                        (anime.animeTitle and anime.animeTitle:gsub("%s+", " ") or nil)
                    -- Mirror-local bangumi IDs need not share an ID namespace.
                    local key = item_key and (server .. ':' .. tostring(item_key))
                    if key and not ctx.seen[key] then
                        ctx.seen[key] = true
                        ctx.server_items[server] = ctx.server_items[server] or {}
                        local note = (ctx.server_notes and ctx.server_notes[server]) or nil
                        local hint = anime.typeDescription
                        if note and note ~= "" then
                            if hint and hint ~= "" then
                                hint = hint .. "|" .. note
                            else
                                hint = note
                            end
                        end
                        local display_title, provider = TitleDisplay.anime(anime.animeTitle)
                        if provider then
                            local kind = type(anime.typeDescription) == 'string'
                                and anime.typeDescription:match('^%s*(.-)%s*$') or ''
                            local node = note
                            if not node or node == '' then
                                node = server:match('^https?://api%.dandanplay%.net') and i18n.t('官方')
                                    or server:match('^https?://([^/]+)') or i18n.t('备用节点')
                            end
                            hint = (kind ~= '' and (kind .. ' · ') or '') .. provider .. ' · ' .. node
                        end
                        table.insert(ctx.server_items[server], {
                            title = display_title,
                            hint = hint,
                            value = { "script-message-to", mp.get_script_name(), "search-episodes-event", anime.animeTitle, anime.bangumiId, server },
                        })
                        ctx.total_count = (ctx.total_count or 0) + 1
                    end
                end
            end
        end

        ctx.source_done[server] = true
        ctx.completed_count = math.min(ctx.total_servers, (ctx.completed_count or 0) + 1)
        ctx.remaining.n = math.max(0, ctx.remaining.n - 1)

        if not uosc_available then
            local display_items = append_ready_search_sources(ctx)
            if not ctx.first_opened.val and input_loaded and (ctx.total_count or 0) > 0 then
                ctx.first_opened.val = true
                show_message("", 0)
                input.terminate()
                mp.add_timeout(0.1, function()
                    latest_menu_anime = utils.format_json(display_items)
                    open_menu_select(display_items)
                end)
            end
        end

        if ctx.remaining.n == 0 then
            pcall(finalize_search_menu, ctx)
        else
            schedule_stable_search_flush(ctx)
        end
    end
end

-- 打开番剧数据匹配菜单
function get_animes(query, include_extra, pending_generation, anime_only)
    local request_generation = pending_generation
    if request_generation then
        -- 快速连续提交时，较早的零延迟定时器可能晚于新搜索触发；
        -- 在发出任何网络请求前丢弃它，避免无效请求占用连接。
        if request_generation ~= active_request_generation then return end
    else
        active_request_generation = active_request_generation + 1
        request_generation = active_request_generation
    end
    local encoded_query = url_encode(query)
    local server_setting = options.api_server
    if anime_only then server_setting = options.anime_api_server end
    local server_metas = get_api_server_list(server_setting, true)
    if anime_only and #server_metas == 0 then
        show_message(i18n.t("动漫补充源未启用"), 3)
        return
    end
    local servers = {}
    local server_notes = {}
    for _, m in ipairs(server_metas) do
        table.insert(servers, m.url)
        if m.note and m.note ~= '' then
            server_notes[m.url] = m.note
        end
    end

    local has_extra = not anime_only and include_extra
        and type(make_extra_search_request_args) == "function"
        and type(parse_extra_search_response) == "function"
    local request_sources = {}
    if has_extra then table.insert(request_sources, EXTRA_SEARCH_KEY) end
    for _, server in ipairs(servers) do table.insert(request_sources, server) end

    local seen = {}
    local first_opened = false
    local remaining = #request_sources
    local total_servers = remaining
    local server_items = {}
    local server_order = {}
    if has_extra then table.insert(server_order, EXTRA_SEARCH_KEY) end
    for _, server in ipairs(servers) do
        table.insert(server_order, server)
    end
    local total_count = 0
    request_cancelled = false

    local message = "加载数据中..."
    local menu_type = "menu_anime"
    local menu_title, footnote, event = search_ui(anime_only, include_extra)
    local menu_cmd = { "script-message-to", mp.get_script_name(), event }

    local initial_message = message
    local initial_footnote = footnote
    if total_servers and total_servers > 1 then
        initial_footnote = footnote .. string.format(i18n.t("　｜　搜索 0/%d"), total_servers)
    end
    if uosc_available then
        active_request_type = menu_type
        update_menu_uosc(menu_type, menu_title, initial_message, initial_footnote, menu_cmd, query, "spinner",
            { "script-message-to", mp.get_script_name(), "cancel-active-request", menu_type })
    else
        show_message(initial_message, 30)
    end

    msg.verbose("尝试并行获取影视/番剧数据，sources: " .. table.concat(request_sources, ", ") .. " query: " .. query)

    local build_server_args = make_build_args(encoded_query)
    local function build_args(source)
        if source == EXTRA_SEARCH_KEY then
            return make_extra_search_request_args(query, nil, SEARCH_CONNECT_TIMEOUT, SEARCH_REQUEST_TIMEOUT)
        end
        return build_server_args(source)
    end

    -- 构造 ctx，用于 handle_response 闭包访问和修改共享状态
    local ctx = {
        seen = seen,
        first_opened = { val = first_opened },
        remaining = { n = remaining },
        message = message,
        total_servers = total_servers,
        menu_type = menu_type,
        menu_title = menu_title,
        footnote = footnote,
        menu_cmd = menu_cmd,
        query = query,
        server_items = server_items,
        server_order = server_order,
        server_notes = server_notes,
        total_count = total_count,
        live_items = {},
        source_done = {},
        published_sources = {},
        completed_count = 0,
        flush_timer = nil,
        extra_key = EXTRA_SEARCH_KEY,
        generation = request_generation,
        finalized = false,
    }

    local handle_response = make_handle_response(ctx)

    local cancel_fn = parallel_requests(request_sources, build_args, handle_response, function()
        if request_is_current(ctx.generation, ctx.menu_type) then
            pcall(finalize_search_menu, ctx)
        end
    end, { concurrency = 5, per_request_timeout = SEARCH_REQUEST_TIMEOUT })
    active_request_cancel = cancel_fn
    active_request_type = menu_type
end

function get_episodes(animeTitle, bangumiId, api_server)
    local url = api_server .. "/api/v2/bangumi/" .. bangumiId
    local items = {}

    local message = "加载数据中..."
    local menu_type = "menu_episodes"
    local menu_title = i18n.t("输入集数快速定位")
    local footnote = i18n.t("可立即输入集数，剧集载入后自动定位")
    local episode_menu_options = {
        search_style = "palette",
        search_debounce = 0,
    }

    active_request_generation = active_request_generation + 1
    local request_generation = active_request_generation
    request_cancelled = false
    active_request_type = menu_type

    if uosc_available then
        update_menu_uosc(menu_type, menu_title, message, footnote, nil, nil, "spinner",
            { "script-message-to", mp.get_script_name(), "cancel-active-request", menu_type },
            nil, episode_menu_options)
    else
        show_message(message, 30)
    end

    local args = make_danmaku_request_args("GET", url, nil, nil, {
        connect_timeout = 3, max_time = 10, fail_http = true,
    })

    if args == nil then
        return
    end

    active_request_cancel = call_cmd_async(args, function(err, stdout)
        if not request_is_current(request_generation, menu_type) then return end
        active_request_cancel = nil

        if err then
            local message = i18n.t("剧集加载失败，请换源或重试")
            if uosc_available then
                update_menu_uosc(menu_type, menu_title, message, footnote,
                    nil, nil, nil, nil, true)
            else
                show_message(message, 3)
            end
            msg.error("HTTP 请求失败：" .. tostring(err))
            return
        end

        local response = utils.parse_json(stdout)
        if not response or not response.bangumi or not response.bangumi.episodes then
            local message = i18n.t("无结果")
            if uosc_available then
                update_menu_uosc(menu_type, menu_title, message, footnote,
                    nil, nil, nil, nil, true)
            else
                show_message(message, 3)
            end
            msg.info("无结果")
            return
        end

        table.insert(items, {
            title = i18n.t("← 返回搜索结果"),
            value = { "script-message-to", mp.get_script_name(), "open-latest-menu-anime", latest_menu_anime },
            keep_open = false,
            selectable = true,
        })

        for _, episode in ipairs(response.bangumi.episodes) do
            table.insert(items, {
                title = episode.episodeTitle,
                hint = episode.episodeNumber,
                search_exact_hint = true,
                value = { "script-message-to", mp.get_script_name(), "load-danmaku",
                animeTitle, episode.episodeTitle, episode.episodeId, api_server, episode.episodeNumber },
                keep_open = false,
                selectable = true,
            })
        end

        if uosc_available then
            footnote = i18n.t("输入集数定位，回车加载　｜　") .. tostring(mp.get_property("filename") or "")
            update_menu_uosc(menu_type, menu_title, items, footnote,
                nil, nil, nil, nil, true, episode_menu_options)
        elseif input_loaded then
            show_message("", 0)
            input.terminate()
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
    active_request_type = menu_type
end

local function make_menu_uosc_props(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query,
    message_icon, on_close, menu_options)
    local items = {}
    if type(menu_item) == "string" then
        table.insert(items, {
            title = i18n.text(menu_item),
            value = "",
            italic = true,
            keep_open = true,
            selectable = false,
            align = "center",
            icon = message_icon or "",
        })
    else
        items = menu_item
    end

    local menu_props = {
        type = menu_type,
        title = menu_title,
        search_style = menu_cmd and "palette" or "on_demand",
        search_debounce = menu_cmd and "submit" or 0,
        on_search = menu_cmd,
        footnote = menu_footnote,
        search_suggestion = query,
        uniform_title_size = true,
        items = items,
    }

    if on_close ~= nil then
        menu_props.on_close = on_close
    end

    if type(menu_options) == "table" then
        for key, value in pairs(menu_options) do
            menu_props[key] = value
        end
    end

    return menu_props
end

function build_menu_uosc_json(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query,
    message_icon, on_close, menu_options)
    return utils.format_json(make_menu_uosc_props(menu_type, menu_title, menu_item, menu_footnote,
        menu_cmd, query, message_icon, on_close, menu_options))
end

function update_menu_uosc(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query,
    message_icon, on_close, update_only, menu_options)
    local menu_props = make_menu_uosc_props(menu_type, menu_title, menu_item, menu_footnote,
        menu_cmd, query, message_icon, on_close, menu_options)

    local current_menu_type = mp.get_property_native('user-data/uosc/menu/type')
    if update_only and tostring(current_menu_type) ~= tostring(menu_type) then
        return nil
    end
    local cmd = "open-menu"
    if current_menu_type and tostring(current_menu_type) == tostring(menu_type) then
        cmd = "update-menu"
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", cmd, json_props)

    return json_props
end

local function show_search_loading_menu(query, include_extra, anime_only)
    if not uosc_available then return end

    local title, footnote, event = search_ui(anime_only, include_extra)
    update_menu_uosc(
        "menu_anime",
        title,
        "加载数据中...",
        footnote,
        { "script-message-to", mp.get_script_name(), event },
        query,
        "spinner",
        { "script-message-to", mp.get_script_name(), "cancel-active-request", "menu_anime" }
    )
end

function open_menu_select(menu_items, is_time)
    local item_titles, item_values = {}, {}
    for i, v in ipairs(menu_items) do
        item_titles[i] = is_time and "[" .. v.hint .. "] " .. v.title or
            (v.hint and v.title .. " (" .. v.hint .. ")" or v.title)
        item_values[i] = v.value
    end
    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = is_time and i18n.t('筛选:') or i18n.t('选择:'),
        items = item_titles,
        submit = function(id)
            input.terminate()
            perform_cancel_active_request()
            local v = item_values[id]
            if type(v) == 'table' then
                mp.commandv(unpack(v))
            elseif type(v) == 'string' then
                mp.command(v)
            end
        end,
        closed = function()
            show_message("", 0)
            input.terminate()
            perform_cancel_active_request()
        end,
    })
end

-- 打开弹幕输入搜索菜单
function open_input_menu_get(anime_only)
    mp.commandv('script-message-to', 'console', 'disable')
    local title = parse_title()
    local _, _, event = search_ui(anime_only)
    input.get({
        prompt = anime_only and i18n.t('动漫片名:') or i18n.t('片名:'),
        default_text = title,
        cursor_position = title and #title + 1,
        submit = function(text)
            input.terminate()
            mp.commandv("script-message-to", mp.get_script_name(), event, text)
        end
    })
end

local function append_association_items(items)
    local current = type(get_danmaku_load_status) == 'function' and get_danmaku_load_status() or {}
    local count = type(COMMENTS) == 'table' and #COMMENTS or 0
    local phase = current.phase
    local title = phase == 'matching' and i18n.t('正在匹配弹幕')
        or (phase == 'loading' or phase == 'downloading') and i18n.t('正在下载弹幕')
        or phase == 'error' and (count > 0 and i18n.t('本次加载暂失败 · 已保留之前弹幕') or i18n.t('弹幕暂时加载失败'))
        or phase == 'empty' and (count > 0 and i18n.t('本次来源无有效弹幕 · 已保留之前弹幕') or i18n.t('当前来源没有可显示的弹幕'))
        or count > 0 and (i18n.t('已加载 ') .. count .. i18n.t(' 条弹幕'))
        or (DANMAKU.anime and DANMAKU.episode) and i18n.t('已关联，尚未加载弹幕')
        or i18n.t('尚未匹配弹幕')
    items[#items + 1] = {title = title, hint = i18n.text(current.message or ''),
        bold = true, keep_open = true, selectable = false}
    if not (DANMAKU.anime and DANMAKU.episode) then return end
    local anime, provider = TitleDisplay.anime(DANMAKU.anime)
    local episode = TitleDisplay.episode(DANMAKU.episode)
    items[#items + 1] = {
        title = i18n.t('关联内容：') .. anime .. (episode ~= '' and (' · ' .. episode) or ''),
        hint = TitleDisplay.source(DANMAKU.source, provider),
        keep_open = true, selectable = false,
    }
end

function open_input_menu_uosc(anime_only)
    local items = {}
    append_association_items(items)

    items[#items + 1] = {
        title = anime_only and i18n.t("152468 动漫补充源；选择番剧后再选集加载")
            or i18n.t("直接搜片名；同名结果可加 |ds 或 |dy 精确筛选"),
        align = "center",
        muted = true,
        keep_open = true,
        selectable = false,
    }

    local title, footnote, event = search_ui(anime_only)
    local menu_props = {
        type = "menu_danmaku",
        title = title,
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = parse_title(),
        on_search = { "script-message-to", mp.get_script_name(), event },
        footnote = footnote,
        items = items
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_input_menu(anime_only)
    perform_cancel_active_request()
    if anime_only and #get_api_server_list(options.anime_api_server) == 0 then
        show_message(i18n.t("动漫补充源未启用"), 3)
        return
    end
    if uosc_available then
        open_input_menu_uosc(anime_only)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_input_menu_get(anime_only)
        end)
    end
end

-- 打开弹幕源添加管理菜单
function open_add_menu_get()
    local menu_log, deal_value = {}, {}

    -- 重建菜单内容函数
    local function rebuild_menu_log(select_num)
        deal_value = {}
        menu_log = {
            { text = i18n.t("【既有弹幕源】"), style = "{\\c&H00CCFF&\\b1}" },
            { text = "----------------------------", style = "{\\c&H888888&}" }
        }

        local serial = 0
        for url, source in pairs(DANMAKU.sources) do
            if source.data then
                if source.from == "api_server" then
                    serial = serial + 1
                    local action = source.blocked and "unblock" or "block"
                    local text = string.format(i18n.t("  [%02d] %s [来源：弹幕服务器%s]  "), serial, url,
                        source.blocked and i18n.t("（已屏蔽）") or i18n.t("（未屏蔽）"))
                    local style = (tonumber(select_num) == serial) and "{\\c&HFFDE7F&\\b1}" or (action == "unblock" and "{\\c&H4C4CC3&\\b0}" or "{\\c&HCCCCCC&\\b0}")
                    deal_value[serial] = {value = url, action = action}
                    table.insert(menu_log, {text = text, style = style})
                else
                    serial = serial + 1
                    local action1 = source.blocked and "unblock" or "block"
                    local text1 = string.format(i18n.t("  [%02d] %s [来源：用户添加]%s  "), serial, url, source.blocked and i18n.t(" (已屏蔽)") or i18n.t("（未屏蔽）"))
                    local style1 = (tonumber(select_num) == serial) and "{\\c&HFFDE7F&\\b1}" or (action1 == "unblock" and "{\\c&H4C4CC3&\\b0}" or "{\\c&HCCCCCC&\\b0}")
                    deal_value[serial] = {value = url, action = action1}
                    table.insert(menu_log, {text = text1, style = style1})

                    serial = serial + 1
                    local action2 = "delete"
                    local text2 = string.format(i18n.t("  [%02d] %s [来源：用户添加] (删除)  "), serial, url)
                    local style2 = (tonumber(select_num) == serial) and "{\\c&HFFDE7F&\\b1}" or "{\\c&HCCCCCC&\\b0}"
                    deal_value[serial] = {value = url, action = action2}
                    table.insert(menu_log, {text = text2, style = style2})
                end
            end
        end

        if serial == 0 then
            table.insert(menu_log, { text = i18n.t("        无"), style = "" })
        end
    end

    -- 显示菜单
    local function show_menu(extra_lines, select_num)
        rebuild_menu_log(select_num)

        local display = {}
        for _, item in ipairs(menu_log) do table.insert(display, item) end
        table.insert(display, { text = "----------------------------", style = "{\\c&H888888&}" })

        if extra_lines then
            if #extra_lines < 2 then table.insert(display, { text = "\n", style = "" }) end
            for _, line in ipairs(extra_lines) do table.insert(display, line) end
        else
            table.insert(display, { text = "\n", style = "" })
            table.insert(display, {
                text = i18n.t("提示: 输入【选项数字】可屏蔽或删除既有弹幕源"),
                style = "{\\c&H999999&}"
            })
        end

        input.set_log(display)
    end

    -- 获取操作提示
    local function get_hint(action)
        local hints = {
            block = i18n.t("按回车执行，屏蔽该弹幕源"),
            unblock = i18n.t("按回车执行，解除该弹幕源的屏蔽"),
            delete = i18n.t("按回车执行，删除该弹幕源")
        }
        return hints[action] or i18n.t("按回车执行，获取输入源地址url的弹幕")
    end

    input.get({
        keep_open = true,
        prompt = i18n.t("请在此输入源地址url: "),
        opened = function() show_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                show_menu()
                return
            end

            local num = tonumber(text)
            local event = num and deal_value[num]
            local hint = get_hint(event and event.action)

            show_menu({
                { text = string.format(i18n.t("已输入: %s"), text), style = "{\\c&HCCCCCC&}" },
                { text = hint, style = "{\\c&H999999&}" }
            }, text)
        end,
        submit = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            local num = tonumber(text)
            local event = num and deal_value[num]

            if event then
                local args = string.format('{"type":"activate","value":"%s","action":"%s"}',
                    string.gsub(event.value, '\\', '\\\\'), event.action)
                mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-source", args)
            else
                input.terminate()
                mp.commandv("script-message-to", mp.get_script_name(), "add-source-event", text)
            end

            mp.add_timeout(0.1, show_menu)
        end
    })
end

function open_add_menu_uosc()
    local sources = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data then
            local item = {title = utf8_sub(url, 1, 100), value = url, keep_open = true,}
            if source.from == "api_server" then
                if source.blocked then
                    item.hint = i18n.t("来源：弹幕服务器（已屏蔽）")
                    item.actions = {{icon = "check", name = "unblock", label = i18n.t("解除屏蔽")},}
                else
                    item.hint = i18n.t("来源：弹幕服务器（未屏蔽）")
                    item.actions = {{icon = "not_interested", name = "block", label = i18n.t("屏蔽")},}
                end
            else
                item.hint = i18n.t("来源：用户添加")
                if source.blocked then
                    item.actions = {
                        {icon = "check", name = "unblock", label = i18n.t("解除屏蔽")},
                        {icon = "delete", name = "delete", label = i18n.t("删除")},
                    }
                else
                    item.actions = {
                        {icon = "not_interested", name = "block", label = i18n.t("屏蔽")},
                        {icon = "delete", name = "delete", label = i18n.t("删除")},
                    }
                end
            end
            table.insert(sources, item)
        end
    end
    local menu_props = {
        type = "menu_source",
        title = i18n.t("在此输入源地址url"),
        search_style = "palette",
        search_debounce = "submit",
        on_search = { "script-message-to", mp.get_script_name(), "add-source-event" },
        footnote = i18n.t("使用enter或ctrl+enter进行添加"),
        items = sources,
        item_actions_place = "outside",
        callback = {mp.get_script_name(), 'setup-danmaku-source'},
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_add_menu()
    if uosc_available then
        open_add_menu_uosc()
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_add_menu_get()
        end)
    end
end

-- 打开弹幕内容菜单
function open_content_menu(pos)
    local items = {}
    local time_pos = pos or mp.get_property_native("time-pos")
    local duration = mp.get_property_number("duration", 0)

    if COMMENTS ~= nil then
        for _, event in ipairs(COMMENTS) do
            local text = event.clean_text:gsub("^m%s[mbl%s%-%d%.]+$", ""):gsub("^%s*(.-)%s*$", "%1")
            local delay = event.delay
            local start_time = event.start_time
            local end_time = event.end_time
            if text and text ~= "" and start_time >= 0 and start_time <= duration then
                local delay_label_suffix = nil
                local delay_num = delay and tonumber(delay)
                if delay_num and math.abs(delay_num) > 0 then
                    delay_label_suffix = string.format(i18n.t("已存在延迟: %+0.1fs"), delay_num)
                end

                local adjust_label = i18n.t('调整弹幕延迟')
                if delay_label_suffix then
                    adjust_label = adjust_label .. '（' .. delay_label_suffix .. '）'
                end

                table.insert(items, {
                    title = abbr_str(text, 60),
                    hint = seconds_to_time(start_time) .. "  (" .. utf8_sub(remove_query(event.source), 1, 70) .. ")",
                    actions = {
                        {
                            name = 'block_source',
                            icon = 'block',
                            label = i18n.t('屏蔽对应弹幕源')
                        },
                        {
                            name = 'adjust_delay',
                            icon = 'more_time',
                            label = adjust_label,
                        },
                    },
                    value = { "seek", start_time, "absolute" },
                    active = time_pos >= start_time and time_pos <= end_time,
                })
            end
        end
    end

    local menu_props = {
        type = "menu_content",
        title = i18n.t("弹幕内容"),
        footnote = i18n.t("使用 / 打开搜索"),
        items = items,
        item_actions_place = "outside",
        callback = {mp.get_script_name(), 'handle-danmaku-content-action'},
    }
    local json_props = utils.format_json(menu_props)

    if uosc_available then
        mp.commandv("script-message-to", "uosc", "open-menu", json_props)
    elseif input_loaded then
        open_menu_select(items, true)
    end
end

local menu_items_config = {
    bold = { title = i18n.t("粗体"), hint = options.bold, original = options.bold,
        footnote = "true / false", },
    fontsize = { title = i18n.t("大小"), hint = options.fontsize, original = options.fontsize,
        scope = { min = 0, max = math.huge }, footnote = "请输入整数(>=0)", },
    outline = { title = i18n.t("描边"), hint = options.outline, original = options.outline,
        scope = { min = 0.0, max = 4.0 }, footnote = i18n.t("输入范围：(0.0-4.0)") },
    shadow = { title = i18n.t("阴影"), hint = options.shadow, original = options.shadow,
        scope = { min = 0, max = math.huge }, footnote = "请输入整数(>=0)", },
    scrolltime = { title = i18n.t("速度"), hint = options.scrolltime, original = options.scrolltime,
        scope = { min = 1, max = math.huge }, footnote = "请输入整数(>=1)", },
    opacity = { title = i18n.t("透明度"), hint = options.opacity, original = options.opacity,
        scope = { min = 0, max = 1 }, footnote = i18n.t("输入范围：0（完全透明）到1（不透明）"), },
    displayarea = { title = i18n.t("弹幕显示范围"), hint = options.displayarea, original = options.displayarea,
        scope = { min = 0.0, max = 1.0 }, footnote = i18n.t("显示范围(0.0-1.0)"), },
}
-- 创建一个包含键顺序的表，这是样式菜单的排布顺序
local ordered_keys = {"bold", "fontsize", "outline", "shadow", "scrolltime", "opacity", "displayarea"}

local function save_style_option(key, value)
    local config_path = mp.command_native({
        "expand-path",
        "~~/script-opts/" .. mp.get_script_name() .. ".conf",
    })
    local content = read_file(config_path) or ""
    local serialized = type(value) == "boolean" and (value and "yes" or "no") or tostring(value)
    local pattern_key = key:gsub("([^%w])", "%%%1")
    local replaced

    content, replaced = content:gsub(
        "^([ \t]*" .. pattern_key .. "[ \t]*=)[^\r\n]*",
        "%1" .. serialized,
        1
    )
    if replaced == 0 then
        content, replaced = content:gsub(
            "([\r\n][ \t]*" .. pattern_key .. "[ \t]*=)[^\r\n]*",
            "%1" .. serialized,
            1
        )
    end
    if replaced == 0 then
        local newline = content:find("\r\n", 1, true) and "\r\n" or "\n"
        if content ~= "" and not content:match("[\r\n]$") then
            content = content .. newline
        end
        content = content .. key .. "=" .. serialized .. newline
    end

    local file = io.open(config_path, "wb")
    if not file then
        msg.error("无法保存弹幕样式配置：" .. tostring(config_path))
        show_message(i18n.t("无法保存弹幕样式配置"), 3)
        return false
    end
    file:write(content)
    file:close()
    msg.info(("已保存弹幕样式：%s=%s"):format(key, serialized))
    return true
end

-- Defaults and persisted state are available even before the first video.
local Color = require("modules/color")
local COLOR_PROPERTY = "user-data/uosc_danmaku/smart-color"
local COLOR_PERCENT_PROPERTY = "user-data/uosc_danmaku/smart-color-percent"
local FORCE_WHITE_PROPERTY = "user-data/uosc_danmaku/force-white"
options.smart_color_percent = Color.percentage(options.smart_color_percent)
mp.set_property_bool(COLOR_PROPERTY, options.smart_color)
mp.set_property_number(COLOR_PERCENT_PROPERTY, options.smart_color_percent)
mp.set_property_bool(FORCE_WHITE_PROPERTY, options.force_white)

local function color_switch_status()
    return options.smart_color and i18n.t('● 开启') or i18n.t('○ 关闭')
end

local function color_status()
    if options.force_white then return i18n.t('全白') end
    if not options.smart_color or options.smart_color_percent == 0 then return i18n.t('原生弹幕源') end
    return i18n.t('智能补色 · ') .. options.smart_color_percent .. '%'
end

local function refresh_colors()
    refresh_danmaku_colors()
end

local function open_color_menu(update)
    local items = {
        {title=i18n.t('源自带的彩色也变为白色'), selectable=false, muted=true},
        {title=i18n.t('全白弹幕'), hint=options.force_white and i18n.t('● 开启') or i18n.t('○ 关闭'), keep_open=true,
            value={'script-message-to', mp.get_script_name(), 'toggle-force-white', 'menu'}},
        {title=i18n.t('智能补色'), hint=color_switch_status(), keep_open=true,
            value={'script-message-to', mp.get_script_name(), 'toggle-smart-color', 'menu'}},
        {title=i18n.t('彩色比例'), hint=options.smart_color_percent == 0 and i18n.t('原生弹幕源') or options.smart_color_percent .. '%',
            value={'script-message-to', mp.get_script_name(), 'open-color-percentage'}},
    }
    if uosc_available then
        mp.commandv('script-message-to', 'uosc', update and 'update-menu' or 'open-menu', utils.format_json({
            type='menu_color', title=i18n.t('弹幕颜色 · ') .. color_status(), search_style='disabled', items=items,
            footnote=i18n.t('全白优先；关闭后恢复原色与补色比例'),
        }))
    elseif input_loaded then
        input.select({prompt=i18n.t('弹幕颜色'), items={i18n.t('全白弹幕：') .. (options.force_white and i18n.t('开启') or i18n.t('关闭')),
            i18n.t('智能补色：')..color_switch_status(), i18n.t('彩色比例：')..options.smart_color_percent..'%'},
            submit=function(id)
                local selected = ({items[2], items[3], items[4]})[id + 1]
                if selected then mp.commandv(unpack(selected.value)) end
            end})
    end
end

local function open_color_percentage(update, error_text)
    if uosc_available then
        local items = {}
        for _, value in ipairs({0,25,50,75,100}) do
            items[#items + 1] = {title=value .. '%',
                active=options.smart_color_percent==value,
                hint=value==0 and i18n.t('原生弹幕源') or (value==25 and i18n.t('默认') or nil), keep_open=true,
                value={'script-message-to',mp.get_script_name(),'set-smart-color-percent',tostring(value),'menu'}}
        end
        mp.commandv('script-message-to','uosc',update and 'update-menu' or 'open-menu',utils.format_json({
            type='menu_color_percent', title=i18n.t('彩色比例 · ')..options.smart_color_percent..'%',
            search_style='palette', search_debounce='submit', items=items,
            on_search={'script-message-to',mp.get_script_name(),'submit-color-percentage'},
            footnote=error_text or (i18n.t('0% 为原生弹幕源；全白模式优先；输入 0–100 回车保存')),
        }))
    elseif input_loaded then
        input.get({prompt=i18n.t('彩色比例（0–100）：'), default_text=tostring(options.smart_color_percent),
            submit=function(text) mp.commandv('script-message-to',mp.get_script_name(),'set-smart-color-percent',text,'menu') end})
    end
end

mp.register_script_message('open-color-menu', function() open_color_menu() end)
mp.register_script_message('open-color-percentage', function() open_color_percentage() end)
mp.register_script_message('submit-color-percentage', function(text)
    mp.commandv('script-message-to',mp.get_script_name(),'set-smart-color-percent',text,'menu')
end)
mp.register_script_message('toggle-force-white', function(view)
    local enabled = not options.force_white
    if not save_style_option('force_white', enabled) then return end
    options.force_white = enabled
    mp.set_property_bool(FORCE_WHITE_PROPERTY, enabled)
    refresh_colors()
    show_message(enabled and i18n.t('弹幕颜色：全白（包括源自带彩色）') or
        (i18n.t('弹幕颜色：') .. color_status()), 2)
    if view then open_color_menu(true) end
end)
mp.register_script_message('set-smart-color-percent', function(text, view)
    local value=tonumber(text)
    if not value or value~=value or value<0 or value>100 or value~=math.floor(value) then
        if view then open_color_percentage(true,i18n.t('请输入 0–100 的整数')) else show_message(i18n.t('彩色比例请输入 0–100 的整数'),2) end
        return
    end
    if value~=options.smart_color_percent then
        if not save_style_option('smart_color_percent',value) then return end
        options.smart_color_percent=value
        mp.set_property_number(COLOR_PERCENT_PROPERTY,value)
        refresh_colors()
    end
    if view then open_color_percentage(true) end
end)
mp.register_script_message("toggle-smart-color", function(view)
    local enabled = not options.smart_color
    if not save_style_option("smart_color", enabled) then return end
    options.smart_color = enabled
    refresh_colors()
    mp.set_property_bool(COLOR_PROPERTY, enabled)
    show_message(enabled and i18n.t("彩色弹幕：原始颜色 + 智能补色") or i18n.t("彩色弹幕：仅原始颜色"), 2)
    if view then open_color_menu(true) end
end)

-- 设置弹幕样式菜单
function open_style_menu_get(query, indicator)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local select_num = 0
    local select_query = nil
    if query then
        if tonumber(query) ~= nil then
            select_num = tonumber(query)
        else
            for i, v in ipairs(ordered_keys) do
                if v == query then
                    select_num = i
                end
            end
        end
        select_query = ordered_keys[select_num]
    end

    local function build_menu(source)
        menu_log = {
            { text = i18n.t("【弹幕样式菜单】"), style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        local serial = 0
        for _, key in ipairs(ordered_keys) do
            serial = serial + 1
            local config = menu_items_config[key]
            local text = string.format(i18n.t("  [%02d] %s   [目前：%s] "), serial, config.title, config.hint)
            text = config.hint ~= config.original and text .. "⟳" or text
            local style = serial == select_num and "{\\c&HFFDE7F&}" or "{\\c&HCCCCCC&}"
            local item_config = { text = text, style = style }
            table.insert(menu_log, item_config)
        end

        table.insert(menu_log, { text = ("-"):rep(33), style = "{\\c&H888888&}" })
        if select_num == 0 then
            table.insert(menu_log, {
                text = i18n.t("注: 样式更改会自动保存到配置文件"),
                style = "{\\c&HFFDE7F&}"
            })
            table.insert(menu_log, {
                text = i18n.t("提示: 输入【w】可上移选项，【s】可下移选项"),
                style = "{\\c&H999999&}"
            })
        else
            local input_text = source and source or ""
            local config = menu_items_config[select_query]
            local suffix = ""
            if config and config.hint ~= config.original then
                suffix = i18n.t("（输入\\r恢复默认配置）")
            end
            input_text = string.format(i18n.t("已输入%s: %s"), suffix, input_text)

            local scope = config and i18n.t(config.footnote) or ""
            local hint_text = select_query == "bold" and i18n.t("提示: 输入【y】切换状态") or i18n.t("提示: ") .. scope
            local hint_style = "{\\c&H999999&}"
            if source and source:lower() == "\\r" then
                hint_text = string.format(i18n.t("提示: 回车将恢复默认配置 < %s >"), config.original)
            end
            if indicator == "refresh" or indicator == "updata" then
                indicator = ""
                hint_text = i18n.t("提示: 样式更改成功")
                hint_style = "{\\c&HFFDE7F&}"
                mp.add_timeout(1.5, build_menu)
            elseif indicator == "error" then
                indicator = ""
                hint_text = i18n.t("提示: 输入非数字字符或范围出错")
                hint_style = "{\\c&H4C4CC3&}"
                mp.add_timeout(1.5, build_menu)
            end

            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = hint_text, style = hint_style })
        end
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = i18n.t("请在此输入操作（w/s|上移/下移）: "),
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                build_menu()
                return
            end

            if text:lower() == "w" or text:lower() == "s" then
                input.terminate()
                select_num = text:lower() == "w" and select_num - 1 or select_num + 1
                select_num = (select_num > #ordered_keys) and 1 or (select_num <= 0 and #ordered_keys or select_num)
                mp.add_timeout(0.01, function()
                    open_style_menu_get(select_num)
                end)
                return
            end

            build_menu(text)
        end,
        submit = function(text)
            if select_query == nil then return end
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            if text:lower() == "\\r" then
                input.terminate()
                local args = string.format('{"type":"activate","action":"%s","index":%d}', select_query, select_num)
                mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", args)
            else
                if menu_items_config[select_query]["scope"] ~= nil then
                    input.terminate()
                    mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", select_query, text)
                elseif text:lower() == "y" and select_query == "bold" then
                    input.terminate()
                    local args = string.format('{"type":"activate","index":%d}', select_num)
                    mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", args)
                end
            end
            return
        end
    })
end

function open_style_menu_uosc(actived, status)
    local items = {}
    for _, key in ipairs(ordered_keys) do
        local config = menu_items_config[key]
        local item_config = {
            title = config.title,
            hint = i18n.t("目前：") .. tostring(config.hint),
            active = key == actived,
            keep_open = true,
            selectable = true,
        }
        if config.hint ~= config.original then
            local original_str = tostring(config.original)
            item_config.actions = {{icon = "refresh", name = key, label = i18n.t("恢复默认配置 < ") .. original_str .. " >"}}
        end
        table.insert(items, item_config)
    end

    local menu_props = {
        type = "menu_style",
        title = i18n.t("弹幕样式"),
        search_style = "disabled",
        footnote = i18n.t("样式更改会自动保存到配置文件"),
        item_actions_place = "outside",
        items = items,
        callback = { mp.get_script_name(), 'setup-danmaku-style'},
    }

    local actions = "open-menu"
    if status ~= nil then
        -- msg.info(status)
        if status == "updata" then
            -- "updata" 模式会保留输入框文字
            menu_props.title = "  " .. i18n.t(menu_items_config[actived]["footnote"])
            actions = "update-menu"
        elseif status == "refresh" then
            -- "refresh" 模式会清除输入框文字
            menu_props.title = "  " .. i18n.t(menu_items_config[actived]["footnote"])
        elseif status == "error" then
            menu_props.title = i18n.t("输入非数字字符或范围出错")
            -- 创建一个定时器，在1秒后触发回调函数，删除搜索栏错误信息
            mp.add_timeout(1.0, function() open_style_menu_uosc(actived, "updata") end)
        end
        menu_props.search_style = "palette"
        menu_props.search_debounce = "submit"
        menu_props.footnote = i18n.t(menu_items_config[actived]["footnote"]) or ""
        menu_props.on_search = { "script-message-to", mp.get_script_name(), "setup-danmaku-style", actived }
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", actions, json_props)
end

function open_style_menu(actived, status)
    if uosc_available then
        open_style_menu_uosc(actived, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_style_menu_get(actived, status)
        end)
    else
        show_message(i18n.t("无支持可用的 UI框架，不支持使用该功能"), 3)
    end
end

-- 打开以指定时间为起点的延迟菜单
function open_delay_from_time_get(source, time, status)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local function build_menu(query, input_text)
        menu_log = {
            { text = i18n.t("【从该时间起调整弹幕延迟】"), style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        table.insert(menu_log, { text = "\n", style = "" })
        local hint_text = i18n.t("提示：请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数")
        local hint_style = "{\\c&H999999&}"
        if status == "error" then
            hint_text = i18n.t("提示: 输入非数字字符或范围出错")
            hint_style = "{\\c&H4C4CC3&}"
        end

        table.insert(menu_log, { text = input_text and (i18n.t("已输入：") .. input_text) or "", style = "{\\c&HCCCCCC&}" })
        table.insert(menu_log, { text = hint_text, style = hint_style })
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = i18n.t("请输入要设置的延迟（秒或 XmYs）: "),
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then
                build_menu()
                return
            end
            build_menu(text)
        end,
        submit = function(text)
            text = text and text:gsub("^%s*(.-)%s*$", "%1") or ""
            if text == "" then return end
            input.terminate()
            local parsed = parse_delay_input(text)
            if parsed ~= nil then
                mp.commandv("script-message", "danmaku-delay", tostring(parsed), tostring(time), tostring(source))
            else
                open_delay_from_time(time, "error")
            end
        end
    })
end

function open_delay_from_time_uosc(source, time, status)
    if not uosc_available then
        show_message(i18n.t("无uosc UI框架，不支持使用该功能"), 2)
        return
    end

    local menu_props = {
        type = "menu_delay_from_time",
        title = i18n.t("从该时间起调整弹幕延迟"),
        search_style = "palette",
        search_debounce = "submit",
        footnote = i18n.t("请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"),
        items = {},
        on_search = { "script-message-to", mp.get_script_name(), "setup-content-delay", tostring(time), tostring(source) },
    }

    if status == "error" then
    menu_props.title = i18n.t("输入非数字字符或范围出错")
    mp.add_timeout(1.0, function() open_delay_from_time_uosc(source, time) end)
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_delay_from_time(source, time, status)
    if uosc_available then
        open_delay_from_time_uosc(source, time, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_delay_from_time_get(source, time, status)
        end)
    else
        show_message(i18n.t("无支持可用的 UI框架，不支持使用该功能"), 3)
    end
end

-- 设置弹幕源延迟菜单
function open_delay_menu_get(source, status)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local serial = 0
    local select_num = 0
    if source and tonumber(source) ~= nil then
        select_num = tonumber(source)
    end
    local select_url = nil

    local function build_menu(query, text)
        menu_log = {
            { text = i18n.t("【弹幕源延迟菜单】"), style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        serial, select_num = 0, 0
        for url, src in pairs(DANMAKU.sources) do
            if src.data and not src.blocked then
                local delay = 0
                serial = serial + 1
                select_num = (url == source) and serial or select_num
                if src.delay_segments then
                    for _, seg in ipairs(src.delay_segments) do
                        if seg.start == 0 then
                            delay = seg.delay or 0
                            break
                        end
                    end
                end
                local hint = i18n.t("当前弹幕源延迟: ") .. string.format("%.1f", delay + 1e-10) .. i18n.t("秒")
                local text = string.format("  [%02d] %s   [%s] ", serial, url, hint)
                local style = (serial == select_num) and "{\\c&HFFDE7F&}" or "{\\c&HCCCCCC&}"
                table.insert(menu_log, { text = text, style = style })
                select_url = serial == select_num and url or select_url
            end
        end
        if serial == 0 then
            table.insert(menu_log, { text = i18n.t("        无"), style = "" })
        end

        table.insert(menu_log, { text = ("-"):rep(33), style = "{\\c&H888888&}" })
        if select_num == 0 then
            table.insert(menu_log, { text = "\n", style = "" })
            table.insert(menu_log, {
                text = i18n.t("提示: 输入【w】可上移选项，【s】可下移选项"),
                style = "{\\c&H999999&}"
            })
        else
            local input_text = i18n.t("已输入：") .. (text ~= nil and text or "")

            local hint_text = i18n.t("提示：请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数")
            local hint_style = "{\\c&H999999&}"
            if status == "refresh" then
                status = ""
                hint_text = i18n.t("提示: 样式更改成功")
                hint_style = "{\\c&HFFDE7F&}"
                mp.add_timeout(1.5, build_menu)
            elseif status == "error" then
                status = ""
                hint_text = i18n.t("提示: 输入非数字字符或范围出错")
                hint_style = "{\\c&H4C4CC3&}"
                mp.add_timeout(1.5, build_menu)
            end

--            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = hint_text, style = hint_style })
        end
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = i18n.t("请在此输入操作（w/s|上移/下移）: "),
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                build_menu()
                return
            end

            if text:lower() == "w" or text:lower() == "s" then
                input.terminate()
                select_num = text:lower() == "w" and select_num - 1 or select_num + 1
                select_num = (select_num > serial) and 1 or (select_num <= 0 and serial or select_num)
                mp.add_timeout(0.01, function()
                    open_delay_menu_get(select_num)
                end)
                return
            end

            build_menu(select_num, text)
        end,
        submit = function(text)
            if select_url == nil then return end
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            input.terminate()
            mp.commandv("script-message-to", mp.get_script_name(), "setup-source-delay", select_url, text)
            return
        end
    })
end

function open_delay_menu_uosc(source_url, status)
    if not uosc_available then
        show_message(i18n.t("无uosc UI框架，不支持使用该功能"), 2)
        return
    end

    local sources = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data and not source.blocked then
            local delay = 0
            if source.delay_segments then
                for _, seg in ipairs(source.delay_segments) do
                    if seg.start == 0 then
                        delay = seg.delay or 0
                        break
                    end
                end
            end
            local item = {title = utf8_sub(url, 1, 100), value = url, keep_open = true,}
            item.hint = i18n.t("当前弹幕源延迟:") .. string.format("%.1f", delay + 1e-10) .. i18n.t("秒")
            item.active = url == source_url
            table.insert(sources, item)
        end
    end

    local menu_props = {
        type = "menu_delay",
        title = i18n.t("弹幕源延迟设置"),
        search_style = "disabled",
        items = sources,
        callback = {mp.get_script_name(), 'setup-source-delay'},
    }
    if source_url ~= nil then
        if status == "error" then
            menu_props.title = i18n.t("输入非数字字符或范围出错")
            -- 创建一个定时器，在1秒后触发回调函数，删除搜索栏错误信息
            mp.add_timeout(1.0, function() open_delay_menu_uosc(source_url) end)
        else
            menu_props.title = i18n.t("请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数")
        end
        menu_props.search_style = "palette"
        menu_props.search_debounce = "submit"
        menu_props.on_search = { "script-message-to", mp.get_script_name(), "setup-source-delay", source_url }
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_delay_menu(source, status)
    if uosc_available then
        open_delay_menu_uosc(source, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_delay_menu_get(source, status)
        end)
    else
        show_message(i18n.t("无支持可用的 UI框架，不支持使用该功能"), 3)
    end
end

-- 总集合弹幕菜单
local total_menu_items_config = {
    { title = i18n.t("弹幕搜索"), action = "open_search_danmaku_menu" },
    { title = i18n.t("动漫弹幕搜索（152468）"), action = "open_anime_danmaku_menu", anime_only = true },
    { title = i18n.t("从源添加弹幕"), action = "open_add_source_menu" },
    { title = i18n.t("弹幕源延迟设置"), action = "open_source_delay_menu" },
    { title = i18n.t("弹幕样式"), action = "open_danmaku_style_menu" },
    { title = i18n.t("彩色弹幕"), action = "open-color-menu" },
    { title = i18n.t("弹幕内容"), action = "open_content_danmaku_menu" },
}

function open_add_total_menu_uosc()
    local items = {}
    append_association_items(items)

    for _, config in ipairs(total_menu_items_config) do
        if not config.anime_only or #get_api_server_list(options.anime_api_server) > 0 then
        table.insert(items, {
            title = config.title,
            hint = config.action == 'open-color-menu' and color_status() or nil,
            value = { "script-message-to", mp.get_script_name(), config.action },
            keep_open = false,
            selectable = true,
        })
        end
    end

    local menu_props = {
        type = "menu_total",
        title = i18n.t("弹幕设置"),
        search_style = "disabled",
        items = items,
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_add_total_menu_select()
    local item_titles, item_values = {}, {}
    for _, config in ipairs(total_menu_items_config) do
        if not config.anime_only or #get_api_server_list(options.anime_api_server) > 0 then
            item_titles[#item_titles + 1] = config.title
            item_values[#item_values + 1] = { "script-message-to", mp.get_script_name(), config.action }
        end
    end

    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = i18n.t('选择:'),
        items = item_titles,
        submit = function(id)
            local cmd = item_values[id]
            mp.add_timeout(0.1, function()
                mp.commandv(unpack(cmd))
            end)
        end,
    })
end

function open_add_total_menu()
    if uosc_available then
        open_add_total_menu_uosc()
    elseif input_loaded then
        open_add_total_menu_select()
    end
end

function refresh_danmaku_button()
    local switch_property = DANMAKU_SWITCH_ON or "user-data/uosc_danmaku/danmaku-switch-on"
    local is_on = mp.get_property_bool(switch_property, false)
    local has_comments = type(COMMENTS) == "table" and #COMMENTS > 0
    mp.commandv(
        "script-message-to",
        "uosc",
        "set-button",
        "danmaku_menu",
        utils.format_json({
            icon = "chat",
            -- Highlight means that danmaku is actually available and enabled,
            -- not merely that automatic loading/searching is switched on.
            active = is_on and has_comments,
            tooltip = i18n.t("弹幕菜单"),
            command = "script-message open_add_total_menu",
            secondary_command = "script-message toggle_danmaku",
        })
    )
end

function toggle_danmaku_switch(value)
    mp.commandv("script-message-to", "uosc", "set", "show_danmaku", value)
    mp.set_property_bool(DANMAKU_SWITCH_ON, value == "on")
    refresh_danmaku_button()
end

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku",
    utils.format_json({
        icon = "search",
        tooltip = i18n.t("弹幕搜索"),
        command = "script-message open_search_danmaku_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_source",
    utils.format_json({
        icon = "add_box",
        tooltip = i18n.t("从源添加弹幕"),
        command = "script-message open_add_source_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_styles",
    utils.format_json({
        icon = "palette",
        tooltip = i18n.t("弹幕样式"),
        command = "script-message open_danmaku_style_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_delay",
    utils.format_json({
        icon = "more_time",
        tooltip = i18n.t("弹幕源延迟设置"),
        command = "script-message open_source_delay_menu",
    })
)

refresh_danmaku_button()


mp.register_script_message('uosc-version', function()
    uosc_available = true
end)

local initial_state = mp.get_property_bool("user-data/uosc_danmaku/danmaku-switch-on", false) and "on" or "off"
mp.commandv("script-message-to", "uosc", "set", "show_danmaku", initial_state)
function set_danmaku_enabled(value)
    local desired = value == true or value == 'on'
    if ENABLED == desired and mp.get_property_bool(DANMAKU_SWITCH_ON, false) == desired then return end
    if type(cancel_danmaku_auto_load) == 'function' then cancel_danmaku_auto_load() end

    if desired then
        ENABLED = true
        if COMMENTS == nil then
            set_danmaku_visibility(true)
            local path = mp.get_property("path")
            init(path)
        else
            show_loaded()
            show_danmaku_func()
        end
    else
        show_message(i18n.t("关闭弹幕"), 2)
        ENABLED = false
        hide_danmaku_func()
    end

    toggle_danmaku_switch(desired and 'on' or 'off')
end

mp.register_script_message("set", function(prop, value)
    if prop ~= "show_danmaku" then return end
    set_danmaku_enabled(value)
end)

-- 右键弹幕按钮：双向切换弹幕开关
mp.register_script_message("toggle_danmaku", function()
    local is_on = mp.get_property_bool(DANMAKU_SWITCH_ON, false)
    local target = is_on and "off" or "on"
    mp.commandv("script-message-to", mp.get_script_name(), "set", "show_danmaku", target)
end)

-- 注册函数给 uosc 按钮使用
local function submit_anime_search(query, anime_only)
    perform_cancel_active_request()
    query = tostring(query or ""):gsub("^%s*(.-)%s*$", "%1")
    if query == "" then return end

    if anime_only and #get_api_server_list(options.anime_api_server) == 0 then
        show_message(i18n.t("动漫补充源未启用"), 3)
        return
    end
    local name, class
    if not anime_only then name, class = query:match("^(.-)%s*|%s*(.-)%s*$") end
    active_request_generation = active_request_generation + 1
    local pending_generation = active_request_generation
    request_cancelled = false
    active_request_type = "menu_anime"
    show_search_loading_menu(query, not anime_only and not (name and class), anime_only)
    mp.add_timeout(0.01, function()
        if pending_generation ~= active_request_generation then return end
        if name and class then
            query_extra(name, class)
        else
            get_animes(query, not anime_only, pending_generation, anime_only)
        end
    end)
end

mp.register_script_message("search-anime-event", function(query)
    submit_anime_search(query, false)
end)
mp.register_script_message("search-anime-proxy-event", function(query)
    submit_anime_search(query, true)
end)
mp.register_script_message("open_anime_danmaku_menu", function()
    open_input_menu(true)
end)
mp.register_script_message("search-episodes-event", function(animeTitle, bangumiId, api_server)
    perform_cancel_active_request()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    get_episodes(animeTitle, bangumiId, api_server)
end)

mp.register_script_message("load-danmaku", function(animeTitle, episodeTitle, episodeId, api_server, episodeNumber)
    if danmaku_remote_desktop_selection then danmaku_remote_desktop_selection() end
    local previous = {
        anime = DANMAKU.anime,
        episode = DANMAKU.episode,
        source = DANMAKU.source,
        extra = DANMAKU.extra,
        api_server = DANMAKU.api_server,
        sources = {},
    }
    local had_source = false
    for url, source in pairs(DANMAKU.sources) do
        if source.data and (source.association or source.from == 'api_server') then
            previous.sources[url] = source
            had_source = true
        end
    end
    ENABLED = true
    DANMAKU.anime = animeTitle
    DANMAKU.episode = episodeTitle
    set_episode_id(episodeId, true, api_server, episodeNumber, {
        on_complete = function(success)
            if success then return end
            DANMAKU.anime = had_source and previous.anime or nil
            DANMAKU.episode = had_source and previous.episode or nil
            DANMAKU.source = had_source and previous.source or nil
            DANMAKU.extra = had_source and previous.extra or nil
            DANMAKU.api_server = had_source and previous.api_server or nil
            if not had_source then
                show_message(i18n.t('所选弹幕源暂不可用，请换一条搜索结果'), 4)
                return
            end
            for url, source in pairs(previous.sources) do
                DANMAKU.sources[url] = source
                if source.association then add_source_to_history(url, source) end
            end
            local restored = load_danmaku(true, true)
            if restored and restored > 0 then
                show_loaded(true)
                if danmaku_remote_status then danmaku_remote_status('error', '所选弹幕源暂不可用，已保留之前的弹幕') end
                show_message(i18n.t('所选弹幕源暂不可用，已保留之前的弹幕'), 4)
            else
                show_message(i18n.t('所选弹幕源暂不可用，请换一条搜索结果'), 4)
            end
        end,
    })
end)

mp.register_script_message("add-source-event", function(query)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
    end
    ENABLED = true
    add_danmaku_source(query, true)
end)

mp.register_script_message("open_danmaku_style_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_style_menu()
end)

mp.register_script_message("open_content_danmaku_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_content_menu()
end)

mp.register_script_message("open-latest-menu-anime", function ()
    perform_cancel_active_request()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "open-menu", latest_menu_anime)
    elseif input_loaded then
        show_message("", 0)
        mp.add_timeout(0.1, function()
            open_menu_select(utils.parse_json(latest_menu_anime))
        end)
    end
end)

mp.register_script_message('cancel-active-request', function(menu_type)
    perform_cancel_active_request(menu_type)
end)

mp.register_script_message("setup-danmaku-style", function(query, text)
    local event = utils.parse_json(query)
    if event ~= nil then
        -- item点击 或 图标点击
        if event.type == "activate" then
            if not event.action then
                if ordered_keys[event.index] == "bold" then
                    options.bold = not options.bold
                    menu_items_config.bold.hint = options.bold and "true" or "false"
                    save_style_option("bold", options.bold)
                    if refresh_danmaku_renderer then refresh_danmaku_renderer() end
                end
                -- "updata" 模式会保留输入框文字
                open_style_menu(ordered_keys[event.index], "updata")
                return
            else
                -- msg.info("event.action：" .. event.action)
                options[event.action] = menu_items_config[event.action]["original"]
                menu_items_config[event.action]["hint"] = options[event.action]
                save_style_option(event.action, options[event.action])
                open_style_menu(event.action, "updata")
                if event.action == "fontsize" or event.action == "scrolltime" then
                    load_danmaku(true)
                elseif refresh_danmaku_renderer then
                    refresh_danmaku_renderer()
                end
            end
        end
    else
        -- 数值输入
        if text == nil or text == "" then
            return
        end
        local newText, _ = text:gsub("%s", "") -- 移除所有空白字符
        if tonumber(newText) ~= nil and menu_items_config[query]["scope"] ~= nil then
            local num = tonumber(newText)
            local min_num = menu_items_config[query]["scope"]["min"]
            local max_num = menu_items_config[query]["scope"]["max"]
            if num and min_num <= num and num <= max_num then
                if string.match(menu_items_config[query]["footnote"], "整数") then
                    -- 输入范围为整数时向下取整
                    num = tostring(math.floor(num))
                end
                options[query] = tostring(num)
                menu_items_config[query]["hint"] = options[query]
                save_style_option(query, options[query])
                -- "refresh" 模式会清除输入框文字
                open_style_menu(query, "refresh")
                if query == "fontsize" or query == "scrolltime" then
                    load_danmaku(true, true)
                elseif refresh_danmaku_renderer then
                    refresh_danmaku_renderer()
                end
                return
            end
        end
        open_style_menu(query, "error")
    end
end)

mp.register_script_message('setup-danmaku-source', function(json)
    local event = utils.parse_json(json)
    if event.type == 'activate' then

        if event.action == "delete" then
            DANMAKU.sources[event.value] = nil
            remove_source_from_history(event.value)
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end

        if event.action == "block" then
            DANMAKU.sources[event.value]["blocked"] = true
            add_source_to_history(event.value, DANMAKU.sources[event.value])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end

        if event.action == "unblock" then
            DANMAKU.sources[event.value]["blocked"] = false
            add_source_to_history(event.value, DANMAKU.sources[event.value])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end
    end
end)

mp.register_script_message("setup-source-delay", function(query, text)
    local event = utils.parse_json(query)
    if event ~= nil then
        -- item点击
        if event.type == "activate" then
            open_delay_menu(event.value)
        end
    else
        -- 数值输入
        if text == nil or text == "" then
            return
        end
        local delay = parse_delay_input(text)
        if delay ~= nil then
            mp.commandv("script-message", "danmaku-delay", tostring(delay), "0", tostring(query))
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_delay")
            mp.add_timeout(0.1, function()
                open_delay_menu(query, "refresh")
            end)
        else
            open_delay_menu(query, "error")
        end
    end
end)

mp.register_script_message('handle-danmaku-content-action', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' then return end

    if event.action then
        local d = COMMENTS[event.index]
        if not d or not d.source then return end

        if event.action == "block_source" then
            DANMAKU.sources[d.source]["blocked"] = true
            add_source_to_history(d.source, DANMAKU.sources[d.source])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
            load_danmaku(true)
        elseif event.action == "adjust_delay" then
            -- 打开以该弹幕时间为起点的延迟菜单（该延迟将作用于该时间点及之后的弹幕），仅针对该条弹幕的 source
            mp.commandv("script-message", "open_content_delay_menu", d.source, tostring(d.start_time))
        end
    else
        if event.value then
            if type(event.value) == "table" then
                mp.commandv(unpack(event.value))
            else
                mp.command(event.value)
            end
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
        end
    end
end)

mp.register_script_message("open_content_delay_menu", function(source, time)
    open_delay_from_time(source, tonumber(time))
end)

mp.register_script_message("setup-content-delay", function(...)
    local args = {...}
    if #args == 1 then
        return
    end
    if #args >= 2 then
        local time = tonumber(args[1])
        local source = args[2]
        local delay_str = args[3]
        local delay = parse_delay_input(delay_str)
        if delay ~= nil then
            mp.commandv("script-message", "danmaku-delay", tostring(delay), tostring(time), tostring(source))
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_delay_from_time")
        else
            open_delay_from_time(source, tonumber(time), "error")
        end
    end
end)
