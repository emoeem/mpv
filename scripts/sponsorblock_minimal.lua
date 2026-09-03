-- sponsorblock_minimal.lua v 0.5.1
--
-- This script skip/mute sponsored segments of YouTube and bilibili videos
-- using data from https://github.com/ajayyy/SponsorBlock
-- and https://github.com/hanydd/BilibiliSponsorBlock

local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local options = {
    youtube_sponsor_server = "https://sponsor.ajay.app/api/skipSegments",
    bilibili_sponsor_server = "https://bsbsb.top/api/skipSegments",
    -- Categories to fetch
    -- Perform skip/mute/mark chapter based on the 'actionType' returned
    categories = '"sponsor"',
    connect_timeout = 5,
    request_timeout = 10,
}

opt.read_options(options)

local ranges = nil
local pending_request = nil
local request_generation = 0
local observing_time = false
local mute_before_sponsor = false
local muted_by_sponsorblock = false

local function positive_timeout(value, fallback)
    value = tonumber(value)
    if not value or value <= 0 then return tostring(fallback) end
    return tostring(value)
end

local function fetch_ranges(url, callback)
    local request = mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = {
            "curl", "-L", "-sS", "-g",
            "--connect-timeout", positive_timeout(options.connect_timeout, 5),
            "--max-time", positive_timeout(options.request_timeout, 10),
            "-H", "origin: mpv-script/sponsorblock_minimal",
            "-H", "x-ext-version: 0.5.1",
            url
        }
    }, function(success, result, error)
        if not success or type(result) ~= "table" or result.status ~= 0 then
            local reason = error
                or (type(result) == "table" and result.stderr)
                or "unknown error"
            callback(nil, tostring(reason):gsub("%s+$", ""))
            return
        end

        local parsed = utils.parse_json(result.stdout or "")
        if type(parsed) ~= "table" then
            msg.verbose("SponsorBlock returned no usable ranges")
            callback(nil)
            return
        end

        callback(parsed)
    end)

    return request
end

local function normalize_ranges(value)
    local normalized = {}
    if type(value) ~= "table" then return normalized end

    for _, item in ipairs(value) do
        local segment = type(item) == "table" and item.segment or nil
        local start_time = type(segment) == "table" and tonumber(segment[1]) or nil
        local end_time = type(segment) == "table" and tonumber(segment[2]) or nil
        local action_type = type(item) == "table" and item.actionType or nil
        if start_time and end_time and end_time > start_time
            and (action_type == nil or action_type == "skip" or action_type == "mute") then
            normalized[#normalized + 1] = {
                segment = {start_time, end_time},
                actionType = action_type or "skip",
            }
        end
    end

    return normalized
end

local function skip_ads(_, pos)
    if pos ~= nil and ranges ~= nil then
        local in_mute_segment = false
        for _, v in pairs(ranges) do
            if v.actionType == "skip" and v.segment[1] <= pos and v.segment[2] > pos then
                --this message may sometimes be wrong
                --it only seems to be a visual thing though
                local time = math.floor(v.segment[2] - pos)
                mp.osd_message(string.format("[sponsorblock] skipping forward %ds", time))
                --need to do the +0.01 otherwise mpv will start spamming skip sometimes
                mp.set_property("time-pos", v.segment[2] + 0.01)
            elseif v.actionType == "mute" and v.segment[1] <= pos and v.segment[2] >= pos then
                in_mute_segment = true
            end
        end

        if in_mute_segment and not muted_by_sponsorblock then
            mute_before_sponsor = mp.get_property_bool("mute", false)
            mp.set_property_bool("mute", true)
            muted_by_sponsorblock = true
        elseif not in_mute_segment and muted_by_sponsorblock then
            mp.set_property_bool("mute", mute_before_sponsor)
            muted_by_sponsorblock = false
        end
    end
end

local function reset_state()
    request_generation = request_generation + 1

    if pending_request then
        mp.abort_async_command(pending_request)
        pending_request = nil
    end
    if observing_time then
        mp.unobserve_property(skip_ads)
        observing_time = false
    end
    if muted_by_sponsorblock then
        mp.set_property_bool("mute", mute_before_sponsor)
        muted_by_sponsorblock = false
    end
    ranges = nil
end

local function extract_video_id(video_path, video_referer, purl)
    local urls = {
        "ytdl://youtu%.be/([%w-_]+).*",
        "ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
        "ytdl://w?w?w?%.?bilibili%.com/video/([%w-_]+).*",
        "https?://youtu%.be/([%w-_]+).*",
        "https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
        "https?://w?w?w?%.?bilibili%.com/video/([%w-_]+).*",
        "/watch.*[?&]v=([%w-_]+).*",
        "/embed/([%w-_]+).*",
        "/shorts/([%w-_]+).*",
        "/live/([%w-_]+).*",
        "^ytdl://([%w-_]+)$",
    }

    local video_id = nil
    for _, url in ipairs(urls) do
        video_id = video_path:match(url) or video_referer:match(url) or purl:match(url)
        if video_id then break end
    end
    return video_id
end

local function file_loaded()
    reset_state()

    local video_path = mp.get_property("path", "")
    local video_referer = mp.get_property("http-header-fields", ""):match("[Rr]eferer:%s*([^,\r\n]+)") or ""
    local purl = mp.get_property("metadata/by-key/PURL", "")
    local video_id = extract_video_id(video_path, video_referer, purl)

    if not video_id or string.len(video_id) < 11 then return end

    local bilibili = video_path:match("bilibili%.com/video")
        or video_referer:match("bilibili%.com/video")
        or purl:match("bilibili%.com/video")
        or video_id:match("^BV[%w]+$")
    local sponsor_server
    if bilibili then
        sponsor_server = options.bilibili_sponsor_server
        video_id = string.sub(video_id, 1, 12)
    else
        sponsor_server = options.youtube_sponsor_server
        video_id = string.sub(video_id, 1, 11)
    end

    local url = ("%s?videoID=%s&categories=[%s]"):format(sponsor_server, video_id, options.categories)
    local this_generation = request_generation

    pending_request = fetch_ranges(url, function(result, error)
        if this_generation ~= request_generation then return end
        pending_request = nil
        if error then
            msg.warn("SponsorBlock request failed: " .. error)
            return
        end
        ranges = normalize_ranges(result)
        if #ranges > 0 then
            observing_time = true
            mp.observe_property("time-pos", "native", skip_ads)
        end
    end)
end

local function end_file()
    reset_state()
end

mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
