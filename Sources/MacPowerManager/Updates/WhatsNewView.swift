import AppKit
import PowerCore
import SwiftUI

/// Cửa sổ "Có gì mới" (khoảng 520×560): phiên bản mới, ngày phát hành, ghi chú thay đổi và các lựa chọn cập nhật.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var model

    static let size = CGSize(width: 520, height: 560)

    var body: some View {
        Group {
            if let release = model.updates.available {
                WhatsNewContent(release: release, currentVersion: model.updates.currentVersion)
            } else {
                NoUpdateView()
            }
        }
        .frame(minWidth: 560, idealWidth: Self.size.width, maxWidth: .infinity,
               minHeight: 460, idealHeight: Self.size.height, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

private struct WhatsNewContent: View {
    let release: ReleaseInfo
    let currentVersion: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var version: String { release.version?.description ?? release.tagName }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                notes
                helperNote
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)

            Divider()
            footer
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppLogo(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Có gì mới trong v\(version)")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let dmg = release.diskImage {
                    Text(verbatim: "\(dmg.name) · \(Int64(dmg.size).formatted(.byteCount(style: .file).locale(Format.locale)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let current = String(localized: "Bạn đang dùng v\(currentVersion)")
        guard let date = release.publishedAt else { return current }
        return String(localized: "Phát hành \(Format.date(date))") + " · " + current
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView {
                Group {
                    if release.notes.isEmpty {
                        Text("Bản phát hành này chưa có ghi chú.")
                            .foregroundStyle(.secondary)
                    } else {
                        ReleaseNotesView(markdown: release.notes)
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .cardSurface()

            // Ghi chú phát hành lấy từ CHANGELOG (tiếng Việt); báo cho người dùng giao diện tiếng Anh.
            if Format.locale.language.languageCode?.identifier != "vi" && ReleaseNotesView.isVietnamese(release.notes) {
                Label("Ghi chú phát hành được viết bằng tiếng Việt.", systemImage: "character.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var helperNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text("Helper tự cập nhật cùng app, không cần mật khẩu. Nếu helper đang dùng còn cũ (trước v0.6.0), app sẽ nhắc cài lại helper một lần sau khi mở lại.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Bỏ qua bản này") {
                model.updates.skip(release)
                dismiss()
            }
            .help("Không nhắc lại bản này. Bản mới hơn vẫn được thông báo.")
            .fixedSize()
            Spacer(minLength: Theme.Space.s)
            Button("Để sau") {
                model.updates.remindLater(release)
                dismiss()
            }
            .help("Nhắc lại sau 24 giờ.")
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            Button("Xem trên GitHub") {
                model.updates.openReleasePage(release)
            }
            .fixedSize()
            if release.supportsAutomaticUpdate {
                Button("Cập nhật ngay") {
                    model.installer.install(release)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Tải, kiểm tra chữ ký và cài bản mới, rồi mở lại app.")
                .fixedSize()
            } else {
                // Bản phát hành cũ chưa có chữ ký: chỉ tải thủ công được.
                Button("Tải bản cập nhật") {
                    model.updates.download(release)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(release.downloadURL.absoluteString)
                .fixedSize()
            }
        }
        .controlSize(.regular)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.installer.isBusy)
        .overlay(alignment: .top) { progress.offset(y: -36) }
    }

    /// Tiến độ cập nhật tự động (tải, kiểm tra, cài) hoặc lỗi kèm đường tải thủ công.
    @ViewBuilder
    private var progress: some View {
        switch model.installer.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            HStack(spacing: Theme.Space.s) {
                ProgressView(value: fraction).frame(maxWidth: .infinity)
                Text("Đang tải \(Int(fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Hủy") { model.installer.cancel() }.controlSize(.small)
            }
        case .verifying:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Đang kiểm tra chữ ký…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        case .installing:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Đang cài và mở lại app…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        case .failed(let message):
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).lineLimit(2)
                Spacer()
                Button("Tải .dmg thủ công") { model.updates.download(release) }.controlSize(.small)
            }
        }
    }
}

/// Không có bản mới (cửa sổ được mở lại sau khi đã cập nhật, hoặc chưa kiểm tra).
private struct NoUpdateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            switch model.updates.state {
            case .checking:
                Label("Đang kiểm tra cập nhật…", systemImage: "arrow.triangle.2.circlepath")
            case .failed:
                Label("Không kiểm tra được cập nhật", systemImage: "exclamationmark.triangle")
            case .idle:
                Label("Chưa kiểm tra cập nhật", systemImage: "clock")
            case .upToDate, .available:
                Label("Không có bản cập nhật mới", systemImage: "checkmark.seal")
            }
        } description: {
            if case .failed(let message) = model.updates.state {
                Text(message)
            } else {
                Text("Bạn đang dùng MacPowerManager v\(model.updates.currentVersion).")
            }
        } actions: {
            Button("Kiểm tra cập nhật") { Task { await model.updates.checkNow() } }
                .disabled(model.updates.state == .checking)
            Button("Xem các bản phát hành") { NSWorkspace.shared.open(Links.releases) }
        }
        // Mở cửa sổ khi chưa kiểm tra lần nào (ví dụ bấm thông báo ngay sau khi mở lại app): kiểm tra luôn.
        .task {
            if model.updates.state == .idle { await model.updates.checkNow() }
        }
    }
}

