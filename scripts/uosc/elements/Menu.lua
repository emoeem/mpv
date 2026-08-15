local Element = require('elements/Element')

---@alias MenuAction {name: string; icon: string; label?: string; filter_hidden?: boolean;}
---@alias MenuSearchAction {name: string; icon: string; label?: string;}

-- Menu data structure accepted by `Menu:open(menu)`.
---@alias MenuData {id?: string; type?: string; title?: string; hint?: string; min_width?: number; min_width_px?: boolean; fixed_columns?: boolean; uniform_title_size?: boolean; footnote: string; content_padding_bottom?: number; search_style?: 'on_demand' | 'palette' | 'disabled'; search_action?: MenuSearchAction; search_cursor_blink?: boolean; search_focus_indicator?: boolean; item_actions?: MenuAction[]; item_actions_place?: 'inside' | 'outside'; callback?: string[]; keep_open?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; items?: MenuDataChild[]; selected_index?: integer; on_search?: string|string[]; on_search_action?: string|string[]; on_paste?: string|string[]; on_move?: string|string[]; on_close?: string|string[]; search_debounce?: number|string; search_submenus?: boolean; search_suggestion?: string; search_submit?: boolean; back_on_escape?: boolean; bind_keys?: string[]}
---@alias MenuDataChild MenuDataItem|MenuData
---@alias MenuDataItem {title?: string; hint?: string; icon?: string; value: any; actions?: MenuAction[]; actions_place?: 'inside' | 'outside'; active?: boolean; keep_open?: boolean; selectable?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; opacity?: number; separator?: boolean; align?: 'left'|'center'|'right'; search_exact_hint?: boolean}
---@alias MenuOptions {mouse_nav?: boolean;}

-- Internal data structure created from `MenuData`.
---@alias MenuStack {id?: string; type?: string; title?: string; hint?: string; footnote: string; min_width?: number; min_width_px?: boolean; fixed_columns?: boolean; uniform_title_size?: boolean; content_padding_bottom?: number; search_style?: 'on_demand' | 'palette' | 'disabled'; search_action?: MenuSearchAction; search_cursor_blink?: boolean; search_focus_indicator?: boolean; item_actions?: MenuAction[]; item_actions_place?: 'inside' | 'outside'; callback?: string[]; selected_index?: number; action_index?: number; keep_open?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; items: MenuStackChild[]; on_search?: string|string[]; on_search_action?: string|string[]; on_paste?: string|string[]; on_move?: string|string[]; on_close?: string|string[]; search_debounce?: number|string; search_submenus?: boolean; search_suggestion?: string; search_submit?: boolean; back_on_escape?: boolean; bind_keys?: string[]; parent_menu?: MenuStack; submenu_path: integer[]; active?: boolean; width: number; height: number; top: number; scroll_y: number; scroll_height: number; title_width: number; hint_width: number; max_hint_width: number; max_item_width: number; max_width: number; is_root?: boolean; fling?: Fling, search?: Search, ass_safe_title?: string}
---@alias MenuStackChild MenuStackItem|MenuStack
---@alias MenuStackItem {title?: string; hint?: string; icon?: string; value: any; actions?: MenuAction[]; actions_place?: 'inside' | 'outside'; active?: boolean; keep_open?: boolean; selectable?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; opacity?: number; separator?: boolean; align?: 'left'|'center'|'right'; title_width: number; hint_width: number; ass_safe_hint?: string}
---@alias Fling {y: number, distance: number, time: number, easing: fun(x: number), duration: number, update_cursor?: boolean}
---@alias Search {query: string; cursor: number; timeout: unknown; min_top: number; max_width: number; source: {width: number; top: number; scroll_y: number; selected_index?: integer; items?: MenuStackChild[]}}

---@alias MenuEventActivate {type: 'activate'; index: number; value: any; action?: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean; is_pointer: boolean; keep_open?: boolean; menu_id: string;}
---@alias MenuEventMove {type: 'move'; from_index: number; to_index: number; menu_id: string;}
---@alias MenuEventSearch {type: 'search'; query: string; menu_id: string;}
---@alias MenuEventSearchAction {type: 'search_action'; action: string; query: string; menu_id: string; is_pointer: boolean;}
---@alias MenuEventKey {type: 'key'; id: string; key: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean; menu_id: string; selected_item?: {index: number; value: any; action?: string;}}
---@alias MenuEventPaste {type: 'paste'; value: string; menu_id: string; selected_item?: {index: number; value: any; action?: string;}}
---@alias MenuEventBack {type: 'back';}
---@alias MenuEventClose {type: 'close';}
---@alias MenuEvent MenuEventActivate | MenuEventMove | MenuEventSearch | MenuEventSearchAction | MenuEventKey | MenuEventPaste | MenuEventBack | MenuEventClose
---@alias MenuCallback fun(data: MenuEvent)

---@class Menu : Element
local Menu = class(Element)

-- Menu motion stays local because the global animation duration can be disabled.
-- A short, shallow alpha transition softens context-menu open/close without
-- re-enabling the legacy wide submenu slide animations.
local menu_open_opacity = 0.82
local menu_open_duration = 80
local menu_close_duration = 60
local wheel_scroll_rows = 2
local wheel_scroll_duration = 0.09
local wheel_hover_suppression = 0.12
local search_cursor_blink_interval = 0.55

local function is_file_navigation_menu(menu)
	local menu_type = tostring(menu.type or '')
	return menu_type == 'open-file' or menu_type:match('^load%-') ~= nil
end

local function uses_uniform_title_size(menu)
	return menu.uniform_title_size
		or menu.type == 'playlist'
		or menu.type == 'sub'
		or menu.type == 'audio'
		or menu.type == 'video'
		or menu.type == 'menu_subtitle'
		or menu.type == 'recent_menu'
		or is_file_navigation_menu(menu)
end

local function uses_fixed_columns(menu)
	return menu.fixed_columns
		or (uses_uniform_title_size(menu) and (menu.max_hint_width or 0) > 0)
end

local function get_responsive_width_bounds(menu)
	if menu.type == 'recent_menu' then return nil, nil end

	local scale = math.max(state.scale, 0.01)
	local logical_display_width = display.width / scale
	local logical_content_width = (
		is_file_navigation_menu(menu) and menu.max_item_width
		or menu.max_width
		or 0
	) / scale
	local minimum_width, maximum_width

	if is_file_navigation_menu(menu) then
		-- Directory titles are often much longer than the visible file rows.
		-- Size from row content and let the centered title ellipsize instead of
		-- turning the browser into a wide empty panel.
		maximum_width = math.min(logical_display_width * 0.60, 760)
		minimum_width = math.min(math.max(logical_content_width * 1.04, 560), maximum_width)
	elseif menu.type == 'playlist' then
		maximum_width = math.min(logical_display_width * 0.72, 1020)
		minimum_width = math.min(math.max(logical_content_width * 1.22, 680), maximum_width)
	elseif menu.uniform_title_size and (menu.search or menu.search_style == 'palette') then
		maximum_width = math.min(logical_display_width * 0.60, 640)
		minimum_width = math.min(math.max(logical_content_width * 1.06, 480), maximum_width)
	elseif uses_uniform_title_size(menu) and (menu.max_hint_width or 0) > 0 then
		maximum_width = math.min(logical_display_width * 0.56, 600)
		minimum_width = math.min(math.max(logical_content_width * 1.04, 440), maximum_width)
	end

	return minimum_width and minimum_width * scale or nil,
		maximum_width and maximum_width * scale or nil
end

local function utf8_prefix_for_width(value, max_width, opts)
	local prefix = ''
	for char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
		local candidate = prefix .. char
		if text_width(candidate, opts) > max_width then break end
		prefix = candidate
	end
	return prefix
end

-- Calculate the size needed to fit text, then add a visible ellipsis after
-- reaching the readable minimum instead of ending abruptly.
local function fit_text_to_width(value, max_width, base_size, min_size, opts, policy)
	if not value or value == '' or max_width <= 0 then return base_size, nil end

	-- libass can render mixed Latin/CJK labels a little wider than the width
	-- estimated from cached glyph metrics. Fit overflowing labels against a
	-- conservative budget so they do not reach the hard clip at runtime.
	local fit_ratio = policy and policy.fit_ratio or 0.92
	local fit_width = max_width * fit_ratio
	local measure_opts = table_assign({}, opts or {}, {size = base_size})
	local width = text_width(value, measure_opts)
	if width <= fit_width then return base_size, nil end

	local fitted_size = math.max(min_size, math.floor(base_size * fit_width / width))
	measure_opts.size = fitted_size
	local force_ellipsis = policy and (
		(policy.force_ellipsis_when_scaled and fitted_size < base_size)
		or (policy.force_ellipsis_at_floor and fitted_size <= min_size + 1)
	)
	if text_width(value, measure_opts) <= fit_width and not force_ellipsis then
		return fitted_size, nil
	end

	local ellipsis = '…'
	-- Once text has reached its readable minimum, leave a larger final guard.
	-- Very long Latin runs can accumulate enough metric error to push the
	-- ellipsis itself outside the clip even when the measured prefix fits.
	local ellipsis_ratio = policy and policy.ellipsis_ratio or fit_ratio * 0.88
	local prefix_width = math.max(
		0,
		max_width * ellipsis_ratio - text_width(ellipsis, measure_opts)
	)
	local prefix = utf8_prefix_for_width(value, prefix_width, measure_opts)
	return fitted_size, ass_escape(prefix .. ellipsis)
end

---@param data MenuData
---@param callback MenuCallback
---@param opts? MenuOptions
function Menu:open(data, callback, opts)
	local open_menu = Menu:is_open()
	if open_menu then
		open_menu.is_being_replaced = true
		open_menu:close(true)
	end
	return Menu:new(data, callback, opts)
end

---@param menu_type? string
---@return Menu|nil
function Menu:is_open(menu_type)
	return Elements.menu and (not menu_type or Elements.menu.type == menu_type) and Elements.menu or nil
end

---@param immediate? boolean Close immediately without fadeout animation.
---@param callback? fun() Called after the animation (if any) ends and element is removed and destroyed.
---@overload fun(callback: fun())
function Menu:close(immediate, callback)
	if type(immediate) ~= 'boolean' then callback = immediate end

	local menu = self == Menu and Elements.menu or self

	if state.ime_active == false and mp.get_property_bool('input-ime') then
		mp.set_property_bool('input-ime', false)
	end

	if menu and not menu.destroyed then
		if menu.is_closing then
			menu:tween_stop()
			return
		end

		local function close()
			local on_close = menu.root.on_close -- removed in menu:destroy()
			Elements:remove('menu') -- calls menu:destroy() under the hood
			Elements:update_proximities()
			cursor:queue_autohide()

			-- Call :close() callback
			if callback then callback() end

			-- Call callbacks/events defined on menu config
			local close_event = {type = 'close'}
			if not on_close or menu:command_or_event(on_close, {}, close_event) ~= 'event' then
				menu.callback(close_event)
			end

			request_render()
		end

		menu.is_closing = true

		if immediate then
			close()
		else
			menu:fadeout(close)
		end
	end
end

