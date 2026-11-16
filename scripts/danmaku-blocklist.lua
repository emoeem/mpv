-- 弹幕屏蔽词管理：读写 uosc_danmaku 的 blacklist_path 文件（blacklist_path 未
-- 配置时默认 ~~/files/danmaku-blacklist.txt），提供 uosc 菜单增删屏蔽词，改完
-- 即时通知 uosc_danmaku 重载，无需重启。
-- 文件逐行原样保存；每行是 Lua 模式（与 uosc_danmaku 的匹配语义一致）。
local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'

-- 手工从 script-opts/<name>.conf 提取单个键值。不能用 mp.options 跨脚本读
-- uosc_danmaku.conf：read_options 只认输入表里预置的键，conf 里其余键全会刷
-- 「unknown key」告警（每次启动几十行）。
local function conf_lookup(conf_name, key)
    local path = mp.command_native({ 'expand-path',
        '~~/script-opts/' .. conf_name .. '.conf' })
    local file = io.open(path, 'r')
    if not file then return nil end
    local value = nil
    for line in file:lines() do
        local clean = line:gsub('%s*#.*$', '')
        local k, v = clean:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k == key then value = v end
    end
    file:close()
    return value
end

-- 屏蔽词路径：默认跟随 uosc_danmaku.conf 的 blacklist_path（未配置时回退
-- 默认文件）；用户可用 script-opts/danmaku_blocklist.conf 的同名键覆盖。
local o = {
    blacklist_path = conf_lookup('uosc_danmaku', 'blacklist_path')
        or '~~/files/danmaku-blacklist.txt',
}
options.read_options(o, 'danmaku_blocklist')
if o.blacklist_path == nil or o.blacklist_path == '' then
    o.blacklist_path = '~~/files/danmaku-blacklist.txt'
end

local blacklist_file = mp.command_native({ 'expand-path', o.blacklist_path })

local msg = require 'mp.msg'
local input_loaded, input = pcall(require, 'mp.input')
local uosc_available = false

local function osd(text, duration)
    mp.osd_message(text, duration or 2)
end

local function read_words()
    local words = {}
    local file = io.open(blacklist_file, 'r')
    if file then
        for line in file:lines() do
            line = line:match('^%s*(.-)%s*$')
            if line ~= '' then words[#words+1] = line end
        end
        file:close()
    end
    return words
end

local function write_words(words)
    local file = io.open(blacklist_file, 'w')
    if not file then
        osd(i18n.t('屏蔽词文件写入失败：') .. blacklist_file, 4)
        msg.error('无法写入屏蔽词文件: ' .. blacklist_file)
        return false
    end
    for _, word in ipairs(words) do
        file:write(word .. '\n')
    end
    file:close()
    return true
end

local function reload_engine()
    -- uosc_danmaku 在 parse.lua 里注册了 reload-blacklist 消息，即时生效。
    mp.commandv('script-message-to', 'uosc_danmaku', 'reload-blacklist')
end

local function add_word(text)
    text = (text or ''):match('^%s*(.-)%s*$')
    if text == '' then return end
    local words = read_words()
    for _, word in ipairs(words) do
        if word == text then
            osd(i18n.t('屏蔽词已存在：') .. text)
            return
        end
    end
    words[#words+1] = text
    if write_words(words) then
        reload_engine()
        osd(i18n.t('已添加屏蔽词：') .. text .. i18n.t('（弹幕已即时重载）'))
        msg.info('已添加屏蔽词: ' .. text)
    end
end

local function remove_word(word)
    local words = read_words()
    local kept = {}
    for _, item in ipairs(words) do
        if item ~= word then kept[#kept+1] = item end
    end
    if #kept == #words then return end
    if write_words(kept) then
        reload_engine()
        osd(i18n.t('已删除屏蔽词：') .. word .. i18n.t('（弹幕已即时重载）'))
        msg.info('已删除屏蔽词: ' .. word)
    end
end

local function prompt_add_word()
    if input_loaded and input.prompt then
        input.prompt({
            prompt = i18n.t('输入屏蔽词（支持 Lua 模式）：'),
            submit = function(text)
                add_word(text)
            end,
        })
    else
        osd(i18n.t('当前 mpv 不支持文本输入，请手动编辑：') .. blacklist_file, 4)
    end
end

local function open_menu_uosc()
    local items = {
        {
            title = i18n.t('＋ 添加屏蔽词'),
            hint = i18n.t('支持 Lua 模式'),
            value = { 'script-message-to', mp.get_script_name(), 'add-word-interactive' },
            keep_open = false,
            selectable = true,
        },
    }
    for _, word in ipairs(read_words()) do
        items[#items+1] = {
            title = word,
            hint = i18n.t('点击删除'),
            value = { 'script-message-to', mp.get_script_name(), 'remove-word', word },
            keep_open = true,
            selectable = true,
        }
    end
    local menu_props = {
        type = 'menu_blocklist',
        title = i18n.t('弹幕屏蔽词管理'),
        search_style = 'disabled',
        items = items,
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu_props))
end

local function open_menu_select()
    local words = read_words()
    local item_titles, item_values = {}, {}
    item_titles[#item_titles+1] = i18n.t('＋ 添加屏蔽词')
    item_values[#item_values+1] = 'add'
    for _, word in ipairs(words) do
        item_titles[#item_titles+1] = word
        item_values[#item_values+1] = word
    end
    if input_loaded and input.select then
        input.select({
            prompt = i18n.t('弹幕屏蔽词管理（选择词条删除）：'),
            items = item_titles,
            submit = function(id)
                local picked = item_values[id]
                if picked == 'add' then
                    prompt_add_word()
                else
                    remove_word(picked)
                end
            end,
        })
    else
        osd(i18n.t('无可用 UI，请手动编辑：') .. blacklist_file, 4)
    end
end

local function open_menu()
    -- uosc 可用性：优先听 uosc 启动广播，再探它发布的 user-data 属性
    -- （本脚本可能晚于广播加载，属性探测无竞态）。
    if uosc_available
        or mp.get_property('user-data/uosc/dock-animation-mode') ~= nil
        or mp.get_property('user-data/uosc/idle-branding') ~= nil then
        open_menu_uosc()
    else
        open_menu_select()
    end
end

mp.register_script_message('uosc-version', function()
    uosc_available = true
end)
mp.register_script_message('open-blocklist-menu', open_menu)
mp.register_script_message('add-word-interactive', prompt_add_word)
mp.register_script_message('remove-word', function(word)
    remove_word(word)
    open_menu()  -- 菜单 keep_open：删完刷新词条列表
end)
