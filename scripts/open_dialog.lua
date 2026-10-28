-- Copyright (c) 2022-2024 dyphire <qimoge@gmail.com>
-- License: MIT
-- link: https://github.com/dyphire/mpv-scripts

--[[
The script calls up a window in mpv to quickly load the folder/files/iso/clipboard (support url)/other subtitles/other audio tracks/other video tracks.
Usage, add bindings to input.conf:
key        script-message-to open_dialog import_folder
key        script-message-to open_dialog import_files
key        script-message-to open_dialog import_files <type>      # vid, aid, sid (video/audio/subtitle track)
key        script-message-to open_dialog import_clipboard
key        script-message-to open_dialog import_clipboard <type>  # vid, aid, sid (video/audio/subtitle track)
key        script-message-to open_dialog set_clipboard <text>     # text can be mpv properties as ${path}

Also supports open dialog to select folder/files for other scripts.
Scripting Example:
-- open a folder select dialog
mp.commandv('script-message-to', 'open_dialog', 'select_folder', mp.get_script_name())
-- receive the selected folder reply
mp.register_script_message('select_folder_reply', function(folder_path)
    if folder_path and folder_path ~= '' then
        -- do something with folder_path
    end
end)
-- open a xml file select dialog
mp.commandv('script-message-to', 'open_dialog', 'select_files', mp.get_script_name(), 'XML File|*.xml')
-- receive the selected files reply
mp.register_script_message('select_files_reply', function(file_paths)
    for i, file_path in ipairs(utils.parse_json(file_paths)) do
        -- do something with file_path
    end
end)

]]--

local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

o = {
    video_types = '3g2,3gp,asf,avi,f4v,flv,h264,h265,m2ts,m4v,mkv,mov,mp4,mp4v,mpeg,mpg,ogm,ogv,rm,rmvb,ts,vob,webm,wmv,y4m',
    audio_types = 'aac,ac3,aiff,ape,au,cue,dsf,dts,flac,m4a,mid,midi,mka,mp3,mp4a,oga,ogg,opus,spx,tak,tta,wav,weba,wma,wv',
    image_types = 'apng,avif,bmp,gif,j2k,jp2,jfif,jpeg,jpg,jxl,mj2,png,svg,tga,tif,tiff,webp',
    subtitle_types = 'aqt,ass,gsub,idx,jss,lrc,mks,pgs,pjs,psb,rt,sbv,slt,smi,sub,sup,srt,ssa,ssf,ttxt,txt,usf,vt,vtt',
    playlist_types = 'm3u,m3u8,pls,cue',
    iso_types = 'iso',
}
options.read_options(o)

local function split(input)
    local ret = {}
    for str in string.gmatch(input, "([^,]+)") do
        ret[#ret + 1] = string.format("*.%s", str)
    end
    return ret
end

-- pre-defined file types
local file_types = {
    video = table.concat(split(o.video_types), ';'),
    audio = table.concat(split(o.audio_types), ';'),
    image = table.concat(split(o.image_types), ';'),
    iso = table.concat(split(o.iso_types), ';'),
    subtitle = table.concat(split(o.subtitle_types), ';'),
    playlist = table.concat(split(o.playlist_types), ';'),
}

-- 平台判断一律走 mpv 自己的属性（windows / darwin / linux），不用
-- "zenity 是否存在"去猜：那在装了 zenity 的 macOS/WSL 上会直接判错。
local PLATFORM = tostring(mp.get_property('platform') or '')

local powershell = nil

-- 统一跑外部程序：参数永远是数组，不经 shell。
-- 返回 1) stdout（成功） 2) nil, 可读原因（工具缺失等） 3) nil, nil（用户取消）
local function run_dialog(argv)
    local res, launch_error = mp.command_native({
        name = 'subprocess', playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = argv,
    })
    if type(res) ~= 'table' then
        return nil, string.format('%s 无法启动（%s）',
            tostring(argv[1]), tostring(launch_error or '命令不存在'))
    end
    if tonumber(res.status) ~= 0 then
        -- zenity / osascript 用非零退出表示"用户取消"，这是正常路径，不报错。
        return nil, nil
    end
    return tostring(res.stdout or '')
end

local function pwsh_check()
    local arg = {"cmd", "/c", "pwsh", "--version"}
    local res = mp.command_native({name = "subprocess", capture_stdout = true, playback_only = false, args = arg})
    if res.status ~= 0 or res.stdout:match("^PowerShell") == nil then
        powershell = "powershell"
    else
        powershell = "pwsh"
    end
end

