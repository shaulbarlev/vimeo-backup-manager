import Contracts
import CryptoKit
import Foundation

/// Downloads the exact file Vimeo lists (`source` or a rendition) with curl, resuming `.part` files,
/// and verifies it: curl fails on a short transfer, and the source file must match Vimeo's size and md5.
/// Sidecars (info.json, thumbnail, captions) come from yt-dlp without downloading the video.
/// Videos without a listed file fall back to yt-dlp entirely.
public struct VimeoDownloader: VideoDownloading {
    static let curl = URL(fileURLWithPath: "/usr/bin/curl")
    let ytdlp = YtDlpDownloader()

    public init() {}

    public func download(_ request: DownloadRequest, log: LogSink,
                         onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        guard let rendition = request.rendition, let link = rendition.link else {
            log.log("no Vimeo file listed for \(request.video.id), using yt-dlp")
            return try await ytdlp.download(request, log: log, onEvent: onEvent)
        }
        let dir = request.destinationDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = dir.appendingPathComponent(Self.fileName(request.video, rendition, link: link))
        let part = final.appendingPathExtension("part")

        if FileManager.default.fileExists(atPath: final.path) {
            if rendition.sizeIsExact, Self.size(of: final) == rendition.size {
                log.log("already complete: \(final.lastPathComponent)")
                return final
            }
            // Never overwrite or delete an existing file: the engine moves old copies aside before downloading.
            throw VBackupError.tool("\(final.lastPathComponent) already exists and does not match Vimeo's file")
        }

        try await fetch(link, to: part, expected: rendition.size, exact: rendition.sizeIsExact,
                        id: request.video.id, log: log, onEvent: onEvent)
        try verify(part, rendition)
        try FileManager.default.moveItem(at: part, to: final)
        log.log("saved \(final.lastPathComponent) (\(Self.size(of: final)) bytes)")

        do {
            try await ytdlp.refreshMetadata(request, existingFile: final, log: log)
        } catch {
            if error is CancellationError { throw error }
            log.log("sidecars failed for \(request.video.id) (video is saved): \(error.localizedDescription)")
        }
        return final
    }

    public func refreshMetadata(_ request: DownloadRequest, existingFile: URL, log: LogSink) async throws {
        try await ytdlp.refreshMetadata(request, existingFile: existingFile, log: log)
    }

    // MARK: - Transfer

    /// curl with resume. Progress comes from polling the .part size. 403/410 = expired link, 429 = back off.
    private func fetch(_ link: URL, to part: URL, expected: Int64, exact: Bool, id: String, log: LogSink,
                       onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws {
        var attempt = 0
        while true {
            attempt += 1
            let poller = Task.detached {
                while !Task.isCancelled {
                    let done = Self.size(of: part)
                    onEvent(.progress(videoID: id, fraction: expected > 0 ? min(1, Double(done) / Double(expected)) : 0,
                                      downloadedBytes: done))
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            // The signed link is a credential of sorts: log only that a transfer started, never the URL.
            log.log("curl: \(part.lastPathComponent) from byte \(Self.size(of: part))")
            defer { poller.cancel() }
            let run = try await runTool(Self.curl, Self.curlArguments(link, part: part))
            try Task.checkCancellation()

            let http = Int(run.stdout.last ?? "") ?? 0
            // 416 means "nothing past this byte". For the source, verify() checks size and md5 next; a rendition has no
            // exact size to check, so a leftover .part from an older encode is discarded and fetched from scratch once.
            if http == 416, !exact, attempt == 1 {
                log.log("resume refused for \(part.lastPathComponent); starting it over")
                try? FileManager.default.removeItem(at: part)
                continue
            }
            switch Self.outcome(exit: run.status, http: http) {
            case .done:
                onEvent(.progress(videoID: id, fraction: 1, downloadedBytes: Self.size(of: part)))
                return
            case .expired:
                throw VBackupError.linkExpired
            case .throttled:
                let wait = 60 << (attempt - 1)
                if attempt == 5 { throw VBackupError.throttled(retryAfter: wait) }
                onEvent(.throttled(videoID: id, retryInSeconds: wait))
                log.log("HTTP 429 from Vimeo's file server, retry in \(wait)s")
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            case .retry where attempt < 3:
                log.log("curl exited \(run.status) (HTTP \(http)), resuming")
            case .retry, .failed:
                throw VBackupError.tool("curl exited \(run.status) (HTTP \(http)): \(run.stderr.last ?? "")")
            }
        }
    }

    /// The source file must be byte-exact with Vimeo's listing and match its md5. Renditions are only listed
    /// approximately, so for them curl's own completeness check (Content-Length) is the verification.
    private func verify(_ part: URL, _ r: Rendition) throws {
        guard r.sizeIsExact else { return }
        let size = Self.size(of: part)
        guard size == r.size else {
            try? FileManager.default.removeItem(at: part)
            throw VBackupError.sizeMismatch("\(size) bytes, Vimeo lists \(r.size)")
        }
        if let md5 = r.md5, let actual = try? Self.md5(part), actual != md5.lowercased() {
            try? FileManager.default.removeItem(at: part)
            throw VBackupError.sizeMismatch("md5 \(actual) differs from Vimeo's \(md5)")
        }
    }

    // MARK: - Pure helpers

    enum Outcome: Equatable { case done, expired, throttled, retry, failed }

    /// curl exit + HTTP status -> what to do. 416 on a resume means the file was already complete.
    static func outcome(exit: Int32, http: Int) -> Outcome {
        switch (exit, http) {
        case (0, 200..<300), (0, 0), (_, 416): .done // 0 = no HTTP status (file:// in tests)
        case (_, 403), (_, 410): .expired
        case (_, 429): .throttled
        case (18, _), (28, _), (56, _), (92, _): .retry // short transfer, timeout, recv error, HTTP/2 stream
        default: .failed
        }
    }

    static func curlArguments(_ link: URL, part: URL) -> [String] {
        ["--silent", "--show-error", "--location", "--fail",
         "--continue-at", "-", "--output", part.path,
         "--retry", "3", "--retry-delay", "5", "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "120",
         "--write-out", "\n%{http_code}", link.absoluteString]
    }

    /// "Title [ID] [orig].mp4" or "Title [ID] [1080p].mp4" (tag from the rendition's real short side).
    static func fileName(_ video: RemoteVideo, _ r: Rendition, link: URL) -> String {
        let tag = Naming.qualityTag(isOriginal: r.sizeIsExact, shortSide: r.shortSide)
        let ext = link.pathExtension.isEmpty || link.pathExtension.count > 4 ? "mp4" : link.pathExtension.lowercased()
        return Naming.fileStem(title: video.title, id: video.id, qualityTag: tag) + "." + ext
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