/// Vẽ ghi chú phát hành: tiêu đề `###` có biểu tượng theo loại thay đổi, gạch đầu dòng, chữ đậm/mã/liên kết.
struct ReleaseNotesView: View {
    let blocks: [ReleaseNoteBlock]

    init(markdown: String) {
        blocks = ReleaseNoteBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                row(block)
                    .padding(.top, index > 0 && block.isHeading ? 10 : 0)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ block: ReleaseNoteBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let style = HeadingStyle(text)
            HStack(spacing: 7) {
                Image(systemName: style.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 22, height: 22)
                    .background(style.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(Self.inline(text))
                    .font(level <= 2 ? .title3.weight(.semibold) : .headline)
            }
            .padding(.bottom, 1)
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: depth == 0 ? "•" : "◦")
                    .foregroundStyle(.secondary)
                paragraph(text)
            }
            .padding(.leading, 6 + CGFloat(depth) * 16)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                paragraph(text)
            }
            .padding(.leading, 6)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                paragraph(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            paragraph(text)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(Self.inline(text))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Markdown nội dòng (đậm, nghiêng, `mã`, liên kết); lỗi cú pháp thì hiện nguyên văn.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Có chữ tiếng Việt (dấu thanh hoặc ă, â, đ, ê, ô, ơ, ư).
    static func isVietnamese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x1EA0...0x1EF9).contains($0.value) || "ăâđêôơưĂÂĐÊÔƠƯ".unicodeScalars.contains($0) }  // l10n-ignore
    }

    /// Biểu tượng theo nhóm thay đổi của Keep a Changelog (tiếng Việt và tiếng Anh).
    private struct HeadingStyle {
        let symbol: String
        let tint: Color

        init(_ text: String) {
            let t = text.lowercased()
            func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
            if has("tính năng", "feature", "added") {  // l10n-ignore
                (symbol, tint) = ("sparkles", .purple)
            } else if has("sửa lỗi", "fix") {  // l10n-ignore
                (symbol, tint) = ("wrench.and.screwdriver", .orange)
            } else if has("an toàn", "bảo mật", "safety", "security") {  // l10n-ignore
                (symbol, tint) = ("checkmark.shield", .green)
            } else if has("cải tiến", "thay đổi", "improve", "changed") {  // l10n-ignore
                (symbol, tint) = ("arrow.up.forward.circle", .blue)
            } else if has("gỡ bỏ", "removed", "deprecated") {  // l10n-ignore
                (symbol, tint) = ("minus.circle", .red)
            } else {
                (symbol, tint) = ("doc.text", .secondary)
            }
        }
    }
}

private extension ReleaseNoteBlock {
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}
