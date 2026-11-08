import XCTest
@testable import VBackupApp

final class SendLogsTests: XCTestCase {
    func testBundleHasRecentLogsStatusAndInfoButNoCookies() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent(".vbackup/logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<12 { try "run \(i)".write(to: logs.appendingPathComponent(String(format: "2026-11-%02d_1200.log", i + 1)), atomically: true, encoding: .utf8) }
        try "status".write(to: root.appendingPathComponent(".vbackup/status.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent(".vbackup/cookies.txt"), atomically: true, encoding: .utf8)

        let zip = try SendLogs.bundle(root: root, problems: ["HTTP 504"])
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z1", zip.path]
        let out = Pipe()
        list.standardOutput = out
        try list.run()
        list.waitUntilExit()
        let names = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)

        XCTAssertEqual(names.filter { $0.hasSuffix(".log") }.count, 10, "the 10 most recent logs")
        XCTAssertTrue(names.contains { $0.hasSuffix("2026-11-12_1200.log") })
        XCTAssertFalse(names.contains { $0.hasSuffix("2026-11-01_1200.log") })
        XCTAssertTrue(names.contains { $0.hasSuffix("status.txt") })
        XCTAssertTrue(names.contains { $0.hasSuffix("info.txt") })
        XCTAssertFalse(names.contains { $0.contains("cookies") })
    }
}
