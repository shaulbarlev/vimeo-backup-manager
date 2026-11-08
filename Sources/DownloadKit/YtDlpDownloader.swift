import Contracts
import Foundation

/// Downloads one video with yt-dlp, then renames it to its real quality tag.
public struct YtDlpDownloader: VideoDownloading {
    public init() {}

    public func download(_ request: DownloadRequest, log: LogSink,
                         onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: request.destinationDir, withIntermediateDirectories: true)
        let info = request.destinationDir.appendingPathComponent(
            Naming.base(title: request.video.title, id: request.video.id) + ".info.json")
        // --no-overwrites keeps an existing info.json, which on an upgrade describes the old file.
        // Set the old one aside so yt-dlp writes a fresh one, and put it back if this download fails.
        let previous = try? Data(contentsOf: info)
        try? FileManager.default.removeItem(at: info)
        do {
            try await fetch(request, metadataOnly: false, log: log, onEvent: onEvent)
        } catch {
            if let previous { try? previous.write(to: info) }
            throw error
        }
        return try await finish(request, log: log)
    }

    public func refreshMetadata(_ request: DownloadRequest, existingFile: URL, log: LogSink) async throws {
        var r = request
        r.destinationDir = existingFile.deletingLastPathComponent()
        // Keep the existing file's name base: a title changed on Vimeo must not create a second set of sidecars.
        let stem = existingFile.deletingPathExtension().lastPathComponent
        if let range = stem.range(of: " [\(request.video.id)]", options: .backwards) {
            r.video.title = String(stem[..<range.lowerBound])
        }
        try await fetch(r, metadataOnly: true, log: log, onEvent: { _ in })
    }

    /// Runs yt-dlp for pageURL, then playerURL, retrying the pair on HTTP 429 with doubling waits.
    private func fetch(_ request: DownloadRequest, metadataOnly: Bool, log: LogSink,
                       onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws {
        let id = request.video.id
        let secret = request.video.password ?? ""

        var attempt = 0
        while true {
            attempt += 1
            var stderr: [String] = []
            var succeeded = false
            for url in [request.video.pageURL, request.video.playerURL] {
                let argv = metadataOnly
                    ? YtDlpArguments.metadata(request, url: url)
                    : YtDlpArguments.download(request, url: url)
                log.log("$ yt-dlp " + YtDlpArguments.redacted(argv).joined(separator: " "))
                let run = try await runTool(request.tools.ytdlp, argv) { line, _ in
                    if line.hasPrefix("VBP ") {
                        if let fraction = Self.parseProgress(line) {
                            let done = Int64(Double(line.split(separator: " ")[1]) ?? 0)
                            onEvent(.progress(videoID: id, fraction: fraction, downloadedBytes: done))
                        }
                    } else {
                        log.log(secret.isEmpty ? line : line.replacingOccurrences(of: secret, with: "***"))
                    }
                }
                try Task.checkCancellation()
                if run.status == 0 {
                    succeeded = true
                    break
                }
                stderr += run.stderr
                log.log("yt-dlp exited \(run.status) for \(url.absoluteString)")
            }
            if succeeded { return }

            switch Self.classify(stderr) {
            case .loggedOut:
                throw VBackupError.loggedOut
            case .rateLimited:
                let wait = 60 << (attempt - 1) // 60, 120, 240, 480; the fifth failure gives up
                if attempt == 5 { throw VBackupError.throttled(retryAfter: wait) }
                onEvent(.throttled(videoID: id, retryInSeconds: wait))
                log.log("HTTP 429 from Vimeo, retry \(attempt + 1) in \(wait)s")
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            case .other(let message):
                throw VBackupError.tool(message)
            }
        }
    }

    /// Finds the file yt-dlp wrote, renames it with its real quality tag and returns the final URL.
    private func finish(_ r: DownloadRequest, log: LogSink) async throws -> URL {
        try Task.checkCancellation()
        let dir = r.destinationDir
        let base = Naming.base(title: r.video.title, id: r.video.id)
        let found = try FileManager.default.contentsOfDirectory(atPath: dir.path).first {
            $0.hasPrefix(base + ".") && Naming.videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }
        guard let name = found else { throw VBackupError.tool("yt-dlp finished but wrote no video file") }

        let video = dir.appendingPathComponent(name)
        let info = (try? Data(contentsOf: dir.appendingPathComponent(base + ".info.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var width = (info["width"] as? Int) ?? 0
        var height = (info["height"] as? Int) ?? 0
        if width == 0 || height == 0 {
            (width, height) = try await probeSize(video, ffprobe: r.tools.ffprobe)
        }
        let isOriginal = Naming.isOriginalFormatID((info["format_id"] as? String) ?? "")
        let stem = Naming.fileStem(title: r.video.title, id: r.video.id,
                                   qualityTag: Naming.qualityTag(isOriginal: isOriginal, shortSide: min(width, height)))
        let dest = dir.appendingPathComponent(stem + "." + URL(fileURLWithPath: name).pathExtension)
        if dest != video {
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                throw VBackupError.tool("cannot rename to \(dest.lastPathComponent): file exists")
            }
            try FileManager.default.moveItem(at: video, to: dest)
        }
        log.log("saved \(dest.lastPathComponent)")
        return dest
    }

    private func probeSize(_ file: URL, ffprobe: URL) async throws -> (Int, Int) {
        guard let size = await MediaProbe.size(of: file, ffprobe: ffprobe) else {
            throw VBackupError.tool("could not read the resolution of \(file.lastPathComponent)")
        }
        return size
    }

    // MARK: - Pure helpers

    /// `VBP <downloaded> <total> <estimate>` to a 0...1 fraction. Uses the estimate when total is NA.
    /// Returns nil for anything unusable.
    // ponytail: merged formats report progress per stream, so the fraction can drop when audio starts.
    // Keep a running max here if the bar visibly jumps back.
    static func parseProgress(_ line: String) -> Double? {
        let fields = line.split(separator: " ")
        guard fields.count == 4, fields[0] == "VBP", let done = Double(fields[1]) else { return nil }
        guard let total = Double(fields[2]) ?? Double(fields[3]), total > 0 else { return nil }
        return min(1, done / total)
    }

    enum YtDlpFailure: Equatable {
        case loggedOut, rateLimited, other(String)
    }

    /// Matches on the ERROR: lines when there are any, so a warning that mentions --cookies cannot sign the user out.
    static func classify(_ stderr: [String]) -> YtDlpFailure {
        let errors = stderr.filter { $0.hasPrefix("ERROR:") }
        let text = (errors.isEmpty ? stderr : errors).joined(separator: "\n").lowercased()
        if ["only works when logged-in", "login required", "--cookies"].contains(where: { text.contains($0) }) {
            return .loggedOut
        }
        if text.contains("http error 429") { return .rateLimited }
        return .other(errors.last ?? stderr.last(where: { !$0.isEmpty }) ?? "yt-dlp failed")
    }
}
