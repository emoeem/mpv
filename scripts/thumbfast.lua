-- thumbfast.lua
--
-- High-performance on-the-fly thumbnailer
--
-- Built for easy integration in third-party UIs.

--[[
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]

local options = {
    -- Socket path (leave empty for auto)
    socket = "",

    -- Thumbnail path (leave empty for auto)
    thumbnail = "",

    -- Maximum thumbnail size in pixels (scaled down to fit)
    -- Values are scaled when hidpi is enabled
    max_height = 200,
    max_width = 200,

    -- Overlay id
    overlay_id = 42,

    -- Spawn thumbnailer on file load for faster initial thumbnails
    spawn_first = false,

    -- Close thumbnailer process after an inactivity period in seconds, 0 to disable
    quit_after_inactivity = 0,

    -- Enable on network playback
    network = false,

    -- Enable thumbnails for media opened through the built-in AList browser.
    -- no: disabled; yes: always enabled; auto: try on first hover and stop the
    -- second remote reader when the first valid frame takes too long.
    alist = "auto",

    -- AList/WebDAV auto mode timeout for the first valid frame. The main video
    -- always wins: a slow server or link disables previews for this file only.
    remote_timeout = 2.5,

    -- Remote exact seeks are deliberately delayed longer while scrubbing so
    -- rapid pointer movement only keeps the latest inexpensive keyframe seek.
    remote_exact_seek_delay = 0.35,

    -- Enable on audio playback
    audio = false,

    -- Enable hardware decoding
    hwdec = false,

    -- Use fast keyframe seek before exact seek. Faster, but can flash two different frames.
    fast_seek = true,

    -- Refine to the exact frame only after the pointer has stayed still for
    -- this long.  Fast previews continue while moving, avoiding exact-decode
    -- backlogs during timeline scrubbing.
    exact_seek_delay = 0.16,

    -- Tone-map PQ/HLG thumbnails to SDR after downscaling.  This keeps HDR
    -- previews readable without copying the main playback shader chain.
    hdr_tone_mapping = true,

    -- HDR preview initializes a tiny GPU renderer. Delay only that prewarm so
    -- main playback can settle first; an immediate hover still spawns on demand.
    hdr_prewarm_delay = 1.2,

    -- Windows only: use native Windows API to write to pipe (requires LuaJIT)
    direct_io = false,

    -- Custom path to the mpv executable
    mpv_path = "mpv",

    -- Specifies a blacklist of video extensions to ignore
    blacklist_ext = "bdmv,ifo",

    -- excluded directories for shared, #windows: ["X:", "Z:", "F:/Download/", "Download"]
    excluded_dir = [[
        []
    ]],
}

mp.utils = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "thumbfast")

local properties = {}
local pre_0_30_0 = mp.command_native_async == nil
local pre_0_33_0 = true

local is_windows = package.config:sub(1, 1) == "\\" -- detect path separator, windows uses backslashes

local function split(input)
    local ret = {}
    for str in string.gmatch(input, "([^,]+)") do
        ret[#ret + 1] = str
    end
    return ret
end

local function exclude(extension, tab)
    if #tab > 0 then
        for _, ext in pairs(tab) do
            if extension == ext then
                return true
            end
        end
    else
        return
    end
end

local function need_ignore(tab, val)
    for index, element in ipairs(tab) do
        if string.find(val, element) then
            return true
        end
    end
    return false
end

local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

function subprocess(args, async, callback, discard_stderr)
    callback = callback or function() end

    if not pre_0_30_0 then
        if async then
            local command = {name = "subprocess", playback_only = true, args = args}
            if discard_stderr then
                -- Some decoders (notably libdavs2) write ANSI-coloured diagnostics
                -- directly to stderr, bypassing mpv's --really-quiet/--no-terminal.
                -- Drain that child-only stream without retaining it so the main
                -- console stays clean and long thumbnail sessions do not grow RAM.
                command.capture_stderr = true
                command.capture_size = 0
            end
            return mp.command_native_async(command, callback)
        else
            return mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, args = args})
        end
    else
        if async then
            return mp.utils.subprocess_detached({args = args}, callback)
        else
            return mp.utils.subprocess({args = args})
        end
    end
end