---@param data MenuData
---@param callback MenuCallback
---@param opts? MenuOptions
---@return Menu
function Menu:new(data, callback, opts) return Class.new(self, data, callback, opts) --[[@as Menu]] end
---@param data MenuData
---@param callback MenuCallback
---@param opts? MenuOptions
function Menu:init(data, callback, opts)
	Element.init(self, 'menu', {render_order = 1001})

	-----@type fun()
	self.callback = callback
	self.opts = opts or {}
	self.offset_x = 0 -- Used for submenu transition animation.
	self.mouse_nav = self.opts.mouse_nav -- Stops pre-selecting items
	self.item_height = nil
	self.min_width = nil
	self.item_spacing = 1
	self.item_padding = nil
	self.separator_size = nil
	self.padding = nil
	self.gap = nil
	self.font_size = nil
	self.font_size_hint = nil
	self.scroll_step = nil -- Item height + item spacing.
	self.scroll_height = nil -- Items + spacings - container height.
	self.opacity = menu_open_opacity -- Used to fade in/out.
	self.type = data.type
	---@type MenuStack Root MenuStack.
	self.root = nil
	---@type MenuStack Current MenuStack.
	self.current = nil
	---@type MenuStack[] All menus in a flat array.
	self.all = nil
	---@type table<string, MenuStack> Map of submenus by their ids, such as `'Tools > Aspect ratio'`.
	self.by_id = {}
	self.type_to_search = options.menu_type_to_search
	self.is_being_replaced = false
	self.is_closing = false
	self.drag_last_y = nil
	self.is_dragging = false
	self.scrollbar_hide_timer = mp.add_timeout(0.8, function() request_render() end)
	self.scrollbar_hide_timer:kill()
	self:register_disposer(function() self.scrollbar_hide_timer:kill() end)
	self.search_cursor_visible = true
	self.search_cursor_timer = mp.add_periodic_timer(search_cursor_blink_interval, function()
		local menu = self.current
		if menu and menu.search and menu.search_cursor_blink and not menu.selected_index
			and not self.is_closing then
			self.search_cursor_visible = not self.search_cursor_visible
			request_render()
		elseif not self.search_cursor_visible then
			self.search_cursor_visible = true
			request_render()
		end
	end)
	self:register_disposer(function() self.search_cursor_timer:kill() end)
	self.pointer_menu = nil
	self.pointer_index = nil

	if utils.shared_script_property_set then
		utils.shared_script_property_set('uosc-menu-type', self.type or 'undefined')
	end
	mp.set_property_native('user-data/uosc/menu/type', self.type or 'undefined')
	self:update(data)

	for _, menu in ipairs(self.all) do self:scroll_to_index(menu.selected_index, menu.id) end
	if self.mouse_nav then self.current.selected_index = nil end

	self:tween_property('opacity', self.opacity, 1, menu_open_duration)
	self:enable_key_bindings()
	Elements:maybe('curtain', 'register', self.id)

	if data.search_submit then
		-- We have to defer this so that menu callbacks don't fire before the menu
		-- instance we're constructing here is returned, as they might depend on it.
		mp.add_timeout(0.01, function()
			self:search_submit()
		end)
	end
end

function Menu:destroy()
	Element.destroy(self)
	self.is_closing = false
	if not self.is_being_replaced then Elements:maybe('curtain', 'unregister', self.id) end
	if utils.shared_script_property_set then
		utils.shared_script_property_set('uosc-menu-type', nil)
	end
	mp.set_property_native('user-data/uosc/menu/type', nil)
end

