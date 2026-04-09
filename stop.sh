#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$ROOT_DIR/build/stream"
ORCH_DIR="$STATE_DIR/orchestrator"

SENDER_STOP_SCRIPT="$ROOT_DIR/tools/stream/stop_rtsp_sender.sh"

APP_ID="${APP_ID:-com.bnfnc.quest3}"
STOP_APP=1

usage() {
    cat <<'EOF'
Kullanım: ./stop.sh [seçenekler]

Seçenekler:
  --app-id <package>   Android paket adı (varsayılan: com.bnfnc.quest3)
  --keep-app           Tablet uygulamasını force-stop yapma
  -h, --help           Yardım
EOF
}

kill_pid_from_file() {
    local pid_file="$1"
    local label="$2"

    if [[ ! -f "$pid_file" ]]; then
        return
    fi

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        echo "[orchestrator] $label kapatıldı (PID=$pid)."
    fi

    rm -f "$pid_file"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-id)
            [[ $# -ge 2 ]] || { echo "[orchestrator] --app-id için değer gerekli."; exit 1; }
            APP_ID="$2"
            shift 2
            ;;
        --keep-app)
            STOP_APP=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[orchestrator] Bilinmeyen seçenek: $1"
            usage
            exit 1
            ;;
    esac
done

echo "[orchestrator] Quest3 canlı doğrulama kapatılıyor..."

if [[ -d "$ORCH_DIR" ]]; then
    shopt -s nullglob
    for pid_file in "$ORCH_DIR"/*.term.pid; do
        kill_pid_from_file "$pid_file" "terminal"
    done
    shopt -u nullglob

    kill_pid_from_file "$ORCH_DIR/adb_logcat.pid" "adb logcat"
    rm -f "$ORCH_DIR/adb_logcat_file.txt"
    rm -f "$ORCH_DIR"/run_*.sh
fi

if [[ "$STOP_APP" -eq 1 ]] && command -v adb >/dev/null 2>&1; then
    adb start-server >/dev/null 2>&1 || true
    DEVICE_COUNT="$(adb devices | awk 'NR>1 && $2=="device" {c++} END {print c+0}')"
    if [[ "$DEVICE_COUNT" -gt 0 ]]; then
        adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
        echo "[orchestrator] Tablet uygulaması force-stop gönderildi: $APP_ID"
    fi
fi

if [[ -x "$SENDER_STOP_SCRIPT" ]]; then
    "$SENDER_STOP_SCRIPT" || true
else
    echo "[orchestrator] Sender stop scripti çalıştırılamıyor: $SENDER_STOP_SCRIPT"
fi

echo "[orchestrator] Kapatma tamamlandı ✅"
