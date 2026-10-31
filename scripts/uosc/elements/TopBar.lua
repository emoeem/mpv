local Element = require('elements/Element')

---@alias TopBarButtonProps {icon: string; hover_fg?: string; hover_bg?: string; command: (fun():string)}

---@class TopBar : Element
local TopBar = class(Element)

local function is_internal_autoskip_chapter(chapter)
	return chapter and chapter.title
		and chapter.title:lower():find('^%[autoskip') ~= nil
end

function TopBar:new() return Class.new(self) --[[@as TopBar]] end
function TopBar:init()
	Element.init(self, 'top_bar', {render_order = 4})
	self.size = 0
	self.alt_title_size = 0
	self.chapter_size = 0
	self.titles_spacing = 1
	self.icon_size, self.font_size, self.title_by = 1, 1, 1
	self.show_alt_as_main = false
	self.main_title, self.alt_title = nil, nil
	---@type table<string, string|nil>
	self.render_titles = {}
	---@type {index: number; title: string}|nil
	self.current_chapter = nil

	local function maximized_command()
		mp.command(state.fullormaxed and 'set fullscreen no;set window-maximized no' or 'set window-maximized yes')
	end

	local close = {icon = 'close', hover_bg = '2311e8', hover_fg = 'ffffff', command = function() mp.command('quit') end}
	local max = {icon = 'crop_square', command = maximized_command, is_max = true}
	local min = {icon = 'minimize', command = function() mp.command('cycle window-minimized') end}
	local pin = {
		icon = 'push_pin',
		command = function() mp.commandv('script-message-to', 'ontop_mode', 'cycle') end,
	}
	self.buttons = options.top_bar_controls == 'left' and {close, max, min, pin} or {pin, min, max, close}

	self:register_observers()
	self:decide_enabled()
	self:update_dimensions()
end

---@return string|nil
local function expand_template(template)
	-- escape ASS, and strip newlines and trailing slashes and trim whitespace
	local tmp = mp.command_native({'expand-text', template}):gsub('\\n', ' '):gsub('[\\%s]+$', ''):gsub('^%s+', '')
	return tmp and tmp ~= '' and ass_escape(tmp) or nil
end

-- 按 UTF-8 字符切分，避免截断把多字节字符劈成半个（中文/emoji 文件名很常见）。
local function utf8_chars(text)
	local chars = {}
	for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = char end
	return chars
end

-- 把一个字符串压进指定像素宽度：能放下就原样返回，放不下就用「…」收尾。
-- 返回 nil 表示连省略号都放不下，调用方应当整块隐藏而不是画半个字。
local function fit_text_to_width(text, opts, max_width)
	if not text or text == '' or not max_width or max_width <= 0 then return nil end
	if text_width(text, opts) <= max_width then return text end
	local ellipsis = '…'
	local ellipsis_width = text_width(ellipsis, opts)
	if max_width <= ellipsis_width then return nil end
	local chars = utf8_chars(text)
	local budget = max_width - ellipsis_width
	local lo, hi = 0, #chars
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if text_width(table.concat(chars, '', 1, mid), opts) <= budget then lo = mid else hi = mid - 1 end
	end
	if lo <= 0 then return nil end
	-- 截断点正好落在分隔符上时会拼成「….」「….」，读起来像多个点；
	-- 先把尾部这些符号吃掉再接省略号。
	while lo > 1 do
		local ch = chars[lo]
		if ch == '.' or ch == ':' or ch == '·' or ch == '-' or ch == '_' or ch == ',' or ch == ' ' then
			lo = lo - 1
		else
			break
		end
	end
	return table.concat(chars, '', 1, lo) .. ellipsis
end

function TopBar:add_template_listener(template, callback)
	local props = get_expansion_props(template)
	for prop, _ in pairs(props) do
		self:observe_mp_property(prop, 'native', callback)
	end
	if not next(props) then callback() end
end

