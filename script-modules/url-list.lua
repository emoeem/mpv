local M = {}

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

---Parse one URL or a newline-delimited M3U URL list.
---@param text string
---@return string[]|nil urls
---@return string|nil error
function M.parse(text)
    text = tostring(text or ''):gsub('^\239\187\191', '')
    local urls, seen = {}, {}
    local invalid = nil
    local is_hls_manifest = false

    for raw_line in (text .. '\n'):gmatch('(.-)\r?\n') do
        local line = trim(raw_line)
        if line:match('^#EXT%-X%-') then
            is_hls_manifest = true
        elseif line ~= '' and not line:match('^#') then
            if not line:match('^https?://') then
                invalid = line
                break
            end
            if not seen[line] then
                seen[line] = true
                urls[#urls + 1] = line
            end
        end
    end

    if is_hls_manifest then
        return nil, '检测到 HLS 清单正文，请粘贴该 m3u8 文件的网址，而不是分片列表'
    end
    if invalid then
        return nil, '存在非 HTTP(S) 链接：' .. invalid
    end
    if #urls == 0 then
        return nil, '没有找到可用的 HTTP(S) 视频链接'
    end
    return urls, nil
end

return M
