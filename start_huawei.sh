#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB_HELPER="$ROOT_DIR/tools/adb/connect_wifi_adb.sh"
START_SCRIPT="$ROOT_DIR/start.sh"
LAST_CONNECT_FILE="$ROOT_DIR/build/stream/orchestrator/last_adb_connect.txt"

CAMERA_DEVICE="${CAMERA_DEVICE:-usb}"
TABLET_IP="${TABLET_IP:-}"
TCPIP_PORT="${TCPIP_PORT:-5555}"
STRICT_ADB=0
START_ARGS=()

is_ip_port() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]]
}

is_ipv4() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

normalize_endpoint() {
    local value="$1"
    value="${value#<}"
    value="${value%>}"

    if is_ip_port "$value"; then
        echo "$value"
        return 0
    fi

    if is_ipv4 "$value"; then
        echo "$value:$TCPIP_PORT"
        return 0
    fi

    return 1
}

has_any_device() {
    local adb_list
    adb_list="$(adb devices 2>/dev/null || true)"
    awk 'NR>1 && $2=="device" {found=1} END {exit found?0:1}' <<< "$adb_list"
}

usage() {
    cat <<'EOF'
Kullanım:
  ./start_huawei.sh [seçenekler] [-- start.sh-seçenekleri]

Seçenekler:
  --tablet-ip <ip|ip:port>  Tablet IP'si (port verilmezse --tcpip-port kullanılır)
  --tcpip-port <port>       Legacy adb tcpip portu (varsayılan: 5555)
  --camera <device>         start.sh için kamera cihazı (varsayılan: usb)
    --strict-adb              ADB kurulamazsa devam etme (varsayılan: ADB yoksa da stream başlat)
  -h, --help                Yardım

Örnek:
  ./start_huawei.sh --tablet-ip 192.168.2.134
  ./start_huawei.sh --tablet-ip 192.168.2.134 --camera usb -- --no-terminals
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tablet-ip)
            [[ $# -ge 2 ]] || { echo "[huawei] --tablet-ip için değer gerekli."; exit 1; }
            TABLET_IP="$2"
            shift 2
            ;;
        --tcpip-port)
            [[ $# -ge 2 ]] || { echo "[huawei] --tcpip-port için değer gerekli."; exit 1; }
            TCPIP_PORT="$2"
            shift 2
            ;;
        --camera)
            [[ $# -ge 2 ]] || { echo "[huawei] --camera için değer gerekli."; exit 1; }
            CAMERA_DEVICE="$2"
            shift 2
            ;;
        --strict-adb)
            STRICT_ADB=1
            shift
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                START_ARGS+=("$1")
                shift
            done
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            START_ARGS+=("$1")
            shift
            ;;
    esac
done

if ! [[ "$TCPIP_PORT" =~ ^[0-9]{2,5}$ ]]; then
    echo "[huawei] Geçersiz --tcpip-port: '$TCPIP_PORT'"
    exit 1
fi

if [[ ! -x "$ADB_HELPER" ]]; then
    echo "[huawei] ADB helper bulunamadı: $ADB_HELPER"
    exit 1
fi

if [[ ! -x "$START_SCRIPT" ]]; then
    echo "[huawei] start.sh bulunamadı: $START_SCRIPT"
    exit 1
fi

connect_args=(--legacy-tcpip --tcpip-port "$TCPIP_PORT")
TARGET_ENDPOINT=""
ADB_CONNECT=""

if [[ -n "$TABLET_IP" ]]; then
    TARGET_ENDPOINT="$(normalize_endpoint "$TABLET_IP" || true)"
    if [[ -z "$TARGET_ENDPOINT" ]]; then
        echo "[huawei] Geçersiz --tablet-ip: '$TABLET_IP'"
        echo "[huawei] Örnek: 192.168.2.134 veya 192.168.2.134:5555"
        exit 1
    fi
fi

if [[ -z "$TARGET_ENDPOINT" && -f "$LAST_CONNECT_FILE" ]]; then
    saved_endpoint="$(cat "$LAST_CONNECT_FILE" 2>/dev/null || true)"
    if is_ip_port "$saved_endpoint"; then
        TARGET_ENDPOINT="$saved_endpoint"
    fi
fi

if [[ -n "$TARGET_ENDPOINT" ]]; then
    adb start-server >/dev/null 2>&1 || true
    echo "[huawei] Önce mevcut Wi‑Fi ADB endpoint deneniyor: $TARGET_ENDPOINT"
    if adb connect "$TARGET_ENDPOINT" >/dev/null 2>&1 && has_any_device; then
        ADB_CONNECT="$TARGET_ENDPOINT"
        echo "[huawei] Wi‑Fi ADB doğrudan bağlandı, USB adımı atlandı."
    else
        echo "[huawei] Doğrudan bağlanamadı, legacy USB tcpip adımına geçiliyor..."
    fi
fi

if [[ -z "$ADB_CONNECT" ]]; then
    if [[ -n "$TARGET_ENDPOINT" ]]; then
        connect_args+=(--connect-endpoint "$TARGET_ENDPOINT")
    fi

    echo "[huawei] Legacy Wi‑Fi ADB bağlantısı başlatılıyor..."
    set +e
    "$ADB_HELPER" "${connect_args[@]}"
    helper_status=$?
    set -e

    if [[ "$helper_status" -ne 0 ]]; then
        if [[ "$STRICT_ADB" -eq 1 ]]; then
            echo "[huawei] ADB kurulamadı ve --strict-adb aktif olduğu için işlem durduruldu."
            exit "$helper_status"
        fi

        echo "[huawei] ADB kurulamadı; stream ADB'siz modda devam edecek (uygulama tablette zaten açık olmalı)."
        exec "$START_SCRIPT" --camera "$CAMERA_DEVICE" --no-logcat --no-launch "${START_ARGS[@]}"
    fi

    if [[ ! -f "$LAST_CONNECT_FILE" ]]; then
        echo "[huawei] ADB endpoint dosyası bulunamadı: $LAST_CONNECT_FILE"
        exit 1
    fi

    ADB_CONNECT="$(cat "$LAST_CONNECT_FILE" 2>/dev/null || true)"
    if [[ -z "$ADB_CONNECT" ]]; then
        echo "[huawei] ADB endpoint okunamadı."
        exit 1
    fi
fi

echo "[huawei] Canlı akış başlatılıyor (ADB: $ADB_CONNECT)..."
exec "$START_SCRIPT" --camera "$CAMERA_DEVICE" --adb-connect "$ADB_CONNECT" "${START_ARGS[@]}"
