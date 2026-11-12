-- Filename suggestions only. User-entered queries must bypass format_filename.
local M = {}
local unpack = table.unpack or unpack
local thin_space = string.char(0xE2, 0x80, 0x89)
local resolutions = {['240']=true, ['360']=true, ['480']=true, ['576']=true,
    ['720']=true, ['1080']=true, ['1440']=true, ['2160']=true, ['4320']=true}
local media_extensions = {}
for ext in ('mkv mp4 m4v webm avi mov wmv ts m2ts mts mpeg mpg flv ogv ogg '
    .. 'mp3 m4a aac flac wav opus ape rm rmvb 3gp vob asf'):gmatch('%S+') do
    media_extensions[ext] = true
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.url_encode(value)
    if value == nil then return nil end
    return (tostring(value):gsub('.', function(c)
        local b = c:byte()
        if b >= 48 and b <= 57 or b >= 65 and b <= 90 or b >= 97 and b <= 122
            or c == '-' or c == '.' or c == '_' or c == '~' then return c end
        return string.format('%%%02X', b)
    end))
end

-- Validate and bound complete UTF-8 code points; replace malformed input bytes.
local function utf8_prefix(value, limit)
    local parts, used, i = {}, 0, 1
    while i <= #value do
        local b = value:byte(i)
        local n = b < 128 and 1 or b >= 194 and b <= 223 and 2
            or b >= 224 and b <= 239 and 3 or b >= 240 and b <= 244 and 4
        local valid = n and i + n - 1 <= #value
        if valid then
            for j = i+1, i+n-1 do
                local c = value:byte(j)
                if c < 128 or c > 191 then valid = false; break end
            end
            local c = value:byte(i+1)
            if n >= 3 and (b == 224 and c < 160 or b == 237 and c > 159
                or b == 240 and c < 144 or b == 244 and c > 143) then valid = false end
        end
        local part = valid and value:sub(i, i+n-1) or '_'
        if used + #part > limit then break end
        parts[#parts+1], used = part, used + #part
        i = i + (valid and n or 1)
    end
    return table.concat(parts)
end

local function reserved_name(name)
    local stem = name:match('^[^.]*'):gsub('[%.%s]+$', ''):upper()
    local serial = stem:match('^COM(.+)$') or stem:match('^LPT(.+)$')
    return stem == 'CON' or stem == 'PRN' or stem == 'AUX' or stem == 'NUL'
        or stem == 'CONIN$' or stem == 'CONOUT$'
        or stem:match('^COM[1-9]$') or stem:match('^LPT[1-9]$')
        or serial == '¹' or serial == '²' or serial == '³'
end

function M.sanitize_name(name, max_bytes)
    local limit = math.max(1, math.floor(tonumber(max_bytes) or 120))
    name = trim(tostring(name or 'subtitle'):gsub('[%z\1-\31\\/:*?"<>|]', '_'))
    name = utf8_prefix(name, limit):gsub('[%.%s]+$', '')
    if name == '' then name = ('subtitle'):sub(1, limit) end
    if reserved_name(name) then name = utf8_prefix('_' .. name, limit):gsub('[%.%s]+$', '') end
    return name
end

local function clean_name(name)
    return name:gsub("^%[.-%]", " ")
        :gsub("^%(.-%)", " ")
        :gsub("[_%.%[%]]", " ")
        :gsub("^%s*(.-)%s*$", "%1")
        :gsub("[!@#%.%?%+%-%%&*_=,/~`]+$", "")
end

-- Formatters for media titles
local formatters = {
    {
        regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)[_%.%s]%d%d[_%.%s]%d%d%s*[_%.%s]?(.-)%s*[_%.%s]%d+[pPkKxXbBfF]",
        format = function(name, year, subtitle)
            local title = clean_name(name)
            if subtitle then
                title = title .. ": " .. subtitle:gsub("%.", " "):gsub("^%s*(.-)%s*$", "%1")
            end
            return title .. " (" .. year .. ")"
        end,
    },
    {
        regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)%s*[_%.%s]%s*[sS](%d+)[%.%-%s:]?[eE](%d+%.?%d*)",
        format = function(name, year, season, episode)
            return clean_name(name) .. " (" .. year .. ") S" .. season .. "E" .. episode
        end,
    },
    {
        regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)%s*[_%.%s]%s*[eEpP]+(%d+%.?%d*)",
        format = function(name, year, episode)
            return clean_name(name) .. " (" .. year .. ") E" .. episode
        end,
    },
    {
        regex = "^(.-)%s*[_%-%.%s]%s*[sS](%d+)[%.%-%s:]?[eE](%d+[%.v]?%d*)%s*[_%.%s]%s*(%d%d%d%d)[^%dhHxXvVpPkKxXbBfF]",
        format = function(name, season, episode, year)
            return clean_name(name) .. " (" .. year .. ") S" .. season .. "E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*[_%-%.%s]%s*[sS](%d+)[%.%-%s:]?[eE](%d+%.?%d*)",
        format = function(name, season, episode)
            return clean_name(name) .. " S" .. season .. "E" .. episode
        end,
    },
    {
        regex = "^(.-)%s*[_%.%s]%s*(%d+)[nrdsth]+[_%.%s]%s*[sS]eason[_%.%s]%s*%[(%d+[%.v]?%d*)%]",
        format = function(name, season, episode)
            return clean_name(name) .. " S" .. season .. "E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*([^dD])[eEpP]+(%d+[%.v]?%d*)[_%.%s]%s*(%d%d%d%d)[^%dhHxXvVpPkKxXbBfF]",
        format = function(name, previous, episode, year)
            return clean_name(name .. previous) .. " (" .. year .. ") E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*([^dD])[eEpP]+(%d+%.?%d*)",
        format = function(name, previous, episode)
            return clean_name(name .. previous) .. " E" .. episode
        end,
    },
    {
        regex = "^(.-)%s*第%s*(%d+[%.v]?%d*)%s*话",
        format = function(name, episode)
            return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*第%s*(%d+[%.v]?%d*)%s*回",
        format = function(name, episode)
            return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*第%s*(%d+[%.v]?%d*)%s*集",
        format = function(name, episode)
            return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*%[(%d+[%.v]?%d*)%]",
        format = function(name, episode)
            return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*%[(%d+[%.v]?%d*)%(%a+%)%]",
        format = function(name, episode)
            return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
        end,
    },
    {
        regex = "^(.-)%s*[%-#]%s*(%d+%.?%d*)%s*",
        format = function(name, episode)
            return clean_name(name) .. " E" .. episode
        end,
    },
    {
        regex = "^(.-)%s*[%[%(]([OVADSPs]+)[%]%)]",
        format = function(name, sp)
            return clean_name(name) .. " [" .. sp .. "]"
        end,
    },
    {
        regex = "^(.-)%s*[_%-%.%s]%s*(%d?%d)x(%d%d?%d?%d?)[^%dhHxXvVpPkKxXbBfF]",
        format = function(name, season, episode)
            return clean_name(name) .. " S" .. season .. "E" .. episode
        end,
    },
    {
        regex = "^%((%d%d%d%d)%.?%d?%d?%.?%d?%d?%)%s*(.-)%s*[%(%[]",
        format = function(year, name)
            return clean_name(name) .. " (" .. year .. ")"
        end,
    },
    {
        regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)[^%dhHxXvVpPkKxXbBfF]",
        format = function(name, year)
            return clean_name(name) .. " (" .. year .. ")"
        end,
    },
    {
        regex = "^%[.-%]%s*%[?(.-)%]?%s*[%(%[]",
        format = function(name)
            return clean_name(name)
        end,
    },
}

