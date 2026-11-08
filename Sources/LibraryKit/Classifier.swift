import Foundation
import Contracts

// Foundation's ObjC runtime also exports a `Category`; pin ours.
typealias Category = Contracts.Category

/// Pure classification of the Vimeo listing against local files. No I/O.
public enum Classifier {
    /// A local short side must reach this fraction of the target to count as full resolution.
    static let resolutionTolerance = 0.98

    public static func classify(_ lib: RemoteLibrary, _ locals: [LocalFile], failures: [String: String],
                                diskScannedAt: Date? = nil, problems: [String] = []) -> LibrarySummary {
        let localByID = bestLocalByID(locals)
        let folders = Dictionary(lib.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var stats = emptyStats()
        var folderStats: [String: [Category: CategoryStat]] = [:]
        var failureList: [Failure] = []
        var missing = SizeEstimate(bytes: 0, exact: true)
        var states: [VideoState] = []
        var problems = problems

        for video in lib.videos {
            let local = localByID[video.id]
            let (cat, mismatch) = category(for: video, local: local, unreachable: failures[video.id] != nil)
            let bytes = local?.sizeBytes ?? 0
            let folder = Naming.folderPath(folderID: video.folderID, folders: folders)
            add(cat, bytes: bytes, to: &stats)
            add(cat, bytes: bytes, to: &folderStats[folder, default: emptyStats()])
            if cat == .missing || cat == .unreachable { missing = missing + Quality.original.size(of: video) }
            if cat == .unreachable {
                failureList.append(Failure(videoID: video.id, title: video.title, reason: failures[video.id] ?? ""))
            }
            if mismatch, let local {
                problems.append("\(local.url.lastPathComponent) is not the size Vimeo lists for the original: re-download it")
            }
            states.append(VideoState(video: video, folderPath: folder, category: cat, local: local, sizeMismatch: mismatch))
        }
        let remoteIDs = Set(lib.videos.map(\.id))

        return LibrarySummary(
            accountName: lib.accountName,
            total: lib.videos.count,
            stats: stats,
            missing: missing,
            videos: states,
            folders: folderStats.map { FolderSummary(path: $0.key, stats: $0.value) }.sorted(by: folderOrder),
            failures: failureList,
            localOnly: localByID.values.filter { !remoteIDs.contains($0.videoID) }.sorted { $0.url.path < $1.url.path },
            vimeoCheckedAt: lib.fetchedAt,
            diskScannedAt: diskScannedAt,
            problems: problems)
    }

    /// The Vimeo listing failed, so only the disk is known. Files tagged [orig] count as original, the rest as
    /// full resolution (nothing to compare against). Nothing is missing, unreachable or lower; no folder rows.
    public static func diskOnly(accountName: String, _ locals: [LocalFile], diskScannedAt: Date?,
                                problems: [String]) -> LibrarySummary {
        let best = bestLocalByID(locals).values
        var stats = emptyStats()
        for local in best {
            add(local.tag == "orig" ? .original : .fullResolution, bytes: local.sizeBytes, to: &stats)
        }
        return LibrarySummary(
            accountName: accountName, total: best.count, stats: stats, missing: SizeEstimate(bytes: 0, exact: true),
            folders: [], failures: [], localOnly: [], vimeoCheckedAt: nil,
            diskScannedAt: diskScannedAt, problems: problems)
    }

    /// Category of one Vimeo video from what is actually on disk:
    /// - same byte size as Vimeo's source file -> original
    /// - tagged [orig] but a different size -> a broken original: counts as missing, `mismatch` true
    /// - otherwise by resolution against the source: full resolution or lower
    static func category(for video: RemoteVideo, local: LocalFile?, unreachable: Bool) -> (Category, mismatch: Bool) {
        guard let local else { return (unreachable ? .unreachable : .missing, false) }
        if let source = video.source {
            if local.videoBytes == source.size { return (.original, false) }
            if local.tag == "orig" { return (unreachable ? .unreachable : .missing, true) }
        } else if local.tag == "orig" {
            return (.original, false) // no listed source to check against (yt-dlp fallback)
        }
        let reference = video.shortSide > 0 ? video.shortSide : (video.renditions.map(\.shortSide).max() ?? 0)
        return (Double(local.shortSide) >= Double(reference) * resolutionTolerance ? .fullResolution : .lower, false)
    }

    // MARK: - Helpers

    /// One local file per video id: the largest short side, then the larger file.
    static func bestLocalByID(_ locals: [LocalFile]) -> [String: LocalFile] {
        var best: [String: LocalFile] = [:]
        for local in locals {
            if let current = best[local.videoID],
               (current.shortSide, current.videoBytes) >= (local.shortSide, local.videoBytes) { continue }
            best[local.videoID] = local
        }
        return best
    }

    static func emptyStats() -> [Category: CategoryStat] {
        Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0, CategoryStat()) })
    }

    private static func add(_ category: Category, bytes: Int64, to stats: inout [Category: CategoryStat]) {
        var stat = stats[category, default: CategoryStat()]
        stat.count += 1
        stat.bytes += bytes
        stats[category] = stat
    }

    /// Alphabetical by path, with the unsorted bucket last.
    private static func folderOrder(_ a: FolderSummary, _ b: FolderSummary) -> Bool {
        if a.path == Naming.unsortedFolder { return false }
        if b.path == Naming.unsortedFolder { return true }
        return a.path < b.path
    }
}
