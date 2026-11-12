local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
--[[
    Assrt / 迅雷 / 字幕猫下载，mpv-Yaozhi集成版。
    Based on dyphire/mpv-sub-assrt (MIT), https://github.com/dyphire/mpv-sub-assrt
    双源菜单参考用户提供的群友整合脚本；保留原作者署名。
    Ctrl+f / uosc 下载字幕；配置 script-opts/sub_assrt.conf。
    搜索只在提交后请求；Esc取消；只在当前媒体下载成功后加载主字幕。
]]

local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"
local script_source = debug.getinfo(1, 'S').source:gsub('^@', '')
local script_directory = script_source:match('^(.*)[/\\][^/\\]+$') or '.'
local function sibling(name)
    return dofile(utils.join_path(script_directory, '../script-modules/' .. name .. '.lua'))
end
local subtitle_output = sibling('subtitle-output')
local query_tools = sibling('subtitle-search-query')
local request_module = sibling('subtitle-request')
local subtitle_cat = sibling('subtitle-cat')
local search_session = sibling('subtitle-search-session')
local remote_module = sibling('subtitle-remote')
local input_loaded, input = pcall(require, "mp.input")
local uosc_available = false
local unpack = table.unpack or unpack

local o = {
    -- API token, 可以在 https://assrt.net 上注册账号后在个人界面获取
    api_token = "tNjXZUnOJWcHznHDyalNMYqqP6IdDdpQ",
    -- 是否使用 https
    use_https = true,
    -- 代理设置，例如 http://127.0.0.1:7890
    proxy = "",
    -- 默认字幕源：all（聚合）、ask（选择来源）、assrt、xunlei、subtitlecat（仅现成字幕）
    default_source = "all",
    -- 迅雷字幕接口（一般不需要改）
    xunlei_api = "https://api-shoulei-ssl.xunlei.com/oracle/subtitle",
}

options.read_options(o, "sub_assrt")
local requests = request_module.new(mp, utils, o)
local aggregate = search_session.new(mp, function() return request_module.new(mp, utils, o) end)
local aggregate_return, aggregate_escape_bound
local remote
local function cancel_desktop_requests()
    requests:cancel()
    aggregate:cancel()
    if aggregate_escape_bound then
        mp.remove_key_binding('aggregate-search-cancel')
        aggregate_escape_bound = nil
    end
end
local function cancel_requests()
    cancel_desktop_requests()
    if remote then remote:cancel('已转到电脑操作，请重新搜索') end
end

local script_name = mp.get_script_name and mp.get_script_name() or "sub-assrt"
local TEMP_DIR = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local cache = { assrt = {}, xunlei = {}, subtitlecat = {} }
local menu_serial, menu_path = 0, nil
local function deferred_input(delay, callback)
    local serial, path = requests.serial, mp.get_property('path')
    mp.add_timeout(delay, function()
        if serial == requests.serial and path == mp.get_property('path') then callback() end
    end)
end
local thin_space = string.char(0xE2, 0x80, 0x89)

-- 所有 uosc 菜单使用独立 type，避免与旧脚本 / 其他脚本冲突
local MENU = {
    source = "sub_assrt_source",
    all = "sub_all_search",
    assrt = "sub_assrt_search",
    assrt_details = "sub_assrt_details",
    xunlei = "sub_xunlei_search",
    subtitlecat = "sub_cat_search",
    cat_details = "sub_cat_details",
    download = "sub_assrt_download",
}

-- ===== 基础工具 =====

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_protocol(path)
    return type(path) == "string" and (path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil)
end

local function hex_to_char(x)
    return string.char(tonumber(x, 16))
end

local url_encode = query_tools.url_encode

local function file_exists(path)
    if path then
        local meta = utils.file_info(path)
        return meta and meta.is_file
    end
    return false
end

-- 只测试是否可写，不截断已有文件
local sanitize_name = query_tools.sanitize_name

local function fmt_size(n)
    n = tonumber(n)
    if not n or n <= 0 then return nil end
    if n >= 1024 * 1024 then
        return string.format("%.2f MB", n / 1024 / 1024)
    elseif n >= 1024 then
        return string.format("%.1f KB", n / 1024)
    end
    return string.format("%d B", n)
end

local function fmt_duration(ms)
    local total = tonumber(ms)
    if not total or total <= 0 then return nil end
    total = math.floor(total / 1000)
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

local function is_compressed_file(filename)
    if type(filename) ~= "string" then return false end
    local ext = filename:match("%.([%w]+)$")
    if not ext then return false end
    local ext_map = {
        zip = true,
        rar = true,
        ["7z"] = true,
        gz = true,
        tar = true,
        bz2 = true,
        xz = true,
        tgz = true,
        tbz2 = true,
    }
    return ext_map[ext:lower()] or false
end

local normalize_path
local platform = mp.get_property("platform")
if not platform then
    platform = package.config:sub(1, 1) == "\\" and "windows" or "linux"
end

local function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            path = mp.command_native({ "normalize-path", path })
        else
            local directory = mp.get_property("working-directory", "")
            path = utils.join_path(directory, path:gsub("^%.[\\/]", ""))
            if platform == "windows" then path = path:gsub("\\", "/") end
        end
        return path
    end

    normalize_path = false
    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "normalize-path" then
            normalize_path = true
            break
        end
    end
    return normalize(path)
end

local function append_sub(sub_file)
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'sub' and track.external and track['external-filename'] == sub_file then
            local ok, result, err = pcall(mp.commandv, 'sub-reload', track.id)
            if not ok or result == false or (result == nil and err) then return false end
            local selected, value, why = pcall(mp.set_property_native, 'sid', track.id)
            return selected and value ~= false and not (value == nil and why)
        end
    end
    local ok, result, err = pcall(mp.commandv, 'sub-add', sub_file, 'select')
    return ok and result ~= false and not (result == nil and err)
end