---@param data MenuData
function Menu:update(data)
	local new_root = {is_root = true, submenu_path = {}}
	local new_all = {}
	local new_menus = {} -- menus that didn't exist before this `update()`
	local new_by_id = {}
	local menus_to_serialize = {{new_root, data}}
	local old_current_id = self.current and self.current.id
	local menu_state_props = {'selected_index', 'action_index', 'scroll_y', 'fling', 'search'}
	local internal_props_set = create_set(itable_append({'is_root', 'submenu_path', 'id', 'items'}, menu_state_props))

	table_assign_exclude(new_root, data, internal_props_set)

	local i = 0
	while i < #menus_to_serialize do
		i = i + 1
		local menu, menu_data = menus_to_serialize[i][1], menus_to_serialize[i][2]
		local parent_id = menu.parent_menu and not menu.parent_menu.is_root and menu.parent_menu.id
		if menu_data.id then
			menu.id = menu_data.id
		elseif not menu.is_root then
			menu.id = (parent_id and parent_id .. ' > ' or '') .. (menu_data.title or i)
		else
			menu.id = '{root}'
		end
		menu.icon = 'chevron_right'

		-- Normalize `search_debounce`
		if type(menu_data.search_debounce) == 'number' then
			menu.search_debounce = math.max(0, menu_data.search_debounce --[[@as number]])
		elseif menu_data.search_debounce == 'submit' then
			menu.search_debounce = 'submit'
		else
			menu.search_debounce = menu.on_search and 300 or 0
		end

		-- Update items
		local first_active_index = nil
		menu.items = {
			{title = t('Empty'), value = 'ignore', italic = 'true', muted = 'true', selectable = false, align = 'center'},
		}

		for i, item_data in ipairs(menu_data.items or {}) do
			if item_data.active and not first_active_index then first_active_index = i end

			local item = {}
			table_assign_exclude(item, item_data, internal_props_set)
			if item.keep_open == nil then item.keep_open = menu.keep_open end

			-- Submenu
			if item_data.items then
				item.parent_menu = menu
				item.submenu_path = itable_join(menu.submenu_path, {i})
				menus_to_serialize[#menus_to_serialize + 1] = {item, item_data}
			end

			menu.items[i] = item
		end

		if menu.is_root then menu.selected_index = menu_data.selected_index or first_active_index end

		-- Retain old state
		local old_menu = self.by_id[menu.id]
		if old_menu then
			table_assign_props(menu, old_menu, menu_state_props)
		else
			new_menus[#new_menus + 1] = menu
		end

		new_all[#new_all + 1] = menu
		new_by_id[menu.id] = menu
	end

	self.root, self.all, self.by_id = new_root, new_all, new_by_id
	self.current = self.by_id[old_current_id] or self.root

	self:update_content_dimensions()
	self:reset_navigation()

	-- Ensure palette menus have active searches, and clean empty searches from menus that lost the `palette` flag
	local update_dimensions_again = false
	for _, menu in ipairs(self.all) do
		local is_palette = menu.search_style == 'palette'
		if not menu.search and (is_palette or (menu.search_suggestion and itable_index_of(new_menus, menu))) then
			update_dimensions_again = true
			self:search_init(menu.id)
		elseif not is_palette and menu.search and menu.search.query == '' then
			update_dimensions_again = true
			menu.search = nil
		end
	end
	-- We update before _and_ after because search_inits need the initial un-searched
	-- menu's position and scroll state to save on the `search.source` table.
	if update_dimensions_again then
		self:update_content_dimensions()
		self:reset_navigation()
	end
	-- Apply search suggestions
	for _, menu in ipairs(new_menus) do
		if menu.search_suggestion then
			menu.search.query = menu.search_suggestion
			menu.search.cursor = #menu.search_suggestion
		end
	end
	for _, menu in ipairs(self.all) do
		if menu.search then
			-- the menu items are new objects and the search needs to contain those
			menu.search.source.items = not menu.on_search and menu.items or nil
			-- Only internal searches are immediately submitted
			if not menu.on_search then self:search_internal(menu.id, true) end
		end

		if menu.selected_index then self:select_by_offset(0, menu) end
	end

	self:search_ensure_key_bindings()
end

---@param items MenuDataChild[]
function Menu:update_items(items)
	local data = table_assign({}, self.root)
	data.items = items
	self:update(data)
end

function Menu:update_content_dimensions()
	local logical_display_height = display.height / math.max(state.scale, 0.01)
	local density_scale = logical_display_height < 600 and 0.86
		or logical_display_height < 800 and 0.86
		or logical_display_height < 900 and 0.94
		or 1
	self.item_height = round(options.menu_item_height * state.scale * density_scale)
	self.min_width = round(options.menu_min_width * state.scale)
	self.separator_size = round(1 * state.scale)
	self.scrollbar_size = round(2 * state.scale)
	self.padding = round(options.menu_padding * state.scale)
	self.gap = round(2 * state.scale)
	self.font_size = round(self.item_height * 0.46 * options.font_scale)
	self.font_size_hint = self.font_size - 1
	self.font = options.menu_font ~= '' and options.menu_font or config.font
	self.item_padding = round((self.item_height - self.font_size) * 0.6)
	self.scroll_step = self.item_height + self.item_spacing

	local title_opts = {size = self.font_size, font = self.font, italic = false, bold = false}
	-- Uniform lists render hints at the title size, so measuring every hint at
	-- that size prevents the first glyph from being clipped in mixed CJK rows.
	local hint_opts = {size = self.font_size, font = self.font}
	self.ellipsis_width = text_width('…', title_opts)

	for _, menu in ipairs(self.all) do
		title_opts.bold, title_opts.italic = true, false
		local max_width = text_width(menu.title, title_opts) + 2 * self.item_padding
		local max_title_width = 0
		local max_hint_width = 0
		local max_icon_width = 0
		local max_item_width = 0

		-- Estimate width of a widest item
		for _, item in ipairs(menu.items) do
			local icon_width = item.icon and self.font_size or 0
			-- Keep a small guard around measured glyphs. libass fallback fonts
			-- can be wider than the cached metrics, especially for CJK/Latin mixes.
			item.title_width = math.ceil(text_width(item.title, title_opts) * 1.06)
			item.hint_width = math.ceil(text_width(item.hint, hint_opts) * 1.08)
			max_title_width = math.max(max_title_width, item.title_width)
			max_hint_width = math.max(max_hint_width, item.hint_width)
			max_icon_width = math.max(max_icon_width, icon_width)
			local spacings_in_item = 1 + (item.title_width > 0 and 1 or 0)
				+ (item.hint_width > 0 and 1 or 0) + (icon_width > 0 and 1 or 0)
			local estimated_width = item.title_width + item.hint_width + icon_width
				+ (self.item_padding * spacings_in_item)
			max_item_width = math.max(max_item_width, estimated_width)
			if estimated_width > max_width then max_width = estimated_width end
		end

		menu.max_hint_width = max_hint_width
		if uses_fixed_columns(menu) and max_hint_width > 0 then
			local column_spacings = 3 + (max_icon_width > 0 and 1 or 0)
			local fixed_column_width = max_title_width + max_hint_width + max_icon_width
				+ self.item_padding * column_spacings
			max_item_width = math.max(max_item_width, fixed_column_width)
			max_width = math.max(max_width, fixed_column_width)
		end
		menu.max_item_width = max_item_width
		menu.max_width = max_width
	end

	self:update_dimensions()
end

function Menu:update_dimensions()
	-- Coordinates and sizes are of the scrollable area. Title is rendered
	-- above it, so we need to account for that in max_height and ay position.
	-- This is a debt from an era where we had different cursor event handling,
	-- and dumb titles with no search inputs. It could use a refactor.
	local margin = round(self.item_height / 2)
	local external_buttons_reserve = display.width / self.item_height > 14 and self.scroll_step * 6 - margin * 2 or 0
	local width_available = display.width - margin * 2 - self.padding * 2 - external_buttons_reserve
	local height_available = display.height - margin * 2 - self.padding * 2
	local min_width = math.min(self.min_width, width_available)

	for _, menu in ipairs(self.all) do
		local width = math.max(menu.search and menu.search.max_width or 0, menu.max_width)
		local preferred_width, maximum_width = get_responsive_width_bounds(menu)
		if maximum_width then width = math.min(width, maximum_width) end
		if preferred_width then width = math.max(width, preferred_width) end
		local menu_min_width = menu.min_width and (
			menu.min_width_px and round(menu.min_width)
			or round(menu.min_width * state.scale)
		) or min_width
		menu.width = round(clamp(math.min(menu_min_width, width_available), width, width_available))
		local title_height = (menu.is_root and menu.title or menu.search) and
			self.scroll_step + self.separator_size + 1 or 0
		-- Do not reserve an invisible footer. The default command menu has no
		-- footnote, so unconditional reserve made its top/bottom margins uneven.
		local footnote_height = menu.footnote and self.font_size * 1.5 or 0
		local max_height = height_available - title_height - footnote_height
		local content_padding_bottom = round((menu.content_padding_bottom or 0) * state.scale)
		local content_height = self.scroll_step * #menu.items + content_padding_bottom
		local full_content_height = content_height - self.item_spacing
		menu.height = math.min(full_content_height, max_height)
		if full_content_height > max_height then
			-- A viewport ending between two rows exposes a clipped half-row at
			-- rest. Quantize overflowing menus to complete rows; scrolling
			-- remains responsible for revealing the remaining items.
			local visible_rows = math.floor((max_height + self.item_spacing) / self.scroll_step)
			if visible_rows > 0 then
				menu.height = visible_rows * self.scroll_step - self.item_spacing
			end
		end
		menu.top = clamp(
			title_height + margin + self.padding,
			menu.search and math.min(menu.search.min_top, menu.search.source.top) or height_available,
			round((height_available - menu.height + title_height) / 2)
		)
		if menu.search then
			menu.search.min_top = math.min(menu.search.min_top, menu.top)
			menu.search.max_width = math.max(menu.search.max_width, menu.width)
		end
		menu.scroll_height = math.max(content_height - menu.height - self.item_spacing, 0)
		self:set_scroll_to(menu.scroll_y, menu.id) -- clamps scroll_y to scroll limits
	end

	-- Rendering used to walk the complete submenu tree on every frame just to
	-- reserve cascade width. Cache it whenever dimensions change so short menu
	-- fades and scroll flings do not multiply that work.
	local function cache_cascade_width(menu)
		local max_child_width = 0
		for _, item in ipairs(menu.items) do
			if item.items then
				max_child_width = math.max(max_child_width,
					self.gap + cache_cascade_width(item --[[@as MenuStack]]))
			end
		end
		menu.cascade_width = menu.width + self.padding * 2 + max_child_width
		return menu.cascade_width
	end
	cache_cascade_width(self.root)

	self:update_coordinates()
end

-- Updates element coordinates to match padding box of currently open (sub)menu.
function Menu:update_coordinates()
	local ax = round((display.width - self.current.width) / 2 - self.padding) + self.offset_x
	self:set_coordinates(
		ax, self.current.top - self.padding,
		ax + self.current.width + self.padding * 2, self.current.top + self.current.height + self.padding
	)
end

function Menu:reset_navigation()
	local menu = self.current

	-- Reset indexes and scroll
	self:set_scroll_to(menu.scroll_y) -- clamps scroll_y to scroll limits
	if menu.items and #menu.items > 0 then
		-- Normalize existing selected_index always, and force it only in keyboard navigation
		if not self.mouse_nav then
			self:select_by_offset(0)
		end
	else
		self:select_index(nil)
	end

	-- Walk up the parent menu chain and activate items that lead to current menu
	local parent = menu.parent_menu
	while parent do
		parent.selected_index = itable_index_of(parent.items, menu)
		menu, parent = parent, parent.parent_menu
	end

	request_render()
end

function Menu:set_offset_x(offset)
	local delta = offset - self.offset_x
	self.offset_x = offset
	self:set_coordinates(self.ax + delta, self.ay, self.bx + delta, self.by)
end

function Menu:fadeout(callback)
	self:tween_property('opacity', self.opacity, 0, menu_close_duration, callback)
end

-- If `menu_id` is provided, will return menu with that id or `nil`. If `menu_id` is `nil`, will return current menu.
---@param menu_id? string
---@return MenuStack | nil
function Menu:get_menu(menu_id) return menu_id == nil and self.current or self.by_id[menu_id] end

function Menu:get_first_active_index(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	for index, item in ipairs(menu.items) do
		if item.active then return index end
	end
end

---@param pos? number
---@param menu_id? string
function Menu:set_scroll_to(pos, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	menu.scroll_y = clamp(0, pos or 0, menu.scroll_height)
	request_render()
end

---@param delta? number
---@param menu_id? string
function Menu:set_scroll_by(delta, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	self:set_scroll_to(menu.scroll_y + delta, menu_id)
end

---@param pos? number
---@param menu_id? string
---@param fling_options? table
function Menu:scroll_to(pos, menu_id, fling_options)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	menu.fling = {
		y = menu.scroll_y,
		distance = clamp(-menu.scroll_y, pos - menu.scroll_y, menu.scroll_height - menu.scroll_y),
		time = mp.get_time(),
		duration = 0.1,
		easing = ease_out_sext,
	}
	if fling_options then table_assign(menu.fling, fling_options) end
	request_render()
end

---@param delta? number
---@param menu_id? string
---@param fling_options? Fling
function Menu:scroll_by(delta, menu_id, fling_options)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	self:scroll_to((menu.fling and (menu.fling.y + menu.fling.distance) or menu.scroll_y) + delta, menu_id, fling_options)
end

---@param index? integer
---@param menu_id? string
---@param immediate? boolean
function Menu:scroll_to_index(index, menu_id, immediate)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if (index and index >= 1 and index <= #menu.items) then
		local position = round((self.scroll_step * (index - 1)) - ((menu.height - self.scroll_step) / 2))
		if immediate then
			self:set_scroll_to(position, menu_id)
		else
			self:scroll_to(position, menu_id)
		end
	end
end

---@param index? integer
---@param menu_id? string
function Menu:select_index(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	menu.selected_index = (index and index >= 1 and index <= #menu.items) and index or nil
	self:select_action(menu.action_index, menu_id) -- normalize selected action index
	request_render()
end

---@param index? integer
---@param menu_id? string
function Menu:select_action(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local actions = menu.items[menu.selected_index] and menu.items[menu.selected_index].actions or menu.item_actions
	if not index or not actions or type(actions) ~= 'table' or index < 1 or index > #actions then
		menu.action_index = nil
		return
	end
	menu.action_index = index
	request_render()
end

---@param delta? integer
---@param menu_id? string
function Menu:navigate_action(delta, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local actions = menu.items[menu.selected_index] and menu.items[menu.selected_index].actions or menu.item_actions
	if actions and delta ~= 0 then
		-- Circular navigation where zero gets converted to nil
		local index = (menu.action_index or (delta > 0 and 0 or #actions + 1)) + delta
		self:select_action(index <= #actions and index > 0 and (index - 1) % #actions + 1 or nil, menu_id)
	else
		self:select_action(nil, menu_id)
	end
	request_render()
end

function Menu:next_action() self:navigate_action(1) end
function Menu:prev_action() self:navigate_action(-1) end

---@param value? any
---@param menu_id? string
function Menu:select_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:select_index(index)
end

---@param menu_id? string
function Menu:deactivate_items(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	for _, item in ipairs(menu.items) do item.active = false end
	request_render()
end

---@param index? integer
---@param menu_id? string
function Menu:activate_index(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if index and index >= 1 and index <= #menu.items then menu.items[index].active = true end
	request_render()
end

---@param value? any
---@param menu_id? string
function Menu:activate_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:activate_index(index, menu_id)
end

---@param value? any
---@param menu_id? string
function Menu:activate_one_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:activate_index(index, menu_id)
end

---@param id string One of menus in `self.all`.
function Menu:activate_menu(id)
	local menu = self:get_menu(id)
	if menu then
		self.current = menu
		self:update_coordinates()
		self:reset_navigation()
		self:search_ensure_key_bindings()
		local parent = menu.parent_menu
		while parent do
			parent.selected_index = itable_index_of(parent.items, menu)
			self:scroll_to_index(parent.selected_index, parent)
			menu, parent = parent, parent.parent_menu
		end
		request_render()
	end
end

---@param index? integer
---@param menu_id? string
function Menu:delete_index(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if (index and index >= 1 and index <= #menu.items) then
		table.remove(menu.items, index)
		self:update_content_dimensions()
		self:scroll_to_index(menu.selected_index, menu_id)
	end
end

---@param value? any
---@param menu_id? string
function Menu:delete_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:delete_index(index)
end

---@param id string Menu id.
---@param x number `x` coordinate to slide from.
function Menu:slide_in_menu(id, x)
	local menu = self:get_menu(id)
	if not menu then return end
	self:activate_menu(id)
	self:tween(-(display.width / 2 - menu.width / 2 - x), 0, function(offset) self:set_offset_x(offset) end)
	self.opacity = 1 -- in case tween above canceled fade in animation
end

function Menu:back()
	if not self:is_alive() then return end

	local current = self.current
	local parent = current.parent_menu

	if parent then
		self:slide_in_menu(parent.id, display.width / 2 - current.width / 2 - parent.width / 2 + self.offset_x)
	else
		self.callback({type = 'back'})
	end
end

---@param shortcut? Shortcut
---@param is_pointer? boolean Whether this was called by a pointer.
function Menu:activate_selected_item(shortcut, is_pointer)
	local menu = self.current
	local item = menu.items[menu.selected_index]
	if item then
		-- Is submenu
		if item.items then
			if not self.mouse_nav then
				self:select_index(1, item.id)
			end
			self:activate_menu(item.id)
			self:tween(self.offset_x + menu.width / 2, 0, function(offset) self:set_offset_x(offset) end)
			self.opacity = 1 -- in case tween above canceled fade in animation
		else
			local actions = item.actions or menu.item_actions
			local action = actions and actions[menu.action_index]
			self.callback({
				type = 'activate',
				index = menu.selected_index,
				value = item.value,
				is_pointer = is_pointer == true,
				action = action and action.name,
				keep_open = item.keep_open or menu.keep_open,
				modifiers = shortcut and shortcut.modifiers or nil,
				alt = shortcut and shortcut.alt or false,
				ctrl = shortcut and shortcut.ctrl or false,
				shift = shortcut and shortcut.shift or false,
				menu_id = menu.id,
			})
		end
	end
end

---@param index integer
function Menu:move_selected_item_to(index)
	if self.current.search then return end -- Moving filtered items is an undefined behavior
	local callback = self.current.on_move
	local from, items_count = self.current.selected_index, self.current.items and #self.current.items or 0
	if callback and from and from ~= index and index >= 1 and index <= items_count then
		local event = {type = 'move', from_index = from, to_index = index, menu_id = self.current.id}
		self:command_or_event(callback, {from, index, self.current.id}, event)
		self:select_index(index, self.current.id)
		self:scroll_to_index(index, self.current.id, true)
	end
end

---@param delta number
function Menu:move_selected_item_by(delta)
	local current_index, items_count = self.current.selected_index, self.current.items and #self.current.items or 0
	if current_index and items_count > 1 then
		local new_index = clamp(1, current_index + delta, items_count)
		if current_index ~= new_index then
			self:move_selected_item_to(new_index)
		end
	end
end

function Menu:on_display() self:update_dimensions() end
function Menu:on_prop_fullormaxed() self:update_content_dimensions() end
function Menu:on_options() self:update_content_dimensions() end

function Menu:handle_cursor_down()
	if self.proximity_raw <= 0 then
		self.drag_last_y = cursor.y
		self.current.fling = nil
	else
		self:close()
	end
end

---@param shortcut? Shortcut
function Menu:handle_cursor_up(shortcut)
	if self.proximity_raw <= -self.padding and self.drag_last_y and not self.is_dragging then
		self:activate_pointer_item(shortcut)
	end
	if self.is_dragging then
		local distance = cursor:get_velocity().y / -3
		if math.abs(distance) > 50 then
			self.current.fling = {
				y = self.current.scroll_y,
				distance = distance,
				time = cursor.history:head().time,
				easing = ease_out_quart,
				duration = 0.5,
				update_cursor = true,
			}
			request_render()
		end
	end
	self.is_dragging = false
	self.drag_last_y = nil
end

---@param shortcut? Shortcut
---@param target_menu? MenuStack
---@param target_index? integer
function Menu:activate_pointer_item(shortcut, target_menu, target_index)
	local menu = target_menu or self.pointer_menu or self.current
	local index = target_index or self.pointer_index or menu.selected_index
	local item = index and menu.items[index]
	if not item then return end

	-- Pointer navigation uses cascading panels. Hovering a submenu is enough to open it;
	-- clicking the parent must not replace and recenter the current panel.
	if item.items then return end

	local actions = item.actions or menu.item_actions
	local action = actions and menu.action_index and actions[menu.action_index]
	self.callback({
		type = 'activate',
		index = index,
		value = item.value,
		is_pointer = true,
		action = action and action.name,
		keep_open = item.keep_open or menu.keep_open,
		modifiers = shortcut and shortcut.modifiers or nil,
		alt = shortcut and shortcut.alt or false,
		ctrl = shortcut and shortcut.ctrl or false,
		shift = shortcut and shortcut.shift or false,
		menu_id = menu.id,
	})
end

function Menu:on_global_mouse_move()
	self.mouse_nav = true
	-- A real pointer move is the signal that hover selection may resume after a
	-- wheel fling. Until then, keep the row that opened the cascade stable.
	for _, menu in ipairs(self.all) do menu.hover_suppressed_until = 0 end
	if self.drag_last_y then
		self.is_dragging = self.is_dragging or math.abs(cursor.y - self.drag_last_y) >= 10
		if self.is_dragging then
			self:show_scrollbar()
			local distance = self.drag_last_y - cursor.y
			if distance ~= 0 then self:set_scroll_by(distance) end
			self.drag_last_y = cursor.y
		end
	end
	request_render()
end

---@param menu_id? string
function Menu:show_scrollbar(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or menu.scroll_height <= 0 then return end
	menu.scrollbar_visible_until = mp.get_time() + 0.8
	self.scrollbar_hide_timer:kill()
	self.scrollbar_hide_timer:resume()
	request_render()
end

---@param menu_id? string
function Menu:handle_wheel_up(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or menu.scroll_height <= 0 then return end
	self:show_scrollbar(menu_id)
	menu.hover_suppressed_until = mp.get_time() + wheel_hover_suppression
	self:scroll_by(self.scroll_step * -wheel_scroll_rows, menu_id, {
		update_cursor = true,
		duration = wheel_scroll_duration,
		easing = ease_out_quart,
	})
end
---@param menu_id? string
function Menu:handle_wheel_down(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or menu.scroll_height <= 0 then return end
	self:show_scrollbar(menu_id)
	menu.hover_suppressed_until = mp.get_time() + wheel_hover_suppression
	self:scroll_by(self.scroll_step * wheel_scroll_rows, menu_id, {
		update_cursor = true,
		duration = wheel_scroll_duration,
		easing = ease_out_quart,
	})
end

---@param offset integer
---@param menu? MenuStack
function Menu:select_by_offset(offset, menu)
	menu = menu or self.current

	-- Blur selected_index when navigating off bounds and submittable search is active.
	-- Blurred selected_index is an implied focused input, so enter can submit it.
	if menu.search and menu.search_debounce == 'submit' and (
			(menu.selected_index == 1 and offset < 0) or (menu.selected_index == #menu.items and offset > 0)
		) then
		self:select_index(nil, menu.id)
	else
		local index = clamp(1, (menu.selected_index or offset >= 0 and 0 or #menu.items + 1) + offset, #menu.items)
		local prev_index = itable_find(menu.items, function(item) return item.selectable ~= false end, index, 1)
		local next_index = itable_find(menu.items, function(item) return item.selectable ~= false end, index)
		if prev_index and next_index then
			if offset == 0 then
				self:select_index(index - prev_index <= next_index - index and prev_index or next_index, menu.id)
			elseif offset > 0 then
				self:select_index(next_index, menu.id)
			else
				self:select_index(prev_index, menu.id)
			end
		else
			self:select_index(prev_index or next_index or nil, menu.id)
		end
	end

	request_render()
end

---@param offset integer
---@param immediate? boolean
function Menu:navigate_by_items(offset, immediate)
	self:select_by_offset(offset)
	if self.current.selected_index then
		self:scroll_to_index(self.current.selected_index, self.current.id, immediate)
	end
end

---@param offset integer
---@param immediate? boolean
function Menu:navigate_by_page(offset, immediate)
	local items_per_page = round((self.current.height / self.scroll_step) * 0.4)
	self:navigate_by_items(items_per_page * offset, immediate)
end

function Menu:paste()
	local menu = self.current
	local payload = get_clipboard()
	if not payload then return end
	if menu.search then
		self:search_query_insert(payload)
	elseif menu.on_paste then
		local selected_item = menu.items and menu.selected_index and menu.items[menu.selected_index]
		local actions = selected_item and selected_item.actions or menu.item_actions
		local selected_action = actions and menu.action_index and actions[menu.action_index]
		self:command_or_event(menu.on_paste, {payload, menu.id}, {
			type = 'paste',
			value = payload,
			menu_id = menu.id,
			selected_item = selected_item and {
				index = menu.selected_index, value = selected_item.value, action = selected_action,
			},
		})
	elseif menu.search_style ~= 'disabled' then
		self:search_start(menu.id)
		self:search_query_replace(payload, menu.id)
	end
end

---@param menu_id string
---@param no_select_first? boolean
function Menu:search_internal(menu_id, no_select_first)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local query = menu.search.query:lower()
	if query == '' then
		-- Reset menu state to what it was before search
		for key, value in pairs(menu.search.source) do menu[key] = value end
	else
		-- Inherit `search_submenus` from parent menus
		local search_submenus, parent_menu = menu.search_submenus, menu.parent_menu
		while not search_submenus and parent_menu do
			search_submenus, parent_menu = parent_menu.search_submenus, parent_menu.parent_menu
		end
		menu.items = search_items(menu.search.source.items, query, search_submenus)
		-- Select 1st item in search results
		if not no_select_first then
			menu.scroll_y = 0
			self:select_index(1, menu_id)
		end
	end
	self:update_content_dimensions()
end

---@param items MenuStackChild[]
---@param query string
---@param recursive? boolean
---@param prefix? string
---@return MenuStackChild[]
function search_items(items, query, recursive, prefix)
	local result = {}
	local haystacks = {}
	local flat_items = {}
	local concat = table.concat
	local romanization = need_romanization()

	for _, item in ipairs(items) do
		if item.selectable ~= false then
			local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title
			haystacks[#haystacks + 1] = item.title
			flat_items[#flat_items + 1] = item

			if item.items and recursive then
				itable_append(result, search_items(item.items, query, recursive, prefixed_title))
			end
		end
	end

	local seen = {}

	local fuzzy = fzy.filter(query, haystacks, false)
	for _, match in ipairs(fuzzy) do
		local idx, positions, score = match[1], match[2], match[3]
		local matched_title = haystacks[idx]
		local item = flat_items[idx]
		local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title

		if item.selectable ~= false and not (item.items and recursive) and not seen[item] then
			local exact_hint = item.search_exact_hint and item.hint
				and item.hint:lower() == query
			local bold = item.bold or options.font_bold
			local font_color = item.active and fgt or bgt
			local ass_safe_title = highlight_match(matched_title, positions, font_color, bold) or nil
			local new_item = table_assign({}, item)
			new_item.title = prefixed_title
			new_item.ass_safe_title = prefix and prefix .. ' / ' .. (ass_safe_title or '') or ass_safe_title
			new_item.score = exact_hint and 1000000 or score
			result[#result + 1] = new_item
			seen[item] = true
		end
	end

	for _, item in ipairs(items) do
		local title = item.title and item.title:lower()
		local hint = item.hint and item.hint:lower()
		local bold = item.bold or options.font_bold
		local font_color = item.active and fgt or bgt
		local ass_safe_title = nil
		local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title
		if item.selectable ~= false and not (item.items and recursive) and not seen[item] then
			local score = 0
			local match = false

			if title and romanization then
				local ligature_conv_title, ligature_roman = char_conv(title, true)
				local initials_arr_conv, initials_roman = char_conv(title, false)
				local initials_conv_title = concat(initials(initials_arr_conv))
				if ligature_conv_title:find(query, 1, true) then
					match = true
					score = 1000
					local pos = get_roman_match_positions(title, query, 'ligature', ligature_roman)
					if pos then
						ass_safe_title = highlight_match(item.title, pos, font_color, bold)
					end
				elseif initials_conv_title:find(query, 1, true) then
					match = true
					score = 900
					local pos = get_roman_match_positions(title, query, 'initial', initials_roman)
					if pos then
						ass_safe_title = highlight_match(item.title, pos, font_color, bold)
					end
				end
			end

			if hint and not match then
				if item.search_exact_hint and hint == query then
					match = true
					score = 1000000
				elseif hint:find(query, 1, true) then
					match = true
					score = 100
				elseif concat(initials(hint)):find(query, 1, true) then
					match = true
					score = 90
				end
			end

			if match then
				local new_item = table_assign({}, item)
				new_item.title = prefixed_title
				new_item.ass_safe_title = prefix and prefix .. ' / ' .. (ass_safe_title or '') or ass_safe_title
				new_item.score = score
				result[#result + 1] = new_item
			end
		end
	end

	table.sort(result, function(a, b) return a.score > b.score end)

	return result
end

---@param menu_id? string
function Menu:search_submit(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	local callback, query = menu.on_search, menu.search.query
	if callback then
		self:command_or_event(callback, {query, menu.id}, {type = 'search', query = query, menu_id = menu.id})
	else
		self:search_internal(menu.id)
	end
end

-- Move search query cursor by an amount.
---@param amount number `<0` for left, `>0` for right.
---@param word_mode? boolean Move by words/segments. Overwrites amount, but respects its direction.
function Menu:search_cursor_move(amount, word_mode)
	local menu = self:get_menu()
	if not menu or not menu.search then return end
	local query, cursor = menu.search.query, menu.search.cursor
	if word_mode then
		menu.search.cursor = find_string_segment_bound(query, cursor, amount) + (amount < 0 and -1 or 0)
	else
		local move = amount > 0 and utf8_next or utf8_prev
		local step_count = 0
		local limit = math.abs(amount)

		while step_count < limit do
			local next_cursor = move(query, cursor)
			if next_cursor == cursor then break end
			cursor = next_cursor
			step_count = step_count + 1
		end

		menu.search.cursor = clamp(0, cursor, #query)
	end
	self:search_cursor_blink_reset()
	request_render()
end

function Menu:search_cursor_blink_reset()
	self.search_cursor_visible = true
	if self.search_cursor_timer then
		self.search_cursor_timer:kill()
		self.search_cursor_timer:resume()
	end
end

---@param query string
---@param menu_id? string
---@param immediate? boolean
function Menu:search_query_replace(query, menu_id, immediate)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	menu.search.query = query
	menu.search.cursor = #query
	self:search_trigger(menu_id, immediate)
end

-- Insert string into search query at cursor.
---@param str string
---@param menu_id? string
function Menu:search_query_insert(str, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	local query, cursor = menu.search.query, menu.search.cursor
	local head, tail = string.sub(query, 1, cursor), string.sub(query, cursor + 1)
	menu.search.query = head .. str .. tail
	menu.search.cursor = cursor + #str
	self:search_trigger(menu_id)
end

-- Trigger menu search callbacks, should be called after any query changes.
function Menu:search_trigger(menu_id, immediate)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	self:search_cursor_blink_reset()
	if menu.search_debounce ~= 'submit' then
		if menu.search.timeout then menu.search.timeout:kill() end
		if menu.search.timeout and not immediate then
			menu.search.timeout:resume()
		else
			self:search_submit(menu_id)
		end
	else
		-- `search_debounce='submit'` behavior: We blur selected item when query
		-- changes to let [enter] key submit searches instead of activating items.
		self:select_index(nil, menu.id)
	end
	request_render()
end

---@param event? string
---@param word_mode? boolean Delete by words.
function Menu:search_query_backspace(event, word_mode)
	local search = self.current.search
	if not search then return end

	local cursor, old_query = search.cursor, search.query
	local head, tail = string.sub(old_query, 1, cursor), string.sub(old_query, cursor + 1)

	if word_mode then
		cursor = find_string_segment_bound(head, cursor, -1) - 1
	elseif cursor > 0 then
		-- The while loop is for skipping utf8 continuation bytes
		while cursor > 1 and old_query:byte(cursor) >= 0x80 and old_query:byte(cursor) <= 0xbf do
			cursor = cursor - 1
		end
		cursor = cursor - 1
	end

	local new_query = head:sub(1, cursor) .. tail
	if new_query ~= old_query then
		search.query = new_query
		search.cursor = math.max(0, cursor)
		self:search_trigger()
	end

	if #new_query == 0 then
		local is_palette = self.current.search_style == 'palette'
		if not is_palette and self.type_to_search then
			self:search_cancel()
		elseif is_palette and event ~= 'repeat' then
			self:back()
		end
	end
end

---@param event? string
---@param word_mode? boolean Delete by words.
function Menu:search_query_delete(event, word_mode)
	local search = self.current.search
	if not search then return end

	local cursor, old_query = search.cursor, search.query
	local head, tail = string.sub(old_query, 1, cursor), string.sub(old_query, cursor + 1)
	local tail_cursor = 1

	if word_mode then
		tail_cursor = find_string_segment_bound(tail, 0, 1) + 1
	else
		-- The while loop is for skipping utf8 continuation bytes
		while tail_cursor < #tail and tail:byte(tail_cursor) >= 0x80 and tail:byte(tail_cursor) <= 0xbf do
			tail_cursor = tail_cursor + 1
		end
		tail_cursor = tail_cursor + 1
	end

	local new_query = head .. tail:sub(tail_cursor)
	if new_query ~= old_query then
		search.query = new_query
		search.cursor = #head
		self:search_trigger()
	end

	if #new_query == 0 then
		local is_palette = self.current.search_style == 'palette'
		if not is_palette and self.type_to_search then
			self:search_cancel()
		elseif is_palette and event ~= 'repeat' then
			self:back()
		end
	end
end

function Menu:search_text_input(info)
	local menu = self.current
	if not menu.search and menu.search_style == 'disabled' then return end
	if info.event ~= 'up' then
		local key_text = info.key_text
		if not key_text then
			-- might be KP0 to KP9 or KP_DEC
			key_text = info.key_name:match('KP_?(.+)')
			if not key_text then return end
			if key_text == 'DEC' then key_text = '.' end
		end
		if not menu.search then self:search_start() end
		self:search_query_insert(key_text)
	end
end

---@param menu_id? string
function Menu:search_cancel(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search or menu.search_style == 'palette' then
		self:search_query_replace('', menu_id)
		return
	end
	if state.ime_active == false then
		mp.set_property_bool('input-ime', false)
	end
	self:search_query_replace('', menu_id, true)
	menu.search = nil
	self:search_ensure_key_bindings()
	self:update_dimensions()
	self:reset_navigation()
end

---@param menu_id? string
function Menu:search_init(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if menu.search then return end
	if state.ime_active == false then
		mp.set_property_bool('input-ime', true)
	end
	local timeout
	if menu.search_debounce ~= 'submit' and menu.search_debounce > 0 then
		timeout = mp.add_timeout(menu.search_debounce / 1000, self:create_action(function()
			self:search_submit(menu.id)
		end))
		timeout:kill()
	end
	menu.search = {
		query = '',
		cursor = 0,
		timeout = timeout,
		min_top = menu.top,
		max_width = menu.width,
		source = {
			width = menu.width,
			top = menu.top,
			scroll_y = menu.scroll_y,
			selected_index = menu.selected_index,
			items = not menu.on_search and menu.items or nil,
		},
	}
	self:search_cursor_blink_reset()
end

---@param menu_id? string
function Menu:search_start(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or menu.search_style == 'disabled' then return end
	self:search_init(menu_id)
	self:search_ensure_key_bindings()
	self:update_dimensions()
end

---@param menu_id? string
function Menu:search_clear_query(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if not self.current.search_style == 'palette' and self.type_to_search then
		self:search_cancel(menu_id)
	else
		self:search_query_replace('', menu_id)
	end
end

function Menu:search_enable_key_bindings()
	if self:has_keybindings('search') then return end
	local flags = {repeatable = true, complex = true}
	self:add_key_binding('any_unicode', {self:create_key_handler('search_text_input'), flags}, 'search')
	-- KP0 to KP9 and KP_DEC are not included in any_unicode
	-- despite typically producing characters, they don't have a info.key_text
	self:add_key_binding('kp_dec', {self:create_key_handler('search_text_input'), flags}, 'search')
	for i = 0, 9 do
		self:add_key_binding('kp' .. i, {self:create_key_handler('search_text_input'), flags}, 'search')
	end
end

function Menu:search_ensure_key_bindings()
	if self.current.search or (self.type_to_search and self.current.search_style ~= 'disabled') then
		self:search_enable_key_bindings()
	else
		self:remove_key_bindings('search')
	end
end

function Menu:enable_key_bindings()
	local standalone_keys = {'/', 'kp_divide', 'mbtn_back', 'ctrl+f', 'ctrl+v', 'ctrl+c'}
	if type(self.root.bind_keys) == 'table' then itable_append(standalone_keys, self.root.bind_keys) end
	-- `+` at the end enables `repeatable` flag
	local modifiable_keys = {'up+', 'down+', 'left', 'right', 'enter', 'kp_enter', 'bs', 'tab', 'esc', 'pgup+',
		'pgdwn+', 'home', 'end', 'del'}
	local modifiers = {nil, 'alt', 'alt+ctrl', 'alt+shift', 'alt+ctrl+shift', 'ctrl', 'ctrl+shift', 'shift'}

	---@param shortcut Shortcut
	---@param flags table<string, boolean>
	local function bind(shortcut, flags)
		local handler = self:create_action(function(info) self:handle_shortcut(shortcut, info) end)
		self:add_key_binding(shortcut.id, {handler, flags})
	end

	for i, key in ipairs(standalone_keys) do
		bind(create_shortcut(key), {repeatable = false, complex = true})
	end

	for i, key in ipairs(modifiable_keys) do
		local flags = {repeatable = false, complex = true}

		if key:sub(-1) == '+' then
			key = key:sub(1, -2)
			flags.repeatable = true
		end

		for j = 1, #modifiers do
			bind(create_shortcut(key, modifiers[j]), flags)
		end
	end

	self:search_ensure_key_bindings()
end

-- Handles all key and mouse button shortcuts, except unicode inputs.
---@param shortcut Shortcut
---@param info ComplexBindingInfo
function Menu:handle_shortcut(shortcut, info)
	if not self:is_alive() then return end

	self.mouse_nav = info.is_mouse
	local menu, id, key, modifiers = self.current, shortcut.id, shortcut.key, shortcut.modifiers
	local selected_index = menu.selected_index
	local selected_item = menu and selected_index and menu.items[selected_index]
	local is_submenu = selected_item and selected_item.items ~= nil
	local actions = selected_item and selected_item.actions or menu.item_actions
	local selected_action = actions and menu.action_index and actions[menu.action_index]

	if info.event == 'up' then return end

	function trigger_shortcut(shortcut)
		self.callback(table_assign({}, shortcut, {
			type = 'key',
			menu_id = menu.id,
			selected_item = selected_item and {
				index = selected_index, value = selected_item.value, action = selected_action,
			},
		}))
	end

	if (key == 'enter' and selected_item) or (id == 'right' and is_submenu and not menu.search) then
		self:activate_selected_item(shortcut)
	elseif id == 'enter' and menu.search and menu.search_debounce == 'submit' then
		self:search_submit()
	elseif id == 'up' or id == 'down' then
		self:navigate_by_items(id == 'up' and -1 or 1, true)
	elseif id == 'pgup' or id == 'pgdwn' then
		self:navigate_by_page(id == 'pgup' and -1 or 1)
	elseif menu.search and (id == 'left' or id == 'ctrl+left') then
		self:search_cursor_move(-1, modifiers == 'ctrl')
	elseif menu.search and (id == 'right' or id == 'ctrl+right') then
		self:search_cursor_move(1, modifiers == 'ctrl')
	elseif menu.search and id == 'home' then
		self:search_cursor_move(-math.huge)
	elseif menu.search and id == 'end' then
		self:search_cursor_move(math.huge)
	elseif id == 'home' or id == 'end' then
		self:navigate_by_items(id == 'home' and -math.huge or math.huge)
	elseif id == 'shift+tab' then
		self:prev_action()
	elseif id == 'tab' then
		self:next_action()
	elseif id == 'ctrl+up' then
		self:move_selected_item_by(-1)
	elseif id == 'ctrl+down' then
		self:move_selected_item_by(1)
	elseif id == 'ctrl+pgup' then
		self:move_selected_item_by(-round((menu.height / self.scroll_step) * 0.4))
	elseif id == 'ctrl+pgdwn' then
		self:move_selected_item_by(round((menu.height / self.scroll_step) * 0.4))
	elseif id == 'ctrl+home' then
		self:move_selected_item_by(-math.huge)
	elseif id == 'ctrl+end' then
		self:move_selected_item_by(math.huge)
	elseif id == '/' or id == 'kp_divide' or id == 'ctrl+f' then
		self:search_start()
	elseif key == 'esc' then
		if menu.back_on_escape then
			self.callback({type = 'back'})
		elseif menu.search and menu.search_style ~= 'palette' then
			self:search_cancel()
		else
			self:close()
		end
	elseif id == 'left' and menu.parent_menu then
		self:back()
	elseif key == 'bs' then
		if menu.search then
			if modifiers == 'shift' then
				self:search_clear_query()
			elseif not modifiers or modifiers == 'ctrl' then
				self:search_query_backspace(info.event, modifiers == 'ctrl')
			end
		elseif not modifiers and info.event ~= 'repeat' then
			self:back()
		end
	elseif menu.search and (id == 'del' or id == 'ctrl+del' or id == 'shift+del') then
		if id == 'shift+del' then
			-- During search `del` edits the string. We convert `shift+del` to
			-- `del` to have a way to trigger menu callbacks bound to `del`.
			trigger_shortcut(create_shortcut('del'))
		else
			self:search_query_delete(info.event, modifiers == 'ctrl')
		end
	elseif key == 'mbtn_back' then
		self:back()
	elseif id == 'ctrl+v' then
		self:paste()
	else
		trigger_shortcut(shortcut)
	end
end

-- Check if menu is not closed or closing.
function Menu:is_alive() return not self.is_closing and not self.destroyed end

---@param name string
function Menu:create_key_handler(name)
	return self:create_action(function(...)
		self.mouse_nav = false
		self:maybe(name, ...)
	end)
end

-- Sends command with params, or triggers a callback event if `command == 'callback'`.
-- Intended to handle `on_{event}: 'callback' | string | string[]` events.
-- Returns what happened.
---@param command string|number|string[]|number[]
---@param params string[]|number[]
---@param event MenuEvent
---@return 'event' | 'command' | nil
function Menu:command_or_event(command, params, event)
	if command == 'callback' then
		self.callback(event)
		return 'event'
	elseif type(command) == 'table' then
		---@diagnostic disable-next-line: deprecated
		mp.command_native(itable_join(command, params))
		return 'command'
	elseif type(command) == 'string' then
		mp.command(command .. ' ' .. table.concat(params, ' '))
		return 'command'
	end
	return nil
end

function Menu:render()
	self.pointer_menu = nil
	self.pointer_index = nil

	for _, menu in ipairs(self.all) do
		if menu.fling then
			local time_delta = state.render_last_time - menu.fling.time
			local progress = menu.fling.easing(math.min(time_delta / menu.fling.duration, 1))
			self:set_scroll_to(round(menu.fling.y + menu.fling.distance * progress), menu.id)
			if progress < 1 then request_render() else menu.fling = nil end
		end
	end

	local function bind_zone(event, hitbox, callback)
		if not self.is_closing then cursor:zone(event, hitbox, callback) end
	end
	bind_zone('primary_down', display, self:create_action(function() self:handle_cursor_down() end))
	bind_zone('primary_up', display, self:create_action(function(shortcut) self:handle_cursor_up(shortcut) end))

	local ass = assdraw.ass_new()
	local now = mp.get_time()
	local icon_size = self.font_size
	local menu_bg = config.color.menu_background or bg
	local menu_fg = config.color.menu_foreground or fg
	local menu_text = config.color.menu_text or bgt
	local menu_selection = config.color.menu_selection or fg
	local menu_active = config.color.menu_active or config.color.match
	local menu_title = config.color.menu_title or fg
	local menu_title_text = config.color.menu_title_text or bg

	---@param menu MenuStack
	---@param x number
	---@param pos number Horizontal position index. 0 = current menu, <0 parent menus, >1 submenu.
	local function draw_menu(menu, x, pos)
		local is_current, is_parent, is_submenu = pos == 0, pos < 0, pos > 0
		local menu_opacity = (pos == 0 and 1 or config.opacity.submenu ^ math.abs(pos)) * self.opacity
		-- Scrollable content area coordinates
		local content_rect = {
			ax = x + self.padding,
			ay = menu.top,
			bx = x + self.padding + menu.width,
			by = menu.top + menu.height,
		}
		local content_padding_bottom = round((menu.content_padding_bottom or 0) * state.scale)
		-- local ax, ay, bx, by = x + self.padding, menu.top, x + menu.width + self.padding, menu.top + menu.height
		local draw_title = menu.is_root and menu.title or menu.search
		local scroll_clip = '\\clip(0,' .. content_rect.ay .. ',' .. display.width .. ',' .. content_rect.by .. ')'
		local start_index = math.floor(menu.scroll_y / self.scroll_step) + 1
		local end_index = math.ceil((menu.scroll_y + menu.height) / self.scroll_step)
		local bg_rect = {
			ax = x,
			ay = content_rect.ay - (draw_title and self.scroll_step or 0) - self.padding,
			bx = content_rect.bx + self.padding,
			by = content_rect.by + self.padding,
		}
		-- Every visible cascade level owns its selection independently. This
		-- allows pointer retreat to collapse one level at a time (3 -> 2 -> 1)
		-- instead of a descendant loss clearing the whole chain at once.
		local hover_frozen = self.mouse_nav and (
			(menu.fling and menu.fling.update_cursor)
			or now < (menu.hover_suppressed_until or 0)
			or (self.is_dragging and menu == self.current)
		)
		local blur_selected_index = self.mouse_nav and (is_current or is_submenu) and not hover_frozen
		local blur_action_index = self.mouse_nav and menu.action_index ~= nil
		local item_title_font_size = self.font_size
		local uniform_title_size = uses_uniform_title_size(menu)
		local fixed_columns = uses_fixed_columns(menu)

		-- A narrow menu with only short command labels looks oversized when it
		-- inherits the full result-list font. Reduce only these compact panels;
		-- playlists, tracks and search results keep their readable shared size.
		local logical_menu_width = menu.width / math.max(state.scale, 0.01)
		local narrow_file_fit_policy = is_file_navigation_menu(menu)
			and logical_menu_width < 700
			and {
				fit_ratio = 0.86,
				ellipsis_ratio = 0.85,
				force_ellipsis_when_scaled = true,
			}
			or nil
		-- Recent-history rows have a fixed right metadata column.  Use the
		-- measured space up to that column instead of applying the generic
		-- conservative ellipsis reserve a second time.
		local title_fit_policy = menu.type == 'recent_menu'
			and {fit_ratio = 0.98, ellipsis_ratio = 0.92, force_ellipsis_at_floor = true}
			or narrow_file_fit_policy
		if not uniform_title_size and logical_menu_width < 420 then
			item_title_font_size = round(self.font_size * 0.90)
		end

		if uniform_title_size then
			-- Search/result menus should stay comfortably readable. Once a
			-- shared size reaches this floor, exceptionally long titles are
			-- ellipsized instead of shrinking every row to a tiny font.
			-- Playlists use a slightly lower floor than search results, but
			-- still prioritize readability over showing every character of
			-- an exceptionally long file name.
			local logical_width = display.width / math.max(state.scale, 0.01)
			-- Recent history often contains one exceptionally long ISO or release
			-- name. Keep the whole list at the normal readable size and ellipsize
			-- that title instead of shrinking every row to match it.
			local recent_font_ratio = 1
			local search_result_ratio = menu.search and menu.uniform_title_size and 0.92
				or menu.uniform_title_size and 0.84
			local min_font_ratio = menu.type == 'recent_menu' and recent_font_ratio
				or search_result_ratio or 0.82
			local min_font_size = math.max(round(8 * state.scale), round(self.font_size * min_font_ratio))
			local base_content_width = math.max(0, menu.width - self.item_padding * 2)

			-- Selected menu groups can share one size derived from their most
			-- constrained title. This avoids a visibly uneven mix of large and
			-- small labels while keeping the size stable as the list scrolls.
			for _, item in ipairs(menu.items) do
				if item.title then
					local available_width = base_content_width
						- (item.icon and icon_size + self.item_padding or 0)
					if item.hint_width > 0 then
						local width_before_hint = available_width - self.item_padding
						local hint_width = fixed_columns and menu.max_hint_width or item.hint_width
						local hint_reserve = math.min(
							width_before_hint * 0.58,
							hint_width + self.item_padding * 1.5
						)
						available_width = width_before_hint - hint_reserve
					end

					local fitted_size = fit_text_to_width(
						item.title,
						math.max(0, available_width - round(2 * state.scale)),
						self.font_size,
						min_font_size,
						{
							font = self.font,
							italic = item.italic,
							bold = item.bold == true or item.active,
						},
						title_fit_policy
					)
					item_title_font_size = math.min(item_title_font_size, fitted_size)
				end
			end
		end

		-- Background
		ass:rect(bg_rect.ax, bg_rect.ay, bg_rect.bx, bg_rect.by, {
			color = menu_bg,
			opacity = menu_opacity * config.opacity.menu,
			radius = state.radius > 0 and math.min(state.radius + self.padding, state.radius * 3) or 0,
		})
		-- Every visible cascade panel owns its wheel input. The recursive submenus
		-- are not `self.current`, so binding only the element rectangle either
		-- missed their wheel events or scrolled the root panel.
		local target_menu_id = menu.id
		bind_zone('wheel_down', bg_rect, self:create_action(function()
			self:handle_wheel_down(target_menu_id)
		end))
		bind_zone('wheel_up', bg_rect, self:create_action(function()
			self:handle_wheel_up(target_menu_id)
		end))

		if is_parent then
			bind_zone('primary_down', bg_rect, self:create_action(function() self:slide_in_menu(menu.id, x) end))
		end

		-- Scrollbar: reveal only while scrolling/dragging or when the pointer
		-- deliberately approaches the panel's right edge.
		local scrollbar_hover_rect = {
			ax = content_rect.bx - round(14 * state.scale),
			ay = content_rect.ay,
			bx = bg_rect.bx,
			by = content_rect.by,
		}
		local show_scrollbar = self.is_dragging or menu.fling
			or now < (menu.scrollbar_visible_until or 0)
			or get_point_to_rectangle_proximity(cursor, scrollbar_hover_rect) <= 0
		if menu.scroll_height > 0 and show_scrollbar then
			local groove_height = menu.height - 2
			local thumb_height = math.max((menu.height / (menu.scroll_height + menu.height)) * groove_height, 40)
			local thumb_y = content_rect.ay + 1 + ((menu.scroll_y / menu.scroll_height) * (groove_height - thumb_height))
			local sax = content_rect.bx - round(self.scrollbar_size / 2)
			local sbx = sax + self.scrollbar_size
			ass:rect(sax, thumb_y, sbx, thumb_y + thumb_height, {
				color = config.color.match, opacity = menu_opacity * 0.8,
			})
		end

		-- Draw submenu if selected
		local submenu_rect, current_item = nil,
			not hover_frozen and (is_current or is_submenu)
			and menu.selected_index and menu.items[menu.selected_index]
		local submenu_is_hovered = false
		if current_item and current_item.items then
			-- Align cascading submenu with the hovered parent item instead of centering it independently.
			local parent_item_ay = content_rect.ay - menu.scroll_y
				+ self.scroll_step * (menu.selected_index - 1)
			local original_top = current_item.top
			-- Keep cascades clear of the viewport edge. A padding-only margin is
			-- effectively invisible with compact themes and makes the last row look
			-- clipped even when it technically fits by a few pixels.
			local edge_margin = math.max(self.padding * 2, round(self.item_height / 2))
			local min_top = edge_margin
			local max_top = math.max(
				min_top,
				display.height - current_item.height - self.padding - edge_margin
			)
			current_item.top = clamp(min_top, parent_item_ay + self.padding, max_top)
			local submenu_x = bg_rect.bx + self.gap
			submenu_rect = draw_menu(current_item --[[@as MenuStack]], submenu_x, 1)
			submenu_is_hovered = get_point_to_rectangle_proximity(cursor, submenu_rect) <= 0
			current_item.top = original_top
		end

		---@type MenuAction|nil
		local selected_action
		for index = start_index, end_index, 1 do
			local item = menu.items[index]

			if not item then break end

			local item_ay = content_rect.ay - menu.scroll_y + self.scroll_step * (index - 1)
			local item_by = item_ay + self.item_height
			local item_text_clip_by = math.min(
				item_by + (index == #menu.items and content_padding_bottom or 0),
				content_rect.by
			)
			local item_center_y = item_ay + (self.item_height / 2)
			local item_clip = (item_ay < content_rect.ay or item_by > content_rect.by) and scroll_clip or nil
			local content_ax, content_bx = content_rect.ax + self.item_padding,
				content_rect.bx - self.item_padding
			local is_selected = menu.selected_index == index
			local item_rect_hitbox = {
				ax = content_rect.ax,
				ay = math.max(item_ay, bg_rect.ay),
				bx = bg_rect.bx + (item.items and self.gap or -self.padding), -- to bridge the submenu gap with cursor
				by = math.min(item_ay + self.scroll_step, bg_rect.by),
			}

			local has_background = is_selected or item.active
			local next_item = menu.items[index + 1]
			local next_is_active = next_item and next_item.active
			local next_has_background = menu.selected_index == index + 1 or next_is_active
			-- Active/current rows should remain the clearest item in lists.
			-- `menu_title_text` is reserved for the pale title bar.
			local font_color = menu_text
			local actions = is_selected and (item.actions or menu.item_actions) -- not nil = actions are visible
			local action = actions and actions[menu.action_index] -- not nil = action is selected

			if action then selected_action = action end

			-- Separator
			if not item.hide_separator and item_by < content_rect.by and ((not has_background and not next_has_background) or item.separator) then
				local ay, by = item_by, item_by + self.separator_size
				if has_background then
					ay, by = ay + self.separator_size, by + self.separator_size
				elseif next_has_background then
					ay, by = ay - self.separator_size, by - self.separator_size
				end
				ass:rect(
					content_rect.ax + self.item_padding, ay, content_rect.bx - self.item_padding, by,
					{color = menu_fg, opacity = menu_opacity * (item.separator and 0.16 or 0.055)}
				)
			end

			-- Background
			local highlight_opacity = item.active and (is_selected and 0.62 or 0.52)
				or (is_selected and 0.34 or 0)
			if highlight_opacity > 0 then
				ass:rect(content_rect.ax, item_ay, content_rect.bx, item_by, {
					radius = state.radius,
					color = item.active and menu_active or menu_selection,
					opacity = highlight_opacity * menu_opacity,
					clip = item_clip,
				})
			end

			local title_clip_bx = content_bx

			-- Actions
			local actions_rect
			if is_selected and actions and #actions > 0 and not item.items then
				local place = item.actions_place or menu.item_actions_place
				local margin = self.gap * 2
				local size = item_by - item_ay - margin * 2
				local rect_width = size * #actions + margin * (#actions - 1)

				-- Place actions outside of menu when requested and there's enough space for it
				actions_rect = {
					ay = item_ay + margin,
					by = item_by - margin,
					is_outside = place == 'outside' and display.width - bg_rect.bx + margin * 2 > rect_width,
				}
				actions_rect.bx = actions_rect.is_outside and bg_rect.bx + margin + rect_width or
					content_rect.bx - margin
				actions_rect.ax = actions_rect.bx

				for i = 1, #actions, 1 do
					local action_index = #actions - (i - 1)
					local action = actions[action_index]

					-- Hide when the action shouldn't be displayed when the item is a result of a search/filter
					if not (action.filter_hidden and menu.search) then
						local is_active = action_index == menu.action_index
						local bx = actions_rect.ax - (i == 1 and 0 or margin)
						local rect = {
							ay = actions_rect.ay,
							by = actions_rect.by,
							ax = bx - size,
							bx = bx,
						}
						actions_rect.ax = rect.ax

						ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
							radius = state.radius > 2 and state.radius - 1 or state.radius,
							color = is_active and fg or bg,
							border = is_active and self.gap or nil,
							border_color = bg,
							opacity = menu_opacity,
							clip = item_clip,
						})
						ass:icon(rect.ax + size / 2, rect.ay + size / 2, size * 0.66, action.icon, {
							color = is_active and bg or fg, opacity = menu_opacity, clip = item_clip,
						})

						-- Re-use rect as a hitbox by growing it so it bridges gaps to prevent flickering
						rect.ay, rect.by, rect.bx = item_ay, item_ay + self.scroll_step, rect.bx + margin

						-- Select action on cursor hover
						if self.mouse_nav and get_point_to_rectangle_proximity(cursor, rect) <= 0 then
							bind_zone('primary_down', rect, self:create_action(function(shortcut)
								self:activate_selected_item(shortcut, true)
							end))
							blur_action_index = false
							if not is_active then
								menu.action_index = action_index
								selected_action = actions[action_index]
								request_render()
							end
						end
					end
				end

				title_clip_bx = actions_rect.ax - self.gap * 2
			end

			-- Selected item indicator line
			if is_selected and not selected_action then
				local size = round(2 * state.scale)
				local v_padding = math.min(state.radius, math.ceil(self.item_height / 3))
				ass:rect(
					content_rect.ax - size - 1, item_ay + v_padding,
					content_rect.ax - 1, item_by - v_padding,
					{radius = 1 * state.scale, color = fg, opacity = menu_opacity, clip = item_clip}
				)
			end

			-- Icon
			if item.icon then
				if not actions_rect or actions_rect.is_outside then
					local x = (not item.title and not item.hint and item.align == 'center')
						and bg_rect.ax + (bg_rect.bx - bg_rect.ax) / 2
						or content_bx - (icon_size / 2)
					if item.icon == 'spinner' then
						ass:spinner(x, item_center_y, icon_size * 1.5, {color = font_color, opacity = menu_opacity * 0.8})
					else
						ass:icon(x, item_center_y, icon_size * 1.5, item.icon, {
							color = font_color, opacity = menu_opacity, clip = item_clip,
						})
					end
				end
				content_bx = content_bx - icon_size - self.item_padding
				title_clip_bx = math.min(content_bx, title_clip_bx)
			end

			local hint_clip_bx = title_clip_bx
			if item.hint_width > 0 then
				-- Keep the right-side metadata fully readable. Proportional font
				-- metrics can render a few pixels wider than text_width reports,
				-- so reserve an extra padding buffer and clip the title earlier.
				local width = content_bx - content_ax - self.item_padding
				local hint_width = fixed_columns and menu.max_hint_width or item.hint_width
				local hint_reserve = math.min(width * 0.58, hint_width + self.item_padding * 1.5)
				local title_width = width - hint_reserve
				title_clip_bx = math.min(
					title_clip_bx,
					round(content_ax + math.max(0, title_width))
				)
			end

			-- Hint
			if item.hint then
				item.ass_safe_hint = item.ass_safe_hint or ass_escape(item.hint)
				local hint_font_size = uniform_title_size and item_title_font_size
					or self.font_size_hint
				local fitted_hint_size, fitted_hint = fit_text_to_width(
					item.hint,
					math.max(0, hint_clip_bx - title_clip_bx - round(2 * state.scale)),
					hint_font_size,
					uniform_title_size and hint_font_size
						or math.max(round(8 * state.scale), round(self.font_size_hint * 0.82)),
					{font = self.font}
				)
				local clip = '\\clip(' .. title_clip_bx .. ','
					.. math.max(item_ay, content_rect.ay) .. ',' .. hint_clip_bx .. ','
					.. item_text_clip_by .. ')'
				local is_webdav_placeholder = menu.type == "webdav_shortcut"
					and (item.hint == "127.0.0.1:5244" or item.hint == "未设置")
				ass:txt(content_bx, item_center_y, 6, fitted_hint or item.ass_safe_hint, {
					size = fitted_hint_size,
					font = self.font,
					scale_x = fitted_hint and 94 or nil,
					color = font_color,
					wrap = 2,
					opacity = (item.opacity or item.active and 0.8 or is_selected and 0.72 or 0.62)
						* menu_opacity
						* (is_webdav_placeholder and 0.68 or 1),
					clip = clip,
				})
			end

			-- Title
			if item.title then
				item.ass_safe_title = item.ass_safe_title or ass_escape(item.title)
				local rendered_title = item.ass_safe_title
				-- Fixed-column titles should already end well before this guard.
				-- Keep it only as a final guarantee that metadata can never overlap.
				local clip_bx = title_clip_bx
				local clip = '\\clip(' .. content_rect.ax .. ',' .. math.max(item_ay, content_rect.ay) .. ','
					.. clip_bx .. ',' .. item_text_clip_by .. ')'
				local title_x, align = content_ax, 4
				if item.align == 'right' then
					title_x, align = title_clip_bx, 6
				elseif item.align == 'center' then
					title_x, align = content_ax + (title_clip_bx - content_ax) / 2, 5
				end
				local title_font_size, fitted_title = fit_text_to_width(
					item.title,
					math.max(0, title_clip_bx - content_ax - round(2 * state.scale)),
					item_title_font_size,
					uniform_title_size and item_title_font_size
						or math.max(round(8 * state.scale), round(self.font_size * 0.82)),
					{
						font = self.font,
						italic = item.italic,
						bold = item.bold == true or item.active,
					},
					title_fit_policy
				)
				if fitted_title then rendered_title = fitted_title end
				local title_style = {
					size = title_font_size,
					font = self.font,
					scale_x = fitted_title and 94
						or title_font_size < item_title_font_size and 97 or nil,
					color = font_color,
					italic = item.italic,
					bold = item.bold == true or item.active,
					border = item.active and 0 or 0.28 * state.scale,
					border_color = font_color,
					wrap = 2,
					opacity = menu_opacity * (item.opacity or item.muted and 0.5
						or item.active and 1 or is_selected and 0.94 or 0.82),
					clip = clip,
				}
				ass:txt(title_x, item_center_y, align, rendered_title, title_style)
			end

			-- Select hovered item
			if (is_current or is_submenu) and self.mouse_nav and not hover_frozen and item.selectable ~= false then
				if submenu_is_hovered then
					-- A deeper descendant already owns the pointer. Keep this ancestor
					-- selected, but do not overwrite the deepest clickable target.
					blur_selected_index = false
				elseif submenu_rect and cursor:direction_to_rectangle_distance(submenu_rect)
					or actions_rect and actions_rect.is_outside and cursor:direction_to_rectangle_distance(actions_rect) then
					blur_selected_index = false
				else
					if get_point_to_rectangle_proximity(cursor, item_rect_hitbox) <= 0 then
						blur_selected_index = false
						self.pointer_menu = menu
						self.pointer_index = index
						menu.selected_index = index
						if not is_selected then
							is_selected = true
							request_render()
						end
						if is_current or is_submenu then
							local target_menu, target_index = menu, index
							bind_zone('primary_down', item_rect_hitbox, self:create_action(function(shortcut)
								-- Capture the exact panel and row at render time. Depending on shared
								-- hover state here lets an ancestor steal a deep submenu click.
								self:activate_pointer_item(shortcut, target_menu, target_index)
							end))
						end
					end
				end
			end
		end

		-- Footnote / Selected action label
		if is_current and (menu.footnote or selected_action) then
			local height_half = self.font_size
			local icon_x, icon_y = content_rect.ax + self.font_size / 2, bg_rect.by + height_half
			local is_icon_hovered = false
			local icon_hitbox = {
				ax = icon_x - height_half,
				ay = icon_y - height_half,
				bx = icon_x + height_half,
				by = icon_y + height_half,
			}
			is_icon_hovered = get_point_to_rectangle_proximity(cursor, icon_hitbox) <= 0
			local text = selected_action and selected_action.label or is_icon_hovered and menu.footnote
			local opacity = (is_icon_hovered and 1 or 0.5) * menu_opacity
			ass:icon(icon_x, icon_y, self.font_size, is_icon_hovered and 'help' or 'help_outline', {
				color = fg, border = state.scale, border_color = bg, opacity = opacity,
			})
			if text then
				ass:txt(icon_x + self.font_size * 0.75, icon_y - self.font_size * 0.5, 7, ass_escape(text), {
					size = self.font_size,
					font = self.font,
					color = fg,
					border = state.scale,
					border_color = bg,
					opacity = menu_opacity,
					italic = true,
				})
			end
		end

		-- Menu title
		if draw_title then
			local title_height = self.item_height + self.padding - 3
			local requires_submit = menu.search_debounce == 'submit'
			local rect = {
				ax = content_rect.ax,
				ay = content_rect.ay - self.scroll_step - round(5 * state.scale),
				bx = content_rect.bx,
				by = content_rect.ay - round(5 * state.scale),
			}
			-- Centers
			rect.cx, rect.cy = round(rect.ax + (rect.bx - rect.ax) / 2), round(rect.ay + (rect.by - rect.ay) / 2)
			local search_action_rect
			local search_content_bx = rect.bx
			local search_inner_padding = menu.search and round(10 * state.scale) or 0
			if menu.search and menu.search_action then
				local action_margin = round(5 * state.scale)
				local action_max_size = title_height - action_margin * 2
				local action_size = math.min(
					action_max_size,
					math.max(round(24 * state.scale), round(28 * state.scale))
				)
				local action_center_y = rect.ay + (rect.by - rect.ay) / 2 + round(1.5 * state.scale)
				search_action_rect = {
					ax = rect.bx - action_margin - action_size,
					ay = action_center_y - action_size / 2,
					bx = rect.bx - action_margin,
					by = action_center_y + action_size / 2,
				}
				search_content_bx = search_action_rect.ax - self.gap
			end

			if menu.title and not menu.ass_safe_title then
				menu.ass_safe_title = ass_escape(menu.title)
			end

			-- Background
			if menu.search then
				ass:rect(content_rect.ax + 3, rect.ay + 3, content_rect.bx - 3, rect.ay + title_height - 1, {
					color = fg .. '\\1a&HFF', opacity = menu_opacity * 0.1,
					radius = state.radius > 0 and state.radius + self.padding or 0,
					border = 1, border_color = fg, border_opacity = menu_opacity * 0.8
				})
				ass:texture(content_rect.ax + 3, rect.ay + 3, content_rect.bx - 3, rect.ay + title_height - 1, 'n', {
					size = 80, color = bg, opacity = menu_opacity * 0.1, anchor_x = content_rect.ax + 2, anchor_y = rect.ay + 2,
				})
			else
				ass:rect(content_rect.ax + 2, rect.ay + 2, content_rect.bx - 2, rect.ay + title_height, {
					color = menu_title, opacity = menu_opacity * 0.58,
					radius = state.radius > 0 and state.radius + self.padding or 0,
				})
			end

			-- Blur selection (also activates search input) when user clicks title
			if is_current then
				local input_rect = {
					ax = rect.ax, ay = rect.ay,
					bx = search_content_bx, by = rect.by,
				}
				bind_zone('primary_down', input_rect, function()
					self:search_cursor_blink_reset()
					self:select_index(nil)
				end)
			end

			-- Title
			if menu.search then
				local search_font_size = uniform_title_size and item_title_font_size
					or self.font_size
				local search_text_bx = search_content_bx - search_inner_padding
				-- Icon
				local icon_size, icon_opacity = search_font_size * 1.3,
					menu_opacity * (requires_submit and 0.5 or 1)
				local icon_offset = round((menu.search_icon_margin or 0) * state.scale)
					+ search_inner_padding
				local icon_rect = {
					ax = rect.ax + icon_offset,
					ay = rect.ay,
					bx = content_rect.ax + icon_offset + icon_size + self.item_padding * 1.5,
					by = rect.by,
				}

				if is_current and requires_submit then
					bind_zone('primary_down', icon_rect, function() self:search_submit() end)
					if get_point_to_rectangle_proximity(cursor, icon_rect) <= 0 then
						icon_opacity = menu_opacity
					end
				end

				ass:icon(rect.ax + icon_offset + icon_size / 2, rect.cy, icon_size, 'search', {
					color = fg,
					opacity = icon_opacity,
					clip = '\\clip(' ..
						icon_rect.ax .. ',' .. icon_rect.ay .. ',' .. icon_rect.bx .. ',' .. icon_rect.by .. ')',
				})

				-- Query/Placeholder
				local cursor_height_half = round(search_font_size * 0.5)
				local cursor_thickness = math.max(1, round(search_font_size / 14))
				local cursor_ax = search_text_bx + 1
				local placeholder_left = menu.search_placeholder_left_align
				if menu.search.query ~= '' then
					local opts = {
						size = search_font_size,
						font = self.font,
						color = bgt,
						wrap = 2,
						opacity = menu_opacity,
						clip = '\\clip(' .. icon_rect.bx .. ',' .. rect.ay .. ',' .. search_text_bx .. ',' .. rect.by .. ')',
					}
					local query, cursor = menu.search.query, menu.search.cursor
					-- Add a ZWNBSP suffix to prevent libass from trimming trailing spaces
					local head = ass_escape(string.sub(query, 1, cursor)) .. '\239\187\191'
					local tail_no_escape = string.sub(query, cursor + 1)
					local tail = ass_escape(tail_no_escape) .. '\239\187\191'
					cursor_ax = math.max(round(cursor_ax - text_width(tail_no_escape, opts)), rect.cx)
					ass:txt(cursor_ax, rect.cy, 6, head, opts)
					ass:txt(cursor_ax, rect.cy, 4, tail, opts)
				else
					local placeholder = (menu.search_style == 'palette' and menu.ass_safe_title)
						and menu.ass_safe_title
						or (requires_submit and t('type & ctrl+enter to search') or t('type to search'))
					local p_align = placeholder_left and 4 or 6
					local p_anchor = placeholder_left and icon_rect.bx or search_text_bx
					local p_clip_left = placeholder_left and icon_rect.bx or rect.ax
					ass:txt(p_anchor, rect.cy, p_align, placeholder, {
						size = search_font_size,
						font = self.font,
						italic = true,
						color = bgt,
						wrap = 2,
						opacity = menu_opacity * 0.4,
						clip = '\\clip(' .. p_clip_left .. ',' .. rect.ay .. ',' .. search_text_bx .. ',' .. rect.by .. ')',
					})
				end

				-- Selected input indicator for submittable searches.
				-- (input is selected when `selected_index` is `nil`)
				if menu.search_debounce == 'submit' and not menu.selected_index
					and menu.search_focus_indicator ~= false then
					local size_half = round(1 * state.scale)
					ass:rect(
						content_rect.ax, rect.by - size_half, search_content_bx, rect.by + size_half,
						{color = fg, opacity = menu_opacity}
					)
				end
				local input_is_blurred = menu.search_debounce == 'submit' and menu.selected_index

				-- Cursor
				local cursor_bx = cursor_ax + cursor_thickness
				local cursor_is_visible = not menu.search_cursor_blink or self.search_cursor_visible
				ass:rect(cursor_ax, rect.cy - cursor_height_half, cursor_bx, rect.cy + cursor_height_half, {
					color = menu_text,
					opacity = menu_opacity * (input_is_blurred and 0.34
						or cursor_is_visible and 0.82 or 0.08),
					radius = cursor_thickness / 2,
					clip = '\\clip(' .. cursor_ax .. ',' .. rect.ay .. ',' .. cursor_bx .. ',' .. rect.by .. ')',
				})

				if search_action_rect then
					local is_hovered = is_current
						and get_point_to_rectangle_proximity(cursor, search_action_rect) <= 0
					if is_hovered then
						ass:rect(
							search_action_rect.ax, search_action_rect.ay,
							search_action_rect.bx, search_action_rect.by,
							{
								color = menu_selection,
								opacity = menu_opacity * 0.22,
								radius = state.radius,
							}
						)
					end
					ass:icon(
						(search_action_rect.ax + search_action_rect.bx) / 2,
						(search_action_rect.ay + search_action_rect.by) / 2,
						(search_action_rect.by - search_action_rect.ay) * 0.58,
						menu.search_action.icon,
						{color = menu_text, opacity = menu_opacity * (is_hovered and 0.96 or 0.66)}
					)
					if is_current then
						bind_zone('primary_down', search_action_rect, self:create_action(function(shortcut)
							self:command_or_event(menu.on_search_action, {menu.search_action.name, menu.id}, {
								type = 'search_action',
								action = menu.search_action.name,
								query = menu.search.query,
								menu_id = menu.id,
								is_pointer = true,
							})
						end))
					end
				end
			else
				local title_available_width = math.max(
					0,
					rect.bx - rect.ax - self.item_padding * 2
				)
				if is_file_navigation_menu(menu) and not narrow_file_fit_policy then
					-- Centered directory titles need more breathing room than
					-- list rows because libass clips overflow at both edges.
					title_available_width = title_available_width * 0.86
				end
				local title_font_size, fitted_title = fit_text_to_width(
					menu.title,
					title_available_width,
					self.font_size,
					math.max(round(10 * state.scale), round(self.font_size * 0.82)),
					{font = self.font, bold = true},
					narrow_file_fit_policy
				)
				ass:txt(rect.cx, rect.cy, 5, fitted_title or menu.ass_safe_title, {
					size = title_font_size,
					font = self.font,
					scale_x = (fitted_title or title_font_size < self.font_size) and 94 or nil,
					bold = true,
					color = menu_title_text,
					wrap = 2,
					opacity = menu_opacity,
					clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')',
				})
			end
		end

		-- We are in mouse nav and cursor isn't hovering any item
		if blur_selected_index then
			menu.selected_index = nil
		end
		if blur_action_index then
			menu.action_index = nil
			request_render()
		end

		-- Return the bounds of this panel and its complete visible descendant
		-- chain. Ancestors must treat the cursor as still inside their submenu
		-- while it is over a grandchild panel, otherwise entering level three
		-- clears level one's selection and instantly collapses the whole chain.
		if submenu_rect then
			return {
				ax = math.min(bg_rect.ax, submenu_rect.ax),
				ay = math.min(bg_rect.ay, submenu_rect.ay),
				bx = math.max(bg_rect.bx, submenu_rect.bx),
				by = math.max(bg_rect.by, submenu_rect.by),
			}
		end
		return bg_rect
	end

	-- Reserve the widest possible submenu path from the first frame. The value
	-- is cached in update_dimensions() to keep menu animation/rendering cheap.
	local cascade_width = self.current.cascade_width or (self.current.width + self.padding * 2)
	local cascade_x = math.max(self.padding,
		math.min(self.ax, display.width - self.padding - cascade_width))

	-- Active menu
	draw_menu(self.current, cascade_x, 0)

	-- Parent menus
	local parent_menu = self.current.parent_menu
	local parent_offset_x, parent_horizontal_index = cascade_x, -1

	while parent_menu do
		parent_offset_x = parent_offset_x - parent_menu.width - self.padding * 2 - self.gap
		draw_menu(parent_menu, parent_offset_x, parent_horizontal_index)
		parent_horizontal_index = parent_horizontal_index - 1
		parent_menu = parent_menu.parent_menu
	end

	return ass
end

return Menu
