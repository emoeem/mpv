-- Subtitle Cat public HTML: existing links only; never initiate translation.
local M = {}
local ORIGIN = 'https://www.subtitlecat.com'
local MAX_HTML, MAX_RESULTS = 2097152, 100

local function trim(value)
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function utf8(code)
    if not code or code < 0 or code > 1114111 or code >= 55296 and code <= 57343 then return '' end
    if code < 128 then return string.char(code) end
    if code < 2048 then return string.char(192 + math.floor(code / 64), 128 + code % 64) end
    if code < 65536 then
        return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
    end
    return string.char(240 + math.floor(code / 262144), 128 + math.floor(code / 4096) % 64,
        128 + math.floor(code / 64) % 64, 128 + code % 64)
end

local entities = {amp='&', lt='<', gt='>', quot='"', apos="'", nbsp=' '}
function M.decode_entities(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('&([#%w]+);', function(entity)
        if entities[entity] then return entities[entity] end
        local hex = entity:match('^#[xX](%x+)$')
        local decimal = entity:match('^#(%d+)$')
        if hex or decimal then return utf8(tonumber(hex or decimal, hex and 16 or 10)) end
        return '&' .. entity .. ';'
    end))
end

local function clean_html(html)
    if type(html) ~= 'string' or #html == 0 or #html > MAX_HTML then return nil end
    return html:gsub('<!%-%-.-%-%->', '')
        :gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>', '')
        :gsub('<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>', '')
        :gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.*$', '')
end

local function text(html)
    return trim(M.decode_entities(html:gsub('<[^>]*>', ' ')):gsub('[%z\1-\31\127]', ' '):gsub('%s+', ' '))
end

local function attributes(value)
    local attrs = {}
    for name, quote, body in value:gmatch('([%w:_%-]+)%s*=%s*([\'"])(.-)%2') do
        attrs[name:lower()] = M.decode_entities(body)
    end
    return attrs
end

local function percent_decode(value)
    return (value:gsub('%%(%x%x)', function(pair) return string.char(tonumber(pair, 16)) end))
end

