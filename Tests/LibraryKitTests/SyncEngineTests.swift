import XCTest
import Contracts
@testable import LibraryKit

/// Writes a dummy copy of a real tiny video plus an info.json, and fails the ids in `failing`.
final class FakeDownloader: VideoDownloading, @unchecked Sendable {
    let source: URL
    let failing: Set<String>
    var cancelling: Set<String> = []     // throws CancellationError, like a user pressing Stop mid-video
    var expireOnce: Set<String> = []     // throws linkExpired the first time
    private var expired: Set<String> = []
    private let lock = NSLock()
    private var stored: [String] = []
    private var refreshedIDs: [String] = []

    init(source: URL, failing: Set<String>) {
        self.source = source
        self.failing = failing
    }

    /// Video ids asked for, in order.
    var attempts: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    private func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(id)
    }

    func download(_ request: DownloadRequest, log: LogSink,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        let id = request.video.id
        record(id)
        if failing.contains(id) { throw VBackupError.tool("ERROR: HTTP Error 403: Forbidden") }
        if cancelling.contains(id) { throw CancellationError() }
        let expire = lock.withLock { expireOnce.contains(id) && expired.insert(id).inserted }
        if expire { throw VBackupError.linkExpired }
        onEvent(.progress(videoID: id, fraction: 0.5, downloadedBytes: 1000))
        try FileManager.default.createDirectory(at: request.destinationDir, withIntermediateDirectories: true)
        let video = request.destinationDir.appendingPathComponent(
            Naming.fileStem(title: request.video.title, id: id, qualityTag: "orig") + ".mp4")
        try FileManager.default.copyItem(at: source, to: video)
        try Data(#"{"format_id": "Original"}"#.utf8)
            .write(to: request.destinationDir.appendingPathComponent(Naming.base(title: request.video.title, id: id) + ".info.json"))
        return video
    }

    /// Video ids whose sidecars were refreshed, in order.
    var refreshed: [String] {
        lock.lock(); defer { lock.unlock() }
        return refreshedIDs
    }

    private func noteRefresh(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        refreshedIDs.append(id)
    }

    func refreshMetadata(_ request: DownloadRequest, existingFile: URL, log: LogSink) async throws {
        noteRefresh(request.video.id)
    }
}

/// Records phases from the engine's @Sendable callback.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncPhase] = []

    var phases: [SyncPhase] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func record(_ phase: SyncPhase) {
        lock.lock(); defer { lock.unlock() }
        stored.append(phase)
    }
}

final class SyncEngineTests: XCTestCase {
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

    private var tinySize: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: tiny.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private var allIDs: [String] { library().videos.map(\.id) }

    private var config: BackupConfig {
        BackupConfig(root: root, cookies: scratch.appendingPathComponent("cookies.txt"),
                     tools: Tools(ytdlp: scratch, ffmpeg: scratch, ffprobe: ffprobe))
    }

    /// The listed source is the tiny file's size, so a copy of it counts as the original.
    private func video(_ id: String, _ title: String, folder: String?, sourceSize: Int64? = nil) -> RemoteVideo {
        RemoteVideo(id: id, title: title, folderID: folder, durationSeconds: 10, width: 1920, height: 1080,
                    privacy: "anybody", downloadAllowed: true, modified: Date(timeIntervalSince1970: 946_684_800),
                    renditions: [Rendition(name: "source", width: 1920, height: 1080, size: sourceSize ?? tinySize)],
                    pageURL: URL(string: "https://vimeo.com/\(id)")!, playerURL: URL(string: "https://player.vimeo.com/video/\(id)")!)
    }

