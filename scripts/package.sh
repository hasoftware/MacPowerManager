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
cp Resources/AppIcon.icns dist/dmg-root/.VolumeIcon.icns

# hdiutil thỉnh thoảng lỗi "Resource busy" trên CI, thử lại vài lần.
retry() {
    for attempt in 1 2 3; do
        "$@" && return 0
        [ "$attempt" = 3 ] && return 1
        sleep 5
    done
}

# Tạo ảnh ghi được, bật cờ "custom icon" cho gốc ổ đĩa (để Finder hiện icon app), rồi nén thành bản chỉ đọc.
# Cờ này không được giữ khi tạo thẳng từ -srcfolder. Không có SetFile (đi kèm Xcode) thì bỏ qua bước icon.
retry hdiutil create -quiet -volname "MacPowerManager $VERSION" -srcfolder dist/dmg-root \
    -fs HFS+ -format UDRW -ov dist/rw.dmg
if command -v SetFile >/dev/null 2>&1; then
    MOUNT="$(mktemp -d)"
    retry hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" dist/rw.dmg
    SetFile -a C "$MOUNT" || true
    retry hdiutil detach -quiet "$MOUNT"
    rmdir "$MOUNT" 2>/dev/null || true
fi
retry hdiutil convert -quiet dist/rw.dmg -format UDZO -o "dist/$NAME.dmg" -ov
rm -f dist/rw.dmg
rm -rf dist/dmg-root

(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
