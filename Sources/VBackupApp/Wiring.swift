import Contracts
import DownloadKit
import Foundation
import LibraryKit

/// Picks the engine and tools the app runs with. The integrator swaps in SyncEngine and ToolManager here.
enum Wiring {
    /// VBACKUP_MOCK=1 runs the UI against the mock engine.
    static let useMock = ProcessInfo.processInfo.environment["VBACKUP_MOCK"] == "1"
    static func engine() -> BackupEngine { useMock ? MockEngine() : SyncEngine(downloader: VimeoDownloader()) }
    static func tools() -> ToolProviding { useMock ? MockTools() : ToolManager() }
    /// One log file per run in <root>/.vbackup/logs; stdout if the folder can't be written.
    static func log(root: URL) -> LogSink { (try? FileLog(root: root)) ?? PrintLog() }
}

/// Stand-in for the real engine: sample numbers, steps through every phase.
struct MockEngine: BackupEngine {
    /// Folder rows: path, then counts in Category order (original, fullResolution, lower, missing, unreachable).
    private static let rows: [(path: String, counts: [Int])] = [
        ("commercials", [210, 5, 0, 5, 2]),
        ("animation", [105, 10, 5, 8, 2]),
        ("animation/sub", [30, 5, 5, 4, 1]),
        ("events", [60, 15, 5, 8, 2]),
        ("talks", [40, 10, 2, 8, 0]),
        ("clients", [35, 12, 3, 5, 0]),
        ("clients/2024", [30, 4, 2, 4, 0]),
        ("product", [25, 5, 4, 6, 0]),
        ("team", [20, 4, 2, 4, 0]),
        ("archive", [30, 10, 8, 10, 2]),
        ("archive 2026", [40, 6, 2, 2, 0]),
        ("drafts", [10, 5, 3, 7, 0]),
        ("360", [12, 4, 1, 3, 0]),
        ("music", [6, 2, 0, 2, 0]),
        ("_Unsorted", [3259, 704, 168, 322, 27]),
    ]

    /// Average local file size per category; sizes add up to the README's 2.41 TB.
    private static let bytesPerVideo: [Category: Int64] = [
        .original: 506_000_000, .fullResolution: 387_000_000, .lower: 571_000_000, .missing: 0, .unreachable: 0,
    ]

    private static let failureReasons = [
        "No video formats found (private video)", "Login required", "HTTP Error 403: Forbidden",
    ]

    static func summary(vimeoCheckedAt: Date?, problems: [String]) -> LibrarySummary {
        let folders = rows.map { FolderSummary(path: $0.path, stats: stats($0.counts)) }
        var total: [Category: CategoryStat] = [:]
        for folder in folders {
            for (cat, s) in folder.stats {
                total[cat, default: CategoryStat()].count += s.count
                total[cat, default: CategoryStat()].bytes += s.bytes
            }
        }
        let unreachable = total[.unreachable]?.count ?? 0
        let now = Date()
        return LibrarySummary(
            accountName: "Example Account",
            total: total.values.reduce(0) { $0 + $1.count },
            stats: total,
            missing: SizeEstimate(bytes: 190_000_000_000, exact: true),
            videos: mockVideos(),
            folders: folders,
            failures: (0..<unreachable).map { i in
                Failure(videoID: String(830_000_000 + i * 1_000), title: "Clip \(i + 1)",
                        reason: failureReasons[i % failureReasons.count])
            },
            localOnly: [
                LocalFile(videoID: "555123456", url: URL(fileURLWithPath: "/Volumes/Backup/animation/Old reel [555123456] [1080p].mp4"),
                          sizeBytes: 180_000_000, width: 1920, height: 1080, modified: now),
                LocalFile(videoID: "555123457", url: URL(fileURLWithPath: "/Volumes/Backup/_Unsorted/Draft cut [555123457] [orig].mp4"),
                          sizeBytes: 95_000_000, width: 1080, height: 1920, modified: now),
            ],
            vimeoCheckedAt: vimeoCheckedAt,
            diskScannedAt: now.addingTimeInterval(-180),
            problems: problems)
    }