    /// A local original copy with its info.json (and a jpg sidecar when asked).
    private func placeOriginal(_ title: String, _ id: String, in dir: String, jpg: Bool = false) throws {
        let folder = root.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Naming.base(title: title, id: id)
        try FileManager.default.copyItem(at: tiny, to: folder.appendingPathComponent(base + " [orig].mp4"))
        try Data(#"{"format_id": "Original"}"#.utf8).write(to: folder.appendingPathComponent(base + ".info.json"))
        if jpg { try Data("jpg".utf8).write(to: folder.appendingPathComponent(base + ".jpg")) }
    }

    private func library() -> RemoteLibrary {
        RemoteLibrary(
            accountName: "Fixture Account",
            folders: [
                RemoteFolder(id: "1", name: "animation", parentID: nil),
                RemoteFolder(id: "2", name: "sub", parentID: "1"),
                RemoteFolder(id: "3", name: "commercials", parentID: nil),
            ],
            videos: [
                video("100000001", "Relocated clip", folder: "3"),   // on disk under animation/, belongs in commercials/
                video("100000002", "Missing clip", folder: "1"),     // not on disk: download
                video("100000003", "Broken clip", folder: nil),      // not on disk, download fails: recorded
                video("100000004", "Done clip", folder: "2"),        // already in the right place
            ],
            fetchedAt: Date())
    }

    private func seedDisk() throws {
        try placeOriginal("Relocated clip", "100000001", in: "animation", jpg: true)
        try placeOriginal("Done clip", "100000004", in: "animation/sub")
        try placeOriginal("Gone clip", "999999999", in: "_Unsorted")   // no longer on Vimeo
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func testSyncRelocatesDownloadsMissingRecordsFailureAndWritesStatus() async throws {
        try seedDisk()
        let downloader = FakeDownloader(source: tiny, failing: ["100000003"])
        let remote = library()
        let engine = SyncEngine(downloader: downloader, fetch: { _, _ in remote })
        let log = CollectingLog()
        let phases = PhaseRecorder()

        let summary = try await engine.download(config, videoIDs: allIDs, quality: .original, log: log, onPhase: { phases.record($0) })

        // Relocate: the video and its sidecar move together; the old location is empty.
        XCTAssertTrue(exists("commercials/Relocated clip [100000001] [orig].mp4"))
        XCTAssertTrue(exists("commercials/Relocated clip [100000001].info.json"))
        XCTAssertTrue(exists("commercials/Relocated clip [100000001].jpg"))
        XCTAssertFalse(exists("animation/Relocated clip [100000001] [orig].mp4"))

        // Download missing, in listing order. The failing one is attempted once and recorded.
        XCTAssertEqual(downloader.attempts, ["100000002", "100000003"])
        XCTAssertTrue(exists("animation/Missing clip [100000002] [orig].mp4"))
        XCTAssertEqual(FailureStore(root: root).load().keys.sorted(), ["100000003"])
        XCTAssertTrue(FailureStore(root: root).load()["100000003"]?.contains("403") == true)

        // Summary: three originals, one unreachable with its reason, one local-only file that was not deleted.
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.stats[.original]?.count, 3)
        XCTAssertEqual(summary.stats[.unreachable]?.count, 1)
        XCTAssertEqual(summary.failures.map(\.videoID), ["100000003"])
        XCTAssertEqual(summary.localOnly.map(\.videoID), ["999999999"])
        XCTAssertTrue(exists("_Unsorted/Gone clip [999999999] [orig].mp4"), "local-only files are never deleted")
        XCTAssertEqual(summary.vimeoCheckedAt, remote.fetchedAt)

        // status.txt is written at the end.
        let status = try String(contentsOf: root.appendingPathComponent(".vbackup/status.txt"), encoding: .utf8)
        XCTAssertTrue(status.contains("Failures (1)"))
        XCTAssertTrue(status.contains("Broken clip"))
        XCTAssertTrue(status.contains("Gone"), "local-only file listed")

        // Phases and log cover the whole run.
        XCTAssertTrue(phases.phases.contains(.listingVimeo(videos: 0, total: nil)))
        XCTAssertTrue(phases.phases.contains(.writingStatus))
        XCTAssertTrue(phases.phases.contains { if case .relocating = $0 { return true } else { return false } })
        XCTAssertTrue(phases.phases.contains { if case .downloading = $0 { return true } else { return false } })
        XCTAssertTrue(log.lines.contains { $0.contains("relocated Relocated clip") })
        XCTAssertTrue(log.lines.contains { $0.contains("download failed: 100000003") })
    }

    func testRelocationNeverOverwritesAnExistingFile() async throws {
        try seedDisk()
        // A file with the same name already sits in commercials/: the move is skipped, both stay.
        let blocker = root.appendingPathComponent("commercials/Relocated clip [100000001] [orig].mp4")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: blocker)

        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: []), fetch: { _, _ in self.library() })
        let summary = try await engine.download(config, videoIDs: allIDs, quality: .original, log: CollectingLog(), onPhase: { _ in })

        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "keep me")
        XCTAssertTrue(exists("animation/Relocated clip [100000001] [orig].mp4"))
        XCTAssertTrue(summary.problems.contains { $0.hasPrefix("relocation skipped for 100000001") })
    }

    func testSyncWithoutRootThrowsAndCreatesNothing() async throws {
        let missing = scratch.appendingPathComponent("unmounted", isDirectory: true)
        var cfg = config
        cfg.root = missing
        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: []), fetch: { _, _ in self.library() })
        do {
            _ = try await engine.download(cfg, videoIDs: allIDs, quality: .original, log: CollectingLog(), onPhase: { _ in })
            XCTFail("expected rootUnavailable")
        } catch {
            XCTAssertEqual(error as? VBackupError, .rootUnavailable(missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testLoggedOutAbortsSync() async throws {
        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: []),
                                fetch: { _, _ in throw VBackupError.loggedOut })
        do {
            _ = try await engine.download(config, videoIDs: allIDs, quality: .original, log: CollectingLog(), onPhase: { _ in })
            XCTFail("expected loggedOut")
        } catch {
            XCTAssertEqual(error as? VBackupError, .loggedOut)
        }
    }

    func testUpgradeRedownloadsLowerCopyAndSetsOldAside() async throws {
        let folder = root.appendingPathComponent("_Unsorted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Not original, and downloads are allowed at quality .original, so it is lower.
        try FileManager.default.copyItem(at: tiny, to: folder.appendingPathComponent("Lower clip [100000005] [720p].mp4"))
        let remote = RemoteLibrary(accountName: "Fixture Account", folders: [],
                                   videos: [video("100000005", "Lower clip", folder: nil, sourceSize: tinySize + 1)], fetchedAt: Date())
        let downloader = FakeDownloader(source: tiny, failing: [])
        let engine = SyncEngine(downloader: downloader, fetch: { _, _ in remote })

        _ = try await engine.download(config, videoIDs: ["100000005"], quality: .original, log: CollectingLog(), onPhase: { _ in })

        XCTAssertEqual(downloader.attempts, ["100000005"])
        XCTAssertTrue(exists("_Unsorted/Lower clip [100000005] [orig].mp4"))
        XCTAssertFalse(exists("_Unsorted/Lower clip [100000005] [720p].mp4"))
        XCTAssertTrue(exists(".vbackup/replaced/Lower clip [100000005] [720p].mp4"), "the replaced copy is kept")
    }

    func testStaleSidecarIsRefreshedWithoutRedownload() async throws {
        try seedDisk()
        var newer = video("100000004", "Done clip", folder: "2")
        newer.modified = Date().addingTimeInterval(3600)   // Vimeo changed after the info.json was written
        let remote = RemoteLibrary(accountName: "Fixture Account", folders: library().folders, videos: [newer], fetchedAt: Date())
        let downloader = FakeDownloader(source: tiny, failing: [])
        let engine = SyncEngine(downloader: downloader, fetch: { _, _ in remote })

        _ = try await engine.download(config, videoIDs: ["100000004"], quality: .original, log: CollectingLog(), onPhase: { _ in })

        XCTAssertEqual(downloader.refreshed, ["100000004"])
        XCTAssertEqual(downloader.attempts, [])
    }

    func testRefreshWithFailedListingClassifiesDiskOnly() async throws {
        try seedDisk()
        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: []),
                                fetch: { _, _ in throw VBackupError.vimeo("HTTP 500") })
        let summary = try await engine.refresh(config, log: CollectingLog(), onPhase: { _ in })

        XCTAssertNil(summary.vimeoCheckedAt, "a failed listing shows as never checked")
        XCTAssertNotNil(summary.diskScannedAt)
        XCTAssertEqual(summary.total, 3, "every local video counts as backed up")
        XCTAssertTrue(summary.problems.contains { $0.hasPrefix("Vimeo listing failed") })
        XCTAssertFalse(exists(".vbackup/status.txt"), "refresh does not write status.txt")
    }

    func testOnlyRequestedVideosAreDownloaded() async throws {
        let downloader = FakeDownloader(source: tiny, failing: [])
        let engine = SyncEngine(downloader: downloader, fetch: { _, _ in self.library() })
        _ = try await engine.download(config, videoIDs: ["100000004", "100000002"], quality: .p720,
                                      log: CollectingLog(), onPhase: { _ in })
        XCTAssertEqual(downloader.attempts, ["100000002", "100000004"], "listing order, only the requested ones")
    }

    func testStopKeepsFinishedFilesAndWritesStatus() async throws {
        let downloader = FakeDownloader(source: tiny, failing: [])
        downloader.cancelling = ["100000003"]
        let engine = SyncEngine(downloader: downloader, fetch: { _, _ in self.library() })

        let summary = try await engine.download(config, videoIDs: allIDs, quality: .original,
                                                log: CollectingLog(), onPhase: { _ in })

        XCTAssertEqual(downloader.attempts, ["100000001", "100000002", "100000003"], "nothing after the stop")
        XCTAssertEqual(summary.stats[.original]?.count, 2, "what finished before the stop is counted")
        XCTAssertTrue(exists(".vbackup/status.txt"), "status is saved on stop")
        XCTAssertTrue(FailureStore(root: root).load().isEmpty, "a stop is not a failure")
    }

    func testExpiredLinkIsRefetchedOnce() async throws {
        let downloader = FakeDownloader(source: tiny, failing: [])
        downloader.expireOnce = ["100000002"]
        let remote = library()
        let refetched = Counter()
        let engine = SyncEngine(downloader: downloader, fetch: { _, _ in remote }, refetch: { _, id, _ in
            refetched.add()
            return remote.videos.first { $0.id == id }!
        })
        _ = try await engine.download(config, videoIDs: ["100000002"], quality: .original, log: CollectingLog(), onPhase: { _ in })
        XCTAssertEqual(downloader.attempts, ["100000002", "100000002"])
        XCTAssertEqual(refetched.value, 1)
        XCTAssertTrue(exists("animation/Missing clip [100000002] [orig].mp4"))
    }

    func testFailedUpgradePutsTheOldCopyBack() async throws {
        let folder = root.appendingPathComponent("_Unsorted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("Lower clip [100000005] [720p].mp4")
        try FileManager.default.copyItem(at: tiny, to: old)
        let remote = RemoteLibrary(accountName: "a", folders: [],
                                   videos: [video("100000005", "Lower clip", folder: nil, sourceSize: tinySize + 1)], fetchedAt: Date())
        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: ["100000005"]), fetch: { _, _ in remote })

        let summary = try await engine.download(config, videoIDs: ["100000005"], quality: .original, log: CollectingLog(), onPhase: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the existing copy is restored")
        XCTAssertEqual(summary.videos.first?.category, .lower)
        XCTAssertFalse(exists(".vbackup/replaced/Lower clip [100000005] [720p].mp4"))
    }

    func testScannerIgnoresYtDlpStreamFiles() async throws {
        let folder = root.appendingPathComponent("_Unsorted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tiny, to: folder.appendingPathComponent("Clip [100000006].f137.mp4"))
        try FileManager.default.copyItem(at: tiny, to: folder.appendingPathComponent("Clip [100000007] [orig].mp4.vbackup-old"))
        let scan = try await DiskScanner(ffprobe: ffprobe).scan(root: root)
        XCTAssertTrue(scan.files.isEmpty, "\(scan.files.map(\.url.lastPathComponent))")
    }

    func testRefreshRestoresACopyParkedByACrashedRun() async throws {
        let folder = root.appendingPathComponent("_Unsorted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tiny, to: folder.appendingPathComponent("Clip [100000009] [720p].mp4.vbackup-old"))
        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: []), fetch: { _, _ in self.library() })
        _ = try await engine.refresh(config, log: CollectingLog(), onPhase: { _ in })
        XCTAssertTrue(exists("_Unsorted/Clip [100000009] [720p].mp4"))
        XCTAssertFalse(exists("_Unsorted/Clip [100000009] [720p].mp4.vbackup-old"))
    }

    func testCaseOnlyFolderRenameIsNotAClash() async throws {
        try placeOriginal("Done clip", "100000004", in: "Animation/Sub")   // Vimeo now says animation/sub
        let engine = SyncEngine(downloader: FakeDownloader(source: tiny, failing: []), fetch: { _, _ in self.library() })
        let summary = try await engine.download(config, videoIDs: ["100000004"], quality: .original,
                                                log: CollectingLog(), onPhase: { _ in })
        XCTAssertFalse(summary.problems.contains { $0.hasPrefix("relocation skipped") }, "\(summary.problems)")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
