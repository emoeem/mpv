local Element = require('elements/Element')
local Button = require('elements/Button')
local CycleButton = require('elements/CycleButton')
local ManagedButton = require('elements/ManagedButton')
local Speed = require('elements/Speed')
local TimeDisplay = require('elements/TimeDisplay')
local SpeedButton = require('elements/SpeedButton')

-- sizing:
--   static - shrink, have highest claim on available space, disappear when there's not enough of it
--   dynamic - shrink to make room for static elements until they reach their ratio_min, then disappear
--   gap - shrink if there's no space left
--   space - expands to fill available space, shrinks as needed
-- scale - `options.controls_size` scale factor.
-- ratio - Width/height ratio of a static or dynamic element.
-- ratio_min Min ratio for 'dynamic' sized element.
---@alias ControlItem {element?: Element; kind: string; sizing: 'space' | 'static' | 'dynamic' | 'gap'; scale: number; ratio?: number; ratio_min?: number; hide: boolean; narrow_priority?: integer; dispositions?: {[string]: boolean}[]}

-- Per-icon glyph width ratios. MaterialIconsRound glyphs fill different
-- fractions of the em-square: narrow icons like more_vert are ~28% wide,
-- wide icons like folder fill ~75%. Other icons default to 0.72.
local icon_width_factor = {
	more_vert = 0.28,
	folder = 0.75,
}

---@class Controls : Element
local Controls = class(Element)

function Controls:new() return Class.new(self) --[[@as Controls]] end
function Controls:init()
	Element.init(self, 'controls', {render_order = 6})
	---@type ControlItem[] All control elements serialized from `options.controls`.
	self.controls = {}
	---@type ControlItem[] Only controls that match current dispositions.
	self.layout = {}

	self:init_options()
end

function Controls:destroy()
	self:destroy_elements()
	Element.destroy(self)
end

