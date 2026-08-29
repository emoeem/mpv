-- Professional startup format logos for mpv.
-- Shows at most one picture-standard logo and one audio-standard logo.

local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'
local logo_bounds = dofile(mp.command_native({
    'expand-path', '~~/script-modules/startup-logo-bounds.lua',
}))

local o = {
    enabled = true,
    show_video = true,
    show_audio = true,
    show_sdr = true,
    show_common_audio = true,
    require_video = false,
    filename_fallback = true,
    show_on_audio_change = true,
    position = 'top-right',
    anchor_to_video = true,
    detect_encoded_bars = true,
    encoded_bar_threshold = 16,
    encoded_bar_delay = 0,
    encoded_bar_samples = 3,
    encoded_bar_sample_interval = 0.22,
    encoded_bar_followup_delay = 2.5,
    encoded_bar_followup_interval = 1.5,
    encoded_bar_followup_samples = 3,
    scale = 1.0,
    portrait_scale = 1.18,
    margin_x = 60,
    margin_y = 38,
    delay = 0,
    hold = 4.0,
    frame_wait_timeout = 5.0,
    fade_in = 0.12,
    fade_out = 0.18,
    retry_interval = 0.25,
    retry_count = 8,
    style = 'color',
    video_priority = 'dolby-vision,hdr-vivid,hdr10-plus,hdr10,hlg,sdr',
    audio_priority = 'dolby-atmos,dts-x,audio-vivid,dolby-truehd,dts-hd-ma,dts-hd-hra,dolby-digital-plus,dolby-digital,dts,ac4,mpeg-h,dra,flac,alac,pcm,mlp,wavpack,ape,wma,opus,aac,vorbis,mp3',
    asset_dir = '~~/script-assets/startup-format-logos/runtime',
    overlay_id = 50,
}

options.read_options(o, 'startup_format_logos')

local function normalize_style(value)
    return tostring(value or ''):lower() == 'white' and 'white' or 'color'
end

o.style = normalize_style(o.style)

local state = {
    loaded = false,
    file_generation = 0,
    display_generation = 0,
    timers = {},
    visible = false,
    overlays_present = false,
    opacity_index = 0,
    current = nil,
    last_aid = nil,
    frame_ready = false,
    waiting_for_frame = false,
    content_insets = nil,
    bar_anchor_locked = false,
    bar_request = nil,
    overlay_error_logged = false,
}

local asset_root = nil
local manifest = nil
local levels = nil
local overlay_base = math.floor(tonumber(o.overlay_id) or 50)
local config_path = mp.command_native({
    'expand-path', '~~/script-opts/startup_format_logos.conf',
})


local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end


local function round(value)
    return math.floor(value + 0.5)
end


local function number_option(value, fallback)
    local number = tonumber(value)
    if number == nil then return fallback end
    return number
end


local function stop_timer(name)
    local timer = state.timers[name]
    if timer then
        timer:kill()
        state.timers[name] = nil
    end
end


local function schedule(name, delay, callback)
    stop_timer(name)
    local timer
    timer = mp.add_timeout(math.max(0, tonumber(delay) or 0), function()
        if state.timers[name] == timer then
            state.timers[name] = nil
        end
        callback()
    end)
    state.timers[name] = timer
end


local function join_path(root, child)
    return utils.join_path(root, child)
end


local function read_text_file(path)
    local handle, err = io.open(path, 'rb')
    if not handle then return nil, err end
    local content = handle:read('*a')
    handle:close()
    return content
end


local function persist_option(name, value)
    local handle = io.open(config_path, 'rb')
    local content = handle and handle:read('*a') or ''
    if handle then handle:close() end

    local escaped_name = tostring(name):gsub('([^%w])', '%%%1')
    local serialized = tostring(value)
    local replaced
    content, replaced = content:gsub(
        '^([ \t]*' .. escaped_name .. '[ \t]*=)[^\r\n]*',
        '%1' .. serialized,
        1
    )
    if replaced == 0 then
        content, replaced = content:gsub(
            '(\r?\n)([ \t]*' .. escaped_name .. '[ \t]*=)[^\r\n]*',
            '%1%2' .. serialized,
            1
        )
    end
    if replaced == 0 then
        content = tostring(name) .. '=' .. serialized .. '\n' .. content
    end

    handle = io.open(config_path, 'wb')
    if not handle then
        msg.error('Unable to persist startup logo setting: ' .. tostring(config_path))
        return false
    end
    handle:write(content)
    handle:close()
    return true
end


local function load_assets()
    asset_root = mp.command_native({'expand-path', o.asset_dir})
    if not asset_root or asset_root == '' then
        msg.error('Unable to expand startup logo asset directory')
        return false
    end

    local raw, read_err = read_text_file(join_path(asset_root, 'manifest.json'))
    if not raw then
        msg.error('Unable to read startup logo manifest: ' .. tostring(read_err))
        return false
    end

    local parsed, parse_err = utils.parse_json(raw)
    if type(parsed) ~= 'table' then
        msg.error('Unable to parse startup logo manifest: ' .. tostring(parse_err))
        return false
    end
    if type(parsed.opacity_levels) ~= 'table'
        or type(parsed.backgrounds) ~= 'table'
        or type(parsed.logos) ~= 'table'
        or type(parsed.base_layout) ~= 'table' then
        msg.error('Startup logo manifest is incomplete')
        return false
    end

    manifest = parsed
    levels = parsed.opacity_levels
    table.sort(levels, function(a, b) return tonumber(a) < tonumber(b) end)
    msg.info(string.format(
        'assets loaded: %d logos, %d opacity levels',
        (function()
            local count = 0
            for _ in pairs(parsed.logos) do count = count + 1 end
            return count
        end)(),
        #levels
    ))
    return true
end


