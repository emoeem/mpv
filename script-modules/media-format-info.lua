-- Shared media format detection for startup overlays and uosc.

local M = {}

local function lower(value)
    return tostring(value or ''):lower()
end

local function compact(value)
    return lower(value):gsub('%+', 'plus'):gsub('[^%w]', '')
end

local function contains(text, needle)
    return tostring(text or ''):find(needle, 1, true) ~= nil
end

local function positive(value)
    local number = tonumber(value)
    return number ~= nil and number > 0
end

local function append_value(parts, value)
    if type(value) == 'string' or type(value) == 'number' then
        parts[#parts + 1] = tostring(value)
    end
end

local TRACK_FIELDS = {
    'codec', 'codec-desc', 'codec-profile', 'decoder-desc', 'demux-codec',
    'demux-channel-layout', 'title', 'format', 'lang',
}

local function append_track(parts, track)
    if type(track) ~= 'table' then return end
    for _, field in ipairs(TRACK_FIELDS) do append_value(parts, track[field]) end
    if type(track.metadata) == 'table' then
        for key, value in pairs(track.metadata) do
            append_value(parts, key)
            append_value(parts, value)
        end
    end
end

local function build_context(snapshot, track, extra, include_filename)
    local parts = {}
    append_track(parts, track)
    append_value(parts, extra)
    if include_filename ~= false then
        append_value(parts, snapshot.filename)
        append_value(parts, snapshot.media_title)
        append_value(parts, snapshot.path)
    end
    local raw = lower(table.concat(parts, ' '))
    return raw, compact(raw)
end

local function read_selected_track(kind)
    local current = mp.get_property_native('current-tracks/' .. kind, {})
    if type(current) == 'table' and current.type == kind then return current end

    local selected
    local count = 0
    local tracks = mp.get_property_native('track-list', {})
    if type(tracks) == 'table' then
        for _, track in ipairs(tracks) do
            if type(track) == 'table' and track.type == kind then
                count = count + 1
                if track.selected == true then return track end
                selected = selected or track
            end
        end
    end
    return count == 1 and selected or {}
end

local function read_snapshot()
    return {
        filename = mp.get_property('filename', ''),
        media_title = mp.get_property('media-title', ''),
        path = mp.get_property('path', ''),
        video_params = mp.get_property_native('video-params', {}),
        video_frame_info = mp.get_property_native('video-frame-info', {}),
        audio_params = mp.get_property_native('audio-params', {}),
        video_track = read_selected_track('video'),
        audio_track = read_selected_track('audio'),
        video_codec = mp.get_property('video-codec', ''),
        audio_codec = mp.get_property('audio-codec', ''),
        hwdec = mp.get_property('hwdec-current', ''),
        fps = mp.get_property_number('estimated-vf-fps', 0),
        container_fps = mp.get_property_number('container-fps', 0),
        audio_channel_count = mp.get_property_number('audio-params/channel-count', 0),
        audio_channels = mp.get_property_number('audio-channels', 0),
    }
end

local function dolby_vision_label(snapshot, context)
    local track = snapshot.video_track or {}
    local params = snapshot.video_params or {}
    local profile = tonumber(track['dolby-vision-profile'])
        or tonumber(params['dolby-vision-profile'])
    local detected = positive(profile)
        or track['dolby-vision-level'] ~= nil
        or params['dolby-vision-level'] ~= nil
        or contains(context, 'dolbyvision')
        or contains(context, 'dovi')
        or contains(context, 'dvhe')
        or contains(context, 'dvh1')
    if not detected then return nil end
    return profile and profile > 0 and ('Dolby Vision P' .. tostring(profile)) or 'Dolby Vision'
end

local function has_hdr10_plus(track, params, context)
    return track.hdr10plus == true
        or params.hdr10plus == true
        or positive(track['scene-max-r'])
        or positive(track['scene-max-g'])
        or positive(track['scene-max-b'])
        or positive(params['scene-max-r'])
        or positive(params['scene-max-g'])
        or positive(params['scene-max-b'])
        or contains(context, 'hdr10plus')
        or contains(context, 'hdr10p')
end

local function has_hdr10_static_metadata(track, params, context)
    return positive(track['max-cll'])
        or positive(track['max-fall'])
        or positive(track['min-luma'])
        or positive(track['max-luma'])
        or positive(params['max-cll'])
        or positive(params['max-fall'])
        or positive(params['min-luma'])
        or positive(params['max-luma'])
        or contains(context, 'hdr10')
end

local function detect_dynamic_range(snapshot, context)
    local track = type(snapshot.video_track) == 'table' and snapshot.video_track or {}
    local params = type(snapshot.video_params) == 'table' and snapshot.video_params or {}
    local dv = dolby_vision_label(snapshot, context)
    if dv then return dv end

    if params['hdr-vivid'] == true
        or track['hdr-vivid'] == true
        or contains(context, 'hdrvivid')
        or contains(context, 'cuvahdr') then
        return 'HDR Vivid'
    end

    local gamma = lower(params.gamma or params.transfer)
    local pq = gamma == 'pq' or gamma == 'smpte2084'
    if pq and has_hdr10_plus(track, params, context) then return 'HDR10+' end
    if gamma == 'hlg' or gamma == 'arib-std-b67' or gamma == 'aribstdb67'
        or contains(context, 'hlg') then
        return 'HLG'
    end
    if pq then
        return has_hdr10_static_metadata(track, params, context) and 'HDR10' or 'HDR'
    end
    return 'SDR'
end

local VIDEO_CODEC_RULES = {
    {'VVC', {'vvc', 'h266'}},
    {'AVS3', {'avs3'}},
    {'AVS2', {'avs2', 'davs2'}},
    {'AVS+', {'cavs'}},
    {'HEVC', {'hevc', 'h265', 'x265'}},
    {'EVC', {'evc'}},
    {'AVC', {'h264', 'x264', 'avc1', 'avc'}},
    {'AV1', {'av01', 'libaomav1', 'dav1d', 'av1'}},
    {'VP9', {'vp9'}},
    {'VP8', {'vp8'}},
    {'MPEG-2', {'mpeg2video', 'mpeg2'}},
    {'MPEG-4', {'mpeg4', 'xvid', 'divx'}},
    {'VC-1', {'vc1', 'wmv3'}},
    {'ProRes', {'prores'}},
    {'Theora', {'theora'}},
    {'JPEG XL', {'jpegxl', 'jxl'}},
    {'WebP', {'webp'}},
}

local function detect_video_codec(context)
    for _, rule in ipairs(VIDEO_CODEC_RULES) do
        for _, needle in ipairs(rule[2]) do
            if contains(context, needle) then return rule[1] end
        end
    end
    return ''
end

local function detect_audio_codec(snapshot, raw, context, codec_context)
    if contains(context, 'dolbyatmos') or contains(context, 'atmos')
        or raw:match('%f[%w]joc%f[%W]') then
        return 'Dolby Atmos'
    end
    if contains(context, 'dtsx') then return 'DTS:X' end
    if contains(codec_context, 'av3a') or contains(context, 'audiovivid')
        or contains(context, 'avs3audio') then
        return 'Audio Vivid'
    end
    if contains(context, 'dtshdmasteraudio') or contains(context, 'dtshdmaster')
        or contains(context, 'dtshdma') or contains(context, 'dtsma') then
        return 'DTS-HD MA'
    end
    if contains(context, 'dtshdhighresolutionaudio')
        or contains(context, 'dtshdhighresolution')
        or contains(context, 'dtshdhra') or contains(context, 'dtshighres') then
        return 'DTS-HD HRA'
    end
    if contains(context, 'truehd') or contains(context, 'mlpfba') then
        return 'Dolby TrueHD'
    end
    if contains(codec_context, 'eac3') or contains(context, 'dolbydigitalplus')
        or contains(context, 'ddplus') or contains(context, 'ddp') then
        return 'Dolby Digital Plus'
    end
    if contains(codec_context, 'ac3') or contains(context, 'dolbydigital') then
        return 'Dolby Digital'
    end
    if contains(codec_context, 'dca') or contains(codec_context, 'dts')
        or raw:match('%f[%w]dts%f[%W]') then
        return 'DTS'
    end
    if contains(codec_context, 'ac4') then return 'Dolby AC-4' end
    if contains(codec_context, 'mpegh') or contains(codec_context, 'mhm1')
        or contains(codec_context, 'mha1') then
        return 'MPEG-H Audio'
    end
    if contains(context, 'heaacv2') or contains(context, 'heaac2')
        or contains(context, 'sbrps') then
        return 'HE-AAC v2'
    end
    if contains(context, 'heaac') or contains(context, 'aacplus')
        or contains(context, 'sbr') then
        return 'HE-AAC'
    end
    if contains(context, 'dabplus') then return 'DAB+' end
    if contains(codec_context, 'flac') then return 'FLAC' end
    if contains(codec_context, 'alac') then return 'ALAC' end
    if contains(codec_context, 'wavpack') or contains(codec_context, 'wavpak') then return 'WavPack' end
    if contains(codec_context, 'tak') then return 'TAK' end
    if contains(codec_context, 'tta') then return 'TTA' end
    if contains(codec_context, 'ape') or contains(codec_context, 'monkeysaudio') then return 'APE' end
    if codec_context == 'wma' or contains(codec_context, 'wmav1')
        or contains(codec_context, 'wmav2') or contains(codec_context, 'wmapro')
        or contains(codec_context, 'wmavoice') or contains(codec_context, 'wmalossless')
        or contains(codec_context, 'windowsmediaaudio') then
        return 'WMA'
    end
    if contains(codec_context, 'opus') then return 'Opus' end
    if contains(codec_context, 'vorbis') then return 'Vorbis' end
    if contains(codec_context, 'aac') then return 'AAC' end
    if contains(codec_context, 'mp3') or contains(codec_context, 'mpa') then return 'MP3' end
    if contains(codec_context, 'pcm') or contains(codec_context, 'lpcm') then return 'PCM' end
    if contains(codec_context, 'mlp') then return 'MLP' end
    local fallback = tostring(snapshot.audio_codec or '')
    return fallback ~= '' and fallback:upper() or ''
end

local function direct_layout_label(value)
    local text = lower(value)
    local three = text:match('(%d+%.%d+%.%d+)')
    if three then return three end
    local two = text:match('(%d+%.%d+)')
    if two then return two end
    if text:find('stereo', 1, true) or text:find('2ch', 1, true) then return '2.0' end
    if text:find('mono', 1, true) or text:find('1ch', 1, true) then return '1.0' end
    return nil
end

local function speaker_layout_label(value)
    local text = tostring(value or ''):upper()
    local speakers = {}
    for token in text:gmatch('[A-Z][A-Z0-9]+') do speakers[token] = true end
    local top_names = {'TFL', 'TFR', 'TFC', 'TBL', 'TBR', 'TBC', 'TSL', 'TSR'}
    local main_names = {'FL', 'FR', 'FC', 'BL', 'BR', 'SL', 'SR', 'WL', 'WR', 'BC'}
    local top, main = 0, 0
    for _, name in ipairs(top_names) do if speakers[name] then top = top + 1 end end
    for _, name in ipairs(main_names) do if speakers[name] then main = main + 1 end end
    if main > 0 and top > 0 then
        return string.format('%d.%d.%d', main, speakers.LFE and 1 or 0, top)
    end
    return nil
end

local function detect_audio_layout(snapshot)
    local params = type(snapshot.audio_params) == 'table' and snapshot.audio_params or {}
    local track = type(snapshot.audio_track) == 'table' and snapshot.audio_track or {}
    local candidates = {
        params['hr-channels'], params.channels, params['channel-layout'],
        track['demux-channel-layout'], track['channel-layout'],
    }
    for _, value in ipairs(candidates) do
        local layout = direct_layout_label(value) or speaker_layout_label(value)
        if layout then return layout end
    end

    local filename_layout = direct_layout_label(snapshot.filename)
    if filename_layout then return filename_layout end

    local count = tonumber(params['channel-count'])
        or tonumber(snapshot.audio_channel_count)
        or tonumber(snapshot.audio_channels)
        or tonumber(track['demux-channel-count'])
        or 0
    if count == 8 then return '7.1' end
    if count == 6 then return '5.1' end
    if count == 2 then return '2.0' end
    if count == 1 then return '1.0' end
    return count > 0 and (tostring(count) .. 'ch') or ''
end

local function resolution_labels(width, height, interlaced)
    if width <= 0 and height <= 0 then return '', '' end
    if width >= 7600 or height >= 4300 then return '8K', '8K UHD' end
    if width >= 3800 or height >= 2100 then return '4K', '4K UHD' end
    if width >= 2500 or height >= 1400 then return '1440P', '1440P QHD' end
    if width >= 1900 or height >= 1000 then
        local label = interlaced and '1080i' or '1080P'
        return label, label
    end
    if width >= 1200 or height >= 700 then
        local label = interlaced and '720i' or '720P'
        return label, label
    end
    if height > 0 then
        local label = tostring(math.floor(height + 0.5)) .. (interlaced and 'i' or 'P')
        return label, label
    end
    return '', ''
end

local function format_fps(value)
    local fps = tonumber(value) or 0
    if fps <= 0 then return '' end
    local rounded = math.floor(fps + 0.5)
    if math.abs(fps - rounded) < 0.015 then return tostring(rounded) .. 'FPS' end
    local precision = math.abs(fps * 1001 / 1000 - rounded) < 0.02 and 3 or 2
    return string.format('%.' .. tostring(precision) .. 'fFPS', fps)
end

function M.from_snapshot(snapshot)
    snapshot = type(snapshot) == 'table' and snapshot or {}
    local params = type(snapshot.video_params) == 'table' and snapshot.video_params or {}
    local frame_info = type(snapshot.video_frame_info) == 'table'
        and snapshot.video_frame_info or {}
    local width = tonumber(params.w or params.dw or params.width) or 0
    local height = tonumber(params.h or params.dh or params.height) or 0
    local video_raw, video_context = build_context(
        snapshot, snapshot.video_track, snapshot.video_codec, true
    )
    local audio_raw, audio_context = build_context(
        snapshot, snapshot.audio_track, snapshot.audio_codec, true
    )
    local _, audio_codec_context = build_context(
        snapshot, snapshot.audio_track, snapshot.audio_codec, false
    )
    local interlaced = frame_info.interlaced == true or snapshot.interlaced == true
    local resolution, resolution_long = resolution_labels(width, height, interlaced)
    local fps = tonumber(snapshot.fps) or 0
    if fps <= 0 then fps = tonumber(snapshot.container_fps) or 0 end

    return {
        video_present = width > 0 or height > 0,
        resolution = resolution,
        resolution_long = resolution_long,
        interlaced = interlaced,
        video_codec = detect_video_codec(video_context),
        dynamic_range = detect_dynamic_range(snapshot, video_context),
        fps = fps,
        fps_label = format_fps(fps),
        audio_codec = detect_audio_codec(
            snapshot, audio_raw, audio_context, audio_codec_context
        ),
        audio_layout = detect_audio_layout(snapshot),
        hwdec = snapshot.hwdec and snapshot.hwdec ~= '' and snapshot.hwdec ~= 'no'
            and 'HW' or 'SW',
    }
end

function M.collect()
    return M.from_snapshot(read_snapshot())
end

return M