local winapi = {}
if options.direct_io then
    local ffi_loaded, ffi = pcall(require, "ffi")
    if ffi_loaded then
        winapi = {
            ffi = ffi,
            C = ffi.C,
            bit = require("bit"),
            socket_wc = "",

            -- WinAPI constants
            CP_UTF8 = 65001,
            GENERIC_WRITE = 0x40000000,
            OPEN_EXISTING = 3,
            FILE_FLAG_WRITE_THROUGH = 0x80000000,
            FILE_FLAG_NO_BUFFERING = 0x20000000,
            PIPE_NOWAIT = ffi.new("unsigned long[1]", 0x00000001),

            INVALID_HANDLE_VALUE = ffi.cast("void*", -1),

            -- don't care about how many bytes WriteFile wrote, so allocate something to store the result once
            _lpNumberOfBytesWritten = ffi.new("unsigned long[1]"),
        }
        -- cache flags used in run() to avoid bor() call
        winapi._createfile_pipe_flags = winapi.bit.bor(winapi.FILE_FLAG_WRITE_THROUGH, winapi.FILE_FLAG_NO_BUFFERING)

        ffi.cdef[[
            void* __stdcall CreateFileW(const wchar_t *lpFileName, unsigned long dwDesiredAccess, unsigned long dwShareMode, void *lpSecurityAttributes, unsigned long dwCreationDisposition, unsigned long dwFlagsAndAttributes, void *hTemplateFile);
            bool __stdcall WriteFile(void *hFile, const void *lpBuffer, unsigned long nNumberOfBytesToWrite, unsigned long *lpNumberOfBytesWritten, void *lpOverlapped);
            bool __stdcall CloseHandle(void *hObject);
            bool __stdcall SetNamedPipeHandleState(void *hNamedPipe, unsigned long *lpMode, unsigned long *lpMaxCollectionCount, unsigned long *lpCollectDataTimeout);
            int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
        ]]

        winapi.MultiByteToWideChar = function(MultiByteStr)
            if MultiByteStr then
                local utf16_len = winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, nil, 0)
                if utf16_len > 0 then
                    local utf16_str = winapi.ffi.new("wchar_t[?]", utf16_len)
                    if winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, utf16_str, utf16_len) > 0 then
                        return utf16_str
                    end
                end
            end
            return ""
        end

    else
        options.direct_io = false
    end
end

local file = nil
local file_bytes = 0
local inherited_options_path = nil
local inherited_options_generation = 0
local spawned = false
local prewarm_started = false
local prewarm_timer = nil
local disabled = false
local force_disabled = false
local spawn_waiting = false
local spawn_working = false
local script_written = false

local dirty = false

local x = nil
local y = nil
local last_x = x
local last_y = y

local last_seek_time = nil

local effective_w = options.max_width
local effective_h = options.max_height
local real_w = nil
local real_h = nil
local last_real_w = nil
local last_real_h = nil

local script_name = nil

local show_thumbnail = false
local preview_ready = false
local remote_watchdog = nil
local remote_auto_disabled = false
local disable_reason = ""

local filters_reset = {["lavfi-crop"]=true, ["crop"]=true}
local filters_runtime = {["hflip"]=true, ["vflip"]=true}
local filters_all = {["hflip"]=true, ["vflip"]=true, ["lavfi-crop"]=true, ["crop"]=true}

local last_vf_reset = ""
local last_vf_runtime = ""

local last_rotate = 0

local par = ""
local last_par = ""

local last_has_vid = 0
local has_vid = 0
local last_is_dolby_vision = false
local last_hdr_preview = false
local last_vout_gamma = nil

local file_timer = nil
local file_check_period = 1/60

local allow_fast_seek = true

local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumbfast" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

local cached_ranges = {}
local ext_blacklist = split(options.blacklist_ext)
local excluded_dir = mp.utils.parse_json(options.excluded_dir)

local function get_os()
    local raw_os_name = ""

    if jit and jit.os and jit.arch then
        raw_os_name = jit.os
    else
        if package.config:sub(1,1) == "\\" then
            -- Windows
            local env_OS = os.getenv("OS")
            if env_OS then
                raw_os_name = env_OS
            end
        else
            raw_os_name = subprocess({"uname", "-s"}).stdout
        end
    end

    raw_os_name = (raw_os_name):lower()

    local os_patterns = {
        ["windows"] = "windows",
        ["linux"]   = "linux",

        ["osx"]     = "darwin",
        ["mac"]     = "darwin",
        ["darwin"]  = "darwin",

        ["^mingw"]  = "windows",
        ["^cygwin"] = "windows",

        ["bsd$"]    = "darwin",
        ["sunos"]   = "darwin"
    }

    -- Default to linux
    local str_os_name = "linux"

    for pattern, name in pairs(os_patterns) do
        if raw_os_name:match(pattern) then
            str_os_name = name
            break
        end
    end

    return str_os_name
end

local os_name = mp.get_property("platform") or get_os()

local path_separator = os_name == "windows" and "\\" or "/"

if options.socket == "" then
    if os_name == "windows" then
        options.socket = "thumbfast"
    else
        options.socket = "/tmp/thumbfast"
    end
end

if options.thumbnail == "" then
    if os_name == "windows" then
        options.thumbnail = os.getenv("TEMP").."\\thumbfast.out"
    else
        options.thumbnail = "/tmp/thumbfast.out"
    end
end

local unique = mp.utils.getpid()

options.socket = options.socket .. unique
options.thumbnail = options.thumbnail .. unique

if options.direct_io then
    if os_name == "windows" then
        winapi.socket_wc = winapi.MultiByteToWideChar("\\\\.\\pipe\\" .. options.socket)
    end

    if winapi.socket_wc == "" then
        options.direct_io = false
    end
end

local mpv_path = options.mpv_path

if mpv_path == "mpv" then
    local frontend_name = mp.get_property_native("user-data/frontend/name")
    if frontend_name == "mpv.net" then
        mpv_path = mp.get_property_native("user-data/frontend/process-path")
    end
end

