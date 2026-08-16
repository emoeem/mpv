--[[
    manager.lua - safely check and update selected mpv extensions.

    Sources are configured in ~~ /manager.json. Each source uses a bare mirror
    in ~~ /.manager. "check" sources are never installed automatically.
    "replace" sources are staged, backed up, and replaced only when their
    upstream tree differs from the local tree.
]]

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local function join(...)
    return table.concat({...}, '/')
end

local function trim(value)
    local text = tostring(value or '')
    text = text:gsub('^%s+', '')
    text = text:gsub('%s+$', '')
    return text
end

local function short_commit(commit)
    return commit and commit:sub(1, 8) or 'unknown'
end

local function ass_escape(value)
    local text = tostring(value or '')
    text = text:gsub('\\', '\\\\')
    text = text:gsub('{', '\\{')
    text = text:gsub('}', '\\}')
    return text
end

local root = trim(mp.command_native({'expand-path', '~~/'})):gsub('/+$', '')
local store = join(root, '.manager')
local backup_store = join(store, 'backups')
local staging_store = join(store, 'staging')
local worktree_store = join(store, 'worktrees')
local state_path = join(store, 'state.json')

local running = false
local shutting_down = false
local active_async = nil
local worker = nil
local resume_worker

local progress_osd = mp.create_osd_overlay('ass-events')
progress_osd.res_x = 1280
progress_osd.res_y = 720
progress_osd.z = 2000

local hide_timer = mp.add_timeout(4, function()
    progress_osd:remove()
end)
hide_timer:kill()

local colors = {
    base = '2e1e1e',
    surface = '443231',
    text = 'f4d6cd',
    blue = 'fab489',
    green = 'a1e3a6',
    yellow = 'afe2f9',
    red = 'a88bf3',
}

local function say(level, text)
    msg[level](text)
end

local function draw_rect(ax, ay, bx, by, color, alpha)
    return string.format(
        '{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}'
            .. 'm %d %d l %d %d l %d %d l %d %d{\\p0}',
        color, alpha or '00', ax, ay, bx, ay, bx, by, ax, by
    )
end

local function set_manager_properties(source, status, ratio)
    mp.set_property_bool('user-data/manager/running', running)
    mp.set_property_number('user-data/manager/progress', math.floor(ratio * 100 + 0.5))
    mp.set_property('user-data/manager/source', source or '')
    mp.set_property('user-data/manager/status', status or '')
end

local function show_progress(index, total, source, status, stage, tone)
    local ratio = total > 0 and math.max(0, math.min(1, ((index - 1) + stage) / total)) or 0
    local accent = colors[tone or 'blue'] or colors.blue
    local box_ax, box_ay, box_bx, box_by = 330, 590, 950, 676
    local bar_ax, bar_ay, bar_bx, bar_by = box_ax + 22, box_by - 22, box_bx - 22, box_by - 12
    local fill_bx = bar_ax + math.floor((bar_bx - bar_ax) * ratio)
    local heading = string.format('SCRIPT MANAGER  %d/%d', math.min(index, total), total)
    local detail = source and source ~= '' and (source .. '  ' .. status) or status
    if #detail > 78 then detail = detail:sub(1, 75) .. '...' end

    progress_osd.data = table.concat({
        draw_rect(box_ax, box_ay, box_bx, box_by, colors.base, '18'),
        draw_rect(bar_ax, bar_ay, bar_bx, bar_by, colors.surface, '00'),
        fill_bx > bar_ax and draw_rect(bar_ax, bar_ay, fill_bx, bar_by, accent, '00') or '',
        string.format(
            '{\\an7\\pos(%d,%d)\\fnSans\\fs22\\b1\\bord0\\shad0\\1c&H%s&}%s',
            box_ax + 22, box_ay + 16, colors.text, ass_escape(heading)
        ),
        string.format(
            '{\\an7\\pos(%d,%d)\\fnSans\\fs18\\bord0\\shad0\\1c&H%s&}%s',
            box_ax + 22, box_ay + 45, accent, ass_escape(detail)
        ),
    })
    progress_osd:update()
    set_manager_properties(source, status, ratio)
end

local function finish_progress(status, tone)
    running = false
    show_progress(1, 1, '', status, 1, tone)
    set_manager_properties('', status, 1)
    hide_timer:kill()
    hide_timer:resume()
