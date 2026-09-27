-- copy-paste-URL-optimized.lua
-- Original idea/script provided by community contributor
-- Optimized for mpv-Yaozhi
--
-- 功能：
--   在 mpv 启动页 / 当前无媒体载入时按 Ctrl+V，读取剪贴板中的网页 URL 并播放。
--
-- 设计：
--   1. 仅在无媒体状态强绑定 Ctrl+V，媒体开始载入前立即释放。
--   2. 优先使用 mpv 原生剪贴板；不可用时异步回退 wl-paste/xclip/xsel。
--   3. 仅接受 http/https URL，不执行剪贴板中的命令或本地路径。
--   4. 防重复触发、防超大剪贴板、防加载竞态。

local mp = require("mp")

local BINDING_NAME = "yaozhi_paste_open_url"
local MAX_CLIPBOARD_BYTES = 256 * 1024
local binding_active = false
local request_in_flight = false
local console_open = false
local paste_handler

local function notify(text, duration)
    mp.osd_message(text, duration or 2)
end

local function trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^\239\187\191", "") -- UTF-8 BOM
    s = s:gsub("%z", "")             -- NUL
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_wrapping(text)
    text = trim(text)
    if not text or text == "" then return nil end

    local first = text:sub(1, 1)
    local last = text:sub(-1)
    if (first == '"' and last == '"') or
       (first == "'" and last == "'") or
       (first == "<" and last == ">") then
        text = trim(text:sub(2, -2))
    end

    return text
end

local function is_http_url(value)
    return type(value) == "string"
        and value:match("^[Hh][Tt][Tt][Pp][Ss]?://") ~= nil
end

local function clean_url(url)
    url = strip_wrapping(url)
    if not url or url == "" then return nil end

    -- 只清理明显的分享文案包裹符，避免破坏 URL 本身可能合法的标点。
    url = url:gsub("[\"'>]+$", "")

    if not is_http_url(url) then return nil end
    return url
end

local function extract_url(text)
    text = trim(text)
    if not text or text == "" then return nil end

    if #text > MAX_CLIPBOARD_BYTES then
        return nil, "剪贴板内容过长"
    end

    -- 地址栏直接复制：优先完整使用第一行。
    if is_http_url(text) then
        return clean_url(text:match("([^\r\n]+)") or text), nil
    end

    -- 兼容“标题/分享文案 + URL”。
    return clean_url(text:match("([Hh][Tt][Tt][Pp][Ss]?://[^%s\r\n]+)")), nil
end

local function no_media_loaded()
    -- path 在当前没有媒体时为 nil/空；适合自定义启动页。
    local path = mp.get_property("path")
    return path == nil or path == ""
end

local function set_binding_enabled(enabled)
    if enabled and not binding_active then
        -- 仅在无媒体状态强绑定，确保启动页 Ctrl+V 可用。
        mp.add_forced_key_binding("ctrl+v", BINDING_NAME, function()
            -- 真正处理函数在下方定义后通过 paste_handler 转发。
            if paste_handler then paste_handler() end
        end)
        binding_active = true
        mp.msg.verbose("启动页 Ctrl+V URL 粘贴已启用")
    elseif not enabled and binding_active then
        mp.remove_key_binding(BINDING_NAME)
        binding_active = false
        mp.msg.verbose("Ctrl+V URL 粘贴已释放")
    end
end

local function refresh_binding()
    set_binding_enabled(no_media_loaded() and not request_in_flight and not console_open)
end

local function open_url(url)
    if not url or not no_media_loaded() then
        refresh_binding()
        return
    end

    -- 在 loadfile 前先释放强绑定，避免 path 尚未更新时连续 Ctrl+V 重复加载。
    set_binding_enabled(false)

    mp.msg.info("启动页 Ctrl+V：已识别网页 URL，开始加载")
    notify("正在打开剪贴板网址…", 1.5)

    local ok, err = mp.commandv("loadfile", url, "replace")
    if not ok then
        mp.msg.error("loadfile 失败: " .. tostring(err or "unknown error"))
        notify("网址加载失败", 2.5)
        refresh_binding()
    end
end

local function handle_clipboard_text(text, read_error)
    request_in_flight = false

    -- 读取期间如果用户已经通过其他方式打开媒体，就不再干预。
    if not no_media_loaded() then
        refresh_binding()
        return
    end

    if read_error then
        notify(read_error, 2.5)
        refresh_binding()
        return
    end

    if not text or trim(text) == "" then
        notify("剪贴板为空", 2)
        refresh_binding()
        return
    end

    local url, extract_error = extract_url(text)
    if not url then
        notify(extract_error or "未识别到 http / https 网页地址", 2.5)
        refresh_binding()
        return
    end

    open_url(url)
end

local function get_native_clipboard_text()
    -- mpv 0.42+ 在 clipboard-monitor=no 时读取前需要 update-clipboard。
    -- 老版本如果没有该命令会直接失败，随后仍可继续尝试属性/PowerShell 回退。
    pcall(mp.commandv, "update-clipboard", "text", "50")

    local ok, text = pcall(mp.get_property, "clipboard/text")
    if ok and type(text) == "string" and trim(text) ~= "" then
        return text
    end

    return nil
end

local function get_linux_clipboard_text_async(callback)
    local candidates = {
        {"wl-paste", "--no-newline"},
        {"xclip", "-selection", "clipboard", "-o"},
        {"xsel", "--clipboard", "--output"},
    }
    local index = 0
    local function try_next()
        index = index + 1
        local args = candidates[index]
        if not args then
            callback(nil, "无法读取剪贴板（需要 wl-paste、xclip 或 xsel）")
            return
        end
        mp.command_native_async({name="subprocess", args=args, playback_only=false,
            capture_stdout=true, capture_stderr=true, capture_size=MAX_CLIPBOARD_BYTES+1},
            function(success, result)
                if success and result and result.status == 0 then
                    callback(result.stdout, nil)
                else
                    try_next()
                end
            end)
    end
    try_next()
end

paste_handler = function()
    if console_open or request_in_flight or not no_media_loaded() then
        return
    end

    local text = get_native_clipboard_text()
    if text then
        handle_clipboard_text(text, nil)
        return
    end

    -- Linux 剪贴板工具作为兼容旧内核的兜底，异步执行避免阻塞 mpv UI。
    request_in_flight = true
    set_binding_enabled(false)
    get_linux_clipboard_text_async(handle_clipboard_text)
end

-- path 变化负责在返回启动页时重新启用绑定。
mp.observe_property("path", "string", function()
    refresh_binding()
end)

-- 打开 mpv 内置 Console/输入框时释放 Ctrl+V，避免抢占正常文本粘贴。
mp.observe_property("user-data/mpv/console/open", "bool", function(_, value)
    console_open = value == true
    refresh_binding()
end)

-- start-file 比等待 path 更新更早，确保任何媒体加载一开始就释放 Ctrl+V。
mp.register_event("start-file", function()
    set_binding_enabled(false)
end)

-- 文件结束/加载失败后，等本轮状态更新完成再判断是否回到启动页。
mp.register_event("end-file", function()
    mp.add_timeout(0, refresh_binding)
end)