function TopBar:register_observers()
	-- 引擎胶囊：HDR 处理链模式变化时重绘
	mp.observe_property('user-data/hdr-pipeline/mode', 'string', function() request_render() end)
	-- 引擎胶囊 hdr-only 显隐：内容在 SDR ↔ HDR 之间切换时重绘
	self:observe_mp_property('video-params/gamma', 'string', function() request_render() end)
	-- Main title
	if #options.top_bar_title > 0 and options.top_bar_title ~= 'no' then
		if options.top_bar_title == 'yes' then
			local template = nil
			local function update_main_title()
				self.main_title = expand_template(template)
				self:update_render_titles()
			end
			local function remove_template_listener(callback) mp.unobserve_property(callback) end

			self:observe_mp_property('title', 'string', function(_, title)
				remove_template_listener(update_main_title)
				template = title
				if template then
					if template:sub(-6) == ' - mpv' then template = template:sub(1, -7) end
					self:add_template_listener(template, update_main_title)
				end
			end)
		elseif type(options.top_bar_title) == 'string' then
			self:add_template_listener(options.top_bar_title, function()
				self.main_title = expand_template(options.top_bar_title)
				self:update_render_titles()
			end)
		end
	end

	-- Alt title
	if #options.top_bar_alt_title > 0 and options.top_bar_alt_title ~= 'no' then
		self:add_template_listener(options.top_bar_alt_title, function()
			self.alt_title = expand_template(options.top_bar_alt_title)
			self:update_render_titles()
		end)
	end
end

function TopBar:decide_enabled()
	if options.top_bar == 'no-border' then
		self.enabled = not state.border or state.title_bar == false or state.fullscreen
	else
		self.enabled = options.top_bar == 'always'
	end
	self.enabled = self.enabled and (options.top_bar_controls or options.top_bar_title ~= 'no' or state.has_playlist)
end

--- 顶栏和控制区同进同退。
--- 只按自身 proximity 算的话，鼠标停在下半屏时底栏已经展开、顶栏还藏着，
--- 看起来像「信息要分两次才给全」。取两者的较大可见度让它们一起淡入淡出；
--- 菜单/幕布挡在前面时不把顶栏从幕布后面拽出来。
function TopBar:get_visibility()
	local visibility = Element.get_visibility(self)
	if visibility >= 1 then return 1 end
	local controls = Elements.controls
	if not controls then return visibility end
	local controls_visibility = controls:get_visibility()
	if controls_visibility <= 0 then return visibility end
	local curtain = Elements.curtain
	if curtain and curtain.opacity > 0 and not self.ignores_curtain then return visibility end
	return math.max(visibility, controls_visibility)
end

-- Set titles. Both have to be passed at the same time so that they can be normalized & deduplicated.
function TopBar:update_render_titles()
	local main, alt = self.main_title, self.alt_title

	if main == 'No file' then
		main = t('No file')
	end

	-- Fall back to alt title if main is empty
	if not main or main == '' then
		main, alt = alt, nil
	end

	-- Deduplicate the main and alt titles by checking if one completely
	-- contains the other, and using only the longer one.
	if main and alt and not self.show_alt_as_main then
		local longer_title, shorter_title
		if #main < #alt then
			longer_title, shorter_title = alt, main
		else
			longer_title, shorter_title = main, alt
		end

		local escaped_shorter_title = regexp_escape(shorter_title --[[@as string]])
		if string.match(longer_title --[[@as string]], escaped_shorter_title) then
			main, alt = longer_title, nil
		end
	end

	if self.show_alt_as_main and alt and alt ~= '' then
		main, alt = alt, nil
	end

	self.render_titles.main, self.render_titles.alt = main, alt
	self:update_dimensions()
	request_render()
end

