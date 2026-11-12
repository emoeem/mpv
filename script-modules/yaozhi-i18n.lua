-- Player UI language is independent of audio/subtitle preferences. Read once
-- per script instance; changing the remembered preference takes effect on restart.
local mp = require 'mp'
local utils = require 'mp.utils'
local M = {}
local PREF = '~~/script-opts/yaozhi-language.conf'
local function path(value)
    local ok, result = pcall(mp.command_native, {'expand-path', value})
    -- With --no-config mpv expands ~~ to a relative path. Do not read/write
    -- accidental files in the working directory in that mode.
    return ok and type(result) == 'string'
        and (result:match('^%a:[/\\]') or result:match('^[/\\]')) and result or nil
end
local persistence
local function storage()
    if persistence then return persistence end
    local location = path('~~/script-modules/yaozhi-persistence.lua')
    local ok, module = pcall(dofile, location or '')
    if ok and type(module) == 'table' then persistence = module end
    return persistence
end
local function read_file(name, limit)
    if not name then return nil end
    local reliable = storage()
    if reliable then
        local raw, _, code = reliable.read(name, limit)
        if raw then return #raw <= limit and raw or nil end
        if code ~= 'unsupported' then return nil end
    end
    local file = io.open(name, 'rb')
    if not file then return nil end
    local raw = file:read(limit + 1); file:close()
    return raw and #raw <= limit and raw or nil
end
local function read_language()
    local raw = read_file(path(PREF), 16384) or ''
    raw = raw:gsub('^\239\187\191', '')
    local selected
    for line in (raw .. '\n'):gmatch('([^\r\n]*)[\r\n]') do
        local value = line:match('^%s*language%s*=%s*([^#]-)%s*$')
        if value then selected = value end
    end
    return selected == 'en' and 'en' or 'zh-CN'
end
local language = read_language()
local catalog = {}
if language == 'en' then
    local raw = read_file(path('~~/script-assets/i18n/en.json'), 4 * 1024 * 1024)
    local ok, value = pcall(utils.parse_json, raw or '')
    if ok and type(value) == 'table' then
        for key, text in pairs(value) do
            if type(key) == 'string' and type(text) == 'string' then catalog[key] = text end
        end
    end
end
function M.language() return language end
function M.is_english() return language == 'en' end
local function format(text, ...)
    if select('#', ...) == 0 then return text end
    local ok, value = pcall(string.format, text, ...)
    return ok and value or text
end
function M.t(text, ...)
    if type(text) ~= 'string' then return text end
    return format(language == 'en' and (catalog[text] or text) or text, ...)
end

-- Match only catalogued UI templates. No substring replacement or translation
-- of user content: callers must explicitly choose a UI display boundary.
local patterns
local cache, cache_order = {}, {}
local function cached(original, translated)
    if #cache_order >= 256 then cache[table.remove(cache_order, 1)] = nil end
    cache[original] = translated
    cache_order[#cache_order + 1] = original
    return translated
end
local function pattern_for(source, translated)
    local pieces, slots, at = {}, {}, 1
    while at <= #source do
        local first, last, spec = source:find('%%([%d%.%-+ #]*[sdifegqu])', at)
        local literal = source:sub(at, first and first - 1 or #source)
        literal = literal:gsub('%%%%', '%%')
        pieces[#pieces + 1] = literal:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1')
        if not first then break end
        slots[#slots + 1] = spec
        pieces[#pieces + 1] = spec:match('[difegu]$') and '([%+%-]?[%d%.]+)' or '(.-)'
        at = last + 1
    end
    if #slots == 0 then return nil end
    -- A bare placeholder must never become a catch-all translator.
    if not source:find('[\128-\255]') then return nil end
    return {pattern = '^' .. table.concat(pieces) .. '$', text = translated,
        slots = slots, prefix = source:match('^([^%%]+)') or ''}
end
function M.text(text)
    if language ~= 'en' or type(text) ~= 'string' or text == '' then return text end
    if catalog[text] then return catalog[text] end
    if cache[text] then return cache[text] end
    if not patterns then
        patterns = {}
        for source, translated in pairs(catalog) do
            local item = pattern_for(source, translated)
            if item then patterns[#patterns + 1] = item end
        end
        table.sort(patterns, function(a, b) return #a.prefix > #b.prefix end)
    end
    for _, item in ipairs(patterns) do
        if text:sub(1, #item.prefix) == item.prefix then
            local values = {text:match(item.pattern)}
            if #values == #item.slots then
                local index = 0
                return cached(text, (item.text:gsub('%%([%d%.%-+ #]*[sdifegqu%%])', function(spec)
                    if spec == '%' then return '%' end
                    index = index + 1
                    return values[index] or ('%' .. spec)
                end)))
            end
        end
    end
    return cached(text, text)
end

-- Only for application-owned composite status labels, never media metadata.
function M.status(text)
    if type(text) ~= 'string' or language ~= 'en' then return text end
    local translated = M.text(text)
    if translated ~= text then return translated end
    local pieces = {}
    for piece in (text .. ' · '):gmatch('(.-) · ') do pieces[#pieces + 1] = M.text(piece) end
    return #pieces > 1 and table.concat(pieces, ' · ') or text
end

function M.preference_path() return path(PREF) end
function M.remember(selected)
    if selected ~= 'en' and selected ~= 'zh-CN' then return nil, 'Invalid UI language' end
    local destination = M.preference_path()
    if not destination then return nil, 'UI language path unavailable' end
    local persistence = storage()
    if not persistence then return nil, 'Reliable language persistence unavailable' end
    local saved, err, code = persistence.update_options(destination, {language = selected})
    if saved or err ~= 'The settings file is missing' then return saved, err, code end
    -- Create a removed/legacy preference through the same atomic transaction.
    -- If another window created it meanwhile, merge into its latest contents.
    saved, err, code = persistence.update(destination, function(_, missing)
        if not missing then return nil, 'Language preference appeared' end
        return '# Player interface language. Restart the player after changing.\nlanguage=' .. selected .. '\n'
    end)
    if not saved and err == 'Language preference appeared' then
        return persistence.update_options(destination, {language = selected})
    end
    return saved, err, code
end
return M
