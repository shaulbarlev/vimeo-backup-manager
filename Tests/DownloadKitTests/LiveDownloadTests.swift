import Contracts
import XCTest
@testable import DownloadKit

/// Real network, real yt-dlp. Runs only with VBACKUP_NET=1.
final class LiveDownloadTests: XCTestCase {
    func testPrepareAndDownloadPublicVideoAtP540() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VBACKUP_NET"] == "1", "set VBACKUP_NET=1")

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbackup-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let out = work.appendingPathComponent("library", isDirectory: true)
        let cookies = work.appendingPathComponent("cookies.txt")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Header only: an empty cookie jar. A zero-byte file is rejected by yt-dlp as "not Netscape format".
        try "# Netscape HTTP Cookie File\n".write(to: cookies, atomically: true, encoding: .utf8)

        let tools = try await ToolManager(appSupport: work.appendingPathComponent("appsupport")).prepare(log: PrintLog())

        let video = RemoteVideo(id: "33951933", title: "vbackup live test", folderID: nil, durationSeconds: 0,
                                width: 0, height: 0, privacy: "anybody", downloadAllowed: false,
                                modified: Date(), pageURL: URL(string: "https://vimeo.com/33951933")!,
                                playerURL: URL(string: "https://player.vimeo.com/video/33951933")!)
        let request = DownloadRequest(video: video, destinationDir: out, quality: .p540, cookies: cookies, tools: tools)
        let base = "vbackup live test [33951933]"

        // A stale info.json from an earlier copy must not decide the tag (upgrade case).
        let info = out.appendingPathComponent(base + ".info.json")
        try #"{"format_id":"original-stale","width":1,"height":1}"#.write(to: info, atomically: true, encoding: .utf8)

        let file = try await YtDlpDownloader().download(request, log: PrintLog(), onEvent: { _ in })

        let name = file.lastPathComponent
        XCTAssertTrue(name.range(of: #"^vbackup live test \[33951933\] \[\d+p\]\.mp4$"#, options: .regularExpression) != nil, name)
        let short = Int(name.components(separatedBy: "[").last?.prefix { $0.isNumber } ?? "") ?? 0
        XCTAssertTrue((1...540).contains(short), "short side \(short)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(base + ".info.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(base + ".jpg").path))

        // Metadata refresh must actually rewrite info.json: backdate it, refresh, expect a new mtime.
        let old = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: info.path)
        try await YtDlpDownloader().refreshMetadata(request, existingFile: file, log: PrintLog())
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: info.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(mtime, old)
    }
}
