#!/usr/bin/env bash
# 录制 mpv-Emo 功能演示视频（wf-recorder，Wayland/niri）
#
# 用法：
#   chmod +x tools/record-demo.sh && tools/record-demo.sh
# 录完的 demo.mkv 建议剪辑后传 B 站/YouTube，把链接填进 README「演示视频」小节。
#
# 演示动线（约 40~60 秒，全屏状态更出效果）：
#   0~5s   主界面播放（uosc 底栏 + 顶栏胶囊一览）
#   5~12s  右键 → 逐个划过菜单分类（打开/视频/着色器/Emo/工具）
#   12~18s 弹幕：CTRL+SHIFT+D 打开弹幕综合菜单 → 选一部剧 → CTRL+D 开弹幕
#   18~25s 超分：右键 Emo > 超分与补帧 → 切换 自动/性能/画质 看画面变化
#   25~31s 均衡器：按 e 拖两下推子 → 选个预设 → 保存
#   31~38s 在线字幕：CTRL+F 搜一部电影 → 选一条下载
#   38~45s stats 页（两次 CTRL+SHIFT+I? 用你绑定的 stats 键）+ HDR 菜单划过
#   45s    收尾回到全屏播放
set -euo pipefail

OUT="${1:-demo.mkv}"
DUR="${2:-50}"

echo "▶ 3 秒后开始录制 ${DUR}s → $OUT （期间请按上面的动线操作）"
sleep 3
wf-recorder -d 60 -f "$OUT" -t &
REC_PID=$!
sleep "$DUR"
kill -INT "$REC_PID"
wait "$REC_PID" 2>/dev/null || true
echo "✅ 录制完成: $OUT"
echo "   剪辑建议：剪掉头尾、加字幕条；发布后把链接填入 README「演示视频」小节"
