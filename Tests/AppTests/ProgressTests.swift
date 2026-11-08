import Contracts
import XCTest
@testable import VBackupApp

final class ProgressTests: XCTestCase {
    func testEtaExtrapolatesAndWaitsForSignal() {
        let t0 = Date(timeIntervalSince1970: 0)
        var clock = ProgressClock()
        clock.update(.scanningDisk(done: 0, total: 100), now: t0)
        XCTAssertNil(clock.eta(fraction: 0.25, now: t0.addingTimeInterval(1)))         // too early
        XCTAssertEqual(clock.eta(fraction: 0.25, now: t0.addingTimeInterval(60)), 180)  // 60s for 25% -> 180s left
        clock.update(.scanningDisk(done: 50, total: 100), now: t0.addingTimeInterval(90))
        XCTAssertEqual(clock.startedAt, t0, "same phase kind keeps its start")
        clock.update(.writingStatus, now: t0.addingTimeInterval(100))
        XCTAssertEqual(clock.startedAt, t0.addingTimeInterval(100), "new kind restarts the clock")
    }

    func testEtaText() {
        XCTAssertEqual(Format.eta(30), "<1m left")
        XCTAssertEqual(Format.eta(125), "~2m left")
        XCTAssertEqual(Format.eta(4_800), "~1h 20m left")
    }

    func testProgressLineForDownloads() {
        let t0 = Date(timeIntervalSince1970: 0)
        var clock = ProgressClock()
        clock.update(.downloading(DownloadProgress(index: 1, total: 4, title: "x", videoFraction: 0,
                                                   overallFraction: 0, bytesDownloaded: 0)), now: t0)
        let p = SyncPhase.downloading(DownloadProgress(index: 2, total: 4, title: "x", videoFraction: 0.5,
                                                       overallFraction: 0.5, bytesDownloaded: 100_000_000))
        clock.update(p, now: t0.addingTimeInterval(5))
        let line = Format.progressLine(phase: p, clock: clock, now: t0.addingTimeInterval(10))
        XCTAssertTrue(line.hasPrefix("50.0%"), line)
        XCTAssertTrue(line.contains("/s"), line)
        XCTAssertTrue(line.contains("so far"), line)
        XCTAssertTrue(line.hasSuffix("<1m left"), line)
    }

    func testResumedBytesAndThrottleDoNotInflateSpeed() {
        let t0 = Date(timeIntervalSince1970: 0)
        var clock = ProgressClock()
        // A resumed run starts at 40% with 1.5 GB already on disk.
        clock.update(.downloading(DownloadProgress(index: 1, total: 2, title: "x", videoFraction: 0.4,
                                                   overallFraction: 0.4, bytesDownloaded: 1_500_000_000)), now: t0)
        clock.update(.throttled(resumeAt: t0.addingTimeInterval(60)), now: t0.addingTimeInterval(1))
        XCTAssertEqual(clock.startedAt, t0, "a throttle pause doesn't restart the clock")
        XCTAssertEqual(clock.bytesPerSecond(1_510_000_000, now: t0.addingTimeInterval(10)), 1_000_000)
        XCTAssertEqual(clock.eta(fraction: 0.5, now: t0.addingTimeInterval(10)) ?? 0, 50, accuracy: 0.001) // 10% per 10 s, 50% left
    }
}
