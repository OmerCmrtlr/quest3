#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$ROOT_DIR/build/stream"
ORCH_DIR="$STATE_DIR/orchestrator"

SENDER_START_SCRIPT="$ROOT_DIR/tools/stream/start_rtsp_sender.sh"
SENDER_STATUS_SCRIPT="$ROOT_DIR/tools/stream/status_rtsp_sender.sh"

LOGCAT_PID_FILE="$ORCH_DIR/adb_logcat.pid"
LOGCAT_FILE_POINTER="$ORCH_DIR/adb_logcat_file.txt"
LAST_ADB_CONNECT_FILE="$ORCH_DIR/last_adb_connect.txt"

APP_ID="${APP_ID:-com.bnfnc.quest3}"
CAMERA_DEVICE="${CAMERA_DEVICE:-}"
HLS_PORT="${HLS_PORT:-8888}"
ADB_CONNECT="${ADB_CONNECT:-}"
SCENE_FILE="$ROOT_DIR/scenes/StereoViewScene.tscn"

OPEN_TERMINALS=1
START_LOGCAT=1
CLEAR_LOGCAT=1
LAUNCH_APP=1

usage() {
    cat <<'EOF'
Kullanım: ./start.sh [seçenekler]

Seçenekler:
--camera <device>        Kamera cihazını zorla (örn: /dev/video1)
--app-id <package>       Android paket adı (varsayılan: com.bnfnc.quest3)
--adb-connect <ip:port>  ADB cihazına Wi‑Fi ile bağlan (örn: 192.168.2.55:5555)
--no-terminals           Ek log pencereleri açma
--no-logcat              adb logcat başlatma
--no-clear-logcat        logcat buffer temizlemeden başlat
--no-launch              Tablette uygulamayı otomatik açma
-h, --help               Yardım

Örnek:
  ./start.sh
  ./start.sh --camera /dev/video2
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
    fi

    rm -f "$pid_file"
    echo "[orchestrator] Önceki $label süreci temizlendi."
}

open_terminal_window() {
    local title="$1"
    local script_path="$2"
    local pid_file="$3"

    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal --title="$title" -- bash "$script_path" >/dev/null 2>&1 &
    elif command -v konsole >/dev/null 2>&1; then
        konsole --hold -p tabtitle="$title" -e bash "$script_path" >/dev/null 2>&1 &
    elif command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal --title="$title" --hold --command="bash '$script_path'" >/dev/null 2>&1 &
    elif command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator -T "$title" -e bash "$script_path" >/dev/null 2>&1 &
    elif command -v xterm >/dev/null 2>&1; then
        xterm -T "$title" -e bash "$script_path" >/dev/null 2>&1 &
    else
        return 1
    fi

    echo "$!" > "$pid_file"
    return 0
}

wait_for_hls() {
    local url="$1"
    local attempts="${2:-8}"
    local delay_sec="${3:-2}"

    local i
    for ((i = 1; i <= attempts; i++)); do
        if curl -fsS --max-time 4 "$url" >/dev/null 2>&1; then
            return 0
        fi

        if [[ "$i" -lt "$attempts" ]]; then
            sleep "$delay_sec"
        fi
    done

    return 1
}

probe_rtsp_stream() {
    local url="$1"

    if ! command -v ffprobe >/dev/null 2>&1; then
        return 2
    fi

    if ffprobe -v error -rtsp_transport tcp -rw_timeout 5000000 -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$url" >/dev/null 2>&1; then
        return 0
    fi

    # Bazı ffprobe sürümlerinde rw_timeout yerine stimeout destekli olabilir.
    ffprobe -v error -rtsp_transport tcp -stimeout 5000000 -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$url" >/dev/null 2>&1
}

extract_host_from_url() {
    local url="$1"

    if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi

    echo ""
}

