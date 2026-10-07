#!/bin/sh
# Cài hoặc gỡ PowerHelper dưới dạng LaunchDaemon. Cần chạy bằng root.
#   helper-install.sh install <đường-dẫn-helper> <đường-dẫn-plist> [<đường-dẫn-app>]
#   helper-install.sh uninstall [<helper-đi-kèm-app>]
# Khi cài có đường dẫn app: ghi cdhash của app vào trusted-clients.json để helper chỉ nhận lệnh từ đúng bản app này.
# Mã thoát khi gỡ: 3 = Apple Silicon, đã gỡ nhưng chưa xác minh được việc khôi phục (khởi động lại sẽ reset SMC);
#                  4 = Intel, chưa trả được BCLM về 100% (BCLM được lưu trong firmware), helper được giữ lại để chạy lại.
set -eu

LABEL="com.hasoftware.MacPowerManager.helper"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/MacPowerManager"
TRUSTED_CLIENTS="$SUPPORT_DIR/trusted-clients.json"

stop_daemon() {
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    # Chờ launchd dừng hẳn (helper khôi phục SMC khi nhận SIGTERM).
    i=0
    while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

# Chạy `--restore-defaults` với giới hạn thời gian. Trả 0 nếu helper xác minh đã khôi phục.
run_restore() {
    bin="$1"
    [ -x "$bin" ] || return 1
    # Helper cũ (v0.1.0) không hiểu tham số này và sẽ chạy thành daemon, nên không chạy nó.
    grep -q -- '--restore-defaults' "$bin" || return 1
    # set -e không áp dụng trong hàm được gọi từ `if`, nên kiểm tra từng bước: một bản copy rỗng
    # (ví dụ ổ đĩa đầy) sẽ chạy như script rỗng, thoát 0 và bị coi nhầm là đã khôi phục.
    tmp="$(mktemp /tmp/mpm-restore.XXXXXX)" || return 1
    if ! cp -fX "$bin" "$tmp" || ! cmp -s "$bin" "$tmp" || ! chmod 755 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    xattr -c "$tmp" 2>/dev/null || true
    # Không để tiến trình con giữ stdout/stderr của script, nếu không osascript sẽ chờ nó dù đã bị kill.
    "$tmp" --restore-defaults </dev/null >/dev/null 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        rc=1
    else
        wait "$pid"
        rc=$?
    fi
    rm -f "$tmp"
    return $rc
}

# Ghi cdhash của từng kiến trúc trong file chạy chính của app (bản universal có 2 cdhash).
# Không tính được cdhash nào thì xóa file cũ: helper quay về chỉ kiểm tra bundle identifier,
# thay vì ghim theo một bản app khác và từ chối bản vừa cài.
write_trusted_clients() {
    app="$1"
    hashes=""
    for arch in arm64 x86_64; do
        h="$(codesign -dvvv --arch "$arch" "$app" 2>&1 | sed -n 's/^CDHash=\([0-9a-fA-F]\{40\}\)$/\1/p' | head -n 1)"
        [ -n "$h" ] || continue
        case " $hashes " in *" $h "*) ;; *) hashes="$hashes $h" ;; esac
    done
    if [ -z "$hashes" ]; then
        echo "Không đọc được cdhash của $app, helper chỉ kiểm tra bundle identifier" >&2
        rm -f "$TRUSTED_CLIENTS"
        return 0
    fi
    json=""
    for h in $hashes; do
        json="$json${json:+,}\"$h\""
    done
    mkdir -p "$SUPPORT_DIR"
    chown root:wheel "$SUPPORT_DIR"
    chmod 755 "$SUPPORT_DIR"
    tmp="$(mktemp "$SUPPORT_DIR/.trusted-clients.XXXXXX")"
    printf '{"cdhashes":[%s]}\n' "$json" >"$tmp"
    chown root:wheel "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$TRUSTED_CLIENTS"
}

case "${1:-}" in
install)
    [ -f "${2:-}" ] && [ -f "${3:-}" ] || { echo "Thiếu helper hoặc plist" >&2; exit 1; }
    # Ghi danh sách client trước khi dừng helper cũ: lỗi ở bước này không để máy thiếu helper.
    if [ -n "${4:-}" ]; then
        [ -d "$4" ] || { echo "Không tìm thấy app: $4" >&2; exit 1; }
        write_trusted_clients "$4"
    fi
    stop_daemon
    mkdir -p /Library/PrivilegedHelperTools
    # -X: không chép extended attributes (kể cả com.apple.quarantine của bản tải từ GitHub),
    # nếu không Gatekeeper có thể chặn launchd chạy helper.
    cp -fX "$2" "$HELPER_DST"
    xattr -c "$HELPER_DST" 2>/dev/null || true
    chown root:wheel "$HELPER_DST"
    chmod 755 "$HELPER_DST"
    cp -fX "$3" "$PLIST_DST"
    chown root:wheel "$PLIST_DST"
    chmod 644 "$PLIST_DST"
    launchctl bootstrap system "$PLIST_DST"
    echo "Đã cài $LABEL"
    ;;
uninstall)
    stop_daemon
    # Helper đã khôi phục khi nhận SIGTERM; chạy lại để xóa mọi key ngắt adapter và xác minh.
    # Ưu tiên helper đi kèm app vì helper đang cài có thể là bản cũ.
    restored=1
    for bin in "${2:-}" "$HELPER_DST"; do
        [ -n "$bin" ] || continue
        if run_restore "$bin"; then
            restored=0
            break
        fi
    done
    rm -f "$PLIST_DST"
    if [ $restored -ne 0 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
        # Intel: BCLM vẫn còn sau khi khởi động lại, nên giữ helper để người dùng chạy lại lệnh khôi phục.
        echo "MPM-E4: Chưa trả được giới hạn sạc của firmware (BCLM) về 100%. Chạy: sudo $HELPER_DST --restore-defaults" >&2
        exit 4
    fi
    rm -f "$HELPER_DST"
    rm -rf "$SUPPORT_DIR"
    if [ $restored -ne 0 ]; then
        echo "MPM-E3: Đã gỡ helper nhưng chưa xác minh được việc khôi phục sạc. Hãy khởi động lại máy để SMC trở về mặc định." >&2
        exit 3
    fi
    echo "Đã gỡ $LABEL"
    ;;
*)
    echo "Cách dùng: $0 install <helper> <plist> [<app>] | uninstall [<helper>]" >&2
    exit 1
    ;;
esac