-- escapes a string so that it can be inserted into powershell as a string literal
local function escape_powershell(str)
    if not str then return '""' end
    str = str:gsub('[$"`]', '`%1'):gsub('“', '`%1'):gsub('”', '`%1')
    return '"'..str..'"'
end

local function end_file(event)
    mp.unregister_event(end_file)
    if event["reason"] == "eof" or event["reason"] == "stop" or event["reason"] == "error" then
        local bd_device = mp.get_property_native("bluray-device")
        local dvd_device = mp.get_property_native("dvd-device")
        if event["reason"] == "error" and bd_device and bd_device ~= "" then
            loaded_fail = true
        else
            loaded_fail = false
        end
        if bd_device then mp.set_property("bluray-device", "") end
        if dvd_device then mp.set_property("dvd-device", "") end
    end
end

-- open bluray iso or dir
local function open_bluray(path)
    mp.set_property('bluray-device', path)
    mp.commandv('loadfile', 'bd://')
end

-- open dvd iso or dir
local function open_dvd(path)
    mp.set_property('dvd-device', path)
    mp.commandv('loadfile', 'dvd://')
end

-- open folder
local function open_folder(path, i)
    local fpath, dir = utils.split_path(path)
    if utils.file_info(utils.join_path(path, "BDMV")) then
        open_bluray(path)
    elseif utils.file_info(utils.join_path(path, "VIDEO_TS")) then
        open_dvd(path)
    elseif dir:upper() == "BDMV" then
        open_bluray(fpath)
    elseif dir:upper() == "VIDEO_TS" then
        open_dvd(fpath)
    else
        mp.commandv('loadfile', path, i == 1 and 'replace' or 'append')
    end
end

-- open files
local function open_files(path, type, i, is_clip)
    local ext = string.match(path, "%.([^%.]+)$"):lower()
    if file_types['subtitle']:match(ext) then
        mp.commandv('sub-add', path, 'cached')
    elseif type == 'vid' and (not is_clip or (file_types['video']:match(ext) or file_types['image']:match(ext))) then
        mp.commandv('video-add', path, 'cached')
    elseif type == 'aid' and (not is_clip or file_types['audio']:match(ext)) then
        mp.commandv('audio-add', path, 'cached')
    elseif file_types['iso']:match(ext) then
        -- Keep ISO files on the normal loadfile path. auto_iso_loader.lua will
        -- rewrite them to bd:// or dvd://, which also makes ISO A -> ISO B
        -- switching behave the same as uosc's built-in file browser.
        mp.commandv('loadfile', path, i == 1 and 'replace' or 'append')
    else
        mp.commandv('loadfile', path, i == 1 and 'replace' or 'append')
    end
end

local function select_folder()
    if PLATFORM == 'darwin' then
        -- osascript 的 choose folder 返回 alias，必须显式取 POSIX path 才能给 mpv 用，
        -- 而且末尾带路径分隔符，这里统一去掉。
        local out, launch_error = run_dialog({'osascript', '-e',
            'POSIX path of (choose folder with prompt "选择文件夹")'})
        if launch_error then
            msg.warn('[open_dialog] ' .. launch_error)
            return nil
        end
        if not out then return nil end -- 用户取消：静默
        local folder = out:match('(.-)[\r\n]*$') or ''
        folder = folder:gsub('[/\\]+$', '')
        if folder == '' then return nil end
        return folder
    end
    if PLATFORM ~= 'windows' then
        local out, launch_error = run_dialog({
            'zenity', '--file-selection', '--directory', '--title=选择文件夹',
        })
        if launch_error then
            msg.warn('[open_dialog] ' .. launch_error .. '；请安装 zenity，或改用 script-message 接口')
            return nil
        end
        if not out then return nil end -- 用户取消也无需提示错误
        local folder = out:match('(.-)[\r\n]*$') or ''
        if folder == '' then return nil end
        return folder
    end
    if not powershell then pwsh_check() end
    local powershell_script = string.format([[&{
        Add-Type -AssemblyName System.Windows.Forms
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.RootFolder = "Desktop"
        $fbd.ShowNewFolderButton = $true
        $owner = New-Object System.Windows.Forms.NativeWindow
        $owner.AssignHandle((Get-Process -Id %d).MainWindowHandle)
        try {
            if ($fbd.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                $u8 = [System.Text.Encoding]::UTF8
                $out = [Console]::OpenStandardOutput()
                $selectedFolder = $fbd.SelectedPath
                $u8selectedFolder = $u8.GetBytes("$selectedFolder`n")
                $out.Write($u8selectedFolder, 0, $u8selectedFolder.Length)
            }
        } finally {
            $owner.ReleaseHandle()
            $fbd.Dispose()
        }
    }]], mp.get_property_number('pid'))
    local res = mp.command_native({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = { powershell, '-NoProfile', '-Command', powershell_script },
    })
    if res.status ~= 0 then
        mp.osd_message("Failed to open folder dialog.")
        return nil
    end
    local folder_path = res.stdout:match("(.-)[\r\n]?$") -- Trim any trailing newline
    return folder_path
