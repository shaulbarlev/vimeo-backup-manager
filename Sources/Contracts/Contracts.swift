// Shared types between LibraryKit (A), DownloadKit (B) and VBackupApp (C).
// Owned by the integrator. Agents must NOT edit this file; request changes in their final report.
import Foundation

// MARK: - Quality

public enum Quality: String, Codable, CaseIterable, Sendable {
    case original, p1080, p720, p540, p360

    /// Max short side in pixels; nil = no cap (the source file).
    public var shortSideCap: Int? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        case .p540: 540
        case .p360: 360
        }
    }

    public var label: String {
        switch self {
        case .original: "Original"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p540: "540p"
        case .p360: "360p"
        }
    }

    /// The file this quality downloads: `source` for Original, else the largest rendition whose short side
    /// fits the cap, else the smallest. nil when Vimeo lists no files (yt-dlp fallback).
    public func pick(_ renditions: [Rendition]) -> Rendition? {
        let videos = renditions.filter { $0.name != "source" }
        switch shortSideCap {
        case nil:
            return renditions.first { $0.name == "source" } ?? videos.max { $0.shortSide < $1.shortSide }
        case let cap?:
            return videos.filter { $0.shortSide <= cap }.max { $0.shortSide < $1.shortSide }
                ?? videos.min { $0.shortSide < $1.shortSide }
                ?? renditions.first
        }
    }

    /// Download size of `video` at this quality. Exact only for the source file; renditions use Vimeo's
    /// listed size (measured 0.02-0.75% high); no files at all falls back to duration x a nominal bitrate.
    public func size(of video: RemoteVideo) -> SizeEstimate {
        if let r = pick(video.renditions) { return SizeEstimate(bytes: r.size, exact: r.sizeIsExact) }
        let mbps: Double = switch self {
        case .original: 20
        case .p1080: 8
        case .p720: 4
        case .p540: 2.5
        case .p360: 1
        }
        return SizeEstimate(bytes: Int64(Double(video.durationSeconds) * mbps * 125_000), exact: false)
    }
}

public struct SizeEstimate: Sendable, Hashable, Codable {
    public var bytes: Int64
    public var exact: Bool
    public init(bytes: Int64, exact: Bool) { self.bytes = bytes; self.exact = exact }
    public static func + (a: SizeEstimate, b: SizeEstimate) -> SizeEstimate {
        SizeEstimate(bytes: a.bytes + b.bytes, exact: a.exact && b.exact)
    }
}

/// One downloadable file Vimeo lists for a video (`download[]` in the API).
public struct Rendition: Sendable, Hashable, Codable {
    public var name: String        // "source", "2160p", "1080p", ... (the API's `rendition`)
    public var width: Int
    public var height: Int
    public var size: Int64         // exact for "source"; slightly high for transcodes
    public var md5: String?        // only Vimeo's source file has one
    public var link: URL?          // signed, expires (~24 h)
    public var sizeIsExact: Bool { name == "source" }
    public var shortSide: Int { min(width, height) }
    public init(name: String, width: Int, height: Int, size: Int64, md5: String? = nil, link: URL? = nil) {
        self.name = name; self.width = width; self.height = height; self.size = size; self.md5 = md5; self.link = link
    }
}

// MARK: - Remote (Vimeo) library

public struct RemoteFolder: Sendable, Hashable, Codable {
    public var id: String          // "500001" (last path component of /users/X/projects/500001)
    public var name: String
    public var parentID: String?   // nil = top level
    public init(id: String, name: String, parentID: String?) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

public struct RemoteVideo: Sendable, Hashable, Codable {
    public var id: String              // "1000000001"
    public var title: String
    public var folderID: String?       // nil = not in any folder -> "_Unsorted"
    public var durationSeconds: Int
    public var width: Int              // source resolution as reported by Vimeo
    public var height: Int
    public var privacy: String         // "anybody" | "unlisted" | "password" | "nobody" | "disable" | ...
    public var downloadAllowed: Bool   // privacy.download -> an original is offered
    public var modified: Date
    public var created: Date           // upload date (`created_time`); download date ranges filter on this
    public var renditions: [Rendition] // files Vimeo offers; empty -> yt-dlp fallback
    public var pageURL: URL            // https://vimeo.com/ID[/HASH] (the `link` field)
    public var playerURL: URL          // https://player.vimeo.com/video/ID?h=HASH (`player_embed_url`)
    public var password: String?       // only for privacy == "password"
    public var description: String?

