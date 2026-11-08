import Foundation
import Contracts

/// Listing, disk scan, relocation, downloads, sidecar refresh and status.
/// Never deletes user files and never creates the backup root.
public struct SyncEngine: BackupEngine {
    let downloader: VideoDownloading
    let fetch: @Sendable (BackupConfig, LogSink, @escaping @Sendable (Int, Int?) -> Void) async throws -> RemoteLibrary
    /// One video with fresh download links, used once when a signed link has expired.
    let refetch: @Sendable (BackupConfig, String, LogSink) async throws -> RemoteVideo
    /// The last listing per backup folder. A download reuses it while it is fresh instead of re-listing everything.
    let cache = ListingCache()
    static let listingMaxAge: TimeInterval = 3600

    public init(downloader: VideoDownloading,
                makeClient: @escaping @Sendable (URL) -> VimeoWebClient = { VimeoWebClient(cookiesFile: $0) }) {
        self.downloader = downloader
        self.fetch = { config, log, progress in
            try await makeClient(config.cookies).fetchLibrary(log: log, onProgress: progress)
        }
        self.refetch = { config, id, log in try await makeClient(config.cookies).fetchVideo(id: id, log: log) }
    }

    /// Test seam: a fake listing instead of Vimeo.
    init(downloader: VideoDownloading,
         fetch: @escaping @Sendable (BackupConfig, LogSink) async throws -> RemoteLibrary,
         refetch: @escaping @Sendable (BackupConfig, String, LogSink) async throws -> RemoteVideo = { _, _, _ in
             throw VBackupError.linkExpired
         }) {
        self.downloader = downloader
        self.fetch = { config, log, _ in try await fetch(config, log) }
        self.refetch = refetch
    }

