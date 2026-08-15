local utils = require("mp.utils")
local options = require("mp.options")
local input_available, input = pcall(require, "mp.input")

local o = {
    enabled = true,
    path = "~~/recent.json",
    title = 'Recently played',
    length = 10,
    width = 88,
    ignore_same_series = true,
    reduce_io = false,
    keep_signed_urls = true,
}
options.read_options(o, _, function() end)

local path = mp.command_native({ "expand-path", o.path })

local uosc_available = false
local command_palette_available = false

local is_windows = package.config:sub(1, 1) == "\\" -- detect path separator, windows uses backslashes

local menu = {
    type = 'recent_menu',
    title = o.title,
    min_width_px = true,
    fixed_columns = true,
    items = {},
    item_actions = {
        {
            name = 'remove',
            icon = "delete",
            label = "Remove (del)",
        }
    },
    item_actions_place = "outside",
    callback = { mp.get_script_name(), "uosc-callback" }
}

local current_item = { nil, nil, nil }

function utf8_char_bytes(str, i)
    local char_byte = str:byte(i)
    if char_byte < 0xC0 then
        return 1
    elseif char_byte < 0xE0 then
        return 2
    elseif char_byte < 0xF0 then
        return 3
    elseif char_byte < 0xF8 then
        return 4
    else
        return 1
    end
end

function utf8_iter(str)
    local byte_start = 1
    return function()
        local start = byte_start
        if #str < start then return nil end
        local byte_count = utf8_char_bytes(str, start)
        byte_start = start + byte_count
        return start, str:sub(start, start + byte_count - 1)
    end
end

