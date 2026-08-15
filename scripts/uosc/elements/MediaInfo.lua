local Element = require('elements/Element')

---@class MediaInfo : Element
local MediaInfo = class(Element)

function MediaInfo:new() return Class.new(self) end
function MediaInfo:init()
	Element.init(self, 'media_info', {render_order = 84, anchor_id = 'timeline'})
	self.enabled = false
	self.text = ''
end

function MediaInfo:on_display()
	self:refresh()
end

function MediaInfo:on_prop_fullormaxed()
	self:refresh()
end

-- uosc calls these events if the element has the methods
function MediaInfo:on_file_loaded()
	self:refresh()
	request_render()
end

function MediaInfo:on_video_reconfig()
	self:refresh()
	request_render()
end

function MediaInfo:refresh()
	-- Use video height as reliable indicator instead of mp.get_property_bool('video-params')
	local h = mp.get_property_number('video-params/h', 0)
	local w = mp.get_property_number('video-params/w', 0)

	if h <= 0 and w <= 0 then
		self.text = ''
		self.enabled = false
		return
	end

	local parts = {}

	-- HW/SW
	local hwdec = mp.get_property('hwdec-current', '')
	if hwdec ~= '' and hwdec ~= 'no' then
		parts[#parts + 1] = 'HW'
	elseif hwdec == 'no' then
		parts[#parts + 1] = 'SW'
	end

	-- Dynamic range
	local gamma = mp.get_property('video-params/gamma', '')
	local filename = mp.get_property('filename', ''):lower()
	local compact_filename = filename:gsub('[%s%._%-:/\\%[%]%(%)]+', '')
	local hdr_vivid = mp.get_property_bool('video-params/hdr-vivid', false)
		or compact_filename:find('hdrvivid', 1, true) ~= nil
		or compact_filename:find('cuvahdr', 1, true) ~= nil
	if hdr_vivid then
		parts[#parts + 1] = 'HDR VIVID'
	elseif gamma == 'pq' then
		if filename:match('dolby') or filename:match('dovi') or filename:match('%.dv%.') then
			local p = filename:match('profile[%s_-]?(%d)') or filename:match('p([578])')
			if p == '5' then parts[#parts + 1] = 'DV P5'
			elseif p == '7' then parts[#parts + 1] = 'DV P7'
			elseif p == '8' then parts[#parts + 1] = 'DV P8'
			else parts[#parts + 1] = 'DV' end
		else
			parts[#parts + 1] = 'HDR10'
		end
	elseif gamma == 'hlg' then
		parts[#parts + 1] = 'HLG'
	elseif filename:match('dolby') or filename:match('dovi') then
		parts[#parts + 1] = 'DV'
	else
		parts[#parts + 1] = 'SDR'
	end

	-- Codec
	local codec = mp.get_property('video-params/codec', '')
	local fc = codec:lower()
	if fc:match('hevc') or fc:match('h265') or filename:match('hevc') or filename:match('x%.265') then
		parts[#parts + 1] = 'HEVC'
	elseif fc:match('avc') or fc:match('h264') or filename:match('avc') or filename:match('x%.264') then
		parts[#parts + 1] = 'AVC'
	elseif fc:match('av1') or filename:match('av1') then
		parts[#parts + 1] = 'AV1'
	elseif fc:match('vp9') or filename:match('vp9') then
		parts[#parts + 1] = 'VP9'
	end

	-- Resolution
	if h > 0 then
		parts[#parts + 1] = tostring(math.floor(h)) .. 'P'
	else
		local m = filename:match('(%d+)p')
		if m then parts[#parts + 1] = m .. 'P' end
	end

	-- Framerate
	local fps = mp.get_property_number('estimated-vf-fps', 0)
	if fps <= 0 then fps = mp.get_property_number('container-fps', 0) end
	if fps > 0 then
		parts[#parts + 1] = tostring(math.floor(fps + 0.5)) .. 'FPS'
	end

	self.text = #parts > 0 and table.concat(parts, '   ') or ''
	self.enabled = self.text ~= ''
end

function MediaInfo:render()
	if not self.enabled or self.text == '' then return '' end

	local tl = Elements and Elements.timeline
	if not tl or not tl.enabled then return '' end

	local x = tl.ax
	local y = tl.ay
	if not x or not y then return '' end

	local fs = tl.font_size or 18
	local border = tl.top_border or 0
	local v = self:get_visibility()
	if v <= 0 then return '' end

	local ass = assdraw.ass_new()
	ass:txt(x, y - border - 4, 4, self.text, {
		size = fs,
		color = fg,
		opacity = v * 0.72,
	})
	return ass
end

return MediaInfo
