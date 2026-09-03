---@alias OpenCommandMenuOptions {submenu?: string; mouse_nav?: boolean; anchor_x?: number; anchor_y?: number; item_height?: number; font_scale?: number; on_close?: string | string[]}
---@param data MenuData
---@param opts? OpenCommandMenuOptions
function open_command_menu(data, opts)
	opts = opts or {}
	local menu

	local function run_command(command)
		if type(command) == 'table' then
			---@diagnostic disable-next-line: deprecated
			mp.commandv(unpack(command))
		else
			mp.command(tostring(command))
		end
	end

	local function callback(event)
		if type(menu.root.callback) == 'table' then
			---@diagnostic disable-next-line: deprecated
			mp.commandv(unpack(itable_join({'script-message-to'}, menu.root.callback, {utils.format_json(event)})))
		elseif event.type == 'activate' then
			-- Modifiers and actions are not available on basic non-callback mode menus.
			-- `alt` modifier should activate without closing the menu.
			if (event.modifiers == 'alt' or not event.modifiers) and not event.action then
				run_command(event.value)
			end
			-- Convention: Only pure item activations should close the menu.
			-- Using modifiers or triggering item actions should not.
			if not event.keep_open and not event.modifiers and not event.action then
				menu:close()
			end
		end
	end

	---@type MenuOptions
	local menu_opts = table_assign_props({}, opts,
		{'mouse_nav', 'anchor_x', 'anchor_y', 'item_height', 'font_scale'})
	menu = Menu:open(data, callback, menu_opts)
	if opts.submenu then menu:activate_menu(opts.submenu) end
	return menu
end

