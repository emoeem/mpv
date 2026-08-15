local Element = require('elements/Element')

--[[ VolumeSlider ]]

---@class VolumeSlider : Element
local VolumeSlider = class(Element)
---@param props? ElementProps
function VolumeSlider:new(props) return Class.new(self, props) --[[@as VolumeSlider]] end
function VolumeSlider:init(props)
	Element.init(self, 'volume_slider', props)
	self.pressed = false
	self.nudge_y = 0 -- vertical position where volume overflows 100
	self.nudge_size = 0
	self.draw_nudge = false
	self.spacing = 0
	self.border_size = 0
	self:update_dimensions()
end

function VolumeSlider:update_dimensions()
	self.border_size = math.max(0, round(options.volume_border * state.scale))
end

function VolumeSlider:get_visibility() return Elements.volume:get_visibility(self) end

function VolumeSlider:set_volume(volume)
	volume = round(volume / options.volume_step) * options.volume_step
	if state.volume == volume then return end
	mp.commandv('set', 'volume', clamp(0, volume, state.volume_max))
end

function VolumeSlider:set_from_cursor()
	local volume_fraction = (self.by - cursor.y - self.border_size) / (self.by - self.ay - self.border_size)
	self:set_volume(volume_fraction * state.volume_max)
end

function VolumeSlider:on_display() self:update_dimensions() end
function VolumeSlider:on_options() self:update_dimensions() end
function VolumeSlider:on_coordinates()
	if type(state.volume_max) ~= 'number' or state.volume_max <= 0 then return end
	local width = self.bx - self.ax
	self.nudge_y = self.by - round((self.by - self.ay) * (100 / state.volume_max))
	self.nudge_size = round(width * 0.18)
	self.draw_nudge = self.ay < self.nudge_y
	self.spacing = round(width * 0.2)
end
function VolumeSlider:on_global_mouse_move()
	if self.pressed then self:set_from_cursor() end
end
function VolumeSlider:handle_wheel_up() self:set_volume(state.volume + options.volume_step) end
function VolumeSlider:handle_wheel_down() self:set_volume(state.volume - options.volume_step) end

function VolumeSlider:render()
	local visibility = self:get_visibility()
	local ax, ay, bx, by = self.ax, self.ay, self.bx, self.by
	local width, height = bx - ax, by - ay

	if width <= 0 or height <= 0 or visibility <= 0 then return end

	cursor:zone('primary_down', self, function()
		self.pressed = true
		self:set_from_cursor()
		cursor:once('primary_up', function() self.pressed = false end)
	end)
	cursor:zone('wheel_down', self, function() self:handle_wheel_down() end)
	cursor:zone('wheel_up', self, function() self:handle_wheel_up() end)

	local ass = assdraw.ass_new()
	local track_width = math.max(3, round(width * 0.1))
	local track_ax = round(ax + (width - track_width) / 2)
	local track_bx = track_ax + track_width
	local track_ay = ay + round(width * 0.45)
	local value_reserve = round(width * 0.9)
	local track_by = by - value_reserve
	local volume_fraction = clamp(0, state.volume / state.volume_max, 1)
	local volume_y = track_by - (track_by - track_ay) * volume_fraction

	ass:rect(track_ax, track_ay, track_bx, track_by, {
		color = fg, radius = track_width / 2, opacity = visibility * config.opacity.slider,
	})
	ass:rect(track_ax, volume_y, track_bx, track_by, {
		color = config.color.match,
		radius = track_width / 2,
		opacity = visibility * config.opacity.slider_gauge,
	})
	ass:circle(track_ax + track_width / 2, volume_y, math.max(2, track_width * 0.75), {
		color = config.color.match, opacity = visibility,
	})

	local volume_string = tostring(round(state.volume * 10) / 10)
	local font_size = round(width * 0.44 * options.font_scale)
	ass:txt(ax + width / 2, by - round(value_reserve * 0.45), 5, volume_string, {
		size = font_size,
		color = fg,
		bold = true,
		border = math.max(1, options.text_border * state.scale),
		border_color = bg,
		opacity = visibility,
	})

	return ass
