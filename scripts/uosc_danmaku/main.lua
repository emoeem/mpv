local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
VERSION = "2.2.0"

mp.commandv('script-message', 'uosc_danmaku-version', VERSION)

local msg = require('mp.msg')
local utils = require("mp.utils")

AES = require("modules/aes")
Base64 = require("modules/base64")
MD5 = require("modules/md5")
Sha256 = require("modules/hash")
local ResolverAffinity = require("modules/resolver_affinity")
local Color = require("modules/color")
local TitleDisplay = require('modules/title_display')

require("modules/options")
require("modules/utils")
require("modules/parse")
require("modules/guess")
require('modules/render')
require('modules/menu')

require("apis/dandanplay")
require('apis/extra')

require("sites/bilibili")
require("sites/bahamut")
require("sites/iqiyi")
require("sites/mgtv")
require("sites/tencentvideo")
require("sites/youku")

DANMAKU_PATH = os.getenv("TEMP") or "/tmp/"
HISTORY_PATH = mp.command_native({"expand-path", options.history_path})
PID = utils.getpid()
DANMAKU = {sources = {}, count = 1}
ENABLED, FALLBACK_TRIGGER, COMMENTS, DELAY = false, false, nil, 0
DELAY_PROPERTY = string.format("user-data/%s/danmaku-delay", mp.get_script_name())
mp.set_property_native(DELAY_PROPERTY, 0)
HAS_DANMAKU = string.format("user-data/%s/has-danmaku", mp.get_script_name())
mp.set_property_bool(HAS_DANMAKU, false)
DANMAKU_SWITCH_ON = string.format("user-data/%s/danmaku-switch-on", mp.get_script_name())
mp.set_property_bool(DANMAKU_SWITCH_ON, false)
DANMAKU_COUNT = string.format("user-data/%s/danmaku-count", mp.get_script_name())
mp.set_property_native(DANMAKU_COUNT, 0)
KEY = table_to_zero_indexed({
    0x00,0x01,0x02,0x03,0x04,
    0x05,0x06,0x07,0x08,0x09,
    0x0a,0x0b,0x0c,0x0d,0x0e,
    0x0f,0x10,0x11,0x12,0x13,
    0x14,0x15,0x16,0x17,0x18,
    0x19,0x1a,0x1b,0x1c,0x1d,
    0x1e,0x1f
})

PLATFORM = (function()
    local platform = mp.get_property_native("platform")
    if platform then
        if itable_index_of({ "windows", "darwin" }, platform) then
            return platform
        end
    else
        if os.getenv("windir") ~= nil then
            return "windows"
        end
        local homedir = os.getenv("HOME")
        if homedir ~= nil and string.sub(homedir, 1, 6) == "/Users" then
            return "darwin"
        end
    end
    return "linux"
end)()

local rebuild_convert_timer = nil
local auto_load_generation = 0
local pending_local_auto_load = nil
local local_first_frame_ready = false
local LIVE_DANMAKU_SOURCE = "__bilibili_live__"
local live_danmaku_active = false
local live_danmaku_max_messages = 800
local live_danmaku_window = 45

local function delay_auto_load(callback)
    local delay = tonumber(options.auto_load_delay) or 0
    local generation = auto_load_generation
    if delay <= 0 then
        callback()
        return
    end
    add_danmaku_timeout(delay, function()
        if generation == auto_load_generation then callback() end
    end)
end

local function cancel_pending_auto_load()
    auto_load_generation = auto_load_generation + 1
    pending_local_auto_load = nil
end

function cancel_danmaku_auto_load()
    -- An explicit keyboard or menu action owns the loading decision. Restore
    -- local source settings if automatic startup has not reached its first frame.
    if pending_local_auto_load then read_danmaku_source_record(mp.get_property('path')) end
    cancel_pending_auto_load()
end

local function reset_local_auto_load()
    cancel_pending_auto_load()
    local_first_frame_ready = false
end

mp.register_event('start-file', reset_local_auto_load)
mp.register_event('end-file', reset_local_auto_load)
mp.register_event('playback-restart', function(event)
    if event and event.error then return end
    -- This also fires for the first displayed frame when opening paused.
    -- Local history, XML parsing and matching must wait for that frame, rather
    -- than competing with VO startup after an arbitrary file-loaded timeout.
    local_first_frame_ready = true
    local pending = pending_local_auto_load
    pending_local_auto_load = nil
    if pending and pending.generation == auto_load_generation then
        add_danmaku_timeout(0, function()
            if pending.generation == auto_load_generation then pending.callback() end
        end)
    end
end)

function get_danmaku_visibility()
    local history_json = read_file(HISTORY_PATH)
    local history = history_json and utils.parse_json(history_json)
    if type(history) == 'table' and history.show_danmaku ~= nil then
        return history.show_danmaku
    end
    update_json_file(HISTORY_PATH, function(current)
        if current.show_danmaku == nil then current.show_danmaku = false end
    end)
    return false
end

function set_danmaku_visibility(flag)
    return update_json_file(HISTORY_PATH, function(history)
        history.show_danmaku = flag
    end)
end

function set_danmaku_button()
    if get_danmaku_visibility() then
        toggle_danmaku_switch("on")
    end
end