end

local function compact_error(value)
    local detail = trim(value)
    if detail == '' then return nil end
    local lines = {}
    for line in detail:gmatch('[^\r\n]+') do
        lines[#lines + 1] = line
        if #lines == 6 then break end
    end
    detail = table.concat(lines, '\n')
    if #detail > 1200 then detail = detail:sub(1, 1200) .. '...' end
    return detail
end

local function subprocess_result(success, result, error)
    local status = result and result.status or nil
    if success and status == 0 then return true, result.stdout or '' end

    local detail = compact_error(result and result.stderr)
        or compact_error(result and result.stdout)
        or compact_error(error)
        or compact_error(result and result.error)
    if not detail then
        detail = 'subprocess exited with status ' .. tostring(status or 'unknown')
    end
    return false, detail
end

local function command(args)
    if shutting_down then return false, 'update interrupted because mpv is shutting down' end
    if coroutine.running() ~= worker then return false, 'subprocess called outside update worker' end

    active_async = mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        active_async = nil
        if resume_worker then
            resume_worker(subprocess_result(success, result, error))
        end
    end)
    return coroutine.yield()
end

local function exists(path, kind)
    local info = utils.file_info(path)
    return info and (not kind or info.is_dir == (kind == 'dir'))
end

local function safe_relative(path)
    return type(path) == 'string'
        and path ~= ''
        and not path:match('^/')
        and path ~= '..'
        and not path:match('^%.%./')
        and not path:match('/%.%./')
        and not path:match('/%.%.$')
end

local function valid_url(url)
    return type(url) == 'string'
        and (url:match('^https?://') or url:match('^file:///'))
end

local function valid_source(source)
    local mode = source.mode or 'check'
    return type(source.name) == 'string' and source.name:match('^[A-Za-z0-9_-]+$')
        and valid_url(source.url)
        and type(source.branch) == 'string' and source.branch:match('^[A-Za-z0-9._/-]+$')
        and (source.source == '.' or safe_relative(source.source))
        and source.destination ~= '.'
        and safe_relative(source.destination)
        and (mode == 'check' or mode == 'replace')
        and (source.baseline == nil or type(source.baseline) == 'string')
end

local function read_json(path)
    local file, err = io.open(path, 'rb')
    if not file then return nil, err end
    local data = file:read('*a')
    file:close()
    return utils.parse_json(data)
end

local function load_sources()
    local config, err = read_json(join(root, 'manager.json'))
    if not config or type(config.sources) ~= 'table' then
        return nil, 'manager.json must contain a sources array' .. (err and (': ' .. err) or '')
    end
    return config.sources
end

local function load_state()
    local state = read_json(state_path)
    if type(state) ~= 'table' then state = {} end
    if type(state.sources) ~= 'table' then state.sources = {} end
    state.version = 1
    return state
end

local function save_state(state)
    local temporary = state_path .. '.tmp'
    local file, err = io.open(temporary, 'wb')
    if not file then return false, tostring(err) end
    file:write(utils.format_json(state))
    file:write('\n')
    file:close()
    local ok, rename_err = os.rename(temporary, state_path)
    if not ok then
        os.remove(temporary)
        return false, tostring(rename_err)
    end
    return true
end

local function source_state(state, name)
    local entry = state.sources[name]
    if type(entry) ~= 'table' then
        entry = {}
        state.sources[name] = entry
    end
    return entry
end

local function mirror_path(source)
    return join(store, source.name .. '.git')
end

local function timestamp()
    return os.date('%Y%m%d-%H%M%S')
end

local function unique_path(path)
    if not exists(path) then return path end
    local suffix = 1
    while exists(path .. '-' .. suffix) do suffix = suffix + 1 end
    return path .. '-' .. suffix
end

local function move_to_backup(path, name, label)
    if not exists(path) then return nil end
    local directory = join(backup_store, name)
    local ok, output = command({'mkdir', '-p', directory})
    if not ok then return nil, output end
    local backup = unique_path(join(directory, timestamp() .. '-' .. label))
    local moved, move_error = os.rename(path, backup)
    if not moved then return nil, tostring(move_error) end
    return backup
end

local function migrate_legacy_git(source)
    local legacy_git = join(root, source.destination, '.git')
    if not exists(legacy_git) then return true end
    local backup, output = move_to_backup(legacy_git, source.name, 'legacy-git')
    if not backup then return false, output end
    return true, 'backed up legacy Git metadata'
