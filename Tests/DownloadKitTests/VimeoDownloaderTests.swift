import Contracts
import XCTest
@testable import DownloadKit

/// Direct downloads with curl against file:// links: resume, size and md5 checks, naming, outcome mapping.
final class VimeoDownloaderTests: XCTestCase {
    private var dir: URL!
    private var sourceFile: URL!
    private let payload = Data((0..<200_000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sourceFile = dir.appendingPathComponent("remote.mp4")
        try payload.write(to: sourceFile)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func request(size: Int64, md5: String?) -> DownloadRequest {
        let video = RemoteVideo(id: "123456789", title: "Clip: one", folderID: nil, durationSeconds: 1, width: 1920, height: 1080,
                                privacy: "anybody", downloadAllowed: true, modified: .distantPast,
                                renditions: [Rendition(name: "source", width: 1920, height: 1080, size: size, md5: md5, link: sourceFile)],
                                pageURL: URL(string: "https://vimeo.com/123456789")!, playerURL: URL(string: "https://vimeo.com/123456789")!)
        let none = URL(fileURLWithPath: "/usr/bin/false") // sidecars fail, which must not fail the download
        return DownloadRequest(video: video, destinationDir: dir.appendingPathComponent("out"), quality: .original,
                               cookies: dir.appendingPathComponent("cookies.txt"), tools: Tools(ytdlp: none, ffmpeg: none, ffprobe: none))
    }

    private var md5: String { try! VimeoDownloader.md5(sourceFile) }

    func testResumesPartialFileAndVerifiesSizeAndMD5() async throws {
        let r = request(size: Int64(payload.count), md5: md5)
        try FileManager.default.createDirectory(at: r.destinationDir, withIntermediateDirectories: true)
        let part = r.destinationDir.appendingPathComponent("Clip_ one [123456789] [orig].mp4.part")
        try payload.prefix(70_000).write(to: part)

        let out = try await VimeoDownloader().download(r, log: PrintLog(), onEvent: { _ in })

        XCTAssertEqual(out.lastPathComponent, "Clip_ one [123456789] [orig].mp4")
        XCTAssertEqual(try Data(contentsOf: out), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testWrongListedSizeIsRejectedAndPartRemoved() async throws {
        let r = request(size: Int64(payload.count) + 1, md5: nil)
        do {
            _ = try await VimeoDownloader().download(r, log: PrintLog(), onEvent: { _ in })
            XCTFail("expected sizeMismatch")
        } catch let VBackupError.sizeMismatch(message) {
            XCTAssertTrue(message.contains("\(payload.count)"), message)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: r.destinationDir.path)
        XCTAssertEqual(leftovers, [], "a bad download leaves nothing that could pass as a backup")
    }

    func testWrongMD5IsRejected() async throws {
        let r = request(size: Int64(payload.count), md5: "00000000000000000000000000000000")
        do {
            _ = try await VimeoDownloader().download(r, log: PrintLog(), onEvent: { _ in })
            XCTFail("expected sizeMismatch")
        } catch VBackupError.sizeMismatch {}
    }

    func testCompleteFileIsNotDownloadedAgain() async throws {
        let r = request(size: Int64(payload.count), md5: md5)
        let first = try await VimeoDownloader().download(r, log: PrintLog(), onEvent: { _ in })
        try FileManager.default.removeItem(at: sourceFile) // a second fetch would now fail
        let second = try await VimeoDownloader().download(r, log: PrintLog(), onEvent: { _ in })
        XCTAssertEqual(first, second)
    }

    func testOutcome() {
        XCTAssertEqual(VimeoDownloader.outcome(exit: 0, http: 200), .done)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 0, http: 206), .done)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 22, http: 416), .done)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 22, http: 403), .expired)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 22, http: 410), .expired)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 22, http: 429), .throttled)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 18, http: 200), .retry)
        XCTAssertEqual(VimeoDownloader.outcome(exit: 22, http: 500), .failed)
    }

    func testRenditionFileNameUsesRealShortSide() {
        let v = request(size: 1, md5: nil).video
        let r720 = Rendition(name: "720p", width: 720, height: 1280, size: 1)
        XCTAssertEqual(VimeoDownloader.fileName(v, r720, link: URL(string: "https://x/y/file.mp4?s=1")!),
                       "Clip_ one [123456789] [720p].mp4")
    }
}
