-- Only shorten labels shown in menus and OSD. Keep the original API titles
-- untouched for episode matching and history recovery.
local M = {}

local source_names = {
    dandanplay = '弹弹Play', qq = '腾讯视频', youku = '优酷',
    qiyi = '爱奇艺', imgo = '芒果TV', bilibili1 = '哔哩哔哩',
    ['360'] = '360影视',
}

local media_tags = {'电视剧', '电影', '动漫', '动画', '综艺', '纪录片'}

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$')
end

function M.anime(value)
    local title = trim(value)
    local provider = title:match('[Ff][Rr][Oo][Mm]%s+([%w_%-]+)%s*$')
    title = title:gsub('%s*[Ff][Rr][Oo][Mm]%s+[%w_%-]+%s*$', '')
        :gsub('%s*%(别名：[^)]*%)', '')
        :gsub('%s*（别名：.-）', '')
        :gsub('%s*%((%d%d%d%d)%)', ' (%1)')
        :gsub('%s+', ' ')
    for _, tag in ipairs(media_tags) do
        title = title:gsub('%s*【' .. tag .. '】', '')
    end
    title = trim(title)
    return title ~= '' and title or trim(value), source_names[provider] or provider
end

function M.episode(value)
    local episode = trim(value):gsub('^【[%w_%-]+】%s*', '')
    for _, unit in ipairs({'集', '话', '回'}) do
        local number = episode:match('第%s*(%d+)%s*' .. unit)
        if number then return '第' .. number .. unit end
    end
    local season, part = episode:match('[sS](%d+)[eE](%d+)')
    if season and part then return '第' .. tonumber(part) .. '集' end
    local abbreviated = episode:match('^第%s*(%d+)%s*[eE]$')
    if abbreviated then return '第' .. abbreviated .. '集' end
    return trim(episode)
end

function M.source(source, provider)
    local name = source_names[tostring(source or '')] or trim(source)
    if name == '' then name = '来源未记录' end
    if provider and provider ~= '' and provider ~= name then
        return name .. ' · ' .. provider
    end
    return name
end

return M