end

local function ensure_mirror(source, index, total)
    local mirror = mirror_path(source)
    show_progress(index, total, source.name, 'checking mirror', 0.12, 'blue')

    if exists(mirror, 'dir') then
        local valid, bare = command({'git', '--git-dir=' .. mirror, 'rev-parse', '--is-bare-repository'})
        if not valid or trim(bare) ~= 'true' then
            local moved, move_error = move_to_backup(mirror, source.name, 'invalid-mirror')
            if not moved then return nil, 'invalid mirror could not be backed up: ' .. tostring(move_error) end
        end
    end

    if not exists(mirror, 'dir') then
        show_progress(index, total, source.name, 'creating mirror', 0.22, 'blue')
        local ok, output = command({'git', 'clone', '--mirror', source.url, mirror})
        if not ok then return nil, output end
    else
        local ok, output = command({'git', '--git-dir=' .. mirror, 'remote', 'get-url', 'origin'})
        if not ok then return nil, 'invalid local mirror: ' .. output end
        if trim(output) ~= source.url then return nil, 'local mirror points to a different remote' end
    end

    show_progress(index, total, source.name, 'fetching upstream', 0.35, 'blue')
    local ref = 'refs/heads/' .. source.branch
    local refspec = '+' .. ref .. ':' .. ref
    local ok, output = command({
        'git', '--git-dir=' .. mirror, 'fetch', '--prune', '--tags', 'origin', refspec,
    })
    if not ok then return nil, output end

    ok, output = command({'git', '--git-dir=' .. mirror, 'rev-parse', '--verify', ref})
    if not ok then return nil, 'fetched branch is unavailable: ' .. output end
    return mirror, trim(output)
end

local function resolve_commit(mirror, ref)
    local ok, output = command({'git', '--git-dir=' .. mirror, 'rev-parse', '--verify', ref .. '^{commit}'})
    if not ok then return nil, output end
    return trim(output)
end

local function resolve_source_tree(mirror, commit, source_path)
    local treeish = source_path == '.' and (commit .. '^{tree}') or (commit .. ':' .. source_path)
    local ok, output = command({'git', '--git-dir=' .. mirror, 'rev-parse', '--verify', treeish})
    if not ok then return nil, output end
    return trim(output)
end