local function publish_state()
    local current = state.current or {}
    mp.set_property_bool('user-data/startup-format-logos/enabled', o.enabled == true)
    mp.set_property('user-data/startup-format-logos/style', o.style)
    mp.set_property('user-data/startup-format-logos/video', current.video or '')
    mp.set_property('user-data/startup-format-logos/audio', current.audio or '')
    mp.set_property('user-data/startup-format-logos/visible', state.visible and 'yes' or 'no')
end


local function remove_overlay(id)
    pcall(mp.command_native, {'overlay-remove', id})
end


local function remove_overlays()
    if state.overlays_present then
        remove_overlay(overlay_base)
        remove_overlay(overlay_base + 1)
        remove_overlay(overlay_base + 2)
    end
    state.overlays_present = false
    state.visible = false
    state.opacity_index = 0
    publish_state()
end


local function cancel_display(clear_current)
    state.display_generation = state.display_generation + 1
    stop_timer('animation')
    stop_timer('hold')
    remove_overlays()
    if clear_current then
        state.current = nil
        publish_state()
    end
end


local function split_priority(value)
    local result = {}
    for token in tostring(value or ''):gmatch('[^,%s]+') do
        result[#result + 1] = token:lower()
    end
    return result
end


local function choose_candidate(candidates, priority)
    if not manifest then return nil end
    for _, slug in ipairs(split_priority(priority)) do
        if candidates[slug] and manifest.logos[slug] then
            return slug
        end
    end
    return nil
end


local function read_selected_track(kind)
    local selector = kind == 'audio' and 'aid' or (kind == 'video' and 'vid' or nil)
    if selector then
        local selected_id = mp.get_property_native(selector)
        if selected_id == false or tostring(selected_id or '') == 'no' then
            return nil
        end
    end

    local current = mp.get_property_native('current-tracks/' .. kind, {})
    if type(current) == 'table' and current.type == kind then
        return current
    end

    local tracks = mp.get_property_native('track-list', {})
    if type(tracks) == 'table' then
        local fallback = nil
        local count = 0
        for _, track in ipairs(tracks) do
            if type(track) == 'table' and track.type == kind then
                if track.selected == true then return track end
                count = count + 1
                fallback = fallback or track
            end
        end
        -- A lone track is safe during the short interval before mpv marks it
        -- selected. With multiple tracks, guessing the first one can display
        -- the wrong family before aid/vid settles.
        if count == 1 then return fallback end
    end
    return nil
end


local function count_tracks(kind)
    local count = 0
    local tracks = mp.get_property_native('track-list', {})
    if type(tracks) == 'table' then
        for _, track in ipairs(tracks) do
            if type(track) == 'table' and track.type == kind then
                count = count + 1
            end
        end
    end
    return count
end


local function has_real_video_track()
    local track = read_selected_track('video')
    return type(track) == 'table'
        and track.type == 'video'
        and track.albumart ~= true
end


local function append_context(parts, value)
    if type(value) == 'string' or type(value) == 'number' then
        parts[#parts + 1] = tostring(value)
    end
end


local TRACK_TEXT_FIELDS = {
    'codec', 'codec-desc', 'codec-profile', 'decoder-desc',
    'demux-codec', 'title', 'lang', 'format',
}


local function build_context(track, include_filename, extra)
    local parts = {}
    append_context(parts, extra)
    if type(track) == 'table' then
        for _, field in ipairs(TRACK_TEXT_FIELDS) do
            append_context(parts, track[field])
        end
        if type(track.metadata) == 'table' then
            for key, value in pairs(track.metadata) do
                append_context(parts, key)
                append_context(parts, value)
            end
        end
    end
    if include_filename then
        append_context(parts, mp.get_property('filename', ''))
        append_context(parts, mp.get_property('media-title', ''))
        append_context(parts, mp.get_property('path', ''))
    end
    local raw = table.concat(parts, ' '):lower()
    -- Keep the meaning of literal "+" markers before stripping punctuation.
    -- This makes filenames such as HDR10+ and DD+ match the same rules as
    -- their spelled-out forms without weakening the brand checks.
    local compact = raw:gsub('%+', 'plus')
        :gsub('[%s%._%-:/\\%[%]%(%)]+', '')
    return raw, compact
end


local function contains_plain(text, needle)
    return text:find(needle, 1, true) ~= nil
end


local CODEC_IDENTITY_FIELDS = {
    'codec', 'decoder', 'codec-desc', 'decoder-desc', 'demux-codec', 'format',
}


local APE_CODEC_IDENTITIES = {
    ape = true,
    monkeysaudio = true,
}


local DRA_CODEC_IDENTITIES = {
    dra = true,
    libdra = true,
    draudiodecoder = true,
}


local function normalize_codec_identity(value)
    local normalized = tostring(value or ''):lower():gsub('’', '')
    normalized = normalized:gsub('[%s%p]+', '')
    return normalized
end


local function has_codec_identity(track, current_codec, identities)
    if identities[normalize_codec_identity(current_codec)] then return true end
    if type(track) ~= 'table' then return false end
    for _, field in ipairs(CODEC_IDENTITY_FIELDS) do
        if identities[normalize_codec_identity(track[field])] then return true end
    end
    return false
end


local function positive(value)
    local number = tonumber(value)
    return number ~= nil and number > 0
end


local function has_dolby_vision(track, params, compact)
    if positive(mp.get_property_native(
        'user-data/media-format/dolby-vision-profile')) then
        return true
    end
    if type(track) == 'table' then
        if positive(track['dolby-vision-profile']) or track['dolby-vision-level'] ~= nil then
            return true
        end
    end
    if type(params) == 'table' then
        if positive(params['dolby-vision-profile']) or params['dolby-vision-level'] ~= nil then
            return true
        end
        local colormatrix = tostring(
            params.colormatrix or params['color-matrix'] or ''):lower()
        if colormatrix == 'dolbyvision' then return true end
    end
    return contains_plain(compact, 'dolbyvision')
        or contains_plain(compact, 'dovi')
        or contains_plain(compact, 'dvhe')
        or contains_plain(compact, 'dvh1')
end


local function has_hdr10_plus(track, params, compact)
    if type(track) == 'table' then
        if track.hdr10plus == true
            or positive(track['scene-max-r'])
            or positive(track['scene-max-g'])
            or positive(track['scene-max-b']) then
            return true
        end
    end
    if type(params) == 'table' then
        if params.hdr10plus == true
            or positive(params['scene-max-r'])
            or positive(params['scene-max-g'])
            or positive(params['scene-max-b']) then
            return true
        end
    end
    return contains_plain(compact, 'hdr10plus')
        or contains_plain(compact, 'hdr10p')
end


local function detect_video_candidates(track)
    local candidates = {}
    if type(track) ~= 'table' or track.type ~= 'video' or track.albumart == true then
        return candidates
    end

    local params = mp.get_property_native('video-params', {})
    local _, compact = build_context(track, o.filename_fallback, nil)
    if has_dolby_vision(track, params, compact) then
        candidates['dolby-vision'] = true
    end
    if (type(params) == 'table' and params['hdr-vivid'] == true)
        or (o.filename_fallback
            and (contains_plain(compact, 'hdrvivid')
                or contains_plain(compact, 'cuvahdr'))) then
        candidates['hdr-vivid'] = true
    end
    if has_hdr10_plus(track, params, compact) then
        candidates['hdr10-plus'] = true
    end

    local gamma = type(params) == 'table'
        and tostring(params.gamma or params.transfer or ''):lower()
        or ''
    if gamma == 'pq' or gamma == 'smpte2084'
        or (o.filename_fallback and contains_plain(compact, 'hdr10')) then
        candidates.hdr10 = true
    end
    if gamma == 'hlg'
        or gamma == 'arib-std-b67'
        or gamma == 'aribstdb67'
        or (o.filename_fallback and contains_plain(compact, 'hlg')) then
        candidates.hlg = true
    end
    if o.show_sdr then
        candidates.sdr = true
    end
    return candidates
end


local function detect_audio_candidates(track, include_filename)
    local candidates = {}
    if type(track) ~= 'table' or track.type ~= 'audio' then
        return candidates
    end

    local codec = mp.get_property('audio-codec', '')
    local raw, compact = build_context(track, include_filename == true, codec)
    local _, codec_compact = build_context(track, false, codec)

    if contains_plain(compact, 'atmos')
        or contains_plain(compact, 'dolbyatmos')
        or raw:match('%f[%w]joc%f[%W]') then
        candidates['dolby-atmos'] = true
    end
    if contains_plain(compact, 'dtsx') then
        candidates['dts-x'] = true
    end
    if contains_plain(codec_compact, 'av3a')
        or contains_plain(compact, 'audiovivid')
        or contains_plain(compact, 'avs3audio') then
        candidates['audio-vivid'] = true
    end
    if contains_plain(compact, 'truehd')
        or contains_plain(compact, 'mlpfba') then
        candidates['dolby-truehd'] = true
    end
    if contains_plain(compact, 'dtshdmasteraudio')
        or contains_plain(compact, 'dtshdmaster')
        or contains_plain(compact, 'dtshdma')
        or contains_plain(compact, 'dtsma') then
        candidates['dts-hd-ma'] = true
    end
    if contains_plain(compact, 'dtshdhighresolutionaudio')
        or contains_plain(compact, 'dtshdhighresolution')
        or contains_plain(compact, 'dtshdhra')
        or contains_plain(compact, 'dtshighres') then
        candidates['dts-hd-hra'] = true
    end
    if contains_plain(compact, 'dolbydigitalplus')
        or contains_plain(compact, 'eac3')
        or contains_plain(compact, 'ddplus')
        or contains_plain(compact, 'ddp') then
        candidates['dolby-digital-plus'] = true
    end
    if contains_plain(codec_compact, 'ac3')
        or contains_plain(compact, 'dolbydigital') then
        candidates['dolby-digital'] = true
    end
    if contains_plain(codec_compact, 'dca')
        or contains_plain(codec_compact, 'dts')
        or raw:match('%f[%w]dts%f[%W]') then
        candidates.dts = true
    end

    -- AC-4 and MPEG-H are immersive delivery formats, not ordinary fallback
    -- codecs. They remain available when common FLAC/AAC/PCM badges are off.
    if contains_plain(codec_compact, 'ac4') then
        candidates.ac4 = true
    end
    if contains_plain(codec_compact, 'mpegh')
        or contains_plain(codec_compact, 'mhm1')
        or contains_plain(codec_compact, 'mha1') then
        candidates['mpeg-h'] = true
    end
    if has_codec_identity(track, codec, DRA_CODEC_IDENTITIES) then
        candidates.dra = true
    end

    if o.show_common_audio then
        if contains_plain(codec_compact, 'flac') then
            candidates.flac = true
        end
        if contains_plain(codec_compact, 'alac') then
            candidates.alac = true
        end
        if contains_plain(codec_compact, 'pcm')
            or contains_plain(codec_compact, 'lpcm') then
            candidates.pcm = true
        end
        if contains_plain(codec_compact, 'mlp')
            and not candidates['dolby-truehd'] then
            candidates.mlp = true
        end
        if contains_plain(codec_compact, 'wavpack')
            or codec_compact == 'wv' then
            candidates.wavpack = true
        end
        if has_codec_identity(track, codec, APE_CODEC_IDENTITIES) then
            candidates.ape = true
        end
        if codec_compact == 'wma'
            or contains_plain(codec_compact, 'wmav1')
            or contains_plain(codec_compact, 'wmav2')
            or contains_plain(codec_compact, 'wmapro')
            or contains_plain(codec_compact, 'wmavoice')
            or contains_plain(codec_compact, 'wmalossless')
            or contains_plain(codec_compact, 'windowsmediaaudio') then
            candidates.wma = true
        end
        if contains_plain(codec_compact, 'opus') then
            candidates.opus = true
        end
        if contains_plain(codec_compact, 'aac') then
            candidates.aac = true
        end
        if contains_plain(codec_compact, 'vorbis') then
            candidates.vorbis = true
        end
        if contains_plain(codec_compact, 'mp3') then
            candidates.mp3 = true
        end
    end
    return candidates
end


local DOLBY_AUDIO_CANDIDATES = {
    ['dolby-atmos'] = true,
    ['dolby-truehd'] = true,
    ['dolby-digital-plus'] = true,
    ['dolby-digital'] = true,
}


local DTS_AUDIO_CANDIDATES = {
    ['dts-x'] = true,
    ['dts-hd-ma'] = true,
    ['dts-hd-hra'] = true,
    dts = true,
}


local AUDIO_CODEC_FIELDS = {
    'codec', 'codec-desc', 'codec-profile', 'decoder-desc',
    'demux-codec', 'format',
}


local function selected_audio_profile(track)
    local codec_track = {type = 'audio'}
    if type(track) == 'table' then
        for _, field in ipairs(AUDIO_CODEC_FIELDS) do
            codec_track[field] = track[field]
        end
    end

    local codec = mp.get_property('audio-codec', '')
    local _, compact = build_context(codec_track, false, codec)
    local dts_family = contains_plain(compact, 'dca')
        or contains_plain(compact, 'dts')
    local atmos_carrier = contains_plain(compact, 'truehd')
        or contains_plain(compact, 'mlpfba')
        or contains_plain(compact, 'eac3')
        or contains_plain(compact, 'ec3')
        or contains_plain(compact, 'ac4')
    local dolby_family = atmos_carrier
        or contains_plain(compact, 'ac3')
        or contains_plain(compact, 'mlp')
        or contains_plain(compact, 'dolbydigital')
        or contains_plain(compact, 'dolbytruehd')

    if dts_family then return 'dts', false end
    if dolby_family then return 'dolby', atmos_carrier end
    if compact ~= '' then return 'other', false end
    return 'unknown', false
end


local function remove_candidate_family(candidates, family)
    for slug in pairs(family) do
        candidates[slug] = nil
    end
end


local function filter_audio_candidates(candidates, family, atmos_carrier)
    if family == 'dts' then
        remove_candidate_family(candidates, DOLBY_AUDIO_CANDIDATES)
    elseif family == 'dolby' then
        remove_candidate_family(candidates, DTS_AUDIO_CANDIDATES)
        if not atmos_carrier then
            candidates['dolby-atmos'] = nil
        end
    elseif family == 'other' then
        remove_candidate_family(candidates, DOLBY_AUDIO_CANDIDATES)
        remove_candidate_family(candidates, DTS_AUDIO_CANDIDATES)
    end
    return candidates
end


local function merge_candidate_family(target, source, family)
    for slug in pairs(family) do
        if source[slug] then target[slug] = true end
    end
end


local function detect_selected_audio(track)
    if type(track) ~= 'table' or track.type ~= 'audio' then return nil end

    local family, atmos_carrier = selected_audio_profile(track)
    local candidates = filter_audio_candidates(
        detect_audio_candidates(track, false),
        family,
        atmos_carrier
    )

    -- File names describe the whole container, not the selected audio track.
    -- They are therefore unsafe in multi-audio files. For a single track they
    -- may only refine a compatible codec family, never replace it with Dolby
    -- or DTS from another family.
    if o.filename_fallback and count_tracks('audio') == 1 then
        local fallback = filter_audio_candidates(
            detect_audio_candidates(track, true),
            family,
            atmos_carrier
        )
        if family == 'dts' then
            merge_candidate_family(candidates, fallback, DTS_AUDIO_CANDIDATES)
        elseif family == 'dolby' and atmos_carrier and fallback['dolby-atmos'] then
            candidates['dolby-atmos'] = true
        end
    end

    return choose_candidate(candidates, o.audio_priority)
end


local function detect_pair()
    local video_track = read_selected_track('video')
    if o.require_video and not has_real_video_track() then
        return nil, nil
    end

    local audio_track = read_selected_track('audio')
    local video = o.show_video
        and choose_candidate(detect_video_candidates(video_track), o.video_priority)
        or nil
    local audio = o.show_audio
        and detect_selected_audio(audio_track)
        or nil
    local audio_pending = false
    if o.show_audio and not audio then
        if type(audio_track) == 'table' and audio_track.type == 'audio' then
            audio_pending = true
        else
            local aid = mp.get_property_native('aid')
            if aid ~= false and tostring(aid or '') ~= 'no'
                and count_tracks('audio') > 0 then
                audio_pending = true
            end
        end
    end
    return video, audio, audio_pending
end


local function get_osd_size()
    local width = mp.get_property_number('osd-width', 0)
    local height = mp.get_property_number('osd-height', 0)
    if width <= 0 or height <= 0 then return nil, nil end
    return width, height
end


local function get_viewport_scale(osd_width, osd_height)
    -- Keep the same physical hierarchy when the player window follows a
    -- portrait video instead of treating its short width as a landscape view.
    if osd_height > osd_width then
        return math.min(osd_width / 1080, osd_height / 1920)
    end
    return math.min(osd_width / 1920, osd_height / 1080)
end


local function get_video_bounds(osd_width, osd_height)
    local bounds = {
        left = 0,
        top = 0,
        right = osd_width,
        bottom = osd_height,
    }
    if not o.anchor_to_video then return bounds end

    local dimensions = mp.get_property_native('osd-dimensions', {})
    if type(dimensions) ~= 'table' then return bounds end

    local left = clamp(tonumber(dimensions.ml) or 0, 0, osd_width)
    local top = clamp(tonumber(dimensions.mt) or 0, 0, osd_height)
    local right = clamp(osd_width - (tonumber(dimensions.mr) or 0), 0, osd_width)
    local bottom = clamp(osd_height - (tonumber(dimensions.mb) or 0), 0, osd_height)
    if right <= left or bottom <= top then return bounds end

    bounds.left = left
    bounds.top = top
    bounds.right = right
    bounds.bottom = bottom

    -- osd-dimensions only describes bars added by mpv. Blu-ray/ISO video often
    -- carries black bars inside the decoded 16:9 frame, so apply the normalized
    -- pixel probe as an additional safe area. Sparse opening frames receive a
    -- few follow-up probes, so a later stable letterbox can safely re-anchor
    -- the badge without seeking or delaying playback. If another script has
    -- already cropped the video, ignore these insets to avoid double-cropping.
    local insets = state.content_insets
    local video_crop = mp.get_property('video-crop', '')
    if type(insets) == 'table' and (not video_crop or video_crop == '') then
        local video_width = bounds.right - bounds.left
        local video_height = bounds.bottom - bounds.top
        bounds.left = bounds.left + video_width * (tonumber(insets.left) or 0)
        bounds.right = bounds.right - video_width * (tonumber(insets.right) or 0)
        bounds.top = bounds.top + video_height * (tonumber(insets.top) or 0)
        bounds.bottom = bounds.bottom - video_height * (tonumber(insets.bottom) or 0)
    end
    return bounds
end




local function compute_layout(kind)
    local osd_width, osd_height = get_osd_size()
    if not osd_width then return nil end

    local base = manifest.base_layout[kind]
    local bounds = get_video_bounds(osd_width, osd_height)
    local available_width = bounds.right - bounds.left
    local available_height = bounds.bottom - bounds.top
    local viewport_scale = get_viewport_scale(osd_width, osd_height)
    local orientation_scale = osd_height > osd_width
        and number_option(o.portrait_scale, 1.18)
        or 1.0
    local display_scale = clamp(
        viewport_scale * number_option(o.scale, 1.0) * orientation_scale,
        0.25,
        2.0
    )
    local fit_scale = math.min(
        (available_width - 24) / tonumber(base.w),
        (available_height - 24) / tonumber(base.h)
    )
    display_scale = math.min(display_scale, fit_scale)
    if display_scale <= 0 then return nil end

    local width = round(tonumber(base.w) * display_scale)
    local height = round(tonumber(base.h) * display_scale)
    local margin_x = round(number_option(o.margin_x, 60) * viewport_scale)
    local margin_y = round(number_option(o.margin_y, 38) * viewport_scale)
    local position = tostring(o.position):lower():gsub('_', '-')
    local left = position:find('left', 1, true) ~= nil
    local bottom = position:find('bottom', 1, true) ~= nil
    local x = left
        and bounds.left + margin_x
        or bounds.right - width - margin_x
    local y = bottom
        and bounds.bottom - height - margin_y
        or bounds.top + margin_y

    return {
        x = round(clamp(x, bounds.left, bounds.right - width)),
        y = round(clamp(y, bounds.top, bounds.bottom - height)),
        w = width,
        h = height,
        scale = display_scale,
        base = base,
    }
end


local function overlay_add(id, x, y, file, width, height, display_width, display_height)
    local ok, err = pcall(mp.command_native, {
        'overlay-add', id, x, y, file, 0, 'bgra',
        width, height, width * 4, display_width, display_height,
    })
    if not ok then
        if not state.overlay_error_logged then
            msg.error('Unable to render startup logo overlay: ' .. tostring(err))
            state.overlay_error_logged = true
        end
        return false
    end
    return true
end


local function render_logo(id, slug, level_key, layout, center_y)
    local asset = manifest.logos[slug]
    if not asset then return false end
    local source_scale = tonumber(manifest.source_scale) or 2
    local base_logo_width = tonumber(manifest.base_layout.logo_max_w)
        or asset.w / source_scale
    local base_logo_height = tonumber(manifest.base_layout.logo_max_h)
        or asset.h / source_scale
    local display_width = math.max(1, round(base_logo_width * layout.scale))
    local display_height = math.max(1, round(base_logo_height * layout.scale))
    local white = o.style == 'white'
    local variants = white and asset.white_variants or asset.variants
    local source = {
        w = asset.w,
        h = asset.h,
        files = white and asset.white_files or asset.files,
    }
    if type(variants) == 'table' then
        -- Use the smallest source that is at least as large as the target.
        -- 1080p therefore renders the 156x64 tier 1:1, while 1440p/4K use
        -- the 312x128 tier and avoid unnecessary double filtering.
        local one_x = variants['1']
        local two_x = variants['2']
        if type(one_x) == 'table'
            and display_width <= (tonumber(one_x.w) or 0)
            and display_height <= (tonumber(one_x.h) or 0) then
            source = one_x
        elseif type(two_x) == 'table' then
            source = two_x
        end
    end
    local filename = type(source.files) == 'table' and source.files[level_key]
    if not filename then return false end
    local x = round(layout.x + layout.w / 2 - display_width / 2)
    local y = round(layout.y + center_y * layout.scale - display_height / 2)
    return overlay_add(
        id, x, y, join_path(asset_root, filename),
        source.w, source.h, display_width, display_height
    )
end


local function render_level(index)
    if not manifest or not state.current then return false end
    local level = levels[index]
    if not level then return false end
    local level_key = tostring(level)
    local double = state.current.video ~= nil and state.current.audio ~= nil
    local kind = double and 'double' or 'single'
    local layout = compute_layout(kind)
    if not layout then return false end
    local background = manifest.backgrounds[kind]
    local background_file = background
        and type(background.files) == 'table'
        and background.files[level_key]
        or nil
    if background_file then
        local background_ok = overlay_add(
            overlay_base,
            layout.x,
            layout.y,
            join_path(asset_root, background_file),
            background.w,
            background.h,
            layout.w,
            layout.h
        )
        if not background_ok then return false end
    else
        -- Color-badge assets carry their own dark surface and accent rim.
        -- The shared background remains optional for other asset themes.
        remove_overlay(overlay_base)
    end

    if double then
        render_logo(
            overlay_base + 1,
            state.current.video,
            level_key,
            layout,
            tonumber(layout.base.top_center_y)
        )
        render_logo(
            overlay_base + 2,
            state.current.audio,
            level_key,
            layout,
            tonumber(layout.base.bottom_center_y)
        )
    else
        local slug = state.current.video or state.current.audio
        render_logo(
            overlay_base + 1,
            slug,
            level_key,
            layout,
            tonumber(layout.base.center_y)
        )
        remove_overlay(overlay_base + 2)
    end

    state.overlays_present = true
    state.visible = true
    state.opacity_index = index
    publish_state()
    return true
end


local function start_fade_out(generation)
    if generation ~= state.display_generation then return end
    local count = #levels
    local duration = math.max(0, tonumber(o.fade_out) or 0)
    if duration <= 0 or count <= 1 then
        remove_overlays()
        return
    end

    local interval = duration / count
    local index = count - 1
    local function step()
        if generation ~= state.display_generation then return end
        if index < 1 then
            remove_overlays()
            return
        end
        render_level(index)
        index = index - 1
        schedule('animation', interval, step)
    end
    schedule('animation', interval, step)
end


local function finish_fade_in(generation)
    if generation ~= state.display_generation then return end
    local hold = math.max(0, tonumber(o.hold) or 0)
    schedule('hold', hold, function() start_fade_out(generation) end)
end


local function start_fade_in(generation)
    local count = #levels
    local duration = math.max(0, tonumber(o.fade_in) or 0)
    if duration <= 0 or count <= 1 then
        render_level(count)
        finish_fade_in(generation)
        return
    end

    local interval = duration / (count - 1)
    local index = 1
    local function step()
        if generation ~= state.display_generation then return end
        render_level(index)
        if index >= count then
            finish_fade_in(generation)
            return
        end
        index = index + 1
        schedule('animation', interval, step)
    end
    step()
end


local function show_pair(video, audio, reason)
    if not o.enabled or not manifest then return false end
    if not video and not audio then return false end
    if video and not manifest.logos[video] then video = nil end
    if audio and not manifest.logos[audio] then audio = nil end
    if not video and not audio then return false end

    cancel_display(false)
    state.current = {video = video, audio = audio}
    local generation = state.display_generation
    publish_state()
    msg.debug(string.format(
        'show (%s): video=%s audio=%s style=%s',
        tostring(reason or 'unknown'),
        tostring(video or 'none'),
        tostring(audio or 'none'),
        o.style
    ))
    start_fade_in(generation)
    return true
end


local function detect_and_show(file_generation, attempt, reason)
    if file_generation ~= state.file_generation or not state.loaded or not o.enabled then
        return
    end
    local video, audio, audio_pending = detect_pair()
    local max_attempts = math.max(1, math.floor(tonumber(o.retry_count) or 1))
    if (video or audio) and audio_pending and attempt < max_attempts then
        -- Do not hold the visible video badge for late audio-track metadata.
        -- Show what is already known, then replace it with the complete pair
        -- when the selected audio track becomes available.
        if attempt == 1 then show_pair(video, audio, reason .. '-video-ready') end
        schedule('retry', tonumber(o.retry_interval) or 0.25, function()
            detect_and_show(file_generation, attempt + 1, reason)
        end)
        return
    elseif video or audio then
        show_pair(video, audio, reason)
        return
    end

    if attempt < max_attempts then
        schedule('retry', tonumber(o.retry_interval) or 0.25, function()
            detect_and_show(file_generation, attempt + 1, reason)
        end)
    else
        state.current = nil
        publish_state()
        msg.debug('no premium startup logo detected')
    end
end


local function schedule_detection(reason, delay)
    local file_generation = state.file_generation
    stop_timer('retry')
    schedule('retry', delay or 0, function()
        detect_and_show(file_generation, 1, reason)
    end)
end


local function has_video_geometry()
    local params = mp.get_property_native('video-out-params', {})
    if type(params) ~= 'table' then return false end
    local width = tonumber(params.dw) or tonumber(params.w)
    local height = tonumber(params.dh) or tonumber(params.h)
    if not width or width <= 0 or not height or height <= 0 then return false end

    local dimensions = mp.get_property_native('osd-dimensions', {})
    return type(dimensions) == 'table'
        and tonumber(dimensions.w) ~= nil
        and tonumber(dimensions.h) ~= nil
        and tonumber(dimensions.w) > 0
        and tonumber(dimensions.h) > 0
end


local function start_ambiguous_bar_followup(file_generation)
    local remaining = clamp(
        math.floor(tonumber(o.encoded_bar_followup_samples) or 3),
        0,
        5
    )
    if remaining <= 0 then
        state.bar_anchor_locked = true
        return
    end
    local interval = clamp(
        tonumber(o.encoded_bar_followup_interval) or 1.5,
        0.5,
        4.0
    )

    local probes = {}
    local no_bar_samples = 0

    local function commit(insets, reason)
        if file_generation ~= state.file_generation or not state.loaded
            or state.bar_anchor_locked then
            return true
        end
        state.content_insets = insets
        state.bar_anchor_locked = true
        stop_timer('bar-followup')
        if type(insets) == 'table' then
            msg.debug(string.format(
                'encoded bars locked (%s): left=%.4f top=%.4f right=%.4f bottom=%.4f',
                tostring(reason),
                tonumber(insets.left) or 0,
                tonumber(insets.top) or 0,
                tonumber(insets.right) or 0,
                tonumber(insets.bottom) or 0
            ))
            if state.visible and state.opacity_index > 0 then
                render_level(state.opacity_index)
            end
        else
            msg.debug('encoded bars locked (' .. tostring(reason) .. '): frame bounds')
        end
        return true
    end

    local function request_sample()
        if file_generation ~= state.file_generation or not state.loaded
            or state.bar_anchor_locked or remaining <= 0 then
            return
        end
        remaining = remaining - 1
        local ok, request = pcall(mp.command_native_async, {
            name = 'screenshot-raw', flags = 'video', format = 'bgr0',
        }, function(success, frame)
            state.bar_request = nil
            if file_generation ~= state.file_generation or not state.loaded then return end
            if success then
                local insets, meaningful = logo_bounds.detect(frame, o.encoded_bar_threshold)
                if meaningful then
                    if insets then
                        probes[#probes + 1] = insets
                    else
                        no_bar_samples = no_bar_samples + 1
                    end
                end
            end
            local stable = logo_bounds.merge_stable(probes, 2, 0.012)
            if stable then
                commit(stable, 'stable-followup')
            elseif no_bar_samples >= 2 then
                commit(nil, 'stable-full-frame-followup')
            elseif remaining > 0 then
                schedule('bar-followup', interval, request_sample)
            else
                commit(nil, 'ambiguous-followup')
            end
        end)
        if ok then
            state.bar_request = request
        elseif remaining > 0 then
            schedule('bar-followup', interval, request_sample)
        else
            commit(nil, 'followup-unavailable')
        end
    end

    schedule(
        'bar-followup',
        clamp(tonumber(o.encoded_bar_followup_delay) or 2.5, 0.5, 8.0),
        request_sample
    )
end


local function prepare_display_after_frame(reason)
    local file_generation = state.file_generation
    local function lock_insets(insets, suffix)
        if file_generation ~= state.file_generation or not state.loaded
            or state.bar_anchor_locked then return end
        state.content_insets = insets
        state.bar_anchor_locked = true
        if type(insets) == 'table' then
            msg.debug(string.format(
                'encoded bars locked%s: left=%.4f top=%.4f right=%.4f bottom=%.4f',
                tostring(suffix or ''),
                tonumber(insets.left) or 0,
                tonumber(insets.top) or 0,
                tonumber(insets.right) or 0,
                tonumber(insets.bottom) or 0
            ))
            if state.visible and state.opacity_index > 0 then
                render_level(state.opacity_index)
            end
        else
            msg.debug('encoded bars locked' .. tostring(suffix or '') .. ': frame bounds')
        end
    end
    local function continue_detection(insets, suffix, followup)
        if file_generation ~= state.file_generation or not state.loaded then return end
        state.bar_request = nil
        stop_timer('bar-detect-timeout')
        if followup then
            start_ambiguous_bar_followup(file_generation)
        else
            lock_insets(insets, suffix)
        end
    end

    if not has_real_video_track() or not o.anchor_to_video or not o.detect_encoded_bars then
        continue_detection(nil, '', false)
        return
    end

    schedule('bar-detect', math.max(0, tonumber(o.encoded_bar_delay) or 0.18), function()
        if file_generation ~= state.file_generation or not state.loaded then return end
        local completed = false
        local probes = {}
        local no_bar_samples = 0
        local sample_count = clamp(math.floor(tonumber(o.encoded_bar_samples) or 3), 1, 5)
        local sample_interval = clamp(tonumber(o.encoded_bar_sample_interval) or 0.22, 0.05, 0.75)
        local function finish(suffix)
            if completed then return end
            completed = true
            local insets = logo_bounds.merge_stable(probes, 2, 0.012)
            local followup = insets == nil and no_bar_samples < 2
            continue_detection(
                insets,
                suffix,
                followup
            )
        end
        schedule('bar-detect-timeout', 1.4 + sample_count * sample_interval, function()
            finish('-bar-timeout')
        end)

        local function request_sample(index)
            if completed or file_generation ~= state.file_generation or not state.loaded then return end
            local ok, request = pcall(mp.command_native_async, {
                name = 'screenshot-raw', flags = 'video', format = 'bgr0',
            }, function(success, frame)
                if completed then return end
                if success then
                    local insets, meaningful = logo_bounds.detect(
                        frame,
                        o.encoded_bar_threshold
                    )
                    if meaningful then
                        if insets then
                            probes[#probes + 1] = insets
                        else
                            no_bar_samples = no_bar_samples + 1
                        end
                    end
                end
                if index >= sample_count then
                    finish('-sampled')
                else
                    schedule('bar-detect-sample', sample_interval, function()
                        request_sample(index + 1)
                    end)
                end
            end)
            if not ok then
                if index >= sample_count then
                    finish('-bar-unavailable')
                else
                    schedule('bar-detect-sample', sample_interval, function()
                        request_sample(index + 1)
                    end)
                end
            else
                state.bar_request = request
            end
        end
        request_sample(1)
    end)
end


local function mark_frame_ready(reason)
    if not state.loaded or state.frame_ready then return end
    state.frame_ready = true
    state.waiting_for_frame = false
    stop_timer('frame-wait')
    if o.enabled and manifest then
        -- playback-restart is the first presentable frame boundary. Start the
        -- badge now and probe encoded bars in parallel instead of serializing
        -- 1-2 seconds of sampling ahead of the first visible overlay.
        schedule_detection(reason .. '-immediate', tonumber(o.delay) or 0)
        prepare_display_after_frame(reason)
    end
end


local function on_playback_restart()
    -- The first playback-restart arrives only after mpv has a presentable
    -- video frame. Waiting for it prevents the badges from appearing against
    -- the empty window and then jumping when letterbox/pillarbox bounds land.
    if state.loaded and not state.frame_ready then
        mark_frame_ready('first-frame')
    end
end


local function on_video_geometry_ready()
    -- video-reconfig normally precedes the first presented frame and already
    -- carries the final OSD/video bounds. Rendering here lets the first frame
    -- contain the badge; playback-restart remains the safe fallback when a VO
    -- does not emit reconfiguration for a same-size playlist transition.
    if state.loaded and state.waiting_for_frame and not state.frame_ready
        and has_real_video_track() and has_video_geometry() then
        mark_frame_ready('video-geometry-ready')
    end
end


local function on_file_loaded()
    state.file_generation = state.file_generation + 1
    state.loaded = true
    state.frame_ready = false
    state.waiting_for_frame = true
    state.content_insets = nil
    state.bar_anchor_locked = false
    state.last_aid = mp.get_property_native('aid')
    state.overlay_error_logged = false
    cancel_display(true)
    stop_timer('frame-wait')
    stop_timer('bar-followup')

    if not has_real_video_track() then
        if o.require_video then
            state.waiting_for_frame = false
            msg.debug('startup logo skipped: a real video track is required')
            return
        end

        -- Audio-only playback has no video frame or video-out geometry to wait
        -- for. Wait briefly for the window OSD instead, then use the full OSD
        -- bounds and skip video-only encoded-bar probing.
        local file_generation = state.file_generation
        local function wait_for_audio_osd(attempt)
            schedule('frame-wait', attempt == 1 and 0.05 or 0.10, function()
                if file_generation ~= state.file_generation
                    or not state.loaded or state.frame_ready then
                    return
                end
                local width, height = get_osd_size()
                if width and height then
                    mark_frame_ready('audio-only-osd')
                elseif attempt < 15 then
                    wait_for_audio_osd(attempt + 1)
                else
                    state.waiting_for_frame = false
                    msg.debug('startup logo skipped: no OSD geometry for audio-only playback')
                end
            end)
        end
        wait_for_audio_osd(1)
        return
    end

    schedule('frame-wait', math.max(0.5, tonumber(o.frame_wait_timeout) or 5.0), function()
        if not state.loaded or state.frame_ready then return end
        if has_video_geometry() then
            mark_frame_ready('video-geometry-timeout')
        else
            state.waiting_for_frame = false
            msg.debug('startup logo skipped: no stable video frame or geometry')
        end
    end)
end


local function on_end_file()
    state.file_generation = state.file_generation + 1
    state.loaded = false
    state.frame_ready = false
    state.waiting_for_frame = false
    state.content_insets = nil
    state.bar_anchor_locked = false
    state.last_aid = nil
    stop_timer('frame-wait')
    stop_timer('bar-detect')
    stop_timer('bar-detect-timeout')
    stop_timer('bar-followup')
    if state.bar_request then
        pcall(mp.abort_async_command, state.bar_request)
        state.bar_request = nil
    end
    stop_timer('retry')
    stop_timer('audio-change')
    cancel_display(true)
end


local function on_audio_track_change(_, value)
    if not state.loaded then
        state.last_aid = value
        return
    end
    if value == state.last_aid then return end
    state.last_aid = value
    if not state.frame_ready then return end
    if o.enabled and o.show_on_audio_change then
        schedule('audio-change', 0.18, function()
            if not state.loaded then return end
            local video, audio = detect_pair()
            if video or audio then
                show_pair(video, audio, 'audio-track-change')
            else
                cancel_display(true)
            end
        end)
    end
end


local function preview_message(video, audio)
    local function normalize(value)
        value = tostring(value or ''):lower()
        if value == '' or value == 'none' or value == 'no' then return nil end
        return value
    end
    video = normalize(video)
    audio = normalize(audio)
    if not show_pair(video, audio, 'manual-preview') then
        mp.osd_message('起播 Logo 预览参数无效', 2)
    end
end


local function toggle_message()
    o.enabled = not o.enabled
    persist_option('enabled', o.enabled and 'yes' or 'no')
    if not o.enabled then
        cancel_display(true)
    elseif state.loaded then
        if state.frame_ready then
            schedule_detection('runtime-toggle', 0)
        else
            state.waiting_for_frame = true
        end
    end
    publish_state()
    mp.osd_message('起播格式 Logo：' .. (o.enabled and '开启' or '关闭'), 2)
end


local function set_style_message(value)
    local style = normalize_style(value)
    o.style = style
    persist_option('style', style)
    if state.visible and state.opacity_index > 0 then
        render_level(state.opacity_index)
    end
    publish_state()
    mp.osd_message(
        '起播格式图标：' .. (style == 'white' and '透明白图标' or '彩色徽章'),
        2
    )
end


if overlay_base < 0 or overlay_base > 61 then
    msg.warn('overlay_id must leave room for three IDs; falling back to 50')
    overlay_base = 50
end
if overlay_base <= 42 and overlay_base + 2 >= 42 then
    msg.warn('overlay_id range collides with thumbfast overlay 42')
end

if not load_assets() then
    o.enabled = false
end

mp.register_event('file-loaded', on_file_loaded)
mp.register_event('video-reconfig', on_video_geometry_ready)
mp.register_event('playback-restart', on_playback_restart)
mp.register_event('end-file', on_end_file)
mp.observe_property('aid', 'native', on_audio_track_change)
mp.observe_property('user-data/media-format/dolby-vision-profile', 'native', function()
    if state.loaded and state.frame_ready then
        schedule_detection('demuxer-metadata', 0)
    end
end)
mp.observe_property('osd-dimensions', 'native', function()
    on_video_geometry_ready()
    if state.visible and state.opacity_index > 0 then
        render_level(state.opacity_index)
    end
end)

mp.register_script_message('startup-format-logos-show', function()
    if state.loaded then schedule_detection('manual-detect', 0) end
end)
mp.register_script_message('startup-format-logos-preview', preview_message)
mp.register_script_message('startup-format-logos-hide', function() cancel_display(true) end)
mp.register_script_message('startup-format-logos-toggle', toggle_message)
mp.register_script_message('startup-format-logos-set-style', set_style_message)

publish_state()
msg.info('script loaded')
