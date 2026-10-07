#!/bin/sh
# Build MacPowerManager.app từ Swift Package.
#   UNIVERSAL=1   build cho cả Apple Silicon (arm64) và Intel (x86_64)
#   SIGN_ID=...   danh tính ký, mặc định "-" (ad-hoc). Ví dụ "Developer ID Application: Tên (TEAMID)"
set -eu

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/MacPowerManager.app"
SIGN_ID="${SIGN_ID:--}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

# Version trong code phải khớp file VERSION (helper dùng nó để biết khi nào cần cài lại).
CODE_VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/PowerCore/Version.swift)"
if [ "$CODE_VERSION" != "$VERSION" ]; then
    echo "Lỗi: VERSION ($VERSION) khác Sources/PowerCore/Version.swift ($CODE_VERSION). Hãy dùng scripts/bump-version.sh." >&2
    exit 1
fi

ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCH_FLAGS --product MacPowerManager
# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCH_FLAGS --product PowerHelper
# shellcheck disable=SC2086
BIN="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$BIN/MacPowerManager" "$APP/Contents/MacOS/MacPowerManager"
cp "$BIN/PowerHelper" "$APP/Contents/MacOS/PowerHelper"
cp Resources/com.hasoftware.MacPowerManager.helper.plist "$APP/Contents/Resources/"
cp scripts/helper-install.sh "$APP/Contents/Resources/helper-install.sh"

# Dùng tham số vị trí để danh tính có dấu cách ("Developer ID Application: …") không bị tách.
set -- --force --options runtime --sign "$SIGN_ID"
if [ "$SIGN_ID" != "-" ]; then
    set -- "$@" --timestamp   # bắt buộc khi notarize
fi
codesign "$@" --identifier com.hasoftware.MacPowerManager.helper "$APP/Contents/MacOS/PowerHelper"
codesign "$@" --identifier com.hasoftware.MacPowerManager "$APP"
codesign --verify --strict "$APP"

echo "Đã tạo $APP (v$VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/MacPowerManager"))"
