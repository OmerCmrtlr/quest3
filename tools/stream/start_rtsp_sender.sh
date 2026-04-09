#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/build/stream"
PID_FILE="$STATE_DIR/rtsp_sender.pid"
LOG_FILE="$STATE_DIR/rtsp_sender.log"
LAST_URL_FILE="$STATE_DIR/last_url.txt"

CAMERA_DEVICE="${1:-${CAMERA_DEVICE:-}}"
STREAM_PORT="${STREAM_PORT:-8554}"
STREAM_PATH="${STREAM_PATH:-quest3}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
MEDIAMTX_CONTAINER="${MEDIAMTX_CONTAINER:-quest3-mediamtx}"
MEDIAMTX_IMAGE="${MEDIAMTX_IMAGE:-bluenviron/mediamtx:latest}"

if [[ -z "$CAMERA_DEVICE" ]] && command -v v4l2-ctl >/dev/null 2>&1; then
    CAMERA_DEVICE="$(v4l2-ctl --list-devices 2>/dev/null | awk '
        BEGIN { in_loopback = 0 }
        /^[^ \t].*:$/ {
            line = tolower($0)
            in_loopback = (line ~ /v4l2loopback/)
            next
        }
        /^[ \t]*\/dev\/video[0-9]+/ {
            if (!in_loopback) {
                print $1
                exit
            }
        }
    ')"
fi

if [[ -z "$CAMERA_DEVICE" ]]; then
    CAMERA_DEVICE="/dev/video1"
fi

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

if ! command -v docker >/dev/null 2>&1; then
    echo "[sender] docker bulunamadı. RTSP server için docker gerekli."
    echo "[sender] Ubuntu kurulum: sudo apt update && sudo apt install -y docker.io"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "[sender] Docker daemon erişilemiyor."
    echo "[sender] Servisi başlat: sudo systemctl start docker"
    echo "[sender] Kullanıcı yetkisi: sudo usermod -aG docker $USER && oturumu kapat/aç"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
        docker rm -f "$MEDIAMTX_CONTAINER" >/dev/null 2>&1 || true
    fi

    echo "[sender] RTSP server (MediaMTX) başlatılıyor..."
    if ! docker run -d \
        --name "$MEDIAMTX_CONTAINER" \
        --restart unless-stopped \
        -p "${STREAM_PORT}:8554" \
        "$MEDIAMTX_IMAGE" >/dev/null; then
        echo "[sender] MediaMTX container başlatılamadı."
        exit 1
    fi

    sleep 1
fi

ENCODERS_LIST="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"

if grep -Eiq '(^|[[:space:]])libx264([[:space:]]|$)' <<< "$ENCODERS_LIST"; then
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
elif grep -Eiq '(^|[[:space:]])h264_v4l2m2m([[:space:]]|$)' <<< "$ENCODERS_LIST"; then
    ENCODER_ARGS=(
        -c:v h264_v4l2m2m
        -pix_fmt yuv420p
        -b:v 2500k
        -g "$FPS"
    )
elif grep -Eiq '(^|[[:space:]])libopenh264([[:space:]]|$)' <<< "$ENCODERS_LIST"; then
    ENCODER_ARGS=(
        -c:v libopenh264
        -b:v 2500k
        -g "$FPS"
    )
else
    echo "[sender] Uyumlu H264 encoder bulunamadı (libx264 / h264_v4l2m2m / libopenh264)."
    exit 1
fi

PUBLISH_URL="rtsp://127.0.0.1:${STREAM_PORT}/${STREAM_PATH}"
CLIENT_URL="rtsp://${LOCAL_IP}:${STREAM_PORT}/${STREAM_PATH}"

echo "[sender] Başlatılıyor..."
echo "[sender] Kamera cihazı: $CAMERA_DEVICE"
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
    "$PUBLISH_URL" \
    >"$LOG_FILE" 2>&1 &

PID="$!"
echo "$PID" > "$PID_FILE"
echo "$CLIENT_URL" > "$LAST_URL_FILE"

if ! kill -0 "$PID" 2>/dev/null; then
    echo "[sender] ffmpeg başlatılamadı. Log: $LOG_FILE"
    tail -n 50 "$LOG_FILE" || true
    docker logs --tail 50 "$MEDIAMTX_CONTAINER" 2>/dev/null || true
    exit 1
fi

echo "[sender] Çalışıyor (PID=$PID)"
echo "[sender] Stream URL: $CLIENT_URL"
echo "[sender] Log: $LOG_FILE"