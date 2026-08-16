local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    mode = 'loop',
    show_osd = true,
}
options.read_options(o, 'music_mode')

local config_path = mp.command_native({
    'expand-path',
    '~~/script-opts/music_mode.conf',
})

local overlay = mp.create_osd_overlay('ass-events')
overlay.z = 2100
local overlay_timer = nil
local evaluate_timer = nil
local loop_owned = false
local saved_loop_playlist = nil
local loop_file_owned = false
local saved_loop_file = nil
local active = false
local last_announced_mode = nil
local random_playlist_signature = nil
local random_pending = {}
local random_played = {}
local random_seeded = false

local audio_extensions = {
    mp3 = true, flac = true, wav = true, wave = true, m4a = true,
    aac = true, ogg = true, oga = true, opus = true, ape = true,
    wv = true, wma = true, alac = true, aiff = true, aif = true,
    dsf = true, dff = true, mka = true, tak = true, tta = true,
    mid = true, midi = true,
}

local modes = {
    off = '关闭',
    loop = '列表循环',
    single = '单曲循环',
    random = '随机循环',
}

local function normalize_mode(mode)
    mode = tostring(mode or ''):lower()
    if mode == 'background' then return 'loop' end
    return modes[mode] and mode or 'loop'
end

local function ass_escape(value)
    return tostring(value or '')
        :gsub('\\', '\\\\')
        :gsub('{', '\\{')
        :gsub('}', '\\}')
        :gsub('\n', '\\N')
end

local function mode_label(mode)
    return modes[mode] or modes.loop
end

local function mode_detail(mode)
    if mode == 'random' then return '随机防重复' end
    if mode == 'single' then return '单曲循环' end
    if mode == 'loop' then return '列表循环' end
    return '已关闭'
end

local function osd_text_for_mode(mode)
    if mode == 'off' then return '已退出音乐模式' end
    return '已进入音乐模式 · ' .. mode_detail(mode)
end

local function osd_parts_for_mode(mode)
    if mode == 'off' then return '已退出音乐模式', nil end
    return '已进入音乐模式', mode_detail(mode)
end

local function publish_state(is_active, mode)
    mp.set_property('user-data/music-mode/mode', mode)
    mp.set_property('user-data/music-mode/label', mode_label(mode))
    mp.set_property('user-data/music-mode/detail', is_active and mode_detail(mode) or '等待音乐文件')
    mp.set_property('user-data/music-mode/active', is_active and 'yes' or 'no')
    mp.set_property('user-data/music-mode/minimize-bypass', is_active and mode ~= 'off' and 'yes' or 'no')
    mp.set_property('user-data/music-mode/random-nav', is_active and mode == 'random' and 'yes' or 'no')
end

local function hide_overlay()
    if overlay_timer then
        overlay_timer:kill()
        overlay_timer = nil
    end
    overlay.data = ''
    overlay:update()
end

local function show_music_osd(mode)
    if not o.show_osd then return end

    if overlay_timer then
        overlay_timer:kill()
        overlay_timer = nil
    end

    local width, height = mp.get_osd_size()
    if not width or width <= 0 or not height or height <= 0 then
        mp.osd_message(osd_text_for_mode(mode), 2.4)
        return
    end

    local scale = mp.get_property_number('display-hidpi-scale', 1)
    local y = math.max(math.floor(48 * scale + 0.5), height - math.floor(150 * scale + 0.5))
    local font_size = math.max(19, math.floor(20 * scale + 0.5))

    local prefix, suffix = osd_parts_for_mode(mode)
    local text = suffix
        and string.format(
            '{\\c&HFAB489&}%s{\\c&HC8ADA6&} · {\\c&HF7A6CB&}%s',
            ass_escape(prefix),
            ass_escape(suffix)
        )
        or ('{\\c&HFAB489&}' .. ass_escape(prefix))

    overlay.res_x = width
    overlay.res_y = height
    overlay.data = string.format(
        '{\\an2\\pos(%d,%d)\\fs%d\\b1\\3c&H1B1111&'
            .. '\\3a&H25&\\bord%d\\blur0.4\\shad0}%s',
        math.floor(width / 2),
        y,
        font_size,
        math.max(2, math.floor(2.2 * scale + 0.5)),
        text
    )
    overlay:update()
    overlay_timer = mp.add_timeout(2.4, hide_overlay)
