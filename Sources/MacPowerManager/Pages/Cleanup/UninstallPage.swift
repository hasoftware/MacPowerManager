import AppKit
import CleanCore
import SwiftUI

/// Gỡ ứng dụng: chọn app, xem lại mọi file liên quan (không chọn sẵn gì, mỗi mục ghi rõ vì sao), rồi chuyển vào Thùng
/// rác có sao lưu (khôi phục trong Lịch sử dọn). Mục cần quyền quản trị và mục dùng chung chỉ được báo.
struct UninstallPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        UninstallView(model: app.uninstall)
    }
}

struct UninstallView: View {
    @Bindable var model: UninstallModel
    @State private var confirming = false

    var body: some View {
        Group {
            switch model.phase {
            case .list: UninstallAppListView(model: model)
            case .collecting: UninstallCollectingView(apps: model.collectingApps) { model.cancelCollect() }
            case .review, .removing, .finished: UninstallReviewView(model: model) { confirming = true }
            }
        }
        .frame(maxWidth: MonitorPage<EmptyView>.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
        // Không timer: macOS báo khi có app thoát thì mới kiểm tra lại app đang chạy.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.appDidTerminate()
        }
        .sheet(isPresented: $confirming) {
            ConfirmRemovalSheet(items: model.selectedItems, bytes: model.selectedBytes, showsSeverity: false,
                                warnings: model.confirmWarnings,
                                cancel: { confirming = false },
                                confirm: {
                                    confirming = false
                                    model.removeSelected()
                                })
        }
        .sheet(isPresented: Binding(get: { if case .finished = model.phase { true } else { false } },
                                    set: { if !$0 { model.closeResults(backToList: false) } })) {
            if case .finished(let run) = model.phase {
                RemovalResultsSheet(run: run,
                                    close: { model.closeResults(backToList: false) },
                                    rescan: { model.closeResults(backToList: true) },
                                    rescanTitle: "Về danh sách ứng dụng", notes: model.resultNotes)
            }
        }
        .alert(Text("Có lỗi"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }
}

// MARK: - Danh sách app

private struct UninstallAppListView: View {
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                if model.appsLoaded { UninstallFilterBar(model: model) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)
            Divider()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.appsLoaded && !model.apps.isEmpty { UninstallListBottomBar(model: model) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chọn ứng dụng cần gỡ").font(.title3.weight(.semibold))
                Text("Xem lại mọi file liên quan trước khi gỡ. Không mục nào được chọn sẵn; mọi thứ vào Thùng rác và khôi phục được trong Lịch sử dọn.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button {
                model.loadApps(keepSizes: false)
            } label: {
                Label("Làm mới", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingApps)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.appsLoaded {
            VStack(spacing: Theme.Space.m) {
                ProgressView().controlSize(.small)
                Text("Đang liệt kê ứng dụng…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.apps.isEmpty {
            ContentUnavailableView("Không có ứng dụng nào gỡ được", systemImage: "app.dashed")
                .frame(maxHeight: .infinity)
        } else if model.visibleApps.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(model.visibleApps) { row in
                    UninstallAppRowView(app: row.app, size: model.sizes[row.id], sizing: model.isSizing,
                                        selected: model.isAppSelected(row.id)) { on in
                        model.setAppSelected(row.id, on)
                    }
                    .contextMenu {
                        Button("Hiện trong Finder") { CleanupActions.reveal(row.app.path) }
                        Button("Sao chép đường dẫn") { CleanupActions.copy(row.app.path) }
                        if let bid = row.app.bundleID {
                            Button("Sao chép bundle id") { CleanupActions.copy(bid) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .contentMargins(.horizontal, Theme.Space.xl - Theme.Space.l, for: .scrollContent)
        }
    }
}

private struct UninstallFilterBar: View {
    @Bindable var model: UninstallModel
    /// Chữ trong ô tìm; áp vào model sau một nhịp gõ.
    @State private var query: String

    init(model: UninstallModel) {
        self.model = model
        _query = State(initialValue: model.searchText)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { search; sort; Spacer(minLength: 0); status }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.m) { search; sort }
                status
            }
        }
    }

    private var search: some View {
        TextField("Tìm theo tên hoặc bundle id", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160, maxWidth: 280)
            .task(id: query) {
                // không timer: task tự hủy khi gõ tiếp
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
                if !Task.isCancelled { model.searchText = query }
            }
            .onChange(of: model.searchText) { _, text in if text != query { query = text } }
    }

    private var sort: some View {
        Picker("Sắp xếp", selection: $model.sortOrder) {
            Text("Tên").tag(UninstallModel.SortOrder.name)
            Text("Dung lượng").tag(UninstallModel.SortOrder.size)
            Text("Dùng gần nhất").tag(UninstallModel.SortOrder.lastUsed)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var status: some View {
        Group {
            if model.isSizing {
                Text("Đang tính dung lượng…")
            } else if model.excludedCount > 0 {
                Text("\(model.apps.count) ứng dụng, ẩn \(model.excludedCount) ứng dụng không gỡ được")
                    .help("App của macOS (/System), chính MacPowerManager, app nằm trong app khác và app trong Thùng rác không được đưa ra gỡ.")
            } else {
                Text("\(model.apps.count) ứng dụng")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Một app: ô chọn, biểu tượng, tên + phiên bản, bundle id, dung lượng, lần dùng gần nhất. Cả dòng là nhãn của ô chọn
/// (bấm đâu cũng chọn, như ô chọn chuẩn của macOS).
private struct UninstallAppRowView: View {
    let app: InstalledApp
    let size: Int64?
    let sizing: Bool
    let selected: Bool
    let setSelected: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { selected }, set: setSelected)) {
            HStack(spacing: 10) {
                AppIconView(path: app.path, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: app.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let version = app.version {
                            Text(verbatim: version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(verbatim: app.bundleID ?? app.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: Theme.Space.m)
                VStack(alignment: .trailing, spacing: 2) {
                    Group {
                        if let size {
                            Text(verbatim: Format.bytes(UInt64(max(size, 0))))
                        } else if sizing {
                            Text(verbatim: "–").foregroundStyle(.tertiary).help(Text("Đang tính dung lượng…"))
                        } else {
                            Text(verbatim: "–").foregroundStyle(.tertiary)
                        }
                    }
                    .monospacedDigit()
                    Text(verbatim: UninstallText.lastUsed(app.lastUsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(Text(verbatim: app.name))
        .accessibilityValue(Text(verbatim: accessibilityDetail))
        .padding(.vertical, 3)
    }

    /// Phiên bản, dung lượng, lần dùng gần nhất (nhãn chỉ giữ tên app).
    private var accessibilityDetail: String {
        var parts: [String] = []
        if let version = app.version { parts.append(version) }
        if let size { parts.append(Format.bytes(UInt64(max(size, 0)))) }
        parts.append(UninstallText.lastUsed(app.lastUsed))
        return parts.joined(separator: ", ")
    }
}

private struct UninstallListBottomBar: View {
    let model: UninstallModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            let count = model.appSelection.count
            if count == 0 {
                Text("Chưa chọn ứng dụng nào").foregroundStyle(.secondary)
            } else {
                let bytes = model.selectedAppsBytes
                if bytes > 0 && model.selectedAppsSizePending {
                    Text("Đã chọn \(count) ứng dụng · \(Format.bytes(UInt64(bytes))) (đang tính)")
                } else if bytes > 0 {
                    Text("Đã chọn \(count) ứng dụng · \(Format.bytes(UInt64(bytes)))")
                } else {
                    Text("Đã chọn \(count) ứng dụng")
                }
                Button("Bỏ chọn") { model.clearAppSelection() }
                    .buttonStyle(.link)
            }
            Spacer()
            Button {
                model.findRelatedFiles()
            } label: {
                Label("Tìm file liên quan", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCollect)
        }
        .font(.callout)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Đang gom

private struct UninstallCollectingView: View {
    let apps: [InstalledApp]
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Đang tìm file liên quan…").font(.title3.weight(.semibold))
                }
                Text(verbatim: apps.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("Chỉ đọc: chưa có gì bị thay đổi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 460, alignment: .leading)
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

// MARK: - Xem lại

private struct UninstallReviewView: View {
    let model: UninstallModel
    let review: () -> Void

    var body: some View {
        let enabled = model.phase == .review
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                if !model.runningApps.isEmpty {
                    RunningAppsBanner(model: model)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)
            Divider()
            List {
                ForEach(model.rows) { row in
                    switch row {
                    case .header(let group):
                        UninstallGroupHeader(group: group, model: model, enabled: enabled)
                            .padding(.top, Theme.Space.s)
                            .listRowSeparator(.hidden)
                    case .item(let item):
                        UninstallItemRow(item: item, model: model, enabled: enabled)
                    }
                }
            }
            .listStyle(.inset)
            .contentMargins(.horizontal, Theme.Space.xl - Theme.Space.l, for: .scrollContent)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            UninstallReviewBottomBar(model: model, review: review)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    model.backToList()
                } label: {
                    Label("Chọn ứng dụng khác", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .disabled(model.phase != .review)
                Text("Xem lại trước khi gỡ").font(.title3.weight(.semibold))
                Text("Không mục nào được chọn sẵn. Mục cần quyền quản trị và mục dùng chung với ứng dụng khác chỉ được báo, không gỡ.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button {
                model.refreshReview()
            } label: {
                Label("Tìm lại", systemImage: "arrow.clockwise")
            }
            .disabled(model.phase != .review)
            .help("Tìm lại file liên quan của các ứng dụng này (sau khi thoát ứng dụng hoặc cấp quyền).")
        }
    }
}

/// App có tiến trình chạy từ trong gói. Ba loại, ba cách xử lý: app (nút Thoát), dịch vụ launchd của chính app
/// (chọn job để dừng khi gỡ, hoặc lệnh quản trị), helper do công cụ khác chạy (chỉ nói tên, ai chạy).
private struct RunningAppsBanner: View {
    let model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            banner
            ForEach(model.runningApps, id: \.path) { app in
                if let state = model.running[app.path] {
                    RunningAppRow(app: app, state: state, model: model)
                        .padding(.leading, Theme.Space.m)
                }
            }
        }
    }

    private var banner: some View {
        BannerLayout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                     title: Text("Ứng dụng đang chạy"),
                     message: Text("Mục của ứng dụng đang chạy bị khóa vì xóa dữ liệu đang dùng dễ làm hỏng nó. Khi ứng dụng thoát, trang tự kiểm tra lại; với tiến trình khác, bấm Kiểm tra lại.")) {
            Button("Kiểm tra lại") { model.recheckRunning() }
                .disabled(model.phase != .review)
        }
    }
}

private struct RunningAppRow: View {
    let app: InstalledApp
    let state: AppRunState
    let model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.s) {
                Text(verbatim: app.name).fontWeight(.semibold)
                if !state.appProcesses.isEmpty {
                    if model.quitRequested.contains(app.path) {
                        ProgressView().controlSize(.mini)
                        Text("Đang chờ \(app.name) thoát…").foregroundStyle(.secondary)
                    } else {
                        Button("Thoát \(app.name)") { model.quit(app) }
                            .controlSize(.small)
                            .disabled(model.phase != .review)
                    }
                }
            }
            if !state.helpers.isEmpty {
                let list = state.helpers.map { p in
                    p.parentName.map { String(localized: "\(p.process.name) (do \($0) chạy)") } ?? p.process.name
                }.joined(separator: ", ")
                Text("Tiến trình khác đang dùng gói này: \(list). Thoát công cụ đã chạy chúng rồi bấm Kiểm tra lại.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(state.services, id: \.findingID) { service in
                ServiceLine(service: service, model: model)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

/// Dịch vụ launchd của app chạy từ trong gói: Thoát không dừng được nó (launchd chạy lại).
private struct ServiceLine: View {
    let service: RunningService
    let model: UninstallModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Group {
                if service.isSelectable {
                    Text("Dịch vụ nền \(service.label) đang chạy từ gói. Chọn mục job của nó: khi gỡ, job được dừng trước rồi mới gỡ gói.")
                } else {
                    Text("Dịch vụ nền \(service.label) (\(service.domain)) đang chạy từ gói và chỉ dừng được bằng quyền quản trị. Gói bị khóa tới khi dịch vụ dừng; dữ liệu người dùng vẫn gỡ được.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if service.isSelectable {
                Button("Chọn job này") { model.setSelected(service.findingID, true) }
                    .buttonStyle(.link)
                    .disabled(model.phase != .review || model.isSelected(service.findingID))
            } else {
                Button("Sao chép lệnh dừng") { CleanupActions.copy(UninstallModel.stopCommand(for: service)) }
                    .buttonStyle(.link)
                    .help(Text(verbatim: UninstallModel.stopCommand(for: service)))
            }
        }
    }
}

private struct UninstallGroupHeader: View {
    let group: UninstallGroup
    let model: UninstallModel
    let enabled: Bool

    var body: some View {
        let app = group.app
        let running = model.isRunning(app.path)
        let bulk = model.bulkSelectableIDs(group)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppIconView(path: app.path, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: app.name)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        if let version = app.version {
                            Text(verbatim: version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if running {
                            TagBadge(text: Text("Đang chạy"), symbol: "play.circle.fill")
                        }
                        if model.missingApps.contains(app.path) {
                            TagBadge(text: Text("Gói đã gỡ"), symbol: "checkmark.circle")
                        }
                    }
                    summary
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                if !bulk.isEmpty {
                    if model.isGroupFullySelected(group) {
                        Button("Bỏ chọn app này") { model.setGroup(group, selected: false) }
                            .buttonStyle(.link)
                            .disabled(!enabled)
                            .accessibilityLabel(Text("Bỏ chọn mọi mục của \(app.name)"))
                    } else {
                        Button("Chọn tất cả của app này") { model.setGroup(group, selected: true) }
                            .buttonStyle(.link)
                            .disabled(!enabled)
                            .help(Text("Chọn mọi mục gỡ được của \(app.name), trừ mục khớp gần đúng."))
                            .accessibilityLabel(Text("Chọn mọi mục của \(app.name)"))
                    }
                }
            }
            if model.activeDeveloperApps.contains(app.path) {
                warning(Text("\(app.name) đang là công cụ dòng lệnh mặc định (xcode-select). Gỡ nó thì git, clang, swift lỗi cho tới khi chạy \"sudo xcode-select --reset\"."))
            }
            if model.isDataOnly(group) {
                warning(Text("Chưa chọn gói ứng dụng: \(app.name) vẫn còn cài, chỉ dữ liệu của nó bị xóa (có thể bị đăng xuất, mất cài đặt)."))
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    /// "6 mục · gỡ được 9 MB · chỉ báo 121 MB · 4 cần quyền quản trị · 1 dùng chung · 2 gần đúng"
    private var summary: some View {
        HStack(spacing: 4) {
            Text("\(group.items.count) mục")
            Text(verbatim: "·")
            Text("gỡ được \(Format.bytes(UInt64(max(group.removableBytes, 0))))")
            if group.reportBytes > 0 {
                Text(verbatim: "·")
                Text("chỉ báo \(Format.bytes(UInt64(group.reportBytes)))")
            }
            if group.adminCount > 0 {
                Text(verbatim: "·")
                Text("\(group.adminCount) cần quyền quản trị")
            }
            if group.sharedCount > 0 {
                Text(verbatim: "·")
                Text("\(group.sharedCount) dùng chung")
            }
            if group.lowConfidenceCount > 0 {
                Text(verbatim: "·")
                Text("\(group.lowConfidenceCount) gần đúng")
            }
        }
    }

    private func warning(_ text: Text) -> some View {
        Label {
            text.fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
        }
        .font(.callout)
        .padding(.leading, 38)
    }
}

/// Mục của app: dòng chung với trang Quét tàn dư, thêm hướng dẫn khi chính gói app cần quyền.
private struct UninstallItemRow: View {
    let item: CleanupItem
    let model: UninstallModel
    let enabled: Bool

    var body: some View {
        let f = item.finding
        let canPick = model.canSelect(item) || model.isSelected(item.id)
        VStack(alignment: .leading, spacing: 6) {
            FindingRowView(item: item, selected: model.isSelected(item.id), enabled: enabled && canPick,
                           showsSeverity: false, blockedHelp: blockedHelp) { on in
                model.setSelected(item.id, on)
            }
            if case .appBundle(let owner) = f.reason, f.needsAdmin {
                ProtectedBundleNote(path: f.target, running: model.isRunning(owner.path),
                                    rootOwned: model.rootOwnedApps.contains(owner.path),
                                    hasAdminItems: hasAdminServiceItems(owner))
                    .padding(.leading, 26)
                    .padding(.bottom, 4)
            }
        }
        .contextMenu { menu }
    }

    /// Có helper root/job launchd cần quản trị của cùng app (cài bằng trình cài đặt).
    private func hasAdminServiceItems(_ owner: AppRef) -> Bool {
        model.items.contains { other in
            guard other.finding.uninstallOwner == owner, other.finding.needsAdmin else { return false }
            if case .launchdJob = other.finding.action { return true }
            return other.finding.appFileMatch == .privilegedHelper
        }
    }

    private var blockedHelp: Text? {
        switch model.runBlock(item) {
        case .running?: return Text("Ứng dụng đang chạy: thoát trước khi gỡ.")
        case .serviceNeedsAdmin(let label, _)?: return Text("Dịch vụ nền \(label) đang chạy từ gói này: dừng nó bằng quyền quản trị trước.")
        case .serviceNotSelected?, .sharedWithKeptApp?, nil: break
        }
        if item.finding.isJointAppFile {
            let names = item.finding.uninstallOwners.map(\.name).joined(separator: ", ")
            return Text("Dùng chung giữa \(names): chọn gói của mọi ứng dụng này trước.")
        }
        return nil
    }

    @ViewBuilder
    private var menu: some View {
        let f = item.finding
        if let path = CleanupText.filePath(f) {
            Button("Hiện trong Finder") { CleanupActions.reveal(path) }
            Button("Sao chép đường dẫn") { CleanupActions.copy(path) }
        } else {
            Button("Sao chép đường dẫn") { CleanupActions.copy(f.target) }
        }
        if f.needsAdmin {
            Button("Sao chép lệnh") {
                Task { CleanupActions.copy(await model.adminCommand(for: f)) }
            }
        }
    }
}

/// Gói app không ghi được. Ba trường hợp: app đang chạy (thoát trước, không kéo vào Thùng rác khi đang chạy); gói
/// thuộc root hoặc có helper/dịch vụ root (dùng trình gỡ của hãng hoặc lệnh quản trị, Finder để lại dịch vụ root trỏ
/// vào chỗ trống); gói của người dùng mà macOS chặn (cấp quyền Quản lý ứng dụng).
private struct ProtectedBundleNote: View {
    let path: String
    let running: Bool
    let rootOwned: Bool
    let hasAdminItems: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                message.fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.orange).accessibilityHidden(true)
            }
            .font(.callout)
            HStack(spacing: Theme.Space.m) {
                Button("Hiện trong Finder") { CleanupActions.reveal(path) }
                if !running && !rootOwned && !hasAdminItems {
                    Button("Mở cài đặt Quản lý ứng dụng") { NSWorkspace.shared.open(UninstallText.appManagementSettings) }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.leading, 24)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    private var message: Text {
        if running {
            return Text("MacPowerManager không được phép sửa gói này. Ứng dụng đang chạy: thoát nó (và dừng dịch vụ nền của nó) trước khi gỡ bằng bất kỳ cách nào.")
        }
        if rootOwned || hasAdminItems {
            return Text("Gói này được cài bằng trình cài đặt (thuộc root, hoặc kèm helper/dịch vụ chạy quyền root). Dùng trình gỡ của hãng nếu có; hoặc chạy lệnh quản trị của các mục bên dưới (chuột phải → Sao chép lệnh) trước, rồi mới bỏ gói vào Thùng rác.")
        }
        return Text("MacPowerManager không được phép sửa gói này (macOS chặn vì chưa cấp quyền Quản lý ứng dụng). Cấp quyền rồi bấm Tìm lại, hoặc kéo nó vào Thùng rác trong Finder.")
    }
}

private struct UninstallReviewBottomBar: View {
    let model: UninstallModel
    let review: () -> Void

    var body: some View {
        Group {
            if model.phase == .removing {
                removing
            } else {
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
            Text("Đang gỡ \(p.done) / \(p.total)…").monospacedDigit()
            Spacer()
            Button("Dừng") { model.cancelRemoval() }
        }
    }

    private var selectionRow: some View {
        HStack(spacing: Theme.Space.m) {
            let count = model.selection.count
            if count == 0 {
                Text("Chưa chọn mục nào").foregroundStyle(.secondary)
            } else {
                Text("Đã chọn \(count) mục · \(Format.bytes(UInt64(max(model.selectedBytes, 0))))")
                Button("Bỏ chọn") { model.clearSelection() }
                    .buttonStyle(.link)
                    .disabled(model.phase != .review)
            }
            Spacer()
            if count > 0 && model.isOtherWorkBusy() {
                Text("Đang dọn hoặc khôi phục ở trang khác").foregroundStyle(.secondary)
            }
            if count == 0 {
                Button("Chuyển vào Thùng rác…", action: review)
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            } else {
                Button("Chuyển \(count) mục vào Thùng rác…", action: review)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRemove)
            }
        }
    }
}

// MARK: - Biểu tượng app

/// Biểu tượng app, đọc ngoài main thread và đệm (cuộn lại không đọc lại).
struct AppIconView: View {
    let path: String
    let size: CGFloat
    @State private var image: CGImage?

    init(path: String, size: CGFloat) {
        self.path = path
        self.size = size
        _image = State(initialValue: AppIconCache.shared.cached(path))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: path) {
            if image == nil { image = await AppIconCache.shared.icon(for: path) }
        }
    }
}

/// Đệm biểu tượng app (CGImage 64 pt @2x). NSCache tự giải phóng khi thiếu bộ nhớ.
final class AppIconCache: @unchecked Sendable {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, CGImageBox>()

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func cached(_ path: String) -> CGImage? { cache.object(forKey: path as NSString)?.image }

    func icon(for path: String) async -> CGImage? {
        if let hit = cached(path) { return hit }
        let box = await Task.detached(priority: .utility) { () -> CGImageBox? in
            let icon = NSWorkspace.shared.icon(forFile: path)
            var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
            return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(CGImageBox.init)
        }.value
        guard let box else { return nil }
        cache.setObject(box, forKey: path as NSString)
        return box.image
    }
}

// MARK: - Chữ

enum UninstallText {
    static let appManagementSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    /// "Dùng 3 ngày trước" / "Chưa rõ lần dùng".
    static func lastUsed(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "Chưa rõ lần dùng") }
        if Calendar.current.isDate(date, inSameDayAs: now) { return String(localized: "Dùng hôm nay") }
        let relative = date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Format.locale))
        return String(localized: "Dùng \(relative)")
    }
}