    public var shortSide: Int { min(width, height) }
    public var source: Rendition? { renditions.first { $0.name == "source" } }

    public init(id: String, title: String, folderID: String?, durationSeconds: Int, width: Int, height: Int,
                privacy: String, downloadAllowed: Bool, modified: Date, created: Date? = nil,
                renditions: [Rendition] = [], pageURL: URL, playerURL: URL,
                password: String? = nil, description: String? = nil) {
        self.id = id; self.title = title; self.folderID = folderID; self.durationSeconds = durationSeconds
        self.width = width; self.height = height; self.privacy = privacy; self.downloadAllowed = downloadAllowed
        self.modified = modified; self.created = created ?? modified; self.renditions = renditions
        self.pageURL = pageURL; self.playerURL = playerURL
        self.password = password; self.description = description
    }
}

public struct RemoteLibrary: Sendable, Codable {
    public var accountName: String
    public var folders: [RemoteFolder]
    public var videos: [RemoteVideo]
    public var fetchedAt: Date
    public init(accountName: String, folders: [RemoteFolder], videos: [RemoteVideo], fetchedAt: Date) {
        self.accountName = accountName; self.folders = folders; self.videos = videos; self.fetchedAt = fetchedAt
    }
}

// MARK: - Local library

public struct LocalFile: Sendable, Hashable, Codable {
    public var videoID: String
    public var url: URL            // the video file (.mp4/.mkv/.mov)
    public var sizeBytes: Int64    // video file + its sidecars
    public var videoBytes: Int64   // the video file alone; compared with Vimeo's source size
    public var width: Int          // from ffprobe, never from the filename
    public var height: Int
    public var modified: Date
    public var shortSide: Int { min(width, height) }
    /// Quality tag from the filename ("orig", "1080p"). Says what was intended; the size says what is there.
    public var tag: String? { Naming.qualityTag(fromFilename: url.lastPathComponent) }
    public init(videoID: String, url: URL, sizeBytes: Int64, videoBytes: Int64? = nil, width: Int, height: Int, modified: Date) {
        self.videoID = videoID; self.url = url; self.sizeBytes = sizeBytes; self.videoBytes = videoBytes ?? sizeBytes
        self.width = width; self.height = height; self.modified = modified
    }
}

// MARK: - Overview

public enum Category: String, CaseIterable, Sendable, Codable {
    case original        // local file is byte-for-byte the size of Vimeo's source file
    case fullResolution  // not the source, but same resolution as the source
    case lower           // smaller resolution than the source
    case missing         // no local copy, or a copy whose size doesn't match (see mismatchedIDs)
    case unreachable     // last download attempt failed / refused

    public var label: String {
        switch self {
        case .original: "Original"
        case .fullResolution: "Full resolution"
        case .lower: "Lower resolution"
        case .missing: "Not backed up"
        case .unreachable: "Unreachable"
        }
    }
}

public struct CategoryStat: Sendable, Codable, Hashable {
    public var count: Int
    public var bytes: Int64
    public init(count: Int = 0, bytes: Int64 = 0) { self.count = count; self.bytes = bytes }
}

public struct FolderSummary: Sendable, Codable, Hashable {
    public var path: String                       // "commercials", "animation/sub", "_Unsorted"
    public var stats: [Category: CategoryStat]    // every Category key present
    public var total: Int { stats.values.reduce(0) { $0 + $1.count } }
    public var bytes: Int64 { stats.values.reduce(0) { $0 + $1.bytes } }
    public init(path: String, stats: [Category: CategoryStat]) { self.path = path; self.stats = stats }
}

public struct Failure: Sendable, Codable, Hashable {
    public var videoID: String
    public var title: String
    public var reason: String
    public init(videoID: String, title: String, reason: String) {
        self.videoID = videoID; self.title = title; self.reason = reason
    }
}

/// One Vimeo video with its local state, for the download sheet and lists.
public struct VideoState: Sendable, Hashable, Codable, Identifiable {
    public var video: RemoteVideo
    public var folderPath: String
    public var category: Category
    public var local: LocalFile?
    public var sizeMismatch: Bool   // local file tagged [orig] whose size differs from Vimeo's source
    public var id: String { video.id }
    public init(video: RemoteVideo, folderPath: String, category: Category, local: LocalFile?, sizeMismatch: Bool) {
        self.video = video; self.folderPath = folderPath; self.category = category
        self.local = local; self.sizeMismatch = sizeMismatch
    }
}

extension VideoState {
    /// False when the local copy is already at `quality` or better. The original is the best there is;
    /// a broken original (size mismatch) always needs a new download.
    public func needsDownload(_ quality: Quality) -> Bool {
        guard let local, !sizeMismatch else { return true }
        if category == .original { return false }
        // An original can only be fetched when Vimeo lists one; otherwise the best available is the target.
        if quality == .original, video.source != nil { return true }
        let target = quality.pick(video.renditions)?.shortSide ?? min(video.shortSide, quality.shortSideCap ?? .max)
        return Double(local.shortSide) < Double(target) * 0.98
    }
}

public struct LibrarySummary: Sendable, Codable {
    public var accountName: String
    public var total: Int
    public var stats: [Category: CategoryStat]    // every Category key present
    public var missing: SizeEstimate               // Original size of missing + unreachable videos
    public var videos: [VideoState]                // every Vimeo video, listing order (newest first)
    public var folders: [FolderSummary]            // sorted by path, "_Unsorted" last
    public var failures: [Failure]                 // the `.unreachable` videos with reasons
    public var localOnly: [LocalFile]              // files whose video id is no longer on Vimeo
    public var vimeoCheckedAt: Date?
    public var diskScannedAt: Date?
    public var problems: [String]                  // e.g. "Vimeo listing failed: ..." -> UI must show, not hide

