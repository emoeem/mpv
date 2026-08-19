-- Keep explicit audio-track and subtitle-position choices only while moving
-- through the same episode group. A different playlist/directory, a standalone
-- title, or a new mpv process starts from the normal configured defaults.

local msg = require 'mp.msg'

local preference = nil
local current_group = nil
local pending_group = nil
local pending_preference_matched = false
local file_active = false
local generation = 0
local arm_timer = nil
local disable_audio_timer = nil
local last_stable_aid = nil
local last_sub_pos = nil
local last_speed = nil

local function kill_timer(timer)
    if timer then timer:kill() end
end

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$')
end

local function normalize_text(value)
    return trim(value):lower():gsub('%s+', ' ')
end

local function normalize_aid(value)
    if value == false or value == 'no' then return 'no' end
    if value == nil then return '' end
    return tostring(value)
end

local function canonical_path(path)
    path = trim(path)
    if path == '' then return nil end

    path = path:gsub('[?#].*$', '')
    if not path:match('^%a[%w.+-]-://') and not path:match('^%a[%w.+-]-:%?') then
        local ok, expanded = pcall(mp.command_native, {'expand-path', path})
        if ok and type(expanded) == 'string' and expanded ~= '' then path = expanded end
    end

    path = path:gsub('\\', '/'):gsub('/+$', '')
    if path:match('^%a:/') or path:match('^//') then path = path:lower() end
    return path ~= '' and path or nil
end

local function parent_key(path)
    path = canonical_path(path)
    if not path then return nil end
    local parent = path:match('^(.*)/[^/]+$')
    if not parent or parent == '' or parent:match('^%a:$')
        or parent:match('^%a[%w.+-]-://[^/]+$')
    then
        return nil
    end
    return parent
end