end

local function select_files(filter)
    if PLATFORM == 'darwin' then
        -- 多选：AppleScript 只能逐个取 alias，统一转 POSIX path 后按行返回。
        local script = table.concat({
            'set theFiles to choose file with prompt "选择媒体文件" with multiple selections allowed',
            'set output to ""',
            'repeat with picked in theFiles',
            'set output to output & (POSIX path of picked) & linefeed',
            'end repeat',
            'return output',
        }, '\n')
        local out, launch_error = run_dialog({'osascript', '-e', script})
        if launch_error then
            msg.warn('[open_dialog] ' .. launch_error)
            return {}
        end
        local file_paths = {}
        if not out then return file_paths end -- 用户取消：静默
        for file_path in string.gmatch(out, '[^\r\n]+') do
            table.insert(file_paths, file_path)
        end
        return file_paths
    end
    if PLATFORM ~= 'windows' then
        local out, launch_error = run_dialog({
            'zenity', '--file-selection', '--multiple', '--separator=\n', '--title=选择媒体文件',
        })
        if launch_error then
            msg.warn('[open_dialog] ' .. launch_error .. '；请安装 zenity，或改用 script-message 接口')
            return {}
        end
        local file_paths = {}
        if not out then return file_paths end -- 用户取消也无需提示错误
        for file_path in string.gmatch(out, '[^\r\n]+') do
            table.insert(file_paths, file_path)
        end
        return file_paths
    end
    if not powershell then pwsh_check() end
    local powershell_script = string.format([[&{
        Add-Type -AssemblyName System.Windows.Forms
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Multiselect = $true
        $ofd.Filter = %s
        $owner = New-Object System.Windows.Forms.NativeWindow
        $owner.AssignHandle((Get-Process -Id %d).MainWindowHandle)
        try {
            if ($ofd.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                $u8 = [System.Text.Encoding]::UTF8
                $out = [Console]::OpenStandardOutput()
                ForEach ($filename in $ofd.FileNames) {
                    $u8filename = $u8.GetBytes("$filename`n")
                    $out.Write($u8filename, 0, $u8filename.Length)
                }
            }
        } finally {
            $owner.ReleaseHandle()
            $ofd.Dispose()
        }
    }]], escape_powershell(filter), mp.get_property_number('pid'))
    local res = mp.command_native({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = { powershell, '-NoProfile', '-Command', powershell_script },
    })
    local file_paths = {}
    if res.status ~= 0 then
        mp.osd_message("Failed to open files dialog.")
        return file_paths
    end
    for file_path in string.gmatch(res.stdout, '[^\r\n]+') do
        table.insert(file_paths, file_path)
    end
    return file_paths
end

-- import folder
local function import_folder()
    local folder_path = select_folder()
    if folder_path and folder_path ~= '' then open_folder(folder_path, 1) end
end

-- import files
local function import_files(type)
    local filter = ''
    if type == 'vid' then
        filter = string.format("Video Files|%s|Image Files|%s", file_types['video'], file_types['image'])
    elseif type == 'aid' then
        filter = string.format("Audio Files|%s", file_types['audio'])
    elseif type == 'sid' then
        filter = string.format("Subtitle Files|%s", file_types['subtitle'])
    else
        filter = string.format("All Files (*.*)|*.*|Video Files|%s|Audio Files|%s|Image Files|%s|ISO Files|%s|Subtitle Files|%s|Playlist Files|%s",
            file_types['video'], file_types['audio'], file_types['image'], file_types['iso'], file_types['subtitle'], file_types['playlist'])
    end
    for i, file_path in ipairs(select_files(filter)) do
        open_files(file_path, type, i, false)
    end
end

--- 读取剪贴板文本：先走 mpv 原生剪贴板属性，再按平台回退到对应命令行工具。
--- 原来的实现无条件调用 powershell，在 Linux/macOS 上只会拿到空字符串。
local function clipboard_read_commands()
    if PLATFORM == 'darwin' then
        return {{'pbpaste'}}
    elseif PLATFORM == 'windows' then
        return {{'powershell', '-NoProfile', '-Command', [[& {
            Trap {
                Write-Error -ErrorRecord $_
                Exit 1
            }
            $clip = Get-Clipboard -Raw -Format Text -TextFormatType UnicodeText
            if (-not $clip) {
                $clip = Get-Clipboard -Raw -Format FileDropList
            }
            $u8clip = [System.Text.Encoding]::UTF8.GetBytes($clip)
            [Console]::OpenStandardOutput().Write($u8clip, 0, $u8clip.Length)
        }]]}}
    end
    return {
        {'wl-paste', '--no-newline'},
        {'xclip', '-selection', 'clipboard', '-o'},
        {'xsel', '--clipboard', '--output'},
    }
