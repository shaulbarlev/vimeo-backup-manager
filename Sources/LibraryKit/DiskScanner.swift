import Foundation
import Contracts

/// Walks the backup folder and builds one LocalFile per Vimeo video id.
/// Resolution comes from AVFoundation (ffprobe as fallback), cached in `.vbackup/probe-cache.tsv` per file (re-probed when size or mtime changes).
public struct DiskScanner: Sendable {
    public struct Result: Sendable {
        public var files: [LocalFile]
        public var problems: [String]
    }

    public let ffprobe: URL

    public init(ffprobe: URL) { self.ffprobe = ffprobe }

    /// `progress` reports (done, total) over the video files found.
    public func scan(root: URL, progress: (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        guard FileManager.default.fileExists(atPath: root.path) else { throw VBackupError.rootUnavailable(root.path) }
        let rootPrefix = root.standardizedFileURL.path + "/"

        // Regular files only. Hidden names (which covers .vbackup) and .part downloads are skipped.
        var all: [URL] = []
        if let walker = FileManager.default.enumerator(at: root,
                                                       includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                       options: [.skipsHiddenFiles]) {
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension != "part", !Self.isIntermediate(url.lastPathComponent) else { continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { all.append(url) }
            }
        }
        let videos = all.filter(Self.isVideo).sorted { $0.path < $1.path }
        // Sidecar bytes per "<dir>/<base>", computed once (a per-video directory scan is O(n²) in big folders).
        var sidecarBytes: [String: Int64] = [:]
        for url in all where !Self.isVideo(url) {
            guard let id = Naming.videoID(fromFilename: url.lastPathComponent) else { continue }
            let key = url.deletingLastPathComponent().path + "/" + Self.base(of: url, id: id)
            sidecarBytes[key, default: 0] += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        let cacheURL = root.appendingPathComponent(Naming.hiddenDir).appendingPathComponent("probe-cache.tsv")
        let cache = Self.readCache(cacheURL)
        var nextCache: [String: CacheRow] = [:]
        var problems: [String] = []
        var byID: [String: [LocalFile]] = [:]

        progress(0, videos.count)
        for (index, url) in videos.enumerated() {
            try Task.checkCancellation()
            defer { progress(index + 1, videos.count) }
            guard let id = Naming.videoID(fromFilename: url.lastPathComponent) else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(rootPrefix.count))
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue } // gone mid-scan
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
            let mtime = Int(modified.timeIntervalSince1970)

            let base = Self.base(of: url, id: id)
            let row: CacheRow
            if let hit = cache[rel], hit.size == size, hit.mtime == mtime {
                row = hit
                nextCache[rel] = hit
            } else if let dims = await probe(url) {
                row = CacheRow(rel: rel, size: size, mtime: mtime, width: dims.0, height: dims.1)
                nextCache[rel] = row
            } else {
                // Not cached, so the next scan retries. The file still counts as backed up, at 0 px.
                problems.append("could not read resolution of \(rel)")
                row = CacheRow(rel: rel, size: size, mtime: mtime, width: 0, height: 0)
            }

            let sidecars = sidecarBytes[url.deletingLastPathComponent().path + "/" + base] ?? 0
            byID[id, default: []].append(LocalFile(videoID: id, url: url, sizeBytes: size + sidecars,
                                                   videoBytes: size, width: row.width, height: row.height,
                                                   modified: modified))
        }

        // The cache is an optimisation: a failed write only costs re-probing next time.
        try? Self.writeCache(Array(nextCache.values), to: cacheURL)

        var files: [LocalFile] = []
        for (id, group) in byID {
            // Keep the largest short side; the others are reported, not counted.
            let best = group.max { ($0.shortSide, $0.videoBytes) < ($1.shortSide, $1.videoBytes) }!
            if group.count > 1 {
                let ignored = group.filter { $0.url != best.url }.map { $0.url.lastPathComponent }.sorted()
                problems.append("duplicate files for video \(id): kept \(best.url.lastPathComponent), ignored \(ignored.joined(separator: ", "))")
            }
            files.append(best)
        }
        return Result(files: files.sorted { $0.videoID < $1.videoID }, problems: problems)
    }

    // MARK: - Helpers

    /// yt-dlp's per-stream and temp files ("x [id].f137.mp4", "x [id].temp.mp4"): an unfinished download, not a backup.
    static func isIntermediate(_ name: String) -> Bool {
        name.range(of: #"\.(f\d+|temp)\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil
            || name.hasSuffix(".ytdl") || name.contains(".vbackup-old")
    }

    static func isVideo(_ url: URL) -> Bool {
        Naming.videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// "Title [ID] [orig].mp4" -> "Title [ID]". Sidecars are named from this base.
    static func base(of video: URL, id: String) -> String {
        let stem = video.deletingPathExtension().lastPathComponent
        guard let r = stem.range(of: "[\(id)]", options: .backwards) else { return stem }
        return String(stem[..<r.upperBound])
    }

    private func probe(_ url: URL) async -> (Int, Int)? {
        await MediaProbe.size(of: url, ffprobe: ffprobe)
    }

    // MARK: - Probe cache (.vbackup/probe-cache.tsv: rel path, size, mtime, width, height)

    struct CacheRow: Equatable {
        var rel: String
        var size: Int64
        var mtime: Int
        var width: Int
        var height: Int
    }

    static func readCache(_ url: URL) -> [String: CacheRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var rows: [String: CacheRow] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 5, let size = Int64(f[1]), let mtime = Int(f[2]), let w = Int(f[3]), let h = Int(f[4]) else { continue }
            let rel = String(f[0])
            rows[rel] = CacheRow(rel: rel, size: size, mtime: mtime, width: w, height: h)
        }
        return rows
    }

    static func writeCache(_ rows: [CacheRow], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = rows.sorted { $0.rel < $1.rel }.map {
            "\($0.rel)\t\($0.size)\t\($0.mtime)\t\($0.width)\t\($0.height)"
        }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}