    private func list(_ config: BackupConfig, log: LogSink, reuse: Bool = false,
                      onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> RemoteLibrary {
        if reuse, let lib = cache.get(config.root), Date().timeIntervalSince(lib.fetchedAt) < Self.listingMaxAge {
            log.log("using the Vimeo listing from \(Int(Date().timeIntervalSince(lib.fetchedAt) / 60)) min ago")
            return lib
        }
        onPhase(.listingVimeo(videos: 0, total: nil))
        let lib = try await fetch(config, log) { done, total in onPhase(.listingVimeo(videos: done, total: total)) }
        cache.set(config.root, lib)
        return lib
    }

    public func refresh(_ config: BackupConfig, log: LogSink,
                        onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary {
        try Layout.requireRoot(config.root)
        var problems: [String] = []
        recoverParked(root: config.root, log: log, problems: &problems)
        var listing: RemoteLibrary?
        do {
            listing = try await list(config, log: log, onPhase: onPhase)
        } catch {
            if error is CancellationError || (error as? VBackupError) == .loggedOut { throw error }
            log.log("refresh: Vimeo listing failed: \(error.localizedDescription)")
            problems.append("Vimeo listing failed: \(error.localizedDescription)")
        }
        let scan = try await scanDisk(config, onPhase: onPhase)
        problems += scan.problems
        let failures = FailureStore(root: config.root).load()
        if let lib = listing {
            return Classifier.classify(lib, scan.files, failures: failures, diskScannedAt: Date(), problems: problems)
        }
        return Classifier.diskOnly(accountName: "", scan.files, diskScannedAt: Date(), problems: problems)
    }

    public func download(_ config: BackupConfig, videoIDs: [String], quality: Quality, log: LogSink,
                         onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary {
        try Layout.requireRoot(config.root)
        let store = FailureStore(root: config.root)
        var problems: [String] = []
        recoverParked(root: config.root, log: log, problems: &problems)
        log.log("download: start, \(videoIDs.count) videos requested at \(quality.label)")

        let lib = try await list(config, log: log, reuse: true, onPhase: onPhase)
        log.log("download: listed \(lib.folders.count) folders, \(lib.videos.count) videos")

        var scan = try await scanDisk(config, onPhase: onPhase)
        if relocate(lib, scan.files, config: config, log: log, problems: &problems, onPhase: onPhase) > 0 {
            scan = try await scanDisk(config, onPhase: onPhase)
        }

        let local = Classifier.bestLocalByID(scan.files)
        let wanted = Set(videoIDs)
        let plan = lib.videos.filter { wanted.contains($0.id) && Self.needsDownload($0, local: local[$0.id], quality: quality) }
        log.log("download: \(plan.count) of \(wanted.count) need downloading, the rest are already at \(quality.label) or better")
        var stopped = false
        do {
            try await downloadPlan(plan, lib, quality: quality, config: config, local: local, store: store, log: log,
                                   problems: &problems, onPhase: onPhase)
            // Downloads don't change other video files, so one scan serves the sidecar refresh.
            let after = try await scanDisk(config, onPhase: onPhase)
            try await refreshStaleSidecars(lib, scan: after, only: wanted, config: config, log: log,
                                           problems: &problems, onPhase: onPhase)
        } catch where Self.isCancellation(error) {
            stopped = true
            log.log("download: stopped by the user")
        }

        // Runs outside the (possibly cancelled) task, so a stop still records what was downloaded so far.
        let finishing = problems
        let summary = try await Task.detached { [self] () -> LibrarySummary in
            let after = try await scanDisk(config, onPhase: onPhase)
            onPhase(.writingStatus)
            let summary = Classifier.classify(lib, after.files, failures: store.load(),
                                              diskScannedAt: Date(), problems: finishing + after.problems)
            try StatusWriter.write(summary, root: config.root, syncedAt: Date())
            return summary
        }.value
        log.log("download: \(stopped ? "stopped" : "done"), \(summary.completeCount) of \(summary.total) complete")
        return summary
    }

    /// A video needs downloading unless its local copy is already at `quality` or better.
    /// The original is the best there is; a broken original (size mismatch) always re-downloads.
    static func needsDownload(_ video: RemoteVideo, local: LocalFile?, quality: Quality) -> Bool {
        let (category, mismatch) = Classifier.category(for: video, local: local, unreachable: false)
        return VideoState(video: video, folderPath: "", category: category, local: local, sizeMismatch: mismatch)
            .needsDownload(quality)
    }

    /// A user Stop, however it surfaces (Swift task cancellation or a cancelled URLSession request).
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    // MARK: - Steps

    private func downloadPlan(_ plan: [RemoteVideo], _ lib: RemoteLibrary, quality: Quality, config: BackupConfig,
                              local: [String: LocalFile], store: FailureStore, log: LogSink,
                              problems: inout [String], onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws {
        let folders = Self.foldersByID(lib)
        // Overall progress is weighted by size (falling back to duration) so one big video doesn't look like a clip.
        let weight = { (v: RemoteVideo) in Double(max(quality.size(of: v).bytes, 1)) }
        let totalWeight = plan.reduce(0) { $0 + weight($1) }
        var doneWeight = 0.0
        let bytes = ByteCounter()
        for (index, planned) in plan.enumerated() {
            defer { doneWeight += weight(planned); bytes.finishVideo() }
            try Task.checkCancellation()
            let number = index + 1
            let title = planned.title
            let before = doneWeight, w = weight(planned)
            let progress = { @Sendable (fraction: Double) -> SyncPhase in
                .downloading(DownloadProgress(index: number, total: plan.count, title: title, videoFraction: fraction,
                                              overallFraction: totalWeight > 0 ? (before + w * fraction) / totalWeight : 0,
                                              bytesDownloaded: bytes.total))
            }
            onPhase(progress(0))
            let onEvent: @Sendable (DownloadEvent) -> Void = { event in
                switch event {
                case .progress(_, let fraction, let streamBytes):
                    bytes.update(streamBytes)
                    onPhase(progress(fraction))
                case .throttled(_, let seconds):
                    onPhase(.throttled(resumeAt: Date().addingTimeInterval(TimeInterval(seconds))))
                }
            }
            let dir = config.root.appending(path: Naming.folderPath(folderID: planned.folderID, folders: folders))
            log.log("download \(number)/\(plan.count): \(planned.id) at \(quality.label)")
            // The existing copy steps aside (same folder, a name the scanner ignores) so the download never
            // writes over it. Success moves it to .vbackup/replaced; failure or Stop puts it back.
            let old = local[planned.id]?.url
            let parked = old.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".vbackup-old") }
            if let old, let parked {
                do { try FileManager.default.moveItem(at: old, to: parked) } catch {
                    log.log("could not set aside \(old.lastPathComponent): \(error.localizedDescription)")
                    attempt("record failure \(planned.id)", log: log) {
                        try store.record(id: planned.id, reason: "could not move the existing copy aside")
                    }
                    continue
                }
            }
            func restore() {
                guard let old, let parked, FileManager.default.fileExists(atPath: parked.path) else { return }
                if FileManager.default.fileExists(atPath: old.path) {
                    setAside(parked, root: config.root, log: log, problems: &problems)
                } else {
                    attempt("restore \(old.lastPathComponent)", log: log) { try FileManager.default.moveItem(at: parked, to: old) }
                }
            }
            do {
                var video = planned
                var newURL: URL
                do {
                    newURL = try await downloader.download(
                        DownloadRequest(video: video, destinationDir: dir, quality: quality, cookies: config.cookies, tools: config.tools),
                        log: log, onEvent: onEvent)
                } catch VBackupError.linkExpired {
                    log.log("download link expired for \(video.id), fetching a fresh one")
                    video = try await refetch(config, video.id, log)
                    newURL = try await downloader.download(
                        DownloadRequest(video: video, destinationDir: dir, quality: quality, cookies: config.cookies, tools: config.tools),
                        log: log, onEvent: onEvent)
                }
                log.log("download done: \(video.id) -> \(newURL.lastPathComponent)")
                attempt("clear failure \(video.id)", log: log) { try store.clear(id: video.id) }
                if let parked { setAside(parked, root: config.root, log: log, problems: &problems) }
            } catch {
                restore()
                if Self.isCancellation(error) { throw CancellationError() }
                if (error as? VBackupError) == .loggedOut { throw error }
                let reason = error.localizedDescription
                log.log("download failed: \(planned.id): \(reason)")
                attempt("record failure \(planned.id)", log: log) { try store.record(id: planned.id, reason: reason) }
            }
        }
    }

    private func refreshStaleSidecars(_ lib: RemoteLibrary, scan: DiskScanner.Result, only ids: Set<String>,
                                      config: BackupConfig, log: LogSink, problems: inout [String],
                                      onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws {
        let local = Classifier.bestLocalByID(scan.files)
        let stale = lib.videos.compactMap { video -> (RemoteVideo, LocalFile)? in
            guard ids.contains(video.id), let file = local[video.id], Self.infoModified(file) < video.modified else { return nil }
            return (video, file)
        }
        log.log("download: \(stale.count) videos need refreshed metadata")
        for (index, (video, file)) in stale.enumerated() {
            try Task.checkCancellation()
            onPhase(.refreshingMetadata(done: index, total: stale.count))
            let request = DownloadRequest(video: video, destinationDir: file.url.deletingLastPathComponent(),
                                          quality: .original, cookies: config.cookies, tools: config.tools)
            do {
                try await downloader.refreshMetadata(request, existingFile: file.url, log: log)
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                if (error as? VBackupError) == .loggedOut { throw error }
                log.log("metadata refresh failed: \(video.id): \(error.localizedDescription)")
                problems.append("metadata refresh failed for \(video.id): \(error.localizedDescription)")
            }
        }
    }
}

/// Bytes downloaded across the whole run. yt-dlp restarts its byte count for each stream (video, then audio)
/// and each video, so a drop means a new stream began.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var base: Int64 = 0
    private var current: Int64 = 0

    var total: Int64 { lock.withLock { base + current } }

    func update(_ streamBytes: Int64) {
        lock.withLock {
            if streamBytes < current { base += current }
            current = streamBytes
        }
    }

    func finishVideo() { lock.withLock { base += current; current = 0 } }
}

/// Last listing per backup root, shared by refresh and download.
final class ListingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var libs: [String: RemoteLibrary] = [:]
    func get(_ root: URL) -> RemoteLibrary? { lock.withLock { libs[root.standardizedFileURL.path] } }
    func set(_ root: URL, _ lib: RemoteLibrary) { lock.withLock { libs[root.standardizedFileURL.path] = lib } }
}
