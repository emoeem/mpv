local Element = require('elements/Element')

---@class SpeedButton : Element
local SpeedButton = class(Element)

function SpeedButton:new(props) return Class.new(self, props) --[[@as SpeedButton]] end
function SpeedButton:init(props)
	Element.init(self, 'speed_button', props)
	self.font_size = 0
end

function SpeedButton:on_coordinates()
	self.font_size = round((self.by - self.ay) * 0.52 * options.font_scale)
end

function SpeedButton:on_options() self:on_coordinates() end

local function format_speed(value)
	if math.abs(value - round(value)) < 0.001 then return string.format('%.1f', value) end
	return string.format('%.2f', value):gsub('0$', '')
end

function SpeedButton:open_menu()
	local items = {}
	for _, value in ipairs({0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 5}) do
		items[#items + 1] = {
			title = format_speed(value) .. '×',
			value = 'set speed ' .. value,
			active = math.abs(state.speed - value) < 0.001,
		}
	end
	mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json({
		type = 'speed_selector',
		title = '播放速度',
		search_style = 'disabled',
		items = items,
	}))
end

function SpeedButton:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end
	local visual, transform = self:get_visual_rect()

	-- Keep the wide layout slot that counterbalances the time display and keeps
	-- play/pause centered, but limit pointer interaction to the visible label.
	local hit_width = math.min(self.bx - self.ax, (self.by - self.ay) * 1.45)
	-- Visually pull the compact label toward the playback cluster while keeping
	-- its full layout slot untouched, so play/pause stays window-centered.
	local center_x = self.ax + (self.bx - self.ax) / 2 - round(5 * state.scale)
	local hitbox = {
		ax = center_x - hit_width / 2,
		ay = self.ay,
		bx = center_x + hit_width / 2,
		by = self.by,
	}

	if visibility >= 0.08 then
		cursor:zone('primary_down', hitbox, function()
			mp.add_timeout(0.01, function() self:open_menu() end)
		end)
		cursor:zone('secondary_click', hitbox, function() mp.set_property_native('speed', 1) end)
		cursor:zone('wheel_up', hitbox, function()
			mp.set_property_native('speed', math.min(100, state.speed + options.speed_step))
		end)
		cursor:zone('wheel_down', hitbox, function()
			mp.set_property_native('speed', math.max(0.01, state.speed - options.speed_step))
		end)
	end

	local ass = assdraw.ass_new()
	local is_hover = get_point_to_rectangle_proximity(cursor, hitbox) <= 0
	local visual_hitbox = self:get_visual_rect(hitbox)
	if is_hover then
		ass:rect(visual_hitbox.ax, visual_hitbox.ay, visual_hitbox.bx, visual_hitbox.by, {
			color = fg, opacity = visibility * 0.12, radius = state.radius,
		})
		if visibility >= 0.72 and options.button_tooltips ~= false then
			ass:tooltip(hitbox, '播放速度')
		end
	end
	local value = format_speed(round(state.speed * 100) / 100)
	local value_opts = {
		size = self.font_size * transform.scale,
		color = config.color.time_current or bgt,
		opacity = visibility * 0.92,
		border = options.text_border * state.scale,
		border_color = bg,
	}
	local value_width = text_width(value, value_opts)
	local visual_center_x = visual.ax + (visual.bx - visual.ax) / 2 - round(5 * state.scale * transform.scale)
	local start_x = visual_center_x - value_width / 2
	local center_y = visual.ay + (visual.by - visual.ay) / 2
	ass:txt(start_x, center_y, 4, value, value_opts)
	return ass
end

return SpeedButton
