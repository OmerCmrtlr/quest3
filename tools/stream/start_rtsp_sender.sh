#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/build/stream"
PID_FILE="$STATE_DIR/rtsp_sender.pid"
LOG_FILE="$STATE_DIR/rtsp_sender.log"
LAST_URL_FILE="$STATE_DIR/last_url.txt"

CAMERA_DEVICE="${1:-${CAMERA_DEVICE:-/dev/video0}}"
STREAM_PORT="${STREAM_PORT:-8554}"
STREAM_PATH="${STREAM_PATH:-quest3}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[sender] ffmpeg bulunamadı."
    echo "[sender] Kurulum (Ubuntu): sudo apt update && sudo apt install -y ffmpeg v4l-utils"
    exit 1
fi

if [[ ! -e "$CAMERA_DEVICE" ]]; then
    echo "[sender] Kamera cihazı bulunamadı: $CAMERA_DEVICE"
    echo "[sender] Mevcut cihazları görmek için: ls /dev/video*"
    exit 1
fi

mkdir -p "$STATE_DIR"

if [[ -f "$PID_FILE" ]]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[sender] Zaten çalışıyor (PID=$OLD_PID)."
        if [[ -f "$LAST_URL_FILE" ]]; then
            echo "[sender] URL: $(cat "$LAST_URL_FILE")"
        fi
        exit 0
    fi
    rm -f "$PID_FILE"
fi

LOCAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") {print $(i+1); exit}}')"
if [[ -z "$LOCAL_IP" ]]; then
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [[ -z "$LOCAL_IP" ]]; then
    LOCAL_IP="127.0.0.1"
fi

if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' libx264 '; then
    ENCODER_ARGS=(
        -c:v libx264
        -preset ultrafast
        -tune zerolatency
        -pix_fmt yuv420p
        -profile:v baseline
        -level 3.1
        -g "$FPS"
        -x264-params "keyint=$FPS:min-keyint=$FPS:scenecut=0"
    )
elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' h264_v4l2m2m '; then
    ENCODER_ARGS=(
        -c:v h264_v4l2m2m
        -pix_fmt yuv420p
        -b:v 2500k
        -g "$FPS"
    )
else
    echo "[sender] Uyumlu H264 encoder bulunamadı (libx264 veya h264_v4l2m2m gerekli)."
    exit 1
fi

LISTEN_URL="rtsp://0.0.0.0:${STREAM_PORT}/${STREAM_PATH}"
CLIENT_URL="rtsp://${LOCAL_IP}:${STREAM_PORT}/${STREAM_PATH}"

echo "[sender] Başlatılıyor..."
nohup ffmpeg \
    -hide_banner \
    -loglevel info \
    -f v4l2 \
    -framerate "$FPS" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -i "$CAMERA_DEVICE" \
    -an \
    "${ENCODER_ARGS[@]}" \
    -f rtsp \
    -rtsp_transport tcp \
    -rtsp_flags listen \
    "$LISTEN_URL" \
    >"$LOG_FILE" 2>&1 &

PID="$!"
echo "$PID" > "$PID_FILE"
echo "$CLIENT_URL" > "$LAST_URL_FILE"

if ! kill -0 "$PID" 2>/dev/null; then
    echo "[sender] ffmpeg başlatılamadı. Log: $LOG_FILE"
    tail -n 50 "$LOG_FILE" || true
    exit 1
fi

echo "[sender] Çalışıyor (PID=$PID)"
echo "[sender] Stream URL: $CLIENT_URL"
echo "[sender] Log: $LOG_FILE"