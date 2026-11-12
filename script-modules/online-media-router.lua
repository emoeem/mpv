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
    return {
        scheme = scheme,
        host = host,
        path = path ~= '' and path or '/',
        query = url:match('%?([^#]*)') or '',
    }
end

local function query_value(query, target)
    for field in tostring(query or ''):gmatch('[^&]+') do
        local key, value = field:match('^([^=]+)=?(.*)$')
        if key == target then return value end
    end
end

function M.classify(url)
    local parsed = parse_http_url(url)
    if not parsed then return nil end
    local host, path = parsed.host, parsed.path

    local youtube_id
    if host == 'youtu.be' then
        youtube_id = path:match('^/([A-Za-z0-9_%-]+)/?$')
    else
        local youtube_hosts = {
            ['youtube.com'] = true,
            ['www.youtube.com'] = true,
            ['m.youtube.com'] = true,
            ['music.youtube.com'] = true,
        }
        if youtube_hosts[host] then
            if path == '/watch' or path == '/watch/' then
                youtube_id = query_value(parsed.query, 'v')
            else
                youtube_id = path:match('^/shorts/([A-Za-z0-9_%-]+)/?$')
                    or path:match('^/live/([A-Za-z0-9_%-]+)/?$')
                    or path:match('^/embed/([A-Za-z0-9_%-]+)/?$')
            end
        end
    end
    if youtube_id and #youtube_id == 11
            and youtube_id:match('^[A-Za-z0-9_%-]+$') then
        return {platform = 'youtube', kind = 'youtube-video', content_type = 'video'}
    end

    if host == 'live.bilibili.com'
            and (path:match('^/%d+/?$') or path:match('^/blanc/%d+/?$')) then
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
        -- 大小写两种写法都要认：`ep` / `ss` / `md` 三个前缀各自都有小写与大写
        -- 入口，缺一个字母这里就会静默漏掉（`ss` 曾因为第二组没有小写 s 而漏掉，
        -- 于是整季链接落到 mpv 手里当成网页打开）。数字前缀后面才是 id。
        if path:match('^/video/[Bb][Vv][%w]+') or path:match('^/video/[Aa][Vv]%d+')
                or path:match('^/bangumi/play/[eE][pP]%d+/?$')
                or path:match('^/bangumi/play/[sS][sS]%d+/?$')
                or path:match('^/bangumi/play/[mM][dD]%d+/?$') then
            return {platform = 'bilibili', kind = 'bilibili-video', content_type = 'video'}
        end
    end

    -- 路径允许为空：抖音直播首页/推荐位把当前房间号放在 query 的 live_web_rid 里
    -- （`live.douyin.com/?live_web_rid=87787514002`），路径只有 `/`，不含房间信息。
    -- 是不是直播间由解析器判定，路由器只负责认出平台。
    if host == 'live.douyin.com' and path:match('^/[A-Za-z0-9_%-]*/?') then
        return {platform = 'douyin', kind = 'douyin-live', content_type = 'live'}
    end

    -- 抖音直播搜索结果页同样把房间号放在 live_web_rid 里
    -- （`www.douyin.com/search/…?type=live&live_web_rid=…`），路径里没有房间号。
    -- 只放行带合法房间号的链接，普通视频页/用户页不在这里识别。
    if host == 'douyin.com' or host == 'www.douyin.com' then
        -- Following-feed live pages carry the room in the path. anchor_id is
        -- the broadcaster identity, not the live room number.
        if path:match('^/follow/live/%d%d%d%d+/?$') then
            return {platform = 'douyin', kind = 'douyin-live', content_type = 'live'}
        end
        local douyin_room = query_value(parsed.query, 'live_web_rid') or ''
        if douyin_room:match('^%d%d%d%d+$') then
            return {platform = 'douyin', kind = 'douyin-live', content_type = 'live'}
        end
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
