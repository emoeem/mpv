-- Pure URL router for the online-media integration.
-- Keep platform recognition here; network access and extraction belong to resolvers.

local M = {}

local function parse_http_url(url)
    if type(url) ~= 'string' then return nil end
    local scheme, authority, path = url:match('^([%a][%w+%.%-]*)://([^/%?#]+)([^%?#]*)')
    if not scheme or not authority then return nil end
    scheme = scheme:lower()
    if scheme ~= 'http' and scheme ~= 'https' then return nil end
    if authority:find('@', 1, true) then return nil end

    local host, port = authority:match('^([^:]+):(%d+)$')
    if not host then
        -- IPv6 literals and malformed authorities are deliberately outside this
        -- platform-page allowlist. They remain available to mpv's native loader.
        if authority:find(':', 1, true) then return nil end
        host = authority
    elseif port ~= '80' and port ~= '443' then
        return nil
    end

    host = host:lower():gsub('%.$', '')
    return {scheme = scheme, host = host, path = path ~= '' and path or '/'}
end

function M.classify(url)
    local parsed = parse_http_url(url)
    if not parsed then return nil end
    local host, path = parsed.host, parsed.path

    if host == 'live.bilibili.com' and path:match('^/[A-Za-z0-9_%-]+/?') then
        return {platform = 'bilibili', kind = 'bilibili-live', content_type = 'live'}
    end

    if host == 'b23.tv' and path ~= '/' then
        return {platform = 'bilibili', kind = 'bilibili-short', content_type = 'video'}
    end

    local bili_hosts = {
        ['bilibili.com'] = true,
        ['www.bilibili.com'] = true,
        ['m.bilibili.com'] = true,
    }
    if bili_hosts[host] then
        if path:match('^/video/[Bb][Vv][%w]+') or path:match('^/video/[Aa][Vv]%d+')
                or path:match('^/bangumi/play/[eEsSmM][pSdD]%d+') then
            return {platform = 'bilibili', kind = 'bilibili-video', content_type = 'video'}
        end
    end

    if host == 'live.douyin.com' and path:match('^/[A-Za-z0-9_%-]+/?') then
        return {platform = 'douyin', kind = 'douyin-live', content_type = 'live'}
    end

    if (host == 'v.douyin.com' and path ~= '/')
            or (host == 'www.iesdouyin.com' and path:match('^/share/live/')) then
        return {platform = 'douyin', kind = 'douyin-share', content_type = 'live'}
    end

    local douyu_hosts = {
        ['douyu.com'] = true,
        ['www.douyu.com'] = true,
        ['m.douyu.com'] = true,
    }
    if douyu_hosts[host]
            and (path:match('^/%d+/?$') or path:match('^/topic/%d+/?$')) then
        return {platform = 'douyu', kind = 'douyu-live', content_type = 'live'}
    end

    local huya_hosts = {
        ['huya.com'] = true,
        ['www.huya.com'] = true,
        ['m.huya.com'] = true,
    }
    local huya_channel = huya_hosts[host] and path:match('^/([A-Za-z0-9_%-]+)/?$') or nil
    local huya_reserved = {
        l = true, live = true, lives = true, category = true,
        g = true, m = true, search = true,
    }
    if huya_channel and not huya_reserved[huya_channel:lower()] then
        return {platform = 'huya', kind = 'huya-live', content_type = 'live'}
    end

    return nil
end

return M