if mpv_path == "mpv" and os_name == "darwin" and unique then
    -- TODO: look into ~~osxbundle/
    mpv_path = string.gsub(subprocess({"ps", "-o", "comm=", "-p", tostring(unique)}).stdout, "[\n\r]", "")
    if mpv_path ~= "mpv" then
        mpv_path = string.gsub(mpv_path, "/mpv%-bundle$", "/mpv")
        local mpv_bin = mp.utils.file_info("/usr/local/mpv")
        if mpv_bin and mpv_bin.is_file then
            mpv_path = "/usr/local/mpv"
        else
            local mpv_app = mp.utils.file_info("/Applications/mpv.app/Contents/MacOS/mpv")
            if mpv_app and mpv_app.is_file then
                mp.msg.warn("symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            else
                mp.msg.warn("drag to your Applications folder and symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            end
        end
    end
end

-- The Atmos experiment runs a patched mpv from a versioned sidecar directory.
-- Its nested thumbnail process must still use the native player in the
-- portable package root, which is not reliably discoverable through PATH from
-- every Windows launcher.
local function resolve_spawn_mpv_path()
    if os_name == "windows"
        and mp.get_property_native("user-data/yaozhi/atmos-mode") == "yes"
    then
        local native_mpv = mp.command_native({"expand-path", "~~/../mpv.exe"})
        local native_mpv_info = native_mpv and mp.utils.file_info(native_mpv)
        if native_mpv_info and native_mpv_info.is_file then
            return native_mpv
        end
        mp.msg.warn("Atmos mode could not locate the portable native mpv.exe")
    end
    return mpv_path
end

local function current_video_track()
    local track = properties["current-tracks/video"]
    return type(track) == "table" and track or nil
end

local function is_dolby_vision()
    local track = current_video_track()
    return track and track["dolby-vision-profile"] ~= nil or false
end

local function is_hdr_thumbnail()
    local params = properties["video-params"]
    local gamma = type(params) == "table"
        and tostring(params["gamma"] or ""):lower() or ""
    return options.hdr_tone_mapping and (gamma == "pq" or gamma == "hlg")
end

local function is_nonseekable_alist_archive()
    local path = tostring(properties["path"] or "")
    local open_filename = tostring(properties["stream-open-filename"] or "")
    return properties["user-data/alist/archive-inner"] == true or
        path:match("^alist%-archive://") ~= nil or
        open_filename:match("^https?://.+/ae/") ~= nil
end

local function alist_mode()
    local mode = tostring(options.alist or "auto"):lower()
    if mode == "true" or mode == "1" or mode == "on" then return "yes" end
    if mode == "false" or mode == "0" or mode == "off" then return "no" end
    if mode ~= "yes" and mode ~= "no" and mode ~= "auto" then return "auto" end
    return mode
end

local function is_alist_playback()
    return properties["user-data/alist/playing"] == true
end

local function is_online_live()
    return tostring(properties["user-data/online-media/content-type"] or "") == "live"
end

local function is_online_vod()
    return tostring(properties["user-data/online-media/content-type"] or "") == "video"
end

local function is_adaptive_remote()
    return properties["demuxer-via-network"] == true
        or (is_alist_playback() and alist_mode() == "auto")
        or is_online_vod()
end

local function stop_remote_watchdog()
    if remote_watchdog then
        remote_watchdog:kill()
        remote_watchdog = nil
    end
end

local function vf_string(filters, full)
    local vf = ""
    local vf_table = properties["vf"]

    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            if filters[vf_table[i].name] then
                local args = ""
                for key, value in pairs(vf_table[i].params) do
                    if args ~= "" then
                        args = args .. ":"
                    end
                    args = args .. key .. "=" .. value
                end
                vf = vf .. vf_table[i].name .. "=" .. args .. ","
            end
        end
    end

    if full then
        if is_hdr_thumbnail() then
            -- The mpv GPU filter performs the same color-managed tone mapping
            -- as the renderer, directly at thumbnail resolution.  Unlike the
            -- CPU lavfi tonemap chain, it does not buffer the first paused
            -- frame, so hover/seek behavior stays deterministic.
            vf = vf.."gpu=w="..effective_w..":h="..effective_h..",format=bgra"
        else
            vf = vf.."scale=w="..effective_w..":h="..effective_h..par
                ..",pad=w="..effective_w..":h="..effective_h
                ..":x=-1:y=-1,format=bgra"
        end
    end

    return vf
end

local function calc_dimensions()
    local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
    local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
    if not width or not height then return end

    local scale = properties["display-hidpi-scale"] or 1

    if width / height > options.max_width / options.max_height then
        effective_w = math.floor(options.max_width * scale + 0.5)
        effective_h = math.floor(height / width * effective_w + 0.5)
    else
        effective_h = math.floor(options.max_height * scale + 0.5)
        effective_w = math.floor(width / height * effective_h + 0.5)
    end

    local v_par = properties["video-out-params"] and properties["video-out-params"]["par"] or 1
    if v_par == 1 then
        par = ":force_original_aspect_ratio=decrease"
    else
        par = ""
    end
end

local info_timer = nil

local function info(w, h)
    local rotate = properties["video-params"] and properties["video-params"]["rotate"]
    local rtx_hdr = properties["video-params"] and properties["video-params"]["gamma"] == "bt.1886" and properties["video-out-params"] and properties["video-out-params"]["gamma"] ~= "bt.1886"
    local image = properties["current-tracks/video"] and properties["current-tracks/video"]["image"]
    local albumart = image and properties["current-tracks/video"]["albumart"]
    local cache_state = properties["demuxer-cache-state"]
    local dir = properties["path"] and mp.utils.split_path(properties["path"])
    local file_ext = properties["path"] and properties["path"]:match("%.([^%.]+)$")

    if is_windows and dir then dir = dir:gsub("\\", "/") end
    if cache_state then cached_ranges = cache_state["seekable-ranges"] end

    local network_playback = properties["demuxer-via-network"]
        or is_protocol(properties["path"])
        or (properties["cache"] == "auto" and #cached_ranges > 0)
    local mode = alist_mode()
    disable_reason = ""
    if (w or 0) == 0 or (h or 0) == 0 then
        disable_reason = "missing-video-size"
    elseif has_vid == 0 or not current_video_track() then
        disable_reason = "missing-video-track"
    elseif is_dolby_vision() then
        disable_reason = "dolby-vision-protected"
    elseif is_online_live() then
        disable_reason = "live-stream-protected"
    elseif is_nonseekable_alist_archive() then
        disable_reason = "remote-archive-protected"
    elseif is_alist_playback() and mode == "no" then
        disable_reason = "remote-disabled"
    elseif is_adaptive_remote() and properties["seekable"] ~= true then
        disable_reason = "remote-not-seekable"
    elseif is_adaptive_remote() and remote_auto_disabled then
        disable_reason = "remote-first-frame-timeout"
    elseif dir and need_ignore(excluded_dir, dir) then
        disable_reason = "excluded-directory"
    elseif file_ext and exclude(file_ext:lower(), ext_blacklist) then
        disable_reason = "excluded-extension"
    elseif network_playback and not options.network then
        disable_reason = "network-disabled"
    elseif rtx_hdr then
        disable_reason = "rtx-video-hdr-protected"
    elseif albumart and not options.audio then
        disable_reason = "audio-disabled"
    elseif image and not albumart then
        disable_reason = "still-image"
    elseif force_disabled then
        disable_reason = "runtime-failure"
    end
    disabled = disable_reason ~= ""

    mp.set_property_native("user-data/thumbnail-preview/status",
        disabled and "disabled" or (preview_ready and "ready" or "available"))
    mp.set_property_native("user-data/thumbnail-preview/reason", disable_reason)
    mp.set_property_native("user-data/thumbnail-preview/source",
        is_alist_playback() and "alist-webdav"
            or (network_playback and "network" or "local"))

    if info_timer then
        info_timer:kill()
        info_timer = nil
    elseif has_vid == 0 or rotate == nil then
        info_timer = mp.add_timeout(0.05, function() info(w, h) end)
    end

    local json, err = mp.utils.format_json({
        width=w, height=h, disabled=disabled, available=true,
        ready=preview_ready, tone_mapped=is_hdr_thumbnail(),
        socket=options.socket, thumbnail=options.thumbnail,
        overlay_id=options.overlay_id,
    })
    if pre_0_30_0 then
        mp.command_native({"script-message", "thumbfast-info", json})
    else
        mp.command_native_async({"script-message", "thumbfast-info", json}, function() end)
    end
end

local function remove_thumbnail_files()
    if file then
        pcall(function() file:close() end)
        file = nil
        file_bytes = 0
    end
    os.remove(options.thumbnail)
    os.remove(options.thumbnail..".bgra")
end

local function remove_inherited_options()
    inherited_options_generation = inherited_options_generation + 1
    if inherited_options_path then
        os.remove(inherited_options_path)
        inherited_options_path = nil
    end
end

local function write_inherited_options()
    remove_inherited_options()

    -- The thumbnailer runs with --no-config, so file-local HTTP options used
    -- by AList/WebDAV would otherwise be lost. Keep credentials out of the
    -- child command line and pass them through a short-lived include file.
    if not properties["demuxer-via-network"] then
        return nil
    end

    local inherited = {
        {"http-header-fields", mp.get_property("http-header-fields", "")},
        {"user-agent", mp.get_property("user-agent", "")},
        {"referrer", mp.get_property("referrer", "")},
        {"http-proxy", mp.get_property("http-proxy", "")},
        {"cookies-file", mp.get_property("cookies-file", "")},
        {"tls-verify", mp.get_property("tls-verify", "")},
    }
    local cookies = mp.get_property_native("cookies")
    local has_inherited = cookies == true
    for _, entry in ipairs(inherited) do
        if entry[2] ~= "" then has_inherited = true; break end
    end
    if not has_inherited then return nil end

    inherited_options_path = options.thumbnail..".conf"
    local config = io.open(inherited_options_path, "w")
    if not config then
        inherited_options_path = nil
        mp.msg.warn("could not create temporary thumbnail network options")
        return nil
    end
    for _, entry in ipairs(inherited) do
        if entry[2] ~= "" then
            config:write(entry[1], "=", string.format("%q", entry[2]), "\n")
        end
    end
    if cookies == true then config:write("cookies=yes\n") end
    config:close()
    inherited_options_generation = inherited_options_generation + 1
    local current_generation = inherited_options_generation
    local current_options_path = inherited_options_path
    mp.add_timeout(5, function()
        if inherited_options_generation == current_generation and
            inherited_options_path == current_options_path
        then
            remove_inherited_options()
        end
    end)
    return inherited_options_path
end

local activity_timer

local function spawn(time)
    if disabled then return end

    if prewarm_timer then
        prewarm_timer:kill()
        prewarm_timer = nil
    end

    local path = properties["path"]
    if path == nil then return end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    local open_filename = properties["stream-open-filename"]
    local ytdl = open_filename and properties["demuxer-via-network"] and path ~= open_filename
    if ytdl then
        path = open_filename
    end

    remove_thumbnail_files()

    local vid = properties["vid"]
    has_vid = vid or 0
    local args = {
        resolve_spawn_mpv_path(), "--no-config", "--msg-level=all=no", "--idle", "--ao=null", "--pause", "--keep-open=always", "--really-quiet", "--no-terminal",
        "--load-scripts=no", "--osc=no", "--ytdl=no", "--load-stats-overlay=no", "--load-auto-profiles=no", "--autoload-files=no",
        "--priority=belownormal",
        "--edition="..(properties["edition"] or "auto"), "--vid="..(vid or "auto"), "--no-sub", "--no-audio",
        "--start="..time, allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",
        is_hdr_thumbnail() and "--gpu-dumb-mode=no" or "--gpu-dumb-mode=yes",
        "--dither-depth=no", "--hdr-compute-peak=no", "--target-colorspace-hint=no", "--profile=fast",
        "--ytdl-format=worst", "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
        "--vd-lavc-skiploopfilter=all", "--vd-lavc-skipidct=all", "--vd-lavc-software-fallback=1", "--vd-lavc-fast", "--vd-lavc-threads=2",
        "--hwdec="..(options.hwdec and "auto" or "no"),
        "--vf="..vf_string(filters_all, true), "--audio-pitch-correction=no", "--deinterlace=no",
        "--zimg-scaler=bilinear", "--zimg-fast=yes",
        "--video-rotate="..last_rotate,
        "--ovc=rawvideo", "--of=image2", "--ofopts=update=1", "--ocopy-metadata=no", "--o="..options.thumbnail
    }

    if is_hdr_thumbnail() then
        -- The thumbnail overlay is SDR UI content.  Keep this child on a
        -- standard BT.709/gamma2.2 target regardless of the main display HDR
        -- state; no main GLSL, RIFE or super-resolution chain is inherited.
        table.insert(args, "--target-prim=bt.709")
        table.insert(args, "--target-trc=gamma2.2")
        table.insert(args, "--target-peak=203")
        table.insert(args, "--target-contrast=1000")
    end

    local inherited_options = write_inherited_options()
    if inherited_options then
        table.insert(args, 3, "--include="..inherited_options)
    end

    if mp.get_property_native("load-console") ~= nil then
        table.insert(args, "--load-console=no")
    elseif mp.get_property_native("load-osd-console") ~= nil then
        table.insert(args, "--load-osd-console=no")
    end

    if mp.get_property_native("load-select") ~= nil then
        table.insert(args, "--load-select=no")
    end

    if mp.get_property_native("load-context-menu") ~= nil then
        table.insert(args, "--load-context-menu=no")
    end

    if mp.get_property_native("load-positioning") ~= nil then
        table.insert(args, "--load-positioning=no")
    end

    if mp.get_property_native("load-commands") ~= nil then
        table.insert(args, "--load-commands=no")
    end

    if mp.get_property_native("clipboard-backends") ~= nil then
        table.insert(args, "--clipboard-backends-clr")
    elseif mp.get_property_native("clipboard-enable") ~= nil then
        table.insert(args, "--clipboard-enable=no")
    end

    if os_name == "darwin" and properties["macos-app-activation-policy"] then
        table.insert(args, "--macos-app-activation-policy=accessory")
    end

    if os_name == "windows" or pre_0_33_0 then
        table.insert(args, "--input-ipc-server="..options.socket)
        local media_controls = mp.get_property_native("media-controls")
        if media_controls ~= nil then
            table.insert(args, "--media-controls=no")
        end
    elseif not script_written then
        local client_script_path = options.socket..".run"
        local script = io.open(client_script_path, "w+")
        if script == nil then
            mp.msg.error("client script write failed")
            return
        else
            script_written = true
            script:write(string.format(client_script, options.socket))
            script:close()
            subprocess({"chmod", "+x", client_script_path}, true)
            table.insert(args, "--scripts="..client_script_path)
        end
    else
        local client_script_path = options.socket..".run"
        table.insert(args, "--scripts="..client_script_path)
    end

    table.insert(args, "--")
    table.insert(args, path)

    spawned = true
    prewarm_started = true
    spawn_waiting = true

    subprocess(args, true,
        function(success, result)
            if spawn_waiting and (success == false or (result.status ~= 0 and result.status ~= -2)) then
                spawned = false
                spawn_waiting = false
                mp.msg.error("mpv subprocess create failed" .. tostring(
                    result and (result.error_string or (" status=" .. tostring(result.status)))
                    or " (no result)"))
                if not spawn_working then -- notify users of required configuration
                    if options.mpv_path == "mpv" then
                        if properties["current-vo"] == "libmpv" then
                            if options.mpv_path == mpv_path then -- attempt to locate ImPlay
                                mpv_path = "ImPlay"
                                spawn(time)
                            else -- ImPlay not in path
                                if os_name ~= "darwin" then
                                    force_disabled = true
                                    info(real_w or effective_w, real_h or effective_h)
                                end
                                mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                                mp.commandv("script-message-to", "implay", "show-message", "thumbfast initial setup", "Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                            end
                        else
                            mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                        end
                    else
                        mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                        -- found ImPlay but not defined in config
                        mp.commandv("script-message-to", "implay", "show-message", "thumbfast", "Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                    end
                end
            elseif success == true and (result.status == 0 or result.status == -2) then
                if not spawn_working and properties["current-vo"] == "libmpv" and options.mpv_path ~= mpv_path then
                    mp.commandv("script-message-to", "implay", "show-message", "thumbfast initial setup", "Set mpv_path=ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                end
                spawn_working = true
                spawn_waiting = false
            end
        end,
        true
    )
end

local function run(command)
    if not spawned then return false end

    if options.direct_io then
        local hPipe = winapi.C.CreateFileW(winapi.socket_wc, winapi.GENERIC_WRITE, 0, nil, winapi.OPEN_EXISTING, winapi._createfile_pipe_flags, nil)
        if hPipe ~= winapi.INVALID_HANDLE_VALUE then
            local buf = command .. "\n"
            winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
            local success = winapi.C.WriteFile(hPipe, buf, #buf + 1, winapi._lpNumberOfBytesWritten, nil)
            winapi.C.CloseHandle(hPipe)
            return success
        end

        return false
    end

    local command_n = command.."\n"

    if os_name == "windows" then
        if file and file_bytes + #command_n >= 4096 then
            file:close()
            file = nil
            file_bytes = 0
        end
        if not file then
            file = io.open("\\\\.\\pipe\\"..options.socket, "r+b")
        end
    elseif pre_0_33_0 then
        subprocess({"/usr/bin/env", "sh", "-c", "echo '" .. command .. "' | socat - " .. options.socket})
        return true
    elseif not file then
        file = io.open(options.socket, "r+")
    end
    if file then
        local success, result = pcall(function()
            local position = file:seek("end")
            if position then file_bytes = position end
            if not file:write(command_n) then return false end
            return file:flush()
        end)
        if success and result then
            file_bytes = file_bytes + #command_n
            return true
        end

        pcall(function() file:close() end)
        file = nil
        file_bytes = 0
    end
    return false
end

local function draw(w, h, script)
    if not w or not show_thumbnail or not preview_ready then return end
    if x ~= nil then
        if pre_0_30_0 then
            mp.command_native({"overlay-add", options.overlay_id, x, y, options.thumbnail..".bgra", 0, "bgra", w, h, (4*w)})
        else
            mp.command_native_async({"overlay-add", options.overlay_id, x, y, options.thumbnail..".bgra", 0, "bgra", w, h, (4*w)}, function() end)
        end
    elseif script then
        local json, err = mp.utils.format_json({width=w, height=h, x=x, y=y, socket=options.socket, thumbnail=options.thumbnail, overlay_id=options.overlay_id})
        mp.commandv("script-message-to", script, "thumbfast-render", json)
    end
end

local function remove_overlay()
    if script_name then return end
    if pre_0_30_0 then
        mp.command_native({"overlay-remove", options.overlay_id})
    else
        mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
    end
end

local function real_res(req_w, req_h, filesize)
    local count = filesize / 4
    local diff = (req_w * req_h) - count

    if (properties["video-params"] and properties["video-params"]["rotate"] or 0) % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if diff == 0 then
        return req_w, req_h
    else
        local threshold = 5 -- throw out results that change too much
        local long_side, short_side = req_w, req_h
        if req_h > req_w then
            long_side, short_side = req_h, req_w
        end
        for a = short_side, short_side - threshold, -1 do
            if count % a == 0 then
                local b = count / a
                if long_side - b < threshold then
                    if req_h < req_w then return b, a else return a, b end
                end
            end
        end
        return nil
    end
end

local function move_file(from, to)
    if os_name == "windows" then
        os.remove(to)
    end
    -- move the file because it can get overwritten while overlay-add is reading it, and crash the player
    os.rename(from, to)
end

local function seek(fast)
    if last_seek_time then
        return run("async seek " .. last_seek_time
            .. (fast and " absolute+keyframes" or " absolute+exact"))
    end
    return false
end

local seek_period = 3/60
local seek_retry_timeout = 10
local seek_retry_deadline = 0
local latest_request_at = 0
local pending_fast_seek = false
local pending_exact_seek = false
local seek_timer

local function seek_retry_expired()
    if not spawned or disabled then
        seek_timer:kill()
        return true
    end
    if seek_retry_deadline > 0 and mp.get_time() >= seek_retry_deadline then
        seek_timer:kill()
        mp.msg.warn("thumbnail seek IPC was not ready after " .. seek_retry_timeout .. " seconds")
        return true
    end
    return false
end

seek_timer = mp.add_periodic_timer(seek_period, function()
    if pending_fast_seek then
        if seek(true) then
            pending_fast_seek = false
        else
            seek_retry_expired()
        end
        return
    end

    local stable_for = mp.get_time() - latest_request_at
    local exact_seek_delay = is_adaptive_remote()
        and math.max(0, tonumber(options.remote_exact_seek_delay) or 0.35)
        or math.max(0, tonumber(options.exact_seek_delay) or 0.16)
    if pending_exact_seek and (not allow_fast_seek
        or stable_for >= exact_seek_delay) then
        if seek(false) then
            pending_exact_seek = false
            seek_timer:kill()
        else
            seek_retry_expired()
        end
    end
end)
seek_timer:kill()

local function request_seek()
    latest_request_at = mp.get_time()
    seek_retry_deadline = mp.get_time() + seek_retry_timeout
    pending_fast_seek = allow_fast_seek
    pending_exact_seek = true
    if seek_timer:is_enabled() then
        -- The periodic timer coalesces rapid pointer movement into one latest
        -- seek per tick.  `seek()` reads last_seek_time at dispatch time.
        return
    end

    seek_timer:resume()
    if pending_fast_seek then
        if seek(true) then pending_fast_seek = false end
    else
        if seek(false) then
            pending_exact_seek = false
            seek_timer:kill()
        end
    end
end

local function check_new_thumb()
    -- the slave might start writing to the file after checking existance and
    -- validity but before actually moving the file, so move to a temporary
    -- location before validity check to make sure everything stays consistant
    -- and valid thumbnails don't get overwritten by invalid ones
    local tmp = options.thumbnail..".tmp"
    move_file(options.thumbnail, tmp)
    local finfo = mp.utils.file_info(tmp)
    if not finfo then return false end
    spawn_waiting = false
    local w, h = real_res(effective_w, effective_h, finfo.size)
    if w then -- only accept valid thumbnails
        move_file(tmp, options.thumbnail..".bgra")
        stop_remote_watchdog()

        real_w, real_h = w, h
        local became_ready = show_thumbnail and not preview_ready
        if became_ready then preview_ready = true end
        if real_w and (real_w ~= last_real_w or real_h ~= last_real_h) then
            last_real_w, last_real_h = real_w, real_h
            info(real_w, real_h)
        elseif became_ready then
            info(real_w, real_h)
        end
        if not show_thumbnail then
            file_timer:kill()
        end
        return true
    end

    return false
end

file_timer = mp.add_periodic_timer(file_check_period, function()
    if check_new_thumb() then
        draw(real_w, real_h, script_name)
    end
end)
file_timer:kill()

local function clear()
    file_timer:kill()
    seek_timer:kill()
    stop_remote_watchdog()
    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end
    last_seek_time = nil
    show_thumbnail = false
    pending_fast_seek = false
    pending_exact_seek = false
    if preview_ready then
        preview_ready = false
        info(real_w or effective_w, real_h or effective_h)
    end
    last_x = nil
    last_y = nil
    remove_overlay()
end

local function quit()
    activity_timer:kill()
    if show_thumbnail then
        activity_timer:resume()
        return
    end
    run("quit")
    spawned = false
    real_w, real_h = nil, nil
    clear()
end

activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
    if disabled then return end

    time = tonumber(time)
    if time == nil then return end

    if r_x == "" or r_y == "" then
        x, y = nil, nil
    else
        x, y = math.floor(r_x + 0.5), math.floor(r_y + 0.5)
    end

    script_name = script
    local first_show = not show_thumbnail
    if last_x ~= x or last_y ~= y or not show_thumbnail then
        show_thumbnail = true
        last_x = x
        last_y = y
        if first_show then
            -- A prewarmed thumbnail belongs to the current playback position,
            -- not necessarily the newly requested timeline position. Keep it
            -- hidden until the thumbnailer has produced the requested frame.
            preview_ready = false
            info(real_w or effective_w, real_h or effective_h)
        else
            draw(real_w, real_h, script)
        end
    end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    local same_time = time == last_seek_time
    if not file_timer:is_enabled() then file_timer:resume() end
    if same_time then return end
    last_seek_time = time
    if not spawned then spawn(time) end
    if first_show and is_adaptive_remote() and not preview_ready and not remote_watchdog then
        local timeout = math.max(0.8, tonumber(options.remote_timeout) or 2.5)
        remote_watchdog = mp.add_timeout(timeout, function()
            remote_watchdog = nil
            if not preview_ready and show_thumbnail and is_adaptive_remote() then
                remote_auto_disabled = true
                if spawned then run("quit") end
                spawned = false
                remove_thumbnail_files()
                clear()
                info(real_w or effective_w, real_h or effective_h)
                mp.msg.warn(string.format(
                    "Remote thumbnail disabled after %.1fs first-frame timeout", timeout))
            end
        end)
    end
    request_seek()
end

local function watch_changes()
    if not dirty or not properties["video-out-params"] then return end
    dirty = false

    local old_w = effective_w
    local old_h = effective_h
    local vout_gamma = properties["video-out-params"] and properties["video-out-params"]["gamma"] or nil
    calc_dimensions()

    local vf_reset = vf_string(filters_reset)
    local rotate = properties["video-rotate"] or 0
    local dovi = is_dolby_vision()
    local hdr_preview = is_hdr_thumbnail()

    local resized = old_w ~= effective_w or
        old_h ~= effective_h or
        last_vf_reset ~= vf_reset or
        (last_rotate % 180) ~= (rotate % 180) or
        par ~= last_par or
        dovi ~= last_is_dolby_vision or
        hdr_preview ~= last_hdr_preview

    if resized then
        last_rotate = rotate
        info(effective_w, effective_h)
    elseif last_has_vid ~= has_vid and has_vid ~= 0 then
        info(effective_w, effective_h)
    elseif vout_gamma ~= last_vout_gamma then
        info(effective_w, effective_h)
    end

    if spawned then
        if resized then
            -- mpv doesn't allow us to change output size
            local seek_time = last_seek_time
            local remote_first_frame_pending = show_thumbnail
                and is_adaptive_remote() and not preview_ready
            run("quit")
            spawned = false
            if remote_first_frame_pending then
                -- Some network streams report their final dimensions only after
                -- the first probe.  Keep the user's request and its watchdog
                -- alive while rebuilding the worker; otherwise this internal
                -- resize looks like a manual close and can leave the helper
                -- running forever without ever drawing a thumbnail.
                remove_thumbnail_files()
            else
                clear()
            end
            spawn(seek_time or mp.get_property_number("time-pos", 0))
            file_timer:resume()
            if remote_first_frame_pending and seek_time ~= nil then
                request_seek()
            end
        else
            if rotate ~= last_rotate then
                run("set video-rotate "..rotate)
            end
            local vf_runtime = vf_string(filters_runtime)
            if vf_runtime ~= last_vf_runtime then
                run("vf set "..vf_string(filters_all, true))
                last_vf_runtime = vf_runtime
            end
        end
    else
        last_vf_runtime = vf_string(filters_runtime)
    end

    last_vf_reset = vf_reset
    last_rotate = rotate
    last_par = par
    last_is_dolby_vision = dovi
    last_hdr_preview = hdr_preview
    last_vout_gamma = vout_gamma
    last_has_vid = has_vid

    if not spawned and not disabled and options.spawn_first and not prewarm_started
        and not is_adaptive_remote() then
        local params = properties["video-params"]
        local gamma = type(params) == "table" and tostring(params["gamma"] or "") or ""
        if gamma == "" then return end

        local delay = is_hdr_thumbnail()
            and math.max(0, tonumber(options.hdr_prewarm_delay) or 1.2) or 0
        if delay > 0 then
            if not prewarm_timer then
                prewarm_timer = mp.add_timeout(delay, function()
                    prewarm_timer = nil
                    if not spawned and not disabled and options.spawn_first
                        and not prewarm_started then
                        spawn(mp.get_property_number("time-pos", 0))
                        file_timer:resume()
                    end
                end)
            end
        else
            spawn(mp.get_property_number("time-pos", 0))
            file_timer:resume()
        end
    end
end

local function update_property(name, value)
    properties[name] = value
end

local function update_property_dirty(name, value)
    properties[name] = value
    dirty = true
end

local function update_tracklist(name, value)
    -- current-tracks shim
    for _, track in ipairs(value) do
        if track.type == "video" and track.selected then
            properties["current-tracks/video"] = track
            dirty = true
            return
        end
    end
end

local function sync_changes(prop, val)
    update_property(prop, val)
    if val == nil then return end

    if type(val) == "boolean" then
        if prop == "vid" then
            has_vid = 0
            last_has_vid = 0
            info(effective_w, effective_h)
            clear()
            return
        end
        val = val and "yes" or "no"
    end

    if prop == "vid" then
        has_vid = 1
    end

    if not spawned then return end

    run("set "..prop.." "..val)
    dirty = true
end

local function file_load()
    if prewarm_timer then
        prewarm_timer:kill()
        prewarm_timer = nil
    end
    remove_inherited_options()
    clear()
    spawned = false
    prewarm_started = false
    real_w, real_h = nil, nil
    last_real_w, last_real_h = nil, nil
    last_seek_time = nil
    preview_ready = false
    remote_auto_disabled = false
    disable_reason = ""
    stop_remote_watchdog()
    if info_timer then
        info_timer:kill()
        info_timer = nil
    end

    calc_dimensions()
    info(effective_w, effective_h)
end

local function shutdown()
    if prewarm_timer then
        prewarm_timer:kill()
        prewarm_timer = nil
    end
    run("quit")
    remove_thumbnail_files()
    remove_inherited_options()
    if os_name ~= "windows" then
        os.remove(options.socket)
        os.remove(options.socket..".run")
    end
end

local function on_duration(prop, val)
    allow_fast_seek = options.fast_seek and (val or 30) >= 30
end

mp.observe_property("current-tracks/video", "native", function(name, value)
    if pre_0_33_0 then
        mp.unobserve_property(update_tracklist)
        pre_0_33_0 = false
    end
    update_property_dirty(name, value)
end)

mp.observe_property("track-list", "native", update_tracklist)
mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)
mp.observe_property("cache", "native", update_property)
mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property('demuxer-cache-state', 'native', update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("user-data/alist/playing", "native", update_property_dirty)
mp.observe_property("user-data/alist/archive-inner", "native", update_property_dirty)
mp.observe_property("user-data/online-media/content-type", "native", update_property_dirty)
mp.observe_property("seekable", "native", update_property_dirty)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property)
mp.observe_property("video-rotate", "native", update_property)
mp.observe_property("path", "native", update_property)
mp.observe_property("vid", "native", sync_changes)
mp.observe_property("edition", "native", sync_changes)
mp.observe_property("duration", "native", on_duration)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)

mp.register_event("file-loaded", file_load)
mp.register_event("shutdown", shutdown)

mp.register_idle(watch_changes)
