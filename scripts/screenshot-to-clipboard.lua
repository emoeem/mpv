--- Copy the current screenshot to the clipboard as an image.
---
--- Backends (selected with mp.get_property('platform'), never by "does the tool exist"):
---   wayland  wl-copy --type image/png            (PNG file redirected to stdin)
---   x11      xclip -selection clipboard -t image/png -i <file>
---   windows  PowerShell + System.Windows.Forms.Clipboard::SetImage (STA)
---   darwin   osascript "set the clipboard to (read (POSIX file ...) as «class PNGf»)"
---
--- A PNG is written to a temporary file with screenshot-to-file, copied as *image*
--- data, then removed. Every failure path reports a readable reason on the OSD.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local function platform()
    return tostring(mp.get_property('platform') or '')
end

local function notify(text, duration)
    msg.warn(text)
    mp.osd_message(text, duration or 3)
end

-- Linux is split into Wayland/X11 the same way the session is: WAYLAND_DISPLAY
-- is the authoritative signal, DISPLAY only decides whether X11 can work at all.
local function linux_backend()
    local wayland = os.getenv('WAYLAND_DISPLAY')
    if type(wayland) == 'string' and wayland ~= '' then return 'wayland' end
    local x11 = os.getenv('DISPLAY')
    if type(x11) == 'string' and x11 ~= '' then return 'x11' end
    return nil
end

local function temp_png_path()
    local name = os.tmpname()
    if type(name) ~= 'string' or name == '' then return nil end
    if not name:lower():match('%.png$') then name = name .. '.png' end
    return name
end

local function file_size(path)
    local info = utils.file_info(path)
    if not info or not info.is_file then return nil end
    return info.size
end

--- Run argv without a shell. Errors are returned as readable text, never swallowed.
local function run(argv, stdin_data)
    local command = {
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = argv,
    }
    if stdin_data then command.stdin_data = stdin_data end
    local result, launch_error = mp.command_native(command)
    if type(result) ~= 'table' then
        return false, string.format('%s 无法启动（%s）',
            tostring(argv[1]), tostring(launch_error or '命令不存在或无执行权限'))
    end
    if tonumber(result.status) ~= 0 then
        local detail = tostring(result.stderr or ''):gsub('%s+$', '')
        if detail == '' then detail = '退出码 ' .. tostring(result.status) end
        return false, string.format('%s 执行失败：%s', tostring(argv[1]), detail)
    end
    return true
end

-- PowerShell single-quoted literal: only ' needs doubling.
local function ps_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

-- AppleScript double-quoted literal: backslash and double quote need escaping.
local function applescript_quote(value)
    return tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function copy_wayland(path)
    -- wl-copy 只能从 stdin 读数据，而 mpv 0.41 的 subprocess 不接受含 NUL 的
    -- stdin_data（实测 "argument stdin_data has incompatible type"，PNG 必然带 0x00）。
    -- 所以只做一件事：用常量脚本把文件重定向进 wl-copy，路径作为位置参数 $1 传入，
    -- 不参与命令字符串拼接（脚本文本里没有任何变量插值）。
    return run({'sh', '-c', 'exec wl-copy --type image/png < "$1"', 'sh', path})
end

local function copy_x11(path)
    return run({'xclip', '-selection', 'clipboard', '-t', 'image/png', '-i', path})
end

local function copy_windows(path)
    -- Clipboard.SetImage must run on an STA thread, and the path has to survive
    -- spaces/Unicode: it is passed as a PowerShell literal, not interpolated.
    local script = table.concat({
        'Add-Type -AssemblyName System.Windows.Forms',
        'Add-Type -AssemblyName System.Drawing',
        '$img = [System.Drawing.Image]::FromFile(' .. ps_quote(path) .. ')',
        'try { [System.Windows.Forms.Clipboard]::SetImage($img) } finally { $img.Dispose() }',
    }, '; ')
    return run({'powershell', '-NoProfile', '-STA', '-Command', script})
end

local function copy_darwin(path)
    local script = string.format(
        'set the clipboard to (read (POSIX file "%s") as «class PNGf»)',
        applescript_quote(path))
    local ok, err = run({'osascript', '-e', script})
    if ok then return true end
    -- Fall back to an explicit PNGf alias form before giving up: some OSA
    -- versions reject the «class PNGf» literal but accept the four-char code.
    local fallback = string.format(
        'set the clipboard to (read (POSIX file "%s") as PNGf)',
        applescript_quote(path))
    local ok2, err2 = run({'osascript', '-e', fallback})
    if ok2 then return true end
    return false, err .. '；兼容写法也失败：' .. err2
end

local function copy_screenshot()
    local target = platform()
    local backend
    if target == 'windows' or target == 'darwin' then
        backend = target
    elseif target == 'linux' then
        backend = linux_backend()
        if not backend then
            notify('复制截图失败：既没有 WAYLAND_DISPLAY 也没有 DISPLAY，无法访问剪贴板')
            return
        end
    else
        notify('复制截图失败：不支持的平台（platform=' .. tostring(target) .. '）')
        return
    end

    local path = temp_png_path()
    if not path then
        notify('复制截图失败：无法分配临时文件路径')
        return
    end
    os.remove(path)

    mp.commandv('screenshot-to-file', path, 'subtitles')
    local size = file_size(path)
    if not size or size == 0 then
        os.remove(path)
        notify('复制截图失败：screenshot-to-file 没有生成图片（当前视频输出可能不支持截图）')
        return
    end

    local ok, reason
    if backend == 'wayland' then
        ok, reason = copy_wayland(path)
    elseif backend == 'x11' then
        ok, reason = copy_x11(path)
    elseif backend == 'windows' then
        ok, reason = copy_windows(path)
    else
        ok, reason = copy_darwin(path)
    end

    local removed, remove_error = os.remove(path)
    if not removed then
        msg.warn('截图临时文件清理失败：' .. tostring(path) .. '（' .. tostring(remove_error) .. '）')
    end

    if not ok then
        notify('复制截图到剪贴板失败：' .. tostring(reason), 5)
        return
    end
    mp.osd_message('截图已复制到剪贴板', 2)
end

mp.add_key_binding(nil, 'screenshot-to-clipboard', copy_screenshot)
