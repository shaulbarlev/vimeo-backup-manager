import Foundation
import XCTest
@testable import VBackupApp

final class FormatTests: XCTestCase {
    func testPercentSpecExample() {
        let counts = [3912, 801, 210, 398, 36]
        XCTAssertEqual(counts.reduce(0, +), 5357)
        XCTAssertEqual(counts.map { Format.percent($0, of: 5357) }, ["73.0%", "15.0%", "3.9%", "7.4%", "0.7%"])
        XCTAssertEqual(Format.percent(3912, of: 5357, decimals: 0), "73%")
    }

    func testPercentZeroTotal() {
        XCTAssertEqual(Format.percent(0, of: 0), "0.0%")
    }

    func testCountGroupsThousands() {
        XCTAssertEqual(Format.count(5357), "5,357")
        XCTAssertEqual(Format.count(12), "12")
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(0), "0 bytes")
        XCTAssertEqual(Format.bytes(1_980_000_000_000), "1.98 TB")
        XCTAssertEqual(Format.bytes(190_000_000_000), "190 GB")
    }

    func testBarSegmentsKeepMinimumAndFillWidth() {
        let widths = BarLayout.widths(counts: [3912, 801, 210, 398, 36], width: 1000)
        XCTAssertEqual(widths.reduce(0, +), 1000, accuracy: 0.001)
        XCTAssertTrue(widths.allSatisfy { $0 >= 3 })
        XCTAssertGreaterThan(widths[0], widths[1])
    }

    func testBarZeroSegmentsStayZero() {
        let widths = BarLayout.widths(counts: [10, 0, 0, 5, 0], width: 300)
        XCTAssertEqual(widths[1], 0)
        XCTAssertEqual(widths[2], 0)
        XCTAssertEqual(widths[4], 0)
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.001)
        XCTAssertEqual(BarLayout.widths(counts: [0, 0], width: 300), [0, 0])
    }
}
