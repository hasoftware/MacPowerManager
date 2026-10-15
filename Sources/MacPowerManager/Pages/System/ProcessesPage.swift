import AppKit
import PowerCore
import SwiftUI

/// Tiến trình: bảng sắp xếp được, tìm kiếm, lọc, bảng chi tiết với Thoát / Buộc thoát.
struct ProcessesPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var sortOrder = [KeyPathComparator(\ProcessMonitor.Row.cpu, order: .reverse)]
    @State private var selection: ProcessMonitor.Row.ID?
    @State private var confirmForceQuit: ProcessMonitor.Row?
    /// Chỉ vẽ 100 tiến trình đầu (theo cách sắp xếp đang chọn): bảng 700+ dòng tốn CPU mỗi lần làm mới.
    @AppStorage("processes.showAll") private var showAll = false

    static let rowLimit = 100

    enum Filter: CaseIterable, Identifiable {
        case all, apps, mine, system
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .all: "Tất cả"
            case .apps: "Ứng dụng"
            case .mine: "Của tôi"
            case .system: "Hệ thống"
            }
        }
    }

    var body: some View {
        let monitor = model.processes
        let matching = visibleRows(monitor.rows)
        let rows = showAll ? matching : Array(matching.prefix(Self.rowLimit))
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Tên", value: \.name) { row in
                HStack(spacing: 6) {
                    ProcessIcon(row: row, size: 16)
                    Text(verbatim: row.name).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("% CPU", value: \.cpu) { row in
                Text(verbatim: Format.number(row.cpu * 100, digits: 1))
                    .foregroundStyle(row.cpu >= 0.3 ? .orange : row.cpu < 0.001 ? .secondary : .primary)
            }
            .width(64)
            TableColumn("Bộ nhớ", value: \.memory) { row in Text(verbatim: Format.bytes(row.memory)) }
                .width(78)
            TableColumn("Năng lượng", value: \.power) { row in
                Text(verbatim: Format.power(row.power)).foregroundStyle(row.power < 0.005 ? .secondary : .primary)
            }
            .width(78)
            TableColumn("Luồng", value: \.threads) { row in Text(verbatim: "\(row.threads)") }
                .width(52)
            TableColumn("Thời gian CPU", value: \.cpuTime) { row in Text(verbatim: Format.cpuTime(row.cpuTime)) }
                .width(90)
            TableColumn("PID", value: \.pid) { row in Text(verbatim: "\(row.pid)") }
                .width(56)
            TableColumn("Người dùng", value: \.user) { row in Text(verbatim: row.user).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90)
        }
        .font(.callout.monospacedDigit())
        .searchable(text: $search, placement: .toolbar, prompt: Text("Tìm tiến trình"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Làm mới", selection: Binding(get: { monitor.chosenInterval }, set: { value in
                    monitor.chosenInterval = value
                    model.applyRefreshPolicy()
                })) {
                    ForEach(RefreshPolicy.processChoices, id: \.self) { seconds in
                        Text("\(Int(seconds)) giây").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .help("Làm mới thưa hơn giúp app tốn ít CPU và pin hơn. Khi chạy pin, app tự làm mới tối thiểu mỗi 5 giây.")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Lọc", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let row = monitor.rows.first(where: { $0.pid == selection }) {
                ProcessInspector(row: row, history: monitor.history[row.pid] ?? [],
                                 quit: { monitor.quit(row, force: false) },
                                 forceQuit: { confirmForceQuit = row },
                                 close: { selection = nil })
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            } else {
                ContentUnavailableView("Tiến trình đã kết thúc", systemImage: "xmark.circle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Theme.Space.l) {
                if rows.count < matching.count {
                    Text("\(rows.count) / \(matching.count) tiến trình · \(monitor.threadCount) luồng")
                    Button("Hiện tất cả") { showAll = true }
                        .buttonStyle(.link)
                } else {
                    Text("\(rows.count) tiến trình · \(monitor.threadCount) luồng")
                    if showAll && matching.count > Self.rowLimit {
                        Button("Chỉ hiện \(Self.rowLimit) tiến trình đầu") { showAll = false }
                            .buttonStyle(.link)
                    }
                }
                if !monitor.includesAllUsers {
                    Label("Chỉ thấy tiến trình của bạn. Cài helper để xem cả tiến trình hệ thống.", systemImage: "info.circle")
                }
                Spacer()
                Text(verbatim: "CPU \(Format.percent((model.system.latest?.cpu.total ?? 0) * 100))")
                Text(verbatim: "\(String(localized: "Năng lượng")) \(Format.power(monitor.totalPower))")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .confirmationDialog(Text("Buộc thoát \(confirmForceQuit?.name ?? "")?"),
                            isPresented: Binding(get: { confirmForceQuit != nil }, set: { if !$0 { confirmForceQuit = nil } })) {
            Button("Buộc thoát", role: .destructive) {
                if let row = confirmForceQuit { monitor.quit(row, force: true) }
                confirmForceQuit = nil
            }
        } message: {
            Text("Dữ liệu chưa lưu trong tiến trình này sẽ mất.")
        }
        .onAppear { monitor.retain() }
        .onDisappear { monitor.release() }
    }

    private func visibleRows(_ rows: [ProcessMonitor.Row]) -> [ProcessMonitor.Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return rows.filter { row in
            switch filter {
            case .all: true
            case .apps: row.isApp
            case .mine: row.isMine
            case .system: !row.isMine
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || "\($0.pid)" == query }
        .sorted(using: sortOrder)
    }
}

/// Biểu tượng ứng dụng, hoặc biểu tượng chung cho tiến trình nền. Lưu đệm theo đường dẫn.
struct ProcessIcon: View {
    let row: ProcessMonitor.Row
    var size: CGFloat = 16

    var body: some View {
        if let image = Self.icon(for: row) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for row: ProcessMonitor.Row) -> NSImage? {
        guard let path = row.bundleURL?.path else { return nil }
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

/// Bảng chi tiết của một tiến trình.
private struct ProcessInspector: View {
    let row: ProcessMonitor.Row
    let history: [ProcessMonitor.Point]
    let quit: () -> Void
    let forceQuit: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    ProcessIcon(row: row, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.name).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(verbatim: "PID \(row.pid) · \(row.user)").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }

                HStack {
                    Button("Thoát", action: quit)
                    Button("Buộc thoát", role: .destructive, action: forceQuit)
                    if let url = row.bundleURL ?? row.path.map({ URL(fileURLWithPath: $0) }) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Hiện trong Finder")
                    }
                }
                .disabled(!row.isMine)
                if !row.isMine {
                    Text("Tiến trình của hệ thống hoặc người dùng khác: không thoát được từ đây.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                MiniChart(title: "CPU", value: Format.percent(row.cpu * 100), tint: SystemTint.cpu,
                          values: history.map(\.cpu))
                MiniChart(title: "Bộ nhớ", value: Format.bytes(row.memory), tint: SystemTint.memory,
                          values: history.map { Double($0.memory) })

                VStack(alignment: .leading, spacing: 8) {
                    Text("Chi tiết").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    InfoRow("Thời gian CPU", Format.cpuTime(row.cpuTime))
                    InfoRow("Luồng", "\(row.threads)")
                    InfoRow("Bộ nhớ thực", Format.bytes(row.memory))
                    InfoRow("Bộ nhớ ảo", Format.bytes(row.virtualMemory))
                    InfoRow("Năng lượng", Format.power(row.power))
                    InfoRow("Đánh thức", String(localized: "\(Format.number(row.wakeupsPerSecond, digits: 1))/giây"))
                    InfoRow("Đọc ổ đĩa", "\(Format.rate(row.diskReadRate)) · \(Format.bytes(row.diskRead))")
                    InfoRow("Ghi ổ đĩa", "\(Format.rate(row.diskWriteRate)) · \(Format.bytes(row.diskWritten))")
                    if let started = row.started {
                        InfoRow("Bắt đầu", "\(Format.dateTime(started)) · \(started.formatted(.relative(presentation: .named).locale(Format.locale)))")
                    }
                    if let path = row.path {
                        Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(Theme.Space.l)
        }
    }
}

private struct MiniChart: View {
    let title: LocalizedStringKey
    let value: String
    let tint: Color
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(verbatim: value).font(.callout.weight(.semibold).monospacedDigit())
            }
            let peak = max(values.max() ?? 0, title == "CPU" ? 1 : 1)
            let padded = Array(repeating: nil, count: max(ProcessMonitor.historyLength - values.count, 0))
                + values.map { Optional([$0 / peak]) }
            DotMatrixChart(columns: padded, colors: [tint], rows: 6, tint: tint)
                .frame(height: 76)
        }
    }
}

extension Format {
    /// "2,60 W", "900 mW", "0".
    static func power(_ watts: Double) -> String {
        if watts < 0.005 { return "0" }
        if watts < 1 { return "\(Int((watts * 1000).rounded())) mW" }
        return "\(number(watts, digits: 2)) W"
    }

    /// "25:12,00" (phút:giây) hoặc "1:05:12" khi trên một giờ.
    static func cpuTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        let hundredths = Int((seconds - Double(total)) * 100)
        return String(format: "%d:%02d.%02d", m, s, hundredths)
    }
}