end

local function has_real_video()
    local vid = mp.get_property_native('vid')
    if not vid or vid == 'no' then return false end
    local track = mp.get_property_native('current-tracks/video')
    return not (track and track.albumart)
end

local function has_audio()
    local aid = mp.get_property_native('aid')
    if aid and aid ~= 'no' then return true end
    local track = mp.get_property_native('current-tracks/audio')
    return track ~= nil
end

local function path_ext(path)
    path = tostring(path or ''):gsub('[?#].*$', ''):lower()
    return path:match('%.([%w%d]+)$')
end

local function is_audio_only()
    local path = mp.get_property('path', '')
    if path == '' then return false end
    if has_real_video() then return false end
    local ext = path_ext(path)
    if ext and audio_extensions[ext] then return true end
    return has_audio()
end

local function restore_loop_playlist()
    if loop_owned then
        mp.set_property('loop-playlist', saved_loop_playlist or 'no')
    end
    loop_owned = false
    saved_loop_playlist = nil
end

local function ensure_loop_playlist()
    if not loop_owned then
        saved_loop_playlist = mp.get_property('loop-playlist', 'no')
        loop_owned = true
    end
    if mp.get_property('loop-playlist', 'no') ~= 'inf' then
        mp.set_property('loop-playlist', 'inf')
    end
end

local function restore_loop_file()
    if loop_file_owned then
        mp.set_property('loop-file', saved_loop_file or 'no')
    end
    loop_file_owned = false
    saved_loop_file = nil
end

local function ensure_loop_file()
    if not loop_file_owned then
        saved_loop_file = mp.get_property('loop-file', 'no')
        loop_file_owned = true
    end
    if mp.get_property('loop-file', 'no') ~= 'inf' then
        mp.set_property('loop-file', 'inf')
    end
end

