#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/build/stream"
PID_FILE="$STATE_DIR/rtsp_sender.pid"
LOG_FILE="$STATE_DIR/rtsp_sender.log"
LAST_URL_FILE="$STATE_DIR/last_url.txt"

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