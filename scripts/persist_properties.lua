local i18n = dofile(require("mp").command_native({"expand-path", "~~/script-modules/yaozhi-i18n.lua"}))
-- Script home: https://github.com/d87/mpv-persist-properties
local utils = require "mp.utils"
local msg = require "mp.msg"
local persistence = dofile(mp.command_native({'expand-path', '~~/script-modules/yaozhi-persistence.lua'}))

local opts = {
    properties = "volume,sub-scale",
    properties_path = 'persistent_config.json'
}
(require 'mp.options').read_options(opts, "persist_properties")

local CONFIG_ROOT = mp.find_config_file(".")
if not utils.file_info(CONFIG_ROOT) then
    -- On Windows if using portable_config dir, APPDATA mpv folder isn't auto-created
    -- In more recent mpv versions there's a mp.get_script_directory function, but i'm not using it for compatiblity
    local mpv_conf_path = mp.find_config_file("scripts") -- finds where the scripts folder is located
    local mpv_conf_dir = utils.split_path(mpv_conf_path)
    CONFIG_ROOT = mpv_conf_dir
end
local PCONFIG = utils.join_path(CONFIG_ROOT, opts.properties_path);

local function split(input)
    local ret = {}
    for str in string.gmatch(input, "([^,]+)") do
        table.insert(ret, str)
    end
    return ret
end
local persisted_properties = split(opts.properties)

local print = function(...)
    -- return msg.log("info", ...)
end

-- print("Config Root is "..CONFIG_ROOT)

local isInitialized = false

local properties = {}
local dirty = {}
local save_timer = nil
local got_unsaved_changed = false

local function decode_properties(bytes)
    if type(bytes) ~= 'string' then return nil end
    bytes = bytes:gsub('^\239\187\191', '')
    if not bytes:match('^%s*{') then return nil end
    local value = utils.parse_json(bytes)
    return type(value) == 'table' and value or nil
end

local function load_config(file)
    local bytes, err, code = persistence.read(file)
    if bytes then
        local result = decode_properties(bytes)
        if result then return result end
        msg.error('持久化配置格式无效，已保留原文件')
    elseif code ~= 'missing' then
        msg.error('持久化配置读取失败，已保留原文件：' .. tostring(err))
    end
    return {}
end

local function save_config(file)
    if not next(dirty) then return true end
    local ok, err = persistence.update(file, function(previous, missing)
        local latest = missing and {} or decode_properties(previous)
        if not latest then return nil, 'Existing properties are not a valid JSON object' end
        -- Only observed changes belong to this instance. Never write its stale
        -- snapshot over settings changed by a different player process.
        for name in pairs(dirty) do latest[name] = properties[name] end
        return utils.format_json(latest)
    end)
    if ok then
        dirty = {}
        got_unsaved_changed = false
        if err then msg.warn(tostring(err)) end
    else
        got_unsaved_changed = true
        msg.error('持久化设置保存失败，原文件已保留：' .. tostring(err))
        mp.osd_message(i18n.t('播放设置本次未保存，原配置已保留'), 4)
    end
    return ok == true
end

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function onInitialLoad()
    properties = load_config(PCONFIG)

    for i, property in ipairs(persisted_properties) do
        local name = property
        local value = properties[name]
        if value ~= nil then
            mp.set_property_native(name, value)
        end
    end

    for i, property in ipairs(persisted_properties) do
        properties[property] = mp.get_property_native(property)
        local property_type = nil
        mp.observe_property(property, property_type, function(name)
            if isInitialized then
                local value = mp.get_property_native(name)
                -- print(string.format("%s changed to %s at %s", name, value,  os.time()))

                if equal(properties[name], value) then return end
                properties[name] = value
                dirty[name] = true
                got_unsaved_changed = true

                if save_timer then
                    save_timer:kill()
                    save_timer:resume()
                    got_unsaved_changed = true
                else
                    save_timer = mp.add_timeout(5, function()
                        save_config(PCONFIG)
                    end)
                end
            end
        end)
    end

    isInitialized = true
end

onInitialLoad()
mp.register_event("shutdown", function()
    if got_unsaved_changed then
        save_config(PCONFIG)
    end
end)