function show_loaded(init)
    if type(COMMENTS) ~= 'table' or #COMMENTS == 0 then
        mp.set_property_native(DANMAKU_COUNT, 0)
        if danmaku_remote_status then danmaku_remote_status('empty', '没有可显示的弹幕，请重试或手动搜索') end
        show_message(i18n.t('当前没有可显示的弹幕，请尝试重新搜索或更换弹幕源'), 3)
        return
    end
    if DANMAKU.anime and DANMAKU.episode then
        local title = TitleDisplay.anime(DANMAKU.anime)
        local episode = TitleDisplay.episode(DANMAKU.episode)
        show_message(i18n.t("匹配内容：") .. title .. " · " .. episode .. i18n.t("\\N弹幕加载成功，共计") .. #COMMENTS .. i18n.t("条弹幕"), 3)
        if init then
            msg.info(DANMAKU.anime .. "-" .. DANMAKU.episode .. " 弹幕加载成功，共计" .. #COMMENTS .. "条弹幕")
        end
    else
        show_message(i18n.t("弹幕加载成功，共计") .. #COMMENTS .. i18n.t("条弹幕"), 3)
    end
    mp.set_property_native(DANMAKU_COUNT, #COMMENTS)
    if danmaku_remote_status then danmaku_remote_status('loaded', '弹幕加载成功') end
end

-- 获取指定时间的延迟
-- 返回该时间点之前所有延迟段的总和
function get_delay_for_time(delay_segments, time)
    if not delay_segments or #delay_segments == 0 then return 0 end

    local segs = {}
    for i = 1, #delay_segments do segs[i] = delay_segments[i] end
    table.sort(segs, function(a, b) return a.start < b.start end)

    local applied_delay = 0
    for i = 1, #segs do
        local seg = segs[i]
        local delay = tonumber(seg.delay)
        if time >= seg.start and delay then
            applied_delay = applied_delay + delay
        else
            break
        end
    end
    return applied_delay
end

local function merge_delay_segments(segments)
    if not segments or #segments == 0 then return {} end

    local NEAREST_THRESHOLD = 10  -- 最邻近段合并阈值
    local MERGE_THRESHOLD = 30    -- 跨段合并阈值
    local EPSILON = 1e-6          -- 判断接近 0 的阈值

    table.sort(segments, function(a, b) return a.start < b.start end)

    local partially_merged = {}
    local i = 1
    while i <= #segments do
        local cur = segments[i]
        local next_seg = segments[i + 1]

        if next_seg and (next_seg.start - cur.start) <= NEAREST_THRESHOLD then
            local combined_delay = tonumber(cur.delay) + tonumber(next_seg.delay)
            if math.abs(combined_delay) > EPSILON then
                table.insert(partially_merged, {
                    start = cur.start,
                    delay = combined_delay
                })
            end
            i = i + 2
        else
            if math.abs(tonumber(cur.delay)) > EPSILON then
                table.insert(partially_merged, cur)
            end
            i = i + 1
        end
    end

    local merged = {}
    for _, seg in ipairs(partially_merged) do
        local merged_flag = false
        for idx, m in ipairs(merged) do
            if math.abs(seg.start - m.start) <= MERGE_THRESHOLD then
                m.delay = tonumber(m.delay) + tonumber(seg.delay)
                if math.abs(m.delay) <= EPSILON then
                    table.remove(merged, idx)
                end
                merged_flag = true
                break
            end
        end
        if not merged_flag then
            if math.abs(tonumber(seg.delay)) > EPSILON then
                table.insert(merged, {
                    start = seg.start,
                    delay = seg.delay
                })
            end
        end
    end

    table.sort(merged, function(a, b) return a.start < b.start end)
    return merged
end

function parse_delay_input(text)
    if not text then return nil end
    local s = tostring(text):gsub("%s+", "")
    if s == "" then return nil end
    -- XmYs 格式，允许负号在分钟部分
    local m, sec = string.match(s, "^(%-?%d+)m(%d+)s$")
    if m and sec then
        m = tonumber(m)
        sec = tonumber(sec)
        if not m or not sec then return nil end
        if m < 0 then sec = -sec end
        return m * 60 + sec
    end
    -- 普通数字（整数或小数），支持负数
    local n = tonumber(s)
    if n ~= nil then return n end
    return nil
end

local function set_danmaku_delay(dly, time, specific_source)
    if specific_source then
        local source = DANMAKU.sources[specific_source]
        if source and source.data and not source.blocked then
            source.delay_segments = source.delay_segments or {}
            if dly == 0 then
                source.delay_segments = {}
            elseif time then
                table.insert(source.delay_segments, {start = time, delay = dly})
            else
                table.insert(source.delay_segments, {start = 0, delay = dly})
            end
            source.delay = nil
            source.delay_segments = merge_delay_segments(source.delay_segments)
            add_source_to_history(specific_source, source)
        end
    else
        for url, source in pairs(DANMAKU.sources) do
            if source.data and not source.blocked then
                source.delay_segments = source.delay_segments or {}
                if dly == 0 then
                    source.delay_segments = {}
                elseif time then
                    table.insert(source.delay_segments, {start = time, delay = dly})
                else
                    table.insert(source.delay_segments, {start = 0, delay = dly})
                end

                source.delay = nil
                source.delay_segments = merge_delay_segments(source.delay_segments)
                add_source_to_history(url, source)
            end
        end
    end

    -- 单源校准只写入该来源自己的延迟段，不能污染全局延迟状态。
    if not specific_source then
        if dly == 0 then
            DELAY = 0
        else
            DELAY = DELAY + dly
        end
    end

    -- 防抖：批量重建 ASS 事件并渲染，避免频繁变更导致重复重建
    if rebuild_convert_timer then
        rebuild_convert_timer:kill()
        rebuild_convert_timer = nil
    end
    rebuild_convert_timer = add_danmaku_timeout(0.1, function()
        if convert_danmaku_to_ass_events then
            convert_danmaku_to_ass_events(true)
        end
        if refresh_danmaku_renderer then
            refresh_danmaku_renderer()
        else
            render()
        end
        rebuild_convert_timer = nil
    end)

    if specific_source then
        show_message(i18n.t('设置当前来源弹幕延迟: ') .. string.format("%.1f", dly + 1e-10) .. ' s')
    else
        show_message(i18n.t('设置弹幕延迟: ') .. string.format("%.1f", DELAY + 1e-10) .. ' s')
        mp.set_property_native(DELAY_PROPERTY, DELAY)
    end
end

local function clear_source()
    local path = mp.get_property("path")
    if not path then return end
    local key = get_source_history_path(path)
    if not key then return end
    local changed = false
    local saved = update_json_file(HISTORY_PATH, function(history)
        local record = history[key]
        if type(record) ~= 'table' or record.sources == nil then return false end
        record.sources = nil
        if next(record) == nil then history[key] = nil end
        changed = true
    end)
    if not saved or not changed then return end
    for url, source in pairs(DANMAKU.sources) do
        if source.from == "user_custom" or source.from == "user_local" then
            DANMAKU.sources[url] = nil
        else
            -- Keep the current API payload, but discard the overrides just reset.
            source.delay, source.delay_segments = nil, nil
            source.blocked, source.from_history = false, nil
        end
    end
    load_danmaku(false)
    show_message(i18n.t("已重置当前视频所有弹幕源更改"), 3)
    msg.verbose("已重置当前视频所有弹幕源更改")
end

local function get_emby_danmaku_context(path)
    path=path or mp.get_property('path','')
    if type(path)~='string' or not path:match('^emby://')
        or path~=mp.get_property('path','')
        or not mp.get_property_bool('user-data/emby/managed',false) then return nil end
    local identity=mp.get_property_native('user-data/emby/identity',{})
    local owner=mp.get_property_native('user-data/emby/recovery-owner',{})
    if type(identity)~='table' or identity.version~=1 or identity.uri~=path
        or type(owner)~='table' or owner.uri~=path or owner.entryId~=identity.entryId
        or owner.generation~=identity.generation
        or (identity.mediaType~='Movie' and identity.mediaType~='Episode')
        or type(identity.title)~='string' or identity.title==''
        or type(identity.historyDirectory)~='string' or not identity.historyDirectory:match('^Emby:')
        or type(identity.historyFile)~='string' or not identity.historyFile:match('^Emby:') then return nil end
    local account,item=path:match('^emby://([%w_-]+)/([%w_-]+)%??')
    if account~=identity.accountId or item~=identity.itemId then return nil end
    local function index(value)
        if type(value)=='number' and value==value and value>=0 and value<=100000
            and value==math.floor(value) then return value end
    end
    return {dir=identity.historyDirectory,file=identity.historyFile,filename=identity.title,
        mediaType=identity.mediaType,seriesName=identity.seriesName,
        seasonNumber=index(identity.seasonNumber),episodeNumber=index(identity.episodeNumber)}
end

-- Logical drive paths are decoded once and never taken from a transient ticket.
local function logical_path(value)
    if type(value) ~= 'string' or value:sub(1,1) ~= '/' or #value > 32768
        or value:find('[%z\1-\31\127]') or value:find('\\',1,true) then return nil end
    local parts = {}
    for part in value:gmatch('[^/]+') do
        if part == '..' then return nil end
        if part ~= '.' then parts[#parts+1] = part end
    end
    if #parts == 0 then return nil end
    return '/' .. table.concat(parts,'/')
end

local function drive_context(prefix, file)
    local name = file:match('([^/]+)$')
    local directory = file:match('^(.*)/[^/]+$')
    directory = directory ~= '' and directory or '/'
    local filename = strip_media_extension(name)
    return {dir=prefix..directory:gsub('/+$','')..'/', file=prefix..file,
        filename=filename, directory=directory, episodeNumber=get_episode_number(filename)}
end

local function get_network_danmaku_context(path)
    path = path or mp.get_property('path','')
    if type(path) ~= 'string' or path ~= mp.get_property('path','')
        or not mp.get_property_bool('user-data/network-connections/playing',false) then return nil end
    local id, revision, encoded = path:match('^network%-media://([%w_-]+)/(%d+)/(.*)$')
    if not id or #revision > 15 or encoded:gsub('%%[%x][%x]',''):find('%',1,true) then return nil end
    local file = logical_path('/' .. encoded:gsub('%%(%x%x)',function(hex) return string.char(tonumber(hex,16)) end))
    local owner = mp.get_property_native('user-data/network-connections/danmaku-identity',{})
    local stream = mp.get_property('stream-open-filename','')
    if not file or type(owner) ~= 'table' or owner.version ~= 1 or owner.uri ~= path
        or owner.profileId ~= id or tostring(owner.revision) ~= revision
        or logical_path(owner.path) ~= file
        or mp.get_property_native('user-data/network-connections/profile-id','') ~= id
        or not stream:match('^http://127%.0%.0%.1:%d+/media/[%w_-]+$') then return nil end
    return drive_context('Network:'..id..':r'..revision..':', file)
end

local function get_alist_danmaku_context(path)
    path = path or mp.get_property('path','')
    if not mp.get_property_bool('user-data/alist/playing',false) then return nil end
    local owner = mp.get_property_native('user-data/alist/danmaku-identity',{})
    if type(owner) ~= 'table' or owner.version ~= 1 or owner.uri ~= path
        or path ~= mp.get_property('path','') or type(owner.scope) ~= 'string'
        or #owner.scope ~= 32 or not owner.scope:match('^%x+$') then return nil end
    local file = logical_path(owner.path)
    if not file or file:match('([^/]+)$') ~= owner.name then return nil end
    return drive_context('AList2:'..owner.scope:lower()..':',file)
end

local function get_drive_danmaku_context(path)
    if type(path) == 'string' and path:match('^network%-media://') then
        return get_network_danmaku_context(path)
    end
    return get_alist_danmaku_context(path)
end

local function drive_title(context)
    local title = format_filename(context.filename)
    if title then
        local name, season, episode = title:match('^(.-)%s*[sS](%d+)[eE](%d+)')
        if season then return title_replace(name), season, episode end
        name, episode = title:match('^(.-)%s*[eE](%d+)')
        if episode then return title_replace(name), nil, episode end
        return title_replace(title)
    end
    local parent = context.directory
    local name = parent:match('([^/]+)$') or ''
    local season = name:match('^[sS]easons?%s*(%d+)$') or name:match('^第%s*(%d+)%s*季$')
    if season then name = parent:match('^(.*)/[^/]+$'):match('([^/]+)$') or '' end
    local episode = context.filename:match('^%d%d?%d?$')
    episode = episode and tonumber(episode)
    if episode == 0 then episode = nil end
    if name == '' then return title_replace(context.filename), nil, nil end
    return title_replace(name:gsub('[%._]',' ')), season, episode
end

-- Managed sources bind matching and history to the current owner snapshot.
local parse_media_title = parse_title
function parse_title()
    local path = mp.get_property('path','')
    if path:match('^emby://') then
        local emby = get_emby_danmaku_context(path)
        if not emby then return end
        if emby.mediaType == 'Episode' then
            return emby.seriesName ~= '' and emby.seriesName or nil, emby.seasonNumber, emby.episodeNumber
        end
        return emby.filename
    end
    local drive = get_drive_danmaku_context(path)
    if drive then return drive_title(drive) end
    if path:match('^network%-media://') or mp.get_property_bool('user-data/alist/playing',false) then return end
    return parse_media_title()
end

function get_source_history_path(path)
    if type(path)=='string' and path:match('^emby://') then
        local emby=get_emby_danmaku_context(path)
        return emby and emby.file or nil
    end
    local alist = get_drive_danmaku_context(path)
    if alist and alist.file then return alist.file end
    if type(path) == 'string' and path:match('^network%-media://')
        or mp.get_property_bool('user-data/alist/playing',false) then return nil end
    if is_protocol(path) then return remove_query(path) end
    return path
end

function get_danmaku_association_history_directory(path)
    if type(path)=='string' and path:match('^emby://') then
        local emby=get_emby_danmaku_context(path)
        return emby and emby.dir or nil
    end
    local dir = get_parent_directory(path)
    local alist = get_drive_danmaku_context(path)
    if alist then
        return alist.dir
    elseif type(path) == 'string' and path:match('^network%-media://')
        or mp.get_property_bool('user-data/alist/playing',false) then return nil
    elseif is_protocol(path) then
        local title, season_num, episod_num = parse_title()
        if title and episod_num then
            return season_num and (title .. " Season" .. season_num) or title
        end
    end
    return dir
end

local function get_resolver_history_directory()
    local path = mp.get_property("path")
    if type(path)=='string' and path:match('^emby://') then
        local emby=get_emby_danmaku_context(path)
        return emby and emby.dir or nil
    end
    local dir = path and get_parent_directory(path) or nil
    local alist = get_drive_danmaku_context(path)

    if alist then
        return alist.dir
    elseif type(path) == 'string' and path:match('^network%-media://')
        or mp.get_property_bool('user-data/alist/playing',false) then return nil
    elseif path and is_protocol(path) then
        local title, season_num = parse_title()
        if title then
            return season_num and (title .. " Season" .. season_num) or title
        end
        return get_parent_directory(remove_query(path))
    end
    return dir
end

function get_danmaku_resolver_context(query)
    return {
        directory = get_resolver_history_directory(),
        source_key = ResolverAffinity.source_key(query),
    }
end

function read_danmaku_resolver_affinity(query, context)
    local directory = context and context.directory or get_resolver_history_directory()
    if not directory then return nil end

    local history_json = read_file(HISTORY_PATH)
    if not history_json then return nil end
    local history = utils.parse_json(history_json) or {}
    return ResolverAffinity.get(history, directory, query)
end

function write_danmaku_resolver_affinity(query, server, mode, context)
    local directory = context and context.directory or get_resolver_history_directory()
    if not directory then return false end
    local changed = false
    local saved = update_json_file(HISTORY_PATH, function(history)
        changed = ResolverAffinity.set(history, directory, query, server, mode, os.time())
        return changed
    end)
    return saved and changed
end

function clear_danmaku_resolver_affinity(query, expected_server, context)
    local directory = context and context.directory or get_resolver_history_directory()
    if not directory then return false end
    local changed = false
    local saved = update_json_file(HISTORY_PATH, function(history)
        changed = ResolverAffinity.clear(history, directory, query, expected_server)
        return changed
    end)
    return saved and changed
end

function write_history(episodeid, api_server, matched_episode_number, association, transaction)
    local path = mp.get_property("path")
    local dir = get_danmaku_association_history_directory(path)
    local fname = mp.get_property('filename/no-ext')
    local episodeNumber = tonumber(matched_episode_number)

    local emby = get_emby_danmaku_context(path)
    local alist = get_drive_danmaku_context(path)
    if emby then
        fname=emby.filename
        if emby.episodeNumber~=nil then episodeNumber=emby.episodeNumber end
    elseif alist then
        fname = alist.filename
        if not episodeid and not DANMAKU.extra and alist.episodeNumber then
            episodeNumber = alist.episodeNumber
        end
    elseif is_protocol(path) then
        local title, _, episod_num = parse_title()
        if title and episod_num then
            fname = url_decode(mp.get_property("media-title"))
            episodeNumber = episodeNumber or episod_num
        end
    end

    -- Third-party servers do not necessarily encode the episode number in
    -- episodeId. Prefer explicit API metadata and the actual media filename.
    if not episodeNumber and DANMAKU.extra then
        episodeNumber = DANMAKU.extra.episodenum
    end
    if not episodeNumber and fname then
        episodeNumber = get_episode_number(fname)
    end
    if not episodeNumber and episodeid then
        episodeNumber = tonumber(episodeid) % 1000
    end
    episodeNumber = tonumber(episodeNumber) or 0

    if dir ~= nil or type(transaction) == 'function' then
        return update_json_file(HISTORY_PATH, function(history)
        if transaction then transaction(history) end
        if dir == nil then return end
        -- Replace only owned association fields; preserve extension/source data.
        history[dir] = type(history[dir]) == 'table' and history[dir] or {}
        history[dir].episodeId, history[dir].extra, history[dir].api_server = nil, nil, nil
        history[dir].fname = fname
        history[dir].source = association and association.source or DANMAKU.source
        history[dir].animeTitle = association and association.animeTitle or DANMAKU.anime
        history[dir].episodeTitle = association and association.episodeTitle or DANMAKU.episode
        history[dir].episodeNumber = episodeNumber
        if episodeid then
            history[dir].episodeId = episodeid
        elseif DANMAKU.extra then
            history[dir].extra = DANMAKU.extra
        end
        if api_server then
            history[dir].api_server = api_server
        end
        end)
    end
end

function remove_source_from_history(rm_source)
    local path = get_source_history_path(mp.get_property("path"))
    if not path then return false end
    return update_json_file(HISTORY_PATH, function(history)
        local record = history[path]
        if type(record) ~= 'table' or type(record.sources) ~= 'table' then return false end
        record.sources[rm_source] = nil
    end)
end

function add_source_to_history(add_url, add_source, transaction)
    local path = get_source_history_path(mp.get_property("path"))
    if not path then return false end
    local function mutate(history)
        history[path] = history[path] or {}
        history[path].sources = history[path].sources or {}
        history[path].sources[add_url] = history[path].sources[add_url] or {}
        local record = history[path].sources[add_url]
        record.from = add_source.from or "user_custom"
        record.association = add_source.association == true or nil
        record.blocked = add_source.blocked or false
        local delay_segments = shallow_copy(add_source.delay_segments or {})
        if #delay_segments > 0 then
            record.delay_segments = merge_delay_segments(delay_segments)
            if #record.delay_segments == 0 then record.delay_segments = nil end
        else
            record.delay_segments = nil
        end
        record.delay = nil
    end
    if type(transaction) == 'table' then mutate(transaction); return true end
    return update_json_file(HISTORY_PATH, mutate)
end

function read_danmaku_source_record(path)
    path = get_source_history_path(path)

    local history_json = read_file(HISTORY_PATH)
    if not history_json then return end

    local history = utils.parse_json(history_json) or {}
    local record = history[path]

    if not record or not record.sources then return end

    local sources = record.sources
    local upgraded_sources = {}

    if is_nested_table(sources) then
        for source, data in pairs(sources) do
            local from = data.from or "user_custom"
            local blocked = data.blocked or false
            local delay_segments = shallow_copy(data.delay_segments or {})
            if data.delay ~= nil then
                for i = #delay_segments, 1, -1 do
                    if delay_segments[i].start == 0 then
                        table.remove(delay_segments, i)
                    end
                end
                table.insert(delay_segments, 1, { start = 0, delay = tonumber(data.delay) })
            end
            if #delay_segments > 0 then
                delay_segments = merge_delay_segments(delay_segments)
            else
                delay_segments = nil
            end

            DANMAKU.sources[source] = {
                from = from,
                association = data.association == true or nil,
                blocked = blocked,
                delay_segments = delay_segments,
                from_history = true,
            }
        end
    else
        for _, raw in ipairs(sources) do
            local source = raw
            local blocked = false
            local from = raw:match("<(.-)>")
            local delay = raw:match("{{(.-)}}")

            source = source:gsub("<.->", ""):gsub("{{.-}}", "")

            if source:match("^%-") then
                source = source:sub(2)
                blocked = true
                from = from or "api_server"
            end

            local delay_segments = nil
            if delay ~= nil then
                delay_segments = {
                    { start = 0, delay = tonumber(delay) }
                }
            end

            DANMAKU.sources[source] = {
                from = from or "user_custom",
                blocked = blocked,
                delay_segments = delay_segments,
                from_history = true,
            }

            upgraded_sources[source] = shallow_copy(DANMAKU.sources[source])
        end

        if next(upgraded_sources) then
            update_json_file(HISTORY_PATH, function(current, previous)
                -- A migration based on an earlier snapshot must not undo a
                -- concurrent edit. The next read can migrate the newer file.
                if previous ~= history_json then return false end
                if current[path] then current[path].sources = upgraded_sources end
            end)
        end
    end
end

-- 视频播放时保存弹幕
function save_danmaku(not_forced)
    local path = mp.get_property("path")
    local dir = get_parent_directory(path) or ""
    local filename = mp.get_property('filename/no-ext')
    local danmaku_out = utils.join_path(dir, filename .. ".xml")
    -- 排除网络播放场景
    if not path or is_protocol(path) or (not file_exists(danmaku_out)
    and not is_writable(danmaku_out)) then
        show_message(i18n.t("此弹幕文件不支持保存至本地"))
        msg.warn("此弹幕文件不支持保存至本地")
    else
        if not_forced and file_exists(danmaku_out) then
            show_message(i18n.t("已存在同名弹幕文件：") .. danmaku_out)
            msg.info("已存在同名弹幕文件：" .. danmaku_out)
            return
        else
            convert_danmaku_to_xml(danmaku_out)
        end
    end
end

-- 加载弹幕
function load_danmaku(from_menu, no_osd)
    if not ENABLED then return end
    convert_danmaku_to_ass_events()
    render_danmaku(from_menu, no_osd)
    return type(COMMENTS) == 'table' and #COMMENTS or 0
end

function load_danmaku_for_url(path)
    if path:match('^emby://') then
        local identity=mp.get_property_native('user-data/emby/identity',{})
        if type(identity)=='table' and identity.uri==path and identity.mediaType=='Audio' then
            -- Music is not a film title; never send songs to automatic film matching.
            return
        end
    end
    if danmaku_remote_status then danmaku_remote_status('matching', '正在匹配弹幕') end
    if path:match('^emby://') then
        local emby=get_emby_danmaku_context(path)
        if not emby then return end
        read_danmaku_source_record(path)
        if emby.mediaType=='Episode' and (not emby.seasonNumber or emby.seasonNumber<1
            or not emby.episodeNumber or emby.episodeNumber<1 or not emby.seriesName or emby.seriesName=='') then
            -- Specials and incomplete metadata must not silently become S01E01.
            addon_danmaku(nil,false)
            if danmaku_remote_status then danmaku_remote_status('unmatched','请手动选择这集的弹幕') end
            return
        end
        local stream=mp.get_property('stream-open-filename','')
        if not stream:match('^http://127%.0%.0%.1:%d+/media/[%w_-]+$') then return end
        -- The opaque ticket stays transient. History is keyed by account,
        -- revision, series/season and item; never by this expiring stream URL.
        auto_load_danmaku(path,emby.dir,emby.filename,emby.episodeNumber,stream)
        addon_danmaku(emby.dir,false)
        return
    end
    if path:find('b23%.tv/') or path:find('bili2233%.com/') then
        -- 短链本身带不出 BV/av：优先复用 online-media 已发布的规范地址
        -- （source-url 与当前 path 一致才可信，防止上一条视频的残留值挂错弹幕），
        -- 没有再自行展开重定向，之后与普通页面链接走同一条弹幕链路。
        local canonical = mp.get_property_native('user-data/online-media/canonical-url', '')
        local source_url = mp.get_property_native('user-data/online-media/source-url', '')
        if canonical and source_url == path and canonical:find('bilibili%.com') then
            load_danmaku_for_bilibili(canonical)
            return
        end
        resolve_bilibili_short_link(path, function(resolved)
            if resolved then
                load_danmaku_for_bilibili(resolved)
            else
                show_message(i18n.t("展开哔哩哔哩短链失败，无法获取对应弹幕"), 3)
                msg.warn("展开哔哩哔哩短链失败: " .. tostring(path))
            end
        end)
        return
    end
    if path:find('bilibili.com') or path:find('bilivideo.c[nom]+') then
        load_danmaku_for_bilibili(path)
        return
    end

    if path:find('bahamut.akamaized.net') then
        load_danmaku_for_bahamut(path)
        return
    end

    local alist = get_drive_danmaku_context(path)
    if alist then
        read_danmaku_source_record(path)
        local hash_path = path
        if path:match('^alist%-archive://') or path:match('^network%-media://') then
            local resolved = mp.get_property('stream-open-filename', '')
            if resolved:match('^https?://') then hash_path = resolved end
        end
        auto_load_danmaku(path, alist.dir, alist.filename, alist.episodeNumber, hash_path)
        addon_danmaku(alist.dir, false)
        return
    end

    if path:match('^network%-media://') or mp.get_property_bool('user-data/alist/playing',false) then
        if danmaku_remote_status then danmaku_remote_status('unmatched','网盘播放信息尚未就绪，请重试') end
        return
    end
    local title, season_num, episod_num = parse_title()
    local filename = strip_media_extension(url_decode(mp.get_property("media-title")))
    local episod_number = nil
    if title and episod_num then
        if season_num then
            dir = title .." Season".. season_num
            episod_number = episod_num
        else
            dir = title
        end
        auto_load_danmaku(path, dir, filename, episod_number)
        addon_danmaku(dir, false)
        return
    end
    get_danmaku_with_hash(filename, path)
    addon_danmaku()
end

local function api_server_is_configured(url)
    if not url or url == "" then return false end
    local target = tostring(url):gsub("/+$", "")
    -- A manually selected anime source may resume its own history without
    -- joining generic search/hash/resolver requests for unrelated titles.
    for _, setting in ipairs({options.api_server or "", options.anime_api_server or ""}) do
        for _, configured in ipairs(get_api_server_list(setting)) do
            if tostring(configured):gsub("/+$", "") == target then return true end
        end
    end
    return false
end

-- 自动加载上次匹配的弹幕
local extra_source_hosts = {
    youku = 'youku.com', qq = 'qq.com', qiyi = 'iqiyi.com',
    imgo = 'mgtv.com', bilibili1 = 'bilibili.com',
}

local function saved_extra_source(history, path, extra, allow_stored_url)
    local suffix = extra and extra_source_hosts[extra.site]
    if not suffix then return nil end
    local function same_site(url)
        if type(url) ~= 'string' then return false end
        local host = url:match('^https?://([^/:]+)')
        if not host then return false end
        host = host:lower()
        return host == suffix or host:sub(-#suffix - 1) == '.' .. suffix
    end

    local record = history[get_source_history_path(path)]
    local found, blocked = nil, false
    for url, source in pairs(record and record.sources or {}) do
        if type(source) == 'table' and source.association == true and same_site(url) then
            if source.blocked then
                blocked = true
            else
                if found then return nil end
                found = url
            end
        end
    end
    if blocked then return nil end
    if found then return found end
    return allow_stored_url and same_site(extra.play_url) and extra.play_url or nil
end

function auto_load_danmaku(path, dir, filename, number, hash_path)
    if danmaku_remote_status then danmaku_remote_status('matching', '正在匹配弹幕') end
    if dir ~= nil then
        local history_json = read_file(HISTORY_PATH)
        if history_json ~= nil then
            local history = utils.parse_json(history_json) or {}
            -- 1.判断父文件名是否存在
            local history_dir = history[dir]
            if history_dir ~= nil then
                --2.如果存在，则获取number和id
                DANMAKU.anime = history_dir.animeTitle
                local episode_number = history_dir.episodeTitle and history_dir.episodeTitle:match("%d+")
                local history_number = history_dir.episodeNumber
                local history_id = history_dir.episodeId
                local history_fname = history_dir.fname
                local history_extra = history_dir.extra
                local history_api_server = history_dir.api_server
                if history_api_server and not api_server_is_configured(history_api_server) then
                    msg.warn("历史记录中的弹幕服务器已移除，改用当前配置的服务器")
                    history_api_server = nil
                end
                local playing_number = nil

                -- Repair old history written from episodeId % 1000. The
                -- filename is the reliable source for SxxExx media names.
                local parsed_history_number = history_fname and get_episode_number(history_fname)
                if parsed_history_number then history_number = parsed_history_number end
                history_number = tonumber(history_number)

                if history_fname then
                    if filename ~= history_fname then
                        if number then
                            playing_number = tonumber(number)
                        else
                            history_number, playing_number = get_episode_number(filename, history_fname)
                        end
                    else
                        playing_number = tonumber(number) or get_episode_number(filename) or history_number
                    end
                else
                    playing_number = tonumber(number) or get_episode_number(filename)
                end
                history_number = tonumber(history_number)
                playing_number = tonumber(playing_number)
                if playing_number ~= nil and history_number ~= nil then
                    local x = playing_number - history_number --获取集数差值
                    DANMAKU.episode = episode_number and string.format("第%s话", episode_number + x) or history_dir.episodeTitle
                    DANMAKU.api_server = history_api_server or nil
                    show_message(i18n.t("自动加载上次匹配的弹幕"), 3)
                    msg.verbose("自动加载上次匹配的弹幕")
                    if history_id then
                        local tmp_id = tostring(x + history_id)
                        local normalized_history_server = tostring(history_api_server or "")
                            :lower():gsub("/+$", "")
                        local stable_history_id = normalized_history_server == "https://api.dandanplay.net"
                        set_episode_id(tmp_id, nil, history_api_server, playing_number, {
                            from_history = true,
                            -- Mirror-local episode IDs are not guaranteed to
                            -- stay stable or consecutive after a database refresh.
                            refresh_before_fetch = x ~= 0 or not stable_history_id,
                            refresh_reason = x ~= 0 and "episode_changed" or "community_server_refresh",
                            history_record = {
                                animeTitle = history_dir.animeTitle,
                                episodeTitle = DANMAKU.episode,
                                episodeNumber = playing_number,
                                source = history_dir.source,
                            },
                        })
                    elseif history_extra then
                        local episodenum = (tonumber(history_extra.episodenum) or history_number) + x
                        local reuse_saved_url = x == 0 and history_fname == filename
                            and tonumber(history_extra.episodenum) == playing_number
                        local source_url = saved_extra_source(history, path,
                            history_extra, reuse_saved_url)
                        if source_url then
                            DANMAKU.source = history_extra.site
                            DANMAKU.extra = shallow_copy(history_extra)
                            DANMAKU.extra.episodenum = playing_number
                            DANMAKU.extra.play_url = source_url
                            DANMAKU.sources[source_url] = DANMAKU.sources[source_url]
                                or {from = 'user_custom', association = true}
                            msg.info('复用当前集已确认的弹幕地址，跳过剧集列表查询')
                            add_danmaku_source_online(source_url, false, function()
                                msg.info('历史弹幕地址已失效，重新查询剧集列表')
                                get_details(history_extra.class, history_extra.id,
                                    history_extra.site, history_extra.title,
                                    history_extra.year, history_extra.number, episodenum)
                            end, true)
                        else
                            get_details(history_extra.class, history_extra.id,
                                history_extra.site, history_extra.title,
                                history_extra.year, history_extra.number, episodenum)
                        end
                    end
                else
                    get_danmaku_with_hash(filename, hash_path or path)
                end
            else
                get_danmaku_with_hash(filename, hash_path or path)
            end
        else
            get_danmaku_with_hash(filename, hash_path or path)
        end
    end
end

function init(path)
    if not path then return end
    if danmaku_remote_status then danmaku_remote_status('matching', '正在匹配弹幕') end
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    local video = mp.get_property_native("current-tracks/video")
    local duration = mp.get_property_number("duration", 0)
    if not video or video["image"] or video["albumart"] or duration < 60 then
        msg.info("不支持的播放内容（非视频）")
        return
    end
    if is_protocol(path) then
        load_danmaku_for_url(path)
    end
    if dir and filename then
        local danmaku_xml = utils.join_path(dir, filename .. ".xml")
        if file_exists(danmaku_xml) then
            add_danmaku_source_local(danmaku_xml, true)
        else
            auto_load_danmaku(path, dir, filename)
            addon_danmaku(dir, true)
        end
    end
end

local function refresh_live_danmaku(no_render)
    convert_danmaku_to_ass_events(true)
    local count = type(COMMENTS) == "table" and #COMMENTS or 0
    mp.set_property_native(DANMAKU_COUNT, count)
    mp.set_property_bool(HAS_DANMAKU, count > 0)
    if no_render then return end
    if get_danmaku_visibility() then
        ENABLED = true
        toggle_danmaku_switch("on")
        refresh_danmaku_renderer()
    end
end

local function reset_live_danmaku(source)
    DANMAKU.sources[LIVE_DANMAKU_SOURCE] = {
        from = source == "bilibili" and "bilibili_live" or "live",
        live = true,
        sequence = 0,
        data = {},
    }
    COMMENTS = {}
    live_danmaku_active = true
    mp.set_property_native(DANMAKU_COUNT, 0)
    mp.set_property_bool(HAS_DANMAKU, false)
end

local function stop_live_danmaku()
    local had_source = DANMAKU.sources[LIVE_DANMAKU_SOURCE] ~= nil
    DANMAKU.sources[LIVE_DANMAKU_SOURCE] = nil
    live_danmaku_active = false
    if had_source then refresh_live_danmaku(false) end
end

local function append_live_danmaku(payload)
    if not live_danmaku_active or type(payload) ~= "string" or #payload > 262144 then return end
    local incoming = utils.parse_json(payload)
    if type(incoming) ~= "table" then return end

    local now = mp.get_property_number("time-pos", 0) or 0
    local source = DANMAKU.sources[LIVE_DANMAKU_SOURCE]
    if type(source) ~= "table" then
        reset_live_danmaku("bilibili")
        source = DANMAKU.sources[LIVE_DANMAKU_SOURCE]
    end
    local current = type(source.data) == "table" and source.data or {}
    local retained = {}
    local cutoff = now - live_danmaku_window
    for _, item in ipairs(current) do
        if type(item) == "table" and tonumber(item.time) and item.time >= cutoff then
            retained[#retained + 1] = item
        end
    end

    for index, item in ipairs(incoming) do
        if index > 240 then break end
        if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
            source.sequence = (source.sequence or 0) + 1
            local danmaku_type = math.floor(tonumber(item.type) or 1)
            if danmaku_type < 1 or danmaku_type > 5 then danmaku_type = 1 end
            retained[#retained + 1] = {
                time = now + math.min(index * 0.003, 0.24),
                type = danmaku_type,
                size = math.max(12, math.min(64, tonumber(item.size) or 25)),
                color = Color.normalize(item.color),
                text = item.text,
                live_sequence = source.sequence,
            }
        end
    end

    if #retained > live_danmaku_max_messages then
        local bounded = {}
        local first = #retained - live_danmaku_max_messages + 1
        for index = first, #retained do bounded[#bounded + 1] = retained[index] end
        retained = bounded
    end
    source.data = retained
    refresh_live_danmaku(false)
end

mp.register_event("file-loaded", function()
    auto_load_generation = auto_load_generation + 1
    local path = mp.get_property("path")
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    local video = mp.get_property_native("current-tracks/video")
    local fps = mp.get_property_number("container-fps", 0)
    local duration = mp.get_property_number("duration", 0)
    if not video or video["image"] or video["albumart"] or fps < 23 or duration < 60 then
        return
    end

    local function load_for_current_file()
        read_danmaku_source_record(path)

        if not get_danmaku_visibility() then
            return
        end

        if options.autoload_for_url and is_protocol(path) then
            delay_auto_load(function()
                ENABLED = true
                load_danmaku_for_url(path)
            end)
        end

        if filename == nil or dir == nil then
            return
        end
        local danmaku_xml = utils.join_path(dir, filename .. ".xml")
        if options.autoload_local_danmaku then
            if file_exists(danmaku_xml) then
                ENABLED = true
                add_danmaku_source_local(danmaku_xml)
                return
            end
        end

        if options.auto_load then
            delay_auto_load(function()
                ENABLED = true
                auto_load_danmaku(path, dir, filename)
                addon_danmaku(dir, false)
            end)
            return
        end

        if ENABLED and COMMENTS == nil and not is_async_running() then
            delay_auto_load(function() init(path) end)
        end
    end

    if is_protocol(path) then
        load_for_current_file()
    elseif local_first_frame_ready then
        load_for_current_file()
    else
        pending_local_auto_load = {generation = auto_load_generation, callback = load_for_current_file}
    end
end)

-------------- 键位绑定 --------------
mp.add_key_binding(options.open_search_danmaku_menu_key, "open_search_danmaku_menu", function()
    mp.commandv("script-message", "open_search_danmaku_menu")
end)
mp.add_key_binding(options.show_danmaku_keyboard_key, "show_danmaku_keyboard", function()
    mp.commandv("script-message", "show_danmaku_keyboard")
end)

mp.register_script_message("danmaku-delay", function(...)
    local commands = {...}
    local delay_str, time_str = commands[1], commands[2]
    local source_arg = commands[3]
    local dly = parse_delay_input(delay_str)
    local time = time_str and tonumber(time_str)
    if type(dly) ~= "number" then
        show_message(i18n.t("参数错误：缺少有效的延迟秒数"), 3)
        return
    end
    if source_arg and source_arg ~= "nil" then
        set_danmaku_delay(dly, time, source_arg)
    else
        set_danmaku_delay(dly, time)
    end
end)

mp.register_script_message("live-danmaku-reset", reset_live_danmaku)
mp.register_script_message("live-danmaku-batch", append_live_danmaku)
mp.register_script_message("live-danmaku-stop", stop_live_danmaku)

mp.register_script_message("show_danmaku_keyboard", function()
    cancel_danmaku_auto_load()
    ENABLED = not ENABLED
    if ENABLED then
        toggle_danmaku_switch("on")

        if COMMENTS == nil then
            show_message(i18n.t("加载弹幕初始化..."), 3)
            set_danmaku_visibility(true)
            local path = mp.get_property("path")
            init(path)
        else
            show_loaded()
            show_danmaku_func()
        end
    else
        show_message(i18n.t("关闭弹幕"), 2)
        toggle_danmaku_switch("off")
        hide_danmaku_func()
    end
end)

mp.register_script_message("clear-source", clear_source)
mp.register_script_message("immediately_save_danmaku", save_danmaku)
mp.register_script_message("open_source_delay_menu", open_delay_menu)
mp.register_script_message("open_search_danmaku_menu", open_input_menu)
mp.register_script_message("open_add_source_menu", open_add_menu)
mp.register_script_message("open_add_total_menu", open_add_total_menu)

-- EmoPlay 保留的上游 d8c1cd8 特性：自动弹幕加载失败后按开关弹出搜索框。
-- 沿用 render.lua on_unload 的 FALLBACK_TRIGGER 复位实现每文件重新武装
-- （本地旧代码误用小写 fallback_triggered，从未被复位，此处一并修正）。
mp.register_script_message("auto_load_fallback", function()
    if not FALLBACK_TRIGGER and options.auto_fallback_search and COMMENTS == nil then
        FALLBACK_TRIGGER = true
        msg.info("自动加载弹幕失败，自动弹出搜索框")
        mp.commandv("script-message", "open_search_danmaku_menu")
    end
end)

-- EmoPlay 保留：外部菜单查询实际加载条数。
mp.register_script_message("show_danmaku_count", show_loaded)

-- The phone adapter runs after all engine globals and loaders are initialized.
require('modules/remote')
