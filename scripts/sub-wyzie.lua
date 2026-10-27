-- sub-wyzie.lua - Wyzie Subs 在线字幕搜索
--
-- Wyzie 的 /search 只接受 TMDb / IMDb ID，不接受标题或文件名查询，所以完整
-- 流程是：文件名 → 标题清洗 → TMDb 搜索取 ID → Wyzie 搜索 → 选择 → 下载 → 挂载。
--
-- 标题清洗、季集识别和 TMDb 解析与 skip-segments.lua 同源，但为保持两个脚本
-- 互不依赖，这里是各自独立的副本；改动其中一处时不需要同步另一处。
--
-- 需要 API key（免费申请：https://store.wyzie.io/redeem），未配置时只提示
-- 获取地址，不发请求。

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

package.path = mp.command_native({ 'expand-path', '~~/script-modules/?.lua;' }) .. package.path
local http = require 'http-async'

local o = {
    -- Wyzie API key，留空则禁用搜索
    api_key = '',
    -- 官方文档给的是 sub.wyzie.io；部分客户端仍在使用 .ru，二者参数一致
    api_url = 'https://sub.wyzie.io',
    -- ISO 639-1 语言代码，逗号分隔
    language = 'zh,en',
    -- srt / ass
    format = 'srt,ass',
    -- all 表示 key 可用的全部源；免费 key 实际只有 charlie 和 lima
    source = 'all',
    -- 每次返回的结果上限（1-200）
    limit = 50,
    timeout = 20,
    proxy = '',
    -- TMDb 解析：与 skip_segments.conf 使用同一套配置
    tmdb_api_url = 'https://api.tmdb.org/3',
    tmdb_api_key_base64 = 'NmJmYjIxOTZkNzIyN2UyMTIzMGM3Y2YzZjQ4MDNkZGM=',
    -- 下载后是否立即选中该字幕
    auto_load = true,
}
options.read_options(o, 'sub_wyzie')

local REDEEM_URL = 'https://store.wyzie.io/redeem'

local temp_dir = os.getenv('TMPDIR') or '/tmp'

local last_results = {}
local search_handle = nil
local download_handle = nil

-- ===== 通用工具 =====

local function decode_base64(value)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local bits = tostring(value or ''):gsub('[^' .. alphabet .. '=]', ''):gsub('.', function(char)
        if char == '=' then return '' end
        local index = alphabet:find(char, 1, true)
        if not index then return '' end
        local number, result = index - 1, ''
        for bit_index = 5, 0, -1 do
            result = result .. (number % 2 ^ (bit_index + 1) >= 2 ^ bit_index and '1' or '0')
        end
        return result
    end)
    return bits:gsub('%d%d%d?%d?%d?%d?%d?%d?', function(byte)
        if #byte ~= 8 then return '' end
        local number = 0
        for index = 1, 8 do
            if byte:sub(index, index) == '1' then number = number + 2 ^ (8 - index) end
        end
        return string.char(number)
    end)
end

local function url_encode(value)
    return tostring(value):gsub('([^%w%-_%.~])', function(char)
        return string.format('%%%02X', string.byte(char))
    end)
end

-- 视频文件名里常见的发布标记，按整词丢弃而不是正则替换，避免误伤片名
local RELEASE_WORDS = {}
for _, word in ipairs({
    '2160p', '1080p', '720p', '480p', '576p', '4k', '8k',
    'x264', 'x265', 'h264', 'h265', 'h.264', 'h.265', 'hevc', 'avc', 'av1',
    'webrip', 'web-dl', 'webdl', 'web', 'bluray', 'blu-ray', 'bdrip', 'brrip',
    'hdtv', 'dvdrip', 'remux', 'repack', 'proper', 'extended', 'uncut',
    'aac', 'aac2.0', 'ac3', 'eac3', 'dts', 'dts-hd', 'truehd', 'flac', 'opus',
    '10bit', '8bit', 'hdr', 'hdr10', 'hdr10+', 'dv', 'dolby vision', 'sdr',
    'chs', 'cht', 'gb', 'big5', 'jpn', 'eng', 'chi', 'zho', 'sub', 'subs',
    'multi', 'dual', 'audio', '简体', '繁体', '中字', '双语', '字幕',
}) do
    RELEASE_WORDS[word] = true
end

