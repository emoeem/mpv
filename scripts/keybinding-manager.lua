local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local script_name = mp.get_script_name()
local MENU_MAIN = 'yaozhi_keybindings'
local MENU_DETAIL = 'yaozhi_keybinding_detail'
local MENU_CAPTURE = 'yaozhi_keybinding_capture'
local MENU_CONFLICT = 'yaozhi_keybinding_conflict'
local CAPTURE_SECTION = 'yaozhi_keybinding_capture_input'
local CONFIG_PATH = mp.command_native({
    'expand-path', '~~/script-opts/yaozhi-keybindings.json'
})
local BACKUP_PATH = CONFIG_PATH .. '.bak'
local TEMP_PATH = CONFIG_PATH .. '.tmp'

local data = {version = 1, overrides = {}}
local config_warning = nil
local visible_entries = {}
local selected_entry = nil
local pending_capture = nil
local pending_conflict = nil
local capture_section_active = false
local capture_timer = nil
local capture_arm_timer = nil
local capture_finalize_timer = nil
local capture_candidate = nil
local applied_binding_names = {}
local is_safe_keyboard_key

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$')
end

local function file_exists(path)
    local info = utils.file_info(path)
    return info ~= nil and info.is_file
end

local function read_all(path)
    local file, err = io.open(path, 'rb')
    if not file then return nil, err end
    local content = file:read('*a')
    file:close()
    return content
end

local function write_all(path, content)
    local file, err = io.open(path, 'wb')
    if not file then return false, err end
    local ok, write_err = file:write(content)
    if not ok then
        file:close()
        return false, write_err
    end
    file:flush()
    file:close()
    return true
end

local function parse_config(path)
    local content, read_err = read_all(path)
    if not content then return nil, read_err end
    local parsed, parse_err = utils.parse_json(content)
    if type(parsed) ~= 'table' or type(parsed.overrides) ~= 'table' then
        return nil, parse_err or 'JSON 结构无效'
    end
    parsed.version = tonumber(parsed.version) or 1
    return parsed
end

local function load_config()
    if not file_exists(CONFIG_PATH) then return end
    local parsed, parse_err = parse_config(CONFIG_PATH)
    if parsed then
        data = parsed
        return
    end

    local backup = file_exists(BACKUP_PATH) and parse_config(BACKUP_PATH) or nil
    if backup then
        data = backup
        config_warning = '托管按键文件损坏，已只读恢复上一版；本次未改动 input.conf'
        msg.error(config_warning .. ': ' .. tostring(parse_err))
    else
        data = {version = 1, overrides = {}}
        config_warning = '托管按键文件损坏，已停用全部托管改动；input.conf 未受影响'
        msg.error(config_warning .. ': ' .. tostring(parse_err))
    end
end

-- The only writable file in this script is yaozhi-keybindings.json. input.conf
-- is deliberately opened read-only everywhere. Save through a verified temp
-- file and keep the previous valid generation as .bak.
local function save_config(candidate)
    if config_warning then
        return false, config_warning .. '；为保护备份，已拒绝继续写入托管文件'
    end
    local sanitized = {version = 1, overrides = {}}
    for _, record in ipairs(candidate.overrides or {}) do
        local new_key = trim(record.new_key)
        if not is_safe_keyboard_key(new_key) then
            return false, '目标不是可保存的键盘快捷键：' .. tostring(new_key)
        end
        sanitized.overrides[#sanitized.overrides + 1] = {
            source_key = trim(record.source_key),
            source_command = trim(record.source_command),
            new_key = new_key,
            title = trim(record.title),
            replaced_command = trim(record.replaced_command),
            replaced_owner = trim(record.replaced_owner),
        }
    end
    candidate = sanitized
    local serialized, json_err = utils.format_json(candidate)
    if not serialized then return false, json_err or '无法生成 JSON' end

    local wrote, write_err = write_all(TEMP_PATH, serialized)
    if not wrote then return false, '无法写入临时文件：' .. tostring(write_err) end

    local verified, verify_err = parse_config(TEMP_PATH)
    if not verified then
        os.remove(TEMP_PATH)
        return false, '临时文件校验失败：' .. tostring(verify_err)
    end

    local had_current = file_exists(CONFIG_PATH)
    if had_current then
        if file_exists(BACKUP_PATH) then
            local removed, remove_err = os.remove(BACKUP_PATH)
            if not removed then
                os.remove(TEMP_PATH)
                return false, '无法轮换安全备份：' .. tostring(remove_err)
            end
        end
        local backed_up, backup_err = os.rename(CONFIG_PATH, BACKUP_PATH)
        if not backed_up then
            os.remove(TEMP_PATH)
            return false, '无法创建安全备份：' .. tostring(backup_err)
        end
    end

    local replaced, replace_err = os.rename(TEMP_PATH, CONFIG_PATH)
    if not replaced then
        if had_current then os.rename(BACKUP_PATH, CONFIG_PATH) end
        os.remove(TEMP_PATH)
        return false, '无法原子替换托管文件：' .. tostring(replace_err)
    end

    data = verified
    config_warning = nil
    return true