end

--[[ Volume ]]

---@class Volume : Element
local Volume = class(Element)

function Volume:new() return Class.new(self) --[[@as Volume]] end
function Volume:init()
	Element.init(self, 'volume', {render_order = 7})
	self.size = 0
	self.mute_ay = 0
	self.slider = VolumeSlider:new({anchor_id = 'volume', render_order = self.render_order + 0.1})
	self:update_dimensions()
end

function Volume:destroy()
	self.slider:destroy()
	Element.destroy(self)
end

function Volume:get_visibility()
	if not state.is_idle and not state.has_audio then return 0 end
	return self.slider.pressed and 1 or Elements:maybe('timeline', 'get_is_hovered') and -1
		or Element.get_visibility(self)
end

function Volume:update_dimensions()
	self.size = round(options.volume_size * state.scale)
	local min_y = Elements:v('top_bar', 'by') or Elements:v('window_border', 'size', 0)
	local max_y = Elements:v('controls', 'ay') or Elements:v('timeline', 'ay')
		or display.height - Elements:v('window_border', 'size', 0)
	local available_height = max_y - min_y
	local max_height = available_height * 0.8
	local height = round(math.min(self.size * 6, max_height))
	self.enabled = height > self.size * 2 -- don't render if too small
	-- Keep the floating volume panel visually detached from the window edge.
	local margin = self.size + Elements:v('window_border', 'size', 0)
	self.ax = round(options.volume == 'left' and margin or display.width - margin - self.size)
	self.ay = min_y + round((available_height - height) / 2)
	self.bx = round(self.ax + self.size)
	self.by = round(self.ay + height)
	self.mute_ay = self.by - self.size
	self.slider.enabled = self.enabled
	self.slider:set_coordinates(self.ax, self.ay, self.bx, self.mute_ay)
end

function Volume:on_display() self:update_dimensions() end
function Volume:on_prop_border() self:update_dimensions() end
function Volume:on_prop_title_bar() self:update_dimensions() end
function Volume:on_prop_volume_max() self:update_dimensions() end
function Volume:on_controls_reflow() self:update_dimensions() end
function Volume:on_options() self:update_dimensions() end

function Volume:toggle_mute()
	mp.commandv('cycle', 'mute')
end

function Volume:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end

	-- Reset volume on secondary click
	cursor:zone('secondary_click', self, function()
		mp.set_property_native('mute', false)
		mp.set_property_native('volume', 100)
	end)

	-- Mute button
	local mute_rect = {ax = self.ax, ay = self.mute_ay, bx = self.bx, by = self.by}
	cursor:zone('primary_click', mute_rect, function() self:toggle_mute() end)
	local ass = assdraw.ass_new()
	ass:rect(self.ax - round(4 * state.scale), self.ay - round(6 * state.scale),
		self.bx + round(4 * state.scale), self.by + round(4 * state.scale), {
			color = bg,
			opacity = visibility * 0.82,
			radius = state.radius,
		})
	local width_half = (mute_rect.bx - mute_rect.ax) / 2
	local height_half = (mute_rect.by - mute_rect.ay) / 2
	local icon_size = math.min(width_half, height_half) * 1.05
	local icon_name, horizontal_shift = 'volume_up', 0
	if state.mute then
		icon_name = 'volume_off'
	elseif state.volume <= 0 then
		icon_name, horizontal_shift = 'volume_mute', height_half * 0.25
	elseif state.volume <= 60 then
		icon_name, horizontal_shift = 'volume_down', height_half * 0.125
	end
	ass:icon(mute_rect.ax + width_half - horizontal_shift, mute_rect.ay + height_half, icon_size, icon_name,
		{color = state.mute and config.color.menu_active or fg, opacity = visibility, align = 5}
	)
	return ass
end

return Volume