is_ip_port() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --camera)
            [[ $# -ge 2 ]] || { echo "[orchestrator] --camera için cihaz gerekli."; exit 1; }
            CAMERA_DEVICE="$2"
            shift 2
            ;;
        --app-id)
            [[ $# -ge 2 ]] || { echo "[orchestrator] --app-id için değer gerekli."; exit 1; }
            APP_ID="$2"
            shift 2
            ;;
        --adb-connect)
            [[ $# -ge 2 ]] || { echo "[orchestrator] --adb-connect için ip:port gerekli."; exit 1; }
            ADB_CONNECT="$2"
            shift 2
            ;;
        --no-terminals)
            OPEN_TERMINALS=0
            shift
            ;;
        --no-logcat)
            START_LOGCAT=0
            shift
            ;;
        --no-clear-logcat)
            CLEAR_LOGCAT=0
            shift
            ;;
        --no-launch)
            LAUNCH_APP=0
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

if [[ ! -x "$SENDER_START_SCRIPT" ]]; then
    echo "[orchestrator] Sender start scripti bulunamadı veya çalıştırılamıyor: $SENDER_START_SCRIPT"
    exit 1
fi

if [[ ! -x "$SENDER_STATUS_SCRIPT" ]]; then
    echo "[orchestrator] Sender status scripti bulunamadı veya çalıştırılamıyor: $SENDER_STATUS_SCRIPT"
    exit 1
fi

mkdir -p "$STATE_DIR" "$ORCH_DIR"

echo "[orchestrator] Quest3 canlı doğrulama başlatılıyor..."

if [[ -n "$CAMERA_DEVICE" ]]; then
    "$SENDER_START_SCRIPT" "$CAMERA_DEVICE"
else
    "$SENDER_START_SCRIPT"
fi

"$SENDER_STATUS_SCRIPT" || true

