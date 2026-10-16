import Foundation

/// Sinh `restore.sh` (port nguyên logic `write_restore_script` của MacTrash) để khôi phục được cả khi không mở app.
/// Thêm so với bản gốc: bảng `TRASHED` (orig → đường dẫn thực tế trong Thùng rác) nhúng ngay trong script, làm
/// ứng viên ĐẦU TIÊN cho TrashPath - `trashItem` có thể đã đổi tên ("foo 2"). KHÔNG thêm cột thứ 5 vào manifest.tsv:
/// `read -r kind orig rel extra` dồn mọi phần thừa vào `extra`, làm hỏng đích symlink / owner.
/// Thêm bảng `EXPECT` (orig → SHA-256 sau lần ghi CUỐI của app): file cấu hình bị sửa tiếp sau lần dọn thì KHÔNG
/// chép đè (như Restorer trong app); mỗi file chỉ khôi phục một lần. LaunchdJob: plist đã có lại thì bỏ qua.
enum RestoreScript {
    static func render(entries: [ManifestEntry]) -> String {
        var table = ""
        for e in entries where e.kind == CleanKind.trashPath.rawValue {
            guard let t = e.trashedPath, !t.isEmpty else { continue }
            table += "TRASHED+=( \(quote(e.original)) \(quote(t)) )\n"
        }
        var lastHash: [String: String] = [:]
        var order: [String] = []
        for e in entries where e.kind == CleanKind.pathEntry.rawValue || e.kind == CleanKind.envLine.rawValue {
            guard let h = e.contentHashAfter, !h.isEmpty else { continue }
            if lastHash[e.original] == nil { order.append(e.original) }
            lastHash[e.original] = h
        }
        for o in order {
            if let h = lastHash[o] { table += "EXPECT+=( \(quote(o)) \(quote(h)) )\n" }
        }
        return header + table + body
    }

    /// Single-quote cho zsh: `'` → `'\''`.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let header = """
    #!/bin/zsh
    # Script khôi phục do MacPowerManager tự sinh (logic của MacTrash). Chạy: zsh restore.sh
    # Đọc manifest.tsv cùng thư mục và hoàn tác những gì hoàn tác được.
    emulate -L zsh
    setopt NULL_GLOB
    cd "${0:A:h}" || exit 1
    [[ -f manifest.tsv ]] || { print -r -- "Không thấy manifest.tsv"; exit 1 }

    typeset -A TRASHED EXPECT DONE

    """

    private static let body = """