local function encoded_path(value)
    local result, i = {}, 1
    while i <= #value do
        local char = value:sub(i, i)
        if char == '%' then
            local pair = value:sub(i+1, i+2)
            if not pair:match('^%x%x$') then return nil end
            result[#result+1], i = '%' .. pair:upper(), i + 3
        else
            local byte = char:byte()
            result[#result+1] = char:match('[%w/_.~!$&\'()*+,;=:@%-]') and byte < 128
                and char or string.format('%%%02X', byte)
            i = i + 1
        end
    end
    return table.concat(result)
end

local function absolute_parts(value)
    if type(value) ~= 'string' then return nil end
    local authority, path = value:match('^https://([^/]+)(/.*)$')
    if not authority then return nil end
    authority = authority:lower()
    if authority ~= 'www.subtitlecat.com' and authority ~= 'subtitlecat.com' then return nil end
    return path
end

-- Only exact HTTPS hosts and /subs/<number>/<single file>.html|srt are allowed.
-- No query, fragment, userinfo, port, encoded separator or dot-segment is accepted.
function M.resolve_url(href, base, kind)
    if type(href) ~= 'string' or #href == 0 or #href > 4096
        or href:find('[%z\1-\31\127\\?#]') or href:find('^//') then return nil end
    local path
    if href:find('^https://') then path = absolute_parts(href)
    elseif href:find('^%a[%w+.-]*:') then return nil
    elseif href:sub(1, 1) == '/' then path = href
    else
        local base_path = absolute_parts(base or (ORIGIN .. '/index.php'))
        if not base_path then return nil end
        path = (base_path:gsub('[?#].*$', ''):match('^(.*)/') or '') .. '/' .. href
    end
    if not path then return nil end
    local encoded = encoded_path(path)
    if not encoded then return nil end
    local decoded = percent_decode(encoded)
    -- Reject nested escapes too; they must not conceal traversal/separators.
    if decoded:find('%%') or decoded:find('[%z\1-\31\127\\?#]') then return nil end
    for part in decoded:gmatch('[^/]+') do if part == '.' or part == '..' then return nil end end
    local extension = kind == 'detail' and 'html' or kind == 'download' and 'srt' or nil
    if not extension or not decoded:match('^/subs/%d+/[^/]+%.' .. extension .. '$') then return nil end
    -- A percent-encoded slash would otherwise change the resource's path shape.
    if encoded:lower():find('%%2f') then return nil end
    return ORIGIN .. encoded
end

function M.is_detail_url(url)
    return type(url) == 'string' and url:find('^https://') ~= nil and M.resolve_url(url, nil, 'detail') ~= nil
end

function M.is_download_url(url)
    return type(url) == 'string' and url:find('^https://') ~= nil and M.resolve_url(url, nil, 'download') ~= nil
end

function M.search_url(query, page)
    if page ~= nil and tonumber(page) ~= 0 then return nil, '字幕猫仅支持首屏搜索，请缩小关键字范围' end
    if type(query) ~= 'string' then return nil, '请输入搜索关键字' end
    query = trim(query)
    if query == '' or #query > 512 then return nil, '搜索关键字为空或过长' end
    local encoded = query:gsub('.', function(char)
        local byte = char:byte()
        return char:match('[%w_.~%-]') and byte < 128 and char or string.format('%%%02X', byte)
    end)
    return ORIGIN .. '/index.php?search=' .. encoded
end

function M.parse_search(html, base, page)
    if page ~= nil and tonumber(page) ~= 0 then return nil, nil, '字幕猫仅支持首屏搜索' end
    html = clean_html(html)
    if not html then return nil, nil, '字幕猫网页为空或过大' end
    local rows
    for attrs, body in html:gmatch('<[tT][aA][bB][lL][eE]%s+([^>]-)>(.-)</[tT][aA][bB][lL][eE]%s*>') do
        local class = attributes(attrs).class or ''
        if (' ' .. class .. ' '):find(' sub%-table ') then rows = body; break end
    end
    if not rows then
        if html:find('Nothing found', 1, true) or html:find('>0 subtitles found', 1, true) then return {}, nil end
        return nil, nil, '字幕猫网页格式异常，可能需要在浏览器确认站点状态'
    end
    local items, seen = {}, {}
    for row in rows:gmatch('<[tT][rR][^>]*>(.-)</[tT][rR]%s*>') do
        for attrs, body in row:gmatch('<[aA]%s+([^>]-)>(.-)</[aA]%s*>') do
            local url = M.resolve_url(attributes(attrs).href, base, 'detail')
            local title = text(body)
            if url and title ~= '' and #title <= 2048 and not seen[url] then
                seen[url] = true
                local hint = text(row:match('</[aA]%s*>(.-)</[tT][dD]%s*>') or '')
                items[#items+1] = {title=title, url=url, hint=hint ~= '' and hint or nil}
                if #items >= MAX_RESULTS then return items, nil end
                break
            end
        end
    end
    -- The public site offers show=1000 (bulk expansion), not bounded pages.
    return items, nil
end

local languages = {['zh-cn']={code='zh-CN',title='简体中文',rank=1},
    ['zh-tw']={code='zh-TW',title='繁體中文',rank=2},
    en={code='en',title='English',rank=3}, orig={code='original',title='原始字幕',rank=4}}

function M.parse_details(html, base)
    if not M.is_detail_url(base) then return nil, '字幕猫详情地址无效' end
    html = clean_html(html)
    if not html then return nil, '字幕猫详情网页为空或过大' end
    if not html:find('sub%-single') and not html:find('All language subtitles for', 1, true)
        and not html:find('Original subtitles', 1, true) then return nil, '字幕猫详情网页格式异常' end
    local files, seen = {}, {}
    for attrs, body in html:gmatch('<[aA]%s+([^>]-)>(.-)</[aA]%s*>') do
        local a = attributes(attrs)
        local url = M.resolve_url(a.href, base, 'download')
        local id = (a.id or ''):lower():match('^download_(.+)$')
        if id == 'original' then id = 'orig' end
        if url and not id and url:lower():find('%-orig%.srt$') then id = 'orig' end
        local language = languages[id]
        if url and language and text(body) ~= '' and not seen[url] then
            seen[url] = true
            files[#files+1] = {title=language.title, lang=language.code, language=language.code,
                url=url, filename=percent_decode(url:match('([^/]+)$')), ext='srt',
                original=id == 'orig', rank=language.rank}
        end
    end
    table.sort(files, function(a, b) return a.rank < b.rank end)
    for _, file in ipairs(files) do file.rank = nil end
    return files
end

return M
