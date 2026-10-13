#!/bin/sh
# Tạo ảnh chụp giao diện cho README (dữ liệu mẫu, tiếng Việt và tiếng Anh, sáng và tối, độ phân giải Retina).
#   ./scripts/make-screenshots.sh
# Kết quả ở docs/screenshots/{vi,en}/<tên>-{light,dark}.png
set -eu

cd "$(dirname "$0")/.."
CONFIG=debug ./scripts/build-app.sh >/dev/null
APP_BIN="build/MacPowerManager.app/Contents/MacOS/MacPowerManager"

# Cảnh cần chụp (tên trong --render-snapshots) và có cắt khoảng trống ở đáy hay không.
SCENES="window popover-holding page-limit page-history-day page-health"

for lang in vi en; do
    raw="$(mktemp -d)"
    [ "$lang" = vi ] && locale=vi_VN || locale=en_US
    MPM_SNAPSHOT_SCALE=2 "$APP_BIN" --render-snapshots "$raw" -AppleLanguages "($lang)" -AppleLocale "$locale" \
        >/dev/null 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 240 ]; do sleep 1; i=$((i + 1)); done
    kill "$pid" 2>/dev/null || true

    out="docs/screenshots/$lang"
    mkdir -p "$out"
    for scene in $SCENES; do
        for mode in light dark; do
            src="$raw/$scene-$mode.png"
            [ -f "$src" ] || { echo "Thiếu $src" >&2; exit 1; }
            case "$scene" in
                popover-*) swift scripts/frame-screenshot.swift "$src" "$out/$scene-$mode.png" 22 --trim ;;
                *) swift scripts/frame-screenshot.swift "$src" "$out/$scene-$mode.png" 22 ;;
            esac
        done
    done
    rm -rf "$raw"
done
ls -1 docs/screenshots/*/ | head -40