local function playlist_signature()
    local playlist = mp.get_property_native('playlist') or {}
    local paths = {}
    for index, item in ipairs(playlist) do
        if item.filename then
            paths[#paths + 1] = tostring(index) .. ':' .. tostring(item.filename)
        end
    end
    return table.concat(paths, '\n')
end

local function playlist_entry_key(entry)
    return tostring(entry.id or entry.filename or entry.pos)
end

local function entry_is_audio(entry)
    local ext = path_ext(entry.filename)
    return ext and audio_extensions[ext] or false
end

local function fisher_yates_shuffle(list)
    if not random_seeded then
        math.randomseed(os.time())
        random_seeded = true
    end
    for index = #list, 2, -1 do
        local swap_index = math.random(index)
        list[index], list[swap_index] = list[swap_index], list[index]
    end
end

local function get_playlist_entries()
    local playlist = mp.get_property_native('playlist') or {}
    local entries = {}
    for index, item in ipairs(playlist) do
        local entry = {
            pos = index - 1,
            id = item.id,
            filename = item.filename,
        }
        entry.key = playlist_entry_key(entry)
        if entry.filename and entry_is_audio(entry) then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function reset_random_queue()
    random_pending = {}
    random_played = {}
end

local function current_playlist_entry()
    local pos = mp.get_property_number('playlist-pos', -1)
    local playlist = mp.get_property_native('playlist') or {}
    local item = playlist[pos + 1]
    if not item or not item.filename then return nil end
    local entry = {
        pos = pos,
        id = item.id,
        filename = item.filename,
    }
    entry.key = playlist_entry_key(entry)
    return entry
end

local function remove_pending_key(key)
    for index = #random_pending, 1, -1 do
        if random_pending[index].key == key then
            table.remove(random_pending, index)
        end
    end
end

local function mark_entry_played(entry)
    if not entry then return end
    random_played[entry.key] = true
    remove_pending_key(entry.key)
end

local function mark_current_played()
    mark_entry_played(current_playlist_entry())
end

local function ensure_random_queue()
    local signature = playlist_signature()
    if signature ~= random_playlist_signature then
        random_playlist_signature = signature
        reset_random_queue()
        mark_current_played(false)
    end
    if #random_pending > 0 then return end

    local current_pos = mp.get_property_number('playlist-pos', -1)
    local entries = get_playlist_entries()
    local candidates = {}
    for _, entry in ipairs(entries) do
        if entry.pos ~= current_pos and not random_played[entry.key] then
            candidates[#candidates + 1] = entry
        end
    end

    if #candidates == 0 and #entries > 1 then
        random_played = {}
        mark_current_played(false)
        for _, entry in ipairs(entries) do
            if entry.pos ~= current_pos then
                candidates[#candidates + 1] = entry
            end
        end
    end

    fisher_yates_shuffle(candidates)
    random_pending = candidates
end

local function play_random_next()
    if normalize_mode(o.mode) ~= 'random' then return end
    mark_current_played()
    ensure_random_queue()
    local next_entry = table.remove(random_pending, 1)
    if next_entry then
        mp.commandv('playlist-play-index', tostring(next_entry.pos))
    end
end

local function evaluate(show_enter_osd)
    local mode = normalize_mode(o.mode)
    local is_active = mode ~= 'off' and is_audio_only()

    if is_active and mode == 'single' then
        restore_loop_playlist()
        ensure_loop_file()
    elseif is_active and (mode == 'loop' or mode == 'random') then
        restore_loop_file()
        ensure_loop_playlist()
        if mode == 'random' then
            mark_current_played()
            ensure_random_queue()
        end
    else
        restore_loop_playlist()
        restore_loop_file()
        if not is_active then
            random_playlist_signature = nil
            reset_random_queue()
        end
    end

    active = is_active
    publish_state(is_active, mode)

    if is_active and (show_enter_osd or last_announced_mode ~= mode) then
        show_music_osd(mode)
        last_announced_mode = mode
    elseif not is_active then
        last_announced_mode = nil
    end
end

local function schedule_evaluate(show_enter_osd, delay)
    if evaluate_timer then
        evaluate_timer:kill()
        evaluate_timer = nil
    end
    evaluate_timer = mp.add_timeout(delay or 0.05, function()
        evaluate_timer = nil
        evaluate(show_enter_osd)
    end)
end

local function persist_mode(mode)
    local file = config_path and io.open(config_path, 'wb')
    if not file then
        msg.error('无法保存音乐模式：' .. tostring(config_path))
        return false
    end
    file:write(
        '# 音乐模式：off/loop/single/random\n'
            .. '# loop=列表循环，single=单曲循环，random=随机防重复。\n'
            .. '# 通过“杳知 > 音乐模式”维护。\n'
            .. string.format('mode=%s\n', mode)
            .. string.format('show_osd=%s\n', o.show_osd and 'yes' or 'no')
    )
    file:close()
    return true
end

mp.register_script_message('set', function(mode)
    mode = normalize_mode(mode)
    o.mode = mode
    persist_mode(mode)
    publish_state(active, mode)
    if mode == 'off' then
        restore_loop_playlist()
        restore_loop_file()
        show_music_osd(mode)
    end
    schedule_evaluate(true, 0)
end)

mp.register_script_message('toggle', function()
    local order = {loop = 'random', random = 'single', single = 'off', off = 'loop'}
    local mode = order[normalize_mode(o.mode)] or 'loop'
    o.mode = mode
    persist_mode(mode)
    schedule_evaluate(true, 0)
end)

mp.register_event('start-file', function()
    schedule_evaluate(false, 0.05)
end)

mp.register_event('file-loaded', function()
    schedule_evaluate(true, 0.15)
end)

mp.register_event('end-file', function(event)
    local mode = normalize_mode(o.mode)
    local was_random = active and mode == 'random' and event and event.reason == 'eof'
    active = false
    publish_state(false, normalize_mode(o.mode))
    if was_random then
        play_random_next()
    end
end)

mp.observe_property('idle-active', 'bool', function(_, idle)
    if idle then
        active = false
        restore_loop_playlist()
        restore_loop_file()
        publish_state(false, normalize_mode(o.mode))
    end
end)

mp.observe_property('playlist-count', 'number', function()
    schedule_evaluate(false, 0.1)
end)

mp.observe_property('current-tracks/video', 'native', function()
    schedule_evaluate(false, 0.1)
end)

mp.observe_property('current-tracks/audio', 'native', function()
    schedule_evaluate(false, 0.1)
end)

mp.register_event('shutdown', function()
    hide_overlay()
    restore_loop_playlist()
    restore_loop_file()
end)

schedule_evaluate(false, 0)