local function alphanumsort(a, b)
    -- alphanum sorting for humans in Lua
    -- http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua
    local function padnum(d)
        local dec, n = string.match(d, "(%.?)0*(.+)")
        return #dec > 0 and ("%.12f"):format(d) or ("%s%03d%s"):format(dec, #n, n)
    end
    return tostring(a):lower():gsub("%.?%d+", padnum) .. ("%3d"):format(#b)
         < tostring(b):lower():gsub("%.?%d+", padnum) .. ("%3d"):format(#a)
end

-- ===== 文件名 -> 搜索词 =====

local function initial_query(source)
    return query_tools.initial_query(mp.get_property('path'),
        mp.get_property('filename/no-ext') or '', mp.get_property('media-title') or '', source)
end

local function http_request(url, callback)
    return requests:http(url, callback)
end

local function assrt_endpoint(kind)
    local scheme = o.use_https and "https" or "http"
    return scheme .. "://api.assrt.net/v1/sub/" .. kind
end

local function xunlei_endpoint()
    return o.xunlei_api or "https://api-shoulei-ssl.xunlei.com/oracle/subtitle"
end

-- ===== uosc / input 菜单 =====

local function close_menu(menu_type)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", menu_type)
    end
end

local function close_all_menus()
    if not uosc_available then return end
    close_menu(MENU.source)
    close_menu(MENU.all)
    close_menu(MENU.assrt)
    close_menu(MENU.assrt_details)
    close_menu(MENU.xunlei)
    close_menu(MENU.subtitlecat)
    close_menu(MENU.cat_details)
    close_menu(MENU.download)
end

local function update_menu_uosc(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query, reset_search)
    menu_serial, menu_path = menu_serial + 1, mp.get_property('path')
    local items = {}
    if type(menu_item) == "string" then
        items[1] = {
            title = menu_item,
            value = "",
            italic = true,
            keep_open = true,
            selectable = false,
            align = "center",
        }
    elseif type(menu_item) == "table" then
        items = menu_item
    end

    if aggregate_return and type(menu_item) == 'string'
        and (menu_type == MENU.assrt_details or menu_type == MENU.cat_details or menu_type == MENU.download) then
        table.insert(items, 1, {title = '..', hint = i18n.t('返回聚合搜索结果'),
            value = {'script-message-to', script_name, 'aggregate-back-event'}})
    end

    local menu_props = {
        type = menu_type,
        title = menu_title,
        search_style = menu_cmd and "palette" or "on_demand",
        search_keep_open_on_empty = menu_cmd ~= nil,
        search_debounce = menu_cmd and "submit" or 0,
        on_search = menu_cmd,
        footnote = menu_footnote,
        search_suggestion = query,
        items = items,
        keep_open = true,
        back_on_escape = true,
        callback = {script_name, 'subtitle-menu-event', tostring(menu_serial)},
    }
    local json_props = utils.format_json(menu_props)
    local action = not reset_search and mp.get_property_native('user-data/uosc/menu/type') == menu_type and 'update-menu' or 'open-menu'
    mp.commandv("script-message-to", "uosc", action, json_props)
end

local function open_menu_select(menu_items)
    if not input_loaded then return end
    local serial, path = requests.serial, mp.get_property('path')
    local item_titles, item_values = {}, {}
    for i, v in ipairs(menu_items) do
        local title = tostring(v.title or "")
        local hint = v.hint and tostring(v.hint) or nil
        item_titles[i] = hint and (title .. " (" .. hint .. ")") or title
        item_values[i] = v.value
    end
    mp.commandv("script-message-to", "console", "disable")
    input.select({
        prompt = i18n.t("筛选:"),
        items = item_titles,
        submit = function(id)
            if serial ~= requests.serial or not path or path ~= mp.get_property('path') then return end
            local value = item_values[id]
            if value then
                mp.commandv(unpack(value))
            end
        end,
    })
end

local search_assrt, search_xunlei, search_cat, search_all, open_aggregate, show_aggregate

local function source_menu_info(source)
    if source == 'all' then return MENU.all, i18n.t('搜索字幕 · 全部来源'), 'all-search-event' end
    if source == 'xunlei' then return MENU.xunlei, i18n.t('迅雷字幕'), 'xunlei-search-event' end
    if source == 'subtitlecat' then return MENU.subtitlecat, i18n.t('字幕猫'), 'cat-search-event' end
    return MENU.assrt, i18n.t('Assrt 字幕'), 'assrt-search-event'
end

local function open_input_menu_get(source, query)
    if not input_loaded then return end
    local serial, path = requests.serial, mp.get_property('path')
    mp.commandv("script-message-to", "console", "disable")
    input.get({
        prompt = i18n.t('搜索') .. select(2, source_menu_info(source)) .. ':',
        default_text = query or "",
        cursor_position = query and #query + 1 or 1,
        submit = function(text)
            if serial ~= requests.serial or not path or path ~= mp.get_property('path') then return end
            input.terminate()
            if source == "all" then
                search_all(0, text)
            elseif source == "xunlei" then
                search_xunlei(0, text)
            elseif source == 'subtitlecat' then
                search_cat(0, text)
            else
                search_assrt(0, text)
            end
        end,
    })
end

local function open_input_menu_uosc(source, query)
    local menu_type, menu_title, event_name = source_menu_info(source)
    local cmd = { "script-message-to", script_name, event_name, "0" }
    update_menu_uosc(menu_type, menu_title, {}, i18n.t("输入关键字后按 Enter 搜索"), cmd, query, true)
end

local function open_input_menu(source, query)
    aggregate_return = nil
    cancel_requests()
    if uosc_available then
        open_input_menu_uosc(source, query)
    elseif input_loaded then
        open_input_menu_get(source, query)
    else
        mp.osd_message(i18n.t("没有输入模块，无法搜索"), 3)
    end
end

local function display_items(source, items, query, footnote)
    local menu_type, menu_title, event_name = source_menu_info(source)
    local cmd = { "script-message-to", script_name, event_name, "0" }

    if uosc_available then
        update_menu_uosc(menu_type, menu_title, items, footnote, cmd, query)
    elseif input_loaded then
        mp.osd_message("")
        deferred_input(0.1, function()
            open_menu_select(items)
        end)
    else
        mp.osd_message(i18n.t("没有输入模块，无法选择字幕"), 3)
    end
end

-- ===== 下载与载入 =====

local function show_download_status(message)
    message = i18n.text(message)
    if uosc_available then
        update_menu_uosc(MENU.download, i18n.t("字幕下载"), message, i18n.t("请稍候"), nil, nil)
    else
        mp.osd_message(message)
    end
end

local subtitle_exts = {srt=true, ass=true, ssa=true, vtt=true, sub=true, idx=true, sup=true, txt=true}
local function downloaded_page_error(path)
    local file = io.open(path, 'rb')
    if not file then return nil end -- The file/nonempty check reports this separately.
    local prefix = file:read(4096) or ''
    file:close()
    prefix = prefix:gsub('^\239\187\191', ''):gsub('^%s+', ''):lower()
    if prefix:match('^<!doctype%s+html') or prefix:match('^<html[%s>]')
        or prefix:match('^<head[%s>]') or prefix:match('^<body[%s>]') then
        return '服务返回了网页而非字幕，原文件已保留；请更换字幕源'
    end
end
local function save_subtitle(client, url, remote_name, source, ext_hint, notify, valid)
    valid = valid or function() return true end
    local path = mp.get_property('path')
    if not path then notify('请先打开视频', true, false, 'validation'); return end
    source = cache[source] and source or 'assrt'
    local fname = sanitize_name(remote_name or 'subtitle')
    local url_path = tostring(url or ''):gsub('[?#].*$', '')
    local ext = tostring(ext_hint or fname:match('%.([%w]+)$') or url_path:match('%.([%w]+)$') or ''):lower()
    if not subtitle_exts[ext] then notify('该文件不是可直接载入的字幕，请选择字幕文件', true, false, 'validation'); return end
    if not fname:lower():match('%.' .. ext .. '$') then fname = sanitize_name(fname, 110) .. '.' .. ext end
    local sub_path = utils.join_path(TEMP_DIR, fname)
    if not is_protocol(path) then
        local dir = utils.split_path(normalize(path))
        sub_path = utils.join_path(dir, (mp.get_property('filename/no-ext') or 'subtitle') .. '.' .. source .. '.' .. ext)
        if file_exists(sub_path) then
            local existing = io.open(sub_path, 'r+b')
            if existing then existing:close() else sub_path = utils.join_path(TEMP_DIR, fname) end
        end
    end
    -- Retain the existing short sibling staging / TEMP fallback / commit contract.
    local temporary = subtitle_output.reserve(sub_path, '.' .. ext, source)
    if not temporary then
        sub_path = utils.join_path(TEMP_DIR, fname)
        temporary = subtitle_output.reserve(sub_path, '.' .. ext, source)
    end
    if not temporary then notify('无法创建字幕下载文件', true, false, 'validation'); return end
    local function cleanup() subtitle_output.discard(temporary) end
    notify('正在下载字幕…', false)
    client:download(url, temporary, function(result, err, current)
        if result and current and current() and valid() then
            local info = utils.file_info(temporary)
            if not info or not info.is_file or info.size <= 0 then err = '下载的字幕为空或不存在'
            else
                err = downloaded_page_error(temporary)
            end
            if not err then
                local committed = subtitle_output.commit(temporary, sub_path)
                if not committed then err = '无法保存字幕，原文件已保留' end
            end
        end
        cleanup()
        if not current then notify(err or '字幕下载失败', true, false); return end
        if not current() or not valid() then return end
        if not result or err then notify(err or '字幕下载失败', true, false); return end
        local ok, load_error = append_sub(sub_path)
        if not ok then notify('字幕已保存，但未能载入', true, false); return end
        notify('字幕下载完成，已载入', true, true)
    end, cleanup)
end

local function download_file(url, remote_name, source, ext_hint)
    cancel_requests()
    save_subtitle(requests, url, remote_name, source, ext_hint, function(message, done, ok, kind)
        if kind=='validation' then mp.osd_message(i18n.text(message),3);return end
        show_download_status(not done and (message .. i18n.t(' 按 Esc 取消')) or message)
        if done and ok then
            local serial = requests.serial
            mp.add_timeout(1.5, function() if serial == requests.serial then close_all_menus() end end)
        end
    end)
end

-- ===== Assrt 源 =====

local function assrt_items(query, subs, pos)
    local items = {
        {
            title = "..",
            hint = i18n.t("返回搜索"),
            value = { "script-message-to", script_name, "open-assrt-input-event", "0", query },
        },
        {
            title = i18n.t("选择其他字幕源"),
            hint = query,
            value = { "script-message-to", script_name, "sub-source", query },
            italic = true,
        },
    }

    for _, sub in ipairs(subs) do
      if type(sub) == "table" then
        local title = sub.video_chinese_name
        if not title or title == "" then title = sub.native_name end
        if not title or title == "" then title = sub.videoname end
        if not title or title == "" then
            title = i18n.t("字幕 ") .. tostring(sub.id or sub.fileid or "?")
        end
        title = tostring(title)

        local hint = nil
        if type(sub.lang) == "table" and sub.lang.desc and sub.lang.desc ~= "" then
            hint = tostring(sub.lang.desc)
        elseif sub.m_lang and sub.m_lang ~= "" then
            hint = tostring(sub.m_lang):gsub("&nbsp;", " ")
        end

        local id = sub.id or sub.fileid
        if id then
            items[#items + 1] = {
                title = title,
                hint = hint,
                value = { "script-message-to", script_name, "fetch-details-event", tostring(id) },
            }
        end
    end

      end
    if #subs >= 15 then
        local next_pos = (tonumber(pos) or 0) + 15
        items[#items + 1] = {
            title = i18n.t("加载下一页"),
            hint = i18n.t("第 ") .. (math.floor(next_pos / 15) + 1) .. i18n.t(" 页"),
            value = { "script-message-to", script_name, "assrt-search-event", tostring(next_pos), query },
            italic = true,
            bold = true,
            align = "center",
        }
    end

    return items
end

function search_assrt(pos, query)
    aggregate_return = nil
    cancel_requests()
    query = trim(type(query) == "string" and query or (cache.assrt and cache.assrt.query) or "")

    if query == "" then
        if uosc_available then
            local cmd = { "script-message-to", script_name, "assrt-search-event", "0" }
            update_menu_uosc(MENU.assrt, i18n.t("Assrt 字幕"), i18n.t("请输入搜索关键字"), i18n.t("Enter 搜索"), cmd, query)
        else
            mp.osd_message(i18n.t("请输入搜索关键字"), 3)
        end
        return
    end

    if not o.api_token or o.api_token == "" then
        local message = i18n.t("请先在 script-opts 中配置 Assrt api_token")
        if uosc_available then
            update_menu_uosc(MENU.assrt, i18n.t("Assrt 字幕"), message, i18n.t("按 Esc 关闭"), nil, query)
        else
            mp.osd_message(message, 3)
        end
        return
    end

    local p = math.max(0, math.floor(tonumber(pos) or 0))
    local cache_hit = cache.assrt.query == query and cache.assrt.items ~= nil and (pos == "has_details" or cache.assrt.pos == p)
    if pos ~= "has_details" and p ~= 0 then
        cache_hit = false
    end

    if cache_hit then
        display_items("assrt", cache.assrt.items, query, i18n.t("Enter 搜索 · / 筛选"))
        return
    end

    local cmd = { "script-message-to", script_name, "assrt-search-event", "0" }
    local loading = i18n.t("正在搜索字幕...")
    if uosc_available then
        update_menu_uosc(MENU.assrt, i18n.t("Assrt 字幕"), loading, i18n.t("Enter 搜索 · / 筛选"), cmd, query)
    else
        mp.osd_message(loading)
    end

    local url = assrt_endpoint("search")
        .. "?token=" .. url_encode(o.api_token)
        .. "&q=" .. url_encode(query)
        .. "&cnt=15&pos=" .. tostring(p)

    http_request(url, function(res, request_error)
    if not res or tonumber(res.status) ~= 0 then
        local message = request_error or i18n.t("Assrt搜索失败，请检查Token、配额或稍后重试")
        if uosc_available then
            update_menu_uosc(MENU.assrt, i18n.t("Assrt 字幕"), message, i18n.t("Enter 重试"), cmd, query)
        else
            mp.osd_message(message, 3)
        end
        msg.warn("Assrt search failed")
        return
    end

    local subs = type(res.sub) == "table" and res.sub.subs
    if type(subs) ~= "table" then subs = {} end
    if #subs == 0 then
        local message = i18n.t("未找到字幕，建议更改关键字尝试重新搜索")
        if uosc_available then
            update_menu_uosc(MENU.assrt, i18n.t("Assrt 字幕"), message, i18n.t("Enter 重新搜索"), cmd, query)
        else
            mp.osd_message(message, 3)
        end
        msg.info("No subtitles found.")
        return
    end

    local items = assrt_items(query, subs, p)
    cache.assrt.query = query
    cache.assrt.pos = p
    cache.assrt.title = query
    cache.assrt.items = items
    display_items("assrt", items, query, i18n.t("Enter 搜索 · / 筛选"))
    end)
end

local function fetch_subtitle_details(sub_id)
    cancel_requests()
    local detail_query = aggregate_return and aggregate.state and aggregate.state.query or cache.assrt.query or ''
    if not o.api_token or o.api_token == "" then
        local message = i18n.t("请先在 script-opts 中配置 Assrt api_token")
        if uosc_available then
            update_menu_uosc(MENU.assrt_details, i18n.t("Assrt 字幕详情"), message, i18n.t("按 Esc 关闭"), nil, nil)
        else
            mp.osd_message(message, 3)
        end
        return
    end

    local message = i18n.t("正在加载字幕详细信息...")
    if uosc_available then
        update_menu_uosc(MENU.assrt_details, i18n.t("Assrt 字幕详情"), message, i18n.t("请稍候"), nil, nil)
    else
        mp.osd_message(message)
    end

    local url = assrt_endpoint("detail")
        .. "?token=" .. url_encode(o.api_token)
        .. "&id=" .. url_encode(tostring(sub_id or 0))

    http_request(url, function(res, request_error)
    if not res or tonumber(res.status) ~= 0 then
        local err_message = request_error or i18n.t("Assrt详情请求失败，请检查Token或稍后重试")
        if uosc_available then
            update_menu_uosc(MENU.assrt_details, i18n.t("Assrt 字幕详情"), err_message, i18n.t("按 Esc 返回"), nil, nil)
        else
            mp.osd_message(err_message, 3)
        end
        msg.warn("Assrt details failed")
        return
    end

    local subs = type(res.sub) == "table" and type(res.sub.subs) == "table" and res.sub.subs[1]
    if type(subs) ~= 'table' then
        local err_message = i18n.t("字幕详情为空")
        if uosc_available then
            update_menu_uosc(MENU.assrt_details, i18n.t("Assrt 字幕详情"), err_message, i18n.t("按 Esc 返回"), nil, nil)
        else
            mp.osd_message(err_message, 3)
        end
        return
    end

    local items = {
        {
            title = "..",
            hint = i18n.t("返回搜索结果"),
            value = { "script-message-to", script_name, aggregate_return and "aggregate-back-event" or "assrt-back-event" },
        },
        {
            title = i18n.t("选择其他字幕源"),
            hint = detail_query,
            value = { "script-message-to", script_name, "sub-source", detail_query },
            italic = true,
        },
    }

    local file_count = 0
    local filelist = subs.filelist
    if type(filelist) ~= "table" then filelist = {} end
    for _, f in ipairs(filelist) do
        local fname = type(f) == "table" and f.f or nil
        if type(fname) == 'string' and fname ~= "" and type(f.url) == "string" and not is_compressed_file(fname) then
            local size_hint = fmt_size(f.s)
            if not size_hint and f.s ~= nil then
                size_hint = tostring(f.s)
            end
            items[#items + 1] = {
                title = fname,
                hint = size_hint,
                value = { "script-message-to", script_name, "download-assrt-event", f.url, fname },
            }
            file_count = file_count + 1
        end
    end

    -- 某些字幕没有 filelist，只提供一个打包/单文件下载地址
    if file_count == 0 and subs.url and not is_compressed_file(subs.filename or "") then
        local fallback_name = subs.filename or "subtitle"
        items[#items + 1] = {
            title = fallback_name,
            hint = fmt_size(subs.size),
            value = { "script-message-to", script_name, "download-assrt-event", subs.url, fallback_name },
        }
        file_count = 1
    end

    if file_count == 0 then
        local err_message = i18n.t("该字幕没有可用的文件（可能只有压缩包）")
        if uosc_available then
            update_menu_uosc(MENU.assrt_details, i18n.t("Assrt 字幕详情"), err_message, i18n.t("按 Esc 返回"), nil, nil)
        else
            mp.osd_message(err_message, 3)
        end
        return
    end

    local back = table.remove(items, 1)
    local switch = table.remove(items, 1)
    table.sort(items, function(a, b)
        return alphanumsort(a.title, b.title)
    end)
    table.insert(items, 1, switch)
    table.insert(items, 1, back)

    if uosc_available then
        update_menu_uosc(MENU.assrt_details, i18n.t("Assrt 字幕详情"), items, i18n.t("选择字幕文件下载"), nil, nil)
    elseif input_loaded then
        mp.osd_message("")
        deferred_input(0.1, function()
            open_menu_select(items)
        end)
    end
    end)
end

-- ===== 迅雷源 =====

local function xunlei_items(query, data)
    local items = {
        {
            title = "..",
            hint = i18n.t("返回搜索"),
            value = { "script-message-to", script_name, "open-xunlei-input-event", "0", query },
        },
        {
            title = i18n.t("选择其他字幕源"),
            hint = query,
            value = { "script-message-to", script_name, "sub-source", query },
            italic = true,
        },
    }

    for _, sub in ipairs(data) do
        if type(sub) == "table" and type(sub.url) == "string" and sub.url ~= "" then
            local ext = sub.ext or sub.url:match("%.([%w]+)[^/]*$") or "srt"
            ext = tostring(ext):lower()
            local title = sub.name
            if not title or title == "" then
                title = i18n.t("字幕 ") .. tostring(#items - 1)
            end
            title = tostring(title)

            local hint_parts = {}
            local lang = type(sub.languages) == "table" and sub.languages[1]
            if lang and lang ~= "" and lang ~= "未知语言" then
                hint_parts[#hint_parts + 1] = tostring(lang)
            end
            if ext ~= "" then
                hint_parts[#hint_parts + 1] = ext:upper()
            end
            local duration = fmt_duration(sub.duration)
            if duration then
                hint_parts[#hint_parts + 1] = duration
            end

            items[#items + 1] = {
                title = title,
                hint = #hint_parts > 0 and table.concat(hint_parts, " · ") or nil,
                value = { "script-message-to", script_name, "download-xunlei-event", sub.url, title, ext },
            }
        end
    end

    return items
end

function search_xunlei(pos, query)
    aggregate_return = nil
    cancel_requests()
    query = trim(type(query) == "string" and query or (cache.xunlei and cache.xunlei.query) or "")

    if query == "" then
        if uosc_available then
            local cmd = { "script-message-to", script_name, "xunlei-search-event", "0" }
            update_menu_uosc(MENU.xunlei, i18n.t("迅雷字幕"), i18n.t("请输入搜索关键字"), i18n.t("Enter 搜索"), cmd, query)
        else
            mp.osd_message(i18n.t("请输入搜索关键字"), 3)
        end
        return
    end

    if cache.xunlei.query == query and cache.xunlei.items ~= nil then
        display_items("xunlei", cache.xunlei.items, query, i18n.t("Enter 搜索 · / 筛选"))
        return
    end

    local cmd = { "script-message-to", script_name, "xunlei-search-event", "0" }
    local loading = i18n.t("正在搜索迅雷字幕...")
    if uosc_available then
        update_menu_uosc(MENU.xunlei, i18n.t("迅雷字幕"), loading, i18n.t("Enter 搜索 · / 筛选"), cmd, query)
    else
        mp.osd_message(loading)
    end

    local url = xunlei_endpoint() .. "?gcid=&cid=&name=" .. url_encode(query)
    http_request(url, function(res, request_error)

    if not res or tonumber(res.code) ~= 0 then
        local message = request_error or i18n.t("迅雷字幕请求失败，请稍后重试")
        if uosc_available then
            update_menu_uosc(MENU.xunlei, i18n.t("迅雷字幕"), message, i18n.t("Enter 重试"), cmd, query)
        else
            mp.osd_message(message, 3)
        end
        msg.warn("Xunlei search failed")
        return
    end

    if type(res.data) ~= "table" or #res.data == 0 then
        local message = i18n.t("未找到字幕")
        if uosc_available then
            update_menu_uosc(MENU.xunlei, i18n.t("迅雷字幕"), message, i18n.t("Enter 重新搜索"), cmd, query)
        else
            mp.osd_message(message, 3)
        end
        msg.info("Xunlei: no subtitles found.")
        return
    end

    local items = xunlei_items(query, res.data)
    if #items <= 2 then
        local message = i18n.t("没有可下载的字幕文件")
        if uosc_available then
            update_menu_uosc(MENU.xunlei, i18n.t("迅雷字幕"), message, i18n.t("Enter 重新搜索"), cmd, query)
        else
            mp.osd_message(message, 3)
        end
        return
    end

    cache.xunlei.query = query
    cache.xunlei.title = query
    cache.xunlei.items = items
    display_items("xunlei", items, query, i18n.t("Enter 搜索 · / 筛选"))
    end)
end

-- ===== 字幕猫：只下载详情页显式列出的已有文件，不触发翻译 =====

search_cat = function(pos, query)
    aggregate_return = nil
    cancel_requests()
    query = trim(type(query) == 'string' and query or cache.subtitlecat.query or '')
    local page = math.max(0, math.floor(tonumber(pos) or 0))
    if query == '' then
        display_items('subtitlecat', i18n.t('请输入搜索关键字'), query, i18n.t('Enter 搜索 · 只下载已有字幕'))
        return
    end
    local c = cache.subtitlecat
    if c.query == query and c.items and (pos == 'has_details' or c.pos == page) then
        display_items('subtitlecat', c.items, query, i18n.t('仅已有字幕 · 翻译质量因文件而异'))
        return
    end
    local url, error_message = subtitle_cat.search_url(query, page)
    if not url then display_items('subtitlecat', error_message or i18n.t('不支持该搜索页'), query); return end
    display_items('subtitlecat', i18n.t('正在搜索字幕猫…'), query, i18n.t('按 Esc 取消'))
    requests:text(url, function(html, request_error)
        local found, next_url, parse_error
        if html then found, next_url, parse_error = subtitle_cat.parse_search(html, url, page) end
        local items = {
            {title='..', hint=i18n.t('重新输入关键字'), value={'script-message-to', script_name, 'open-cat-input-event', '0', query}},
            {title=i18n.t('选择其他字幕源'), hint=query, value={'script-message-to', script_name, 'sub-source', query}},
        }
        for _, entry in ipairs(found or {}) do
            items[#items+1] = {title=entry.title, hint=entry.hint,
                value={'script-message-to', script_name, 'cat-details-event', entry.url}}
        end
        if #items == 2 then
            items[#items+1] = {title=request_error or parse_error or i18n.t('未找到字幕，可改用原文片名或其他字幕源'), selectable=false, muted=true}
        else
            c.query, c.title, c.items, c.pos = query, query, items, page
        end
        -- The public page's bulk "Load More" is deliberately not followed.
        display_items('subtitlecat', items, query, i18n.t('仅已有字幕 · 不自动翻译 · 可切换字幕源'))
    end)
end

local function fetch_cat_details(url)
    cancel_requests()
    local detail_query = aggregate_return and aggregate.state and aggregate.state.query or cache.subtitlecat.query or ''
    if not subtitle_cat.is_detail_url(url) then mp.osd_message(i18n.t('字幕猫详情地址无效'), 3); return end
    if not mp.get_property('path') then return end
    if uosc_available then update_menu_uosc(MENU.cat_details, i18n.t('字幕猫 · 可下载语言'), i18n.t('正在读取已有字幕…'), i18n.t('按 Esc 取消'))
    else mp.osd_message(i18n.t('正在读取已有字幕…')) end
    requests:text(url, function(html, request_error)
        local files, parse_error
        if html then files, parse_error = subtitle_cat.parse_details(html, url) end
        local items = {
            {title='..', hint=i18n.t('返回搜索结果'), value={'script-message-to', script_name, aggregate_return and 'aggregate-back-event' or 'cat-back-event'}},
            {title=i18n.t('选择其他字幕源'), hint=detail_query,
                value={'script-message-to', script_name, 'sub-source', detail_query}},
        }
        for _, file in ipairs(files or {}) do
            items[#items+1] = {title=file.title or file.language or file.lang or file.filename,
                hint=file.original and i18n.t('原上传字幕 · SRT') or i18n.t('已有译文 · SRT'),
                value={'script-message-to', script_name, 'download-cat-event', file.url, file.filename}}
        end
        if #items == 2 then
            items[#items+1] = {title=request_error or parse_error or i18n.t('没有可直接下载的现成字幕；不会自动翻译'), selectable=false, muted=true}
        end
        if uosc_available then update_menu_uosc(MENU.cat_details, i18n.t('字幕猫 · 可下载语言'), items, i18n.t('只下载已有文件 · 译文可能为机翻'))
        elseif input_loaded then deferred_input(0.1, function() open_menu_select(items) end) end
    end)
end

-- ===== 聚合搜索：每源一个有界请求，只追加完成源，不移动已显示的条目 =====
local source_labels = {assrt = 'Assrt', xunlei = i18n.t('迅雷'), subtitlecat = i18n.t('字幕猫')}

local function aggregate_rows(state)
    -- Keep a stable display sequence for both results and source notices.
    -- New completions append; successful sources do not add redundant counters.
    state.view_rows = state.view_rows or {}
    state.shown_items = state.shown_items or 0
    state.shown_sources = state.shown_sources or {}
    for i = state.shown_items + 1, #state.items do
        state.view_rows[#state.view_rows + 1] = {item = state.items[i], index = i}
    end
    state.shown_items = #state.items
    local pending = {}
    for _, source in ipairs(state.sources) do
        if source.status == 'pending' then
            pending[#pending + 1] = source_labels[source.id]
        elseif not state.shown_sources[source.id] then
            state.shown_sources[source.id] = true
            if source.status == 'error' or source.status == 'skipped' or #source.items == 0 then
                local reason = source.status == 'ok' and i18n.t('未找到字幕') or source.error or i18n.t('暂不可用')
                state.view_rows[#state.view_rows + 1] = {title = source_labels[source.id] .. '：' .. reason}
            end
        end
    end
    local items = {
        {title = aggregate.active and i18n.t('正在搜索…') or i18n.t('重新搜索'),
            hint = #pending > 0 and ((aggregate.active and '' or i18n.t('未完成：')) .. table.concat(pending, '、')) or i18n.t('修改关键词后按 Enter'),
            value = {'script-message-to', script_name, 'all-input-event', state.query}},
        {title = i18n.t('选择字幕源'), hint = i18n.t('也可以单独搜索或查看更多结果'),
            value = {'script-message-to', script_name, 'sub-source', state.query}},
    }
    for _, row in ipairs(state.view_rows) do
        if row.item then
            items[#items + 1] = {title = row.item.title, hint = row.item.hint,
                value = {'script-message-to', script_name, 'aggregate-item-event', tostring(aggregate.serial), tostring(row.index)}}
        else
            items[#items + 1] = {title = row.title, selectable = false, muted = true}
        end
    end
    return items
end

local function aggregate_status(state)
    local parts = {}
    for _, source in ipairs(state.sources) do
        local status
        if source.status == 'pending' then status = aggregate.active and i18n.t('搜索中') or i18n.t('未完成，可重搜')
        elseif source.status == 'error' or source.status == 'skipped' then status = source.error or i18n.t('暂不可用')
        else status = #source.items > 0 and i18n.t('已完成') or i18n.t('无结果') end
        parts[#parts + 1] = source_labels[source.id] .. '：' .. status
    end
    return table.concat(parts, ' · ')
end

local function render_aggregate(state)
    if state.path ~= mp.get_property('path') then return end
    local status = aggregate_status(state)
    if not uosc_available and input_loaded then
        if aggregate.active and not aggregate_escape_bound and mp.add_forced_key_binding then
            local serial = aggregate.serial
            mp.add_forced_key_binding('ESC', 'aggregate-search-cancel', function()
                if aggregate.serial ~= serial or not aggregate.active or not aggregate_escape_bound then return end
                cancel_requests()
                mp.osd_message(i18n.t('已取消字幕搜索'), 2)
            end)
            aggregate_escape_bound = true
        elseif not aggregate.active and aggregate_escape_bound then
            mp.remove_key_binding('aggregate-search-cancel')
            aggregate_escape_bound = nil
        end
    end
    if uosc_available then
        update_menu_uosc(MENU.all, i18n.t('搜索字幕 · 全部来源'), aggregate_rows(state), i18n.t('Enter 搜索 · 选择结果查看或下载 · 字幕猫仅已有字幕'),
            {'script-message-to', script_name, 'all-search-event', '0'}, state.query)
    elseif aggregate.active then
        mp.osd_message(status)
    elseif input_loaded then
        display_items('all', aggregate_rows(state), state.query, status)
    end
end

local function bounded_records(value)
    local out = {}
    if type(value) == 'table' then
        for i = 1, math.min(#value, 100) do out[i] = value[i] end
    end
    return out
end

function show_aggregate()
    cancel_requests()
    aggregate_return = nil
    local state = aggregate.state
    if state and state.path == mp.get_property('path') then render_aggregate(state) end
end

function open_aggregate(query)
    if not mp.get_property('path') then mp.osd_message(i18n.t('请先打开视频'), 3); return end
    local q = trim(type(query) == 'string' and query or initial_query('all'))
    local state = aggregate.state
    if state and state.path == mp.get_property('path') and state.query == q and #state.items > 0 then
        show_aggregate()
    else
        open_input_menu('all', q)
    end
end

local function collect_aggregate_items(source, built)
    local items, seen = {}, {}
    -- The first two rows are the single-source navigation controls. Keep the
    -- original item actions; details/download remain lazy and source-specific.
    for i = 3, #built do
        local item = built[i]
        if type(item.value) == 'table' and item.value[3] ~= 'assrt-search-event' then
            local key = table.concat(item.value, '\31')
            if not seen[key] and #items < 100 then
                seen[key] = true
                items[#items + 1] = {title = item.title,
                    hint = source_labels[source] .. (item.hint and (' · ' .. item.hint) or ''), value = item.value}
            end
        end
    end
    return items
end

function search_all(_, query)
    cancel_requests()
    aggregate_return = nil
    query = trim(query)
    if not mp.get_property('path') then return end
    if query == '' then open_input_menu('all', ''); return end
    aggregate:start(query, {
        {id = 'assrt', run = function(client, done)
            if not o.api_token or o.api_token == '' then done({}, i18n.t('未配置 Token'), true); return end
            local url = assrt_endpoint('search') .. '?token=' .. url_encode(o.api_token)
                .. '&q=' .. url_encode(query) .. '&cnt=15&pos=0'
            client:http(url, function(res, err)
                if not res or tonumber(res.status) ~= 0 then done(nil, err or i18n.t('请求失败，请检查 Token 或配额')); return end
                local subs = type(res.sub) == 'table' and res.sub.subs
                done(collect_aggregate_items('assrt', assrt_items(query, bounded_records(subs), 0)))
            end)
        end},
        {id = 'xunlei', run = function(client, done)
            client:http(xunlei_endpoint() .. '?gcid=&cid=&name=' .. url_encode(query), function(res, err)
                if not res or tonumber(res.code) ~= 0 then done(nil, err or i18n.t('请求失败')); return end
                done(collect_aggregate_items('xunlei', xunlei_items(query, bounded_records(res.data))))
            end)
        end},
        {id = 'subtitlecat', run = function(client, done)
            local url, why = subtitle_cat.search_url(query, 0)
            if not url then done(nil, why or i18n.t('搜索地址无效')); return end
            client:text(url, function(html, err)
                if not html then done(nil, err); return end
                local found, _, parse_error = subtitle_cat.parse_search(html, url, 0)
                if not found then done(nil, parse_error or i18n.t('网页格式异常')); return end
                local built = {{}, {}}
                for _, entry in ipairs(found) do
                    built[#built + 1] = {title = entry.title, hint = entry.hint,
                        value = {'script-message-to', script_name, 'cat-details-event', entry.url}}
                end
                done(collect_aggregate_items('subtitlecat', built))
            end)
        end},
    }, render_aggregate)
end

mp.register_script_message('all-input-event', function(query) open_input_menu('all', query) end)


-- ===== 字幕源选择与入口 =====

local function open_source(source, query)
    if source == "all" then open_aggregate(query); return end
    source = cache[source] and source or 'assrt'

    if not mp.get_property("path") then
        msg.error("No file loaded.")
        return
    end

    local q = query
    if q == nil or q == "" then
        q = initial_query(source)
    end
    q = trim(q or "")

    local c = cache[source]
    if q ~= "" and c.title == q and c.items and #c.items > 0 then
        if source == "xunlei" then
            search_xunlei("has_details", q)
        elseif source == 'subtitlecat' then
            search_cat('has_details', q)
        else
            search_assrt("has_details", q)
        end
        return
    end

    open_input_menu(source, q)
end

local function show_source_menu(query)
    aggregate_return = nil
    cancel_requests()
    query = type(query) == 'string' and query or nil
    if not mp.get_property("path") then
        msg.error("No file loaded.")
        return
    end

    if uosc_available then
        local items = {
            {
                title = i18n.t("全部来源 · 聚合搜索"),
                hint = i18n.t("一次输入，同时搜索三个来源"),
                value = {"script-message-to", script_name, "source-event", "all", query or ''},
            },
            {
                title = i18n.t("Assrt 字幕库"),
                hint = (o.api_token and o.api_token ~= "") and i18n.t("在线字幕库 · assrt.net") or i18n.t("需要配置 api_token"),
                value = { "script-message-to", script_name, "source-event", "assrt", query or '' },
            },
            {
                title = i18n.t("迅雷字幕"),
                hint = i18n.t("网友上传，无需配置"),
                value = { "script-message-to", script_name, "source-event", "xunlei", query or '' },
            },
            {
                title = i18n.t('字幕猫（SubtitleCat）'),
                hint = i18n.t('无需 Key · 仅下载已有字幕'),
                value = {'script-message-to', script_name, 'source-event', 'subtitlecat', query or ''},
            },
        }
        update_menu_uosc(MENU.source, i18n.t("选择字幕源"), items, i18n.t("选择后输入关键字搜索"), nil, nil)
    elseif input_loaded then
        mp.commandv("script-message-to", "console", "disable")
        input.select({
            prompt = i18n.t("选择字幕源:"),
            items = { i18n.t("Assrt 字幕库"), i18n.t("迅雷字幕"), i18n.t("字幕猫（仅已有字幕）"), i18n.t("全部来源 · 聚合搜索") },
            submit = function(id)
                local source = id == 4 and 'all' or id == 3 and 'subtitlecat' or id == 2 and 'xunlei' or 'assrt'
                -- 等 input.select 完全关闭后再打开输入框，避免嵌套 input
                deferred_input(0.05, function()
                    open_source(source, query)
                end)
            end,
        })
    else
        mp.osd_message(i18n.t("没有输入模块，无法搜索"), 3)
    end
end

local function sub_assrt()
    if not mp.get_property("path") then
        msg.error("No file loaded.")
        return
    end

    local default = tostring(o.default_source or "ask"):lower()
    if default == "all" then
        open_aggregate()
    elseif default == "assrt" or default == "xunlei" or default == 'subtitlecat' then
        open_source(default)
    else
        show_source_menu()
    end
end

-- ===== 消息注册 =====

mp.register_script_message("uosc-version", function()
    if aggregate_escape_bound then
        mp.remove_key_binding('aggregate-search-cancel')
        aggregate_escape_bound = nil
    end
    uosc_available = true
    mp.commandv("script-message-to", "uosc", "overwrite-binding", "download-subtitles",
        "script-message-to " .. script_name .. " sub-assrt")
end)

mp.register_script_message("sub-assrt", sub_assrt)
mp.register_script_message("sub-search-all", function() open_aggregate() end)
mp.register_script_message("all-search-event", search_all)
mp.register_script_message("aggregate-back-event", function() show_aggregate() end)
mp.register_script_message("aggregate-item-event", function(serial, index)
    local state = aggregate.state
    if not state or tonumber(serial) ~= aggregate.serial or state.path ~= mp.get_property('path') then return end
    local item = state.items[tonumber(index)]
    if not item or type(item.value) ~= 'table' then return end
    aggregate_return = true
    cancel_requests()
    mp.commandv(unpack(item.value))
end)
mp.register_script_message("sub-xunlei", function()
    open_source("xunlei")
end)
mp.register_script_message("sub-source", show_source_menu)

mp.register_script_message("source-event", function(source, query)
    open_source(source, query)
end)

mp.register_script_message("switch-source-event", function(source, query)
    open_source(source, query)
end)

mp.register_script_message("open-assrt-input-event", function(_, query)
    open_input_menu("assrt", query)
end)

mp.register_script_message("open-xunlei-input-event", function(_, query)
    open_input_menu("xunlei", query)
end)

mp.register_script_message("assrt-search-event", function(pos, query)
    search_assrt(pos, query)
end)

mp.register_script_message("xunlei-search-event", function(pos, query)
    search_xunlei(pos, query)
end)

mp.register_script_message("fetch-details-event", function(sub_id)
    fetch_subtitle_details(sub_id)
end)

mp.register_script_message("assrt-back-event", function()
    close_menu(MENU.assrt_details)
    search_assrt("has_details", cache.assrt.query)
end)

mp.register_script_message("download-assrt-event", function(url, filename)
    download_file(url, filename, "assrt")
end)

mp.register_script_message("download-xunlei-event", function(url, filename, ext)
    download_file(url, filename, "xunlei", ext)
end)

mp.register_script_message('sub-subtitlecat', function() open_source('subtitlecat') end)
mp.register_script_message('open-cat-input-event', function(_, query) open_input_menu('subtitlecat', query) end)
mp.register_script_message('cat-search-event', search_cat)
mp.register_script_message('cat-details-event', fetch_cat_details)
mp.register_script_message('cat-back-event', function() search_cat('has_details', cache.subtitlecat.query) end)
mp.register_script_message('download-cat-event', function(url, filename)
    cancel_requests()
    if not subtitle_cat.is_download_url(url) then mp.osd_message(i18n.t('字幕猫下载地址无效'), 3); return end
    download_file(url, filename, 'subtitlecat', 'srt')
end)

mp.register_script_message('open-search-menu', function(_, query) open_input_menu('assrt', query) end)
mp.register_script_message('search-subtitles-event', function(pos, query) search_assrt(pos, query) end)
mp.register_script_message('download-file-event', function(url, filename) download_file(url, filename, 'assrt') end)
mp.register_script_message('subtitle-menu-event', function(serial, json)
    if tonumber(serial) ~= menu_serial or menu_path ~= mp.get_property('path') then return end
    local event = utils.parse_json(json)
    if type(event) ~= 'table' then return end
    if event.type == 'back' and aggregate_return then
        show_aggregate()
    elseif event.type == 'back' or event.type == 'close' then
        menu_serial, menu_path = menu_serial + 1, nil
        cancel_requests()
        close_all_menus()
    elseif event.type == 'activate' and type(event.value) == 'table'
        and event.value[1] == 'script-message-to' and event.value[2] == script_name then
        mp.commandv(unpack(event.value))
    end
end)

-- The phone owns independent request clients. The same parsers and atomic
-- download/load implementation are shared without opening a desktop menu.
remote = remote_module.new({
    mp = mp,
    request_factory = function() return request_module.new(mp, utils, o) end,
    session_factory = function(factory) return search_session.new(mp, factory) end,
    active = function() return mp.get_property_native('user-data/cinema/active') == true end,
    keyword = function() return initial_query('all') end,
    assrt_enabled = function() return type(o.api_token)=='string' and o.api_token~='' end,
    assrt_url = function(kind, query, position)
        local url = assrt_endpoint(kind) .. '?token=' .. url_encode(o.api_token)
        if kind=='detail' then return url .. '&id=' .. url_encode(query) end
        return url .. '&q=' .. url_encode(query) .. '&cnt=15&pos=' .. tostring(position or 0)
    end,
    xunlei_url = function(query) return xunlei_endpoint() .. '?gcid=&cid=&name=' .. url_encode(query) end,
    assrt_items = assrt_items,
    xunlei_items = xunlei_items,
    cat = subtitle_cat,
    fmt_size = fmt_size,
    sort = alphanumsort,
    file_allowed = function(name, url)
        if is_compressed_file(name) then return false end
        local ext = tostring(name or ''):match('%.([%w]+)$')
            or tostring(url or ''):gsub('[?#].*$', ''):match('%.([%w]+)$')
        return ext and subtitle_exts[ext:lower()] == true
    end,
    download = save_subtitle,
    takeover = function()
        cancel_desktop_requests()
        menu_serial, menu_path = menu_serial + 1, nil
        close_all_menus()
        if input_loaded and input.terminate then pcall(input.terminate) end
    end,
})
local function publish_remote()
    mp.set_property_native('user-data/sub-assrt/remote', {
        available=true,keyword=initial_query('all'),source='all',
    })
end
mp.register_script_message('cinema-subtitles', function(json)
    if type(json)~='string' or #json>8192 then return end
    local payload=utils.parse_json(json)
    if type(payload)~='table' then return end
    local ok,data,err=pcall(remote.request,remote,payload)
    if not ok then remote:cancel();data,err=nil,'字幕组件暂不可用，请稍后重试' end
    local reply=payload.reply
    if type(reply)=='string' and #reply<=60 and reply:match('^[%w_-]+$')
        and type(payload.id)=='string' and #payload.id<=80 and payload.id:match('^[%w_-]+$') then
        mp.commandv('script-message-to',reply,'cinema-subtitles-result',utils.format_json({
            id=payload.id,ok=data~=nil,data=data,error=data==nil and (err or '字幕操作失败') or nil,
        }))
    end
end)
mp.add_periodic_timer(1,function() remote:expire() end)
publish_remote()

local function media_changed()
    remote:media_changed()
    cancel_requests()
    menu_serial, menu_path = menu_serial + 1, nil
    close_all_menus()
    if input_loaded and input.terminate then pcall(input.terminate) end
    cache = {assrt = {}, xunlei = {}, subtitlecat = {}}
    aggregate.state, aggregate_return = nil, nil
    publish_remote()
end
mp.register_event('start-file', media_changed)
mp.register_event('end-file', media_changed)
mp.register_event('file-loaded',publish_remote)
mp.register_event('shutdown', function()
    cancel_requests()
    mp.set_property_native('user-data/sub-assrt/remote',{available=false})
end)
mp.observe_property('user-data/uosc/menu/type', 'native', function()
    if not uosc_available then return end
    -- Menu replacement briefly publishes nil; inspect after that transition.
    local serial, aggregate_serial = requests.serial, aggregate.serial
    mp.add_timeout(0.05, function()
        if remote and remote:active() then return end
        if serial ~= requests.serial or aggregate_serial ~= aggregate.serial then return end
        local current = mp.get_property_native('user-data/uosc/menu/type')
        for _, kind in pairs(MENU) do if current == kind then return end end
        menu_serial, menu_path = menu_serial + 1, nil
        cancel_requests()
    end)
end)
mp.commandv('script-message-to', 'uosc', 'get-version', script_name)