-- 中文组名常写成【】或★…★，这些不是片名
local function longest_title_group(raw)
    local best = ''
    for group in raw:gmatch('%[(.-)%]') do
        local candidate = group:gsub('^%s*(.-)%s*$', '%1')
        local lower = candidate:lower()
        if #candidate >= 2
            and not RELEASE_WORDS[lower]
            and not candidate:match('^%d+$')
            and not candidate:match('^%d+[pPiI]$')
            and #candidate > #best then
            best = candidate
        end
    end
    return best
end

local function clean_title(text)
    local raw = tostring(text or '')
    local title = raw
    -- 调用方通常已用 filename/no-ext，这里再兜底一次容器扩展名
    title = title:gsub('%.(mkv|mp4|avi|mov|ts|m2ts|webm|rmvb|flv|wmv)$', '')
    title = title:gsub('【.-】', ' '):gsub('★.-★', ' ')
    title = title:gsub('%b[]', ' '):gsub('%b()', ' '):gsub('%b{}', ' ')
    -- 音轨布局 7.1 / 5.1 / 2.0 必须在点号被替换成空格前处理，
    -- 否则 "Blade.Runner.7.1" 会变成 "Blade Runner 7 1" 污染标题
    title = title:gsub('[%s_][%d]%.%d%s*$', ' ')
    title = title:gsub('[%s_][%d]%.%d([%s%[%(])', ' ')
    -- 同一个布局也可能以点号分隔，例如 "TrueHD.7.1"
    title = title:gsub('%.[%d]%.%d%s*$', ' ')
    title = title:gsub('%.[%d]%.%d([%s%[%(])', ' ')
    title = title:gsub('[%._]', ' ')
    -- 从季集标记处截断，后面必然是发布信息而非片名
    title = title:gsub('[Ss]%d+[Ee]%d+.*$', ' ')
    title = title:gsub('%d+[xX]%d+.*$', ' ')
    title = title:gsub('第%s*%d+%s*[季集话回].*$', ' ')
    title = title:gsub('[Ee][Pp]%s*%d+.*$', ' ')
    title = title:gsub('%s+%-%s+%d+%s*$', ' ')

    local words = {}
    for word in title:gmatch('%S+') do
        if not RELEASE_WORDS[word:lower()] then
            words[#words + 1] = word
        end
    end

    local result = table.concat(words, ' ')
    result = result:gsub('%s+', ' '):gsub('^%s*(.-)%s*$', '%1')
    -- 去掉截断后残留的尾部标点
    result = result:gsub('[%s%-%+%,%:%|]+$', '')

    -- 中文发布名把标题也放在方括号里，删掉括号后可能什么都不剩，
    -- 这时退回最长且不像发布标记的那一组
    if #result < 2 or result:match('^[%d%s%-%.]+$') then
        local fallback = longest_title_group(raw)
        if #fallback >= 2 then return fallback end
    end

    return result
end

local function parse_episode(text)
    text = tostring(text or '')

    local function parse(value)
        local season, episode = value:match('[Ss](%d+)[%.%-%s:]?[Ee](%d+)')
        if not episode then season, episode = value:match('(%d+)[xX](%d+)') end
        if not episode then
            season, episode = value:match('第%s*(%d+)%s*[季部].-第%s*(%d+)%s*[话集回]')
        end
        if not episode then episode = value:match('[^%a][Ee][Pp]?[%s%._%-]*(%d+)') end
        if not episode then episode = value:match('%s+%-%s+(%d+)%s*$') end
        -- 动漫常写成 [05]；限定纯数字，避免把 [1080p] 当成集数
        if not episode then episode = value:match('%[(%d+)%]') end
        return tonumber(season) or 1, tonumber(episode)
    end

    local season, episode = parse(text)
    if not episode then
        -- 动漫发布名常在集数后继续跟一堆方括号标签，先去掉括号段再试一次；
        -- 顺序不能反，否则 "[S01E02]" 这类写在括号里的季集标记会先被删掉
        season, episode = parse(text:gsub('%b[]', ' '):gsub('%b()', ' '))
    end
    return season, episode
end

local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w+.-]*://') ~= nil or path:find('^edl://') ~= nil)
end

local function is_writable(path)
    local file = io.open(path, 'w')
    if file then
        file:close()
        os.remove(path)
        return true
    end
    return false
end

-- ===== 菜单 =====

local uosc_available = false

local function open_menu(payload)
    if not uosc_available then
        mp.osd_message('Wyzie：uosc 未加载，无法显示字幕列表', 4)
        return
    end
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(payload))
end