function Controls:init_options()
	-- Serialize control elements
	local shorthands = {
		['play-pause'] = 'cycle:pause:pause:no/yes=play_arrow?' .. t('Play/Pause'),
		menu = 'command:menu_book:script-binding uosc/menu-blurred?' .. t('Menu'),
		subtitles = 'command:closed_caption:script-binding uosc/subtitles#sub>1?' .. t('Subtitles'),
		audio = 'command:graphic_eq:script-binding uosc/audio#audio>1?' .. t('Audio'),
		['audio-device'] = 'command:speaker:script-binding uosc/audio-device?' .. t('Audio device'),
		video = 'command:smart_display:script-binding uosc/video#video>1?' .. t('Video'),
		playlist = 'command:list_alt:script-binding uosc/playlist#playlist>1?' .. t('Playlist'),
		chapters = 'command:library_books:script-binding uosc/chapters#chapters>1?' .. t('Chapters'),
		['editions'] = 'command:movie_filter:script-binding uosc/editions#editions>1?' .. t('Editions'),
		['stream-quality'] = 'command:high_quality:script-binding uosc/stream-quality?' .. t('Stream quality'),
		['open-file'] = 'command:folder:script-binding uosc/open-file?' .. t('Open file'),
		['items'] = 'command:list_alt:script-binding uosc/items#playlist>1?' .. t('Playlist/Files'),
		prev = 'command:arrow_back_ios:script-binding uosc/prev?' .. t('Previous'),
		next = 'command:arrow_forward_ios:script-binding uosc/next?' .. t('Next'),
		first = 'command:first_page:script-binding uosc/first?' .. t('First'),
		last = 'command:last_page:script-binding uosc/last?' .. t('Last'),
		['loop-playlist'] = 'cycle:repeat:loop-playlist:no/inf!?' .. t('Loop playlist'),
		['loop-file'] = 'cycle:repeat_one:loop-file:no/inf!?' .. t('Loop file'),
		shuffle = 'toggle:shuffle:shuffle?' .. t('Shuffle'),
		autoload = 'toggle:hdr_auto:autoload@uosc?' .. t('Autoload'),
		fullscreen = 'cycle:crop_free:fullscreen:no/yes=fullscreen_exit!?' .. t('Fullscreen'),
	}

	-- Parse out disposition/config pairs
	local items = {}
	local in_disposition = false
	local current_item = nil
	for c in options.controls:gmatch('.') do
		if not current_item then current_item = {disposition = '', config = ''} end
		if c == '<' and #current_item.config == 0 then
			in_disposition = true
		elseif c == '>' and #current_item.config == 0 then
			in_disposition = false
		elseif c == ',' and not in_disposition then
			items[#items + 1] = current_item
			current_item = nil
		else
			local prop = in_disposition and 'disposition' or 'config'
			current_item[prop] = current_item[prop] .. c
		end
	end
	items[#items + 1] = current_item

	-- Create controls
	self.controls = {}
	for i, item in ipairs(items) do
		local config = shorthands[item.config] and shorthands[item.config] or item.config
		local config_tooltip = split(config, ' *%? *')
		local tooltip = config_tooltip[2]
		config = shorthands[config_tooltip[1]]
			and split(shorthands[config_tooltip[1]], ' *%? *')[1] or config_tooltip[1]
		local config_badge = split(config, ' *# *')
		config = config_badge[1]
		local badge = config_badge[2]
		local parts = split(config, ' *: *')
		local kind, params = parts[1], itable_slice(parts, 2)

		-- Serialize dispositions into OR groups of AND conditions
		---@type {[string]: boolean}[]
		local dispositions = {}
		---@type string[]
		local disposition_props = {}
		for _, or_group in ipairs(comma_split(item.disposition)) do
			local group = {}
			for _, condition in ipairs(split(or_group, ' *+ *')) do
				if #condition > 0 then
					local value = condition:sub(1, 1) ~= '!'
					local name = not value and condition:sub(2) or condition
					if name:sub(1, 4) == 'has_' or itable_has({'idle', 'image', 'audio', 'video', 'stream'}, name) then
						local prop = name:sub(1, 4) == 'has_' and name or 'is_' .. name
						group[prop] = value
					else
						disposition_props[#disposition_props + 1] = name
						group[name] = value
					end
				end
			end
			dispositions[#dispositions + 1] = group
		end

		-- Convert toggles into cycles
		if kind == 'toggle' then
			kind = 'cycle'
			params[#params + 1] = 'no/yes!'
		end

		-- Create a control element
		local control = {dispositions = dispositions, kind = kind}

		if kind == 'space' then
			control.sizing = 'space'
		elseif kind == 'gap' then
			table_assign(control, {sizing = 'gap', scale = 1, ratio = params[1] or 0.3, ratio_min = 0})
		elseif kind == 'reserve' then
			-- Invisible fixed-width slot used to balance asymmetric side groups
			-- without adding another visible or clickable control.
			table_assign(control, {
				sizing = 'static', scale = tonumber(params[1]) or 1, ratio = 1,
			})
		elseif kind == 'command' then
			if #params < 2 or #params > 3 then
				mp.error(string.format(
					'command button needs 2 or 3 parameters, %d received: %s', #params, table.concat(params, '/')
				))
			else
				local element = Button:new('control_' .. i, {
					render_order = self.render_order,
					icon = params[1],
					anchor_id = 'controls',
					on_click = function() mp.command(params[2]) end,
					on_secondary_click = params[3] and function() mp.command(params[3]) end or nil,
					tooltip = tooltip,
					count_prop = 'sub',
				})
				table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
				if params[1] == 'skip_previous' or params[1] == 'skip_next' then
					control.narrow_priority = 2
				end
				if badge then self:register_badge_updater(badge, element) end
			end
		elseif kind == 'cycle' then
			if #params ~= 3 then
				mp.error(string.format(
					'cycle button needs 3 parameters, %d received: %s',
					#params, table.concat(params, '/')
				))
			else
				local state_configs = split(params[3], ' */ *')
				local states = {}

				for _, state_config in ipairs(state_configs) do
					local active = false
					if state_config:sub(-1) == '!' then
						active = true
						state_config = state_config:sub(1, -2)
					end
					local state_params = split(state_config, ' *= *')
					local value, icon = state_params[1], state_params[2] or params[1]
					states[#states + 1] = {value = value, icon = icon, active = active}
				end

				local element = CycleButton:new('control_' .. i, {
					render_order = self.render_order,
					prop = params[2],
					anchor_id = 'controls',
					states = states,
					tooltip = tooltip,
					idle_icon = params[2] == 'pause' and 'play_arrow' or nil,
				})
				local scale = params[2] == 'pause' and 1.12 or 1
				table_assign(control, {element = element, sizing = 'static', scale = scale, ratio = 1})
				if params[2] == 'pause' then control.narrow_priority = 3 end
				if badge then self:register_badge_updater(badge, element) end
			end
		elseif kind == 'button' then
			if #params ~= 1 then
				mp.error(string.format(
					'managed button needs 1 parameter, %d received: %s', #params, table.concat(params, '/')
				))
			else
				local element = ManagedButton:new('control_' .. i, {
					name = params[1],
					render_order = self.render_order,
					anchor_id = 'controls',
					on_hide = function() self:reflow() end,
				})
				table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
			end
		elseif kind == 'speed' then
			if not Elements.speed then
				local element = Speed:new({anchor_id = 'controls', render_order = self.render_order})
				local scale = tonumber(params[1]) or 1.3
				table_assign(control, {
					element = element, sizing = 'dynamic', scale = scale, ratio = 3.5, ratio_min = 2,
				})
			else
				msg.error('there can only be 1 speed slider')
			end
		elseif kind == 'time' then
			local element = TimeDisplay:new({anchor_id = 'controls', render_order = self.render_order})
			table_assign(control, {
				element = element, sizing = 'static', scale = 1, ratio = 3.8, narrow_priority = 1,
			})
		elseif kind == 'speed-button' then
			local element = SpeedButton:new({anchor_id = 'controls', render_order = self.render_order})
			table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 3.8})
		else
			msg.error('unknown element kind "' .. kind .. '"')
			break
		end

		if control.element then
			for _, prop in ipairs(disposition_props) do
				control.element:observe_mp_property(prop, function() self:reflow() end)
			end
		end
		self.controls[#self.controls + 1] = control
	end

	self:reflow()
end

function Controls:reflow()
	-- Populate the layout only with items that are not hidden and match current disposition
	self.layout = {}
	for _, control in ipairs(self.controls) do
		local matches = false
		local conditions_num = 0

		-- Check against OR groups of AND conditions
		for _, group in pairs(control.dispositions) do
			local group_matches = true
			for prop, value in pairs(group) do
				conditions_num = conditions_num + 1
				---@type boolean
				local current_value
				if prop:sub(1, 4) == 'has_' or prop:sub(1, 3) == 'is_' then
					current_value = state[prop]
				else
					current_value = mp.get_property_bool(prop, false)
				end
				if current_value ~= value then
					group_matches = false
					break
				end
			end
			if group_matches then
				matches = true
				break
			end
		end

		if conditions_num == 0 then matches = true end
		local show = matches and (not control.element or control.element.hide ~= true)
		if control.element then control.element.enabled = show end
		if show then self.layout[#self.layout + 1] = control end
	end

	self:update_dimensions()
	Elements:trigger('controls_reflow')
end

---@param badge string
---@param element Element An element that supports `badge` property.
function Controls:register_badge_updater(badge, element)
	local prop_and_limit = split(badge, ' *> *')
	local prop, limit = prop_and_limit[1], tonumber(prop_and_limit[2] or -1)
	local observable_name, serializer, is_external_prop = prop, nil, false

	if itable_index_of({'sub', 'audio', 'video'}, prop) then
		observable_name = 'track-list'
		serializer = function(value)
			local count = 0
			for _, track in ipairs(value) do if track.type == prop then count = count + 1 end end
			return count
		end
	elseif prop == 'playlist' then
		observable_name = 'playlist-count'
		serializer = function(count) return count end
	else
		local parts = split(prop, '@')
		-- Support both new `prop@owner` and old `@prop` syntaxes
		if #parts > 1 then prop, is_external_prop = parts[1] ~= '' and parts[1] or parts[2], true end
		serializer = function(value) return value and (type(value) == 'table' and #value or tostring(value)) or nil end
	end

	local function handler(_, value)
		local new_value = serializer(value) --[[@as nil|string|integer]]
		local value_number = tonumber(new_value)
		if value_number then new_value = value_number > limit and value_number or nil end
		element.badge = new_value
		request_render()
	end

	if is_external_prop then
		element['on_external_prop_' .. prop] = function(_, value) handler(prop, value) end
	else
		element:observe_mp_property(observable_name, handler)
	end
end

function Controls:get_target_visibility()
	if Elements:v('speed', 'dragging') then return 1 end
	-- Only hide controls when the timeline is actively being pressed/dragged,
	-- not when merely hovered. This keeps bottom buttons visible while the
	-- user moves the mouse over the progress bar to seek or preview thumbnails.
	local timeline = Elements.timeline
	if timeline and timeline.pressed then return -1 end
	return Element.get_visibility(self)
end

function Controls:get_visibility()
	local target = self:get_target_visibility()
	if target == -1 then return -1 end
	return dock_motion and dock_motion:get_controls_opacity() or target
end

function Controls:get_visual_transform()
	return dock_motion and dock_motion:get_controls_transform()
		or {scale = 1, translate_y = 0}
end

function Controls:get_visual_bounds()
	local first, last
	for _, control in ipairs(self.layout) do
		local element = control.element
		if not control.hide and element and element.enabled then
			first = first or element
			last = element
		end
	end
	if not first or not last then return end

	local function icon_edge(element, side)
		local center = element.ax + (element.bx - element.ax) / 2
		local visual_width = element.font_size or (element.by - element.ay) * 0.78
		local glyph_width = visual_width * (icon_width_factor[element.icon] or 0.72)
		return center + side * glyph_width / 2
	end
	return icon_edge(first, -1), icon_edge(last, 1)
end

function Controls:update_dimensions()
	local window_border = Elements:v('window_border', 'size', 0)
	local size = round(options.controls_size * state.scale)
	local spacing = round(options.controls_spacing * state.scale)
	local margin = round(options.controls_margin * state.scale)

	-- Disable when not enough space
	local available_space = display.height - window_border * 2 - Elements:v('top_bar', 'size', 0)
		- Elements:v('timeline', 'size', 0)
	self.enabled = available_space > size + 10

	-- Reset hide/enabled flags
	for c, control in ipairs(self.layout) do
		control.hide = false
		if control.element then control.element.enabled = self.enabled end
	end

	if not self.enabled then return end

	-- Container. Optically center the controls in the actually visible area
	-- between the timeline and the bottom edge. A slight proportional bias
	-- toward the bottom compensates for the timeline's strong visual edge while
	-- still adapting to HiDPI/fullscreen scaling and custom timeline sizes.
	self.bx = display.width - window_border - margin
	local console_bottom = display.height - window_border
	local center_y = console_bottom - margin - size / 2
	local timeline = Elements.timeline
	if timeline and timeline.enabled and timeline.by > timeline.ay then
		local timeline_center_y = timeline.ay + (timeline.by - timeline.ay) / 2
		local optical_center_ratio = 0.52
		center_y = timeline_center_y
			+ (console_bottom - timeline_center_y) * optical_center_ratio
	end
	self.ay = round(center_y - size / 2)
	self.by = self.ay + size
	self.ax = window_border + margin

	-- Controls
	local available_width, statics_width = self.bx - self.ax, 0
	local min_content_width = statics_width
	local max_dynamics_width, dynamic_units, spaces, gaps = 0, 0, 0, 0

	-- Calculate statics_width, min_content_width, and count spaces & gaps
	for c, control in ipairs(self.layout) do
		if control.sizing == 'space' then
			spaces = spaces + 1
		elseif control.sizing == 'gap' then
			gaps = gaps + control.scale * control.ratio
		elseif control.sizing == 'static' then
			local width = size * control.scale * control.ratio + (c ~= #self.layout and spacing or 0)
			statics_width = statics_width + width
			min_content_width = min_content_width + width
		elseif control.sizing == 'dynamic' then
			local spacing = (c ~= #self.layout and spacing or 0)
			statics_width = statics_width + spacing
			min_content_width = min_content_width + size * control.scale * control.ratio_min + spacing
			max_dynamics_width = max_dynamics_width + size * control.scale * control.ratio
			dynamic_units = dynamic_units + control.scale * control.ratio
		end
	end

	-- Hide & disable elements until we fit into available width. Secondary
	-- controls still collapse from the middle out, but the transport trio stays
	-- intact for as long as possible. If an extremely narrow window cannot fit
	-- it, previous/next disappear together before play/pause.
	if min_content_width > available_width then
		local hide_order = {}
		local i = math.ceil(#self.layout / 2 + 0.1)
		for a = 0, #self.layout - 1, 1 do
			i = i + (a * (a % 2 == 0 and 1 or -1))
			hide_order[#hide_order + 1] = i
		end

		local function hide_control(control)
			control.hide = true
			if control.element then control.element.enabled = false end
			if control.sizing == 'static' then
				local width = size * control.scale * control.ratio
				min_content_width = min_content_width - width - spacing
				statics_width = statics_width - width - spacing
			elseif control.sizing == 'dynamic' then
				statics_width = statics_width - spacing
				min_content_width = min_content_width - size * control.scale * control.ratio_min - spacing
				max_dynamics_width = max_dynamics_width - size * control.scale * control.ratio
				dynamic_units = dynamic_units - control.scale * control.ratio
			end
		end

		for priority = 0, 3 do
			for _, index in ipairs(hide_order) do
				local control = self.layout[index]
				if control.sizing ~= 'gap' and control.sizing ~= 'space'
					and (control.narrow_priority or 0) == priority then
					hide_control(control)
				end

				-- Priority 2 is the previous/next pair: finish the entire pass so
				-- the pair cannot degrade into a visually lopsided single button.
				if priority ~= 2 and min_content_width < available_width then break end
			end
			if min_content_width < available_width then break end
		end
	end

	-- Lay out the elements
	local current_x = self.ax
	local width_for_dynamics = available_width - statics_width
	local empty_space_width = width_for_dynamics - max_dynamics_width
	local width_for_gaps = math.min(empty_space_width, size * gaps)
	local individual_space_width = spaces > 0 and ((empty_space_width - width_for_gaps) / spaces) or 0
	individual_space_width = math.max(0, individual_space_width)

	local function get_control_dimensions(control, space_width)
		local sizing, scale, ratio = control.sizing, control.scale, control.ratio
		local width, height = 0, 0
		if sizing == 'space' then
			width = space_width or 0
		elseif sizing == 'gap' then
			if width_for_gaps > 0 then width = width_for_gaps * (ratio / gaps) end
		elseif sizing == 'static' then
			height = size * scale
			width = height * ratio
		elseif sizing == 'dynamic' then
			height = size * scale
			width = max_dynamics_width < width_for_dynamics
				and height * ratio or width_for_dynamics * ((scale * ratio) / dynamic_units)
		end
		return width, height
	end

	-- Equal flexible spaces center the whole middle group only when the left and
	-- right button groups have identical widths. Anchor the play/pause control
	-- to the actual screen center by redistributing the two surrounding spaces.
	-- Clamping keeps both spaces non-negative on narrow windows.
	local space_adjustments = {}
	local anchor_index
	for c, control in ipairs(self.layout) do
		if not control.hide and control.element and control.element.prop == 'pause' then
			anchor_index = c
			break
		end
	end
	if anchor_index and individual_space_width > 0 then
		local space_before, space_after
		for c = anchor_index - 1, 1, -1 do
			local control = self.layout[c]
			if not control.hide and control.sizing == 'space' then
				space_before = c
				break
			end
		end
		for c = anchor_index + 1, #self.layout do
			local control = self.layout[c]
			if not control.hide and control.sizing == 'space' then
				space_after = c
				break
			end
		end

		if space_before and space_after then
			local current_x, anchor_center = self.ax, nil
			for c, control in ipairs(self.layout) do
				if not control.hide then
					local width = get_control_dimensions(control, individual_space_width)
					if c == anchor_index then
						anchor_center = current_x + width / 2
						break
					end
					current_x = current_x + width
					if control.sizing == 'static' or control.sizing == 'dynamic' then
						current_x = current_x + spacing
					end
				end
			end

			if anchor_center then
				local target_center = self.ax + (self.bx - self.ax) / 2
				local shift = math.max(-individual_space_width,
					math.min(individual_space_width, target_center - anchor_center))
				space_adjustments[space_before] = shift
				space_adjustments[space_after] = -shift
			end
		end
	end

	for c, control in ipairs(self.layout) do
		if not control.hide then
			local sizing, element = control.sizing, control.element
			local space_width = individual_space_width + (space_adjustments[c] or 0)
			local width, height = get_control_dimensions(control, space_width)

			local bx = current_x + width
			if element then
				local center_y = self.ay + (self.by - self.ay) / 2
				element:set_coordinates(
					round(current_x),
					round(center_y - height / 2),
					bx,
					round(center_y + height / 2)
				)
			end
			current_x = (sizing == 'static' or sizing == 'dynamic') and bx + spacing or bx
		end
	end

	Elements:update_proximities()
	request_render()
end

function Controls:on_dispositions() self:reflow() end
function Controls:on_display() self:update_dimensions() end
function Controls:on_prop_border() self:update_dimensions() end
function Controls:on_prop_title_bar() self:update_dimensions() end
function Controls:on_prop_fullormaxed() self:update_dimensions() end
function Controls:on_timeline_enabled() self:update_dimensions() end

function Controls:destroy_elements()
	for _, control in ipairs(self.controls) do
		if control.element then control.element:destroy() end
	end
end

function Controls:on_options()
	self:destroy_elements()
	self:init_options()
end

return Controls