    ok=0; fail=0; manual=0
    typeset base src cand owner cur    # `local` chỉ dùng được trong hàm, đây là mức file
    typeset -a cands
    while IFS=$'\\t' read -r kind orig rel extra; do
        [[ -n $kind ]] || continue
        # "-" là chỗ giữ cho ô trống
        [[ $rel   == - ]] && rel=''
        [[ $extra == - ]] && extra=''
        case "$kind" in
            PathEntry|EnvLine)
                # nhiều mục cùng sửa một file: backup chỉ chép về MỘT lần
                [[ -n ${DONE[$orig]} ]] && continue
                DONE[$orig]=1
                # file bị sửa thêm sau lần dọn: không chép đè (mất các sửa đổi đó)
                if [[ -n ${EXPECT[$orig]} && -e $orig ]]; then
                    cur=$(shasum -a 256 < "$orig" 2>/dev/null)
                    cur=${cur%% *}
                    if [[ $cur != ${EXPECT[$orig]} ]]; then
                        print -r -- "THỦ CÔNG  file đã bị sửa sau lần dọn, không ghi đè (bản backup: $rel): $orig"
                        (( manual++ ))
                        continue
                    fi
                fi
                if [[ -n $rel && -e $rel ]] && cp -a "$rel" "$orig" 2>/dev/null; then
                    print -r -- "OK     khôi phục $orig"; (( ok++ ))
                else
                    print -r -- "LỖI    $orig"; (( fail++ ))
                fi ;;
            LaunchdJob)
                if [[ -e $orig || -L $orig ]]; then
                    # plist đã được cài lại: không ghi đè
                    print -r -- "BỎ QUA  đã có ở chỗ cũ: $orig"; (( manual++ ))
                elif [[ -n $rel && -e $rel ]] && cp -a "$rel" "$orig" 2>/dev/null; then
                    launchctl bootstrap "${extra%/*}" "$orig" 2>/dev/null   # domain gui/<uid>: cắt tại "/" cuối
                    print -r -- "OK     khôi phục job $orig"; (( ok++ ))
                else
                    print -r -- "LỖI    $orig"; (( fail++ ))
                fi ;;
            Symlink)
                if ln -s "$extra" "$orig" 2>/dev/null; then
                    print -r -- "OK     tạo lại symlink $orig"; (( ok++ ))
                else
                    print -r -- "LỖI    symlink $orig"; (( fail++ ))
                fi ;;
            TrashPath)
                # Kéo thẳng từ Thùng rác về chỗ cũ. Chỉ làm khi chỗ cũ đang TRỐNG -
                # không bao giờ ghi đè thứ đã được tạo lại sau lần dọn.
                base="${orig:t}"
                src=''
                # Có đường dẫn thực tế thì CHỈ dùng nó: tra theo tên có thể kéo nhầm mục trùng tên bỏ vào sau này
                if [[ -n ${TRASHED[$orig]} ]]; then
                    cands=( "${TRASHED[$orig]}" )
                else
                    cands=( "$HOME/.Trash/$base" ${SUDO_USER:+"/Users/$SUDO_USER/.Trash/$base"} "/var/root/.Trash/$base" )
                fi
                for cand in "${cands[@]}"; do
                    [[ -n $cand ]] || continue
                    [[ -e $cand || -L $cand ]] && { src="$cand"; break }
                done
                if [[ -e $orig || -L $orig ]]; then
                    print -r -- "BỎ QUA  đã có ở chỗ cũ: $orig"; (( manual++ ))
                elif [[ -n $src ]]; then
                    mkdir -p "${orig:h}" 2>/dev/null
                    if mv "$src" "$orig" 2>/dev/null; then
                        # Trả quyền sở hữu về đúng chủ của thư mục cha (quan trọng khi
                        # khôi phục bằng sudo: nếu không, file thành của root)
                        owner=$(stat -f '%Su' "${orig:h}" 2>/dev/null)
                        [[ -n $owner && $owner != root ]] && chown -R "$owner" "$orig" 2>/dev/null
                        print -r -- "OK     kéo từ Thùng rác về: $orig"; (( ok++ ))
                    else
                        print -r -- "LỖI    không chuyển được về (thiếu quyền? thử sudo): $orig"; (( fail++ ))
                    fi
                else
                    print -r -- "THỦ CÔNG  không thấy trong Thùng rác nào (đã đổ?): $orig"; (( manual++ ))
                fi ;;
            PkgReceipt)
                print -r -- "THỦ CÔNG  biên nhận gói '$orig' không nạp lại được - cài lại phần mềm nếu cần"; (( manual++ )) ;;
            FirewallApp)
                print -r -- "THỦ CÔNG  thêm lại luật tường lửa cho: $orig"; (( manual++ )) ;;
            TccReset)
                print -r -- "THỦ CÔNG  quyền '$extra' sẽ được hỏi lại khi app chạy: $orig"; (( manual++ )) ;;
            PurgeTrash|PurgeAny)
                print -r -- "KHÔNG THỂ  đã xóa vĩnh viễn, không hoàn tác được: $orig"; (( manual++ )) ;;
            *)
                print -r -- "BỎ QUA $kind $orig"; (( manual++ )) ;;
        esac
    done < manifest.tsv
    print -r -- ""
    print -r -- "Xong: $ok khôi phục, $fail lỗi, $manual cần làm tay."

    """
}