function M.format_filename(title)
    title = tostring(title or '')
    -- A release resolution after a dot is not the fractional episode number.
    title = title:gsub('([eEpP]%d+)%.(%d+)([pPiI])', function(episode, size, scan)
        if resolutions[size] then return episode .. ' ' .. size .. scan end
        return episode .. '.' .. size .. scan
    end)
    for _, formatter in ipairs(formatters) do
        local matches = {title:match(formatter.regex)}
        if #matches > 0 then return formatter.format(unpack(matches)) end
    end
    return title:gsub('^%[.-%]', ' '):gsub('^%(.-%)', ' ')
        :gsub('[_%.]', ' '):gsub('^%s*(.-)%s*$', '%1')
        :gsub('[!@#%.%?%+%-%%&*_=,/~`]+$', '')
end

local function is_url(value)
    return type(value) == 'string' and value:find('^%a[%w+.-]*://') ~= nil
end

local function strip_media_extension(title)
    local ext = title:match('%.([%w]+)$')
    if ext and media_extensions[ext:lower()] then
        return title:sub(1, #title - #ext - 1), true
    end
    return title, false
end

local function url_basename(url)
    -- Remove actual URL delimiters before decoding escaped path characters.
    local path = url:gsub('[?#].*$', ''):gsub('^%a[%w+.-]*://[^/]*', '')
    local name = path:match('([^/]*)$') or ''
    return (name:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local function release_name(title)
    if title:find('[sS]%d+[%.%-%s:]?[eE]%d+') then return true end
    for size in pairs(resolutions) do
        if title:find('%f[%d]' .. size .. '[pPiI]%f[%W]') then return true end
    end
    return title:find('%f[%d][248][kK]%f[%W]') ~= nil
end

function M.initial_query(path, filename, media_title, source)
    if not path then return nil end
    filename = type(filename) == 'string' and filename or ''
    local title = type(media_title) == 'string' and media_title or filename
    title = title:gsub(thin_space, ' ')
    if is_url(path) then
        local from_url = is_url(title)
        if from_url then title = url_basename(title) end
        local stripped, has_extension = strip_media_extension(title)
        if not from_url and not has_extension and not release_name(title) then
            return trim(title)
        end
        title = stripped
    elseif #title < #filename then
        title = filename:gsub(thin_space, ' ')
    end
    if source == 'xunlei' then
        return trim(title:gsub('%s*E%d+$', ''):gsub('[_%.]', ' '))
    end
    return trim(M.format_filename(title):gsub('%s*E%d+$', ''))
end

return M
