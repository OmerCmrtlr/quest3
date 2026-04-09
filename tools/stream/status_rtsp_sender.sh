#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/build/stream"
PID_FILE="$STATE_DIR/rtsp_sender.pid"
LOG_FILE="$STATE_DIR/rtsp_sender.log"
LAST_URL_FILE="$STATE_DIR/last_url.txt"
MEDIAMTX_CONTAINER="${MEDIAMTX_CONTAINER:-quest3-mediamtx}"

if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
        echo "[sender] RTSP server: çalışıyor ($MEDIAMTX_CONTAINER)."
    elif docker ps -a --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
        echo "[sender] RTSP server: oluşturulmuş ama çalışmıyor ($MEDIAMTX_CONTAINER)."
    else
        echo "[sender] RTSP server: bulunamadı ($MEDIAMTX_CONTAINER)."
    fi
fi

if [[ ! -f "$PID_FILE" ]]; then
    echo "[sender] Çalışmıyor."
    exit 0
fi

PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ -z "$PID" ]]; then
    echo "[sender] PID dosyası bozuk."
    exit 1
fi

if kill -0 "$PID" 2>/dev/null; then
    echo "[sender] Çalışıyor (PID=$PID)."
    if [[ -f "$LAST_URL_FILE" ]]; then
        echo "[sender] URL: $(cat "$LAST_URL_FILE")"
    fi
    if [[ -f "$LOG_FILE" ]]; then
        echo "[sender] Son log satırları:"
        tail -n 20 "$LOG_FILE" || true
    fi
else
    echo "[sender] Çalışmıyor (stale PID=$PID)."
    exit 1
fi