local function get_image_subtitle_summary()
	local media_loaded = not mp.get_property_bool('idle-active', true)
		and mp.get_property('path', '') ~= ''
	if not media_loaded then return nil, false end

	local labels = {}
	local seen = {}
	for _, track in ipairs(mp.get_property_native('track-list') or {}) do
		if track.type == 'sub' then
			local codec = tostring(track.codec or ''):lower()
			local label
			if codec:find('pgs', 1, true) or codec == 'hdmv_pgs_subtitle' then
				label = 'PGS'
			elseif codec:find('vobsub', 1, true) or codec == 'dvd_subtitle' then
				label = 'VobSub'
			elseif codec:find('dvb', 1, true) then
				label = 'DVB'
			end
			if label and not seen[label] then
				seen[label] = true
				labels[#labels + 1] = label
			end
		end
	end

	return #labels > 0 and table.concat(labels, '/') or nil, true
end

local function on_off_hint(enabled)
	return enabled and '● 开启' or '○ 关闭'
end

	-- Keep the optical-disc entry understandable on both the current
-- formal core and the c318236 candidate.  The hint is read-only; it never
-- changes the default disc-menu policy.
local function has_command(name)
	for _, command in ipairs(mp.get_property_native('command-list') or {}) do
		if type(command) == 'table' and command.name == name then return true end
	end
	return false
end

---@param items MenuDataChild[]
local function update_menu_state_hints(items, image_subtitle_summary, media_loaded)
	if media_loaded == nil then
		image_subtitle_summary, media_loaded = get_image_subtitle_summary()
	end
	local index = 1
	while index <= #(items or {}) do
		local item = items[index]
		if item.value == 'script-message-to uosc idle-branding-toggle' then
			item.hint = on_off_hint((mp.get_property_native('user-data/uosc/idle-branding') or 'yes') == 'yes')
		elseif item.value == 'script-message-to uosc chapter-display-toggle' then
			item.hint = on_off_hint((mp.get_property_native('user-data/uosc/chapter-display') or 'no') == 'yes')
		elseif item.value == 'script-message-to idle_branding_image select' then
			item.hint = mp.get_property(
				'user-data/idle-branding-image/mode',
				'default'
			) == 'custom' and '自定义图案' or '默认图案'
		elseif item.value == 'script-message-to startup_format_logos startup-format-logos-toggle' then
			item.hint = on_off_hint(mp.get_property_bool('user-data/startup-format-logos/enabled', true))
		elseif item.value == 'script-message-to startup_format_logos startup-format-logos-set-style color' then
			local style = mp.get_property_native('user-data/startup-format-logos/style') or 'color'
			item.hint = style == 'color' and '● 当前' or '○'
		elseif item.value == 'script-message-to startup_format_logos startup-format-logos-set-style white' then
			local style = mp.get_property_native('user-data/startup-format-logos/style') or 'color'
			item.hint = style == 'white' and '● 当前' or '○'
		elseif item.title == '图标样式' and item.items
			and item.items[1]
			and item.items[1].value == 'script-message-to startup_format_logos startup-format-logos-set-style color' then
			local style = mp.get_property_native('user-data/startup-format-logos/style') or 'color'
			item.hint = style == 'white' and '透明白图标' or '彩色徽章'
		elseif item.value == 'script-message-to auto_fullscreen toggle' then
			local enabled = mp.get_property_native('user-data/auto-fullscreen/enabled') == 'yes'
			item.hint = enabled and '● 开启' or '○ 关闭'
		elseif item.value == 'script-message codex-open-music-mode-menu' then
			local active = mp.get_property_native('user-data/music-mode/active') == 'yes'
			local label = mp.get_property_native('user-data/music-mode/label') or '列表循环'
			item.hint = active and ('● ' .. label) or '○ 关闭'
		elseif item.value == 'script-message codex-open-audio-passthrough-menu' then
			local enabled = mp.get_property_native('user-data/audio-passthrough/enabled') == 'yes'
			local label = mp.get_property_native('user-data/audio-passthrough/label') or '关闭'
			item.hint = enabled and ('● ' .. label) or '○ 关闭'
		elseif item.value == 'script-message codex-open-video-enhancement-menu' then
			local superres_mode = mp.get_property_native(
				'user-data/video-enhancement/superres-mode'
			) or 'auto'
			local smooth_mode = mp.get_property_native(
				'user-data/video-enhancement/smooth-mode'
			) or 'auto'
			local enabled = superres_mode ~= 'off' or smooth_mode ~= 'off'
			item.hint = enabled and '● 开启' or '○ 关闭'
		elseif item.value == 'script-message codex-open-dock-animation-menu' then
			local mode = mp.get_property_native('user-data/uosc/dock-animation-mode') or 'classic'
			item.hint = mode == 'smooth' and '● 丝滑 Morph'
				or mode == 'classic' and '● 经典 Morph'
				or '○ 关闭'
		elseif item.value == 'script-message-to minimize_pause_resume toggle' then
			local enabled = mp.get_property_native('user-data/minimize-pause-resume/pause-on-minimize') ~= 'no'
			item.hint = enabled and '● 开启' or '○ 关闭'
		elseif item.value == 'script-message codex-open-peak-menu' then
			local output_mode = mp.get_property_native('user-data/hdr-mode/output-mode') or 'auto'
			local source_gamma = tostring(mp.get_property('video-params/gamma', '')):lower()
			local target_gamma = tostring(mp.get_property('video-target-params/gamma', '')):lower()
			local source_is_hdr = source_gamma == 'pq' or source_gamma == 'hlg'
			local output_is_hdr = target_gamma == 'pq' or target_gamma == 'hlg'
			local status = tostring(mp.get_property_native('user-data/display-info/hdr-status') or '')
			item.hint = output_mode == 'sdr' and 'HDR→SDR'
				or output_is_hdr and '自动→HDR'
				or source_is_hdr and '自动→SDR'
				or status == 'on' and '自动→SDR'
				or '自动'
		elseif item.value == 'script-message codex-open-black-level-menu' then
			local mode = mp.get_property_native('user-data/black-level/output-range-mode') or 'auto'
			local target = mp.get_property_native('user-data/black-level/target-range') or 'unknown'
			item.hint = mode == 'auto' and ('自动 → ' .. (target == 'unknown' and '检测中' or target))
				or mode == 'full' and 'RGB Full'
				or 'Limited'
		elseif item.value == 'script-message codex-open-subtitle-color-menu' then
			local mode = mp.get_property('sub-ass-vsfilter-color-compat', 'no')
			item.hint = mode == 'no' and '原色优先'
				or mode == 'basic' and '标准兼容'
				or mode == 'full' and '完整矩阵'
				or '强制 BT.601'
		elseif item.value == 'script-message codex-open-image-subs-brightness-menu' then
			local requested = mp.get_property_native('user-data/image-subs-brightness/mode') or 'auto'
			local effective = mp.get_property_native('user-data/image-subs-brightness/effective-mode') or 'video'
			local mode_hint = requested == 'auto'
				and (effective == 'video' and '自动→随视频' or '自动→SDR')
				or (requested == 'video' and '随视频' or 'SDR')
			item.hint = image_subtitle_summary and (image_subtitle_summary .. ' · ' .. mode_hint)
				or media_loaded and '无图形字幕'
				or '未加载'
		elseif item.value == 'script-message-to disc_menu open' then
			if not has_command('discnav') then
				item.hint = '需更新核心'
			else
				local disc_path = tostring(mp.get_property('stream-open-filename') or '')
				local demuxer = tostring(mp.get_property('demuxer') or '')
				local remote = mp.get_property_native('user-data/auto-iso-loader/remote') == true
				local loading = mp.get_property_native('user-data/auto-iso-loader/loading') == true
				local loading_phase = tostring(mp.get_property_native('user-data/auto-iso-loader/loading-phase') or '')
				local menu_active = mp.get_property_native('disc-menu-active') == true
				local bdj_ready = mp.get_property_native('user-data/disc-menu/bdj-runtime-ready') == true
				local is_disc = disc_path:match('^bd://') or disc_path:match('^dvd://')
					or demuxer == 'disc'
				if remote then
					item.hint = '网盘 ISO · 主标题'
				elseif menu_active then
					item.hint = '● 蓝光菜单正在显示 · Esc 返回'
				elseif loading and loading_phase == 'menu-unresponsive' then
					item.hint = '菜单暂未响应 · 点击重试'
				elseif loading then
					item.hint = '正在打开 · 点击查看菜单操作'
				elseif is_disc then
					item.hint = '● 本地原盘 · 可唤出菜单'
				elseif bdj_ready then
					item.hint = '自动进入 · BD-J 已内置'
				else
					item.hint = 'BD-J 组件缺失'
				end
			end
		end
		if item.items then
			update_menu_state_hints(item.items, image_subtitle_summary, media_loaded)
		end
		index = index + 1
	end
end

local function clone_menu_items(items)
	local copy = {}
	for index, item in ipairs(items or {}) do
		local cloned = table_copy(item)
		if item.items then cloned.items = clone_menu_items(item.items) end
		copy[index] = cloned
	end
	return copy
end

local function tune_yaozhi_menu_dimensions(items)
	for _, item in ipairs(items or {}) do
		if item.title == '杳知' and item.items then
			item.min_width = 320
			return
		end
	end
end

-- Atmos is an opt-in process mode. Inject its entry only after the dedicated
-- launcher has published a verified capability state, instead of caching a
-- hidden input.conf item before the experimental decoder is ready.
local function inject_atmos_menu(items)
	local atmosphere_mode = mp.get_property_native('user-data/yaozhi/atmos-mode') or 'no'
	if atmosphere_mode ~= 'yes' then return end

	local yaozhi_menu
	for _, item in ipairs(items or {}) do
		if item.title == '杳知' and item.items then
			yaozhi_menu = item
			break
		end
	end
	if not yaozhi_menu then return end

	for _, item in ipairs(yaozhi_menu.items) do
		if item.value == 'script-message codex-open-atmos-menu' then return end
	end

	local atmosphere_item = {
		title = 'Dolby Atmos 实验模式',
		hint = mp.get_property_native('user-data/yaozhi/atmos-status-label')
			or '实验播放器已进入',
		value = 'script-message codex-open-atmos-menu',
	}
	local insert_at = #yaozhi_menu.items + 1
	for index, item in ipairs(yaozhi_menu.items) do
		if item.value == 'script-message codex-open-audio-passthrough-menu' then
			insert_at = index + 1
			break
		end
	end
	table.insert(yaozhi_menu.items, insert_at, atmosphere_item)
	msg.verbose('Injected Atmos experiment entry into the Yaozhi menu')
end

-- Keep the support entry visually separated and pinned to the very bottom,
-- including in the Atmos sidecar where a process-only item is injected later.
local function pin_yaozhi_donation(items)
	local yaozhi_menu
	for _, item in ipairs(items or {}) do
		if item.title == '杳知' and item.items then
			yaozhi_menu = item
			break
		end
	end
	if not yaozhi_menu then return end

	local donation
	for index, item in ipairs(yaozhi_menu.items) do
		if item.value == 'script-message-to yaozhi_donation open' then
			donation = table.remove(yaozhi_menu.items, index)
			break
		end
	end
	if not donation then return end

	donation.icon = 'favorite'
	donation.hint = '感谢支持 · 长期维护'
	local previous = yaozhi_menu.items[#yaozhi_menu.items]
	if previous then previous.separator = true end
	yaozhi_menu.items[#yaozhi_menu.items + 1] = donation
end

---@param opts? OpenCommandMenuOptions
function toggle_menu_with_items(opts)
	if Menu:is_open('menu') then
		Menu:close()
	else
		-- Keep the primary command tree compact without changing playlist,
		-- history, subtitle, track, or file-navigation menu ergonomics.
		opts = table_assign({item_height = 40, font_scale = 1.12}, opts or {})
		-- get_menu_items() returns a cached tree. Work on a clone so dynamic
		-- state hints and process-only entries never mutate the shared cache.
		local items = clone_menu_items(get_menu_items())
		tune_yaozhi_menu_dimensions(items)
		inject_atmos_menu(items)
		pin_yaozhi_donation(items)
		update_menu_state_hints(items)
		open_command_menu({
			type = 'menu',
			min_width = 250,
			items = items,
			search_submenus = true,
		}, opts)
	end
end

---@alias TrackEventRemove {type: 'remove' | 'delete', index: number; value: any;}
---@alias TrackEventReload {type: 'reload', index: number; value: any;}
---@param opts {type: string; title: string; min_width?: number; center_root_when_closed?: boolean; list_prop: string; active_prop?: string; footnote?: string; serializer: fun(list: any, active: any): MenuDataItem[]; actions?: MenuAction[]; actions_place?: 'inside'|'outside'; on_paste: fun(event: MenuEventPaste); on_move?: fun(event: MenuEventMove); on_activate?: fun(event: MenuEventActivate); on_remove?: fun(event: TrackEventRemove); on_delete?: fun(event: TrackEventRemove); on_reload?: fun(event: TrackEventReload); on_key?: fun(event: MenuEventKey, close: fun())}
function create_self_updating_menu_opener(opts)
	return function()
		if Menu:is_open(opts.type) then
			Menu:close()
			return
		end
		local list = mp.get_property_native(opts.list_prop)
		local active = opts.active_prop and mp.get_property_native(opts.active_prop) or nil
		local menu

		local function update() menu:update_items(opts.serializer(list, active)) end

		local ignore_initial_list = true
		local function handle_list_prop_change(name, value)
			if ignore_initial_list then
				ignore_initial_list = false
			else
				list = value
				update()
			end
		end

		local ignore_initial_active = true
		local function handle_active_prop_change(name, value)
			if ignore_initial_active then
				ignore_initial_active = false
			else
				active = value
				update()
			end
		end

		local function cleanup_and_close()
			mp.unobserve_property(handle_list_prop_change)
			mp.unobserve_property(handle_active_prop_change)
			menu:close()
		end

		local initial_items, selected_index = opts.serializer(list, active)

		---@type MenuAction[]
		local actions = opts.actions or {}
		if opts.on_move then
			actions[#actions + 1] = {
				name = 'move_up',
				icon = 'arrow_upward',
				label = t('Move up') .. ' (ctrl+up/pgup/home)',
				filter_hidden = true,
			}
			actions[#actions + 1] = {
				name = 'move_down',
				icon = 'arrow_downward',
				label = t('Move down') .. ' (ctrl+down/pgdwn/end)',
				filter_hidden = true,
			}
		end
		if opts.on_reload then
			actions[#actions + 1] = {name = 'reload', icon = 'refresh', label = t('Reload') .. ' (f5)'}
		end
		if opts.on_remove or opts.on_delete then
			local label = (opts.on_remove and t('Remove') or t('Delete')) .. ' (del)'
			if opts.on_remove and opts.on_delete then
				label = t('Remove') .. ' (' .. t('%s to delete', 'del, ctrl+del') .. ')'
			end
			actions[#actions + 1] = {name = 'remove', icon = 'delete', label = label}
		end

		function remove_or_delete(index, value, menu_id, modifiers)
			if opts.on_remove and opts.on_delete then
				local method = modifiers == 'ctrl' and 'delete' or 'remove'
				local handler = method == 'delete' and opts.on_delete or opts.on_remove
				if handler then
					handler({type = method, value = value, index = index})
				end
			elseif opts.on_remove or opts.on_delete then
				local method = opts.on_delete and 'delete' or 'remove'
				local handler = opts.on_delete or opts.on_remove
				if handler then
					handler({type = method, value = value, index = index})
				end
			end
		end

		-- Items and active_index are set in the handle_prop_change callback, since adding
		-- a property observer triggers its handler immediately, we just let that initialize the items.
		menu = Menu:open({
			type = opts.type,
			title = opts.title,
			min_width = opts.min_width,
			center_root_when_closed = opts.center_root_when_closed,
			footnote = opts.footnote,
			items = initial_items,
			item_actions = actions,
			item_actions_place = opts.actions_place,
			selected_index = selected_index,
			on_move = opts.on_move and 'callback' or nil,
			on_paste = opts.on_paste and 'callback' or nil,
		}, function(event)
			if event.type == 'activate' then
				if (event.action == 'move_up' or event.action == 'move_down') and opts.on_move then
					local to_index = event.index + (event.action == 'move_up' and -1 or 1)
					if to_index >= 1 and to_index <= #menu.current.items then
						local moved = opts.on_move({
							type = 'move',
							from_index = event.index,
							to_index = to_index,
							menu_id = menu.current.id,
						})
						if moved ~= false then
							menu:select_index(to_index)
							if not event.is_pointer then
								menu:scroll_to_index(to_index, nil, true)
							end
						end
					end
				elseif event.action == 'reload' and opts.on_reload then
					opts.on_reload({type = 'reload', index = event.index, value = event.value})
				elseif event.action == 'remove' and (opts.on_remove or opts.on_delete) then
					remove_or_delete(event.index, event.value, event.menu_id, event.modifiers)
				else
					opts.on_activate(event --[[@as MenuEventActivate]])
					if not event.modifiers and not event.action then cleanup_and_close() end
				end
			elseif event.type == 'key' then
				local item = event.selected_item
				if event.id == 'enter' then
					-- We get here when there's no selectable item in menu and user presses enter.
					cleanup_and_close()
				elseif event.key == 'f5' and opts.on_reload and item then
					opts.on_reload({type = 'reload', index = item.index, value = item.value})
				elseif event.key == 'del' and (opts.on_remove or opts.on_delete) and item then
					if itable_has({nil, 'ctrl'}, event.modifiers) then
						remove_or_delete(item.index, item.value, event.menu_id, event.modifiers)
					end
				elseif opts.on_key then
					opts.on_key(event --[[@as MenuEventKey]], cleanup_and_close)
				end
			elseif event.type == 'paste' and opts.on_paste then
				opts.on_paste(event --[[@as MenuEventPaste]])
			elseif event.type == 'close' then
				cleanup_and_close()
			elseif event.type == 'move' and opts.on_move then
				opts.on_move(event --[[@as MenuEventMove]])
			elseif event.type == 'remove' and opts.on_move then
			end
		end)

		mp.observe_property(opts.list_prop, 'native', handle_list_prop_change)
		if opts.active_prop then
			mp.observe_property(opts.active_prop, 'native', handle_active_prop_change)
		end
	end
end

---@param opts {title: string; type: string; prop: string; enable_prop?: string; secondary?: {prop: string; icon: string; enable_prop?: string}; load_command: string; download_command?: string}
function create_select_tracklist_type_menu_opener(opts)
	local snd = opts.secondary
	local function get_props()
		return tonumber(mp.get_property(opts.prop)), snd and tonumber(mp.get_property(snd.prop)) or nil
	end

	local function escape_codec(str)
		if not str or str == '' then return '' end
	
		local codec_map = {
			mpeg2 = "mpeg2",
			dvvideo = "dv",
			pcm = "pcm",
			pgs = "pgs",
			subrip = "srt",
			vtt = "vtt",
			dvd_sub = "vob",
			dvb_sub = "dvb",
			dvb_tele = "teletext",
			arib = "arib"
		}
	
		for key, value in pairs(codec_map) do
			if str:find(key) then
				return value
			end
		end
	
		return str
	end

	local function codec_label(str)
		str = escape_codec(str or ''):lower()
		if str == '' then return '' end

		local codec_map = {
			aac = 'AAC',
			ac3 = 'AC-3',
			eac3 = 'E-AC-3',
			eac3_atmos = 'E-AC-3 Atmos',
			truehd = 'TrueHD',
			truehd_atmos = 'TrueHD Atmos',
			dts = 'DTS',
			dts_hd = 'DTS-HD',
			dts_hd_ma = 'DTS-HD MA',
			flac = 'FLAC',
			mp3 = 'MP3',
			opus = 'Opus',
			vorbis = 'Vorbis',
			pcm = 'PCM',
			ass = 'ASS',
			ssa = 'SSA',
			srt = 'SRT',
			pgs = 'PGS',
			vob = 'VobSub',
			dvb = 'DVB',
			vtt = 'WebVTT',
		}

		if str:find('truehd') and str:find('atmos') then return codec_map.truehd_atmos end
		if str:find('eac3') and str:find('atmos') then return codec_map.eac3_atmos end
		if str:find('dts') and str:find('ma') then return codec_map.dts_hd_ma end
		if str:find('dts') and str:find('hd') then return codec_map.dts_hd end

		return codec_map[str] or str:upper()
	end

	local function language_label(lang)
		lang = trim(lang or '')
		if lang == '' then return '' end

		local normalized = lang:lower():gsub('_', '-')
		local base = normalized:match('^[^-]+') or normalized
		local language_map = {
			chi = '中文', zho = '中文', zh = '中文',
			['zh-cn'] = '简中', ['zh-hans'] = '简中', cmn = '国语',
			['zh-tw'] = '繁中', ['zh-hant'] = '繁中',
			yue = '粤语', jpn = '日语', ja = '日语',
			eng = '英语', en = '英语', kor = '韩语', ko = '韩语',
			fra = '法语', fre = '法语', fr = '法语',
			spa = '西语', es = '西语', deu = '德语', ger = '德语', de = '德语',
			ita = '意语', it = '意语', rus = '俄语', ru = '俄语',
		}

		return language_map[normalized] or language_map[base] or lang
	end

	local function channel_label(channels)
		if not channels then return '' end
		local text = tostring(channels):lower()
		if text == '' then return '' end
		if text == '1' or text == 'mono' then return 'Mono' end
		if text == '2' or text == 'stereo' then return 'Stereo' end
		if text:match('^%d+%.%d+$') then return text end

		local count = tonumber(text)
		if count == 6 then return '5.1' end
		if count == 8 then return '7.1' end
		if count then return tostring(count) .. 'ch' end

		return text:gsub('^%l', string.upper)
	end

	local function join_values(values, separator)
		local result = {}
		for _, value in ipairs(values) do
			value = trim(value or '')
			if value ~= '' then result[#result + 1] = value end
		end
		return table.concat(result, separator or ' / ')
	end

	local function is_plain_track_title(title, lang)
		title = trim(title or '')
		if title == '' then return true end
		local lower = title:lower()
		local lang_lower = trim(lang or ''):lower()
		return lower:match('^track%s*%d+$') ~= nil
			or lower:match('^轨道%s*%d+$') ~= nil
			or (lang_lower ~= '' and lower == lang_lower)
	end

	local function normalize_compare_text(text)
		return trim(text or ''):lower():gsub('%s+', ''):gsub('[%p%c]', '')
	end

	local function title_contains_label(title, label)
		local normalized_title = normalize_compare_text(title)
		local normalized_label = normalize_compare_text(label)
		return normalized_title ~= ''
			and normalized_label ~= ''
			and normalized_title:find(normalized_label, 1, true) ~= nil
	end

	local function append_title_value(values, title, value)
		value = trim(value or '')
		if value ~= '' and not title_contains_label(title, value) then values[#values + 1] = value end
	end

	local function title_implies_language(title, language)
		local normalized_title = normalize_compare_text(title)
		if normalized_title == '' then return false end

		if language == '中文' or language == '简中' or language == '繁中' or language == '国语' or language == '粤语' then
			return normalized_title:find('中文', 1, true) ~= nil
				or normalized_title:find('简', 1, true) ~= nil
				or normalized_title:find('繁', 1, true) ~= nil
				or normalized_title:find('中英', 1, true) ~= nil
				or normalized_title:find('国配', 1, true) ~= nil
				or normalized_title:find('国语', 1, true) ~= nil
				or normalized_title:find('粤配', 1, true) ~= nil
				or normalized_title:find('粤语', 1, true) ~= nil
		end

		if language == '英语' then
			return normalized_title:find('英文', 1, true) ~= nil
				or normalized_title:find('英语', 1, true) ~= nil
				or normalized_title:find('英字', 1, true) ~= nil
		end

		return title_contains_label(title, language)
	end

	local function serialize_tracklist(tracklist)
		local items = {}

		if opts.load_command then
			items[#items + 1] = {
				title = t('Load'),
				bold = true,
				italic = false,
				hint = t('open file'),
				value = '{load}',
				actions = opts.download_command
					and {{name = 'download', icon = 'language', label = t('Search online')}}
					or nil,
			}
		end
		if #items > 0 then
			items[#items].separator = true
		end

		local track_prop_index, snd_prop_index = get_props()
		local filename = mp.get_property_native('filename/no-ext')
		local escaped_filename = filename and regexp_escape(filename)
		local first_item_index = #items + 1
		local active_index = nil
		local disabled_item = nil
		local track_actions = nil
		local track_external_actions = {}

		if snd then
			local action = {
				name = 'as_secondary', icon = snd.icon, label = t('Use as secondary') .. ' (shift+enter/click)',
			}
			track_actions = {action}
			table.insert(track_external_actions, action)
		end
		table.insert(track_external_actions, {name = 'reload', icon = 'refresh', label = t('Reload') .. ' (f5)'})
		table.insert(track_external_actions, {name = 'remove', icon = 'delete', label = t('Remove') .. ' (del)'})

		for _, track in ipairs(tracklist) do
			if track.type == opts.type then
				local track_selected = track.selected and track.id == track_prop_index
				local snd_selected = snd and track.id == snd_prop_index

				local language = language_label(track.lang)
				local codec = codec_label(track.codec)
				local channels = channel_label(track['audio-channels'] or track['demux-channel-count'])
				local title = not is_plain_track_title(track.title, track.lang) and trim(track.title or '') or ''
				local title_values = {}
				local hint_values = {}

				if track.external then
					local extension = track.title and track.title:match('%.([^%.]+)$')
					if track.title and escaped_filename and extension then
						track.title = trim(track.title:gsub(escaped_filename .. '%.?', ''):gsub('%.?([^%.]+)$', ''))
						title = not is_plain_track_title(track.title, track.lang) and trim(track.title or '') or ''
					end
				end

				if title ~= '' then title_values[#title_values + 1] = title end
				if language ~= '' and not title_implies_language(title, language) then
					title_values[#title_values + 1] = language
				end

				if opts.type == 'audio' then
					append_title_value(title_values, title, channels)
					append_title_value(title_values, title, codec)
					if track.default then hint_values[#hint_values + 1] = t('default') end
					if track.external then hint_values[#hint_values + 1] = t('external') end
					if track['demux-samplerate'] then hint_values[#hint_values + 1] = string.format('%.3g kHz', track['demux-samplerate'] / 1000) end
					if track['demux-bitrate'] then hint_values[#hint_values + 1] = string.format('%.0f kbps', track['demux-bitrate'] / 1000) end
				else
					append_title_value(title_values, title, codec)
					if track.forced then title_values[#title_values + 1] = t('forced') end
					if track.default then title_values[#title_values + 1] = t('default') end
					if track.external then hint_values[#hint_values + 1] = t('external') end
					if track['demux-h'] then
						hint_values[#hint_values + 1] = track['demux-w']
							and (track['demux-w'] .. 'x' .. track['demux-h'])
							or (track['demux-h'] .. 'p')
					end
					if track['demux-fps'] then hint_values[#hint_values + 1] = string.format('%.5g fps', track['demux-fps']) end
				end

				local display_title = join_values(title_values)
				if display_title == '' then display_title = t('Track %s', track.id) end
				table.insert(hint_values, 1, '#' .. tostring(track.id))

				items[#items + 1] = {
					title = display_title,
					hint = join_values(hint_values, ', '),
					value = track.id,
					active = track_selected or snd_selected,
					italic = snd_selected,
					icon = snd and snd_selected and snd.icon or nil,
					actions = track.external and track_external_actions or track_actions,
				}

				if track_selected then
					if disabled_item then disabled_item.active = false end
					active_index = #items
				end
			end
		end

		return items, active_index or first_item_index
	end

	local function reload(id)
		if id then mp.commandv(opts.type .. '-reload', id) end
	end
	local function remove(id)
		if id then mp.commandv(opts.type .. '-remove', id) end
	end

	---@param event MenuEventActivate
	local function handle_activate(event)
		if event.value == '{load}' then
			mp.command(event.action == 'download' and opts.download_command or opts.load_command)
		else
			if snd and (event.action == 'as_secondary' or event.modifiers == 'shift') then
				local _, snd_track_index = get_props()
				mp.commandv('set', snd.prop, event.value == snd_track_index and 'no' or event.value)
				if snd.enable_prop then
					mp.commandv('set', snd.enable_prop, 'yes')
				end
			elseif event.action == 'reload' then
				reload(event.value)
			elseif event.action == 'remove' then
				remove(event.value)
			elseif not event.modifiers or event.modifiers == 'alt' then
				mp.commandv('set', opts.prop, event.value == get_props() and 'no' or event.value)
				if opts.enable_prop then
					mp.commandv('set', opts.enable_prop, 'yes')
				end
			end
		end
	end

	---@param event MenuEventKey
	local function handle_key(event)
		if event.selected_item then
			if event.id == 'f5' then
				reload(event.selected_item.value)
			elseif event.id == 'del' then
				remove(event.selected_item.value)
			end
		end
	end

	return create_self_updating_menu_opener({
		title = opts.title,
		min_width = 520,
		footnote = t('Toggle to disable.') .. ' ' .. t('Paste path or url to add.'),
		type = opts.type,
		list_prop = 'track-list',
		serializer = serialize_tracklist,
		on_activate = handle_activate,
		on_key = handle_key,
		actions_place = 'outside',
		on_paste = function(event) load_track(opts.type, event.value) end,
	})
end

---@alias NavigationMenuOptions {type: string, title?: string, allowed_types?: string[], file_actions?: MenuAction[], directory_actions?: MenuAction[], active_path?: string, selected_path?: string; allow_url_input?: boolean; on_close?: fun()}

-- Sort state management
local sort_state_file = mp.command_native({'expand-path', '~~/files/uosc_sort_state'})
local sort_mode = 1

do
	local f = io.open(sort_state_file, 'r')
	if f then
		local saved = tonumber(f:read('*l'))
		f:close()
		if saved and saved >= 1 and saved <= 4 then sort_mode = saved end
	end
end

local function save_sort_mode()
	local f = io.open(sort_state_file, 'w')
	if f then f:write(tostring(sort_mode)); f:close() end
end

local function uosc_sort_items(files, directories, path)
	local function sort_reverse(arr)
		local i, j = 1, #arr
		while i < j do arr[i], arr[j] = arr[j], arr[i]; i, j = i + 1, j - 1 end
	end

	if sort_mode <= 2 then
		sort_strings(directories)
		sort_strings(files)
		if sort_mode == 2 then sort_reverse(directories); sort_reverse(files) end
	else
		local cache = {}
		local function get_mtime(item)
			if cache[item] then return cache[item] end
			local info = utils.file_info(join_path(path, item))
			local mtime = info and info.mtime or 0
			cache[item] = mtime
			return mtime
		end
		local function date_sort(arr, desc)
			table.sort(arr, function(a, b)
				local at, bt = get_mtime(a), get_mtime(b)
				if at == bt then return a:lower() < b:lower() end
				if desc then return at > bt else return at < bt end
			end)
		end
		local desc = sort_mode == 4
		date_sort(directories, desc)
		date_sort(files, desc)
	end
end

-- Opens a file navigation menu with items inside `directory_path`.
---@param directory_path string
---@param handle_activate fun(event: MenuEventActivate)
---@param opts NavigationMenuOptions
function open_file_navigation_menu(directory_path, handle_activate, opts)
	local url_list = dofile(mp.command_native({
		'expand-path', '~~/script-modules/url-list.lua',
	}))
	if directory_path == '{drives}' then
		if state.platform ~= 'windows' then directory_path = '/' end
	else
		directory_path = normalize_path(mp.command_native({'expand-path', directory_path}))
	end

	opts = opts or {}
	---@type string|nil
	local current_directory = nil
	---@type Menu
	local menu
	---@type string | nil
	local back_path
	local url_input_active = false

	local function create_url_input_item()
		return {
			title = '打开视频 / 直播链接',
			hint = 'B站 · 抖音 · 斗鱼 · 虎牙 · m3u8',
			value = '__open_url__',
			separator = true,
		}
	end

	---@param path string Can be path to a directory, or special string `'{drives}'` to get windows drives items.
	---@param selected_path? string Marks item with this path as active.
	---@return MenuStackChild[] menu_items
	---@return number selected_index
	---@return string|nil error
	local function serialize_items(path, selected_path)
		if path == '{drives}' then
			local process = mp.command_native({
				name = 'subprocess',
				capture_stdout = true,
				playback_only = false,
				args = {'fsutil', 'fsinfo', 'drives'},
			})
			local items, selected_index = {}, 1
			if opts.allow_url_input then items[#items + 1] = create_url_input_item() end

			if process.status == 0 then
				for drive in process.stdout:gmatch('(%a:)\\') do
					if drive then
						local drive_path = normalize_path(drive)
						items[#items + 1] = {
							title = drive, hint = t('drive'), value = drive_path, active = opts.active_path == drive_path,
						}
						if selected_path == drive_path then selected_index = #items end
					end
				end
			else
				return {}, 1, 'Couldn\'t open drives. Error: ' .. utils.to_string(process.stderr)
			end
			return items, selected_index
		end

		local serialized = serialize_path(path)
		if not serialized then
			return {}, 0, 'Couldn\'t serialize path "' .. path .. '.'
		end
		local files, directories, error = read_directory(serialized.path, {
			types = opts.allowed_types,
			hidden = options.show_hidden_files,
		})
		if error then
			return {}, 1, error
		end
		local is_root = not serialized.dirname

		if not files or not directories then return {}, 0 end

		uosc_sort_items(files, directories, path)

		-- Pre-populate items with parent directory selector if not at root
		-- Each item value is a serialized path table it points to.
		local items = {}
		if opts.allow_url_input then items[#items + 1] = create_url_input_item() end

		-- Sort mode selector (compact)
		local sort_labels = {'名称 ↑', '名称 ↓', '日期 ↑', '日期 ↓'}
		items[#items + 1] = {
			title = '排序: ' .. sort_labels[sort_mode],
			hint = '点击切换排序方式',
			value = '__sort__' .. (sort_mode % 4 + 1),
			keep_open = true,
		}
		if is_root then
			if state.platform == 'windows' then
				items[#items + 1] = {title = '..', hint = t('Drives'), value = '{drives}', separator = true, is_to_parent = true}
			end
		else
			items[#items + 1] = {title = '..', hint = t('parent dir'), value = serialized.dirname, separator = true, is_to_parent = true}
		end

		back_path = items[#items] and items[#items].value
		local selected_index = #items + 1

		for _, dir in ipairs(directories) do
			items[#items + 1] = {
				title = dir,
				value = join_path(path, dir),
				bold = true,
				actions = opts
					.directory_actions,
			}
		end

		for _, file in ipairs(files) do
			items[#items + 1] = {title = file, value = join_path(path, file), actions = opts.file_actions}
		end

		for index, item in ipairs(items) do
			if not item.is_to_parent then
				if opts.active_path == item.value then
					item.active = true
					if not selected_path then selected_index = index end
				end

				if selected_path == item.value then selected_index = index end
			end
		end

		return items, selected_index
	end

	local menu_data = {
		type = opts.type,
		title = opts.title or '',
		footnote = t('%s to go up in tree.', 'alt+up') .. ' 支持 B站、抖音、斗鱼、虎牙与媒体直链。',
		items = {},
		on_paste = 'callback',
	}

	---@param path string
	local function open_directory(path)
		local returning_from_url_input = url_input_active
		url_input_active = false
		if returning_from_url_input and menu and menu.current.search then menu:search_cancel() end
		local items, selected_index, error = serialize_items(path, current_directory)
		if error then
			msg.error(error)
			items = {{title = 'Something went wrong. See console for errors.', selectable = false, muted = true}}
		end

		local title = opts.title
		if not title then
			if path == '{drives}' then
				title = 'Drives'
			else
				local serialized = serialize_path(path)
				title = serialized and serialized.basename or '??'
			end
		end

		current_directory = path
		menu_data.title = title
		menu_data.items = items
		menu:search_cancel()
		menu:update(menu_data)
		menu:select_index(selected_index)
		menu:scroll_to_index(selected_index, nil, true)
	end

	local function open_url_input()
		url_input_active = true
		menu:update({
			type = opts.type,
			title = '粘贴或输入视频 / 直播链接',
			search_style = 'palette',
			search_debounce = 'submit',
			on_search = 'callback',
			on_search_action = 'callback',
			search_action = {
				name = 'paste_url',
				icon = 'content_paste',
				label = '粘贴剪贴板并播放',
			},
			search_focus_indicator = false,
			search_cursor_blink = true,
			search_icon_margin = 5,
			search_placeholder_left_align = true,
			content_padding_bottom = 5,
			back_on_escape = true,
			footnote = '支持 B站视频/直播、抖音/斗鱼/虎牙直播和媒体直链；一行一个；Esc 返回',
			items = {
				{
					title = 'B站 · 抖音 · 斗鱼 · 虎牙 · HTTP(S) · Enter 导入',
					value = '__url_input_help__',
					selectable = false,
					muted = true,
					opacity = 0.64,
					align = 'center',
					hide_separator = true,
				},
			},
		})
	end

	local function close()
		menu:close()
		if opts.on_close then opts.on_close() end
	end

	local function submit_url_text(text)
		local urls, parse_error = url_list.parse(text)
		if not urls then
			mp.commandv('show-text', parse_error, 4000)
			return false
		end
		handle_activate({type = 'activate', value = urls[1], urls = urls, action = 'open_url_list'})
		return true
	end

	---@param event MenuEventActivate
	---@param only_if_dir? boolean Activate item only if it's a directory.
	local function activate(event, only_if_dir)
		local path = event.value
		local is_sort = path:match('^__sort__')
		local is_drives = path == '{drives}'
		local is_url_input = path == '__open_url__'
		local is_paste_url = path == '__paste_url__'

		if is_url_input then
			open_url_input()
			return
		end

		if is_paste_url then
			local text = trim(get_clipboard() or '')
			if text == '' then
				mp.commandv('show-text', '剪贴板中没有可用的视频链接', 3000)
			else
				submit_url_text(text)
			end
			return
		end

		if is_sort then
			sort_mode = tonumber(path:match('^__sort__(%d)')) or sort_mode
			save_sort_mode()
			open_directory(current_directory)
			return
		end

		if is_drives then
			open_directory(path)
			return
		end

		local info, error = utils.file_info(path)

		if not info then
			msg.error('Can\'t retrieve path info for "' .. path .. '". Error: ' .. (error or ''))
			return
		end

		if info.is_dir and not event.modifiers and not event.action then
			open_directory(path)
		elseif not only_if_dir then
			handle_activate(event)
		end
	end

	menu = Menu:open(menu_data, function(event)
		if event.type == 'activate' then
			activate(event --[[@as MenuEventActivate]])
		elseif event.type == 'search_action' and url_input_active and event.action == 'paste_url' then
			activate({type = 'activate', value = '__paste_url__'})
		elseif event.type == 'back' then
			if url_input_active then
				open_directory(current_directory)
			elseif back_path then
				open_directory(back_path)
			end
		elseif event.type == 'key' and itable_has({'alt+up', 'left'}, event.id) then
			if back_path then open_directory(back_path) end
		elseif event.type == 'paste' then
			local pasted = trim(event.value or '')
			if pasted:match('^https?://') or pasted:find('[\r\n]') then
				submit_url_text(pasted)
			else
				handle_activate({type = 'activate', value = pasted})
			end
		elseif event.type == 'search' and url_input_active then
			local text = trim(event.query or '')
			if text ~= '' then submit_url_text(text) end
		elseif event.type == 'key' then
			if event.id == 'right' then
				local selected_item = event.selected_item
				if selected_item then
					activate(table_assign({}, selected_item, {type = 'activate'}), true)
				end
			elseif event.id == 'ctrl+c' and event.selected_item then
				set_clipboard(event.selected_item.value)
			end
		elseif event.type == 'close' then
			close()
		end
	end)

	open_directory(directory_path)

	return menu
end

-- On demand menu items loading
do
	---@type {key: string; cmd: string; comment: string; is_menu_item: boolean}[]|nil
	local all_user_bindings = nil
	---@type MenuStackItem[]|nil
	local menu_items = nil
	local executable_availability = {}

	local function is_uosc_menu_comment(v) return v:match('^!') or v:match('^menu:') end

	local function is_executable_available(executable)
		if executable_availability[executable] ~= nil then
			return executable_availability[executable]
		end

		local is_windows = package.config:sub(1, 1) == '\\'
		local candidates = {executable}
		if is_windows and not executable:lower():match('%.exe$') then
			candidates[#candidates + 1] = executable .. '.exe'
		end

		local function candidate_exists(path)
			local meta = utils.file_info(path)
			return meta and meta.is_file
		end

		local available = false
		for _, candidate in ipairs(candidates) do
			if candidate_exists(candidate) then
				available = true
				break
			end
		end

		if not available then
			local executable_path = mp.get_property_native('executable-path')
			local executable_dir = executable_path and select(1, utils.split_path(executable_path)) or nil
			if executable_dir and executable_dir ~= '' then
				for _, candidate in ipairs(candidates) do
					if candidate_exists(utils.join_path(executable_dir, candidate)) then
						available = true
						break
					end
				end
			end
		end

		if not available then
			local path_separator = is_windows and ';' or ':'
			for directory in (os.getenv('PATH') or ''):gmatch('[^' .. path_separator .. ']+') do
				directory = directory:gsub('^"', ''):gsub('"$', '')
				for _, candidate in ipairs(candidates) do
					if candidate_exists(utils.join_path(directory, candidate)) then
						available = true
						break
					end
				end
				if available then break end
			end
		end

		executable_availability[executable] = available
		return executable_availability[executable]
	end

	local function menu_requirements_met(comments)
		for _, comment in ipairs(comments) do
			local normalized = trim(comment)
			local executable = normalized:match('^requires:%s*(%S+)%s*$')
			if executable and not is_executable_available(executable) then return false end

			local alternatives = normalized:match('^requires%-any:%s*(.-)%s*$')
			if alternatives then
				local available = false
				for candidate in alternatives:gmatch('[^,%s]+') do
					if is_executable_available(candidate) then
						available = true
						break
					end
				end
				if not available then return false end
			end
		end
		return true
	end

	-- Returns all relevant bindings from `input.conf`, even if they are overwritten
	-- (same key bound to something else later) or have no keys (uosc menu items).
	function get_all_user_bindings()
		if all_user_bindings then return all_user_bindings end
		all_user_bindings = {}

		local input_conf_property = mp.get_property_native('input-conf')
		local input_conf_iterator
		if input_conf_property:sub(1, 9) == 'memory://' then
			-- mpv.net v7
			local input_conf_lines = split(input_conf_property:sub(10), '\n')
			local i = 0
			input_conf_iterator = function()
				i = i + 1
				return input_conf_lines[i]
			end
		else
			local input_conf = input_conf_property == '' and '~~/input.conf' or input_conf_property
			local input_conf_path = mp.command_native({'expand-path', input_conf})
			local input_conf_meta, meta_error = utils.file_info(input_conf_path)

			-- File doesn't exist
			if not input_conf_meta or not input_conf_meta.is_file then
				menu_items = create_default_menu_items()
				return menu_items, all_user_bindings
			end

			input_conf_iterator = io.lines(input_conf_path)
		end

		for line in input_conf_iterator do
			local key, command, comment = string.match(line, '%s*([%S]+)%s+([^#]*)%s*(.-)%s*$')
			local is_commented_out = key and key:sub(1, 1) == '#'

			if comment and #comment > 0 then comment = comment:sub(2) end
			if command then command = trim(command) end

			local is_menu_item = comment and is_uosc_menu_comment(comment)

			if key
				-- Filter out stuff like `#F2`, which is clearly intended to be disabled
				and not (is_commented_out and #key > 1)
				-- Filter out comments that are not uosc menu items
				and (not is_commented_out or is_menu_item) then
				all_user_bindings[#all_user_bindings + 1] = {
					key = key,
					cmd = command,
					comment = comment or '',
					is_menu_item = is_menu_item,
				}
			end
		end

		return all_user_bindings
	end

	function get_menu_items()
		if menu_items then return menu_items end

		local all_user_bindings = get_all_user_bindings()
		local main_menu = {items = {}, items_by_command = {}}
		local by_id = {}

		for _, bind in ipairs(all_user_bindings) do
			local key, command, comment = bind.key, bind.cmd, bind.comment
			local title = ''

			if comment then
				local comments = split(comment, '#')
				if menu_requirements_met(comments) then
					local titles = itable_filter(comments, is_uosc_menu_comment)
					if titles and #titles > 0 then
						title = titles[1]:match('^!%s*(.*)%s*') or titles[1]:match('^menu:%s*(.*)%s*')
					end
				end
			end

			if title ~= '' then
				local is_dummy = key:sub(1, 1) == '#'
				local submenu_id = ''
				local target_menu = main_menu
				local title_parts = split(title or '', ' *> *')

				for index, title_part in ipairs(#title_parts > 0 and title_parts or {''}) do
					if index < #title_parts then
						submenu_id = submenu_id .. title_part

						if not by_id[submenu_id] then
							local items = {}
							by_id[submenu_id] = {items = items, items_by_command = {}}
							target_menu.items[#target_menu.items + 1] = {title = title_part, items = items}
						end

						target_menu = by_id[submenu_id]
					else
						-- If command is already in menu, just append the key to it
						if key ~= '#' and command ~= '' and target_menu.items_by_command[command] then
							local hint = target_menu.items_by_command[command].hint
							local key_human = keybind_to_human(key)
							target_menu.items_by_command[command].hint = hint and hint .. ', ' .. key_human or key_human
						else
							-- Separator
							if title_part:sub(1, 3) == '---' then
								local last_item = target_menu.items[#target_menu.items]
								if last_item then last_item.separator = true end
							elseif command ~= 'ignore' then
								local item = {
									title = title_part,
									hint = not is_dummy and keybind_to_human(key) or nil,
									value = command,
								}
								if command == '' then
									item.selectable = false
									item.muted = true
									item.italic = true
								else
									target_menu.items_by_command[command] = item
								end
								target_menu.items[#target_menu.items + 1] = item
							end
						end
					end
				end
			end
		end

		menu_items = #main_menu.items > 0 and main_menu.items or create_default_menu_items()
		return menu_items
	end
end

-- Adapted from `stats.lua`
function get_keybinds_items()
	local items = {}
	-- uosc and mpv-menu-plugin binds with no keys
	local no_key_menu_binds = itable_filter(
		get_all_user_bindings(),
		function(b) return b.is_menu_item and b.cmd and b.cmd ~= '' and (b.key == '#' or b.key == '_') end
	)
	local binds_dump = itable_join(find_active_keybindings(), no_key_menu_binds)
	local ids = {}

	-- Convert to menu items
	for _, bind in pairs(binds_dump) do
		local id = bind.key .. '<>' .. bind.cmd
		if not ids[id] then
			ids[id] = true
			items[#items + 1] = {title = bind.cmd, hint = keybind_to_human(bind.key) or bind.key, value = bind.cmd}
		end
	end

	-- Sort
	table.sort(items, function(a, b) return a.title < b.title end)

	return #items > 0 and items or {
		{
			title = t('%s are empty', '`input-bindings`'),
			selectable = false,
			align = 'center',
			italic = true,
			muted = true,
		},
	}
end

function open_stream_quality_menu()
	if Menu:is_open('stream-quality') then
		Menu:close()
		return
	end

	local ytdl_format = mp.get_property_native('ytdl-format')
	local items = {}
	---@type Menu
	local menu

	for _, height in ipairs(config.stream_quality_options) do
		local format = 'bestvideo[height<=?' .. height .. ']+bestaudio/best[height<=?' .. height .. ']'
		items[#items + 1] = {title = height .. 'p', value = format, active = format == ytdl_format}
	end

	menu = Menu:open({type = 'stream-quality', title = t('Stream quality'), items = items}, function(event)
		if event.type == 'activate' then
			mp.set_property('ytdl-format', event.value)

			-- Reload the video to apply new format
			-- This is taken from https://github.com/jgreco/mpv-youtube-quality
			-- which is in turn taken from https://github.com/4e6/mpv-reload/
			local duration = mp.get_property_native('duration')
			local time_pos = mp.get_property('time-pos')

			mp.command('playlist-play-index current')

			-- Tries to determine live stream vs. pre-recorded VOD. VOD has non-zero
			-- duration property. When reloading VOD, to keep the current time position
			-- we should provide offset from the start. Stream doesn't have fixed start.
			-- Decent choice would be to reload stream from it's current 'live' position.
			-- That's the reason we don't pass the offset when reloading streams.
			if duration and duration > 0 then
				local function seeker()
					mp.commandv('seek', time_pos, 'absolute')
					mp.unregister_event(seeker)
				end
				mp.register_event('file-loaded', seeker)
			end

			if not event.alt then menu:close() end
		end
	end)
end

function open_open_file_menu()
	if Menu:is_open('open-file') then
		Menu:close()
		return
	end

	---@type Menu | nil
	local menu
	local directory
	local active_file

	if state.path == nil or is_protocol(state.path) then
		directory = options.default_directory
		active_file = nil
	else
		local serialized = serialize_path(state.path)
		if serialized then
			directory = serialized.dirname
			active_file = serialized.path
		end
	end

	if not directory then
		msg.error('Couldn\'t serialize path "' .. state.path .. '".')
		return
	end

	-- Update active file in directory navigation menu
	local function handle_file_loaded()
		if menu and menu:is_alive() then
			menu:activate_one_value(normalize_path(mp.get_property_native('path')))
		end
	end

	menu = open_file_navigation_menu(
		directory,
		function(event)
			if not menu then return end
			if event.action == 'open_url_list' and type(event.urls) == 'table' then
				for index, url in ipairs(event.urls) do
					mp.commandv('loadfile', url, index == 1 and 'replace' or 'append')
				end
				mp.commandv('show-text', string.format('已导入 %d 条视频链接', #event.urls), 3000)
				menu:close()
				return
			end
			local command = event.action == 'open_url'
				and 'loadfile'
				or has_any_extension(event.value, config.types.playlist) and 'loadlist' or 'loadfile'
			if event.modifiers == 'shift' or event.action == 'add_to_playlist' then
				mp.commandv(command, event.value, 'append')
				local serialized = serialize_path(event.value)
				local filename = serialized and serialized.basename or event.value
				mp.commandv('show-text', t('Added to playlist') .. ': ' .. filename, 3000)
			elseif itable_has({nil, 'ctrl', 'alt', 'alt+ctrl'}, event.modifiers)
				and itable_has({nil, 'force_open', 'open_url'}, event.action) then
				mp.commandv(command, event.value)
				if not event.alt then menu:close() end
			end
		end,
		{
			type = 'open-file',
			allowed_types = config.types.media,
			allow_url_input = true,
			active_path = active_file,
			directory_actions = {
				{name = 'add_to_playlist', icon = 'playlist_add', label = t('Add to playlist') .. ' (shift+enter/click)'},
				{name = 'force_open', icon = 'play_circle_outline', label = t('Open in mpv') .. ' (ctrl+enter/click)'},
			},
			file_actions = {
				{name = 'add_to_playlist', icon = 'playlist_add', label = t('Add to playlist') .. ' (shift+enter/click)'},
			},
			keep_open = true,
			on_close = function() mp.unregister_event(handle_file_loaded) end,
		}
	)
	if menu then mp.register_event('file-loaded', handle_file_loaded) end
end

---@param opts {prop: 'sub'|'audio'|'video'; title: string; loaded_message: string; allowed_types: string[]}
function create_track_loader_menu_opener(opts)
	local menu_type = 'load-' .. opts.prop
	return function()
		if Menu:is_open(menu_type) then
			Menu:close()
			return
		end

		---@type Menu
		local menu
		local path = state.path
		if path then
			if is_protocol(path) then
				path = false
			else
				local serialized_path = serialize_path(path)
				path = serialized_path ~= nil and serialized_path.dirname or false
			end
		end
		if not path then
			path = options.default_directory
		end

		local function handle_activate(event)
			load_track(opts.prop, event.value)
			local serialized = serialize_path(event.value)
			local filename = serialized and serialized.basename or event.value
			mp.commandv('show-text', opts.loaded_message .. ': ' .. filename, 3000)
			if not event.alt then menu:close() end
		end

		menu = open_file_navigation_menu(path, handle_activate, {
			type = menu_type, title = opts.title, allowed_types = opts.allowed_types,
		})
	end
end

function open_subtitle_downloader()
	local menu_type = 'download-subtitles'
	---@type Menu
	local menu

	if Menu:is_open(menu_type) then
		Menu:close()
		return
	end

	local search_suggestion, destination_directory = '', nil

	if state.path then
		if is_protocol(state.path) then
			local title = mp.get_property_native('title')
			if title and not is_protocol(title) then search_suggestion = title end
		else
			local serialized_path = serialize_path(state.path)
			if serialized_path then
				search_suggestion = serialized_path.filename
				destination_directory = serialized_path.dirname
			end
		end
	end

	local force_destination = options.subtitles_directory:sub(1, 1) == '!'
	if force_destination or not destination_directory then
		local subtitles_directory = options.subtitles_directory:sub(force_destination and 2 or 1)
		destination_directory = mp.command_native({'expand-path', subtitles_directory})
	end

	local handle_download, handle_search
	local url = 'https://api.opensubtitles.com/api/v1'

	-- Checks if there an error, or data is invalid. If true, reports the error,
	-- updates menu to inform about it, and returns true.
	---@param error string|nil
	---@param data any
	---@param check_is_valid? fun(data: any):boolean
	---@return boolean abort Whether the further response handling should be aborted.
	local function should_abort(error, data, check_is_valid)
		if error or not data or (not check_is_valid or not check_is_valid(data)) then
			menu:update_items({
				{
					title = t('Something went wrong.'),
					align = 'center',
					muted = true,
					italic = true,
					selectable = false,
				},
				{
					title = t('See console for details.'),
					align = 'center',
					muted = true,
					italic = true,
					selectable = false,
				},
			})
			msg.error(error or ('Invalid response: ' .. (utils.format_json(data) or tostring(data))))
			return true
		end
		return false
	end

	---@param data {kind: 'file', id: number}|{kind: 'page', query: string, page: number}
	handle_download = function(data)
		if data.kind == 'page' then
			handle_search(data.query, data.page)
			return
		end

		menu = Menu:open({
			type = menu_type .. '-result',
			search_style = 'disabled',
			items = {{icon = 'spinner', align = 'center', selectable = false, muted = true}},
		}, function(event)
			if event.type == 'key' and event.key == 'enter' then
				menu:close()
			end
		end)

		local download_url = url .. '/download'

		local headers = {
			['Accept'] =  'application/json',
 			['Api-Key'] = config.open_subtitles_api_key,
			['Content-Type'] = 'application/json',
			['User-Agent'] = config.open_subtitles_agent,

 		}

		local body = {
			file_id = data.id
		}

		http_request_async('POST', download_url, headers, body, function(error, data)
			if not menu:is_alive() then return end
			if data and data.link then
				local file_path = utils.join_path(destination_directory, data.file_name)
				local arg = {
					'curl',
					'-sL',
					'--user-agent', config.open_subtitles_agent,
					'-o', file_path,
					data.link
				}

				mp.command_native({
					name = 'subprocess',
					capture_stdout = true,
					capture_stderr = true,
					playback_only = false,
					args = arg
				})
			end

			local function check_is_valid(data)
				local path = data and utils.join_path(destination_directory, data.file_name) or nil
				local meta = path and utils.file_info(path) or nil
				return meta and meta.is_file
			end
			if should_abort(error, data, check_is_valid) then return end

			load_track('sub', utils.join_path(destination_directory, data.file_name))

			menu:update_items({
				{
					title = t('Subtitles loaded & enabled'),
					bold = true,
					icon = 'check',
					selectable = false,
				},
				{
					title = t('Remaining downloads today: %s', data.remaining),
					italic = true,
					muted = true,
					icon = 'file_download',
					selectable = false,
				},
				{
					title = t('Resets in: %s', data.reset_time),
					italic = true,
					muted = true,
					icon = 'schedule',
					selectable = false,
				},
			})
		end)
	end

	---@param query string
	---@param page number|nil
	handle_search = function(query, page)
		if not menu:is_alive() then return end
		page = math.max(1, type(page) == 'number' and round(page) or 1)

		menu:update_items({{icon = 'spinner', align = 'center', selectable = false, muted = true}})

		local languages = itable_filter(get_languages(), function(lang) return lang:match('.json$') == nil end)

		local search_url = string.format('%s/subtitles?query=%s&languages=%s&page=%s', url, url_encode(query),
			table.concat(table_keys(create_set(languages)), ','), tostring(page))

		local headers = {
 			['Api-Key'] = config.open_subtitles_api_key,
			['User-Agent'] = config.open_subtitles_agent,
 		}

		http_request_async('GET', search_url, headers, nil, function(error, data)
			if not menu:is_alive() then return end

			local function check_is_valid(data)
				return data and type(data.data) == 'table' and data.page and data.total_pages
			end
			if should_abort(error, data, check_is_valid) then return end

			local subs = itable_filter(data.data, function(sub)
				return sub and sub.attributes and sub.attributes.release and type(sub.attributes.files) == 'table' and
					#sub.attributes.files > 0
			end)
			local items = itable_map(subs, function(sub)
				local hints = {sub.attributes.language}
				if sub.attributes.foreign_parts_only then hints[#hints + 1] = t('foreign parts only') end
				if sub.attributes.hearing_impaired then hints[#hints + 1] = t('hearing impaired') end
				local url = sub.attributes.url
				return {
					title = sub.attributes.release,
					hint = table.concat(hints, ', '),
					value = {kind = 'file', id = sub.attributes.files[1].file_id, url = url},
					keep_open = true,
					actions = url and
						{{name = 'open_in_browser', icon = 'open_in_new', label = t('Open in browser') .. ' (shift)'}},
				}
			end)

			if #items == 0 then
				items = {
					{title = t('no results'), align = 'center', muted = true, italic = true, selectable = false},
				}
			end

			if data.page > 1 then
				items[#items + 1] = {
					title = t('Previous page'),
					align = 'center',
					bold = true,
					italic = true,
					icon = 'navigate_before',
					keep_open = true,
					value = {kind = 'page', query = query, page = data.page - 1},
				}
			end

			if data.page < data.total_pages then
				items[#items + 1] = {
					title = t('Next page'),
					align = 'center',
					bold = true,
					italic = true,
					icon = 'navigate_next',
					keep_open = true,
					value = {kind = 'page', query = query, page = data.page + 1},
				}
			end

			menu:update_items(items)
		end)
	end

	local initial_items = {
		{title = t('%s to search', 'enter'), align = 'center', muted = true, italic = true, selectable = false},
	}

	menu = Menu:open(
		{
			type = menu_type,
			title = t('enter query'),
			items = initial_items,
			search_style = 'palette',
			on_search = 'callback',
			search_debounce = 'submit',
			search_suggestion = search_suggestion,
			search_submit = search_suggestion and #search_suggestion > 0,
		},
		function(event)
			if event.type == 'activate' then
				if event.action == 'open_in_browser' or event.modifiers == 'shift' then
					local command = ({
						windows = 'explorer',
						linux = 'xdg-open',
						darwin = 'open',
					})[state.platform]
					local url = event.value.url
					mp.command_native_async({
						name = 'subprocess',
						capture_stderr = true,
						capture_stdout = true,
						playback_only = false,
						args = {command, url},
					}, function(success, result, error)
						if not success then
							local err_str = utils.to_string(error or result.stderr)
							msg.error('Error trying to open url "' .. url .. '" in browser: ' .. err_str)
						end
					end)
				elseif not event.action then
					handle_download(event.value)
				end
			elseif event.type == 'search' then
				handle_search(event.query)
			end
		end
	)
end

-- 底栏动画可在同一播放器进程内即时切换，并由主脚本持久化到 uosc.conf。
mp.register_script_message('codex-open-dock-animation-menu', function()
	local current = mp.get_property_native('user-data/uosc/dock-animation-mode') or 'classic'
	local choices = {
		{
			value = 'classic',
			title = '经典 Morph（旧）',
			hint = '默认 · 收起无细线',
		},
		{
			value = 'smooth',
			title = '丝滑 Morph（新）',
			hint = '可选 · 1.2px 已播进度',
		},
	}
	local items = {}
	for _, choice in ipairs(choices) do
		items[#items + 1] = {
			title = choice.title,
			hint = choice.hint,
			active = current == choice.value,
			value = {'script-message-to', 'uosc', 'dock-animation-set', choice.value},
		}
	end
	open_command_menu({
		type = 'codex_dock_animation',
		title = '底栏动画',
		min_width = 400,
		fixed_columns = true,
		items = items,
		footnote = '经典收起无细线；丝滑保留 1.2px 已播进度；不改变鼠标时序',
	})
end)

local video_enhancement_profiles = {
	off = {
		label = '全部关闭', backend = 'auto', hq = 'native', superres = 'off', smooth = 'off',
	},
	balanced = {
		label = '智能推荐', backend = 'auto', hq = 'native', superres = 'auto', smooth = 'auto',
	},
	ai_smooth = {
		label = '4K 流畅优先', backend = 'nvidia_hq', hq = 'uhd_2k',
		superres = 'off', smooth = 'quality',
	},
	clarity = {
		label = 'AI 清晰优先', backend = 'nvidia_hq', hq = 'ai_superres',
		superres = 'quality', smooth = 'performance',
	},
}

mp.register_script_message('codex-set-video-enhancement-profile', function(name)
	local profile = video_enhancement_profiles[tostring(name or '')]
	if not profile then return end
	mp.commandv('script-message-to', 'ai_interpolation', 'set-backend',
		profile.backend, 'silent')
	mp.commandv('script-message-to', 'ai_interpolation', 'set-hq-mode',
		profile.hq, 'silent')
	mp.commandv('script-message-to', 'adaptive_quality', 'set-profile',
		profile.superres, profile.smooth, 'silent')
	mp.add_timeout(0.12, function()
		local restart = mp.get_property_native(
			'user-data/video-enhancement/ai-backend-restart-required') == 'yes'
		mp.osd_message(restart
			and (profile.label .. '已保存\n重启播放器后切换 VF 后端，当前播放链保持稳定')
			or ('视频增强档位：' .. profile.label), restart and 4 or 2.5)
	end)
end)

local video_enhancement_pages = {}
local open_video_enhancement_menu

-- 两阶段视频增强：超分使用 gpu-next GLSL；补帧在安全边界内优先便携
-- RIFE Vulkan，其他场景无感回退 mpv 原生时间插值。
open_video_enhancement_menu = function()
	local superres_mode = mp.get_property_native('user-data/video-enhancement/superres-mode') or 'auto'
	local smooth_mode = mp.get_property_native('user-data/video-enhancement/smooth-mode') or 'auto'
	local source_is_pq = tostring(mp.get_property('video-params/gamma', '')):lower() == 'pq'
	local superres_detail = mp.get_property_native(
		'user-data/video-enhancement/superres-detail'
	) or '等待视频'
	local protect_4k = mp.get_property_native(
		'user-data/video-enhancement/protect-4k'
	) ~= 'no'
	local gpu = mp.get_property_native('user-data/adaptive-quality/gpu') or '检测中'
	local tier = mp.get_property_native('user-data/adaptive-quality/tier') or 'balanced'
	local tier_labels = {
		low = '入门',
		balanced = '均衡',
		medium = '中档',
		high = '高档',
	}
	local choices = {
		off = {
			title = '关闭', superres_title = '关闭', smooth_title = '关闭',
			superres = '不加载画面增强', smooth = '恢复普通播放',
		},
		auto = {
			title = '自动（推荐）', superres_title = '自动（推荐）', smooth_title = '自动（推荐）',
			superres = '按片源和显卡自动增强', smooth = '性能足够时自动 AI 补帧，否则保持稳定',
		},
		performance = {
			title = '性能优先', superres_title = '省性能', smooth_title = '基础平滑',
			superres = '轻量增强，适合入门显卡', smooth = '不生成 AI 中间帧，资源占用更低',
		},
		quality = {
			title = '画质优先', superres_title = '更清晰', smooth_title = 'AI 补帧优先',
			superres = '优先提高细节，性能不足时自动保护',
			smooth = '优先补帧；重型超分冲突时自动换轻量增强',
		},
	}
	local order = {'off', 'auto', 'performance', 'quality'}
	local superres_items = {}
	local smooth_items = {}
	for _, mode in ipairs(order) do
		local choice = choices[mode]
		superres_items[#superres_items + 1] = {
			title = choice.superres_title,
			hint = choice.superres,
			active = superres_mode == mode,
			selectable = true,
			value = {'script-message-to', 'adaptive_quality', 'set-superres', mode},
		}
		smooth_items[#smooth_items + 1] = {
			title = choice.smooth_title,
			hint = choice.smooth,
			active = smooth_mode == mode,
			selectable = true,
			value = {'script-message-to', 'adaptive_quality', 'set-smooth', mode},
		}
	end
	local hq_pack_installed = mp.get_property_native(
		'user-data/video-enhancement/hq-pack-installed') == 'yes'
	local hq_pack_ready = mp.get_property_native(
		'user-data/video-enhancement/hq-pack-ready') == 'yes'
	local hq_rife_ready = mp.get_property_native(
		'user-data/video-enhancement/hq-rife-ready') == 'yes'
	local hq_gpu_supported = mp.get_property_native(
		'user-data/video-enhancement/hq-gpu-supported') == 'yes'
	local hq_status = mp.get_property_native(
		'user-data/video-enhancement/hq-status') or '正在检测高端扩展'
	local backend_mode = mp.get_property_native(
		'user-data/video-enhancement/ai-backend-mode') or 'auto'
	local backend_mode_label = mp.get_property_native(
		'user-data/video-enhancement/ai-backend-mode-label') or '智能自动（推荐）'
	local hq_processing_mode = mp.get_property_native(
		'user-data/video-enhancement/hq-processing-mode') or 'native'
	local hq_processing_mode_label = mp.get_property_native(
		'user-data/video-enhancement/hq-processing-mode-label') or '原生尺寸安全增强'
	local profile_name = backend_mode == 'auto'
		and hq_processing_mode == 'native'
		and superres_mode == 'off' and smooth_mode == 'off' and 'off'
		or backend_mode == 'nvidia_hq' and hq_processing_mode == 'uhd_2k'
		and superres_mode == 'off' and smooth_mode == 'quality' and 'ai_smooth'
		or backend_mode == 'nvidia_hq' and hq_processing_mode == 'ai_superres'
			and superres_mode == 'quality' and smooth_mode == 'performance' and 'clarity'
		or backend_mode == 'auto'
			and hq_processing_mode == 'native'
			and superres_mode == 'auto' and smooth_mode == 'auto' and 'balanced'
		or 'custom'
	local profile_label = video_enhancement_profiles[profile_name]
		and video_enhancement_profiles[profile_name].label or '自定义组合'
	local backend_display_labels = {
		auto = '自动选择',
		nvidia_hq = 'NVIDIA 高画质补帧',
		vulkan = '通用兼容补帧',
	}
	local backend_display_label = backend_display_labels[backend_mode] or backend_mode_label
	local hq_profile_items = {
		{
			title = '智能推荐（推荐）',
			hint = '自动平衡清晰度和流畅度，适合绝大多数视频',
			active = profile_name == 'balanced',
			selectable = true,
			value = {'script-message', 'codex-set-video-enhancement-profile', 'balanced'},
		},
	}
	if hq_pack_ready and hq_gpu_supported then
		hq_profile_items[#hq_profile_items + 1] = {
			title = '4K 流畅优先',
			hint = '4K 显式降至 2K 后增强流畅度；换取实时性能',
			active = profile_name == 'ai_smooth',
			selectable = true,
			value = {'script-message', 'codex-set-video-enhancement-profile', 'ai_smooth'},
		}
		hq_profile_items[#hq_profile_items + 1] = {
			title = 'AI 清晰优先',
			hint = '适合 SDR 低清视频；优先提升画面清晰度',
			active = profile_name == 'clarity',
			selectable = true,
			value = {'script-message', 'codex-set-video-enhancement-profile', 'clarity'},
		}
	end
	hq_profile_items[#hq_profile_items + 1] = {
		title = '全部关闭',
		hint = '关闭画质增强和补帧，恢复普通播放',
		active = profile_name == 'off',
		selectable = true,
		value = {'script-message', 'codex-set-video-enhancement-profile', 'off'},
	}
	local hq_backend_items = {
		{
			title = '自动选择（推荐）',
			hint = '由播放器选择当前设备最合适的补帧方式',
			active = backend_mode == 'auto',
			selectable = true,
			value = {'script-message-to', 'ai_interpolation', 'set-backend', 'auto'},
		},
		{
			title = 'NVIDIA 高画质补帧',
			hint = hq_gpu_supported and 'RTX 40/50 · TensorRT FP16'
				or '当前显卡不支持此高端后端',
			active = backend_mode == 'nvidia_hq',
			selectable = hq_rife_ready and hq_gpu_supported,
			muted = not (hq_rife_ready and hq_gpu_supported),
			value = {'script-message-to', 'ai_interpolation', 'set-backend', 'nvidia_hq'},
		},
		{
			title = '通用兼容补帧',
			hint = '跨显卡方案 · RIFE Vulkan · 保留安全保护',
			active = backend_mode == 'vulkan',
			selectable = true,
			value = {'script-message-to', 'ai_interpolation', 'set-backend', 'vulkan'},
		},
		{
			title = '关闭 AI 补帧',
			hint = '恢复普通平滑，不再生成 AI 中间帧',
			active = smooth_mode == 'performance',
			selectable = true,
			value = {'script-message-to', 'adaptive_quality', 'set-smooth', 'performance'},
		},
	}
	local hq_processing_items = {
		{
			title = '原生尺寸安全增强（推荐）',
			hint = '与基础包一致：不降低源分辨率，按能力启用 TensorRT RIFE',
			active = hq_processing_mode == 'native',
			selectable = true,
			value = {'script-message-to', 'ai_interpolation', 'set-hq-mode', 'native'},
		},
		{
			title = '4K→2K 高性能补帧',
			hint = source_is_pq
				and 'HDR10：原始帧保持 4K，仅中间帧以 2K 推理后还原'
				or '显式质量取舍：4K 等比降至≤2560×1440，再执行 TensorRT RIFE 2×',
			active = hq_processing_mode == 'uhd_2k',
			selectable = hq_pack_ready and hq_gpu_supported,
			muted = not (hq_pack_ready and hq_gpu_supported),
			value = {'script-message-to', 'ai_interpolation', 'set-hq-mode', 'uhd_2k'},
		},
		{
			title = 'AnimeJaNai TensorRT AI 超分',
			hint = 'SDR ≤1920×1080，模型 x2 后按显示尺寸输出；不冒充普通缩放',
			active = hq_processing_mode == 'ai_superres',
			selectable = hq_pack_ready and hq_gpu_supported,
			muted = not (hq_pack_ready and hq_gpu_supported),
			value = {'script-message-to', 'ai_interpolation', 'set-hq-mode', 'ai_superres'},
		},
	}

	local function status_item(title, hint, options)
		options = options or {}
		return {
			title = title,
			hint = hint,
			selectable = false,
			muted = options.muted ~= false,
			separator = options.separator == true,
			interaction_role = 'status',
		}
	end
	local function action_item(title, hint, value, options)
		options = options or {}
		local enabled = options.enabled ~= false
		return {
			title = title,
			hint = hint,
			value = value,
			active = options.active == true,
			selectable = enabled,
			muted = not enabled,
			separator = options.separator == true,
			interaction_role = 'action',
		}
	end

	local source_width = mp.get_property_number('video-params/w', 0) or 0
	local source_height = mp.get_property_number('video-params/h', 0) or 0
	local source_size = source_width > 0 and source_height > 0
		and string.format('%d×%d', source_width, source_height) or nil
	local superres_active = mp.get_property_native(
		'user-data/video-enhancement/superres-active') == 'yes'
	local spatial_reason = tostring(mp.get_property_native(
		'user-data/video-enhancement/spatial-reason-code') or 'detecting')
	local temporal_reason = tostring(mp.get_property_native(
		'user-data/video-enhancement/temporal-reason-code') or 'detecting')
	local smooth_result_kind = tostring(mp.get_property_native(
		'user-data/video-enhancement/smooth-result-kind') or 'source')
	local ai_source_fps = mp.get_property_number(
		'user-data/video-enhancement/ai-source-fps', 0) or 0
	local ai_result_fps = mp.get_property_number(
		'user-data/video-enhancement/ai-result-fps', 0) or 0
	local ai_reason = tostring(mp.get_property_native(
		'user-data/video-enhancement/ai-reason-code') or 'detecting')

	local function compact_fps(value)
		value = tonumber(value) or 0
		if value <= 0 then return nil end
		if math.abs(value - math.floor(value + 0.5)) < 0.005 then
			return tostring(math.floor(value + 0.5))
		end
		return string.format('%.3f', value):gsub('0+$', ''):gsub('%.$', '')
	end
	local function size_transition(detail)
		return tostring(detail or ''):match('(%d+×%d+%s*→%s*%d+×%d+)')
	end
	local function friendly_superres_hint()
		if spatial_reason == 'active-ai-superres'
			or spatial_reason == 'active-managed-shader' or superres_active then
			local transition = size_transition(superres_detail)
			return transition and ('已增强 · ' .. transition) or '已启用画质增强'
		elseif spatial_reason == 'manual-owner' then
			return '使用自定义画质处理'
		elseif spatial_reason == 'user-disabled' or superres_mode == 'off' then
			return source_size and (source_size .. ' · 已关闭') or '已关闭'
		elseif spatial_reason == 'not-needed' then
			return source_size and (source_size .. ' · 当前无需增强') or '当前无需增强'
		elseif not source_size or spatial_reason == 'detecting' then
			return '等待播放视频'
		end
		return '兼容模式 · 保持稳定画质'
	end
	local function friendly_smooth_hint()
		if temporal_reason == 'active-rife' or smooth_result_kind == 'ai-fps' then
			local source_fps = compact_fps(ai_source_fps)
			local result_fps = compact_fps(ai_result_fps)
			return source_fps and result_fps
				and string.format('已补帧 · %s → %s FPS', source_fps, result_fps)
				or 'AI 补帧已启用'
		elseif temporal_reason == 'active-display-resample' then
			return '已平滑显示 · 自动适配刷新率'
		elseif temporal_reason == 'user-disabled' or smooth_mode == 'off' then
			return '已关闭'
		elseif temporal_reason == 'detecting' or not source_size then
			return '等待片源与显示器'
		elseif temporal_reason == 'cadence-not-needed' then
			return '当前无需补帧'
		elseif temporal_reason == 'passthrough-guard' then
			return '已自动保护 · 音频直通'
		elseif temporal_reason == 'uhd-guard' then
			return '已自动保护 · 高分辨率视频'
		elseif temporal_reason == 'speed-guard' then
			return '倍速播放 · 暂停补帧'
		elseif temporal_reason == 'runtime-budget' then
			return '性能不足 · 已自动回退'
		end
		return '兼容模式 · 保持稳定播放'
	end
	local function friendly_protection_hint()
		if temporal_reason == 'uhd-guard' then return '高分辨率保护已触发' end
		if temporal_reason == 'passthrough-guard' then return '音频直通保护已触发' end
		if temporal_reason == 'speed-guard' then return '倍速播放保护已触发' end
		if temporal_reason == 'runtime-budget' then return '性能保护已触发' end
		if ai_reason:find('guard', 1, true) then return '兼容性保护已触发' end
		return '自动保护已启用 · 当前未限制'
	end
	local environment_hint = not hq_pack_installed
		and '内置方案可用 · 未安装完整依赖'
		or not hq_pack_ready
			and ('完整依赖不完整 · ' .. hq_status)
		or hq_gpu_supported
			and '完整依赖可用'
		or '完整依赖已安装 · 当前设备使用兼容方案'
	local processing_display_labels = {
		native = '原生画质（推荐）',
		uhd_2k = '4K→2K 流畅增强',
		ai_superres = 'AI 清晰增强',
	}
	local advanced_items = {
		status_item('设备与性能', string.format('%s · %s',
			gpu, tier_labels[tier] or tier), {muted = false}),
		status_item('运行环境', environment_hint,
			{muted = not (hq_pack_ready and hq_gpu_supported)}),
		status_item('保护状态', friendly_protection_hint()),
	}
	if hq_pack_installed then
		advanced_items[#advanced_items + 1] = action_item('高性能处理',
			processing_display_labels[hq_processing_mode] or hq_processing_mode_label,
			{'script-message', 'codex-open-video-enhancement-full'})
	end
	advanced_items[#advanced_items + 1] = action_item('补帧引擎',
		backend_mode == 'auto' and '自动选择（推荐）' or backend_display_label,
		{'script-message', 'codex-open-video-enhancement-backends'})
	advanced_items[#advanced_items + 1] = action_item('诊断详情',
		'查看实际处理、未生效原因与技术信息',
		{'script-message-to', 'ai_interpolation', 'show-diagnostics'})
	advanced_items[#advanced_items + 1] = action_item('重新检测',
		'安装依赖或更换设备后使用',
		{'script-message', 'codex-refresh-video-enhancement'})
	for _, item in ipairs(advanced_items) do
		if item.interaction_role == 'action' then
			item.separator = true
			break
		end
	end
	video_enhancement_pages = {
		profiles = {
			title = '增强方案',
			items = hq_profile_items,
			footnote = '不确定怎么选就用“智能推荐”；高性能方案只在设备支持时出现',
		},
		full = {
			title = '高性能处理',
			items = hq_processing_items,
			footnote = '仅完整依赖包可用；4K→2K 是用户显式选择，不会由自动档偷偷触发',
		},
		backends = {
			title = '补帧引擎',
			items = hq_backend_items,
			footnote = '普通用户无需修改；播放器始终只启用一种补帧后端',
		},
		superres = {
			title = '画质增强',
			items = superres_items,
			footnote = '不确定怎么选就用“自动（推荐）”',
		},
		smooth = {
			title = '流畅增强',
			items = smooth_items,
			footnote = '不确定怎么选就用“自动（推荐）”；基础平滑不是 AI 补帧',
		},
		advanced = {
			title = '高级设置',
			items = advanced_items,
			footnote = '设备、依赖与技术信息不会改变自动推荐；排查问题时再进入',
		},
	}

	local menu_items = {
		action_item('增强方案', profile_label,
			{'script-message', 'codex-open-video-enhancement-profiles'}),
		action_item('画质增强', friendly_superres_hint(),
			{'script-message', 'codex-open-video-enhancement-superres'}),
		action_item('流畅增强', friendly_smooth_hint(),
			{'script-message', 'codex-open-video-enhancement-smooth'}),
	}
	menu_items[#menu_items + 1] = action_item('高分辨率保护',
		hq_processing_mode == 'uhd_2k'
			and '由“4K→2K 流畅增强”接管'
			or protect_4k and '● 开启（推荐）' or '○ 关闭 · 将尝试更高负载处理',
		{'script-message-to', 'adaptive_quality', 'set-protect-4k', 'toggle'},
		{active = protect_4k, enabled = hq_processing_mode ~= 'uhd_2k'})
	menu_items[#menu_items + 1] = action_item('高级设置',
		'设备、依赖与诊断',
		{'script-message', 'codex-open-video-enhancement-advanced'})

	open_command_menu({
		type = 'codex_video_enhancement',
		title = '超分与补帧',
		min_width = 520,
		selected_index = 1,
		-- Status text carries mixed Latin/CJK model, clock and HDR metadata.
		-- Give that column deliberate room and ellipsize at the readable edge;
		-- a silently clipped first glyph is much harder to understand.
		hint_max_ratio = 0.70,
		hint_fit_ratio = 0.86,
		hint_ellipsis_ratio = 0.78,
		hint_force_ellipsis_when_scaled = true,
		items = menu_items,
		footnote = '保持“智能推荐”即可；播放器会按片源和设备自动保护',
	}, {mouse_nav = true})
end

local function open_video_enhancement_page(page_name)
	local page = video_enhancement_pages[page_name]
	if not page then
		open_video_enhancement_menu()
		return
	end
	local items = {}
	for _, item in ipairs(page.items) do items[#items + 1] = item end
	items[#items + 1] = {
		title = '返回超分与补帧',
		hint = '继续调整其他选项',
		separator = true,
		selectable = true,
		value = {'script-message', 'codex-open-video-enhancement-menu'},
	}
	local selected_index = 1
	for index, item in ipairs(items) do
		if item.selectable ~= false then
			selected_index = index
			break
		end
	end
	open_command_menu({
		type = 'codex_video_enhancement_' .. page_name,
		title = page.title,
		min_width = 520,
		hint_max_ratio = 0.68,
		hint_fit_ratio = 0.84,
		hint_ellipsis_ratio = 0.76,
		hint_force_ellipsis_when_scaled = true,
		selected_index = selected_index,
		items = items,
		footnote = page.footnote,
	}, {mouse_nav = true})
end

local function schedule_video_enhancement_page(page_name)
	mp.add_timeout(0, function() open_video_enhancement_page(page_name) end)
end

mp.register_script_message('codex-open-video-enhancement-menu', function()
	mp.add_timeout(0, open_video_enhancement_menu)
end)
mp.register_script_message('codex-open-video-enhancement-profiles', function()
	schedule_video_enhancement_page('profiles')
end)
mp.register_script_message('codex-open-video-enhancement-full', function()
	schedule_video_enhancement_page('full')
end)
mp.register_script_message('codex-open-video-enhancement-backends', function()
	schedule_video_enhancement_page('backends')
end)
mp.register_script_message('codex-open-video-enhancement-superres', function()
	schedule_video_enhancement_page('superres')
end)
mp.register_script_message('codex-open-video-enhancement-smooth', function()
	schedule_video_enhancement_page('smooth')
end)
mp.register_script_message('codex-open-video-enhancement-advanced', function()
	schedule_video_enhancement_page('advanced')
end)

mp.register_script_message('codex-refresh-video-enhancement', function()
	mp.commandv('script-message-to', 'adaptive_quality', 'refresh')
	mp.commandv('script-message-to', 'ai_interpolation', 'refresh')
	mp.osd_message('视频增强：正在重新检测', 2)
end)

-- 黑位与输出范围：状态行只读；只有明确标为输出模式或诊断的行可点击。
-- 默认不改 Gamma/亮度/对比度，避免把范围错误掩盖成主观“更黑”。
mp.register_script_message('codex-open-black-level-menu', function()
	local function label_range(value)
		value = tostring(value or ''):lower()
		return value == 'full' and 'Full'
			or value == 'limited' and 'Limited'
			or '检测中'
	end
	local requested = mp.get_property_native(
		'user-data/black-level/output-range-mode') or 'auto'
	local source_params = mp.get_property_native('video-params', {})
	local target_params = mp.get_property_native('video-target-params', {})
	local source_range = type(source_params) == 'table' and source_params.colorlevels or 'unknown'
	local target_range = type(target_params) == 'table' and target_params.colorlevels or 'unknown'
	local source_trc = type(source_params) == 'table' and source_params.gamma or 'unknown'
	local target_trc = type(target_params) == 'table' and target_params.gamma or 'unknown'
	local reason = mp.get_property_native('user-data/black-level/reason-code') or 'detecting'
	local detail = mp.get_property_native('user-data/black-level/detail') or '等待视频输出链稳定'
	local manual_equalizer = mp.get_property_native(
		'user-data/black-level/manual-equalizer') == 'yes'
	local brightness = mp.get_property_number('brightness', 0) or 0
	local contrast = mp.get_property_number('contrast', 0) or 0
	local gamma = mp.get_property_number('gamma', 0) or 0
	local status = tostring(mp.get_property_native('user-data/display-info/hdr-status') or 'unknown')
	local items = {
		{
			title = '片源范围',
			hint = label_range(source_range) .. ' · ' .. source_trc,
			selectable = false, interaction_role = 'status',
		},
		{
			title = '实际输出目标',
			hint = label_range(target_range) .. ' · ' .. target_trc,
			selectable = false, interaction_role = 'status',
		},
		{
			title = '输出链', hint = detail,
			selectable = false, interaction_role = 'status',
		},
		{
			title = 'Windows HDR / 决策',
			hint = status .. ' · ' .. reason,
			selectable = false, muted = true, interaction_role = 'status',
		},
		{
			title = '画面调节状态',
			hint = manual_equalizer
				and string.format('已启用 · 亮度 %.2f / 对比度 %.2f / Gamma %.2f',
					brightness, contrast, gamma)
				or '亮度/对比度/Gamma 均为 0 · 未手动修改',
			selectable = false, muted = not manual_equalizer, interaction_role = 'status',
		},
		{
			title = '自动协商（推荐）',
			hint = '由 gpu-next / D3D11 / 系统选择正确输出范围',
			active = requested == 'auto', selectable = true, separator = true,
			interaction_role = 'action',
			value = {'script-message-to', 'hdr_mode', 'set-output-range', 'auto', 'refresh'},
		},
		{
			title = 'RGB Full（0–255）',
			hint = '仅用于明确按 Full 接收的 PC 显示链',
			active = requested == 'full', selectable = true, interaction_role = 'action',
			value = {'script-message-to', 'hdr_mode', 'set-output-range', 'full', 'refresh'},
		},
		{
			title = 'Limited（16–235）',
			hint = '仅用于明确按 Limited 接收的电视/采集链',
			active = requested == 'limited', selectable = true, interaction_role = 'action',
			value = {'script-message-to', 'hdr_mode', 'set-output-range', 'limited', 'refresh'},
		},
		{
			title = '显示完整诊断',
			hint = '显示范围、色彩、VO、HDR、目标黑点与手动画面校正',
			selectable = true, interaction_role = 'action',
			value = {'script-message-to', 'hdr_mode', 'show-black-level-diagnostics'},
		},
	}
	open_command_menu({
		type = 'codex_black_level',
		title = '黑位与输出范围',
		min_width = 600,
		selected_index = 6,
		hint_max_ratio = 0.70,
		hint_fit_ratio = 0.86,
		items = items,
		footnote = 'HDR10 10-bit Limited 基准：64 应与背景同黑，66 应开始闪烁；不要用 Gamma 掩盖范围不匹配',
	}, {mouse_nav = true})
end)

-- ASS/SSA 特效字幕色彩矩阵。默认优先保持脚本中写明的 RGB 原色；
-- 旧字幕仍可按制作环境临时切换 VSFilter 兼容模式。
mp.register_script_message('codex-open-subtitle-color-menu', function()
	local current = mp.get_property('sub-ass-vsfilter-color-compat', 'no')
	local choices = {
		{
			value = 'no',
			title = '原色优先',
			hint = '推荐 · 修复黄/橙色偏红',
		},
		{
			value = 'basic',
			title = '标准兼容',
			hint = 'mpv 默认 · 兼容常见旧字幕',
		},
		{
			value = 'full',
			title = '完整 YCbCr 矩阵',
			hint = '严格读取 ASS 矩阵标记',
		},
		{
			value = 'force-601',
			title = '强制 BT.601',
			hint = '仅用于缺少/写错标记的旧字幕',
		},
	}
	local items = {}
	for _, choice in ipairs(choices) do
		items[#items + 1] = {
			title = choice.title,
			hint = choice.hint,
			active = current == choice.value,
			value = {
				'set',
				'sub-ass-vsfilter-color-compat',
				choice.value,
			},
		}
	end
	open_command_menu({
		type = 'codex_subtitle_color',
		title = '字幕色彩模式',
		items = items,
		footnote = '只影响 ASS/SSA 颜色转换，不改变视频本身色彩',
	})
end)

-- 仅由 mpv-Atmos.exe 成功启动的实验播放器发布状态。
-- 普通 mpv.exe 中入口会在菜单构建时被完全移除。
mp.register_script_message('codex-open-atmos-menu', function()
	if mp.get_property_native('user-data/yaozhi/atmos-mode') ~= 'yes' then
		mp.osd_message('当前未进入 Dolby Atmos 实验模式')
		return
	end
	local status = mp.get_property_native('user-data/yaozhi/atmos-status-label')
		or '实验播放器已进入'
	local detail = mp.get_property_native('user-data/yaozhi/atmos-status-detail')
		or '等待片源'
	open_command_menu({
		type = 'codex_atmos',
		title = 'Dolby Atmos 实验模式',
		items = {
			{
				title = '实验播放器',
				hint = '已进入',
				selectable = false,
				muted = true,
			},
			{
				title = '当前解码状态',
				hint = status,
				selectable = false,
			},
			{
				title = '当前音轨',
				hint = detail,
				selectable = false,
				muted = true,
			},
			{
				title = '失败保护',
				hint = status == '原生回退' and '已接管' or '原生解码自动接管',
				selectable = false,
				muted = true,
			},
			{
				title = '声场对象视图',
				hint = mp.get_property_native('user-data/yaozhi/atmos-overlay')
					== 'yes' and '已开启' or '已关闭',
				value = {
					'script-message-to',
					'yaozhi_atmos_mode',
					'toggle-overlay',
				},
			},
			{
				title = '打开实验组件目录',
				value = {
					'script-message-to',
					'yaozhi_atmos_mode',
					'open-components',
				},
			},
		},
		footnote = '仅此播放器进程启用；普通 mpv.exe 始终使用原生解码',
	})
end)

-- 音乐播放模式。音乐文件进入后台播放逻辑；视频仍保持最小化自动暂停。
mp.register_script_message('codex-open-music-mode-menu', function()
	local current = mp.get_property_native('user-data/music-mode/mode') or 'loop'
	local active = mp.get_property_native('user-data/music-mode/active') == 'yes'
	local detail = mp.get_property_native('user-data/music-mode/detail') or '等待音乐文件'
	local choices = {
		{value = 'loop', title = '列表循环', hint = '按顺序播放'},
		{value = 'random', title = '随机循环', hint = '防重复播放'},
		{value = 'single', title = '单曲循环', hint = '循环当前歌曲'},
		{value = 'off', title = '退出音乐播放模式'},
	}
	local items = {
		{
			title = active and '已进入音乐播放模式' or '未进入音乐播放模式',
			hint = detail,
			selectable = false,
			muted = true,
			italic = true,
		},
	}

	for _, choice in ipairs(choices) do
		items[#items + 1] = {
			title = choice.title,
			hint = choice.hint,
			active = current == choice.value,
			value = {
				'script-message-to',
				'music_mode',
				'set',
				choice.value,
			},
		}
	end

	open_command_menu({
		type = 'codex_music_mode',
		title = '音乐播放模式',
		items = items,
		footnote = '音乐播放模式下支持后台播放，最小化不暂停',
	})
end)

mp.register_script_message('codex-open-audio-passthrough-menu', function()
	local current = mp.get_property_native('user-data/audio-passthrough/mode') or 'off'
	local enabled = mp.get_property_native('user-data/audio-passthrough/enabled') == 'yes'
	local device = mp.get_property_native('user-data/audio-passthrough/device') or 'Windows 默认'
	local audio = mp.get_property_native('user-data/audio-passthrough/audio') or '未加载音轨'
	local choices = {
		{value = 'off', title = '关闭', hint = '普通输出'},
		{value = 'home', title = '开启直通', hint = '推荐'},
		{value = 'dolby', title = '仅 Dolby', hint = '兼容'},
		{value = 'dts', title = '仅 DTS', hint = '兼容'},
	}
	local items = {
		{
			title = '当前状态',
			hint = enabled and '已开启' or '已关闭',
			selectable = false,
			muted = true,
			italic = true,
		},
		{
			title = '输出设备',
			hint = device,
			selectable = false,
			muted = true,
		},
		{
			title = '音轨',
			hint = audio,
			selectable = false,
			muted = true,
		},
	}

	for _, choice in ipairs(choices) do
		items[#items + 1] = {
			title = choice.title,
			hint = choice.hint,
			active = current == choice.value,
			value = {
				'script-message-to',
				'audio_passthrough',
				'set',
				choice.value,
			},
		}
	end

	open_command_menu({
		type = 'codex_audio_passthrough',
		title = '音频直通',
		items = items,
		footnote = '先在 Windows/电视选择 HDMI/eARC 输出',
	})
end)

-- HDR 图形字幕色彩与亮度。PGS 没有可靠的 HDR/SDR 色彩元数据，
-- 默认自动区分 UHD HDR/DV 内封 PGS 与 SDR 图形字幕，并保留手动覆盖。
mp.register_script_message('codex-open-image-subs-brightness-menu', function()
	local supported = mp.get_property_native('user-data/image-subs-brightness/supported') == 'yes'
		or mp.get_property('image-subs-colorspace', '') ~= ''
	local requested = mp.get_property_native('user-data/image-subs-brightness/mode') or 'auto'
	local effective = mp.get_property_native('user-data/image-subs-brightness/effective-mode') or 'video'
	local reason = mp.get_property_native('user-data/image-subs-brightness/reason') or ''
	local current = tonumber(mp.get_property_native('user-data/image-subs-brightness/peak'))
		or tonumber(mp.get_property('image-subs-hdr-peak', ''))
		or 203
	current = math.floor(current + 0.5)
	local effective_peak = mp.get_property_native('user-data/image-subs-brightness/effective-peak')
		or (effective == 'video' and 'video' or tostring(current))

	local presets = {
		{value = 150, title = '柔和', hint = '暗室或高亮屏幕'},
		{value = 203, title = '标准', hint = '推荐 · SDR 参考白'},
		{value = 250, title = '明亮', hint = '适度增强'},
		{value = 300, title = '高亮', hint = '明亮环境'},
		{value = 400, title = '较强', hint = '大面积白字幕可能刺眼'},
	}
	local mode_choices = {
		{value = 'auto', title = '自动判断（推荐）', hint = 'UHD 内封→随视频；其它→SDR'},
		{value = 'video', title = '随视频（HDR 原生）', hint = 'UHD Blu-ray HDR PGS'},
		{value = 'sdr', title = 'SDR / sRGB', hint = '外置 / SDR 图形字幕'},
	}
	local effective_label = effective == 'video' and '随视频（HDR 原生）' or 'SDR / sRGB'
	local current_label = requested == 'auto'
		and ('当前：自动 → ' .. effective_label)
		or ('当前：' .. effective_label)
	local items = {
		{
			title = supported
				and current_label
				or '当前核心不支持独立调节',
			hint = supported and reason or nil,
			selectable = false,
			muted = true,
			italic = true,
		},
	}

	for _, choice in ipairs(mode_choices) do
		items[#items + 1] = {
			title = choice.title,
			hint = choice.hint,
			active = supported and requested == choice.value,
			selectable = supported,
			muted = not supported,
			value = {
				'script-message-to',
				'image_subs_brightness',
				'set-mode',
				choice.value,
			},
		}
	end

	items[#items + 1] = {
		title = 'SDR 参考白亮度',
		hint = effective_peak == 'video' and '当前随视频 HDR 元数据' or (current .. ' nits'),
		selectable = false,
		muted = true,
		italic = true,
	}

	for _, preset in ipairs(presets) do
		items[#items + 1] = {
			title = string.format('%s · %d nits', preset.title, preset.value),
			hint = preset.hint,
			active = supported and current == preset.value,
			selectable = supported,
			muted = not supported,
			value = {
				'script-message-to',
				'image_subs_brightness',
				'set',
				tostring(preset.value),
			},
		}
	end

	open_command_menu({
		type = 'codex_image_subs_brightness',
		title = 'HDR 图形字幕色彩与亮度',
		items = items,
		footnote = supported
			and '随视频模式保留正片 HDR 元数据；选择亮度档位会切换到 SDR 图形字幕，不影响视频、ASS 与 OSD'
			or '需要配套的 mpv-Yaozhi 自编译核心',
	})
end)

-- 杳知HDR - 安全 HDR 输出与峰值亮度菜单
mp.register_script_message('codex-open-peak-menu', function()
	-- When this page replaces the command tree, preserve how that tree was
	-- opened. Mouse activation must start neutral so the first row cannot open
	-- merely because it appears under the click; keyboard activation keeps its
	-- normal first-row selection. Direct script-message opens default to neutral.
	local source_menu = Menu:is_open()
	local mouse_nav = source_menu and source_menu.mouse_nav
	if mouse_nav == nil then mouse_nav = true end
	local force_active = mp.get_property('user-data/hdr-mode/manual-force', 'no') == 'yes'
	local output_mode = mp.get_property('user-data/hdr-mode/output-mode', 'auto')
	local force_sdr = output_mode == 'sdr'
	local hdr_supported_raw = mp.get_property_native('user-data/display-info/hdr-supported')
	local hdr_status = tostring(mp.get_property_native('user-data/display-info/hdr-status') or '')
	local gamma = mp.get_property('video-params/gamma', ''):lower()
	local source_is_hdr = gamma == 'pq' or gamma == 'hlg'
	local target_gamma = mp.get_property('video-target-params/gamma', ''):lower()
	local output_is_hdr = target_gamma == 'pq' or target_gamma == 'hlg'
	local hdr_supported = hdr_supported_raw == true or hdr_supported_raw == 1
		or hdr_supported_raw == '1' or hdr_supported_raw == 'yes'
		or hdr_supported_raw == 'true' or hdr_status == 'on' or hdr_status == 'off'
		or output_is_hdr
	local hdr_unsupported = not output_is_hdr and (hdr_supported_raw == false or hdr_supported_raw == 'false'
		or hdr_status == 'unsupported'
	)
	local can_force_hdr = source_is_hdr and not force_sdr and not hdr_unsupported
	local can_adjust_peak = not force_sdr and (force_active or output_is_hdr
		or (source_is_hdr and hdr_supported and not hdr_unsupported))
	local current_raw = mp.get_property('target-peak', 'auto')
	local current_number = tonumber(current_raw)
	local current_label = current_number
		and (math.floor(current_number + 0.5) .. ' nits') or '自动'
	local presets = {200, 300, 400, 500, 600, 800, 1000, 1200, 1500, 2000, 4000}
	local unavailable_hint
	if not source_is_hdr then
		unavailable_hint = '当前片源为 SDR'
	elseif hdr_unsupported then
		unavailable_hint = '当前屏幕不支持 HDR · 请使用 HDR→SDR'
	elseif not hdr_supported then
		unavailable_hint = 'HDR 能力尚未确认'
	elseif not output_is_hdr and hdr_status ~= 'on' then
		unavailable_hint = '屏幕尚未进入 HDR'
	end
	local items = {}
	items[#items + 1] = {
		title = '播放器输出模式',
		hint = force_sdr and 'HDR→SDR（不改系统）' or '自动选择 HDR/SDR',
		items = {
			{
				title = '自动选择 HDR/SDR（默认）',
				hint = '按片源和显示能力自动输出',
				value = {'script-message-to', 'hdr_mode', 'set-output-mode', 'auto', 'refresh'},
				active = not force_sdr,
			},
			{
				title = '播放器 HDR→SDR',
				hint = '只转换本播放器画面，不修改 Windows HDR',
				value = {'script-message-to', 'hdr_mode', 'set-output-mode', 'sdr', 'refresh'},
				active = force_sdr,
			},
		},
	}
	items[#items + 1] = {
		title = '强制 HDR 直出',
		hint = force_sdr and '已启用播放器 HDR→SDR · 请先恢复自动'
			or force_active and '已开启 · 仅当前视频'
			or (unavailable_hint or (output_is_hdr and '自动 HDR 已生效' or '异常设备兜底')),
		value = {'script-message-to', 'hdr_mode', 'manual-force-toggle', 'refresh'},
		selectable = force_active or can_force_hdr,
		muted = not (force_active or can_force_hdr),
	}
	if can_adjust_peak then
		items[#items + 1] = {
			title = '当前目标峰值：' .. current_label,
			selectable = false,
			muted = true,
			italic = true,
		}
		items[#items + 1] = {
			title = '自动',
			hint = force_active and '使用系统/显示器报告值' or '使用屏幕检测值',
			value = {'script-message-to', 'hdr_mode', 'manual-force-peak', 'auto', 'refresh'},
			active = not current_number,
		}
		for _, val in ipairs(presets) do
			items[#items + 1] = {
				title = val .. ' nits',
				value = {'script-message-to', 'hdr_mode', 'manual-force-peak', tostring(val), 'refresh'},
				active = current_number and math.floor(current_number + 0.5) == val,
			}
		end
	else
		items[#items + 1] = {
			title = 'HDR 峰值亮度',
			hint = force_sdr and '播放器 HDR→SDR 不需要设置'
				or '仅支持 HDR 的屏幕直出时可调',
			selectable = false,
			muted = true,
		}
	end
	local footnote = '默认自动选择；播放器 HDR→SDR 只改视频渲染，不改 Windows HDR 开关'
	if force_sdr then
		footnote = 'HDR 片源由 gpu-next 映射到 BT.709/gamma2.2/203 nit；Windows HDR 保持原状'
	elseif force_active then
		footnote = '强制模式关闭时会完整恢复自动设置'
	elseif not source_is_hdr then
		footnote = '仅 PQ/HLG HDR 片源可使用强制输出'
	elseif hdr_unsupported then
		footnote = '当前为 SDR 屏：HDR 直出与峰值手动调节已禁用，HDR→SDR 仍可正常使用'
	elseif unavailable_hint then
		footnote = '显示能力尚未确认，暂不强制 HDR 直出'
	else
		footnote = '选择峰值会自动启用强制 HDR，并在关闭时恢复'
	end
	open_command_menu({
		type = 'codex_peak',
		title = 'HDR 输出与峰值亮度',
		items = items,
		footnote = footnote,
	}, {mouse_nav = mouse_nav})
end)