    /// 40 sample videos across folders and dates, for the download sheet.
    static func mockVideos() -> [VideoState] {
        let folders = ["commercials", "animation", "events", "_Unsorted"]
        let cats: [Category] = [.original, .fullResolution, .lower, .missing, .missing, .unreachable]
        return (0..<40).map { i in
            let source = Int64(80_000_000 + i * 9_000_000)
            let video = RemoteVideo(
                id: String(1_240_000_000 + i), title: "Clip \(i + 1) – \(folders[i % 4]) shoot", folderID: nil,
                durationSeconds: 30 + i * 7, width: 1920, height: 1080, privacy: "anybody", downloadAllowed: true,
                modified: Date(), created: Date().addingTimeInterval(Double(-i) * 86_400 * 9),
                renditions: [
                    Rendition(name: "source", width: 1920, height: 1080, size: source, md5: "x"),
                    Rendition(name: "1080p", width: 1920, height: 1080, size: source / 6),
                    Rendition(name: "720p", width: 1280, height: 720, size: source / 11),
                    Rendition(name: "540p", width: 960, height: 540, size: source / 19),
                    Rendition(name: "360p", width: 640, height: 360, size: source / 34),
                ],
                pageURL: URL(string: "https://vimeo.com/1")!, playerURL: URL(string: "https://vimeo.com/1")!)
            let cat = cats[i % cats.count]
            let local = [.missing, .unreachable].contains(cat) ? nil : LocalFile(
                videoID: video.id, url: URL(fileURLWithPath: "/x [\(video.id)] [1080p].mp4"), sizeBytes: source,
                width: cat == .lower ? 1280 : 1920, height: cat == .lower ? 720 : 1080, modified: Date())
            return VideoState(video: video, folderPath: folders[i % 4], category: cat, local: local, sizeMismatch: false)
        }
    }

    /// Normal mock: one problem line, as the README numbers imply.
    static let duplicateProblem = "Two video files for 1000000002: kept the larger one"

    private static func stats(_ counts: [Int]) -> [Category: CategoryStat] {
        Dictionary(uniqueKeysWithValues: zip(Category.allCases, counts).map { cat, n in
            (cat, CategoryStat(count: n, bytes: Int64(n) * (bytesPerVideo[cat] ?? 0)))
        })
    }

    func refresh(_ config: BackupConfig, log: LogSink,
                 onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary {
        log.log("mock refresh")
        return Self.summary(vimeoCheckedAt: Date().addingTimeInterval(-180), problems: [Self.duplicateProblem])
    }

    func download(_ config: BackupConfig, videoIDs: [String], quality: Quality, log: LogSink,
                  onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary {
        log.log("mock download of \(videoIDs.count) at \(quality.label)")
        let steps: [SyncPhase] = [
            .listingVimeo(videos: 0, total: nil),
            .listingVimeo(videos: 2_400, total: 5_357),
            .scanningDisk(done: 2_000, total: 5_357),
            .scanningDisk(done: 5_357, total: 5_357),
            .relocating(done: 1, total: 1),
            .downloading(DownloadProgress(index: 1, total: 3, title: "Clip 1", videoFraction: 0.5, overallFraction: 0.167, bytesDownloaded: 40000000)),
            .downloading(DownloadProgress(index: 1, total: 3, title: "Clip 1", videoFraction: 1, overallFraction: 0.333, bytesDownloaded: 80000000)),
            .throttled(resumeAt: Date().addingTimeInterval(120)),
            .downloading(DownloadProgress(index: 2, total: 3, title: "Clip 2", videoFraction: 0.4, overallFraction: 0.467, bytesDownloaded: 112000000)),
            .refreshingMetadata(done: 1, total: 2),
            .writingStatus,
        ]
        for step in steps {
            try await Task.sleep(for: .milliseconds(450))
            onPhase(step)
        }
        return Self.summary(vimeoCheckedAt: Date(), problems: [Self.duplicateProblem])
    }
}

struct MockTools: ToolProviding {
    func prepare(log: LogSink) async throws -> Tools {
        log.log("mock tools: nothing to prepare")
        let none = URL(fileURLWithPath: "/mock/bin/none")
        return Tools(ytdlp: none, ffmpeg: none, ffprobe: none)
    }
}
