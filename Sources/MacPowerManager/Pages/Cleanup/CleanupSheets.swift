import AppKit
import CleanCore
import SwiftUI

/// Xác nhận cuối: liệt kê đúng từng mục và việc sẽ làm trước khi chạy.
struct ConfirmRemovalSheet: View {
    let items: [CleanupItem]
    let bytes: Int64
    let cancel: () -> Void
    let confirm: () -> Void
    /// Trang Gỡ ứng dụng: không hiện nhãn mức độ, tên mục kèm tên app.
    private let showsSeverity: Bool
    /// Cảnh báo cần đọc trước khi xác nhận (app còn cài sau khi xóa dữ liệu, job launchd bị bỏ lại...).
    private let warnings: [String]
    /// Chỉ chuyển vào Thùng rác: mới được gọi là "Chuyển vào Thùng rác".
    private let trashOnly: Bool
    /// Số thao tác không hoàn tác được trong Lịch sử dọn (thu hồi quyền, dựng lại LaunchServices).
    private let irreversible: Int

    static let size = CGSize(width: 640, height: 560)

    init(items: [CleanupItem], bytes: Int64, showsSeverity: Bool = true, warnings: [String] = [],
         cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.items = items
        self.bytes = bytes
        self.showsSeverity = showsSeverity
        self.warnings = warnings
        self.cancel = cancel
        self.confirm = confirm
        trashOnly = CleanupText.isTrashOnly(items.map(\.finding))
        irreversible = items.filter { CleanupText.undoNote($0.finding) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: trashOnly ? "trash" : "checklist")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if trashOnly {
                            Text("Chuyển \(items.count) mục vào Thùng rác?")
                        } else {
                            Text("Dọn \(items.count) mục?")
                        }
                    }
                    .font(.title3.weight(.semibold))
                    Group {
                        if irreversible == 0 {
                            Text("Mỗi mục dưới đây được xử lý đúng như mô tả. App sao lưu trước khi thay đổi; bạn hoàn tác được trong trang Lịch sử dọn.")
                        } else {
                            Text("Mỗi mục dưới đây được xử lý đúng như mô tả. App sao lưu trước khi thay đổi; phần lớn hoàn tác được trong trang Lịch sử dọn, trừ các mục có ghi chú màu cam.")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if bytes > 0 {
                        Text("Tổng dung lượng: \(Format.bytes(UInt64(bytes)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Space.l)

            if !warnings.isEmpty {
                NoteList(notes: warnings)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.m)
            }
            Divider()
            List(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if showsSeverity {
                            SeverityBadge(severity: item.finding.severity)
                        } else if let owner = item.finding.uninstallOwner {
                            OwnerBadge(name: owner.name)
                        }
                        Text(verbatim: item.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Space.s)
                        if let size = item.sizeText {
                            Text(verbatim: size).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }
                    }
                    Text(verbatim: item.displayTarget)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Label {
                        Text(verbatim: CleanupText.plannedAction(item.finding))
                    } icon: {
                        Image(systemName: "arrow.turn.down.right").accessibilityHidden(true)
                    }
                    .font(.callout)
                    if let note = CleanupText.undoNote(item.finding) {
                        Label {
                            Text(verbatim: note)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: Theme.Space.m) {
                if irreversible == 0 {
                    Label("Hoàn tác được trong Lịch sử dọn", systemImage: "arrow.uturn.backward.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("\(irreversible) thao tác không hoàn tác được", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Hủy", action: cancel)
                    .keyboardShortcut(.cancelAction)
                if trashOnly {
                    Button("Chuyển \(items.count) mục vào Thùng rác", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(items.isEmpty)
                } else {
                    Button("Dọn \(items.count) mục", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(items.isEmpty)
                }
            }
            .padding(Theme.Space.l)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Kết quả từng mục sau khi dọn: mục cần chú ý lên trước.
struct RemovalResultsSheet: View {
    let run: CleanupRemovalRun
    let close: () -> Void
    let rescan: () -> Void
    /// Nút chính (trang Gỡ ứng dụng: về danh sách ứng dụng).
    var rescanTitle: LocalizedStringKey = "Quét lại"
    /// Ghi chú sau khi gỡ (app vẫn còn cài, lệnh cần tự chạy).
    var notes: [String] = []

    static let size = CGSize(width: 640, height: 560)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Kết quả dọn dẹp").font(.title3.weight(.semibold))
                if run.sessionFailed {
                    Label("Không tạo được bản sao lưu nên không gỡ mục nào.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: Theme.Space.s) {
                        ForEach([RemovalOutcome.Status.done, .partial, .failed, .needsAdmin, .skipped], id: \.self) { status in
                            let n = run.count(status)
                            if n > 0 { StatusChip(status: status, count: n) }
                        }
                    }
                    if run.cancelled {
                        Text("Đã dừng giữa chừng. Các mục đã xử lý vẫn khôi phục được.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !notes.isEmpty { NoteList(notes: notes) }
                }
            }
            .padding(Theme.Space.l)

            Divider()
            List(run.sortedForDisplay) { item in
                OutcomeRow(item: item)
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: Theme.Space.m) {
                if let dir = run.backupDirectory {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    } label: {
                        Label("Hiện bản sao lưu trong Finder", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Đóng", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(rescanTitle, action: rescan)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Danh sách cảnh báo màu cam (chọn chữ được, để chép lệnh).
private struct NoteList: View {
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes, id: \.self) { note in
                Label {
                    Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tên app chủ của mục (bảng xác nhận gỡ ứng dụng).
private struct OwnerBadge: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

private struct StatusChip: View {
    let status: RemovalOutcome.Status
    let count: Int

    var body: some View {
        let tint = CleanupText.statusTint(status)
        HStack(spacing: 4) {
            Image(systemName: CleanupText.statusSymbol(status)).foregroundStyle(tint).accessibilityHidden(true)
            Text(verbatim: "\(CleanupText.statusTitle(status)) \(count)")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct OutcomeRow: View {
    let item: CleanupItemOutcome

    var body: some View {
        let status = item.outcome.status
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: CleanupText.statusSymbol(status))
                .foregroundStyle(CleanupText.statusTint(status))
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: CleanupText.statusTitle(status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CleanupText.statusTint(status))
                }
                Text(verbatim: item.target == FindingLiteral.emptyPathTarget ? String(localized: "<rỗng>") : item.target)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = CleanupText.outcomeMessage(item.outcome) {
                    Text(verbatim: message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .needsAdmin(let command) = item.outcome, !command.isEmpty {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        // Lệnh chạy bằng sudo: luôn hiện đủ, không cắt.
                        Text(verbatim: command)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button("Sao chép lệnh") { CleanupActions.copy(command) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