local function hash_directory(mirror, source, destination)
    if not exists(destination, 'dir') then return nil end
    local index_path = unique_path(join(store, 'index-' .. source.name))
    local prefix = {
        'env', 'GIT_INDEX_FILE=' .. index_path, 'git', '-C', destination,
        '--git-dir=' .. mirror, '--work-tree=' .. destination,
    }

    local args = {}
    for _, value in ipairs(prefix) do args[#args + 1] = value end
    args[#args + 1] = 'read-tree'
    args[#args + 1] = '--empty'
    local ok, output = command(args)
    if not ok then os.remove(index_path); return nil, output end

    args = {}
    for _, value in ipairs(prefix) do args[#args + 1] = value end
    args[#args + 1] = 'add'
    args[#args + 1] = '-f'
    args[#args + 1] = '-A'
    args[#args + 1] = '--'
    args[#args + 1] = '.'
    ok, output = command(args)
    if not ok then os.remove(index_path); return nil, output end

    args = {}
    for _, value in ipairs(prefix) do args[#args + 1] = value end
    args[#args + 1] = 'write-tree'
    ok, output = command(args)
    os.remove(index_path)
    if not ok then return nil, output end
    return trim(output)
end

local function check_only(source, mirror, head, state, index, total)
    show_progress(index, total, source.name, 'comparing commits', 0.58, 'blue')
    local entry = source_state(state, source.name)
    local previous = entry.observed
    local baseline = previous
    local baseline_label = previous and short_commit(previous) or nil

    if source.baseline and source.baseline ~= '' then
        local resolved, output = resolve_commit(mirror, source.baseline)
        if not resolved then return false, 'baseline is unavailable: ' .. output, 'error' end
        baseline = resolved
        baseline_label = source.baseline
    end

    entry.mode = 'check'
    entry.observed = head
    entry.baseline = source.baseline
    local saved, save_error = save_state(state)
    if not saved then say('warn', source.name .. ': could not save state: ' .. save_error) end

    if baseline and baseline ~= head then
        local detail = string.format(
            'update available (%s -> %s); check-only, local files preserved',
            baseline_label, short_commit(head)
        )
        show_progress(index, total, source.name, detail, 1, 'yellow')
        return true, detail, 'available'
    end

    if not baseline then
        local detail = 'check baseline initialized at ' .. short_commit(head) .. '; local files preserved'
        show_progress(index, total, source.name, detail, 1, 'green')
        return true, detail, 'initialized'
    end

    local detail = 'no new upstream commit; local files preserved'
    show_progress(index, total, source.name, detail, 1, 'green')
    return true, detail, 'unchanged'
end

local function stage_source(source, mirror, head, index, total)
    local token = source.name .. '-' .. timestamp()
    local worktree = unique_path(join(worktree_store, token))
    local staging = unique_path(join(staging_store, token))

    show_progress(index, total, source.name, 'preparing update', 0.68, 'blue')
    command({'git', '--git-dir=' .. mirror, 'worktree', 'prune'})
    local ok, output = command({'git', '--git-dir=' .. mirror, 'worktree', 'add', '--detach', worktree, head})
    if not ok then return nil, output end

    local checkout_source = source.source == '.' and worktree or join(worktree, source.source)
    if not exists(checkout_source, 'dir') then
        command({'git', '--git-dir=' .. mirror, 'worktree', 'remove', '--force', worktree})
        return nil, 'upstream path does not exist: ' .. source.source
    end

    ok, output = command({'mkdir', '-p', staging})
    if not ok then
        command({'git', '--git-dir=' .. mirror, 'worktree', 'remove', '--force', worktree})
        return nil, output
    end

    show_progress(index, total, source.name, 'staging files', 0.78, 'blue')
    ok, output = command({'cp', '-a', checkout_source .. '/.', staging})
    if ok then
        local staged_git = join(staging, '.git')
        local git_info = utils.file_info(staged_git)
        if git_info then
            if git_info.is_dir then
                ok, output = command({'rm', '-rf', staged_git})
            else
                ok, output = os.remove(staged_git)
                if not ok then output = 'could not remove staged .git metadata: ' .. tostring(output) end
            end
        end
    end

    command({'git', '--git-dir=' .. mirror, 'worktree', 'remove', '--force', worktree})
    if not ok then
        command({'rm', '-rf', staging})
        return nil, output
    end
    return staging
end

local function install_staging(source, destination, staging)
    local parent = destination:match('^(.*)/[^/]+$') or root
    local ok, output = command({'mkdir', '-p', parent})
    if not ok then return nil, output end

    local backup
    if exists(destination) then
        backup, output = move_to_backup(destination, source.name, 'previous')
        if not backup then return nil, 'could not back up current destination: ' .. tostring(output) end
    end

    local installed, install_error = os.rename(staging, destination)
    if not installed then
        if backup then os.rename(backup, destination) end
        return nil, 'could not install staged update: ' .. tostring(install_error)
    end
    return backup
end

local function replace_source(source, mirror, head, state, index, total)
    local destination = join(root, source.destination)
    local entry = source_state(state, source.name)

    show_progress(index, total, source.name, 'comparing file trees', 0.52, 'blue')
    local remote_tree, output = resolve_source_tree(mirror, head, source.source)
    if not remote_tree then return false, output, 'error' end
    local local_tree, hash_error = hash_directory(mirror, source, destination)
    if hash_error then return false, hash_error, 'error' end

    if local_tree == remote_tree then
        entry.mode = 'replace'
        entry.installed = head
        entry.observed = head
        local saved, save_error = save_state(state)
        if not saved then say('warn', source.name .. ': could not save state: ' .. save_error) end
        local detail = 'up to date at ' .. short_commit(head)
        show_progress(index, total, source.name, detail, 1, 'green')
        return true, detail, 'unchanged'
    end

    if local_tree and entry.installed then
        local installed_tree = resolve_source_tree(mirror, entry.installed, source.source)
        if not installed_tree or local_tree ~= installed_tree then
            entry.observed = head
            local saved, save_error = save_state(state)
            if not saved then say('warn', source.name .. ': could not save state: ' .. save_error) end
            local detail = 'local changes detected; automatic replacement skipped'
            show_progress(index, total, source.name, detail, 1, 'yellow')
            return true, detail, 'protected'
        end
    end

    local staging, stage_error = stage_source(source, mirror, head, index, total)
    if not staging then return false, stage_error, 'error' end
    if shutting_down then
        command({'rm', '-rf', staging})
        return false, 'update interrupted because mpv is shutting down', 'error'
    end

    show_progress(index, total, source.name, 'installing update', 0.92, 'blue')
    local backup, install_error = install_staging(source, destination, staging)
    if install_error then
        command({'rm', '-rf', staging})
        return false, install_error, 'error'
    end

    entry.mode = 'replace'
    entry.installed = head
    entry.observed = head
    local saved, save_error = save_state(state)
    if not saved then say('warn', source.name .. ': could not save state: ' .. save_error) end

    local detail = 'updated to ' .. short_commit(head)
    if backup then detail = detail .. '; backup: ' .. backup:gsub('^' .. root .. '/', '~~/') end
    show_progress(index, total, source.name, detail, 1, 'green')
    return true, detail, 'updated'
end

local function process_source(source, state, index, total)
    if not valid_source(source) then return false, 'invalid source entry', 'error' end
    local migrated, migration_detail = migrate_legacy_git(source)
    if not migrated then return false, migration_detail, 'error' end

    local mirror, head_or_error = ensure_mirror(source, index, total)
    if not mirror then return false, head_or_error, 'error' end
    local head = head_or_error
    local ok, detail, kind
    if (source.mode or 'check') == 'replace' then
        ok, detail, kind = replace_source(source, mirror, head, state, index, total)
    else
        ok, detail, kind = check_only(source, mirror, head, state, index, total)
    end
    if ok and migration_detail then detail = detail .. '; ' .. migration_detail end
    return ok, detail, kind
end

local function run_update()
    local sources, load_error = load_sources()
    if not sources then
        say('error', load_error)
        finish_progress('Configuration error', 'red')
        return
    end

    local ok, output = command({'mkdir', '-p', store, backup_store, staging_store, worktree_store})
    if not ok then
        say('error', output)
        finish_progress('Could not prepare update storage', 'red')
        return
    end

    local state = load_state()
    local stats = {updated = 0, available = 0, unchanged = 0, initialized = 0, protected = 0, error = 0}
    say('info', 'checking ' .. #sources .. ' source(s)...')

    for index, source in ipairs(sources) do
        if shutting_down then
            stats.error = stats.error + 1
            break
        end
        local name = type(source.name) == 'string' and source.name or '<unnamed>'
        local source_ok, detail, kind = process_source(source, state, index, #sources)
        if source_ok then
            stats[kind] = (stats[kind] or 0) + 1
            local level = (kind == 'available' or kind == 'protected') and 'warn' or 'info'
            say(level, name .. ': ' .. detail)
        else
            stats.error = stats.error + 1
            say('error', name .. ': ' .. detail)
            show_progress(index, #sources, name, detail, 1, 'red')
        end
    end

    local summary = string.format(
        'Done: %d updated, %d available, %d unchanged, %d protected, %d error',
        stats.updated, stats.available, stats.unchanged + stats.initialized, stats.protected, stats.error
    )
    local tone = stats.error > 0 and 'red'
        or (stats.available + stats.protected > 0 and 'yellow' or 'green')
    say(stats.error > 0 and 'error' or 'info', summary)
    finish_progress(summary, tone)
end

resume_worker = function(...)
    if not worker then return end
    local ok, error_message = coroutine.resume(worker, ...)
    if not ok then
        say('error', 'internal updater error: ' .. tostring(error_message))
        worker = nil
        active_async = nil
        finish_progress('Internal updater error', 'red')
        return
    end
    if coroutine.status(worker) == 'dead' then worker = nil end
end

local function update_all()
    if running then
        say('warn', 'an update check is already running')
        return
    end
    running = true
    hide_timer:kill()
    show_progress(1, 1, '', 'Starting update check', 0, 'blue')
    worker = coroutine.create(run_update)
    resume_worker()
end

mp.set_property_bool('user-data/manager/running', false)
mp.set_property_number('user-data/manager/progress', 0)
mp.register_script_message('manager-update-all', update_all)
mp.register_event('shutdown', function()
    shutting_down = true
    if active_async then mp.abort_async_command(active_async) end
    progress_osd:remove()
end)
