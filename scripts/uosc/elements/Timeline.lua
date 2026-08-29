local Element = require('elements/Element')
local mp_utils = require('mp.utils')

local function load_media_format_info()
	local candidates = {}
	local function add(path)
		if path and path ~= '' then candidates[#candidates + 1] = path end
	end
	add(mp.command_native({'expand-path', '~~/script-modules/media-format-info.lua'}))
	local source = debug.getinfo(1, 'S').source:gsub('^@', '')
	local script_dir = select(1, mp_utils.split_path(source))
	local parent = ''
	for _ = 1, 4 do
		parent = parent .. '../'
		add(mp_utils.join_path(script_dir, parent .. 'script-modules/media-format-info.lua'))
	end
	local last_error = ''
	for _, path in ipairs(candidates) do
		if path and path ~= '' then
			local ok, result = pcall(dofile, path)
			if ok and type(result) == 'table' then return result end
			last_error = tostring(result)
		end
	end
	error('Unable to load media-format-info.lua: ' .. last_error)
end

local MediaFormatInfo = load_media_format_info()

---@class Timeline : Element
local Timeline = class(Element)

local MEDIA_INFO_FONT_SIZE = 16
local MEDIA_INFO_CAPSULE_HEIGHT = 27
local MEDIA_INFO_TIMELINE_OFFSET = 45
local MEDIA_INFO_PICTURE_INSET = 10
local MEDIA_INFO_LETTER_SPACING = 0.2

-- Keep the slim timeline visual while making pointer interaction more
-- forgiving. Values are logical pixels and scale with uosc/DPI.
local SEEK_HITBOX_EXPAND_TOP = 1
local SEEK_HITBOX_EXPAND_BOTTOM = 1
local MISS_GUARD_HEIGHT = 12
local CONTROLS_HITBOX_GAP = 2

-- Media info cache, forward-declared before init to avoid nil reference
local media_info_segments = nil
local media_info_last_update = 0
local function invalidate_media_info() media_info_last_update = 0 end

-- Dynamic range cache (read once per file, retry up to 3 times if video-params not ready)
local cached_dynamic_range_text = ''
local cached_dynamic_range_done = false
local dynamic_range_retries = 0
local MAX_DYNAMIC_RANGE_RETRIES = 3
local function invalidate_dynamic_range()
	cached_dynamic_range_text = ''
	cached_dynamic_range_done = false
	dynamic_range_retries = 0
end

-- Bitrate cache (read once per file, cached as display string)
local cached_bitrate_text = ''
local cached_bitrate_done = false
local function invalidate_bitrate()
	cached_bitrate_text = ''
	cached_bitrate_done = false
end

local function is_likely_remote_path(path)
	if not path or path == '' then return true end
	local lower = path:lower()
	return lower:match('^https?://') ~= nil
		or lower:match('^rtmp[s]?://') ~= nil
		or lower:match('^webdav[s]?://') ~= nil
		or lower:match('^dav[s]?://') ~= nil
		or lower:match('^s?ftp://') ~= nil
		or lower:match('^mms[t]?://') ~= nil
end

-- nil-safe numeric helpers
local function safe_num(value)
	return tonumber(value)
end

local function has_positive_number(value)
	local n = tonumber(value)
	return n ~= nil and n > 0
end

-- Return the displayed video's vertical bounds in uosc coordinates. The OSD
-- margins change with window and video aspect ratios, so they are a more
-- stable anchor than the timeline alone when letterboxing is present.
local function get_video_display_vertical_bounds()
	local dimensions = mp.get_property_native('osd-dimensions', {})
	local osd_height = type(dimensions) == 'table' and safe_num(dimensions.h) or nil
	local display_height = safe_num(display.height)
	if not osd_height or osd_height <= 0 or not display_height or display_height <= 0 then
		return nil, nil
	end

	local scale_y = display_height / osd_height
	local top = clamp(0, (safe_num(dimensions.mt) or 0) * scale_y, display_height)
	local bottom = clamp(0, (osd_height - (safe_num(dimensions.mb) or 0)) * scale_y, display_height)
	if bottom <= top then return nil, nil end
	return top, bottom
end

-- Read current video track info once (prefer current-tracks/video, fallback to track-list)
local function read_video_track_once()
	local track = mp.get_property_native('current-tracks/video', {})
	if type(track) == 'table' and track.type == 'video' then
		return track
	end
	local track_list = mp.get_property_native('track-list', {})
	if type(track_list) == 'table' then
		for _, t in ipairs(track_list) do
			if type(t) == 'table' and t.type == 'video' then
				return t
			end
		end
	end
	return {}
end

-- Dolby Vision label from track metadata (dolby-vision-profile / dolby-vision-level)
local function detect_dolby_vision_label(track)
	if type(track) ~= 'table' then return nil end

	-- Primary: dolby-vision-profile from track metadata
	local profile = tonumber(track['dolby-vision-profile'])
	if profile and profile > 0 then
		if profile == 5 then return 'DV P5'
		elseif profile == 7 then return 'DV P7'
		elseif profile == 8 then return 'DV P8'
		else return 'DV P' .. tostring(profile) end
	end

	-- Fallback: video-params property
	local dvp_vp = mp.get_property('video-params/dolby-vision-profile', '')
	if dvp_vp and dvp_vp ~= '' then
		local p = tonumber(dvp_vp)
		if p and p > 0 then
			if p == 5 then return 'DV P5'
			elseif p == 7 then return 'DV P7'
			elseif p == 8 then return 'DV P8'
			else return 'DV P' .. tostring(p) end
			end
		end

	-- If DV level exists but no profile, signal DV without profile
	if track['dolby-vision-level'] ~= nil then return 'DV' end
	local dvl_vp = mp.get_property('video-params/dolby-vision-level', '')
	if dvl_vp and dvl_vp ~= '' then return 'DV' end
	local colormatrix = mp.get_property('video-params/colormatrix', ''):lower()
	if colormatrix == 'dolbyvision' then return 'DV' end

	return nil
end

-- HDR10+ detection: scene-max-r/g/b from video-params or track metadata
local function detect_hdr10plus(params, track)
	if type(params) == 'table' then
		if has_positive_number(params['scene-max-r'])
			or has_positive_number(params['scene-max-g'])
			or has_positive_number(params['scene-max-b']) then
			return true
		end
	end
	if type(track) == 'table' then
		if track['hdr10plus'] == true then return true end
		if has_positive_number(track['scene-max-r'])
			or has_positive_number(track['scene-max-g'])
			or has_positive_number(track['scene-max-b']) then
			return true
		end
	end
	return false
end

-- HDR Vivid (CUVA HDR) detection from metadata keywords
local function detect_hdr_vivid(track, params)
	local function check_value(v)
		if type(v) == 'string' then
			local vl = v:lower():gsub('[%s%._%-]', '')
			if vl:match('hdrvivid') or vl:match('cuvahdr') or vl:match('cuva') then
				return true
			end
		end
		return false
	end
	local function check_metadata(source)
		if type(source) ~= 'table' then return false end
		for k, v in pairs(source) do
			local normalized_key = type(k) == 'string'
				and k:lower():gsub('[%s%._%-]', '') or ''
			local positive_flag = v == true or v == 1
				or (type(v) == 'string'
					and (v:lower() == 'yes' or v:lower() == 'true'))
			-- `video-params` always contains an `hdr-vivid` key.  Its presence
			-- is not evidence when the value is false.
			if normalized_key == 'hdrvivid' and positive_flag then return true end
			if check_value(v) then return true end
		end
		return false
	end
	if check_metadata(track) or check_metadata(params) then return true end
	if check_value(mp.get_property('filename', ''))
		or check_value(mp.get_property('media-title', ''))
		or check_value(mp.get_property('path', '')) then
		return true
	end
	return false
end

-- Detect dynamic range label once per file, with retry safety
local function detect_dynamic_range_text_once()
	if cached_dynamic_range_done then
		return cached_dynamic_range_text
	end

	local video_params = mp.get_property_native('video-params', {})
	local h = safe_num(video_params and (video_params['h'] or video_params['height']))
	if not h or h <= 0 then
		dynamic_range_retries = dynamic_range_retries + 1
		if dynamic_range_retries < MAX_DYNAMIC_RANGE_RETRIES then
			return '' -- allow retry on next call
		end
		cached_dynamic_range_done = true
		cached_dynamic_range_text = ''
		return ''
	end

	local track = read_video_track_once()

	-- 1. Dolby Vision (highest priority)
	local dv_label = detect_dolby_vision_label(track)
	if dv_label then
		cached_dynamic_range_done = true
		cached_dynamic_range_text = dv_label
		return dv_label
	end

	local gamma = tostring(video_params['gamma'] or video_params['transfer'] or ''):lower()

	-- 2. HDR Vivid
	if detect_hdr_vivid(track, video_params) then
		cached_dynamic_range_done = true
		cached_dynamic_range_text = 'HDR Vivid'
		return 'HDR Vivid'
	end

	-- 3. HDR10+ (must be PQ-based)
	if gamma == 'pq' or gamma == 'smpte2084' then
		if detect_hdr10plus(video_params, track) then
			cached_dynamic_range_done = true
			cached_dynamic_range_text = 'HDR10+'
			return 'HDR10+'
		end
	end

	-- 4. HLG
	if gamma == 'hlg' or gamma == 'arib-std-b67' then
		cached_dynamic_range_done = true
		cached_dynamic_range_text = 'HLG'
		return 'HLG'
	end

	-- 5. HDR10 (PQ + HDR10 static metadata)
	if gamma == 'pq' or gamma == 'smpte2084' then
		if type(video_params) == 'table' then
			if has_positive_number(video_params['max-cll'])
				or has_positive_number(video_params['max-fall'])
				or has_positive_number(video_params['min-luma'])
				or has_positive_number(video_params['max-luma']) then
				cached_dynamic_range_done = true
				cached_dynamic_range_text = 'HDR10'
				return 'HDR10'
			end
		end
		if type(track) == 'table' then
			if has_positive_number(track['max-cll'])
				or has_positive_number(track['max-fall'])
				or has_positive_number(track['min-luma'])
				or has_positive_number(track['max-luma']) then
				cached_dynamic_range_done = true
				cached_dynamic_range_text = 'HDR10'
				return 'HDR10'
			end
		end
		-- PQ without explicit HDR10 metadata: generic HDR label
		cached_dynamic_range_done = true
		cached_dynamic_range_text = 'HDR'
		return 'HDR'
	end

	-- 6. SDR (fallback)
	cached_dynamic_range_done = true
	cached_dynamic_range_text = 'SDR'
	return 'SDR'
end

local function format_bitrate_kbps(kbps)
	if not kbps or kbps <= 0 then return nil end
	if kbps >= 100000 then
		return string.format('%dMbps', math.floor(kbps / 1000 + 0.5))
	elseif kbps >= 1000 then
		return string.format('%.1fMbps', kbps / 1000)
	else
		return string.format('%dKbps', kbps)
	end
end

local function read_bitrate_text_once()
	if cached_bitrate_done then return cached_bitrate_text end

	local track_list = mp.get_property_native('track-list', {})
	if type(track_list) == 'table' then
		for _, track in ipairs(track_list) do
			if type(track) == 'table' and track.type == 'video' then
				local demux_br = tonumber(track['demux-bitrate'])
				if demux_br and demux_br > 0 then
					cached_bitrate_done = true
					local kbps = math.floor(demux_br / 1000 + 0.5)
					cached_bitrate_text = format_bitrate_kbps(kbps) or ''
					return cached_bitrate_text
				end
			end
		end
	end

	local path = mp.get_property('path', '')
	local is_remote = is_likely_remote_path(path)

	local file_size = mp.get_property_number('file-size', 0)
	local duration = mp.get_property_number('duration', 0)
	if file_size > 0 and duration > 0 then
		cached_bitrate_done = true
		local kbps = math.floor(file_size * 8 / duration / 1000 + 0.5)
		cached_bitrate_text = format_bitrate_kbps(kbps) or ''
		return cached_bitrate_text
	end

	-- Remote path: demux-bitrate / file-size may not be ready yet, allow retry
	if is_remote then
		return ''
	end

	-- Local file: definitively no bitrate, cache permanently to avoid re-scan
	cached_bitrate_done = true
	cached_bitrate_text = ''
	return cached_bitrate_text
end

local function add_media_capsule(parts, text, tone, priority, group, compact_before)
	if text and text ~= '' then
		parts[#parts + 1] = {
			text = text,
			tone = tone or 'base',
			priority = priority or 0,
			group = group or tone or 'base',
			compact_before = compact_before == true,
		}
	end
end

local function format_resolution_label(w, h)
	if w <= 0 and h <= 0 then return '' end
	if w >= 7600 or h >= 4320 then
		return '8K UHD'
	elseif w >= 3800 or h >= 2160 then
		return '4K UHD'
	elseif w >= 2500 or h >= 1400 then
		return '2K QHD'
	elseif w >= 1900 or h >= 1000 then
		return '1080P'
	elseif w >= 1200 or h >= 700 then
		return '720P'
	elseif h > 0 then
		return tostring(math.floor(h)) .. 'P'
	end
	return ''
end

local function read_audio_layout_text()
	local hr_channels = mp.get_property('audio-params/hr-channels', ''):lower()
	if hr_channels ~= '' then
		if hr_channels:find('7%.1') then
			return '7.1'
		elseif hr_channels:find('5%.1') then
			return '5.1'
		elseif hr_channels:find('stereo') or hr_channels:find('2ch') then
			return '2.0'
		elseif hr_channels:find('mono') or hr_channels:find('1ch') then
			return '1.0'
		end
	end

	local channels = mp.get_property_number('audio-params/channel-count', 0)
	if channels <= 0 then channels = mp.get_property_number('audio-channels', 0) end
	if channels == 8 then
		return '7.1'
	elseif channels == 6 then
		return '5.1'
	elseif channels == 2 then
		return '2.0'
	elseif channels == 1 then
		return '1.0'
	elseif channels > 0 then
		return tostring(channels) .. 'ch'
	end
	return ''
end

local function read_audio_codec_text()
	local codec = mp.get_property('audio-codec', '')
	if codec == '' then return '' end
	local lower = codec:lower()
	local track = mp.get_property_native('current-tracks/audio', {})
	local title = type(track) == 'table' and tostring(track.title or ''):lower() or ''

	if lower:find('av3a') or lower:find('audio vivid') or lower:find('audio_vivid')
		or title:find('av3a') or title:find('audio vivid') or title:find('audio_vivid') or title:find('菁彩声') then
		return 'Audio Vivid'
	elseif lower:find('truehd') or lower:find('mlp') then
		return 'TrueHD'
	elseif lower:find('dts%-hd') or lower:find('dtshd') or lower:find('dts hd') then
		return 'DTS-HD'
	elseif lower:find('dts') or lower:find('dca') then
		return 'DTS'
	elseif lower:find('e%-ac%-3') or lower:find('e%-ac3') or lower:find('eac3') or lower:find('dd%+') then
		return 'E-AC3'
	elseif lower:find('ac%-3') or lower:find('ac3') or lower:find('dolby') then
		return 'Dolby Digital'
	elseif lower:find('flac') then
		return 'FLAC'
	elseif lower:find('opus') then
		return 'Opus'
	elseif lower:find('aac') then
		return 'AAC'
	elseif lower:find('mp3') then
		return 'MP3'
	elseif lower:find('pcm') then
		return 'PCM'
	end

	return codec:upper()
end

local function is_premium_audio(codec, layout)
	return codec == 'Audio Vivid'
		or codec == 'Dolby Atmos'
		or codec == 'DTS:X'
		or codec == 'Dolby TrueHD'
		or codec == 'DTS-HD MA'
		or codec == 'DTS-HD HRA'
		or codec == 'Dolby Digital Plus'
		or codec == 'Dolby AC-4'
		or codec == 'MPEG-H Audio'
		or codec == 'DTS'
		or codec == 'FLAC'
		or layout:match('^[579]%.1') ~= nil
end

-- 视频位深：从像素格式推断，8bit 返回空串（不显示）
local function video_bit_depth_label()
	local fmt = tostring(mp.get_property('video-params/pixelformat') or '')
	if fmt:find('10le', 1, true) or fmt:find('10be', 1, true)
		or fmt:find('p010', 1, true) or fmt:find('rgb30', 1, true) then
		return '10bit'
	end
	if fmt:find('12le', 1, true) or fmt:find('12be', 1, true)
		or fmt:find('p012', 1, true) then
		return '12bit'
	end
	if fmt:find('16le', 1, true) or fmt:find('16be', 1, true)
		or fmt:find('p016', 1, true) or fmt:find('rgb48', 1, true) then
		return '16bit'
	end
	return ''
end

-- 当前音轨位置与语言：多音轨文件才显示，如 "音轨 2/4 国配"
local function audio_track_label()
	local tl = mp.get_property_native('track-list') or {}
	local total, selected, lang = 0, 0, ''
	for _, t in ipairs(tl) do
		if type(t) == 'table' and t.type == 'audio' then
			total = total + 1
			if t.selected then
				selected = total
				lang = tostring(t.title or '')
				if lang == '' and type(t.lang) == 'string' and #t.lang <= 8 then
					lang = t.lang
				end
			end
		end
	end
	if total < 2 or selected == 0 then return '' end
	local label = ('音轨 %d/%d'):format(selected, total)
	if lang ~= '' then label = label .. ' ' .. lang end
	return label
end

-- 字幕状态：存在字幕轨才显示，如 "字幕 开(简中)" / "字幕 关"
local function subtitle_label()
	local sub = mp.get_property_native('current-tracks/sub')
	if type(sub) ~= 'table' then return '' end
	local lang = tostring(sub.title or '')
	if lang == '' and type(sub.lang) == 'string' and #sub.lang <= 8 then
		lang = sub.lang
	end
	local vis = mp.get_property('sub-visibility')
	if vis == 'yes' or vis == true then
		return lang ~= '' and ('字幕 开(' .. lang .. ')') or '字幕 开'
	end
	return '字幕 关'
end

-- HDR→SDR 映射提示：片源 HDR 且输出明确非 HDR 时显示
local function hdr_mapping_label(dynamic_range)
	if dynamic_range == '' or dynamic_range == 'SDR' then return '' end
	local hdr_status = tostring(mp.get_property_native('user-data/display-info/hdr-status') or '')
	if hdr_status == 'on' then return '' end
	if hdr_status == 'off' then return '映射' end
	-- 没有 display-info 状态时按渲染目标推断：明确非 PQ 才算 SDR 输出
	local trc = tostring(mp.get_property('target-trc') or '')
	if trc ~= '' and trc ~= 'pq' and trc ~= 'auto' then return '映射' end
	return ''
end

function Timeline:new() return Class.new(self) --[[@as Timeline]] end
function Timeline:init()
	Element.init(self, 'timeline', {render_order = 5})
	---@type false|{pause: boolean, distance: number, last: {x: number, y: number}}
	self.pressed = false
	self.obstructed = false
	self.size = 0
	self.progress_size = 0
	self.min_progress_size = 0 -- used for `flash-progress`
	self.font_size = 0
	self.top_border = 0
	self.line_width = 0
	self.progress_line_width = 0
	self.is_hovered = false
	self.has_thumbnail = false
	self.heatmap = nil
	self.edit_active = false
	self.edit_kind = nil
	self.edit_source = nil
	self.edit_deletable = false
	self.edit_start = 0
	self.edit_end = 0
	self.edit_drag = nil
	self.file_browser_open = false

	self:observe_mp_property('user-data/skip-segments/edit-active', 'bool', function(_, value)
		self.edit_active = value == true
		if not self.edit_active then self.edit_drag = nil end
		request_render()
	end)
	self:observe_mp_property('user-data/skip-segments/edit-kind', 'string', function(_, value)
		self.edit_kind = value
		request_render()
	end)
	self:observe_mp_property('user-data/skip-segments/edit-source', 'string', function(_, value)
		self.edit_source = value
		request_render()
	end)
	self:observe_mp_property('user-data/skip-segments/edit-deletable', 'bool', function(_, value)
		self.edit_deletable = value == true
		request_render()
	end)
	self:observe_mp_property('user-data/skip-segments/edit-start', 'number', function(_, value)
		if value then self.edit_start = value end
		request_render()
	end)
	self:observe_mp_property('user-data/skip-segments/edit-end', 'number', function(_, value)
		if value then self.edit_end = value end
		request_render()
	end)
	self:observe_mp_property('user-data/file_browser/open', 'bool', function(_, value)
		self.file_browser_open = value == true
		if self.file_browser_open then
			self.pressed = false
			self.edit_drag = nil
		end
		request_render()
	end)
	self:observe_mp_property('user-data/alist/speed-text', 'string', function() request_render() end)
	self:observe_mp_property('user-data/alist/playing', 'bool', function() request_render() end)
	local function invalidate_media_info_and_render()
		invalidate_media_info()
		request_render()
	end
	self:observe_mp_property('hwdec-current', 'string', invalidate_media_info_and_render)
	self:observe_mp_property('video-params', 'native', function()
		invalidate_media_info()
		invalidate_dynamic_range()
		request_render()
	end)
	self:observe_mp_property('video-frame-info', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('video-codec', 'string', invalidate_media_info_and_render)
	self:observe_mp_property('user-data/media-format/dolby-vision-profile', 'number',
		invalidate_media_info_and_render)
	self:observe_mp_property('vid', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('estimated-vf-fps', 'number', invalidate_media_info_and_render)
	self:observe_mp_property('audio-codec', 'string', invalidate_media_info_and_render)
	self:observe_mp_property('audio-params', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('aid', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('vf', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('glsl-shaders', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('speed', 'number', invalidate_media_info_and_render)
	self:observe_mp_property('user-data/rife', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('af', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('track-list', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('current-tracks/sub', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('sub-visibility', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('decoder-frame-drop-count', 'number', invalidate_media_info_and_render)
	self:observe_mp_property('user-data/display-info/hdr-status', 'native', invalidate_media_info_and_render)
	self:observe_mp_property('target-trc', 'string', invalidate_media_info_and_render)
	self:decide_progress_size()
	self:update_dimensions()

	-- Load Youtube heatmap data if available; also invalidate media info cache
	self:register_mp_event('file-loaded', function()
		self.heatmap = load_youtube_heatmap()
		invalidate_media_info()
		invalidate_bitrate()
		invalidate_dynamic_range()
	end)
	-- Release any dragging and clear heatmap when file gets unloaded
	self:register_mp_event('end-file', function()
		self.pressed = false
		self.heatmap = nil
	end)
	self:register_mp_event('video-reconfig', function()
		invalidate_media_info()
		invalidate_bitrate()
		invalidate_dynamic_range()
	end)
end

function Timeline:get_target_visibility()
	if self.edit_active then return 1 end
	return math.max(Elements:maybe('controls', 'get_target_visibility') or 0, Element.get_visibility(self))
end

function Timeline:get_minimized_progress_proximity()
	local progress_size = math.max(self.min_progress_size, self.progress_size)
	if progress_size <= 0 or cursor.hidden then return 0 end
	local window_border = Elements:v('window_border', 'size', 0)
	local bottom = display.height - window_border
	local hitbox = {
		ax = 0,
		ay = bottom - math.max(progress_size, 2),
		bx = display.width,
		by = bottom,
	}
	local raw = get_point_to_rectangle_proximity(cursor, hitbox)
	local range = options.proximity_out - options.proximity_in
	return 1 - (clamp(0, raw - options.proximity_in, range) / range)
end

function Timeline:get_dock_target()
	return self.enabled and math.max(
		self:get_target_visibility(), self:get_minimized_progress_proximity()
	)
		or (Elements:maybe('controls', 'get_target_visibility') or 0)
end

function Timeline:get_visibility()
	return dock_motion and dock_motion:get_visibility() or self:get_target_visibility()
end

function Timeline:decide_enabled()
	local previous = self.enabled
	self.enabled = not self.obstructed and state.duration ~= nil and state.duration > 0 and state.time ~= nil
	if self.enabled ~= previous then Elements:trigger('timeline_enabled', self.enabled) end
end

function Timeline:get_effective_size()
	if Elements:v('speed', 'dragging') then return self.size end
	local progress_size = math.max(self.min_progress_size, self.progress_size)
	local geometry = dock_motion and dock_motion:get_timeline_geometry() or self:get_visibility()
	return progress_size + (self.size - progress_size) * geometry
end

function Timeline:get_is_hovered() return self.enabled and self.is_hovered end

---@return number|nil
function Timeline:get_loaded_pos_safe()
	if type(state.duration) ~= 'number' or state.duration <= 0 then return nil end
	if type(state.time) ~= 'number' then return nil end

	-- Prefer uncached_ranges: find the first uncached gap after current time
	if type(state.uncached_ranges) == 'table' and #state.uncached_ranges > 0 then
		for _, range in ipairs(state.uncached_ranges) do
			if type(range) == 'table'
				and type(range[1]) == 'number'
				and type(range[2]) == 'number'
			then
				if range[1] <= state.time and range[2] >= state.time then
					return nil -- current position is inside an uncached gap
				end
				if range[1] > state.time then
					return math.max(state.time, math.min(range[1], state.duration))
				end
			end
		end
		return state.duration -- no uncached gap after current time
	end

	-- Fallback: cache_duration
	if type(state.cache_duration) == 'number' and state.cache_duration > 0 then
		return math.min(state.time + state.cache_duration, state.duration)
	end

	return nil
end

function Timeline:sync_horizontal_bounds()
	local controls_ax, controls_bx = Elements:maybe('controls', 'get_visual_bounds')
	if controls_ax and controls_bx and controls_bx > controls_ax then
		self.ax, self.bx = controls_ax, controls_bx
		self.width = self.bx - self.ax
	end
end

function Timeline:update_dimensions()
	self.size = round(options.timeline_size * state.scale)
	self.top_border = round(options.timeline_border * state.scale)
	self.line_width = round(options.timeline_line_width * state.scale)
	self.progress_line_width = round(options.progress_line_width * state.scale)
	self.font_size = math.floor(math.min((self.size + 60 * state.scale) * 0.2, self.size * 0.96) * options.font_scale)
	local window_border_size = Elements:v('window_border', 'size', 0)
	local controls_size = round(options.controls_size * state.scale)
	local controls_margin = round(options.controls_margin * state.scale)
	-- Keep the line inset near the outer buttons' visual center instead of
	-- stretching it almost edge-to-edge across the window.
	local side_margin = round(math.max(24, options.controls_margin * 2) * state.scale)
	local fullscreen_timeline_gap = state.fullormaxed
		and round(options.controls_size * state.scale * 0.18)
		or 0
	self.ax = window_border_size + side_margin
	self.ay = display.height - window_border_size - controls_size - controls_margin * 2
		- fullscreen_timeline_gap - self.size
	self.bx = display.width - window_border_size - side_margin
	self.by = self.ay + self.size
	self.width = self.bx - self.ax
	self.panel_top = self.ay - round(8 * state.scale)
	self.chapter_size = math.max((self.by - self.ay) / 10, 3)
	self.chapter_size_hover = self.chapter_size * 2

	-- Disable if not enough space
	local available_space = display.height - window_border_size * 2 - Elements:v('top_bar', 'size', 0)
	self.obstructed = available_space < self.size + 10
	self:decide_enabled()
end

function Timeline:decide_progress_size()
	local show
	if dock_motion then
		show = dock_motion:is_minimized_progress_enabled()
	else
		show = options.progress == 'always'
			or (options.progress == 'fullscreen' and state.fullormaxed)
			or (options.progress == 'windowed' and not state.fullormaxed)
	end
	self.progress_size = show and options.progress_size or 0
	if not show then
		self.min_progress_size = 0
		if self._flash_progress_timer then self._flash_progress_timer:kill() end
	end
end

function Timeline:toggle_progress()
	if dock_motion and not dock_motion:is_minimized_progress_enabled() then
		self.progress_size = 0
		self.min_progress_size = 0
		request_render()
		return
	end
	local current = self.progress_size
	self:tween_property('progress_size', current, current > 0 and 0 or options.progress_size)
	request_render()
end

function Timeline:flash_progress()
	if dock_motion and not dock_motion:is_minimized_progress_enabled() then return end
	if self.enabled and options.flash_duration > 0 then
		if not self._flash_progress_timer then
			self._flash_progress_timer = mp.add_timeout(options.flash_duration / 1000, function()
				self:tween_property('min_progress_size', options.progress_size, 0)
			end)
			self._flash_progress_timer:kill()
		end

		self:tween_stop()
		self.min_progress_size = options.progress_size
		request_render()
		self._flash_progress_timer.timeout = options.flash_duration / 1000
		self._flash_progress_timer:kill()
		self._flash_progress_timer:resume()
	end
end

function Timeline:get_time_at_x(x)
	local line_width = (options.timeline_style == 'line' and self.line_width - 1 or 0)
	local time_width = self.width - line_width - 1
	local fax = (time_width) * state.time / state.duration
	local fbx = fax + line_width
	-- time starts 0.5 pixels in
	x = x - self.ax - 0.5
	if x > fbx then
		x = x - line_width
	elseif x > fax then
		x = fax
	end
	local progress = clamp(0, x / time_width, 1)
	return state.duration * progress
end

function Timeline:cursor_command(command)
	if type(command) == 'string' and #command > 0 and state.time and state.duration then
		local expanded_command = command:gsub('{time}', self:get_time_at_x(cursor.x))
		mp.command(expanded_command)
	end
end

---@param fast? boolean
function Timeline:set_from_cursor(fast)
	if state.time and state.duration then
		mp.commandv('seek', self:get_time_at_x(cursor.x), fast and 'absolute+keyframes' or 'absolute+exact')
	end
end

function Timeline:clear_thumbnail()
	if self.has_thumbnail then
		mp.commandv('script-message-to', 'thumbfast', 'clear')
		self.has_thumbnail = false
	end
end

function Timeline:handle_cursor_down()
	local ai_active = mp.get_property_native('user-data/video-enhancement/ai-active')
	self.pressed = {
		pause = state.pause,
		distance = 0,
		dragging = false,
		-- A VapourSynth/RIFE graph must refill its temporal frame window after
		-- every seek.  Repeating keyframe seeks on every mouse move turns one
		-- timeline drag into a series of visible stalls.  While real RIFE 2x is
		-- active, keep the existing timeline/thumbnail preview and issue only the
		-- exact landing seek on release.  Native playback retains live scrubbing.
		ai_preview_only = ai_active == true or ai_active == 'yes',
		last = {x = cursor.x, y = cursor.y},
	}
end
function Timeline:on_prop_duration() self:decide_enabled() end
function Timeline:on_prop_time() self:decide_enabled() end
function Timeline:on_prop_uncached_ranges() request_render() end
function Timeline:on_prop_cache_duration() request_render() end
function Timeline:on_prop_pause()
	self:decide_progress_size()
	request_render()
end
function Timeline:on_prop_is_idle()
	self:decide_progress_size()
	request_render()
end
function Timeline:on_prop_eof_reached() self:decide_progress_size() end
function Timeline:on_prop_border() self:update_dimensions() end
function Timeline:on_prop_title_bar() self:update_dimensions() end
function Timeline:on_prop_fullormaxed()
	self:decide_progress_size()
	self:update_dimensions()
end
function Timeline:on_display() self:update_dimensions() end
function Timeline:on_options()
	self:decide_progress_size()
	self:update_dimensions()
end
function Timeline:handle_cursor_up()
	if self.pressed then
		local was_dragging = self.pressed.dragging
		self:set_from_cursor()
		if was_dragging then mp.set_property_native('pause', self.pressed.pause) end
		self.pressed = false
	end
end
function Timeline:on_global_mouse_leave()
	if self.pressed and self.pressed.dragging then
		mp.set_property_native('pause', self.pressed.pause)
	end
	self.pressed = false
end

function Timeline:on_global_mouse_move()
	if self.edit_drag and state.duration then
		local value = clamp(0, self:get_time_at_x(cursor.x), state.duration - 0.05)
		if self.edit_drag == 'start' then
			value = math.min(value, self.edit_end - 1)
			self.edit_start = math.max(0, value)
			mp.set_property_number('user-data/skip-segments/edit-start', self.edit_start)
		else
			value = math.max(value, self.edit_start + 1)
			self.edit_end = math.min(state.duration - 0.05, value)
			mp.set_property_number('user-data/skip-segments/edit-end', self.edit_end)
		end
		request_render()
		return
	end
	if self.pressed then
		self.pressed.distance = self.pressed.distance + get_point_to_point_proximity(self.pressed.last, cursor)
		self.pressed.last.x, self.pressed.last.y = cursor.x, cursor.y
		local drag_threshold = math.max(4, round(4 * state.scale))
		if not self.pressed.dragging and self.pressed.distance >= drag_threshold then
			self.pressed.dragging = true
			mp.set_property_native('pause', true)
		end
		if self.pressed.dragging then
			-- Scrubbing must remain cheap even when the cursor moves slowly.
			-- The exact landing seek is issued only once on mouse release.
			if not self.pressed.ai_preview_only then self:set_from_cursor(true) end
		end
	end
end

local function build_media_info_segments()
	local now = mp.get_time()
	if now - media_info_last_update < 5 and media_info_segments then
		return media_info_segments
	end
	media_info_last_update = now

	local info = MediaFormatInfo.collect()
	if not info.video_present then
		media_info_segments = {}
		return media_info_segments
	end

	local parts = {}

	-- HW/SW: keep the current playback state first for quick confirmation.
	if info.hwdec == 'HW' then
		add_media_capsule(parts, '硬解', 'muted', 96, 'decode')
	else
		add_media_capsule(parts, '软解', 'muted', 96, 'decode')
	end

	-- RIFE 补帧：以滤镜链中的 @rife 标签为准（滤镜初始化失败会被 mpv 自动移除），
	-- 倍数读 rife.lua 发布的 user-data
	local rife_active = false
	for _, filter in ipairs(mp.get_property_native('vf') or {}) do
		if filter.label == 'rife' then
			rife_active = true
			break
		end
	end
	if rife_active then
		local rife_state = mp.get_property_native('user-data/rife')
		local multi = rife_state and tonumber(tostring(rife_state.multi)) or 0
		add_media_capsule(parts, multi > 0 and ('RIFE ×%g'):format(multi) or 'RIFE', 'hero', 95, 'enhance')
	end

	-- 已启用的 GLSL 着色器数量
	local shader_count = #(mp.get_property_native('glsl-shaders') or {})
	if shader_count > 0 then
		add_media_capsule(parts, ('着色器 ×%d'):format(shader_count), 'primary', 70, 'enhance')
	end

	-- 已启用的音频滤镜数量（drcbox/EQ 等）
	local af_count = 0
	for _, filter in ipairs(mp.get_property_native('af') or {}) do
		if type(filter) == 'table' and filter.enabled ~= false then
			af_count = af_count + 1
		end
	end
	if af_count > 0 then
		add_media_capsule(parts, ('音效 ×%d'):format(af_count), 'primary', 65, 'enhance')
	end

	-- Resolution
	local resolution_text = info.resolution_long
	local bit_depth = video_bit_depth_label()
	if bit_depth ~= '' then resolution_text = resolution_text .. ' ' .. bit_depth end
	add_media_capsule(parts, resolution_text, 'primary', 80, 'picture')

	-- Dynamic range
	local dynamic_range = info.dynamic_range
	if dynamic_range ~= '' then
		add_media_capsule(parts, dynamic_range, 'hero', 100, 'picture')
	end
	-- HDR→SDR 映射提示（仅片源 HDR 且输出非 HDR 时出现）
	local mapping_label = hdr_mapping_label(dynamic_range)
	if mapping_label ~= '' then
		add_media_capsule(parts, mapping_label, 'muted', 92, 'picture')
	end

	-- 交错源（老 DVD/电视录制）
	if info.interlaced then
		add_media_capsule(parts, '交错', 'muted', 30, 'picture')
	end

	-- Framerate
	add_media_capsule(parts, info.video_codec, 'primary', 60, 'video')
	add_media_capsule(parts, info.fps_label, 'muted', 55, 'video')

	local audio_codec = info.audio_codec
	local audio_layout = info.audio_layout
	if audio_codec ~= '' or audio_layout ~= '' then
		local premium = is_premium_audio(audio_codec, audio_layout)
		local priority = premium and 65 or 35
		add_media_capsule(parts, audio_codec, 'primary', priority, 'audio')
		add_media_capsule(parts, audio_layout, 'muted', priority, 'audio')
	end
	-- 音轨序号（多音轨文件）
	local audio_track = audio_track_label()
	if audio_track ~= '' then
		add_media_capsule(parts, audio_track, 'muted', 40, 'audio')
	end

	-- 字幕状态
	local subtitle = subtitle_label()
	if subtitle ~= '' then
		add_media_capsule(parts, subtitle, 'primary', 50, 'sub')
	end

	-- 倍速：仅在与原速不同时显示
	local speed = mp.get_property_number('speed', 1)
	if math.abs(speed - 1) > 0.001 then
		add_media_capsule(parts, ('倍速 ×%g'):format(speed), 'primary', 45, 'playback')
	end

	-- Bitrate
	local br_text = read_bitrate_text_once()
	if br_text and br_text ~= '' then
		add_media_capsule(parts, '码率', 'muted', 25, 'throughput')
		add_media_capsule(parts, br_text, 'primary', 25, 'throughput', true)
	end
	-- 解码丢帧（仅丢帧时出现，卡顿诊断）
	local drop_count = mp.get_property_number('decoder-frame-drop-count', 0)
	if drop_count > 0 then
		add_media_capsule(parts, ('丢帧 %d'):format(drop_count), 'muted', 58, 'throughput')
	end

	media_info_segments = parts
	return media_info_segments
end

local function copy_media_info_segments(segments)
	local copied = {}
	local speed = mp.get_property_native('user-data/alist/speed-text', '')
	local speed_value = tonumber(tostring(speed):match('([%d%.]+)')) or 0
	local has_network_speed = speed ~= '' and speed_value > 0
	for _, part in ipairs(segments or {}) do
		if type(part) == 'table' then
			copied[#copied + 1] = table_assign({}, part)
		else
			copied[#copied + 1] = {text = tostring(part), tone = 'base', priority = 0, group = 'base'}
		end
	end

	if has_network_speed then
		copied[#copied + 1] = {
			text = '网络',
			tone = 'muted',
			priority = 90,
			group = 'throughput',
		}
		copied[#copied + 1] = {
			text = speed,
			tone = 'primary',
			priority = 90,
			group = 'throughput',
			compact_before = true,
		}
	end

	return copied
end

local function render_media_info_segments(ass, x, y, segments, visibility, max_width)
	local size = round(MEDIA_INFO_FONT_SIZE * state.scale)
	local item_gap = round(12 * state.scale)
	local compact_gap = round(5 * state.scale)
	local capsule_gap = round(7 * state.scale)
	local capsule_padding = round(9 * state.scale)
	local capsule_height = round(MEDIA_INFO_CAPSULE_HEIGHT * state.scale)
	local capsule_radius = round(5 * state.scale)
	local cursor_x = x
	local max_x = max_width and (x + max_width) or display.width
	local base_opts = {
		size = size,
		color = config.color.menu_text or config.color.time_current or bgt,
		opacity = visibility * 0.98,
		border = math.max(1, options.text_border * state.scale),
		border_color = bg,
		shadow = 0,
		bold = false,
	}
	local hero_accent = config.color.menu_active or config.color.match
		or config.color.menu_foreground or fg
	local function visual_group(segment)
		local group = segment.group or segment.tone or 'base'
		if group == 'decode' or group == 'picture' then return 'picture' end
		return group
	end

	local groups = {}
	for _, segment in ipairs(segments) do
		local text = segment.text or ''
		if text ~= '' then
			local key = visual_group(segment)
			local group = groups[#groups]
			if not group or group.key ~= key then
				group = {key = key, segments = {}}
				groups[#groups + 1] = group
			end
			group.segments[#group.segments + 1] = segment
		end
	end

	for _, group in ipairs(groups) do
		local content_width = 0
		local prepared = {}
		local hero_group = false
		for index, segment in ipairs(group.segments) do
			local text_opts = table_assign({}, base_opts)
			if segment.tone == 'hero' then
				hero_group = true
				text_opts.color = config.color.match or hero_accent
				text_opts.opacity = visibility * 0.92
				text_opts.bold = true
			elseif segment.tone == 'primary' then
				-- Primary values stay within the existing cool-white palette.
				text_opts.opacity = visibility
				text_opts.bold = true
			elseif segment.tone == 'muted' then
				-- Secondary text should recede without looking disabled.
				text_opts.color = config.color.time_current or bgt
				text_opts.opacity = visibility * 0.90
			end
			if segment.text:match('^[%w%s%./%-]+$') then
				text_opts.spacing = MEDIA_INFO_LETTER_SPACING * state.scale
			end
			local width = text_width(segment.text, text_opts)
			if text_opts.spacing then width = width + math.max(0, #segment.text - 1) * text_opts.spacing end
			local gap_before = segment.compact_before and compact_gap or item_gap
			prepared[#prepared + 1] = {
				segment = segment,
				opts = text_opts,
				width = width,
				gap_before = gap_before,
			}
			if index > 1 then content_width = content_width + gap_before end
			content_width = content_width + width
		end

		local capsule_width = content_width + capsule_padding * 2
		local leading_gap = cursor_x > x and capsule_gap or 0
		if cursor_x + leading_gap + capsule_width > max_x then break end
		cursor_x = cursor_x + leading_gap

		ass:rect(cursor_x, y - capsule_height / 2, cursor_x + capsule_width, y + capsule_height / 2, {
			color = config.color.menu_background or bg,
			border = math.max(0.75, 0.85 * state.scale),
			border_color = hero_group and hero_accent
				or config.color.menu_foreground or config.color.timeline_track or fg,
			opacity = {
				main = visibility * 0.38,
				border = visibility * (hero_group and 0.54 or 0.44),
			},
			radius = capsule_radius,
		})

		local text_x = cursor_x + capsule_padding
		for index, item in ipairs(prepared) do
			if index > 1 then text_x = text_x + item.gap_before end
			ass:txt(text_x, y, 4, item.segment.text, item.opts)
			text_x = text_x + item.width
		end

		cursor_x = cursor_x + capsule_width
	end
end

function Timeline:render()
	if self.size == 0 then
		self:clear_thumbnail()
		return
	end

	local size = self:get_effective_size()
	local visibility = self:get_visibility()
	local dock_geometry = dock_motion and dock_motion:get_timeline_geometry() or visibility
	self.is_hovered = false
	self:sync_horizontal_bounds()
	local window_border = Elements:v('window_border', 'size', 0)
	local collapsed_by = display.height - window_border
	local visual_by = self.by + (collapsed_by - self.by) * (1 - dock_geometry)
	local visual_ay = visual_by - size

	local interaction_scale = math.max(0.1, state.scale or 1)
	local expand_top = math.max(1, round(SEEK_HITBOX_EXPAND_TOP * interaction_scale))
	local expand_bottom = math.max(1, round(SEEK_HITBOX_EXPAND_BOTTOM * interaction_scale))
	local guard_height = math.max(1, round(MISS_GUARD_HEIGHT * interaction_scale))
	local controls_gap = math.max(1, round(CONTROLS_HITBOX_GAP * interaction_scale))
	local controls = Elements.controls
	local controls_visibility = controls and controls.enabled and controls:get_visibility() or 0
	local controls_limit = controls_visibility > 0 and controls.ay
		and math.max(visual_by, controls.ay - controls_gap) or nil
	local seek_by = visual_by + expand_bottom
	if controls_limit then seek_by = math.max(visual_by, math.min(seek_by, controls_limit)) end
	local seek_hitbox = {
		ax = self.ax,
		ay = visual_ay - expand_top,
		bx = self.bx,
		by = seek_by,
	}
	local miss_guard_hitbox = nil
	if controls_visibility > 0 and controls_limit then
		local guard_by = seek_hitbox.by + guard_height
		if controls_limit then guard_by = math.min(guard_by, controls_limit) end
		if guard_by > seek_hitbox.by then
			miss_guard_hitbox = {
				ax = self.ax,
				ay = seek_hitbox.by,
				bx = self.bx,
				by = guard_by,
			}
		end
	end
	local input_enabled = not self.file_browser_open
	local seek_hovered = input_enabled and cursor:collides_with(seek_hitbox)

	if size < 1 then
		self:clear_thumbnail()
		return
	end

	if seek_hovered then
		self.is_hovered = true
	end
	-- Register the no-op guard first. The seek zone is registered afterwards so
	-- the shared boundary remains selectable. Controls render later and win any
	-- overlap as a final safety net.
	if input_enabled and miss_guard_hitbox then
		cursor:zone('primary_down', miss_guard_hitbox, function() end)
	end
	if input_enabled and visibility > 0 and not self.edit_active then
		cursor:zone('primary_down', seek_hitbox, function()
			self:handle_cursor_down()
			cursor:once('primary_up', function() self:handle_cursor_up() end)
		end)
		if #options.timeline_mbtn_right > 0 then
			cursor:zone('secondary_down', seek_hitbox, function()
				self:cursor_command(options.timeline_mbtn_right)
			end)
		end
		if config.timeline_step ~= 0 then
			cursor:zone('wheel_down', seek_hitbox, function()
				mp.commandv('seek', -config.timeline_step, config.timeline_step_flag)
			end)
			cursor:zone('wheel_up', seek_hitbox, function()
				mp.commandv('seek', config.timeline_step, config.timeline_step_flag)
			end)
		end
	end

	local ass = assdraw.ass_new()
	local progress_size = math.max(self.min_progress_size, self.progress_size)
	local has_minimized_progress = progress_size > 0
	local bar_visibility = has_minimized_progress and 1 or visibility
	local track_visibility = has_minimized_progress
		and (dock_motion and dock_motion:get_minimized_track_visibility(dock_geometry) or visibility)
		or visibility

	-- Classic mode restores the original deep, fixed-height mask. Smooth mode
	-- keeps the restrained surface whose height follows the full Morph geometry.
	local blur_base, outer_opacity, inner_opacity, follows_motion = 15, 0.70, 0.34, false
	if dock_motion then
		blur_base, outer_opacity, inner_opacity, follows_motion = dock_motion:get_surface_profile()
	end
	local panel_visibility = follows_motion
		and (has_minimized_progress and dock_geometry or visibility)
		or math.max(visibility, Elements:maybe('controls', 'get_visibility') or 0)
	if panel_visibility > 0 then
		local panel_ax, panel_bx = window_border, display.width - window_border
		local panel_by = display.height + state.radius * 2
		local blur = math.max(1, round(blur_base * state.scale))
		local panel_top = self.panel_top
		if follows_motion then
			local collapsed_panel_top = collapsed_by - math.max(progress_size, 1.2) - round(2 * state.scale)
			panel_top = collapsed_panel_top + (self.panel_top - collapsed_panel_top) * dock_geometry
		end
		ass:rect(panel_ax - blur, panel_top, panel_bx + blur, panel_by + blur, {
			color = bg,
			opacity = panel_visibility * outer_opacity,
			blur = blur,
		})
		ass:rect(panel_ax, panel_top + blur, panel_bx, panel_by, {
			color = bg,
			opacity = panel_visibility * inner_opacity,
		})
	end

	-- Text opacity rapidly drops to 0 just before it starts overflowing, or before it reaches progress_size
	local hide_text_below = math.max(self.font_size * 0.8, progress_size * 2)
	local hide_text_ramp = hide_text_below / 2
	local text_opacity = clamp(0, size - hide_text_below, hide_text_ramp) / hide_text_ramp

	local tooltip_gap = round(2 * state.scale)
	local timestamp_gap = tooltip_gap

	local spacing = math.max(math.floor((self.size - self.font_size) / 2.5), 4)
	local progress = state.time / state.duration
	local is_line = options.timeline_style == 'line'

	-- Foreground & Background bar coordinates
	local bax, bbx = self.ax, self.bx
	if dock_motion then
		bax, bbx = dock_motion:get_timeline_bounds(self.ax, self.bx, display.width)
	end
	local bar_width = bbx - bax
	local hit_bay, hit_bby = visual_by - size - self.top_border, visual_by
	local collapsed_bar_height = math.max(1, progress_size)
	local expanded_bar_height = math.max(3, round(4 * state.scale))
	local bar_height = collapsed_bar_height
		+ (expanded_bar_height - collapsed_bar_height) * dock_geometry
	local bay = hit_bay + (size - bar_height) / 2
	local bby = bay + bar_height
	local fax, fay, fbx, fby = 0, bay + self.top_border, 0, bby
	local fcy = fay + (size / 2)

	local line_width = 0

	if is_line then
		local minimized_fraction = 1 - math.min((size - progress_size) / ((self.size - progress_size) / 8), 1)
		local progress_delta = progress_size > 0 and self.progress_line_width - self.line_width or 0
		line_width = self.line_width + (progress_delta * minimized_fraction)
		fax = bax + (bar_width - line_width) * progress
		fbx = fax + line_width
		line_width = line_width - 1
	else
		fax, fbx = bax, bax + bar_width * progress
	end

	local foreground_size = fby - fay
	local foreground_coordinates = round(fax) .. ',' .. fay .. ',' .. round(fbx) .. ',' .. fby -- for clipping

	-- time starts 0.5 pixels in
	local time_ax = bax + 0.5
	local time_width = bar_width - line_width - 1

	-- time to x: calculates x coordinate so that it never lies inside of the line
	local function t2x(time)
		local x = time_ax + time_width * time / state.duration
		return time <= state.time and x or x + line_width
	end

	-- Quiet neutral track under the cyan played section.
	ass:rect(bax, bay, bbx, bby, {
		color = config.color.timeline_track or fg,
		opacity = track_visibility * config.opacity.timeline,
		radius = bar_height / 2,
	})

	-- Buffered / loaded progress (safe, uses uncached_ranges + fallback)
		local loaded_progress_min_ahead = 15
		local loaded_progress_opacity = 0.22
		local loaded_pos = self:get_loaded_pos_safe()
		if type(loaded_pos) == 'number'
			and type(state.time) == 'number'
			and loaded_pos - state.time >= loaded_progress_min_ahead
		then
			local loaded_x = bax + bar_width * (loaded_pos / state.duration)
			if loaded_x > bax + 1 then
				ass:rect(bax, bay, loaded_x, bby, {
					color = config.color.match,
					opacity = track_visibility * loaded_progress_opacity,
					radius = bar_height / 2,
				})
			end
		end

	-- Progress
	local function draw_progress()
		ass:rect(fax, fay, fbx, fby, {
			color = config.color.match,
			opacity = bar_visibility * config.opacity.position,
			radius = bar_height / 2,
		})
		ass:circle(fbx, fay + (fby - fay) / 2, math.max(3, bar_height * 1.2), {
			color = config.color.match,
			opacity = visibility * config.opacity.position,
		})
	end

	-- Youtube heatmap
	local function draw_heatmap()
		if options.timeline_heatmap ~= 'no' and self.heatmap and config.opacity.heatmap > 0 and visibility > 0 then
			local is_above = options.timeline_heatmap == 'above'
			local height = math.min(40, size / self.size * 40)
			local ax, ay = bax, is_above and (bay - height) or (bay + self.top_border)
			local bx, by = bbx, is_above and bay or bby
			local opts = {color = config.color.heatmap, opacity = config.opacity.heatmap * visibility}
			local clip_ay = is_above and (ay - 10) or ay
			opts.clip = string.format('\\clip(%d,%d,%d,%d)', ax, clip_ay, bx, by)
			ass:smooth_curve(ax, ay, bx, by, self.heatmap, opts)
		end
	end

	-- Change draw order based on 'timeline_style' to keep the heatmap visible
	if is_line then
		draw_heatmap()
		draw_progress()
	else
		draw_progress()
		draw_heatmap()
	end

	-- Uncached ranges
	if state.uncached_ranges and visibility > 0.08 then
		local opts = {size = 80, anchor_y = fby}
		local texture_char = visibility > 0 and 'b' or 'a'
		local offset = opts.size / (visibility > 0 and 24 or 28)
		for _, range in ipairs(state.uncached_ranges) do
			if options.timeline_cache then
				local ax = range[1] < 0.5 and bax or math.floor(t2x(range[1]))
				local bx = range[2] > state.duration - 0.5 and bbx or math.ceil(t2x(range[2]))
				opts.color, opts.opacity, opts.anchor_x = fg, 0.4 - (0.2 * visibility), bax
				ass:texture(ax, fay, bx, fby, texture_char, opts)
				opts.color, opts.opacity, opts.anchor_x = bg, 0.6 - (0.2 * visibility), bax + offset
				ass:texture(ax, fay, bx, fby, texture_char, opts)
			end
		end
	end

	-- Custom ranges
	local segment_action_hovered = nil
	for _, chapter_range in ipairs(visibility > 0.08 and state.chapter_ranges or {}) do
		local rax = chapter_range.start < 0.1 and bax or t2x(chapter_range.start)
		local rbx = chapter_range['end'] > state.duration - 0.1 and bbx
			or t2x(math.min(chapter_range['end'], state.duration))
		ass:rect(rax, fay, rbx, fby, {
			color = chapter_range.color, opacity = chapter_range.opacity * visibility,
		})
		-- Keep explicit segment boundaries visible even when regular chapter
		-- markers are disabled. This makes intro/outro start and end nodes
		-- readable on the compact 4px timeline.
		local tick_width = math.max(2, round(2 * state.scale))
		local tick_overhang = math.max(3, round(3 * state.scale))
		ass:rect(
			rax - tick_width / 2, fay - tick_overhang,
			rax + tick_width / 2, fby + tick_overhang,
			{color = chapter_range.color, opacity = math.max(chapter_range.opacity, 0.92) * visibility}
		)
		ass:rect(
			rbx - tick_width / 2, fay - tick_overhang,
			rbx + tick_width / 2, fby + tick_overhang,
			{color = chapter_range.color, opacity = math.max(chapter_range.opacity, 0.92) * visibility}
		)

	end

	-- Interactive local intro/outro editor. While active, regular seeking is
	-- disabled and the nearest green handle is moved instead.
	if input_enabled and self.edit_active and state.duration and self.edit_end > self.edit_start then
		local edit_color = config.color.match
		local start_x = t2x(self.edit_start)
		local end_x = t2x(self.edit_end)
		local handle_radius = math.max(7, round(7 * state.scale))
		local handle_hit_radius = math.max(14, round(15 * state.scale))
		local handle_y = (fay + fby) / 2

		ass:rect(start_x, fay, end_x, fby, {color = edit_color, opacity = 0.72})
		for _, x in ipairs({start_x, end_x}) do
			ass:rect(
				x - math.max(1, state.scale), fay - handle_radius,
				x + math.max(1, state.scale), fby + handle_radius,
				{color = edit_color, opacity = 1}
			)
			ass:circle(x, handle_y, math.max(4, round(4 * state.scale)), {
				color = edit_color, opacity = 1,
			})
		end

		local text_opts = {
			size = math.max(14, round(15 * state.scale)),
			color = edit_color,
			border = math.max(2, round(2 * state.scale)),
			border_color = bg,
			bold = true,
		}
		ass:txt(start_x, fay - handle_radius - round(3 * state.scale), 2,
			format_time(self.edit_start, state.duration), text_opts)
		ass:txt(end_x, fay - handle_radius - round(3 * state.scale), 2,
			format_time(self.edit_end, state.duration), text_opts)

		local full_hitbox = {ax = bax, ay = hit_bay, bx = bbx, by = hit_bby}
		cursor:zone('primary_down', full_hitbox, function()
			local start_delta = math.abs(cursor.x - start_x)
			local end_delta = math.abs(cursor.x - end_x)
			self.edit_drag = start_delta <= end_delta and 'start' or 'end'
			self:on_global_mouse_move()
			cursor:once('primary_up', function() self.edit_drag = nil end)
		end)
		cursor:zone('primary_down', {
			point = {x = start_x, y = handle_y}, r = handle_hit_radius,
		}, function()
			self.edit_drag = 'start'
			cursor:once('primary_up', function() self.edit_drag = nil end)
		end)
		cursor:zone('primary_down', {
			point = {x = end_x, y = handle_y}, r = handle_hit_radius,
		}, function()
			self.edit_drag = 'end'
			cursor:once('primary_up', function() self.edit_drag = nil end)
		end)

		local action_source = self.edit_source
		local matched_existing = self.edit_deletable == true
		if action_source ~= 'manual' and action_source ~= 'website' then
			for _, chapter_range in ipairs(state.chapter_ranges) do
				if chapter_range.autoskip_source and chapter_range.autoskip_kind == self.edit_kind
					and math.abs((chapter_range.start or 0) - self.edit_start) < 1.5
					and math.abs((chapter_range['end'] or 0) - self.edit_end) < 1.5
				then
					action_source = chapter_range.autoskip_source
					matched_existing = true
					break
				end
			end
		end
		if matched_existing and action_source ~= 'manual' and action_source ~= 'website' then
			action_source = 'website'
		end
		if action_source ~= 'manual' and action_source ~= 'website' then
			action_source = 'cancel'
		end
		do
			local button_size = math.max(22, round(23 * state.scale))
			local hit_size = math.max(30, round(32 * state.scale))
			local button_gap = math.max(7, round(8 * state.scale))
			local button_x = end_x + button_size / 2 + button_gap
			if button_x + hit_size / 2 > bbx then
				button_x = start_x - button_size / 2 - button_gap
			end
			button_x = clamp(bax + hit_size / 2, button_x, bbx - hit_size / 2)
			local button_y = handle_y + math.max(18, round(19 * state.scale))
			local hitbox = {
				ax = button_x - hit_size / 2,
				ay = button_y - hit_size / 2,
				bx = button_x + hit_size / 2,
				by = button_y + hit_size / 2,
			}
			local is_button_hovered = cursor:collides_with(hitbox)
			local label
			if action_source == 'cancel' then
				label = '取消编辑'
			else
				label = action_source == 'manual' and '删除手动' or '忽略网站'
				label = label .. (self.edit_kind == 'outro' and '片尾' or '片头')
			end
			ass:rect(
				button_x - button_size / 2, button_y - button_size / 2,
				button_x + button_size / 2, button_y + button_size / 2,
				{
					color = is_button_hovered and config.color.error or bg,
					opacity = is_button_hovered and 0.94 or 0.82,
					radius = math.max(3, round(4 * state.scale)),
					border = math.max(1, round(1 * state.scale)),
					border_color = edit_color,
				}
			)
			ass:txt(button_x, button_y - round(1 * state.scale), 5, '×', {
				size = math.max(18, round(19 * state.scale)),
				color = is_button_hovered and fgt or fg,
				border = math.max(1, round(1 * state.scale)),
				border_color = is_button_hovered and config.color.error or bg,
				bold = true,
			})
			cursor:zone('primary_down', hitbox, function()
				if action_source == 'cancel' then
					mp.commandv('script-message-to', 'skip_segments', 'cancel-edit')
				else
					mp.commandv(
						'script-message-to', 'skip_segments', 'remove-range',
						action_source, self.edit_kind or 'intro',
						tostring(self.edit_start), tostring(self.edit_end)
					)
				end
			end)
			if is_button_hovered then
				segment_action_hovered = {hitbox = hitbox, label = label}
			end
		end
	end

	-- Chapters
	local hovered_chapter = nil
	if visibility > 0.08
		and (config.opacity.chapters > 0 and (#state.chapters > 0 or state.ab_loop_a or state.ab_loop_b)) then
		local diamond_radius = math.min(math.max(1, foreground_size * 0.8), self.chapter_size)
		local diamond_radius_hovered = diamond_radius * 2
		local diamond_border = options.timeline_border and math.max(options.timeline_border, 1) or 1

		if diamond_radius > 0 then
			local chapter_y = fay + foreground_size / 2
			local function draw_chapter(time, radius)
				local chapter_x = t2x(time)
				ass:new_event()
				ass:append(string.format(
					'{\\pos(0,0)\\rDefault\\an7\\blur0\\yshad0.01\\bord%f\\1c&H%s\\3c&H%s\\4c&H%s\\1a&H%X&\\3a&H00&\\4a&H00&}',
					diamond_border, fg, bg, bg, opacity_to_alpha(config.opacity.chapters * visibility)
				))
				ass:draw_start()
				ass:move_to(chapter_x - radius, chapter_y)
				ass:line_to(chapter_x, chapter_y - radius)
				ass:line_to(chapter_x + radius, chapter_y)
				ass:line_to(chapter_x, chapter_y + radius)
				ass:draw_stop()
			end

			if #state.chapters > 0 then
				-- Find hovered chapter indicator
				local closest_delta = math.huge

				if self.proximity_raw < diamond_radius_hovered then
					for i, chapter in ipairs(state.chapters) do
						local chapter_x = t2x(chapter.time)
						local cursor_chapter_delta = math.sqrt((cursor.x - chapter_x) ^ 2 + (cursor.y - chapter_y) ^ 2)
						if cursor_chapter_delta <= diamond_radius_hovered and cursor_chapter_delta < closest_delta then
							hovered_chapter, closest_delta = chapter, cursor_chapter_delta
							self.is_hovered = true
						end
					end
				end

				for i, chapter in ipairs(state.chapters) do
					if chapter ~= hovered_chapter then draw_chapter(chapter.time, diamond_radius) end
					local circle = {point = {x = t2x(chapter.time), y = chapter_y}, r = diamond_radius_hovered}
					if input_enabled and visibility > 0 and chapter == hovered_chapter then
						cursor:zone('primary_down', circle, function()
							mp.commandv('seek', chapter.time, 'absolute+exact')
						end)
					end
				end

				-- Render hovered chapter above others
				if hovered_chapter then
					draw_chapter(hovered_chapter.time, diamond_radius_hovered)
					timestamp_gap = tooltip_gap + round(diamond_radius_hovered)
				else
					timestamp_gap = tooltip_gap + round(diamond_radius)
				end
			end

			-- A-B loop indicators
			local has_a, has_b = state.ab_loop_a and state.ab_loop_a >= 0, state.ab_loop_b and state.ab_loop_b > 0
			local ab_radius = round(math.min(math.max(8, foreground_size * 0.25), foreground_size))

			---@param time number
			---@param kind 'a'|'b'
			local function draw_ab_indicator(time, kind)
				local x = t2x(time)
				ass:new_event()
				ass:append(string.format(
					'{\\pos(0,0)\\rDefault\\an7\\blur0\\yshad0.01\\bord%f\\1c&H%s\\3c&H%s\\4c&H%s\\1a&H%X&\\3a&H00&\\4a&H00&}',
					diamond_border, fg, bg, bg, opacity_to_alpha(config.opacity.chapters * visibility)
				))
				ass:draw_start()
				ass:move_to(x, fby - ab_radius)
				if kind == 'b' then ass:line_to(x + 3, fby - ab_radius) end
				ass:line_to(x + (kind == 'a' and 0 or ab_radius), fby)
				ass:line_to(x - (kind == 'b' and 0 or ab_radius), fby)
				if kind == 'a' then ass:line_to(x - 3, fby - ab_radius) end
				ass:draw_stop()
			end

			if has_a then draw_ab_indicator(state.ab_loop_a, 'a') end
			if has_b then draw_ab_indicator(state.ab_loop_b, 'b') end
		end
	end

	local function draw_timeline_timestamp(x, y, align, timestamp, opts)
		opts.color, opts.border_color = fgt, fg
		opts.clip = '\\clip(' .. foreground_coordinates .. ')'
		local func = options.time_precision > 0 and ass.timestamp or ass.txt
		func(ass, x, y, align, timestamp, opts)
		opts.color, opts.border_color = bgt, bg
		opts.clip = '\\iclip(' .. foreground_coordinates .. ')'
		func(ass, x, y, align, timestamp, opts)
	end

	-- Hovered time and chapter
	local rendered_thumbnail = false
	if segment_action_hovered then
		ass:tooltip(segment_action_hovered.hitbox, segment_action_hovered.label, {
			size = self.font_size,
			offset = tooltip_gap,
			bold = true,
		})
	elseif (seek_hovered or self.pressed or hovered_chapter) and not Elements:v('speed', 'dragging') then
		local cursor_x = hovered_chapter and t2x(hovered_chapter.time) or cursor.x
		local hovered_seconds = hovered_chapter and hovered_chapter.time or self:get_time_at_x(cursor.x)

		-- Cursor line
		-- 0.5 to switch when the pixel is half filled in
		local color = ((fax - 0.5) < cursor_x and cursor_x < (fbx + 0.5)) and bg or fg
		local ax, ay, bx, by = cursor_x - 0.5, fay, cursor_x + 0.5, fby
		ass:rect(ax, ay, bx, by, {color = color, opacity = 0.33})
		local tooltip_anchor = {ax = ax, ay = ay - self.top_border, bx = bx, by = by}

		-- Timestamp
		local opts = {
			size = math.max(round(self.font_size * 1.35), round(15 * state.scale)),
			offset = timestamp_gap,
			margin = tooltip_gap,
			timestamp = options.time_precision > 0,
			bold = true,
		}
		local hovered_time_human = format_time(hovered_seconds, state.duration)
		opts.width_overwrite = timestamp_width(hovered_time_human, opts)
		tooltip_anchor = ass:tooltip(tooltip_anchor, hovered_time_human, opts)

		-- Thumbnail
		if not thumbnail.disabled
			and (not self.pressed or self.pressed.distance < 5)
			and thumbnail.width ~= 0
			and thumbnail.height ~= 0
		then
			local border = math.ceil(math.max(2, state.radius / 2) * state.scale)
			local thumb_x_margin, thumb_y_margin = border + tooltip_gap + bax, border + tooltip_gap
			local thumb_width, thumb_height = thumbnail.width, thumbnail.height
			local thumb_x = round(clamp(
				thumb_x_margin,
				cursor_x - thumb_width / 2,
				display.width - thumb_width - thumb_x_margin
			))
			local thumb_y = round(tooltip_anchor.ay - thumb_y_margin - thumb_height)
			local ax, ay = (thumb_x - border), (thumb_y - border)
			local bx, by = (thumb_x + thumb_width + border), (thumb_y + thumb_height + border)
			ass:rect(ax, ay, bx, by, {
				color = bg,
				border = 1,
				opacity = {main = config.opacity.thumbnail, border = 0.08 * config.opacity.thumbnail},
				border_color = fg,
				radius = state.radius,
			})
			local thumb_seconds = (state.rebase_start_time == false and state.start_time) and
				(hovered_seconds - state.start_time) or hovered_seconds
			mp.commandv('script-message-to', 'thumbfast', 'thumb', thumb_seconds, thumb_x, thumb_y)
			self.has_thumbnail, rendered_thumbnail = true, true
			tooltip_anchor.ay = ay
		end

		-- Chapter title
		if config.opacity.chapters > 0 and #state.chapters > 0 then
			local _, chapter = itable_find(state.chapters, function(c) return hovered_seconds >= c.time end,
				#state.chapters, 1)
			if chapter and not chapter.is_end_only then
				ass:tooltip(tooltip_anchor, chapter.title_wrapped, {
					size = self.font_size,
					offset = tooltip_gap,
					responsive = false,
					bold = true,
					width_overwrite = chapter.title_wrapped_width * self.font_size,
					lines = chapter.title_lines,
					margin = tooltip_gap,
				})
			end
		end
	end

	-- Clear thumbnail
	if not rendered_thumbnail then self:clear_thumbnail() end

	-- Media info: keep a comfortable gap above the timeline and, when the
	-- window is letterboxed, clamp the full text line inside the video picture.
	local mi_ok, mi_segments = pcall(build_media_info_segments)
	if mi_ok and type(mi_segments) == 'table'
		and #mi_segments > 0 and visibility > 0 then
		local mi_x = bax
		local mi_y = bay - round(MEDIA_INFO_TIMELINE_OFFSET * state.scale)
		local picture_top, picture_bottom = get_video_display_vertical_bounds()
		if picture_top and picture_bottom then
			local half_height = round(MEDIA_INFO_CAPSULE_HEIGHT * state.scale) / 2
			local picture_inset = round(MEDIA_INFO_PICTURE_INSET * state.scale)
			local min_y = picture_top + picture_inset + half_height
			local max_y = picture_bottom - picture_inset - half_height
			if min_y <= max_y then mi_y = clamp(min_y, mi_y, max_y) end
		end
		local mi_max_width = bbx - mi_x
		render_media_info_segments(ass, mi_x, mi_y, copy_media_info_segments(mi_segments), visibility, mi_max_width)
	end

	return ass
end

return Timeline
