#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PID_FILE="$ROOT_DIR/build/stream/rtsp_sender.pid"
MEDIAMTX_CONTAINER="${MEDIAMTX_CONTAINER:-quest3-mediamtx}"

if [[ ! -f "$PID_FILE" ]]; then
    echo "[sender] Çalışan sender bulunamadı (pid dosyası yok)."
    exit 0
fi

PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ -z "$PID" ]]; then
    rm -f "$PID_FILE"
    echo "[sender] PID dosyası bozuktu, temizlendi."
    exit 0
fi

if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    if kill -0 "$PID" 2>/dev/null; then
        kill -9 "$PID" 2>/dev/null || true
    fi
    echo "[sender] Durduruldu (PID=$PID)."
else
    echo "[sender] Süreç zaten kapalıydı (stale PID=$PID)."
fi

rm -f "$PID_FILE"

if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$MEDIAMTX_CONTAINER"; then
        docker rm -f "$MEDIAMTX_CONTAINER" >/dev/null 2>&1 || true
        echo "[sender] RTSP server container durduruldu ($MEDIAMTX_CONTAINER)."
    fi
fi