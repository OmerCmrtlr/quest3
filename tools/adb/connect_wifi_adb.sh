#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/build/stream/orchestrator"
LAST_CONNECT_FILE="$STATE_DIR/last_adb_connect.txt"

PAIR_ENDPOINT="${PAIR_ENDPOINT:-}"
PAIR_CODE="${PAIR_CODE:-}"
CONNECT_ENDPOINT="${CONNECT_ENDPOINT:-}"
SKIP_PAIR=0
PAIR_HOST=""
LEGACY_TCPIP=0
TCPIP_PORT="${TCPIP_PORT:-5555}"

usage() {
    cat <<'EOF'
Kullanım:
  ./tools/adb/connect_wifi_adb.sh [seçenekler]

Seçenekler:
  --pair-endpoint <ip:port>     Wireless debugging "pair" endpoint
  --pair-code <code>            Pairing code (opsiyonel; verilmezse etkileşimli istenir)
    --connect-endpoint <ip|ip:port>  Wireless debugging "connect" endpoint
  --skip-pair                   Pair adımını atla, sadece connect yap
    --legacy-tcpip                Pairing olmadan USB üzerinden adb tcpip ile Wi‑Fi ADB aç
    --tcpip-port <port>           Legacy tcpip portu (varsayılan: 5555)
  -h, --help                    Yardım

Örnek:
  ./tools/adb/connect_wifi_adb.sh
  ./tools/adb/connect_wifi_adb.sh --skip-pair --connect-endpoint 192.168.2.55:38947
    ./tools/adb/connect_wifi_adb.sh --legacy-tcpip --connect-endpoint 192.168.2.55
EOF
}

run_pair() {
    local endpoint="$1"
    local code="$2"
    local output=""
    local status=0

    # Öncelikli yöntem: adb pair HOST:PORT CODE
    output="$(adb pair "$endpoint" "$code" 2>&1)" || status=$?

    if [[ $status -eq 0 ]]; then
        echo "$output"
        return 0
    fi

    # Bazı adb sürümlerinde "protocol fault ... Success" görülebiliyor.
    # Bu durumda pairing çoğu kez aslında başarılı oluyor; connect adımını denemeye devam edeceğiz.
    if grep -Eiq 'protocol fault.*success' <<< "$output"; then
        echo "$output"
        echo "[adb] Uyarı: Pair çıktısı protocol fault döndürdü; yine de connect adımına geçilecek."
        return 0
    fi

    # Eski davranışa fallback: stdin üzerinden code besle.
    status=0
    output="$(printf '%s\n' "$code" | adb pair "$endpoint" 2>&1)" || status=$?
    echo "$output"
    return $status
}

is_ip_port() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]]
}

is_ipv4() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

trim() {
    local s="$1"
    # shellcheck disable=SC2001
    s="$(echo "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    echo "$s"
}

normalize_endpoint() {
    local raw="$1"
    local default_port="${2:-}"
    local value

    value="$(trim "$raw")"
    value="${value#<}"
    value="${value%>}"

    if is_ip_port "$value"; then
        echo "$value"
        return 0
    fi

    if [[ -n "$default_port" ]] && is_ipv4 "$value"; then
        echo "$value:$default_port"
        return 0
    fi

    echo "$value"
    return 1
}

discover_connect_endpoint() {
    local host_hint="$1"
    local mdns_out candidates

    mdns_out="$(adb mdns services 2>/dev/null || true)"
    candidates="$(awk '
        /_adb-tls-connect\._tcp/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$/) {
                    gsub(/\r/, "", $i)
                    print $i
                }
            }
        }
    ' <<< "$mdns_out" | sort -u)"

    if [[ -z "$candidates" ]]; then
        return 1
    fi

    if [[ -n "$host_hint" ]]; then
        candidates="$(grep -E "^${host_hint//./\\.}:[0-9]+$" <<< "$candidates" || true)"
        [[ -n "$candidates" ]] || return 1
    fi

    # İlk adayı kullan.
    echo "$candidates" | head -n 1
}

count_adb_state() {
    local state="$1"
    local listing="$2"
    awk -v wanted="$state" 'NR>1 && $2==wanted {c++} END {print c+0}' <<< "$listing"
}

