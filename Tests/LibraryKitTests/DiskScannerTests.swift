import XCTest
import Contracts
@testable import LibraryKit

final class DiskScannerTests: XCTestCase {
    private var scratch: URL!
    private var root: URL!
    private var tiny: URL!
    private let ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")

    override func setUp() async throws {
        scratch = try makeTempDir()
        root = scratch.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tiny = scratch.appendingPathComponent("tiny.mp4")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ffprobe.path), "ffprobe not installed")
        try makeTinyVideo(at: tiny)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func size(_ url: URL) throws -> Int64 {
        Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
    }

    func testScanBuildsFilesWithSidecarsProbesAndCache() async throws {
        let folder = root.appendingPathComponent("commercials", isDirectory: true)
        let nike = folder.appendingPathComponent("Nike spot [1000000002] [orig].mp4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tiny, to: nike)
        try write(#"{"format_id": "Original"}"#, to: folder.appendingPathComponent("Nike spot [1000000002].info.json"))
        try write("jpg-bytes", to: folder.appendingPathComponent("Nike spot [1000000002].jpg"))
        try write("WEBVTT", to: folder.appendingPathComponent("Nike spot [1000000002].en.vtt"))

        // A transcoded copy without info.json is not original.
        let other = root.appendingPathComponent("_Unsorted/Other [111111111] [1080p].mp4")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tiny, to: other)

        // Ignored: a partial download, a hidden video, and anything under .vbackup.
        try write("partial", to: folder.appendingPathComponent("Nike spot [1000000002] [1080p].mp4.part"))
        try FileManager.default.copyItem(at: tiny, to: root.appendingPathComponent(".hidden [222222222].mp4"))
        try write("x", to: root.appendingPathComponent(".vbackup/logs/old.log"))

        let scanner = DiskScanner(ffprobe: ffprobe)
        var progress: [(Int, Int)] = []
        let result = try await scanner.scan(root: root) { progress.append(($0, $1)) }

        XCTAssertEqual(result.files.map(\.videoID), ["1000000002", "111111111"])
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(progress.last?.0, 2)
        XCTAssertEqual(progress.last?.1, 2)

        let nikeFile = try XCTUnwrap(result.files.first { $0.videoID == "1000000002" })
        XCTAssertEqual(nikeFile.url.lastPathComponent, "Nike spot [1000000002] [orig].mp4")
        XCTAssertEqual(nikeFile.width, 320)
        XCTAssertEqual(nikeFile.height, 240)
        XCTAssertEqual(nikeFile.tag, "orig")
        XCTAssertEqual(nikeFile.videoBytes, try size(tiny))
        let sidecars = try size(folder.appendingPathComponent("Nike spot [1000000002].info.json"))
            + size(folder.appendingPathComponent("Nike spot [1000000002].jpg"))
            + size(folder.appendingPathComponent("Nike spot [1000000002].en.vtt"))
        XCTAssertEqual(nikeFile.sizeBytes, try size(tiny) + sidecars)

        let otherFile = try XCTUnwrap(result.files.first { $0.videoID == "111111111" })
        XCTAssertEqual(otherFile.sizeBytes, try size(tiny), "no sidecars, so only the video counts")

        let cacheURL = root.appendingPathComponent(".vbackup/probe-cache.tsv")
        XCTAssertEqual(try String(contentsOf: cacheURL, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testCacheIsUsedUntilSizeOrMtimeChanges() async throws {
        let file = root.appendingPathComponent("Clip [333333333] [orig].mp4")
        try FileManager.default.copyItem(at: tiny, to: file)
        let scanner = DiskScanner(ffprobe: ffprobe)
        _ = try await scanner.scan(root: root)

        // Doctor the cached width. A scan with an unchanged file must return the cached value, not re-probe.
        let cacheURL = root.appendingPathComponent(".vbackup/probe-cache.tsv")
        let doctored = try String(contentsOf: cacheURL, encoding: .utf8).replacingOccurrences(of: "\t320\t240", with: "\t999\t240")
        try doctored.write(to: cacheURL, atomically: true, encoding: .utf8)
        let cached = try await scanner.scan(root: root)
        XCTAssertEqual(cached.files.first?.width, 999)

        // Change the mtime: the file is re-probed and the real width comes back.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        let reprobed = try await scanner.scan(root: root)
        XCTAssertEqual(reprobed.files.first?.width, 320)
    }

    func testDuplicateVideoKeepsOneAndReportsIt() async throws {
        let a = root.appendingPathComponent("Dup [444444444].mp4")
        let b = root.appendingPathComponent("Dup [444444444] [orig].mp4")
        try FileManager.default.copyItem(at: tiny, to: a)
        try FileManager.default.copyItem(at: tiny, to: b)

        let result = try await DiskScanner(ffprobe: ffprobe).scan(root: root)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(result.problems[0].hasPrefix("duplicate files for video 444444444"), result.problems[0])
    }

    func testMissingRootThrowsAndIsNotCreated() async throws {
        let missing = scratch.appendingPathComponent("unmounted-drive", isDirectory: true)
        do {
            _ = try await DiskScanner(ffprobe: ffprobe).scan(root: missing)
            XCTFail("expected rootUnavailable")
        } catch {
            XCTAssertEqual(error as? VBackupError, .rootUnavailable(missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