local function playlist_signature()
    local count = tonumber(mp.get_property_native('playlist-count')) or 0
    if count <= 1 then return nil end

    local paths = {}
    for index = 0, count - 1 do
        local path = canonical_path(mp.get_property('playlist/' .. index .. '/filename', ''))
        if not path then return nil end
        paths[#paths + 1] = path
    end
    table.sort(paths)
    return table.concat(paths, '\n')
end

local function current_episode_group()
    local group = {
        parent = parent_key(mp.get_property('path', '')),
        playlist = playlist_signature(),
    }
    if not group.parent and not group.playlist then return nil end
    return group
end

local function same_group(saved, candidate)
    if not saved or not candidate then return false end
    if saved.playlist then return candidate.playlist == saved.playlist end
    if candidate.playlist then
        return saved.parent ~= nil and saved.parent == candidate.parent
    end
    return saved.parent ~= nil and saved.parent == candidate.parent
end

local function canonical_language(value)
    local lang = normalize_text(value)
    if lang == '' then return '' end
    if lang:match('^zh') or lang == 'chi' or lang == 'zho' or lang == 'chs'
        or lang == 'cht' or lang == 'chinese'
    then
        return 'zh'
    elseif lang == 'en' or lang == 'eng' or lang == 'english' then
        return 'en'
    elseif lang == 'ja' or lang == 'jpn' or lang == 'japanese' then
        return 'ja'
    end
    return lang
end

local function normalized_track_title(track)
    local title = normalize_text(track and track.title)
    local filename = normalize_text(mp.get_property('filename/no-ext', ''))
    if title ~= '' and filename ~= '' then
        local first, last = title:find(filename, 1, true)
        if first then
            title = normalize_text(title:sub(1, first - 1) .. ' ' .. title:sub(last + 1))
        end
    end
    return title
end

local function audio_tracks()
    local result = {}
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'audio' and track.codec ~= 'null' then
            result[#result + 1] = track
        end
    end
    return result
end

local function audio_signature(aid)
    aid = tostring(aid or '')
    local ordinal = 0
    for _, track in ipairs(audio_tracks()) do
        ordinal = ordinal + 1
        if tostring(track.id) == aid then
            return {
                id = aid,
                ordinal = ordinal,
                lang = canonical_language(track.lang),
                title = normalized_track_title(track),
                codec = normalize_text(track.codec),
                channels = tonumber(track['demux-channel-count'] or track['audio-channels']),
                external = track.external == true,
            }
        end
    end
    return nil
end

local function find_matching_audio(saved)
    if not saved then return nil end
    if saved.disabled then return 'no' end

    local best_id, best_score = nil, -math.huge
    local ordinal = 0
    for _, track in ipairs(audio_tracks()) do
        ordinal = ordinal + 1
        local lang = canonical_language(track.lang)
        local title = normalized_track_title(track)
        local external = track.external == true
        local eligible = external == saved.external

        if saved.title ~= '' then eligible = eligible and title == saved.title end
        if saved.lang ~= '' then eligible = eligible and lang == saved.lang end
        if saved.title == '' and saved.lang == '' then eligible = eligible and ordinal == saved.ordinal end

        if eligible then
            local score = 0
            if title ~= '' and title == saved.title then score = score + 100 end
            if lang ~= '' and lang == saved.lang then score = score + 40 end
            if normalize_text(track.codec) == saved.codec then score = score + 20 end
            local channels = tonumber(track['demux-channel-count'] or track['audio-channels'])
            if channels and channels == saved.channels then score = score + 10 end
            if ordinal == saved.ordinal then score = score + 5 end
            if tostring(track.id) == saved.id then score = score + 2 end
            if score > best_score then
                best_id, best_score = tostring(track.id), score
            end
        end
    end
    return best_id
end

local function ensure_preference()
    local group = current_episode_group() or current_group
    if not group then return nil end
    if not preference or not same_group(preference.group, group) then
        preference = {group = group}
    elseif not preference.group.playlist and group.playlist then
        preference.group = group
    end
    return preference
end

local function remember_audio(aid)
    local saved = ensure_preference()
    if not saved then return end
    if tostring(aid) == 'no' then
        saved.audio = {disabled = true}
        msg.verbose('remembered disabled audio for the current episode group')
        return
    end

    local signature = audio_signature(aid)
    if signature then
        saved.audio = signature
        msg.verbose('remembered manual audio track for the current episode group')
    end
end

local function cancel_disable_audio_timer()
    kill_timer(disable_audio_timer)
    disable_audio_timer = nil
end

local function on_aid_change(_, value)
    if not file_active then return end
    local aid = normalize_aid(value)
    if aid == '' then return end

    if aid == 'no' then
        cancel_disable_audio_timer()
        local expected_generation = generation
        disable_audio_timer = mp.add_timeout(0.20, function()
            disable_audio_timer = nil
            if file_active and generation == expected_generation
                and normalize_aid(mp.get_property_native('aid')) == 'no'
            then
                last_stable_aid = 'no'
                remember_audio('no')
            end
        end)
        return
    end

    local had_pending_disable = disable_audio_timer ~= nil
    cancel_disable_audio_timer()
    if aid == tostring(last_stable_aid or '') then return end
    last_stable_aid = aid
    if had_pending_disable or aid ~= '' then remember_audio(aid) end
end

local function on_sub_pos_change(_, value)
    value = tonumber(value)
    if not file_active or not value then return end
    if last_sub_pos ~= nil and math.abs(value - last_sub_pos) < 0.0001 then return end
    last_sub_pos = value
    local saved = ensure_preference()
    if saved then
        saved.sub_pos = value
        msg.verbose('remembered manual subtitle position for the current episode group')
    end
end

local function deactivate_file()
    generation = generation + 1
    file_active = false
    kill_timer(arm_timer)
    arm_timer = nil
    cancel_disable_audio_timer()
    last_stable_aid = nil
    last_sub_pos = nil
    last_speed = nil
end

local function on_preloaded()
    deactivate_file()
    pending_group = current_episode_group()
    pending_preference_matched = preference ~= nil
        and same_group(preference.group, pending_group)

    if preference and not pending_preference_matched then preference = nil end
    if not preference then return end

    if not preference.group.playlist and pending_group and pending_group.playlist then
        preference.group = pending_group
    end

    local aid = find_matching_audio(preference.audio)
    if aid then mp.set_property('file-local-options/aid', aid) end
    if preference.sub_pos ~= nil then
        mp.set_property('file-local-options/sub-pos', tostring(preference.sub_pos))
    end
    if preference.speed ~= nil then
        mp.set_property('file-local-options/speed', tostring(preference.speed))
    end
end

local function on_file_loaded()
    current_group = current_episode_group() or pending_group
    if preference then
        if pending_preference_matched and current_group then
            preference.group = current_group
        elseif not same_group(preference.group, current_group) then
            preference = nil
        end
    end

    local expected_generation = generation
    arm_timer = mp.add_timeout(0.20, function()
        arm_timer = nil
        if generation ~= expected_generation then return end
        current_group = current_episode_group() or current_group
        if preference and pending_preference_matched and current_group then
            preference.group = current_group
        end
        last_stable_aid = normalize_aid(mp.get_property_native('aid'))
        last_sub_pos = tonumber(mp.get_property_native('sub-pos'))
        last_speed = tonumber(mp.get_property_native('speed'))
        file_active = true
    end)
end

local function on_speed_change(_, value)
    value = tonumber(value)
    if not file_active or not value then return end
    if last_speed ~= nil and math.abs(value - last_speed) < 0.0001 then return end
    last_speed = value
    local saved = ensure_preference()
    if saved then saved.speed = value end
end

mp.observe_property('aid', 'native', on_aid_change)
mp.observe_property('sub-pos', 'number', on_sub_pos_change)
mp.observe_property('speed', 'number', on_speed_change)
mp.add_hook('on_preloaded', 40, on_preloaded)
mp.add_hook('on_unload', 40, deactivate_file)
mp.register_event('file-loaded', on_file_loaded)
