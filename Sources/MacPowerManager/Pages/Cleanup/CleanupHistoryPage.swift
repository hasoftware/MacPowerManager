import AppKit
import CleanCore
import SwiftUI

/// Lịch sử dọn: mỗi lần dọn là một bản sao lưu (manifest), khôi phục được ngay trong app.
struct CleanupHistoryPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        CleanupHistoryView(model: app.cleanup)
    }
}

struct CleanupHistoryView: View {
    let model: CleanupModel
    @State private var selected: String?
    @State private var confirmRestore: CleanupSession?
    @State private var confirmOverwrite: CleanupSession?

    init(model: CleanupModel, selected: String? = nil) {
        self.model = model
        _selected = State(initialValue: selected)
    }

    var body: some View {
        Group {
            if !model.historyLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("Chưa có lần dọn nào", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Mỗi lần dọn ở trang Quét tàn dư được sao lưu tại đây và khôi phục được.")
                }
            } else {
                HStack(spacing: 0) {
                    List(model.sessions, selection: $selected) { session in
                        SessionRow(session: session).tag(session.name)
                    }
                    .listStyle(.sidebar)
                    .frame(width: 250)
                    Divider()
                    if let session = model.sessions.first(where: { $0.name == selected }) {
                        SessionDetail(model: model, session: session,
                                      restore: { confirmRestore = session },
                                      overwrite: { confirmOverwrite = session })
                            .id(session.name)
                    } else {
                        ContentUnavailableView("Chọn một lần dọn", systemImage: "sidebar.left")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { model.loadHistory() }
        .onChange(of: model.sessions) { _, sessions in
            if selected == nil || !sessions.contains(where: { $0.name == selected }) { selected = sessions.first?.name }
        }
        .onChange(of: selected, initial: true) { _, name in
            if let session = model.sessions.first(where: { $0.name == name }) { model.loadEntries(for: session) }
            else if selected == nil { selected = model.sessions.first?.name }
        }
        .alert(Text("Khôi phục lần dọn này?"),
               isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Khôi phục") {
                if let session = confirmRestore { model.restore(session) }
                confirmRestore = nil
            }
            Button("Hủy", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Mục trong Thùng rác được đưa về chỗ cũ, file cấu hình được chép lại từ bản sao lưu. Chỗ cũ đã có mục khác thì không bị ghi đè.")
        }
        .alert(Text("Ghi đè file đã sửa?"),
               isPresented: Binding(get: { confirmOverwrite != nil }, set: { if !$0 { confirmOverwrite = nil } })) {
            Button("Ghi đè", role: .destructive) {
                if let session = confirmOverwrite { model.overwriteModifiedFiles(session) }
                confirmOverwrite = nil
            }
            Button("Hủy", role: .cancel) { confirmOverwrite = nil }
        } message: {
            Text("Các file cấu hình này đã bị sửa sau lần dọn. Ghi đè bằng bản sao lưu sẽ mất những thay đổi đó. Mục đã khôi phục khác không bị đụng tới.")
        }
    }
}

enum CleanupDate {
    static func text(_ session: CleanupSession) -> String {
        guard let date = session.date else { return session.name }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Format.locale))
    }
}

private struct SessionRow: View {
    let session: CleanupSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: CleanupDate.text(session)).fontWeight(.medium)
            HStack(spacing: 4) {
                Text("\(session.entryCount) mục")
                if let bytes = session.bytes, bytes > 0 {
                    Text(verbatim: "· \(Format.bytes(UInt64(bytes)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionDetail: View {
    let model: CleanupModel
    let session: CleanupSession
    let restore: () -> Void
    let overwrite: () -> Void

    var body: some View {
        let run = model.restoreRuns[session.directory]
        let restoring = model.restoringSession == session.directory
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: CleanupDate.text(session)).font(.title3.weight(.semibold))
                        HStack(spacing: 4) {
                            Text("\(session.entryCount) mục")
                            if let bytes = session.bytes, bytes > 0 {
                                Text(verbatim: "· \(Format.bytes(UInt64(bytes)))")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                    } label: {
                        Label("Hiện trong Finder", systemImage: "folder")
                    }
                    if model.isRestored(session) {
                        // Đã khôi phục: chạy lại sẽ báo nhầm "file đã bị sửa" và mời ghi đè.
                        Button {} label: {
                            Label("Đã khôi phục", systemImage: "checkmark")
                        }
                        .disabled(true)
                    } else {
                        Button(action: restore) {
                            Label("Khôi phục", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRestore(session))
                    }
                }
                if restoring {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Đang khôi phục…").foregroundStyle(.secondary)
                    }
                } else if model.isBusy {
                    // Phiên mới nhất có thể đang được ghi; khôi phục song song sẽ tranh file với việc dọn.
                    Label("Đang quét hoặc dọn. Khôi phục được sau khi xong.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else if model.isRestoring {
                    Label("Đang khôi phục một lần dọn khác…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                if !restoring, let run {
                    RestoreSummary(run: run, canOverwrite: model.canStartRestore, overwrite: overwrite)
                }
            }
            .padding(Theme.Space.l)
            Divider()
            if let entries = model.sessionEntries[session.directory] {
                if entries.isEmpty {
                    ContentUnavailableView("Bản sao lưu không có mục nào", systemImage: "tray")
                        .frame(maxHeight: .infinity)
                } else {
                    // kết quả khớp theo vị trí trong manifest (không theo thứ tự mảng kết quả)
                    let results = Dictionary((run?.items ?? []).map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
                    List(Array(entries.enumerated()), id: \.offset) { index, entry in
                        EntryRow(entry: entry, result: results[index])
                    }
                    .listStyle(.inset)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct RestoreSummary: View {
    let run: CleanupRestoreRun
    let canOverwrite: Bool
    let overwrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !run.manifestFound {
                Label("Không đọc được manifest của bản sao lưu này.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else {
                Label {
                    let when = run.date.map {
                        $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Format.locale))
                    } ?? ""
                    Text("Khôi phục lúc \(when): đã khôi phục \(run.restoredCount), lỗi \(run.failedCount), cần làm tay \(run.manualCount).")
                } icon: {
                    // còn mục lỗi hoặc cần làm tay: biểu tượng cảnh báo
                    let clean = run.failedCount == 0 && run.manualCount == 0
                    Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(clean ? .green : .orange)
                        .accessibilityHidden(true)
                }
                if run.hasModifiedFiles {
                    HStack(spacing: Theme.Space.s) {
                        Text("Có file cấu hình đã bị sửa sau lần dọn nên chưa ghi đè.")
                            .foregroundStyle(.secondary)
                        Button("Ghi đè các file này…", action: overwrite)
                            .buttonStyle(.link)
                            .disabled(!canOverwrite)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

private struct EntryRow: View {
    let entry: ManifestEntry
    let result: CleanupRestoreItem?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: CleanupText.entrySymbol(entry))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.original)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: CleanupText.entryAction(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let result {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: CleanupText.restoreSymbol(result.status))
                            .foregroundStyle(CleanupText.restoreTint(result.status))
                            .accessibilityHidden(true)
                        Text(verbatim: CleanupText.restoreTitle(result.status))
                            .fontWeight(.semibold)
                            .foregroundStyle(CleanupText.restoreTint(result.status))
                        if let message = CleanupText.restoreMessage(result.status) {
                            Text(verbatim: message)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