end

local function get_clipboard()
    if mp.get_property('clipboard-backends') ~= nil then
        local native = mp.get_property('clipboard/text', '')
        if type(native) == 'string' and native ~= '' then return native end
    end
    for _, argv in ipairs(clipboard_read_commands()) do
        local res = mp.command_native({
            name = 'subprocess', playback_only = false,
            capture_stdout = true, capture_stderr = true, args = argv,
        })
        if type(res) == 'table' and tonumber(res.status) == 0 then
            local text = tostring(res.stdout or '')
            if text ~= '' then return text end
        end
    end
    return ''
end

--- 写入剪贴板文本：同样的平台分支，文本走 stdin 而不是命令行参数。
local function clipboard_write_commands()
    if PLATFORM == 'darwin' then
        return {{'pbcopy'}}
    end
    return {
        {'wl-copy'},
        {'xclip', '-selection', 'clipboard', '-i'},
        {'xsel', '--clipboard', '--input'},
    }
end

local function set_clipboard_via_tools(text)
    for _, argv in ipairs(clipboard_write_commands()) do
        local res = mp.command_native({
            name = 'subprocess', playback_only = false,
            capture_stdout = true, capture_stderr = true, args = argv,
            stdin_data = text,
        })
        if type(res) == 'table' and tonumber(res.status) == 0 then return true end
    end
    return false
end

-- open files from clipboard
local function open_clipboard(path, type, i)
    local path = path:gsub("^[\'\"]", ""):gsub("[\'\"]$", ""):gsub('^%s+', ''):gsub('%s+$', '')
    if path:find('^%a[%w.+-]-://') then
        mp.commandv('loadfile', path, i == 1 and 'replace' or 'append')
    else
        local meta = utils.file_info(path)
        if not meta then
            mp.osd_message('Clipboard path is invalid')
            msg.warn('Clipboard path is invalid')
        elseif meta.is_dir then
            open_folder(path, i)
        elseif meta.is_file then
            open_files(path, type, i, true)
        else
            mp.osd_message('Clipboard path is invalid')
            msg.warn('Clipboard path is invalid')
        end
    end
end

-- import clipboard
local function import_clipboard(type)
    local clip = get_clipboard()
    if clip ~= '' then
        local i = 0
        for path in string.gmatch(clip, '[^\r\n]+') do
            i = i + 1
            open_clipboard(path, type, i)
        end
    else
        mp.osd_message('Clipboard is empty')
        msg.warn('Clipboard is empty')
    end
end

-- sets the contents of the clipboard to the given string
local function set_clipboard(text)
    msg.verbose('setting clipboard text:', text)
    if mp.get_property('clipboard-backends') ~= nil then
        mp.commandv('set', 'clipboard/text', text)
        return
    end
    if PLATFORM == 'windows' then
        local res = mp.command_native({
            name = 'subprocess', playback_only = false,
            capture_stdout = true, capture_stderr = true,
            args = {'powershell', '-NoProfile', '-Command',
                'Set-Clipboard -Value ' .. escape_powershell(text)},
        })
        if type(res) == 'table' and tonumber(res.status) == 0 then return end
        msg.warn('[open_dialog] set_clipboard 失败：powershell Set-Clipboard 未成功')
        return
    end
    if not set_clipboard_via_tools(text) then
        local hint = PLATFORM == 'darwin' and 'pbcopy' or 'wl-copy / xclip / xsel'
        msg.warn('[open_dialog] set_clipboard 失败：没有可用的剪贴板工具（需要 ' .. hint .. '）')
    end
end

mp.register_script_message('import_folder', import_folder)
mp.register_script_message('import_files', import_files)
mp.register_script_message('import_clipboard', import_clipboard)
mp.register_script_message('set_clipboard', set_clipboard)
mp.register_script_message('select_folder', function(script_name)
    local folder_path = select_folder()
    -- 取消时回空串而不是 nil：mp.commandv 不接受 nil 参数，否则取消会变成脚本报错。
    mp.commandv('script-message-to', script_name, 'select_folder_reply', folder_path or '')
end)
mp.register_script_message('select_files', function(script_name, filter)
    local file_paths = select_files(filter)
    mp.commandv('script-message-to', script_name, 'select_files_reply', utils.format_json(file_paths))
end)
