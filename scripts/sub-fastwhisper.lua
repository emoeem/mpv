-- sub-fastwhisper: 使用 whisper-cli 生成字幕
-- 按 Ctrl+w 为当前视频生成 srt 字幕

local function generate_subtitles()
    local path = mp.get_property("path")
    if not path or path == "" then
        mp.osd_message("无视频文件", 2)
        return
    end

    if path:match("^https?://") then
        mp.osd_message("在线视频不支持", 2)
        return
    end

    local base = path:match("^(.*)%.[^%.]+$") or path
    local srt_path = base .. ".srt"

    local f = io.open(srt_path, "r")
    if f then
        f:close()
        mp.osd_message("加载已有字幕", 1)
        mp.commandv("sub_add", srt_path)
        return
    end

    local audio_file = "/tmp/voicefox_whisper_" .. mp.get_property("pid") .. ".wav"
    mp.osd_message("正在提取音频...", 0)

    os.execute(string.format(
        'ffmpeg -y -i "%s" -vn -acodec pcm_s16le -ar 16000 -ac 1 "%s" 2>/dev/null',
        path, audio_file
    ))

    mp.osd_message("正在语音识别...", 0)

    local model = "/usr/share/whisper.cpp-model-large-v3-turbo/ggml-large-v3-turbo.bin"
    os.execute(string.format(
        'whisper-cli -m "%s" -l zh -f "%s" -osrt -of "%s" 2>/dev/null',
        model, audio_file, base
    ))

    os.remove(audio_file)

    local f = io.open(srt_path, "r")
    if f then
        f:close()
        mp.osd_message("字幕已生成", 1)
        mp.commandv("sub_add", srt_path)
    else
        mp.osd_message("字幕生成失败", 2)
    end
end

mp.add_key_binding("Ctrl+w", "fastwhisper-gen", generate_subtitles)