print_usb_detection_hint() {
    if ! command -v lsusb >/dev/null 2>&1; then
        return
    fi

    local usb_matches
    usb_matches="$(lsusb 2>/dev/null | grep -Ei 'Huawei|Android|Google|Samsung|Xiaomi|OnePlus|OPPO|Vivo|Realme|Motorola|12d1:' || true)"
    if [[ -z "$usb_matches" ]]; then
        return
    fi

    echo "[adb] USB'de görünen olası Android cihaz(lar):"
    echo "$usb_matches"

    if grep -Eiq 'Huawei|12d1:' <<< "$usb_matches"; then
        echo "[adb] Huawei notu: USB debugging açık olsa bile bazı modlarda ADB arayüzü açılmaz."
        echo "[adb] Tablette Developer options > USB debugging'i kapat/aç + Revoke USB debugging authorizations yap."
        echo "[adb] Sonra kabloyu çıkar-tak ve USB modunu tekrar Dosya Aktarımı (MTP) seç."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pair-endpoint)
            [[ $# -ge 2 ]] || { echo "[adb] --pair-endpoint için ip:port gerekli."; exit 1; }
            PAIR_ENDPOINT="$2"
            shift 2
            ;;
        --pair-code)
            [[ $# -ge 2 ]] || { echo "[adb] --pair-code için değer gerekli."; exit 1; }
            PAIR_CODE="$2"
            shift 2
            ;;
        --connect-endpoint)
            [[ $# -ge 2 ]] || { echo "[adb] --connect-endpoint için ip:port gerekli."; exit 1; }
            CONNECT_ENDPOINT="$2"
            shift 2
            ;;
        --skip-pair)
            SKIP_PAIR=1
            shift
            ;;
        --legacy-tcpip)
            LEGACY_TCPIP=1
            SKIP_PAIR=1
            shift
            ;;
        --tcpip-port)
            [[ $# -ge 2 ]] || { echo "[adb] --tcpip-port için değer gerekli."; exit 1; }
            TCPIP_PORT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[adb] Bilinmeyen seçenek: $1"
            usage
            exit 1
            ;;
    esac
done

if ! command -v adb >/dev/null 2>&1; then
    echo "[adb] adb komutu bulunamadı. Android platform-tools kurulu olmalı."
    exit 1
fi

mkdir -p "$STATE_DIR"

adb kill-server >/dev/null 2>&1 || true
adb start-server >/dev/null 2>&1 || true

if [[ "$LEGACY_TCPIP" -eq 1 ]]; then
    if ! [[ "$TCPIP_PORT" =~ ^[0-9]{2,5}$ ]]; then
        echo "[adb] Geçersiz --tcpip-port: '$TCPIP_PORT'"
        exit 1
    fi

    ADB_LIST_USB="$(adb devices 2>/dev/null || true)"
    DEVICE_COUNT_USB="$(count_adb_state "device" "$ADB_LIST_USB")"
    UNAUTHORIZED_COUNT_USB="$(count_adb_state "unauthorized" "$ADB_LIST_USB")"
    OFFLINE_COUNT_USB="$(count_adb_state "offline" "$ADB_LIST_USB")"

    if [[ "$DEVICE_COUNT_USB" -eq 0 && "$UNAUTHORIZED_COUNT_USB" -gt 0 ]]; then
        echo "[adb] USB cihazı görüldü ama yetkisiz (unauthorized). RSA onayı bekleniyor olabilir."
        adb reconnect offline >/dev/null 2>&1 || true
        adb start-server >/dev/null 2>&1 || true
        ADB_LIST_USB="$(adb devices 2>/dev/null || true)"
        DEVICE_COUNT_USB="$(count_adb_state "device" "$ADB_LIST_USB")"
        UNAUTHORIZED_COUNT_USB="$(count_adb_state "unauthorized" "$ADB_LIST_USB")"
        OFFLINE_COUNT_USB="$(count_adb_state "offline" "$ADB_LIST_USB")"
    fi

    if [[ "$DEVICE_COUNT_USB" -eq 0 ]]; then
        if [[ "$UNAUTHORIZED_COUNT_USB" -gt 0 ]]; then
            echo "[adb] Cihaz hala unauthorized."
            echo "[adb] Çözüm adımları:"
            echo "[adb]  1) Tablet: Developer options > Revoke USB debugging authorizations"
            echo "[adb]  2) USB debugging kapat/aç"
            echo "[adb]  3) Kabloyu çıkar-tak, USB modunu Dosya Aktarımı (MTP) yap"
            echo "[adb]  4) RSA penceresi gelince 'Always allow' + Allow"
        elif [[ "$OFFLINE_COUNT_USB" -gt 0 ]]; then
            echo "[adb] Cihaz offline görünüyor. Kabloyu çıkar-tak ve USB debugging onayını tekrar ver."
        else
            echo "[adb] Legacy mod için önce tablet USB kabloyla bağlanmalı ve USB debugging onayı verilmeli."
        fi

        echo "[adb] adb devices çıktısı:"
        echo "$ADB_LIST_USB"
        print_usb_detection_hint
        exit 1
    fi

    echo "[adb] USB cihaz bulundu. tcpip modu açılıyor (port=$TCPIP_PORT)..."
    if ! adb tcpip "$TCPIP_PORT"; then
        echo "[adb] adb tcpip başarısız."
        exit 1
    fi

    if [[ -z "$CONNECT_ENDPOINT" ]]; then
        read -r -p "[adb] Tablet Wi‑Fi IP (örn 192.168.2.55): " TABLET_IP
        TABLET_IP="$(trim "$TABLET_IP")"
        if ! [[ "$TABLET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "[adb] Geçersiz tablet IP: '$TABLET_IP'"
            exit 1
        fi
        CONNECT_ENDPOINT="$TABLET_IP:$TCPIP_PORT"
    fi
fi

if [[ "$SKIP_PAIR" -eq 0 ]]; then
    if [[ -z "$PAIR_ENDPOINT" ]]; then
        read -r -p "[adb] Pair endpoint (IP:PORT): " PAIR_ENDPOINT
    fi
    PAIR_ENDPOINT="$(normalize_endpoint "$PAIR_ENDPOINT" || true)"

    if ! is_ip_port "$PAIR_ENDPOINT"; then
        echo "[adb] Geçersiz pair endpoint: '$PAIR_ENDPOINT' (örn: 192.168.2.55:37123)"
        echo "[adb] Not: Komutta < ve > karakterlerini kullanma."
        exit 1
    fi

    PAIR_HOST="${PAIR_ENDPOINT%%:*}"

    if [[ -z "$PAIR_CODE" ]]; then
        read -r -p "[adb] Pairing code: " PAIR_CODE
    fi
    PAIR_CODE="$(trim "$PAIR_CODE")"

    if [[ -z "$PAIR_CODE" ]]; then
        echo "[adb] Pairing code boş olamaz."
        exit 1
    fi

    echo "[adb] Pairing başlatılıyor: $PAIR_ENDPOINT"
    if ! run_pair "$PAIR_ENDPOINT" "$PAIR_CODE"; then
        echo "[adb] Pairing başarısız. Tablette endpoint/code'u tekrar kontrol et."
        echo "[adb] Not: Pair endpoint ve pairing code tek kullanımlık/kısa ömürlü olabilir; tablette yeniden üret."
        exit 1
    fi
fi

if [[ -z "$CONNECT_ENDPOINT" && -f "$LAST_CONNECT_FILE" ]]; then
    saved_endpoint="$(cat "$LAST_CONNECT_FILE" 2>/dev/null || true)"
    if is_ip_port "$saved_endpoint"; then
        CONNECT_ENDPOINT="$saved_endpoint"
        echo "[adb] Son kayıtlı endpoint bulundu: $CONNECT_ENDPOINT"
    fi
fi

if [[ -z "$CONNECT_ENDPOINT" ]]; then
    CONNECT_ENDPOINT="$(discover_connect_endpoint "$PAIR_HOST" || true)"
    if [[ -n "$CONNECT_ENDPOINT" ]]; then
        echo "[adb] mDNS ile connect endpoint bulundu: $CONNECT_ENDPOINT"
    fi
fi

if [[ -z "$CONNECT_ENDPOINT" ]]; then
    echo "[adb] Tablette Developer options > Wireless debugging > 'IP address & Port' değerini gir."
    read -r -p "[adb] Connect endpoint (IP veya IP:PORT): " CONNECT_ENDPOINT
fi
CONNECT_ENDPOINT="$(normalize_endpoint "$CONNECT_ENDPOINT" "$TCPIP_PORT" || true)"

if ! is_ip_port "$CONNECT_ENDPOINT"; then
    echo "[adb] Geçersiz connect endpoint: '$CONNECT_ENDPOINT' (örn: 192.168.2.55:38947 veya 192.168.2.55)"
    echo "[adb] Not: Komutta < ve > karakterlerini kullanma."
    exit 1
fi

echo "[adb] Connect deneniyor: $CONNECT_ENDPOINT"
CONNECT_OUTPUT="$(adb connect "$CONNECT_ENDPOINT" 2>&1 || true)"
echo "$CONNECT_OUTPUT"

ADB_LIST="$(adb devices 2>/dev/null || true)"
echo "$ADB_LIST"

if awk 'NR>1 && $2=="device" {found=1} END {exit found?0:1}' <<< "$ADB_LIST"; then
    echo "$CONNECT_ENDPOINT" > "$LAST_CONNECT_FILE"
    echo "[adb] Başarılı ✅"
    echo "[adb] Artık şunu çalıştırabilirsin:"
    echo "      ./start.sh --camera usb --adb-connect $CONNECT_ENDPOINT"
    exit 0
fi

if awk 'NR>1 && $2=="unauthorized" {found=1} END {exit found?0:1}' <<< "$ADB_LIST"; then
    echo "$CONNECT_ENDPOINT" > "$LAST_CONNECT_FILE"
    echo "[adb] Cihaz unauthorized görünüyor. Tablette USB/Wireless debugging onay penceresini kabul et."
    exit 1
fi

if grep -Eiq 'No route to host|Network is unreachable' <<< "$CONNECT_OUTPUT"; then
    echo "[adb] Ağ erişim hatası: laptop ve tablet aynı Wi‑Fi/alt ağda olmayabilir."
    echo "[adb] Tablet IP'sini (Wireless debugging ekranı) ve laptop IP'sini tekrar kontrol et."
fi

if grep -Eiq 'Connection refused' <<< "$CONNECT_OUTPUT"; then
    echo "[adb] Cihaza ulaşıldı ama ADB portu kapalı görünüyor."
    echo "[adb] Huawei için USB takılıyken tekrar dene: ./tools/adb/connect_wifi_adb.sh --legacy-tcpip --connect-endpoint $CONNECT_ENDPOINT"
fi

echo "[adb] Cihaz bağlantısı doğrulanamadı."
exit 1