local function status_menu(text, footnote)
    open_menu({
        type = 'sub_wyzie',
        title = 'Wyzie 字幕搜索',
        footnote = footnote or '',
        items = {
            {
                title = text,
                value = 'ignore',
                selectable = false,
                italic = true,
                muted = true,
                align = 'center',
            },
        },
    })
end

local function close_menu()
    if uosc_available then
        mp.commandv('script-message-to', 'uosc', 'close-menu', 'sub_wyzie')
    end
end

-- ===== TMDb 解析 =====

local function tmdb_search(title, has_episode, callback)
    local api_key = decode_base64(o.tmdb_api_key_base64)
    if api_key == '' or title == '' then
        callback(nil, nil, nil)
        return
    end

    -- 有季集信息时优先按电视剧搜索，否则用 multi 覆盖电影和剧集
    local kind = has_episode and 'tv' or 'multi'
    local url = string.format(
        '%s/search/%s?api_key=%s&query=%s&language=zh-CN&include_adult=false',
        o.tmdb_api_url, kind, url_encode(api_key), url_encode(title)
    )

    http.request({
        url = url,
        timeout = o.timeout,
        proxy = o.proxy,
        want_json = true,
    }, function(err, data)
        if err or type(data) ~= 'table' or type(data.results) ~= 'table' or #data.results == 0 then
            callback(err, nil, nil)
            return
        end
        local best = data.results[1]
        for _, item in ipairs(data.results) do
            if has_episode and item.media_type ~= 'movie' then
                best = item
                break
            end
        end
        callback(nil, tostring(best.id), best.media_type or kind)
    end)
end

-- ===== Wyzie 搜索 =====

