import AppKit
import CleanCore
import SwiftUI

/// Quét tàn dư: chỉ quét khi bấm nút, không chọn sẵn gì, mỗi mục ghi rõ lý do, gỡ = chuyển vào Thùng rác có sao lưu.
struct CleanupPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        CleanupScanView(model: app.cleanup)
    }
}

struct CleanupScanView: View {
    @Bindable var model: CleanupModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if model.hasFullDiskAccess == false {
                FullDiskAccessNotice { model.refreshAccess() }
                    .padding([.horizontal, .top], Theme.Space.xl)
            }
            switch model.phase {
            case .idle: CleanupIdleView { model.startScan() }
            case .scanning(let status): CleanupScanningView(status: status) { model.cancelScan() }
            case .results, .removing, .finished: results
            }
        }
        // cùng khổ nội dung tối đa với các trang theo dõi
        .frame(maxWidth: MonitorPage<EmptyView>.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Một lần mở file (TCC.db), chỉ khi chưa biết có quyền: người dùng có thể vừa cấp quyền rồi quay lại.
        .onAppear { if model.hasFullDiskAccess != true { model.refreshAccess() } }
        .sheet(isPresented: $confirming) {
            ConfirmRemovalSheet(items: model.selectedItems, bytes: model.selectedBytes,
                                cancel: { confirming = false },
                                confirm: {
                                    confirming = false
                                    model.removeSelected()
                                })
        }
        .sheet(isPresented: Binding(get: { if case .finished = model.phase { true } else { false } },
                                    set: { if !$0 { model.closeRemovalResults(rescan: false) } })) {
            if case .finished(let run) = model.phase {
                RemovalResultsSheet(run: run,
                                    close: { model.closeRemovalResults(rescan: false) },
                                    rescan: { model.closeRemovalResults(rescan: true) })
            }
        }
        .alert(Text("Có lỗi"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    // MARK: Kết quả

    private var results: some View {
        VStack(spacing: 0) {
            CleanupSummaryBar(model: model)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.l)
            if !model.items.isEmpty {
                CleanupFilterBar(model: model)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.m)
            }
            Color.clear.frame(height: Theme.Space.m)
            if !model.ignoredThisSession.isEmpty {
                IgnoredUndoBar(model: model)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.s)
            }
            Divider()
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("Không tìm thấy tàn dư nào", systemImage: "checkmark.seal")
                } description: {
                    Text("Máy sạch. Quét lại sau khi gỡ ứng dụng để tìm phần còn sót.")
                }
                .frame(maxHeight: .infinity)
            } else if model.sections.isEmpty {
                ContentUnavailableView("Không có mục nào khớp bộ lọc", systemImage: "line.3.horizontal.decrease.circle")
                    .frame(maxHeight: .infinity)
            } else {
                findingList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.items.isEmpty {
                CleanupBottomBar(model: model) { confirming = true }
            }
        }
    }

    /// Một ForEach phẳng (tiêu đề nhóm là một dòng thường; Section của List ghim tiêu đề với nền khác màu trang).
    /// `enabled` chỉ đổi khi bắt đầu/xong gỡ; tiến độ gỡ nằm ngoài `phase` nên không vẽ lại danh sách.
    private var findingList: some View {
        let enabled = model.phase == .results
        return List {
            ForEach(model.rows) { row in
                switch row {
                case .header(let section):
                    SectionHeader(section: section, model: model, enabled: enabled)
                        .padding(.top, Theme.Space.s)
                        .listRowSeparator(.hidden)
                case .item(let item):
                    FindingRowView(item: item, selected: model.isSelected(item.id), enabled: enabled) { on in
                        model.setSelected(item.id, on)
                    }
                    .contextMenu { menu(for: item) }
                }
            }
        }
        .listStyle(.inset)
        // dòng thẳng lề 24 pt với các thanh phía trên (kiểu .inset sẵn có lề 16 pt)
        .contentMargins(.horizontal, Theme.Space.xl - Theme.Space.l, for: .scrollContent)
    }

    @ViewBuilder
    private func menu(for item: CleanupItem) -> some View {
        if let path = CleanupText.filePath(item.finding) {
            Button("Hiện trong Finder") { CleanupActions.reveal(path) }
            Button("Sao chép đường dẫn") { CleanupActions.copy(path) }
        } else {
            Button("Sao chép đường dẫn") { CleanupActions.copy(item.finding.target) }
        }
        if item.finding.needsAdmin {
            Button("Sao chép lệnh") {
                let finding = item.finding
                Task { CleanupActions.copy(await model.adminCommand(for: finding)) }
            }
        }
        Divider()
        Button("Bỏ qua vĩnh viễn") { model.ignore(item.id) }
            .disabled(model.phase != .results)
    }
}

