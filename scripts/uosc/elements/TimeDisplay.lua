local Element = require('elements/Element')

---@class TimeDisplay : Element
local TimeDisplay = class(Element)

function TimeDisplay:new(props) return Class.new(self, props) --[[@as TimeDisplay]] end
function TimeDisplay:init(props)
	Element.init(self, 'time_display', props)
	self.font_size = 0
end

function TimeDisplay:on_coordinates()
	self.font_size = round((self.by - self.ay) * 0.5 * options.font_scale)
end

function TimeDisplay:on_options() self:on_coordinates() end

function TimeDisplay:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end

	local ass = assdraw.ass_new()
	local visual, transform = self:get_visual_rect()
	local current = state.time_human or '00:00'
	local destination = state.destination_time_human or '00:00'
	local center_y = visual.ay + (visual.by - visual.ay) / 2
	local padding = round(4 * state.scale)
	local current_opts = {
		size = self.font_size * transform.scale,
		color = config.color.time_current or bgt,
		opacity = visibility,
		border = options.text_border * state.scale,
		border_color = bg,
	}
	local muted_opts = {
		size = self.font_size * transform.scale,
		color = config.color.time_muted or bgt,
		opacity = visibility * 0.82,
		border = options.text_border * state.scale,
		border_color = bg,
	}
	local current_width = timestamp_width(current, current_opts)
	local separator_width = text_width('/', muted_opts)
	local destination_width = timestamp_width(destination, muted_opts)
	local content_width = current_width + separator_width + destination_width + padding * 4
	local start_x = visual.ax + math.max(0, (visual.bx - visual.ax - content_width) / 2)

	ass:txt(start_x, center_y, 4, current, current_opts)
	local separator_x = start_x + current_width + padding * 2
	ass:txt(separator_x, center_y, 4, '/', muted_opts)
	ass:txt(separator_x + separator_width + padding * 2, center_y, 4, destination, muted_opts)

	return ass
end

return TimeDisplay