local function wyzie_format_label(item)
    local parts = {}
    if item.display and item.display ~= '' then
        parts[#parts + 1] = item.display
    elseif item.language and item.language ~= '' then
        parts[#parts + 1] = item.language
    end
    if item.format and item.format ~= '' then
        parts[#parts + 1] = item.format:upper()
    end
    if item.source and item.source ~= '' then
        parts[#parts + 1] = item.source
    end
    if item.isHearingImpaired then
        parts[#parts + 1] = 'HI'
    end
    if item.downloadCount then
        parts[#parts + 1] = tostring(item.downloadCount) .. ' 次下载'
    end
    return table.concat(parts, ' · ')
end

local function show_results(items)
    local menu_items = {}

    for index, item in ipairs(items) do
        local title = item.fileName or item.release or item.releases or item.display or ('结果 ' .. index)
        menu_items[#menu_items + 1] = {
            title = title,
            hint = wyzie_format_label(item),
            value = { 'script-message-to', 'sub_wyzie', 'download', tostring(index) },
            keep_open = false,
        }
    end

    open_menu({
        type = 'sub_wyzie',
        title = string.format('Wyzie 字幕搜索结果（%d 条）', #items),
        footnote = '选择后下载并挂载；Esc 关闭',
        min_width = 640,
        items = menu_items,
    })
end

local function search()
    if o.api_key == '' then
        mp.osd_message('Wyzie 未配置 API key：' .. REDEEM_URL, 6)
        msg.warn('sub-wyzie: 未配置 api_key，请到 ' .. REDEEM_URL .. ' 申请后写入 script-opts/sub_wyzie.conf')
        return
    end

    local path = mp.get_property('path')
    if not path then
        mp.osd_message('Wyzie：没有正在播放的文件', 3)
        return
    end

    local raw_name = mp.get_property('media-title') or mp.get_property('filename/no-ext') or ''
    local season, episode = parse_episode(mp.get_property('filename/no-ext') or raw_name)
    local title = clean_title(mp.get_property('filename/no-ext') or raw_name)

    if title == '' then
        mp.osd_message('Wyzie：无法从文件名识别标题', 4)
        return
    end

    msg.verbose(string.format('sub-wyzie: 解析出标题=%q 季=%s 集=%s', title, tostring(season), tostring(episode)))

    if search_handle then
        search_handle:kill()
        search_handle = nil
    end

    status_menu('正在通过 TMDb 解析标题…', title)

    tmdb_search(title, episode ~= nil, function(err, tmdb_id, media_type)
        if err then
            status_menu('TMDb 解析失败：' .. err, '可在控制台查看详细错误')
            return
        end
        if not tmdb_id then
            status_menu('TMDb 未找到匹配的条目：' .. title, '可以手动重命名文件后重试')
            return
        end

        msg.verbose(string.format('sub-wyzie: TMDb id=%s 类型=%s', tmdb_id, tostring(media_type)))

        local params = {
            'id=' .. url_encode(tmdb_id),
            'key=' .. url_encode(o.api_key),
            'language=' .. url_encode(o.language),
            'format=' .. url_encode(o.format),
            'source=' .. url_encode(o.source),
            'limit=' .. url_encode(tostring(o.limit)),
        }
        -- 电影不能带 season/episode，否则 Wyzie 会返回空
        if episode and media_type ~= 'movie' then
            params[#params + 1] = 'season=' .. url_encode(tostring(season))
            params[#params + 1] = 'episode=' .. url_encode(tostring(episode))
        end

        local url = o.api_url .. '/search?' .. table.concat(params, '&')
        status_menu('正在搜索 Wyzie…', title)

        search_handle = http.request({
            url = url,
            timeout = o.timeout,
            proxy = o.proxy,
            want_json = true,
        }, function(search_err, data, status)
            search_handle = nil

            if search_err then
                -- http-async 在非 2xx 时已经返回 "HTTP 403" 这类描述，
                -- 再拼一次状态码会变成 "HTTP 403（HTTP 403）"
                local detail = search_err
                if status and not search_err:find(tostring(status), 1, true) then
                    detail = string.format('%s（HTTP %s）', search_err, tostring(status))
                end
                status_menu('Wyzie 搜索失败：' .. detail, '404/403 时请检查 api_key 与 source')
                msg.warn('sub-wyzie: 搜索失败 ' .. detail)
                return
            end
            if type(data) ~= 'table' then
                status_menu('Wyzie 返回了无法解析的结果')
                return
            end
            if #data == 0 then
                status_menu('Wyzie 没有找到字幕', string.format('标题：%s（TMDb %s）', title, tmdb_id))
                return
            end

            last_results = data
            show_results(data)
        end)
    end)
end

-- ===== 下载与挂载 =====

local function append_sub(file_path)
    local tracks = mp.get_property_native('track-list') or {}
    local _, sub_title = utils.split_path(file_path)
    for _, track in ipairs(tracks) do
        if track['type'] == 'sub' and track['title'] == sub_title then
            mp.commandv('sub-reload', tostring(track['id']))
            return
        end
    end
    if o.auto_load then
        mp.commandv('sub-add', file_path, 'select')
    else
        mp.commandv('sub-add', file_path)
    end
end

local function download(index)
    local item = last_results[tonumber(index) or 0]
    if not item or not item.url then
        mp.osd_message('Wyzie：该结果没有可用的下载地址', 4)
        return
    end

    local ext = (item.format and item.format ~= '') and item.format:lower() or 'srt'
    -- 有些源返回的 format 带点或大写，统一成纯扩展名
    ext = ext:gsub('[^%a%d]', '')
    if ext == '' then ext = 'srt' end

    local path = mp.get_property('path')
    local filename = mp.get_property('filename/no-ext') or 'subtitle'
    local dest
    if is_protocol(path) then
        dest = utils.join_path(temp_dir, filename .. '.wyzie.' .. ext)
    else
        local dir = utils.split_path(path)
        dest = utils.join_path(dir, filename .. '.wyzie.' .. ext)
        if not is_writable(dest) then
            dest = utils.join_path(temp_dir, filename .. '.wyzie.' .. ext)
        end
    end

    if download_handle then
        download_handle:kill()
        download_handle = nil
    end

    mp.osd_message('Wyzie：正在下载字幕…', 2)

    download_handle = http.download(item.url, dest, {
        timeout = o.timeout,
        proxy = o.proxy,
        user_agent = 'mpv-sub-wyzie/1.0',
    }, function(err)
        download_handle = nil
        if err then
            mp.osd_message('Wyzie 下载失败：' .. err, 5)
            msg.error('sub-wyzie: 下载失败 ' .. tostring(item.url) .. ' -> ' .. tostring(err))
            return
        end
        append_sub(dest)
        mp.osd_message('Wyzie：字幕已加载', 3)
        close_menu()
    end)
end

-- ===== 注册 =====

mp.register_script_message('search', search)
mp.register_script_message('download', download)
mp.register_script_message('uosc-version', function()
    uosc_available = true
end)
mp.add_key_binding(nil, 'search', search)

mp.register_event('shutdown', function()
    if search_handle then search_handle:kill() end
    if download_handle then download_handle:kill() end
end)

mp.register_event('end-file', function()
    last_results = {}
end)
