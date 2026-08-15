-- playlist-view: press P to show playlist info
mp.add_key_binding("P", "playlist-view", function()
    local count = mp.get_property_number("playlist-count", 0)
    local pos = mp.get_property_number("playlist-pos", 0) + 1
    mp.osd_message(string.format("playlist: %d/%d items", pos, count), 3)
end)