function TopBar:select_current_chapter()
	local current_chapter_index = self.current_chapter and self.current_chapter.index
	local current_chapter
	if state.time and state.chapters then
		_, current_chapter = itable_find(state.chapters, function(c) return state.time >= c.time end, #state.chapters, 1)
	end
	local new_chapter_index = current_chapter and current_chapter.index
	if current_chapter_index ~= new_chapter_index then
		self.current_chapter = current_chapter
		if not is_internal_autoskip_chapter(current_chapter)
			and itable_has(config.top_bar_flash_on, 'chapter') then
			self:flash()
		end
		self:update_dimensions()
	end
end

local function responsive_top_bar_scale()
	local ui_scale = math.max(tonumber(state.scale) or 1, 0.01)
	local logical_height = (tonumber(display.height) or 0) / ui_scale
	local resolution_scale
	if logical_height < 1080 then
		-- Compact windows need a quieter title bar without becoming tiny. Grow
		-- smoothly from an 0.8x floor at 540p to the established 1x at 1080p;
		-- a 701px-high window lands near 0.86x (31px instead of 36px).
		local compact_progress = math.min(1, math.max(0, (logical_height - 540) / 540))
		resolution_scale = 0.8 + compact_progress * 0.2
	else
		-- Above 1080p, retain direct height scaling and progressively add the
		-- requested high-resolution emphasis: about 1.556x at 1440p and 3x at
		-- 4K (the former 2x 4K geometry enlarged by another 1.5x).
		local height_ratio = logical_height / 1080
		local four_k_progress = math.min(1, math.max(0, height_ratio - 1))
		resolution_scale = height_ratio * (1 + four_k_progress * 0.5)
	end
	-- Resolution supplements DPI instead of replacing it. If Windows already
	-- reports 200% HiDPI, physical dimensions are converted to logical height
	-- first, so the result is not enlarged twice.
	return ui_scale * resolution_scale
end

function TopBar:update_dimensions()
	local top_bar_scale = responsive_top_bar_scale()
	self.size = round(options.top_bar_size * top_bar_scale)
	self.title_spacing = round(1 * top_bar_scale)
	self.icon_size = round(self.size * 0.5)
	self.font_size = math.floor((self.size - (math.ceil(self.size * 0.25) * 2)) * options.font_scale)
	self.alt_title_size = round(self.font_size * 1.2)
	self.chapter_size = round(self.font_size * 1.1)
	local window_border_size = Elements:v('window_border', 'size', 0)
	local min_hitbox_height = self.size
	if self.render_titles.alt and options.top_bar_alt_title_place == 'below' then
		min_hitbox_height = min_hitbox_height + self.title_spacing + self.alt_title_size
	end
	if self.current_chapter and not is_internal_autoskip_chapter(self.current_chapter)
		and not options.top_bar_now_playing then
		min_hitbox_height = min_hitbox_height + self.title_spacing + self.chapter_size
	end
	self.ax = window_border_size
	self.ay = window_border_size
	self.bx = display.width - window_border_size
	-- We extend the hitbox so that people with low proximity options can still click on chapter button
	self.by = math.max(self.size + window_border_size, min_hitbox_height - options.proximity_in)
end

--- 章节胶囊的文本：章节编号 + 标题。
--- 标题自带「第 N 章 / Chapter N / EP N」等编号时原样保留，不拼第二次；
--- 标题为空时退回「第 N 章」；内部自动跳过章节（[autoskip]）视为无章节，
--- 不用 nil 或虚构编号占位。
function TopBar:get_now_playing_chapter_text()
	local chapter = self.current_chapter
	if not chapter or is_internal_autoskip_chapter(chapter) then return nil end
	local index = tonumber(chapter.index)
	local title = chapter.title

	if not title or title == '' then
		return index and ('第 ' .. index .. ' 章') or nil
	end

	-- 编号也可能是中文数字（「第二章 相遇」很常见）或出现在标题中间，
	-- 只认阿拉伯数字会导致「第 2 章 · 第二章 相遇」这种叠字。
	local numeral = '[0-9一二三四五六七八九十百千零两]+'
	if title:find('第%s*' .. numeral .. '%s*[章话集幕回节]')
		or title:find('[Cc]hapter%s*' .. numeral)
		or title:find('^%s*[Ee][Pp]%.?%s*' .. numeral) then
		return title
	end

	return index and ('第 ' .. index .. ' 章 · ' .. title) or title
end

function TopBar:toggle_title()
	if options.top_bar_alt_title_place ~= 'toggle' then return end
	self.show_alt_as_main = not self.show_alt_as_main
	self:update_render_titles()
end

function TopBar:on_prop_time()
	self:select_current_chapter()
end

function TopBar:on_prop_chapters()
	self:select_current_chapter()
end

function TopBar:on_prop_border()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_title_bar()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_fullscreen()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_maximized()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_has_playlist()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_display() self:update_dimensions() end

function TopBar:on_options()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end
	local ass = assdraw.ass_new()
	-- `by` might be artificially extended so people with low proximity options
	-- can still click on chapter button, so we can't use it for rendering.
	local ax, ay, bx, by = self.ax, self.ay, self.bx, self.ay + self.size
	local margin = math.floor((self.size - self.font_size) / 4)

	-- Window controls
	if options.top_bar_controls then
		local is_left, button_ax = options.top_bar_controls == 'left', 0
		-- 胶囊模式下窗口按钮用正圆（对齐 Mpv∞ 顶栏的圆形窗口控制）
		local control_radius = options.top_bar_capsule and math.floor((self.size - margin) / 2)
			or state.radius
		if is_left then
			button_ax = ax
			ax = self.size * #self.buttons
		else
			button_ax = bx - self.size * #self.buttons
			bx = button_ax
		end

		for _, button in ipairs(self.buttons) do
			if button.is_max then
				button.icon = state.fullscreen and 'close_fullscreen' or
				(state.maximized and 'filter_none' or 'crop_square')
			end

			local rect = {ax = button_ax, ay = ay, bx = button_ax + self.size, by = by}
			local is_hover = get_point_to_rectangle_proximity(cursor, rect) <= 0
			local opacity = is_hover and 1 or config.opacity.controls
			local button_fg = is_hover and (button.hover_fg or bg) or fg
			local button_bg = is_hover and (button.hover_bg or fg) or bg

			cursor:zone('primary_click', rect, button.command)

			local bg_size = self.size - margin
			local bg_ax, bg_ay = rect.ax + (is_left and margin or 0), rect.ay + margin
			local bg_bx, bg_by = bg_ax + bg_size, bg_ay + bg_size

			ass:rect(bg_ax, bg_ay, bg_bx, bg_by, {
				color = button_bg, opacity = visibility * opacity, radius = control_radius,
			})

			ass:icon(bg_ax + bg_size / 2, bg_ay + bg_size / 2, bg_size * 0.5, button.icon, {
				color = button_fg,
				border_color = button_bg,
				opacity = visibility,
				border = options.text_border * state.scale,
			})

			button_ax = button_ax + self.size
		end
	end

	-- 右侧胶囊排：从窗口控制左边缘向左依次排「引擎胶囊」「进度胶囊」，标题再让位。
	-- 胶囊形状由 top_bar_capsule 控制（全圆角 capsule / 主题圆角 classic），
	-- 两者都复用主题的 title 透明度与 state.radius，不引入新的硬编码配色。
	local pill_ay, pill_by = self.ay + margin, by - margin
	local pill_height = math.max(0, pill_by - pill_ay)
	local pill_radius = options.top_bar_capsule and math.max(1, math.floor(pill_height / 2))
		or state.radius
	local pill_padding = round(self.font_size / 2)
	local pill_gap = math.max(2, round(margin * 0.7))
	local pill_fg = config.color.menu_text or bgt

	-- 引擎胶囊（对齐 Mpv∞ 顶栏的 Native 引擎胶囊）。
	-- 数据源：scripts/hdr-pipeline.lua 维护的 user-data/hdr-pipeline/mode。
	-- 注意必须用 get_property_native：user-data 里的字符串用 get_property 读出来
	-- 是带引号的序列化形式（"toys"），直接比较会永远不成立。
	-- 属性不存在（脚本未加载）时整颗胶囊隐藏，不做无功能的死按钮。
	local engine_mode = mp.get_property_native('user-data/hdr-pipeline/mode')
	-- hdr-only 模式：引擎切换器只对 HDR 内容有意义，SDR 下整颗隐藏，避免顶栏挂着
	-- 一颗无功能的开关。gamma 判定与 mpv 条件配置组（[HDR-PASS] 等）保持同一口径。
	local gamma = mp.get_property_native('video-params/gamma')
	local engine_chip_visible = not options.top_bar_engine_chip_hdr_only
		or gamma == 'pq' or gamma == 'hlg'
	if engine_mode and engine_chip_visible and options.top_bar_controls and pill_height > 0 then
		local engine_label = engine_mode == 'toys' and 'Toys' or '原生'
		local text_opts = {
			size = self.font_size, wrap = 2,
			color = pill_fg, opacity = visibility,
			border = options.text_border * state.scale, border_color = bg,
		}
		local pill_width = round(text_width(engine_label, text_opts) + pill_padding * 2)
		local rect = {ax = bx - pill_width, ay = pill_ay, bx = bx, by = pill_by}
		local is_hovered = get_point_to_rectangle_proximity(cursor, rect) <= 0

		cursor:zone('primary_click', rect,
			function() mp.command('script-message-to hdr_pipeline toggle') end)

		ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
			color = bg,
			opacity = visibility * (is_hovered and math.min(1, config.opacity.title + 0.18)
				or config.opacity.title),
			radius = pill_radius,
		})
		ass:txt(rect.ax + (rect.bx - rect.ax) / 2, rect.ay + (rect.by - rect.ay) / 2, 5,
			engine_label, text_opts)

		bx = rect.ax - pill_gap
	end

	-- 章节胶囊：只回答「在看什么」，不再承载播放时间。
	-- 时间语义统一交给时间轴（左端当前 / 右端总时长），顶栏不再和它抢同一件事。
	-- 无章节时不画空占位、不虚构编号；放不下就整颗隐藏，绝不挤压文件标题。
	if options.top_bar_now_playing and pill_height > 0 then
		local chapter_text = self:get_now_playing_chapter_text()
		local available_width = bx - ax - margin * 2
		-- 文件名才是顶栏的主角：先给它留出约 8 个字的最小可读宽度，
		-- 章节胶囊只能吃剩下的。窄窗里挤不下就整颗消失，不许把标题压成「天汽…」。
		local title_reserve = self.font_size * 8
		local chapter_budget = math.min(available_width * 0.55, available_width - title_reserve)
		if chapter_text and chapter_budget > self.font_size * 4 then
			local text_opts = {
				size = self.font_size, wrap = 2,
				color = pill_fg, opacity = visibility,
				border = options.text_border * state.scale, border_color = bg,
			}
			-- 章节名按预算收缩；连省略号都放不下时整颗隐藏。
			local text = fit_text_to_width(chapter_text, text_opts, chapter_budget - pill_padding * 2)
			if text then
				local pill_width = round(text_width(text, text_opts) + pill_padding * 2)
				local rect = {ax = bx - pill_width, ay = pill_ay, bx = bx, by = pill_by}
				ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
					color = bg, opacity = visibility * config.opacity.title, radius = pill_radius,
				})
				ass:txt(rect.ax + (rect.bx - rect.ax) / 2, rect.ay + (rect.by - rect.ay) / 2, 5,
					text, text_opts)

				-- 点击跳到章节列表（与旧版章节条目的交互保持一致）
				if self.current_chapter then
					cursor:zone('primary_click', rect,
						function() mp.command('script-binding uosc/chapters') end)
				end

				bx = rect.ax - pill_gap
			end
		end
	end

	-- Window title
	local main_title, alt_title = self.render_titles.main, self.render_titles.alt
	if main_title or state.has_playlist then
		local padding = round(self.font_size / 2)
		local left_aligned = options.top_bar_controls == 'left'
		local title_ax, title_bx, title_ay = ax + margin, bx - margin, self.ay + margin

		-- Playlist position
		if state.has_playlist then
			local text = state.playlist_pos .. '' .. state.playlist_count
			local formatted_text = '{\\b1}' .. state.playlist_pos .. '{\\b0\\fs' .. self.font_size * 0.9 .. '}/'
				.. state.playlist_count
			local opts = {size = self.font_size, wrap = 2, color = fgt, opacity = visibility}
			local rect_width = round(text_width(text, opts) + padding * 2)
			local ax = left_aligned and title_bx - rect_width or title_ax
			local rect = {
				ax = ax,
				ay = title_ay,
				bx = ax + rect_width,
				by = by - margin,
			}
			local opacity = get_point_to_rectangle_proximity(cursor, rect) <= 0
				and 1 or config.opacity.playlist_position
			if opacity > 0 then
				ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
					color = fg, opacity = visibility * opacity, radius = state.radius,
				})
			end
			ass:txt(rect.ax + (rect.bx - rect.ax) / 2, rect.ay + (rect.by - rect.ay) / 2, 5, formatted_text, opts)
			if left_aligned then title_bx = rect.ax - margin else title_ax = rect.bx + margin end

			-- Click action
			cursor:zone('primary_click', rect, function() mp.command('script-binding uosc/playlist') end)
		end

		-- Skip rendering titles if there's not enough horizontal space
		if title_bx - title_ax > self.font_size * 3 and options.top_bar_title ~= 'no' then
			-- Main title
			if main_title then
				local opts = {
					size = self.font_size,
					wrap = 2,
					color = config.color.menu_text or bgt,
					opacity = visibility,
					border = options.text_border * state.scale,
					border_color = bg,
					clip = string.format('\\clip(%d, %d, %d, %d)', self.ax, ay, title_bx, by),
				}
				-- 文件名过长时用「…」收尾，而不是硬裁一半字符；
				-- 放不下就整块跳过，绝不让文字压到右侧胶囊/窗口控制上。
				local title_text = fit_text_to_width(main_title, opts,
					title_bx - title_ax - padding * 2)
				local rect_ideal_width = round((title_text and text_width(title_text, opts) or 0) + padding * 2)
				local rect_width = math.min(rect_ideal_width, title_bx - title_ax)
				local ax = left_aligned and title_bx - rect_width or title_ax
				local by = by - margin
				local title_rect = {ax = ax, ay = title_ay, bx = ax + rect_width, by = by}

				if options.top_bar_alt_title_place == 'toggle' then
					cursor:zone('primary_click', title_rect, function() self:toggle_title() end)
				end

				ass:rect(title_rect.ax, title_rect.ay, title_rect.bx, title_rect.by, {
					color = bg, opacity = visibility * config.opacity.title, radius = state.radius,
				})
				local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
				local x = align == 6 and title_rect.bx - padding or ax + padding
				if title_text then
					ass:txt(x, ay + (self.size / 2), align, title_text, opts)
				end
				title_ay = by + self.title_spacing
			end

			-- Alt title
			if alt_title and options.top_bar_alt_title_place == 'below' then
				local by = title_ay + self.alt_title_size
				local opts = {
					size = round(self.alt_title_size * 0.77),
					wrap = 2,
					color = bgt,
					border = options.text_border * state.scale,
					border_color = bg,
					opacity = visibility,
				}
				local rect_ideal_width = round(text_width(alt_title, opts) + padding * 2)
				local rect_width = math.min(rect_ideal_width, title_bx - title_ax)
				local ax = left_aligned and title_bx - rect_width or title_ax
				local bx = ax + rect_width
				opts.clip = string.format('\\clip(%d, %d, %d, %d)', title_ax, title_ay, bx, by)
				ass:rect(ax, title_ay, bx, by, {
					color = bg, opacity = visibility * config.opacity.title, radius = state.radius,
				})
				local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
				local x = align == 6 and bx - padding or ax + padding
				ass:txt(x, title_ay + self.alt_title_size / 2, align, alt_title, opts)
				title_ay = by + self.title_spacing
			end

			-- 当前章节已移到顶栏右侧的进度胶囊里（top_bar_now_playing），
			-- 这里不再重复绘制第二行，避免同一信息在顶栏出现两次。
		end
		self.title_by = title_ay - 1
	else
		self.title_by = ay
	end

	return ass
end

return TopBar
