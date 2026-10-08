import Foundation
import PowerCore
import XCTest
@testable import MacPowerManager

final class ForeignWriteBannerTests: XCTestCase {
    private func write(_ secondsAgo: TimeInterval, from now: Date) -> ForeignWrite {
        ForeignWrite(key: "CHTE", expected: "01", found: "00", at: now.addingTimeInterval(-secondsAgo))
    }

    func testRecentWriteShown() {
        let now = Date()
        XCTAssertNotNil(AppModel.recentForeignWrite(in: [write(29 * 60, from: now)], now: now))
    }

    func testOldWriteHidden() {
        let now = Date()
        XCTAssertNil(AppModel.recentForeignWrite(in: [write(31 * 60, from: now)], now: now))
        XCTAssertNil(AppModel.recentForeignWrite(in: [], now: now))
        XCTAssertNil(AppModel.recentForeignWrite(in: nil, now: now))
    }

    func testLatestWriteWinsRegardlessOfOrder() {
        let now = Date()
        let latest = write(60, from: now)
        let result = AppModel.recentForeignWrite(in: [latest, write(3600, from: now)], now: now)
        XCTAssertEqual(result, latest)
    }
}