RTSP_URL="$(cat "$STATE_DIR/last_url.txt" 2>/dev/null || true)"
HLS_URL=""
SCENE_STREAM_URL=""
SCENE_STREAM_HOST=""
if [[ "$RTSP_URL" =~ ^rtsp://([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
    STREAM_HOST="${BASH_REMATCH[1]}"
    STREAM_PATH="${BASH_REMATCH[3]}"
    HLS_URL="http://${STREAM_HOST}:${HLS_PORT}/${STREAM_PATH}/index.m3u8"
fi

if [[ -f "$SCENE_FILE" ]]; then
    SCENE_STREAM_URL="$(grep -E '^NetworkStreamUrl = "' "$SCENE_FILE" 2>/dev/null | head -n 1 | sed -E 's/^NetworkStreamUrl = "(.*)"$/\1/')"
    SCENE_STREAM_HOST="$(extract_host_from_url "$SCENE_STREAM_URL")"
fi

ADB_AVAILABLE=0
DEVICE_COUNT=0
UNAUTHORIZED_COUNT=0
LOGCAT_FILE=""

if command -v adb >/dev/null 2>&1; then
    ADB_AVAILABLE=1
    adb start-server >/dev/null 2>&1 || true

    if [[ -z "$ADB_CONNECT" && -f "$LAST_ADB_CONNECT_FILE" ]]; then
        SAVED_CONNECT="$(cat "$LAST_ADB_CONNECT_FILE" 2>/dev/null || true)"
        if is_ip_port "$SAVED_CONNECT"; then
            ADB_CONNECT="$SAVED_CONNECT"
            echo "[orchestrator] Kayıtlı ADB endpoint kullanılıyor: $ADB_CONNECT"
        fi
    fi

    if [[ -n "$ADB_CONNECT" ]] && [[ "$ADB_CONNECT" == *"<"* || "$ADB_CONNECT" == *">"* ]]; then
        echo "[orchestrator] --adb-connect değeri geçersiz görünüyor: $ADB_CONNECT"
        echo "[orchestrator] Yer tutucu değil gerçek değer kullan: örn 192.168.2.55:38947"
        ADB_CONNECT=""
    fi

    if [[ -n "$ADB_CONNECT" ]]; then
        if is_ip_port "$ADB_CONNECT"; then
            if adb connect "$ADB_CONNECT" >/dev/null 2>&1; then
                echo "$ADB_CONNECT" > "$LAST_ADB_CONNECT_FILE"
            else
                echo "[orchestrator] ADB connect başarısız: $ADB_CONNECT"
                echo "[orchestrator] Yardımcı script: ./tools/adb/connect_wifi_adb.sh"
            fi
        else
            echo "[orchestrator] --adb-connect formatı hatalı: $ADB_CONNECT"
            echo "[orchestrator] Beklenen format: 192.168.x.x:PORT"
        fi
    fi

    ADB_DEVICES_OUTPUT="$(adb devices 2>/dev/null || true)"
    DEVICE_COUNT="$(awk 'NR>1 && $2=="device" {c++} END {print c+0}' <<< "$ADB_DEVICES_OUTPUT")"
    UNAUTHORIZED_COUNT="$(awk 'NR>1 && $2=="unauthorized" {c++} END {print c+0}' <<< "$ADB_DEVICES_OUTPUT")"
fi

if [[ "$START_LOGCAT" -eq 1 ]]; then
    if [[ "$ADB_AVAILABLE" -eq 1 && "$DEVICE_COUNT" -gt 0 ]]; then
        kill_pid_from_file "$LOGCAT_PID_FILE" "adb logcat"

        if [[ "$CLEAR_LOGCAT" -eq 1 ]]; then
            adb logcat -c >/dev/null 2>&1 || true
        fi

        LOGCAT_FILE="$STATE_DIR/adb_logcat_$(date +%Y%m%d_%H%M%S).log"
        nohup adb logcat -v time > "$LOGCAT_FILE" 2>&1 &
        LOGCAT_PID="$!"
        echo "$LOGCAT_PID" > "$LOGCAT_PID_FILE"
        echo "$LOGCAT_FILE" > "$LOGCAT_FILE_POINTER"
        echo "[orchestrator] adb logcat aktif (PID=$LOGCAT_PID): $LOGCAT_FILE"
    else
        if [[ "$ADB_AVAILABLE" -eq 1 && "$UNAUTHORIZED_COUNT" -gt 0 ]]; then
            echo "[orchestrator] adb cihazı unauthorized. Tablette USB debugging onayı ver; sonra tekrar çalıştır."
        else
            echo "[orchestrator] adb/device bulunamadı; logcat başlatılamadı. (USB kablosu + adb devices kontrol et)"
            if [[ -z "$ADB_CONNECT" ]]; then
                echo "[orchestrator] Wi‑Fi ADB için örnek: ./start.sh --adb-connect 192.168.x.x:5555"
            fi
        fi
    fi
fi

if [[ "$LAUNCH_APP" -eq 1 && "$ADB_AVAILABLE" -eq 1 && "$DEVICE_COUNT" -gt 0 ]]; then
    if adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
        echo "[orchestrator] Tablet uygulaması açıldı: $APP_ID"
    else
        echo "[orchestrator] monkey launch başarısız, activity ile deneniyor..."
        adb shell am start -n "$APP_ID/com.godot.game.GodotApp" >/dev/null 2>&1 || true
    fi
fi

if [[ -n "$HLS_URL" ]] && command -v curl >/dev/null 2>&1; then
    if wait_for_hls "$HLS_URL" 8 2; then
        echo "[orchestrator] HLS endpoint erişilebilir: $HLS_URL"
    else
        echo "[orchestrator] HLS endpoint 16sn içinde hazır olmadı: $HLS_URL"
    fi
fi

if [[ -n "$RTSP_URL" ]]; then
    if probe_rtsp_stream "$RTSP_URL"; then
        echo "[orchestrator] RTSP endpoint video akışı doğrulandı: $RTSP_URL"
    else
        echo "[orchestrator] RTSP endpoint probe başarısız: $RTSP_URL"
    fi
fi

OPENED_WINDOWS=0

if [[ "$OPEN_TERMINALS" -eq 1 ]]; then
    kill_pid_from_file "$ORCH_DIR/sender_tail.term.pid" "sender log terminal"
    kill_pid_from_file "$ORCH_DIR/status.term.pid" "status terminal"
    kill_pid_from_file "$ORCH_DIR/logcat.term.pid" "logcat terminal"

    SENDER_TAIL_SCRIPT="$ORCH_DIR/run_sender_tail.sh"
    cat > "$SENDER_TAIL_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
echo "[quest3] Sender log izleniyor: $STATE_DIR/rtsp_sender.log"
tail -n 120 -F "$STATE_DIR/rtsp_sender.log"
EOF
    chmod +x "$SENDER_TAIL_SCRIPT"

    STATUS_SCRIPT="$ORCH_DIR/run_sender_status.sh"
    cat > "$STATUS_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
while true; do
    clear
    echo "[quest3] Sender status (otomatik yenileme)"
    date
    echo
    "$SENDER_STATUS_SCRIPT" || true
    echo
    echo "[quest3] Yenileme: 2 saniye"
    sleep 2
done
EOF
    chmod +x "$STATUS_SCRIPT"

    if open_terminal_window "Quest3 Sender Log" "$SENDER_TAIL_SCRIPT" "$ORCH_DIR/sender_tail.term.pid"; then
        OPENED_WINDOWS=$((OPENED_WINDOWS + 1))
    fi

    if open_terminal_window "Quest3 Sender Status" "$STATUS_SCRIPT" "$ORCH_DIR/status.term.pid"; then
        OPENED_WINDOWS=$((OPENED_WINDOWS + 1))
    fi

    if [[ -z "$LOGCAT_FILE" ]] && [[ -f "$LOGCAT_FILE_POINTER" ]]; then
        LOGCAT_FILE="$(cat "$LOGCAT_FILE_POINTER" 2>/dev/null || true)"
    fi

    if [[ -n "$LOGCAT_FILE" ]]; then
        LOGCAT_TAIL_SCRIPT="$ORCH_DIR/run_logcat_tail.sh"
        cat > "$LOGCAT_TAIL_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
echo "[quest3] ADB logcat izleniyor: $LOGCAT_FILE"
tail -n 120 -F "$LOGCAT_FILE"
EOF
        chmod +x "$LOGCAT_TAIL_SCRIPT"

        if open_terminal_window "Quest3 Tablet Logcat" "$LOGCAT_TAIL_SCRIPT" "$ORCH_DIR/logcat.term.pid"; then
            OPENED_WINDOWS=$((OPENED_WINDOWS + 1))
        fi
    fi
fi

echo
echo "[orchestrator] Hazır ✅"
[[ -n "$RTSP_URL" ]] && echo "[orchestrator] RTSP URL: $RTSP_URL"
[[ -n "$HLS_URL" ]] && echo "[orchestrator] HLS URL:  $HLS_URL"
echo "[orchestrator] Sender log: $STATE_DIR/rtsp_sender.log"
if [[ -n "$SCENE_STREAM_URL" ]]; then
    echo "[orchestrator] Scene URL:  $SCENE_STREAM_URL"
fi
if [[ -n "${STREAM_HOST:-}" && -n "$SCENE_STREAM_HOST" && "$SCENE_STREAM_HOST" != "$STREAM_HOST" ]]; then
    echo "[orchestrator] UYARI: Scene URL host ($SCENE_STREAM_HOST) sender host ile farklı ($STREAM_HOST)."
    echo "[orchestrator] Bu durumda tablette siyah ekran olur; scene URL + APK yeniden export/kurulum gerekir."
fi
if [[ -f "$LOGCAT_FILE_POINTER" ]]; then
    echo "[orchestrator] Logcat log: $(cat "$LOGCAT_FILE_POINTER" 2>/dev/null || true)"
fi
if [[ "$OPEN_TERMINALS" -eq 1 && "$OPENED_WINDOWS" -eq 0 ]]; then
    echo "[orchestrator] Otomatik terminal açılamadı. Bu ortamda GUI terminal komutu yok olabilir."
fi
echo "[orchestrator] Tam kapatma için: ./stop.sh"
