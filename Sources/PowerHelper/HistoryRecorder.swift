import Foundation
import PowerCore

/// Ghi lịch sử pin của helper vào `PowerConstants.helperHistoryURL`, kể cả khi app đã thoát và trong dark wake.
/// Quyết định ghi chạy trên hàng đợi chính (cùng vòng điều khiển); đọc/ghi file chạy trên một hàng đợi tuần tự
/// riêng để vòng điều khiển không bao giờ bị chặn. Lỗi I/O chỉ ghi log (mỗi loại lỗi một lần) rồi bỏ qua.
final class HistoryRecorder {
    private let file: HistoryFile
    private let queue = DispatchQueue(label: "com.hasoftware.MacPowerManager.helper.history", qos: .utility)

    /// Chỉ dùng trên hàng đợi chính.
    private var lastRecorded: Date?
    /// Chỉ dùng trên `queue`.
    private var lastPruned: Date?
    private var lastError: String?

    init(url: URL = PowerConstants.helperHistoryURL) {
        file = HistoryFile(url: url)
    }

    /// Lấy thời điểm mẫu cuối (đồng bộ, trước lần đánh giá đầu tiên) để không ghi trùng ngay sau khi helper
    /// khởi động lại, rồi dọn file ở hàng đợi nền.
    func start() {
        if let last = file.lastSampleDate(), last <= Date() { lastRecorded = last }
        queue.async { [self] in pruneIfNeeded(now: Date()) }
    }

    /// Gọi trên hàng đợi chính sau mỗi lần đánh giá. `makeSample` chỉ chạy khi thực sự cần ghi.
    func recordIfDue(now: Date = Date(), makeSample: () -> HistorySample) {
        guard HistoryRecorderPolicy.shouldRecord(now: now, lastRecorded: lastRecorded) else { return }
        lastRecorded = now
        let sample = makeSample()
        queue.async { [self] in
            do {
                try file.append(sample)
                clearError()
            } catch {
                report("Không ghi được lịch sử pin: \(error)")
            }
            pruneIfNeeded(now: sample.date)
        }
    }

    /// Chạy trên `queue`. Trả về các mẫu còn lại nếu đã dọn.
    @discardableResult
    private func pruneIfNeeded(now: Date) -> [HistorySample]? {
        guard HistoryRecorderPolicy.shouldPrune(now: now, lastPruned: lastPruned, lineCount: file.lineCount) else {
            return nil
        }
        // Dù lỗi cũng đánh dấu đã dọn để không thử lại ở mỗi mẫu; lần sau là ngày hôm sau.
        lastPruned = now
        do {
            let kept = try file.prune(now: now)
            clearError()
            return kept
        } catch {
            report("Không dọn được lịch sử pin: \(error)")
            return nil
        }
    }

    private func report(_ message: String) {
        guard message != lastError else { return }
        lastError = message
        log(message)
    }

    private func clearError() {
        if lastError != nil {
            log("Ghi lịch sử pin hoạt động trở lại")
            lastError = nil
        }
    }
}