function utf8_to_table(str)
    local t = {}
    for _, ch in utf8_iter(str) do
        t[#t + 1] = ch
    end
    return t
end

function utf8_substring(str, indexStart, indexEnd)
    if indexStart > indexEnd then
        return str
    end

    local index = 1
    local substr = ""
    for _, char in utf8_iter(str) do
        if indexStart <= index and index <= indexEnd then
            local width = #char > 2 and 2 or 1
            index = index + width
            substr = substr .. char
        end
    end
    return substr, index
end

function jaro(s1, s2)
    local match_window = math.floor(math.max(#s1, #s2) / 2.0) - 1
    local matches1 = {}
    local matches2 = {}

    local m = 0;
    local t = 0;

    for i = 0, #s1, 1 do
        local start = math.max(0, i - match_window)
        local final = math.min(i + match_window + 1, #s2)

        for k = start, final, 1 do
            if not (matches2[k] or s1[i] ~= s2[k]) then
                matches1[i] = true
                matches2[k] = true
                m = m + 1
                break
            end
        end
    end

    if m == 0 then
        return 0.0
    end

    local k = 0
    for i = 0, #s1, 1 do
        if matches1[i] then
            while not matches2[k] do
                k = k + 1
            end

            if s1[i] ~= s2[k] then
                t = t + 1
            end

            k = k + 1
        end
    end

    t = t / 2.0

    return (m / #s1 + m / #s2 + (m - t) / m) / 3.0
end

function jaro_winkler_distance(s1, s2)
    if #s1 + #s2 == 0 then
        return 0.0
    end

    if s1 == s2 then
        return 1.0
    end

    s1 = utf8_to_table(s1)
    s2 = utf8_to_table(s2)

    local d = jaro(s1, s2)
    local p = 0.1
    local l = 0;
    while (s1[l] == s2[l] and l < 4) do
        l = l + 1
    end

    return d + l * p * (1 - d)
end

function split_path(path)
    -- return path, filename, extension
    return path:match("(.-)([^\\/]-)%.?([^%.\\/]*)$")
end

function strip_url_query(path)
    if type(path) ~= 'string' then return path end
    return path:gsub("[?#].*$", "")
end

function url_decode(str)
    return tostring(str or ""):gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

local signed_query_keys = {
    ['auth_key'] = true,
    ['expires'] = true,
    ['expiry'] = true,
    ['key-pair-id'] = true,
    ['policy'] = true,
    ['signature'] = true,
    ['sign'] = true,
    ['token'] = true,
    ['wssecret'] = true,
    ['wstime'] = true,
    ['x-amz-signature'] = true,
    ['x-oss-signature'] = true,
}

function is_temporary_signed_url(path)
    if type(path) ~= 'string' or not path:lower():find('^https?://') then
        return false
    end

    local query = path:match('%?([^#]*)')
    if not query then return false end

    for pair in query:gmatch('[^&;]+') do
        local key = pair:match('^([^=]+)')
        key = url_decode(key or ''):lower()
        if signed_query_keys[key] then return true end
    end
    return false
end

function is_disc_protocol(path)
    return type(path) == 'string' and (path:find("^bd://") ~= nil or path:find("^dvd://") ~= nil)
end

function is_iso_file(path)
    return type(path) == 'string' and path:lower():match("%.iso$") ~= nil
end

function get_disc_iso_path()
    local iso_path = mp.get_property("user-data/auto-iso-loader/original-path")
    if is_iso_file(iso_path) then return iso_path end

    local bd_dev = mp.get_property("bluray-device") or ""
    local dvd_dev = mp.get_property("dvd-device") or ""

    if is_iso_file(bd_dev) then return bd_dev end
    if is_iso_file(dvd_dev) then return dvd_dev end
    return nil
end

function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            path = mp.command_native({"normalize-path", path})
        else
            local directory = mp.get_property("working-directory", "")
            path = utils.join_path(directory, path:gsub('^%.[\\/]',''))
            if is_windows then path = path:gsub("\\", "/") end
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

function is_same_series(path1, path2)
    if not o.ignore_same_series then
        return false
    end

    local dir1, filename1, extension1 = split_path(path1)
    local dir2, filename2, extension2 = split_path(path2)

    -- don't remove files are not in same folder
    if dir1 ~= dir2 then
        return false
    end

    -- don't remove same filename but different extensions
    if filename1 == filename2 then
        return false
    end

    -- by episode
    local episode1 = filename1:gsub("^[%[%(]+.-[%]%)]+[%s%[]*", ""):match("(.-%D+)0*%d+")
    local episode2 = filename2:gsub("^[%[%(]+.-[%]%)]+[%s%[]*", ""):match("(.-%D+)0*%d+")
    if episode1 and episode2 and episode1 == episode2 then
        return true
    end

    -- by similarity
    local threshold = 0.8
    local similarity = jaro_winkler_distance(filename1, filename2)
    if similarity > threshold then
        return true
    end

    return false
end

function read_json(force, skip_clean)
    if o.reduce_io and not force then
        return
    end
    local meta, meta_error = utils.file_info(path)
    if not meta or not meta.is_file then
        menu.items = {}
        return
    end

    local json_file = io.open(path, "r")
    if not json_file then
        menu.items = {}
        return
    end

    local json = json_file:read("*all")
    json_file:close()

    menu.items = utils.parse_json(json) or {}
    local sanitized = sanitize_recent_items()
    if sanitized then
        write_json()
    end
end

function write_json(force)
    if o.reduce_io and not force then
        return
    end
    local json_file = io.open(path, "w")
    if not json_file then return end

    local json = utils.format_json(menu.items)

    json_file:write(json)
    json_file:close()

end

function trim_trailing_punctuation(str)
    if type(str) ~= 'string' then return str end
    while true do
        local trimmed = str:gsub("[%s%.%-%_/\\|:;,%+]+$", "")
        if trimmed == str then break end
        str = trimmed
    end
    return str
end

function strip_extension(filename)
    if type(filename) ~= 'string' then return filename end
    return filename:gsub('%.([^%./]+)$', '')
end

function is_bad_stream_title(title)
    if type(title) ~= 'string' or title == '' then return true end
    local lower = title:lower()
    return lower:find('^https?://') ~= nil
        or lower:find('link3%.cc') ~= nil
        or lower:find('yunpantv', 1, true) ~= nil
        or lower:find('clipboard/text', 1, true) ~= nil
end

function title_from_path(path)
    if type(path) ~= 'string' or path == '' then return nil end
    local display_path = is_protocol(path) and strip_url_query(path) or path
    local _, filename = split_path(display_path)
    filename = url_decode(filename or "")
    if filename == "" then return nil end
    return strip_extension(filename)
end

function get_alist_recent_title()
    local playing = mp.get_property_bool("user-data/alist/playing", false)
    if not playing then return nil end
    -- user-data string nodes are JSON-serialized by get_property(), which
    -- leaves a leading quote after strip_extension(). Native access returns
    -- the actual filename and keeps recent.json display titles clean.
    local name = mp.get_property_native("user-data/alist/name")
    if type(name) ~= "string" or name == "" then return nil end
    return strip_extension(name)
end

function get_safe_recent_title(path, title)
    local alist_title = get_alist_recent_title()
    if alist_title then return alist_title end

    if is_protocol(path) and is_bad_stream_title(title) then
        return title_from_path(path) or title
    end

    return title
end

function sanitize_recent_item(item)
    if type(item) ~= 'table' or type(item.value) ~= 'table' then return false end
    local command, item_path = item.value[1], item.value[2]
    if command ~= "loadfile" or type(item_path) ~= 'string' then return false end

    local path_title = title_from_path(item_path)
    if not path_title or path_title == "" or path_title == item.title then return false end

    local current_title = tostring(item.title or "")
    local has_serialized_alist_quote = current_title:sub(1, 1) == '"'
        and path_title:sub(1, 1) ~= '"'
        and current_title:sub(2) == path_title
    if has_serialized_alist_quote then
        item.title = path_title
        return true
    end

    local compare_current = trim_trailing_punctuation(current_title):gsub("^[\"']+", "")
    local compare_path = path_title:gsub("^[\"']+", "")
    local looks_truncated = #compare_current > 0
        and #compare_path > #compare_current
        and compare_path:sub(1, #compare_current) == compare_current

    -- Older versions permanently stored the character-count-clipped label in
    -- recent.json. Recover the real filename when that stored label is clearly
    -- a prefix, while preserving unrelated custom media titles.
    if not is_bad_stream_title(current_title) and not looks_truncated then return false end

    item.title = path_title
    return true
end

function sanitize_recent_items()
    local changed = false
    for _, item in ipairs(menu.items or {}) do
        if sanitize_recent_item(item) then
            changed = true
        end
    end
    return changed
end

function clip_recent_title(title)
    -- uosc measures the actual rendered pixel width and adds an ellipsis.
    -- Character-count clipping here caused a second, premature truncation
    -- without an ellipsis and permanently mixed visual title lengths.
    return title
end

function clip_uosc_menu_item(menu)
    local menu_items = {}
    for _, item in ipairs(menu.items) do
        local display_item = {}
        for k, v in pairs(item) do display_item[k] = v end
        display_item.title = clip_recent_title(item.title)
        table.insert(menu_items, display_item)
    end
    menu.items = menu_items
    return menu
end

function append_item(path, title, hint)
    local new_items = { { title = title, hint = hint, value = { "loadfile", path } } }
    read_json()
    for index, value in ipairs(menu.items) do
        local opath = value.value[2]
        if #new_items < o.length and
            path ~= opath and
            not is_same_series(path, opath)
        then
            new_items[#new_items + 1] = value
        end
    end
    menu.items = new_items
    write_json()
end

local function clamp(value, min_value, max_value)
    return math.max(min_value, math.min(max_value, value))
end

local function get_recent_menu_min_width()
    local osd_w = mp.get_osd_size()
    if type(osd_w) ~= 'number' or osd_w <= 0 then
        return nil
    end

    local ratio = 0.44
    local target = math.floor(osd_w * ratio)

    local min_w = math.floor(osd_w * 0.40)
    local max_w = math.floor(osd_w * 0.50)

    target = clamp(target, min_w, max_w)

    target = math.max(target, math.min(620, math.floor(osd_w * 0.72)))

    target = math.min(target, osd_w - math.floor(osd_w * 0.18))

    return target
end

local function get_meta_safe_gap(menu_width)
    if type(menu_width) ~= 'number' or menu_width <= 0 then
        return 8
    end
    return clamp(math.floor(menu_width * 0.010), 6, 12)
end

function remove_item(index)
    table.remove(menu.items, index)
    clip_uosc_menu_item(menu)
    local min_width = get_recent_menu_min_width()
    if min_width then menu.min_width = min_width end
    local json = utils.format_json(menu)
    mp.commandv('script-message-to', 'uosc', 'update-menu', json)
    write_json()
end

function open_menu_uosc()
    clip_uosc_menu_item(menu)
    local min_width = get_recent_menu_min_width()
    if min_width then menu.min_width = min_width end
    local json = utils.format_json(menu)
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end

function open_menu_command_palette()
    local json = utils.format_json(menu)
    mp.commandv('script-message-to',
        'command_palette',
        'show-command-palette-json', json)
end

function open_menu_select()
    local item_titles, item_values = {}, {}
    for i, v in ipairs(menu.items) do
        item_titles[i] = v.title
        item_values[i] = v.value
    end
    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = menu.title .. ':',
        items = item_titles,
        submit = function(id)
            mp.commandv(unpack(item_values[id]))
        end,
    })
end

function update_recent_menu_width()
    local osd_w = mp.get_osd_size()
    if type(osd_w) ~= 'number' or osd_w <= 0 then return end

    local min_width = get_recent_menu_min_width()
    if not min_width then return end

    -- title pixel budget: reserve less for hint+padding so o.width stays generous
    -- even when the menu is narrow (smaller gap, same filename display)
    local safe_gap = get_meta_safe_gap(min_width)
    local title_px = min_width - 160 - safe_gap
    o.width = math.max(85, 30 + math.floor(title_px / 8))
end

function open_menu()
    update_recent_menu_width()
    read_json(false, true)
    if uosc_available then
        open_menu_uosc()
    elseif input_available then
        open_menu_select()
    elseif command_palette_available then
        open_menu_command_palette()
    else
        mp.msg.warn("No menu providers available")
    end
end

function play_last()
    read_json()
    if menu.items[1] then
        mp.command_native(menu.items[1].value)
    end
end
mp.add_key_binding(nil, "open", open_menu)
mp.add_key_binding(nil, "last", play_last)

mp.register_script_message('open-recent-menu', function(provider)
    if provider == nil then
        open_menu()
    elseif provider == "uosc" then
        open_menu_uosc()
    elseif provider == "command-palette" then
        open_menu_command_palette()
    elseif provider == "select" then
        open_menu_select()
    else
        mp.msg.warn(provider .. " not available")
    end
end)

mp.register_script_message('uosc-version', function()
    uosc_available = true
end)
mp.register_script_message('uosc-callback', function(json)
    local event = utils.parse_json(json)

    if event.type == "activate" and not event.action then
        mp.command_native(event.value)
        mp.commandv('script-message-to', 'uosc', 'close-menu', menu.type)
        return
    end

    if event.type == "activate" and event.action == "remove" then
        remove_item(event.index)
        return
    end

    if event.type == "key" and event.id == "del" then
        remove_item(event.selected_item.index)
        return
    end
end)

mp.register_script_message('command-palette-version', function()
    command_palette_available = true
end)

if o.reduce_io then
    read_json(true)
    mp.register_event("shutdown", function (e)
        write_json(true)
    end)
end
function on_load()
    current_item = { nil, nil, nil }
    if not o.enabled then return end
    local path = mp.get_property("path")
    if is_disc_protocol(path) or not path then
        path = get_disc_iso_path() or path
    end
    if not path then return end
    if not is_protocol(path) then path = normalize(path) end
    if not o.keep_signed_urls and is_temporary_signed_url(path) then
        mp.msg.info('Skipping temporary signed URL in recent menu')
        return
    end
    local display_path = is_protocol(path) and strip_url_query(path) or path
    local dir, filename, extension = split_path(display_path)
    local title = mp.get_property("media-title")
    if title then title = title:gsub('%.([^%./]+)$', '') end
    title = get_safe_recent_title(path, title)
    local hint = os.date("%m/%d %H:%M")
    if is_protocol(path) then
        local scheme = path:match("^(%a[%w.+-]-)://")
        if scheme == "bd" or
            scheme == "dvd" or
            scheme == "dvb" or
            scheme == "cdda" or
            path:match("^av://lavfi")
        then
            return
        end
        if not title or title == "" then
            title = title_from_path(path) or path
        end
        hint = scheme .. " | " .. hint
    else
        if not title or #utf8_to_table(title) < #utf8_to_table(filename) then
            title = filename
        end
        hint = extension .. " | " .. hint
    end
    hint = hint:upper()
    current_item = { path, title, hint }
    append_item(unpack(current_item))
end

function on_end(e)
    if not (e and e.reason and e.reason == "quit") then
        return
    end
    if not current_item[1] then
        return
    end
    append_item(unpack(current_item))
end

mp.register_event("file-loaded", on_load)
mp.register_event("end-file", on_end)
