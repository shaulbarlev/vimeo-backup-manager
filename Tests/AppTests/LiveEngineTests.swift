import Contracts
import DownloadKit
import LibraryKit
import XCTest

/// Real Vimeo, real files. Runs only with VBACKUP_COOKIES=<cookies.txt>; downloads into a temp folder.
final class LiveEngineTests: XCTestCase {
    func testListAndDownloadSmallestVideos() async throws {
        guard let path = ProcessInfo.processInfo.environment["VBACKUP_COOKIES"] else { throw XCTSkip("set VBACKUP_COOKIES") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vbackup-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { print("live root: \(root.path)") }
        let tools = try await ToolManager().prepare(log: PrintLog())
        let config = BackupConfig(root: root, cookies: URL(fileURLWithPath: path), tools: tools)
        let engine = SyncEngine(downloader: VimeoDownloader())

        let before = try await engine.refresh(config, log: PrintLog(), onPhase: { _ in })
        let withSource = before.videos.filter { $0.video.source != nil }
        print("first video renditions: \(before.videos.prefix(3).map { ($0.id, $0.video.renditions.map(\.name), $0.video.created) })")
        print("problems: \(before.problems.prefix(3))")
        guard withSource.count >= 2 else { return XCTFail("only \(withSource.count) videos list a source") }
        print("listed \(before.total) videos, \(withSource.count) with a source file, missing \(Format.bytes(before.missing.bytes))")
        XCTAssertGreaterThan(withSource.count, before.total / 2, "most videos list their files")

        let bySource = withSource.sorted { $0.video.source!.size < $1.video.source!.size }
        let orig = bySource[0], small = bySource[1]
        let onlyMe = before.videos.filter { $0.video.privacy == "nobody" && $0.video.source != nil }
            .min { $0.video.source!.size < $1.video.source!.size }

        _ = try await engine.download(config, videoIDs: [orig.id], quality: .original, log: PrintLog(), onPhase: { _ in })
        var ids = [small.id]
        if let onlyMe { ids.append(onlyMe.id) }
        let after = try await engine.download(config, videoIDs: ids, quality: .p360, log: PrintLog(), onPhase: { _ in })

        let state = Dictionary(uniqueKeysWithValues: after.videos.map { ($0.id, $0) })
        XCTAssertEqual(state[orig.id]?.category, .original)
        XCTAssertEqual(state[orig.id]?.local?.videoBytes, orig.video.source?.size, "byte-exact original")
        XCTAssertNotNil(state[small.id]?.local)
        XCTAssertEqual(state[small.id]?.local?.tag?.hasSuffix("p"), true)
        if let onlyMe { XCTAssertNotNil(state[onlyMe.id]?.local, "only-me video downloaded") }
        XCTAssertTrue(after.failures.isEmpty, "\(after.failures)")
        let status = try String(contentsOf: root.appendingPathComponent(".vbackup/status.txt"), encoding: .utf8)
        print(status.split(separator: "\n").prefix(20).joined(separator: "\n"))
        let listing = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".vbackup") }
        print(listing.sorted().joined(separator: "\n"))
    }
}

private enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
