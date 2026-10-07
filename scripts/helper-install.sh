#!/bin/sh
# Cài hoặc gỡ PowerHelper dưới dạng LaunchDaemon. Cần chạy bằng root.
#   helper-install.sh install <đường-dẫn-helper> <đường-dẫn-plist>
#   helper-install.sh uninstall
set -eu

LABEL="com.hasoftware.MacPowerManager.helper"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

stop_daemon() {
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    # Chờ launchd dừng hẳn (helper khôi phục SMC khi nhận SIGTERM).
    i=0
    while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

case "${1:-}" in
install)
    [ -f "${2:-}" ] && [ -f "${3:-}" ] || { echo "Thiếu helper hoặc plist" >&2; exit 1; }
    stop_daemon
    mkdir -p /Library/PrivilegedHelperTools
    cp -f "$2" "$HELPER_DST"
    chown root:wheel "$HELPER_DST"
    chmod 755 "$HELPER_DST"
    cp -f "$3" "$PLIST_DST"
    chown root:wheel "$PLIST_DST"
    chmod 644 "$PLIST_DST"
    launchctl bootstrap system "$PLIST_DST"
    echo "Đã cài $LABEL"
    ;;
uninstall)
    stop_daemon
    rm -f "$HELPER_DST" "$PLIST_DST"
    rm -rf "/Library/Application Support/MacPowerManager"
    echo "Đã gỡ $LABEL"
    ;;
*)
    echo "Cách dùng: $0 install <helper> <plist> | uninstall" >&2
    exit 1
    ;;
esac