// MARK: - Chưa quét

struct CleanupIdleView: View {
    let scan: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Tìm phần còn sót của ứng dụng đã gỡ")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Quét thư mục ~/Library, mục khởi động, helper, PATH và biến môi trường, symlink gãy, plugin, quyền riêng tư và LaunchServices.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    point("eye", "Quét chỉ đọc: không thay đổi gì trên máy.")
                    point("checklist.unchecked", "Không mục nào được chọn sẵn, mỗi mục ghi rõ vì sao bị đánh dấu.")
                    point("arrow.uturn.backward", "Mục bạn chọn được sao lưu trước khi gỡ (chuyển vào Thùng rác hoặc tắt dòng trong file cấu hình) và khôi phục được trong Lịch sử dọn. Vài thao tác không hoàn tác được sẽ được ghi rõ khi xác nhận.")
                    point("hand.raised", "Không có gì bị xóa khi bạn chưa xác nhận. Mục nguy hiểm hoặc cần quyền quản trị chỉ được báo.")
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: 520, alignment: .leading)
                .cardSurface()

                Button(action: scan) {
                    Label("Quét", systemImage: "magnifyingglass")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.xl)
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
        }
    }
}

// MARK: - Đang quét

struct CleanupScanningView: View {
    let status: CleanupScanStatus
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Đang quét…").font(.title3.weight(.semibold))
                if status.total > 0 && status.done > 0 {
                    ProgressView(value: status.fraction)
                } else {
                    ProgressView(value: status.fraction).opacity(0.5)
                }
                HStack {
                    Text(verbatim: CleanupText.scanStage(status.stage))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if status.total > 0 {
                        Text(verbatim: "\(status.done) / \(status.total)").monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text("Quét chỉ đọc. Bạn có thể chuyển sang trang khác, quét vẫn tiếp tục.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 460)
            .cardSurface()
            Button("Hủy", action: cancel)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tóm tắt, bộ lọc

private struct CleanupSummaryBar: View {
    let model: CleanupModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            count(.high)
            count(.medium)
            count(.info)
            tile {
                Text("Có thể dọn")
            } value: {
                Text(verbatim: model.reclaimableBytes > 0 ? Format.bytes(UInt64(model.reclaimableBytes)) : "0")
            }
            Spacer(minLength: Theme.Space.m)
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    model.startScan()
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                if model.hiddenByIgnoreList > 0 {
                    HStack(spacing: 6) {
                        Text("Đang ẩn \(model.hiddenByIgnoreList) mục đã bỏ qua")
                            .foregroundStyle(.secondary)
                        Button("Mở ignore.txt") {
                            Task { NSWorkspace.shared.activateFileViewerSelecting([await model.ignoreFileURL()]) }
                        }
                        .buttonStyle(.link)
                        .help("Hiện ignore.txt trong Finder")
                    }
                    .font(.caption)
                    .help("Các mục đã bỏ qua vĩnh viễn trước đây. Xóa dòng tương ứng trong ignore.txt để hiện lại.")
                }
                if !model.scannerErrors.isEmpty {
                    Label("Một số bộ quét gặp lỗi", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(Text(verbatim: model.scannerErrors.keys.sorted().map(CleanupText.scannerName).joined(separator: ", ")))
                }
            }
        }
    }

    private func count(_ severity: Severity) -> some View {
        tile {
            HStack(spacing: 5) {
                Circle().fill(CleanupText.severityTint(severity)).frame(width: 7, height: 7)
                Text(verbatim: CleanupText.severity(severity))
            }
        } value: {
            Text(verbatim: Format.integer(model.severityCounts[severity] ?? 0))
        }
    }

    private func tile<Title: View, Value: View>(@ViewBuilder _ title: () -> Title,
                                                @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title().font(.caption).foregroundStyle(.secondary)
            value().font(Theme.kpi).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(minWidth: 84, alignment: .leading)
        .cardSurface(radius: Theme.Radius.tile)
    }
}

private struct CleanupFilterBar: View {
    @Bindable var model: CleanupModel
    /// Chữ trong ô tìm; áp vào model sau một nhịp gõ (lọc nhiều mục không chạy lại mỗi phím).
    @State private var query: String

    init(model: CleanupModel) {
        self.model = model
        _query = State(initialValue: model.searchText)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { severity; category; search; Spacer(minLength: 0); selectAll }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.m) { severity; category }
                HStack(spacing: Theme.Space.m) { search; Spacer(minLength: 0); selectAll }
            }
        }
        .disabled(model.isBusy)
    }

    private var severity: some View {
        Picker("Mức độ", selection: $model.severityFilter) {
            ForEach(CleanupModel.SeverityFilter.allCases) { Text(verbatim: CleanupText.severityFilter($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var category: some View {
        Picker("Nhóm", selection: $model.categoryFilter) {
            Text("Tất cả nhóm").tag(CleanCategory?.none)
            Divider()
            ForEach(model.categories, id: \.category) { entry in
                Text(verbatim: "\(CleanupText.category(entry.category)) (\(entry.count))").tag(Optional(entry.category))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var search: some View {
        TextField("Tìm theo tên, đường dẫn, lý do", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160, maxWidth: 260)
            .task(id: query) {
                // xóa thì áp ngay; đang gõ thì chờ ngừng gõ (task tự hủy khi gõ tiếp, không timer)
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
                if !Task.isCancelled { model.searchText = query }
            }
            .onChange(of: model.searchText) { _, text in if text != query { query = text } }
    }

    private var selectAll: some View {
        Toggle(isOn: Binding(get: { model.allVisibleSelected },
                             set: { $0 ? model.selectAllVisible() : model.deselectAllVisible() })) {
            Text("Chọn tất cả mục đang hiện")
        }
        .toggleStyle(.checkbox)
        .disabled(model.visibleSelectableIDs.isEmpty || model.phase != .results)
        .help("Chỉ chọn các mục trong bộ lọc hiện tại. Mục chỉ báo và mục cần quyền quản trị không chọn được.")
        .fixedSize()
    }
}

private struct IgnoredUndoBar: View {
    let model: CleanupModel

    var body: some View {
        if let last = model.ignoredThisSession.last {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Đã bỏ qua vĩnh viễn: \(last.displayName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Hoàn tác") { model.undoIgnore() }
                    .buttonStyle(.link)
                if model.ignoredThisSession.count > 1 {
                    Menu {
                        ForEach(model.ignoredThisSession.reversed()) { item in
                            Button(item.displayName) { model.undoIgnore(item.id) }
                        }
                    } label: {
                        Text("Hoàn tác mục khác (\(model.ignoredThisSession.count - 1))")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        }
    }
}

// MARK: - Danh sách

private struct SectionHeader: View {
    let section: CleanupSection
    let model: CleanupModel
    let enabled: Bool

    var body: some View {
        let ids = section.selectableIDs
        let allSelected = !ids.isEmpty && ids.allSatisfy(model.isSelected)
        let name = CleanupText.category(section.category)
        HStack(spacing: 6) {
            Image(systemName: CleanupText.categorySymbol(section.category))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: Format.integer(section.items.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if !ids.isEmpty {
                if allSelected {
                    Button("Bỏ chọn nhóm") { model.setSection(section, selected: false) }
                        .buttonStyle(.link)
                        .disabled(!enabled)
                        .accessibilityLabel(Text("Bỏ chọn nhóm \(name)"))
                } else {
                    Button("Chọn cả nhóm") { model.setSection(section, selected: true) }
                        .buttonStyle(.link)
                        .disabled(!enabled)
                        .accessibilityLabel(Text("Chọn cả nhóm \(name)"))
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}

/// Một dòng: ô chọn, mức độ, tên, đường dẫn (cắt giữa), lý do, dung lượng. Mọi chữ đã tính sẵn trong `CleanupItem`.
struct FindingRowView: View {
    let item: CleanupItem
    let selected: Bool
    let enabled: Bool
    /// Trang Gỡ ứng dụng: mọi mục cùng mức nên không hiện nhãn mức độ.
    var showsSeverity = true
    /// Vì sao ô chọn bị khóa dù mục chọn được (vd app chủ đang chạy).
    var blockedHelp: Text?
    let setSelected: (Bool) -> Void

    var body: some View {
        let f = item.finding
        HStack(alignment: .top, spacing: 10) {
            // Chỉ ô chọn bật/tắt (bấm vào dòng để đọc, chọn chữ không vô tình đánh dấu mục).
            Toggle(isOn: Binding(get: { selected }, set: setSelected)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.selectable || !enabled)
                .help(checkboxHelp)
                .accessibilityLabel(Text(verbatim: item.displayName))
                .accessibilityValue(accessibilityDetail)
                .accessibilityHint(checkboxHelp)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if showsSeverity { SeverityBadge(severity: f.severity) }
                    Text(verbatim: item.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if f.needsAdmin {
                        TagBadge(text: Text("Cần quyền quản trị"), symbol: "lock.fill")
                    }
                    if f.isSharedAppFile || f.isJointAppFile {
                        TagBadge(text: Text("Dùng chung"), symbol: "person.2")
                    } else if f.appFileMatch?.isLowConfidence == true {
                        TagBadge(text: Text("Gần đúng"), symbol: "questionmark.circle")
                    } else if f.kind == .reportOnly {
                        TagBadge(text: Text("Chỉ báo"), symbol: "eye")
                    }
                    Spacer(minLength: Theme.Space.s)
                    if let size = item.sizeText {
                        Text(verbatim: size)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Text(verbatim: item.displayTarget)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Lý do luôn đọc được đủ: 4 dòng, còn dài hơn thì xem trong chú thích hoặc chọn chữ.
                Text(verbatim: item.reasonText)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(Text(verbatim: item.reasonText))
            }
        }
        .padding(.vertical, 4)
        .opacity(item.selectable ? 1 : 0.85)
    }

    /// Thư mục chứa + nhãn: hai mục cùng tên (Containers / Application Scripts) đọc ra khác nhau.
    private var accessibilityDetail: Text {
        let f = item.finding
        var parts = [PathResolver.tail(PathResolver.parent(f.target))]
        if f.needsAdmin { parts.append(String(localized: "Cần quyền quản trị")) }
        if f.isSharedAppFile || f.isJointAppFile { parts.append(String(localized: "Dùng chung")) }
        if f.appFileMatch?.isLowConfidence == true { parts.append(String(localized: "Gần đúng")) }
        if let size = item.sizeText { parts.append(size) }
        return Text(verbatim: parts.joined(separator: ", "))
    }

    private var checkboxHelp: Text {
        if item.finding.isSharedAppFile { return Text("Dùng chung với ứng dụng khác còn cài: không gỡ cùng ứng dụng này.") }
        if let blockedHelp, !enabled { return blockedHelp }
        if item.finding.kind == .reportOnly { return Text("Chỉ báo: mục này không bao giờ được tự gỡ.") }
        if item.finding.needsAdmin { return Text("Cần quyền quản trị: chuột phải để sao chép lệnh và tự chạy trong Terminal.") }
        if !item.selectable { return Text("Chưa hỗ trợ gỡ mục kiểu này.") }
        return Text("Chọn mục này. Việc sẽ làm: \(CleanupText.plannedAction(item.finding))")
    }
}

// MARK: - Thanh dưới

private struct CleanupBottomBar: View {
    let model: CleanupModel
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if model.phase == .removing {
                removing
            } else {
                let hidden = model.hiddenSelectionCount
                if hidden > 0 { hiddenNotice(hidden) }
                selectionRow
            }
        }
        .font(.callout)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var removing: some View {
        let p = model.removalProgress
        return HStack(spacing: Theme.Space.m) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .frame(width: 160)
            Text("Đang dọn \(p.done) / \(p.total)…").monospacedDigit()
            Spacer()
            Button("Dừng") { model.cancelRemoval() }
        }
    }

    /// Mục đã chọn nhưng bộ lọc đang ẩn: vẫn nằm trong lần dọn nên phải nói rõ.
    private func hiddenNotice(_ hidden: Int) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "eye.slash").foregroundStyle(.orange).accessibilityHidden(true)
            Text("\(hidden) mục đã chọn đang bị bộ lọc ẩn")
            Button("Hiện tất cả") { model.clearFilters() }
                .buttonStyle(.link)
            Button("Bỏ chọn các mục này") { model.deselectHidden() }
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
    }

    private var selectionRow: some View {
        HStack(spacing: Theme.Space.m) {
            let count = model.selection.count
            if count == 0 {
                Text("Chưa chọn mục nào").foregroundStyle(.secondary)
            } else {
                Text("Đã chọn \(count) mục · \(Format.bytes(UInt64(max(model.selectedBytes, 0))))")
            }
            Spacer()
            if count == 0 {
                Button("Dọn mục đã chọn…", action: review)
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            } else if CleanupText.isTrashOnly(model.selectedItems.map(\.finding)) {
                Button("Chuyển \(count) mục vào Thùng rác…", action: review)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .results)
            } else {
                // có sửa file cấu hình / thu hồi quyền: không gọi chung là "vào Thùng rác"
                Button("Dọn \(count) mục…", action: review)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .results)
            }
        }
    }
}

// MARK: - Full Disk Access

struct FullDiskAccessNotice: View {
    let recheck: () -> Void

    var body: some View {
        BannerLayout(symbol: "lock.shield", tint: .orange, title: Text("Chưa có quyền Truy cập toàn bộ ổ đĩa"),
                     message: Text("Không có quyền này, app không đọc được dữ liệu quyền riêng tư (TCC) và vài thư mục trong ~/Library nên có thể bỏ sót tàn dư. Quét vẫn chạy được.")) {
            VStack(alignment: .trailing, spacing: 6) {
                Button("Mở Cài đặt") { NSWorkspace.shared.open(CleanupActions.fullDiskAccessSettings) }
                Button("Kiểm tra lại", action: recheck)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            .fixedSize()
        }
    }
}