    /// Complete = original + fullResolution.
    public var completeCount: Int { (stats[.original]?.count ?? 0) + (stats[.fullResolution]?.count ?? 0) }
    public var localBytes: Int64 { stats.values.reduce(0) { $0 + $1.bytes } + localOnly.reduce(0) { $0 + $1.sizeBytes } }

    public var mismatchedIDs: [String] { videos.filter(\.sizeMismatch).map(\.id) }

    public init(accountName: String, total: Int, stats: [Category: CategoryStat], missing: SizeEstimate,
                videos: [VideoState] = [], folders: [FolderSummary], failures: [Failure], localOnly: [LocalFile],
                vimeoCheckedAt: Date?, diskScannedAt: Date?, problems: [String]) {
        self.accountName = accountName; self.total = total; self.stats = stats
        self.missing = missing; self.videos = videos; self.folders = folders; self.failures = failures
        self.localOnly = localOnly; self.vimeoCheckedAt = vimeoCheckedAt; self.diskScannedAt = diskScannedAt
        self.problems = problems
    }
}

// MARK: - Tools

public struct Tools: Sendable, Hashable {
    public var ytdlp: URL
    public var ffmpeg: URL
    public var ffprobe: URL
    public init(ytdlp: URL, ffmpeg: URL, ffprobe: URL) { self.ytdlp = ytdlp; self.ffmpeg = ffmpeg; self.ffprobe = ffprobe }
}

// MARK: - Config

public struct BackupConfig: Sendable, Hashable {
    public var root: URL        // backup folder chosen by the user
    public var cookies: URL     // Netscape cookies.txt written by the app's sign-in
    public var tools: Tools
    public init(root: URL, cookies: URL, tools: Tools) {
        self.root = root; self.cookies = cookies; self.tools = tools
    }
}

/// What one download covers. Saved for "Repeat last download"; resolved against the current listing each time.
public struct DownloadScope: Sendable, Hashable, Codable {
    public var folderPaths: Set<String>?   // nil = every folder (including "_Unsorted")
    public var from: Date?                 // upload date, inclusive
    public var to: Date?                   // upload date, inclusive
    public var excludedIDs: Set<String>
    public init(folderPaths: Set<String>? = nil, from: Date? = nil, to: Date? = nil, excludedIDs: Set<String> = []) {
        self.folderPaths = folderPaths; self.from = from; self.to = to; self.excludedIDs = excludedIDs
    }

    /// Ignores excludedIDs, so the sheet can still list (unticked) excluded videos.
    public func inRange(_ v: VideoState) -> Bool {
        if let folderPaths, !folderPaths.contains(v.folderPath) { return false }
        if let from, v.video.created < from { return false }
        if let to, v.video.created > to { return false }
        return true
    }

