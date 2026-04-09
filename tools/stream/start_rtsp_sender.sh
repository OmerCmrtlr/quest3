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
FPS="${FPS:-15}"
MEDIAMTX_CONTAINER="${MEDIAMTX_CONTAINER:-quest3-mediamtx}"
MEDIAMTX_IMAGE="${MEDIAMTX_IMAGE:-bluenviron/mediamtx:latest}"
AUDIO_ENABLE="${AUDIO_ENABLE:-1}"
CAMERA_LABEL=""

is_capture_device() {
    local dev="$1"

    if command -v v4l2-ctl >/dev/null 2>&1; then
        v4l2-ctl -d "$dev" --list-formats-ext >/dev/null 2>&1
    else
        [[ -c "$dev" ]]
    fi
}

get_device_label() {
    local dev="$1"

    if command -v udevadm >/dev/null 2>&1; then
        local label
        label="$(udevadm info --query=property --name="$dev" 2>/dev/null | awk -F= '/^ID_V4L_PRODUCT=/{print $2; exit}')"
        if [[ -n "$label" ]]; then
            echo "$label"
            return
        fi
    fi

    echo "$(basename "$dev")"
}

auto_select_camera_device() {
    local preferred=""
    local fallback=""

    shopt -s nullglob
    for dev in /dev/video*; do
        [[ -c "$dev" ]] || continue
        is_capture_device "$dev" || continue

        local props product product_lc
        props="$(udevadm info --query=property --name="$dev" 2>/dev/null || true)"
        product="$(awk -F= '/^ID_V4L_PRODUCT=/{print $2; exit}' <<< "$props")"
        product_lc="$(tr '[:upper:]' '[:lower:]' <<< "${product}")"

        if grep -Eiq 'loopback|v4l2loopback' <<< "$product_lc"; then
            continue
        fi

        if [[ -z "$fallback" ]]; then
            fallback="$dev"
        fi

        if grep -q '^ID_BUS=usb$' <<< "$props"; then
            if ! grep -Eiq 'integrated|mipi|internal|built-?in' <<< "$product_lc"; then
                preferred="$dev"
                break
            fi
        fi
    done
    shopt -u nullglob

    if [[ -n "$preferred" ]]; then
        echo "$preferred"
        return
    fi

    if [[ -n "$fallback" ]]; then
        echo "$fallback"
        return
    fi
}

if [[ "$CAMERA_DEVICE" == "usb" || "$CAMERA_DEVICE" == "auto-usb" ]]; then
    CAMERA_DEVICE=""
fi

if [[ -z "$CAMERA_DEVICE" ]]; then
    CAMERA_DEVICE="$(auto_select_camera_device || true)"
fi

if [[ -z "$CAMERA_DEVICE" ]]; then
    CAMERA_DEVICE="/dev/video1"
fi

CAMERA_LABEL="$(get_device_label "$CAMERA_DEVICE")"

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

container_exists=0
container_running=0
if docker ps -a --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
    container_exists=1
fi
if docker ps --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
    container_running=1
fi

needs_recreate=0
if [[ "$container_exists" == "1" ]]; then
    port_bindings="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$MEDIAMTX_CONTAINER" 2>/dev/null || true)"
    if ! grep -q '"8554/tcp"' <<< "$port_bindings"; then
        needs_recreate=1
    fi
    if ! grep -q '"8000/udp"' <<< "$port_bindings"; then
        needs_recreate=1
    fi
    if ! grep -q '"8001/udp"' <<< "$port_bindings"; then
        needs_recreate=1
    fi
    if ! grep -q '"8888/tcp"' <<< "$port_bindings"; then
        needs_recreate=1
    fi
fi

if [[ "$needs_recreate" == "1" ]]; then
    echo "[sender] RTSP server container port eşleşmeleri güncelleniyor..."
    docker rm -f "$MEDIAMTX_CONTAINER" >/dev/null 2>&1 || true
    container_exists=0
    container_running=0
fi

if [[ "$container_running" == "0" ]]; then
    if [[ "$container_exists" == "1" ]]; then
        docker rm -f "$MEDIAMTX_CONTAINER" >/dev/null 2>&1 || true
    fi

    echo "[sender] RTSP server (MediaMTX) başlatılıyor..."
    if ! docker run -d \
        --name "$MEDIAMTX_CONTAINER" \
        --restart unless-stopped \
        -p "${STREAM_PORT}:8554/tcp" \
        -p "8000:8000/udp" \
        -p "8001:8001/udp" \
        -p "8888:8888/tcp" \
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
HLS_URL="http://${LOCAL_IP}:8888/${STREAM_PATH}/index.m3u8"

if [[ "$AUDIO_ENABLE" == "1" ]]; then
    AUDIO_INPUT_ARGS=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100)
    AUDIO_CODEC_ARGS=(-c:a aac -b:a 96k -ar 44100 -ac 2)
    AUDIO_MAP_ARGS=(-map 0:v:0 -map 1:a:0)
else
    AUDIO_INPUT_ARGS=()
    AUDIO_CODEC_ARGS=()
    AUDIO_MAP_ARGS=(-map 0:v:0 -an)
fi

echo "[sender] Başlatılıyor..."
echo "[sender] Kamera cihazı: $CAMERA_DEVICE ($CAMERA_LABEL)"
nohup ffmpeg \
    -hide_banner \
    -loglevel info \
    -f v4l2 \
    -framerate "$FPS" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -i "$CAMERA_DEVICE" \
    "${AUDIO_INPUT_ARGS[@]}" \
    "${AUDIO_MAP_ARGS[@]}" \
    "${ENCODER_ARGS[@]}" \
    "${AUDIO_CODEC_ARGS[@]}" \
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
echo "[sender] HLS URL (yedek test): $HLS_URL"
echo "[sender] Log: $LOG_FILE"