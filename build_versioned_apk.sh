#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="$ROOT_DIR/build/android/releases"
SERIES="${SERIES:-1.0}"
EXPORT_PRESET="${EXPORT_PRESET:-Quest3}"
APK_NAME="${APK_NAME:-Quest3-tablet-debug.apk}"

mkdir -p "$OUT_ROOT"

last_patch="$(find "$OUT_ROOT" -maxdepth 1 -mindepth 1 -type d -name "v${SERIES}.*" -printf '%f\n' 2>/dev/null \
    | sed -nE "s/^v${SERIES}\.([0-9]+)$/\1/p" \
    | sort -n \
    | tail -n 1)"

if [[ -z "$last_patch" ]]; then
    last_patch=0
fi

next_patch=$((last_patch + 1))
version="v${SERIES}.${next_patch}"
version_dir="$OUT_ROOT/$version"
apk_path="$version_dir/$APK_NAME"
latest_apk_path="$ROOT_DIR/build/android/$APK_NAME"

mkdir -p "$version_dir"

echo "[release] Yeni sürüm klasörü: $version_dir"

godot --headless --path "$ROOT_DIR" --export-debug "$EXPORT_PRESET" "$apk_path"

cp -f "$apk_path" "$latest_apk_path"

sha256="$(sha256sum "$apk_path" | awk '{print $1}')"
size="$(stat -c '%s' "$apk_path")"
timestamp="$(date -Iseconds)"

cat > "$version_dir/build_info.txt" <<EOF
version=$version
preset=$EXPORT_PRESET
apk_name=$APK_NAME
apk_path=$apk_path
latest_apk_path=$latest_apk_path
sha256=$sha256
size_bytes=$size
built_at=$timestamp
EOF

echo "$sha256  $apk_path" > "$version_dir/SHA256SUMS.txt"

echo "[release] APK hazır: $apk_path"
echo "[release] SHA256: $sha256"
echo "[release] Güncel kopya: $latest_apk_path"
