#!/bin/sh
# Build MacPowerManager.app từ Swift Package và ký ad-hoc.
set -eu

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/MacPowerManager.app"
SIGN_ID="${SIGN_ID:--}"   # Đặt SIGN_ID="Developer ID Application: ..." để ký bằng chứng chỉ thật.

swift build -c "$CONFIG" --product MacPowerManager
swift build -c "$CONFIG" --product PowerHelper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/MacPowerManager" "$APP/Contents/MacOS/MacPowerManager"
cp "$BIN/PowerHelper" "$APP/Contents/MacOS/PowerHelper"
cp Resources/com.hasoftware.MacPowerManager.helper.plist "$APP/Contents/Resources/"
cp scripts/helper-install.sh "$APP/Contents/Resources/helper-install.sh"

codesign --force --options runtime --sign "$SIGN_ID" \
    --identifier com.hasoftware.MacPowerManager.helper "$APP/Contents/MacOS/PowerHelper"
codesign --force --options runtime --sign "$SIGN_ID" \
    --identifier com.hasoftware.MacPowerManager "$APP"

echo "Đã tạo $APP"
