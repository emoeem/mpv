local M = {}

local function lower(value)
    return tostring(value or ''):lower()
end

local function positive_number(value)
    local number = tonumber(value)
    return number and number > 0 and number or nil
end

local function layout_label(value)
    local text = lower(value)
    if text == '' then return nil end

    if text:find('7%.1', 1, false) then return '7.1' end
    if text:find('5%.1', 1, false) then return '5.1' end
    if text:find('2%.1', 1, false) then return '2.1' end
    if text:find('stereo', 1, true) or text:find('2ch', 1, true) then
        return '2.0'
    end
    if text:find('mono', 1, true) or text:find('1ch', 1, true) then
        return '1.0'
    end
    return text:match('([1-9]%.[0-9])')
end

local function channel_label(params)
    if type(params) ~= 'table' then return nil end

    local layout = layout_label(
        params['hr-channels']
            or params['channels']
            or params['channel-layout']
    )
    if layout then return layout end

    local count = positive_number(params['channel-count'])
    if not count then return nil end
    if count == 8 then return '7.1' end
    if count == 6 then return '5.1' end
    if count == 2 then return '2.0' end
    if count == 1 then return '1.0' end
    return tostring(count) .. 'ch'
end

function M.is_passthrough(format)
    local text = lower(format)
    return text:match('^spdif%-') ~= nil
        or text:find('iec61937', 1, true) ~= nil
        or text:find('bitstream', 1, true) ~= nil
end

function M.source_channel_label(track)
    if type(track) ~= 'table' then return nil end

    local layout = layout_label(
        track['demux-channels']
            or track['demux-channel-layout']
            or track['channel-layout']
    )
    if layout then return layout end

    local count = positive_number(track['demux-channel-count'])
        or positive_number(track['audio-channels'])
    if not count then return nil end
    if count == 8 then return '7.1' end
    if count == 6 then return '5.1' end
    if count == 2 then return '2.0' end
    if count == 1 then return '1.0' end
    return tostring(count) .. 'ch'
end

function M.params_channel_label(params)
    return channel_label(params)
end

function M.merge_channel_labels(input_params, output_params)
    local input_label = channel_label(input_params)
    local output_label = channel_label(output_params)
    if not input_label then return output_label end
    if not output_label or input_label == output_label then return input_label end
    return input_label .. ' ➜ ' .. output_label
end

function M.source_samplerate(track)
    if type(track) ~= 'table' then return nil end
    return positive_number(track['demux-samplerate'])
        or positive_number(track['samplerate'])
end

function M.passthrough_format_label(format, track)
    local raw = tostring(format or '')
    if raw == '' then return nil end

    local names = {
        ['spdif-ac3'] = 'AC-3',
        ['spdif-eac3'] = 'E-AC-3',
        ['spdif-dts'] = 'DTS',
        ['spdif-dtshd'] = 'DTS-HD',
        ['spdif-truehd'] = 'TrueHD',
    }
    local name = names[lower(raw)]
    if not name and type(track) == 'table' then
        local codec = lower(track.codec)
        if codec == 'ac3' then name = 'AC-3' end
        if codec == 'eac3' then name = 'E-AC-3' end
        if codec == 'dts' or codec == 'dca' then name = 'DTS' end
        if codec == 'dts-hd' or codec == 'dtshd' then name = 'DTS-HD' end
        if codec == 'truehd' or codec == 'mlp' then name = 'TrueHD' end
    end
    if not name then return raw end
    return name .. ' 直通 [' .. raw .. ']'
end

return M