end

local function canonical_key(key)
    key = trim(key)
    if key == '' then return '' end
    local modifiers, base = {}, nil
    for part in key:gmatch('[^+]+') do
        local upper = part:upper()
        if upper == 'CTRL' or upper == 'ALT' or upper == 'SHIFT' or upper == 'META' then
            modifiers[upper] = true
        else
            base = part
        end
    end
    if not base then return key end
    if #base > 1 and base:match('^[%w_%-]+$') then base = base:upper() end
    local result = {}
    for _, modifier in ipairs({'CTRL', 'ALT', 'SHIFT', 'META'}) do
        if modifiers[modifier] then result[#result + 1] = modifier end
    end
    result[#result + 1] = base
    return table.concat(result, '+')
end

-- The binding editor intentionally accepts keyboard keys only. Synthetic and
-- pointer events such as UNMAPPED/MOUSE_MOVE are not stable shortcuts and must
-- never reach the persistent managed layer.
is_safe_keyboard_key = function(key)
    key = canonical_key(key)
    if key == '' then return false end
    local base = key:match('([^+]+)$') or key
    local upper = base:upper()
    if upper == 'CTRL' or upper == 'ALT' or upper == 'SHIFT' or upper == 'META'
        or upper == 'UNMAPPED' or upper == 'ANY_UNICODE' or upper == 'CLOSE_WIN'
        or upper == 'MOUSE_MOVE' or upper == 'MOUSE_ENTER' or upper == 'MOUSE_LEAVE'
        or upper:match('^MOUSE_') or upper:match('^MBTN')
        or upper:match('^WHEEL_') or upper:match('^AXIS_')
        or upper:match('^GAMEPAD_') or upper:match('^JOY')
        or upper:match('^TOUCH_') or upper:match('^GESTURE_') then
        return false
    end
    return true
end

local key_labels = {
    SPACE = '空格', ENTER = '回车', ESC = 'Esc', TAB = 'Tab', BS = '退格',
    DEL = '删除', INS = '插入', HOME = 'Home', END = 'End', PGUP = 'Page Up',
    PGDWN = 'Page Down', LEFT = '左方向键', RIGHT = '右方向键', UP = '上方向键',
    DOWN = '下方向键', WHEEL_UP = '滚轮向上', WHEEL_DOWN = '滚轮向下',
    WHEEL_LEFT = '滚轮向左', WHEEL_RIGHT = '滚轮向右', MBTN_LEFT = '鼠标左键',
    MBTN_RIGHT = '鼠标右键', MBTN_MID = '鼠标中键', MBTN_BACK = '鼠标后退键',
    MBTN_FORWARD = '鼠标前进键',
    ['`'] = '反引号 `（不含 Shift）',
    ['~'] = '波浪号 ~（Shift + 反引号）',
}

local function human_key(key)
    local parts = {}
    for part in canonical_key(key):gmatch('[^+]+') do
        if part == 'CTRL' then parts[#parts + 1] = 'Ctrl'
        elseif part == 'ALT' then parts[#parts + 1] = 'Alt'
        elseif part == 'SHIFT' then parts[#parts + 1] = 'Shift'
        elseif part == 'META' then parts[#parts + 1] = 'Win'
        else parts[#parts + 1] = key_labels[part] or part end
    end
    return table.concat(parts, ' + ')
end

local command_labels = {
    ['cycle pause'] = '播放 / 暂停',
    ['cycle fullscreen'] = '切换全屏',
    ['playlist-next'] = '播放下一个文件',
    ['playlist-prev'] = '播放上一个文件',
    ['quit'] = '退出程序',
    ['quit-watch-later'] = '保存进度并退出',
    ['stop'] = '停止播放',
    ['ignore'] = '禁用此按键',
    ['ab-loop'] = '设置 / 清除片段循环',
    ['screenshot subtitles'] = '截取带字幕画面',
    ['screenshot video'] = '截取无字幕画面',
    ['script-message-to disc_menu root'] = '回蓝光菜单根目录',
    ['script-message-to disc_menu popup'] = '显示 / 隐藏蓝光弹出菜单',
}

local function leaf_menu_title(comment)
    comment = trim(comment)
    local path = comment:match('^menu:%s*(.-)%s*$') or comment:match('^!%s*(.-)%s*$')
    if not path then return nil end
    path = path:gsub('%s+#requires.-$', '')
    local leaf = nil
    for part in path:gmatch('[^>]+') do leaf = trim(part) end
    return leaf ~= '' and leaf or nil
end

local function friendly_title(command, comment, owner)
    local menu_title = leaf_menu_title(comment)
    if menu_title then return menu_title end
    comment = trim(comment)
    if comment ~= '' and not comment:match('^requires[:%-]') then
        return comment:gsub('%s+#requires.-$', '')
    end
    command = trim(command)
    if command_labels[command] then return command_labels[command] end
    if command:match('^seek%s+%-') then return '后退播放进度' end
    if command:match('^seek%s+') then return '前进播放进度' end
    if command:match('add%s+volume%s+%-') then return '降低音量' end
    if command:match('add%s+volume%s+') then return '提高音量' end
    if command:match('^cycle%s+sub') then return '切换字幕' end
    if command:match('^cycle%s+audio') then return '切换音轨' end
    local script, action = command:match('^script%-message%-to%s+([^%s]+)%s+([^;%s]+)')
    if script then
        action = tostring(action or ''):gsub('[_%-]+', ' ')
        return '脚本功能：' .. script .. (action ~= '' and (' / ' .. action) or '')
    end
    local binding = command:match('^script%-binding%s+(.+)$')
    if binding then return '脚本功能：' .. binding end
    return owner and owner ~= '' and ('动态功能：' .. owner) or '自定义命令'
end

local function input_conf_path()
    local configured = mp.get_property_native('input-conf') or ''
    if configured == '' then configured = '~~/input.conf' end
    return mp.command_native({'expand-path', configured})
end

local function read_input_conf()
    local path = input_conf_path()
    local file, err = io.open(path, 'rb')
    if not file then return {}, {}, path, err end
    local entries, by_key = {}, {}
    for line in file:lines() do
        line = line:gsub('^\239\187\191', '')
        local key, command, comment = line:match('%s*([%S]+)%s+([^#]*)%s*(.-)%s*$')
        if key and key:sub(1, 1) ~= '#' then
            command = trim(command)
            -- Scoped bindings such as {discnav} only exist while the core has
            -- enabled that section. A global managed override would leak them
            -- into ordinary playback, so keep those core navigation keys out
            -- of the editable list. The two always-safe Blu-ray entry points
            -- (root/popup) are ordinary input.conf bindings and remain fully
            -- searchable and editable through the managed JSON layer.
            if command ~= '' and not command:match('^%b{}%s+') then
                comment = trim(comment)
                if comment:sub(1, 1) == '#' then comment = trim(comment:sub(2)) end
                local entry = {
                    key = canonical_key(key),
                    command = command,
                    comment = comment,
                    title = friendly_title(command, comment, 'input.conf'),
                    source = 'input.conf',
                    editable = true,
                }
                by_key[entry.key] = entry
            end
        end
    end
    file:close()
    for _, entry in pairs(by_key) do entries[#entries + 1] = entry end
    return entries, by_key, path, nil
end

local function active_bindings(excluded_owner)
    local active = {}
    for _, binding in ipairs(mp.get_property_native('input-bindings') or {}) do
        local key = canonical_key(binding.key)
        local owner = tostring(binding.owner or '')
        if key ~= '' and owner ~= excluded_owner and tonumber(binding.priority or -1) >= 0 then
            local previous = active[key]
            if not previous
                or (previous.is_weak and not binding.is_weak)
                or (previous.is_weak == binding.is_weak
                    and tonumber(binding.priority or -1) > tonumber(previous.priority or -1)) then
                active[key] = {
                    key = key,
                    command = trim(binding.cmd),
                    owner = owner,
                    priority = tonumber(binding.priority or -1),
                    is_weak = binding.is_weak,
                }
            end
        end
    end
    return active
end

local function find_override(source_key, source_command, records)
    for index, record in ipairs(records or data.overrides) do
        if canonical_key(record.source_key) == canonical_key(source_key)
            and trim(record.source_command) == trim(source_command) then
            return record, index
        end
    end
    return nil, nil
end

local function remove_applied_bindings()
    for _, name in ipairs(applied_binding_names) do pcall(mp.remove_key_binding, name) end
    applied_binding_names = {}
end

local function register_managed_binding(key, name, callback)
    local ok, err = pcall(mp.add_forced_key_binding, key, name, callback)
    if ok then applied_binding_names[#applied_binding_names + 1] = name end
    return ok, err
end

local function apply_overrides()
    remove_applied_bindings()
    local _, source_by_key = read_input_conf()
    local effective = active_bindings(script_name)
    local claimed_targets = {}

    for index, record in ipairs(data.overrides) do
        record.status = nil
        local source_key = canonical_key(record.source_key)
        local new_key = canonical_key(record.new_key)
        local source_command = trim(record.source_command)
        local source = source_by_key[source_key]
        local source_effective = effective[source_key]

        if not source or source.command ~= source_command then
            record.status = '原始绑定已变化，未应用'
        elseif not source_effective or source_effective.command ~= source_command then
            record.status = '原按键当前被其他功能占用，未应用'
        elseif not is_safe_keyboard_key(new_key) then
            record.status = '目标按键无效，未应用'
        elseif claimed_targets[new_key] then
            record.status = '与另一条托管改动冲突，未应用'
        else
            local occupied = effective[new_key]
            local replaced_command = trim(record.replaced_command)
            local target_is_source = new_key == source_key
            local occupancy_matches = target_is_source
                or not occupied
                or occupied.command == source_command
                or (replaced_command ~= '' and occupied.command == replaced_command)

            if not occupancy_matches then
                record.status = '目标按键后来发生变化，未应用'
            else
                local prefix = script_name .. '/managed-' .. tostring(index)
                local source_ok = true
                if not target_is_source then
                    source_ok = register_managed_binding(source_key, prefix .. '-source', function() end)
                end
                local target_ok = source_ok and register_managed_binding(new_key, prefix .. '-target', function()
                    local ok, command_err = pcall(mp.command, source_command)
                    if not ok then msg.error('托管按键执行失败：' .. tostring(command_err)) end
                end)
                if target_ok then
                    record.status = '已应用'
                    claimed_targets[new_key] = true
                    effective[source_key] = {command = '', owner = script_name}
                    effective[new_key] = {command = source_command, owner = script_name}
                else
                    record.status = '注册托管按键失败，未应用'
                    remove_applied_bindings()
                    break
                end
            end
        end
    end
end

local function menu_open(menu)
    local json, err = utils.format_json(menu)
    if not json then
        mp.osd_message('无法打开按键菜单：' .. tostring(err), 3)
        return
    end
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end

local function menu_close(menu_type)
    mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
end

local function build_entries()
    local entries = read_input_conf()
    local managed_source = {}
    for _, record in ipairs(data.overrides) do
        managed_source[canonical_key(record.source_key)] = record
    end

    for _, entry in ipairs(entries) do
        local record = managed_source[entry.key]
        if record and trim(record.source_command) == entry.command then
            entry.override = record
            entry.effective_key = record.status == '已应用' and canonical_key(record.new_key) or entry.key
        else
            entry.effective_key = entry.key
        end
    end

    table.sort(entries, function(a, b)
        local a_managed = a.override ~= nil
        local b_managed = b.override ~= nil
        if a_managed ~= b_managed then return a_managed end
        if a.title == b.title then return a.effective_key < b.effective_key end
        return a.title < b.title
    end)
    return entries
end

local function refreshed_entry(source)
    for _, entry in ipairs(build_entries()) do
        if entry.key == source.key and entry.command == source.command then return entry end
    end
    return source
end

local function open_main_menu()
    visible_entries = build_entries()
    local items = {}
    local managed_count = 0
    for _, entry in ipairs(visible_entries) do
        if entry.override then managed_count = managed_count + 1 end
    end
    if config_warning then
        items[#items + 1] = {
            title = config_warning,
            icon = 'warning',
            selectable = false,
            italic = true,
            muted = true,
        }
    end
    local added_other_header = false
    for index, entry in ipairs(visible_entries) do
        if index == 1 and managed_count > 0 then
            items[#items + 1] = {
                title = '已修改的按键（' .. tostring(managed_count) .. '）',
                icon = 'edit',
                selectable = false,
                muted = true,
            }
        elseif not entry.override and managed_count > 0 and not added_other_header then
            items[#items + 1] = {
                title = '其他按键',
                selectable = false,
                muted = true,
            }
            added_other_header = true
        end
        local status = entry.override and entry.override.status or nil
        local hint = human_key(entry.effective_key)
        if status == '已应用' then
            hint = human_key(entry.effective_key) .. ' · 原 ' .. human_key(entry.key)
        elseif status then hint = human_key(entry.key) .. ' · ' .. status end
        items[#items + 1] = {
            title = entry.override and ('已修改 · ' .. entry.title) or entry.title,
            hint = hint,
            icon = entry.override and 'edit' or (entry.editable and 'keyboard' or 'lock'),
            active = status == '已应用',
            value = index,
        }
    end
    if #visible_entries == 0 then
        items[#items + 1] = {title = '未读取到按键绑定', selectable = false, muted = true}
    end
    menu_open({
        id = MENU_MAIN,
        type = MENU_MAIN,
        title = '快捷键管理',
        footnote = '输入中文可搜索 · 回车查看详情 · 修改保存到独立托管层，input.conf 始终只读',
        search_style = 'palette',
        fixed_columns = true,
        callback = {script_name, 'menu-event'},
        items = items,
    })
end

local function open_detail_menu(entry)
    selected_entry = entry
    local status = entry.override and entry.override.status or '未修改'
    local items = {
        {title = '当前按键', hint = human_key(entry.effective_key), selectable = false},
        {title = '配置来源', hint = entry.source .. (entry.editable and '（只读）' or '（不可编辑）'), selectable = false},
        {title = '托管状态', hint = status, selectable = false},
        {title = '原始命令', hint = entry.command, selectable = false},
    }
    if entry.editable then
        items[#items + 1] = {
            title = '修改按键（安全托管）',
            hint = '不会写入 input.conf',
            icon = 'edit',
            value = 'rebind',
        }
        if entry.override then
            items[#items + 1] = {
                title = '恢复原按键',
                hint = human_key(entry.key),
                icon = 'restore',
                value = 'restore',
            }
        else
            items[#items + 1] = {
                title = '恢复原按键',
                hint = '当前未修改，无需恢复',
                icon = 'restore',
                selectable = false,
                muted = true,
            }
        end
    end
    items[#items + 1] = {title = '返回列表', icon = 'arrow_back', value = 'back'}
    menu_open({
        id = MENU_DETAIL,
        type = MENU_DETAIL,
        title = entry.title,
        footnote = '原配置只读；托管改动可随时恢复',
        search_style = 'disabled',
        callback = {script_name, 'menu-event'},
        items = items,
    })
end

local function open_capture_menu(entry)
    menu_open({
        id = MENU_CAPTURE,
        type = MENU_CAPTURE,
        title = '按下新的键盘快捷键',
        footnote = 'Esc 取消 · 12 秒自动取消 · 完整拦截按下与松开，不会执行原功能',
        search_style = 'disabled',
        callback = {script_name, 'menu-event'},
        items = {
            {title = '正在修改', hint = entry.title, selectable = false},
            {title = '当前按键', hint = human_key(entry.effective_key), selectable = false},
            {
                title = '等待键盘输入…',
                hint = '松开按键后保存；修改只进入安全托管层',
                icon = 'keyboard',
                selectable = false,
                active = true,
            },
            {title = '取消修改', icon = 'close', value = 'cancel'},
        },
    })
end

local function cleanup_capture()
    if capture_section_active then
        pcall(mp.commandv, 'disable-section', CAPTURE_SECTION)
        pcall(mp.commandv, 'define-section', CAPTURE_SECTION, '', 'force')
        capture_section_active = false
    end
    if capture_timer then capture_timer:kill(); capture_timer = nil end
    if capture_arm_timer then capture_arm_timer:kill(); capture_arm_timer = nil end
    if capture_finalize_timer then capture_finalize_timer:kill(); capture_finalize_timer = nil end
    capture_candidate = nil
end

local function current_conflict(new_key, source_entry)
    new_key = canonical_key(new_key)
    if new_key == source_entry.key then return nil end
    for _, record in ipairs(data.overrides) do
        if canonical_key(record.new_key) == new_key
            and not (canonical_key(record.source_key) == source_entry.key
                and trim(record.source_command) == source_entry.command) then
            return {
                command = trim(record.source_command),
                owner = '另一条托管改动',
                title = record.title or '另一项功能',
            }
        end
    end
    local effective = active_bindings(script_name)
    local occupied = effective[new_key]
    if occupied and occupied.command ~= source_entry.command then
        occupied.title = friendly_title(occupied.command, '', occupied.owner)
        return occupied
    end
    return nil
end

local function commit_rebind(entry, new_key, occupied)
    if not is_safe_keyboard_key(new_key) then
        mp.osd_message('未识别到有效键盘快捷键，已取消\ninput.conf 未改动', 3)
        mp.add_timeout(0.05, function() open_detail_menu(refreshed_entry(entry)) end)
        return false
    end
    local candidate = {version = 1, overrides = {}}
    for _, record in ipairs(data.overrides) do
        candidate.overrides[#candidate.overrides + 1] = record
    end
    local record, index = find_override(entry.key, entry.command, candidate.overrides)
    if new_key == entry.key then
        if index then table.remove(candidate.overrides, index) end
    else
        local replacement = {
            source_key = entry.key,
            source_command = entry.command,
            new_key = canonical_key(new_key),
            title = entry.title,
            replaced_command = occupied and occupied.command or '',
            replaced_owner = occupied and occupied.owner or '',
        }
        if index then candidate.overrides[index] = replacement
        else candidate.overrides[#candidate.overrides + 1] = replacement end
    end
    local saved, save_err = save_config(candidate)
    if not saved then
        mp.osd_message('按键修改未保存\n' .. tostring(save_err) .. '\ninput.conf 未受影响', 5)
        return false
    end
    apply_overrides()
    mp.osd_message('按键已安全保存：' .. human_key(new_key)
        .. '\n对应功能：' .. entry.title
        .. '\ninput.conf 未改动，可在列表中恢复', 5)
    mp.add_timeout(0.05, function() open_detail_menu(refreshed_entry(entry)) end)
    return true
end

local function open_conflict_menu(entry, new_key, occupied)
    pending_conflict = {entry = entry, new_key = new_key, occupied = occupied}
    menu_open({
        id = MENU_CONFLICT,
        type = MENU_CONFLICT,
        title = '按键冲突：' .. human_key(new_key),
        footnote = '替换仅在托管层生效，恢复后原绑定自动回来',
        search_style = 'disabled',
        callback = {script_name, 'menu-event'},
        items = {
            {title = '当前功能', hint = occupied.title or occupied.command, selectable = false},
            {title = '仍然替换（可撤销）', icon = 'warning', value = 'replace'},
            {title = '重新选择按键', icon = 'keyboard', value = 'recapture'},
            {title = '取消', icon = 'close', value = 'cancel'},
        },
    })
end

local function finish_captured_key(entry, key)
    cleanup_capture()
    pending_capture = nil
    menu_close(MENU_CAPTURE)
    key = canonical_key(key)
    if key == 'ESC' or not is_safe_keyboard_key(key) then
        mp.osd_message('已取消修改；input.conf 未改动', 2)
        mp.add_timeout(0.05, function() open_detail_menu(refreshed_entry(entry)) end)
        return
    end
    local occupied = current_conflict(key, entry)
    if occupied then open_conflict_menu(entry, key, occupied)
    else commit_rebind(entry, key, nil) end
end

local function schedule_capture_finish(entry, key, delay)
    if capture_finalize_timer then capture_finalize_timer:kill() end
    capture_finalize_timer = mp.add_timeout(delay, function()
        capture_finalize_timer = nil
        if pending_capture == entry and capture_candidate == key then
            finish_captured_key(entry, key)
        end
    end)
end

-- A physical key is a down/repeat/up cycle. Keep every temporary forced
-- binding alive until that cycle is over, so neither the old shortcut nor a
-- conflicting shortcut can run while the user is entering the new key.
local function capture_key_event(entry, key, info)
    if pending_capture ~= entry then return end
    local event = info and info.event or 'press'

    if capture_candidate and capture_candidate ~= key then return end
    if event == 'up' then
        if capture_candidate == key then schedule_capture_finish(entry, key, 0.03) end
        return
    end

    if not capture_candidate then
        capture_candidate = key
        if capture_timer then capture_timer:kill(); capture_timer = nil end
    end

    if event == 'repeat' then
        -- Normally key-up finishes capture. This fallback only handles a lost
        -- release event, and is refreshed by every repeat while the key is held.
        schedule_capture_finish(entry, key, 5)
    elseif event == 'down' then
        schedule_capture_finish(entry, key, 5)
    else
        -- IPC keypress and a few keyboard backends report a complete press
        -- without a separate up event. Defer cleanup past the current dispatch.
        schedule_capture_finish(entry, key, 0.03)
    end
end

local function install_capture_bindings()
    local keys = mp.get_property_native('input-key-list') or {}
    if type(keys) ~= 'table' or #keys == 0 then
        keys = {'SPACE', 'ENTER', 'TAB', 'BS', 'DEL', 'LEFT', 'RIGHT', 'UP', 'DOWN',
            'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'}
    end
    -- input-key-list only exposes named keys on current mpv builds; ordinary
    -- printable characters are represented through ANY_UNICODE and therefore
    -- were missing from the first capture section. Add exact ASCII bindings so
    -- existing shortcuts such as k/H/D cannot fall through to input.conf.
    for byte = string.byte('a'), string.byte('z') do
        keys[#keys + 1] = string.char(byte)
        keys[#keys + 1] = string.char(byte):upper()
    end
    for digit = 0, 9 do keys[#keys + 1] = tostring(digit) end
    local seen = {}
    local bindings = {}
    local prefixes = {'', 'CTRL+', 'ALT+', 'CTRL+ALT+', 'SHIFT+', 'CTRL+SHIFT+',
        'ALT+SHIFT+', 'CTRL+ALT+SHIFT+'}
    local function add_capture(candidate)
        candidate = canonical_key(candidate)
        if candidate == '' or seen[candidate] or not is_safe_keyboard_key(candidate) then return end
        seen[candidate] = true
        bindings[#bindings + 1] = candidate .. ' nonscalable script-binding '
            .. script_name .. '/capture-dispatch ' .. candidate
    end
    for _, base in ipairs(keys) do
        base = tostring(base)
        add_capture(base)
        if not base:find('+', 1, true) then
            for index = 2, #prefixes do add_capture(prefixes[index] .. base) end
        end
    end
    -- Keep one text-input wildcard for non-ASCII keyboard characters. The
    -- sentinel itself is never accepted or persisted; capture-dispatch resolves
    -- it to the real mpv key name/text and the save layer validates that result.
    bindings[#bindings + 1] = 'ANY_UNICODE nonscalable script-binding '
        .. script_name .. '/capture-dispatch __ANY_UNICODE__'
    mp.commandv('define-section', CAPTURE_SECTION, table.concat(bindings, '\n'), 'force')
    mp.commandv('enable-section', CAPTURE_SECTION, 'allow-hide-cursor+allow-vo-dragging')
    capture_section_active = true
end

mp.add_key_binding(nil, 'capture-dispatch', function(info)
    local entry = pending_capture
    local raw_key = info and (info.arg or info.key_name) or ''
    if raw_key == '__ANY_UNICODE__' then
        raw_key = info and info.key_name or ''
        if raw_key == '' or raw_key:upper() == 'ANY_UNICODE' then
            raw_key = info and info.key_text or ''
        end
    end
    local key = canonical_key(raw_key)
    if entry and key ~= '' then capture_key_event(entry, key, info) end
end, {complex = true})

local function start_capture(entry)
    cleanup_capture()
    pending_capture = entry
    open_capture_menu(entry)
    -- Queue the complete section in the same activation callback. Re-enable
    -- once uosc has committed its foreground menu so this forced section owns
    -- the final keyboard priority before the user can type into that menu.
    install_capture_bindings()
    capture_arm_timer = mp.add_timeout(0.03, function()
        capture_arm_timer = nil
        if pending_capture == entry and not capture_candidate then install_capture_bindings() end
    end)
    capture_timer = mp.add_timeout(12, function()
        cleanup_capture()
        pending_capture = nil
        menu_close(MENU_CAPTURE)
        mp.osd_message('未检测到新按键，已取消；input.conf 未改动', 3)
        mp.add_timeout(0.05, function() open_detail_menu(refreshed_entry(entry)) end)
    end)
end

local function restore_selected(entry)
    local candidate = {version = 1, overrides = {}}
    for _, record in ipairs(data.overrides) do
        if not (canonical_key(record.source_key) == entry.key
            and trim(record.source_command) == entry.command) then
            candidate.overrides[#candidate.overrides + 1] = record
        end
    end
    local saved, save_err = save_config(candidate)
    if not saved then
        mp.osd_message('恢复失败：' .. tostring(save_err) .. '\ninput.conf 未受影响', 4)
        return
    end
    apply_overrides()
    mp.osd_message('已恢复原按键：' .. human_key(entry.key) .. '\ninput.conf 始终未改动', 3)
    mp.add_timeout(0.05, function() open_detail_menu(refreshed_entry(entry)) end)
end

mp.register_script_message('open', open_main_menu)
mp.add_key_binding(nil, 'open', open_main_menu)

mp.register_script_message('menu-event', function(json)
    local event = utils.parse_json(json)
    if type(event) ~= 'table' or event.type ~= 'activate' or event.action then return end
    if event.menu_id == MENU_MAIN then
        local entry = visible_entries[tonumber(event.value) or -1]
        if entry then open_detail_menu(entry) end
    elseif event.menu_id == MENU_DETAIL and selected_entry then
        if event.value == 'rebind' then start_capture(selected_entry)
        elseif event.value == 'restore' then restore_selected(selected_entry)
        elseif event.value == 'back' then open_main_menu() end
    elseif event.menu_id == MENU_CAPTURE and pending_capture then
        local entry = pending_capture
        cleanup_capture()
        pending_capture = nil
        menu_close(MENU_CAPTURE)
        mp.osd_message('已取消修改；input.conf 未改动', 2)
        mp.add_timeout(0.05, function() open_detail_menu(refreshed_entry(entry)) end)
    elseif event.menu_id == MENU_CONFLICT and pending_conflict then
        local conflict = pending_conflict
        pending_conflict = nil
        if event.value == 'replace' then
            commit_rebind(conflict.entry, conflict.new_key, conflict.occupied)
        elseif event.value == 'recapture' then
            start_capture(conflict.entry)
        else
            mp.osd_message('已取消修改；input.conf 未改动', 2)
            open_detail_menu(conflict.entry)
        end
    end
end)

mp.register_event('start-file', function()
    if pending_capture then
        cleanup_capture()
        pending_capture = nil
        menu_close(MENU_CAPTURE)
    end
    pending_conflict = nil
end)

mp.register_event('shutdown', cleanup_capture)

load_config()
mp.add_timeout(0.8, apply_overrides)
