import Foundation
import PowerCore

/// Một điểm trên biểu đồ. `run` là chỉ số đoạn dữ liệu liền mạch chứa điểm (để vẽ nét liền và tô vùng);
/// các đoạn được nối với nhau bằng `ChartBridge` nên đường vẫn liên tục.
struct ChartPoint: Identifiable, Equatable {
    var date: Date
    var value: Double
    var run: Int = 0
    var id: Date { date }
}

/// Đoạn nối hai điểm cách nhau quá xa (máy ngủ, máy tắt): vẽ nét đứt, mờ hơn, không tô vùng bên dưới.
struct ChartBridge: Identifiable, Equatable {
    var from: ChartPoint
    var to: ChartPoint
    var id: Date { from.date }
    var duration: TimeInterval { to.date.timeIntervalSince(from.date) }
}

/// Khoảng không có dữ liệu (máy ngủ hoặc tắt), tô nền rất nhạt.
struct ChartGap: Identifiable, Equatable {
    var start: Date
    var end: Date
    var id: Date { start }
}

/// Chuỗi giá trị liên tục cho biểu đồ lịch sử: các điểm (đã gộp khi quá nhiều), các đoạn nối qua khoảng trống
/// và các vùng nền "không có dữ liệu".
struct ChartSeries: Equatable {
    /// Hai mẫu cách nhau quá mức này thì nối bằng nét đứt.
    static let bridgeThreshold: TimeInterval = 5 * 60
    /// Khoảng trống dài hơn mức này được tô nền "không có dữ liệu".
    static let gapThreshold: TimeInterval = 10 * 60

    var points: [ChartPoint] = []
    var bridges: [ChartBridge] = []
    var gaps: [ChartGap] = []

    var isEmpty: Bool { points.isEmpty }
    var count: Int { points.count }
    var hasBridges: Bool { !bridges.isEmpty }
    var values: [Double] { points.map(\.value) }

    init(points: [ChartPoint] = [], bridges: [ChartBridge] = [], gaps: [ChartGap] = []) {
        self.points = points
        self.bridges = bridges
        self.gaps = gaps
    }

    /// Dựng chuỗi từ các cặp (thời điểm, giá trị) đã sắp xếp. Khi có nhiều hơn `maxPoints` điểm, gộp theo các ô thời
    /// gian bằng nhau (trung bình) trên toàn chuỗi; khoảng trống nhỏ hơn một ô được coi là liền mạch ở độ phân giải đó.
    init(_ raw: [(date: Date, value: Double)], maxPoints: Int = 300) {
        guard let first = raw.first, let last = raw.last else { return }
        let span = last.date.timeIntervalSince(first.date)

        // Mỗi điểm sau khi gộp nhớ mẫu gốc đầu và cuối để đo khoảng trống thật giữa hai điểm.
        struct Bucket { var date: Date; var value: Double; var firstRaw: Date; var lastRaw: Date }
        var buckets: [Bucket] = []
        var width: TimeInterval = 0
        if raw.count > maxPoints, maxPoints > 0, span > 0 {
            width = span / Double(maxPoints)
            var index = -1
            var sumT = 0.0, sumV = 0.0, n = 0.0
            var firstRaw = first.date, lastRaw = first.date
            func flush() {
                guard n > 0 else { return }
                buckets.append(Bucket(date: Date(timeIntervalSinceReferenceDate: sumT / n), value: sumV / n,
                                      firstRaw: firstRaw, lastRaw: lastRaw))
            }
            for item in raw {
                let i = min(Int(item.date.timeIntervalSince(first.date) / width), maxPoints - 1)
                if i != index {
                    flush()
                    index = i
                    sumT = 0; sumV = 0; n = 0
                    firstRaw = item.date
                }
                sumT += item.date.timeIntervalSinceReferenceDate
                sumV += item.value
                n += 1
                lastRaw = item.date
            }
            flush()
        } else {
            buckets = raw.map { Bucket(date: $0.date, value: $0.value, firstRaw: $0.date, lastRaw: $0.date) }
        }

        let bridgeLimit = max(Self.bridgeThreshold, width)
        let gapLimit = max(Self.gapThreshold, width)
        var run = 0
        var previous: (point: ChartPoint, lastRaw: Date)?
        for bucket in buckets {
            var point = ChartPoint(date: bucket.date, value: bucket.value, run: run)
            if let previous {
                let hole = bucket.firstRaw.timeIntervalSince(previous.lastRaw)
                if hole > bridgeLimit {
                    run += 1
                    point.run = run
                    bridges.append(ChartBridge(from: previous.point, to: point))
                    if hole > gapLimit {
                        // Khoảng trống liền nhau (máy chỉ thức dậy chốc lát giữa hai lần ngủ) gộp thành một vùng.
                        if let lastGap = gaps.last, previous.point.date.timeIntervalSince(lastGap.end) <= max(3 * 60, width) {
                            gaps[gaps.count - 1].end = point.date
                        } else {
                            gaps.append(ChartGap(start: previous.point.date, end: point.date))
                        }
                    }
                }
            }
            points.append(point)
            previous = (point, bucket.lastRaw)
        }
    }

    /// Các đoạn liền mạch (mỗi đoạn vẽ nét liền và tô vùng riêng).
    var runs: [[ChartPoint]] {
        var result: [[ChartPoint]] = []
        for p in points {
            if result.isEmpty || result[result.count - 1].last?.run != p.run { result.append([p]) } else { result[result.count - 1].append(p) }
        }
        return result
    }

    /// Điểm đứng riêng giữa hai khoảng trống (ví dụ một lần máy thức dậy chốc lát): vẽ chấm nhỏ để thấy có mẫu thật.
    var isolated: [ChartPoint] {
        points.indices.filter { i in
            (i == 0 || points[i - 1].run != points[i].run) && (i == points.count - 1 || points[i + 1].run != points[i].run)
                && points.count > 1
        }.map { points[$0] }
    }

    enum Selection: Equatable {
        case point(ChartPoint)
        case gap(start: Date, end: Date)
    }

    /// Điểm gần `date` nhất; nếu `date` nằm giữa một khoảng trống dài và cách hai đầu hơn `snap` thì trả về khoảng trống.
    func selection(at date: Date, snap: TimeInterval) -> Selection? {
        guard !points.isEmpty else { return nil }
        // Tìm nhị phân điểm đầu tiên không trước `date`.
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        let after = lo < points.count ? points[lo] : nil
        let before = lo > 0 ? points[lo - 1] : nil
        if let before, let after, after.date.timeIntervalSince(before.date) > Self.gapThreshold,
           date.timeIntervalSince(before.date) > snap, after.date.timeIntervalSince(date) > snap {
            return .gap(start: before.date, end: after.date)
        }
        let nearest = [before, after].compactMap { $0 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        return nearest.map { .point($0) }
    }
}

extension Array where Element == HistorySample {
    /// Trích một chuỗi giá trị liên tục (bỏ mẫu không có giá trị), gộp còn khoảng `maxPoints` điểm.
    func series(maxPoints: Int = 300, _ value: (HistorySample) -> Double?) -> ChartSeries {
        ChartSeries(compactMap { s in value(s).map { (date: s.date, value: $0) } }, maxPoints: maxPoints)
    }
}
