#!/bin/sh
# Đóng gói build/MacPowerManager.app thành .dmg và .zip trong dist/ để đăng lên GitHub Releases.
set -eu

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/MacPowerManager.app"
NAME="MacPowerManager-$VERSION"

[ -d "$APP" ] || { echo "Chưa có $APP, hãy chạy scripts/build-app.sh trước" >&2; exit 1; }

rm -rf dist
mkdir -p dist/dmg-root
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"

ditto "$APP" "dist/dmg-root/MacPowerManager.app"
ln -s /Applications dist/dmg-root/Applications
# hdiutil thỉnh thoảng lỗi "Resource busy" trên CI, thử lại vài lần.
for attempt in 1 2 3; do
    if hdiutil create -quiet -volname "MacPowerManager $VERSION" -srcfolder dist/dmg-root \
        -fs HFS+ -format UDZO -ov "dist/$NAME.dmg"; then
        break
    fi
    [ "$attempt" = 3 ] && exit 1
    sleep 5
done
rm -rf dist/dmg-root

(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