    public func matches(_ v: VideoState) -> Bool { inRange(v) && !excludedIDs.contains(v.id) }
}

// MARK: - Errors

public enum VBackupError: Error, Sendable, Equatable, LocalizedError {
    case loggedOut                    // session cookie missing/expired -> app reopens sign-in
    case rootUnavailable(String)      // backup folder / drive not mounted -> refuse, never create
    case throttled(retryAfter: Int)   // seconds
    case tool(String)                 // yt-dlp / ffmpeg / ffprobe failure
    case vimeo(String)                // unexpected Vimeo response
    case linkExpired                  // signed download link no longer valid -> engine re-lists the video once
    case sizeMismatch(String)         // downloaded file failed the size / md5 check

    public var errorDescription: String? {
        switch self {
        case .loggedOut: "Signed out of Vimeo. Sign in again."
        case .rootUnavailable(let p): "Backup folder not available: \(p)"
        case .throttled(let s): "Throttled by Vimeo, resuming in \(s / 60)m"
        case .tool(let m): "Tool error: \(m)"
        case .vimeo(let m): "Vimeo error: \(m)"
        case .linkExpired: "Vimeo download link expired"
        case .sizeMismatch(let m): "Download check failed: \(m)"
        }
    }
}

// MARK: - Logging

public protocol LogSink: Sendable {
    func log(_ line: String)
}

public struct PrintLog: LogSink {
    public init() {}
    public func log(_ line: String) { print(line) }
}

// MARK: - Downloader (implemented by DownloadKit, used by LibraryKit)

public struct DownloadRequest: Sendable, Hashable {
    public var video: RemoteVideo
    public var destinationDir: URL   // absolute folder; created by the downloader if missing
    public var quality: Quality
    public var cookies: URL
    public var tools: Tools
    /// The file to fetch directly; nil means yt-dlp downloads the video (no Vimeo file listed).
    public var rendition: Rendition? { quality.pick(video.renditions) }
    public init(video: RemoteVideo, destinationDir: URL, quality: Quality, cookies: URL, tools: Tools) {
        self.video = video; self.destinationDir = destinationDir; self.quality = quality
        self.cookies = cookies; self.tools = tools
    }
}

public enum DownloadEvent: Sendable, Hashable {
    /// fraction 0...1 of the current stream; downloadedBytes of the current stream (resets when yt-dlp moves to the next stream).
    case progress(videoID: String, fraction: Double, downloadedBytes: Int64)
    case throttled(videoID: String, retryInSeconds: Int)
}

public protocol VideoDownloading: Sendable {
    /// Downloads video + sidecars (info.json, thumbnail, subs) into request.destinationDir
    /// using Naming.fileBase. Resumes .part files. Returns the final video file URL.
    /// Throws VBackupError (.loggedOut, .throttled after retries exhausted, .tool).
    func download(_ request: DownloadRequest, log: LogSink,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL

    /// Rewrites only the sidecars (no video download) next to an existing video file.
    func refreshMetadata(_ request: DownloadRequest, existingFile: URL, log: LogSink) async throws
}

public protocol ToolProviding: Sendable {
    /// Ensures yt-dlp/ffmpeg/ffprobe exist under Application Support and runs `yt-dlp -U` once per process.
    func prepare(log: LogSink) async throws -> Tools
}

// MARK: - Engine (implemented by LibraryKit, used by VBackupApp)

public struct DownloadProgress: Sendable, Hashable {
    public var index: Int              // 1-based
    public var total: Int
    public var title: String
    public var videoFraction: Double   // 0...1, current video
    public var overallFraction: Double // 0...1, whole run, weighted by video duration
    public var bytesDownloaded: Int64  // whole run so far
    public init(index: Int, total: Int, title: String, videoFraction: Double, overallFraction: Double, bytesDownloaded: Int64) {
        self.index = index; self.total = total; self.title = title; self.videoFraction = videoFraction
        self.overallFraction = overallFraction; self.bytesDownloaded = bytesDownloaded
    }
}

public enum SyncPhase: Sendable, Hashable {
    case listingVimeo(videos: Int, total: Int?)   // videos listed so far / library size once known
    case scanningDisk(done: Int, total: Int)
    case relocating(done: Int, total: Int)
    case downloading(DownloadProgress)
    case throttled(resumeAt: Date)
    case refreshingMetadata(done: Int, total: Int)
    case writingStatus
}

public protocol BackupEngine: Sendable {
    /// Vimeo listing + disk scan + classification. No downloads, no moves.
    func refresh(_ config: BackupConfig, log: LogSink,
                 onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary

    /// listing -> scan -> relocate moved files -> download `videoIDs` at `quality` (skipping videos already at that
    /// quality or better; replaced lower files go to .vbackup/replaced) -> refresh sidecars -> status.txt.
    /// Honors Task cancellation between and during downloads.
    func download(_ config: BackupConfig, videoIDs: [String], quality: Quality, log: LogSink,
                  onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary
}

// MARK: - Naming (shared on-disk contract; implemented here)

public enum Naming {
    public static let unsortedFolder = "_Unsorted"
    public static let hiddenDir = ".vbackup"
    public static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "webm", "m4v"]

    /// Filesystem-safe single path component. Replaces / : and control chars, trims dots/spaces, caps 150 UTF-8 bytes.
    public static func safe(_ s: String) -> String {
        var out = String(s.map { c -> Character in
            if c == "/" || c == ":" || c == "\\" || c.unicodeScalars.contains(where: { $0.value < 32 }) { return "_" }
            return c
        })
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        // APFS allows 255 bytes per name; 150 leaves room for " [id] [tag].mp4.part" or ".info.json".
        while out.utf8.count > 150 { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "untitled" : out
    }

    public static func qualityTag(isOriginal: Bool, shortSide: Int) -> String {
        isOriginal ? "orig" : "\(shortSide)p"
    }

    /// "x [123] [1080p].mp4" -> "1080p"; nil when there is no tag.
    public static func qualityTag(fromFilename name: String) -> String? {
        guard let r = name.range(of: #"\[[^\]]+\] \[([^\]]+)\]\.[A-Za-z0-9]+$"#, options: .regularExpression) else { return nil }
        let part = name[r]
        guard let open = part.lastIndex(of: "["), let close = part.lastIndex(of: "]") else { return nil }
        return String(part[part.index(after: open)..<close])
    }

    /// "Title [ID]" (no extension, no quality tag). Sidecars use this base: "Title [ID].info.json".
    public static func base(title: String, id: String) -> String { "\(safe(title)) [\(id)]" }

    /// Final video filename stem: "Title [ID] [orig]" / "Title [ID] [1080p]".
    public static func fileStem(title: String, id: String, qualityTag: String) -> String {
        "\(base(title: title, id: id)) [\(qualityTag)]"
    }

    /// Extracts the Vimeo id from any of our filenames: "x [123] [1080p].mp4", "x [123].info.json" -> "123".
    public static func videoID(fromFilename name: String) -> String? {
        guard let r = name.range(of: #"\[(\d{5,})\](?: \[[^\]]+\])?\.[A-Za-z0-9.]+$"#, options: .regularExpression) else { return nil }
        return name[r].split(separator: "]").first.map { String($0.dropFirst()) }
    }

    /// yt-dlp format_id of the original/source file ("Original", "source", "original-…").
    public static func isOriginalFormatID(_ formatID: String) -> Bool {
        let f = formatID.lowercased()
        return !f.hasPrefix("hls-") && !f.hasPrefix("dash-") && (f.contains("original") || f.contains("source"))
    }

    /// Relative folder path for a video: nested folder names joined by "/", or "_Unsorted".
    public static func folderPath(folderID: String?, folders: [String: RemoteFolder]) -> String {
        guard var id = folderID, folders[id] != nil else { return unsortedFolder }
        var parts: [String] = []
        var seen = Set<String>()
        while let f = folders[id], !seen.contains(id) {
            seen.insert(id); parts.insert(safe(f.name), at: 0)
            guard let p = f.parentID else { break }
            id = p
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - Media probe (shared by the disk scanner and the yt-dlp fallback)

import AVFoundation

public enum MediaProbe {
    /// Width x height of the first video track, display orientation. AVFoundation first (built into macOS),
    /// then ffprobe if one is installed (for containers AVFoundation can't open, e.g. webm/mkv).
    public static func size(of url: URL, ffprobe: URL?) async -> (Int, Int)? {
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: natural).applying(transform)
            let w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
            if w > 0, h > 0 { return (w, h) }
        }
        guard let ffprobe, FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return nil }
        let p = Process()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",").compactMap { Int($0) }
        return p.terminationStatus == 0 && parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}
