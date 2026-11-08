import XCTest
import Contracts
@testable import LibraryKit

final class StoresTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempDir().appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testFailureStoreRecordsSanitizesAndClears() throws {
        let store = FailureStore(root: root)
        XCTAssertEqual(store.load(), [:])
        try store.record(id: "100000001", reason: "HTTP Error 403\tForbidden\nretry later")
        try store.record(id: "100000002", reason: "Private")
        try store.record(id: "100000001", reason: "HTTP Error 429")   // a later failure replaces the earlier one
        XCTAssertEqual(store.load(), ["100000001": "HTTP Error 429", "100000002": "Private"])

        try store.clear(id: "100000001")
        try store.clear(id: "never-failed")
        XCTAssertEqual(store.load(), ["100000002": "Private"])
    }

    func testFailureStoreWithoutRootThrowsAndCreatesNothing() throws {
        let missing = root.deletingLastPathComponent().appendingPathComponent("unmounted", isDirectory: true)
        XCTAssertThrowsError(try FailureStore(root: missing).record(id: "1", reason: "x")) { error in
            XCTAssertEqual(error as? VBackupError, .rootUnavailable(missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testFileLogAppendsAndPrunesOldLogs() throws {
        let logs = root.appendingPathComponent(".vbackup/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let old = logs.appendingPathComponent("2026-09-01_1000.log")
        let recent = logs.appendingPathComponent("2026-11-03_0900.log")
        try Data("old".utf8).write(to: old)
        try Data("recent".utf8).write(to: recent)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 24 * 3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: recent.path)

        let log = try FileLog(root: root, run: now)
        log.log("first line")
        let second = try FileLog(root: root, run: now)   // same minute: appends, does not truncate
        second.log("second line")

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "logs older than 30 days are deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains("first line"))
        XCTAssertTrue(text.contains("second line"))
        XCTAssertEqual(log.url, second.url)
    }

    func testFileLogWithoutRootThrowsAndCreatesNothing() throws {
        let missing = root.deletingLastPathComponent().appendingPathComponent("unmounted", isDirectory: true)
        XCTAssertThrowsError(try FileLog(root: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testPercentMatchesSpecExample() {
        let counts = [3912, 801, 210, 398, 36]
        XCTAssertEqual(counts.map { StatusWriter.percent($0, 5357) }, ["73.0", "15.0", "3.9", "7.4", "0.7"])
        XCTAssertEqual(StatusWriter.percent(0, 0), "0.0")
    }

    func testStatusWriterWritesEveryCategoryAndProblem() throws {
        let summary = LibrarySummary(
            accountName: "Fixture Account", total: 5357,
            stats: [.original: CategoryStat(count: 3912, bytes: 2_000), .fullResolution: CategoryStat(count: 801, bytes: 300),
                    .lower: CategoryStat(count: 210, bytes: 100), .missing: CategoryStat(count: 398, bytes: 0),
                    .unreachable: CategoryStat(count: 36, bytes: 0)],
            missing: SizeEstimate(bytes: 190_000, exact: true), folders: [FolderSummary(path: "commercials", stats: Classifier.emptyStats())],
            failures: [Failure(videoID: "900000001", title: "password clip", reason: "Private video")],
            localOnly: [], vimeoCheckedAt: Date(timeIntervalSince1970: 0), diskScannedAt: nil,
            problems: ["Vimeo listing failed: HTTP 500"])

        try StatusWriter.write(summary, root: root, syncedAt: Date())
        let text = try String(contentsOf: root.appendingPathComponent(".vbackup/status.txt"), encoding: .utf8)
        for category in Category.allCases {
            XCTAssertTrue(text.contains(category.label), category.label)
        }
        XCTAssertTrue(text.contains("Complete:        4713 / 5357 (88.0%)"), text)
        XCTAssertTrue(text.contains("Failures (1)"))
        XCTAssertTrue(text.contains("900000001  password clip  - Private video"))
        XCTAssertTrue(text.contains("Problems (1)"))
        XCTAssertTrue(text.contains("Vimeo listing failed: HTTP 500"))
        XCTAssertTrue(text.contains("Account:         Fixture Account"))
    }
}
