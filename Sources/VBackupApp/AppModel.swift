import Contracts
import Foundation
import Observation

/// App state. The only place that calls the engine and the tools; views read it and call its actions.
@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let root = "backupRoot"
        static let lastDownload = "lastDownload"
        static let welcomed = "welcomed"
    }

    /// What the download sheet opens with. `onlyIDs` limits it to specific videos (Upgrade / Re-download).
    struct SheetRequest: Identifiable {
        let id = UUID()
        var title: String
        var scope: DownloadScope
        var quality: Quality
        var onlyIDs: Set<String>?
        /// Date preset name (DatePreset.rawValue). Relative presets are recomputed, so "Last 7 days" stays relative.
        var preset: String?
    }

    /// The last download's scope and quality, for "Repeat last download".
    struct LastDownload: Codable {
        var scope: DownloadScope
        var quality: Quality
        var preset: String?
    }

    private let engine: BackupEngine
    private let toolProvider: ToolProviding
    private var toolsTask: Task<Tools, Error>?
    private var task: Task<Void, Never>?

    var root: URL?
    var summary: LibrarySummary?
    var sheet: SheetRequest?
    /// Problems the user closed in the banner; a new problem text shows again.
    var dismissedProblems: Set<String> = []
    private(set) var lastDownload: LastDownload?
    var phase: SyncPhase? {
        didSet { clock.update(phase) }
    }
    /// Start time of the current phase kind, for ETA and speed.
    private(set) var clock = ProgressClock()
    var error: String?
    var showSignIn = false
    var showHelp = false
    private(set) var isSignedIn = VimeoSession.isSignedIn
    /// The getting-started screen shows until the user presses Get Started once.
    private(set) var welcomed = UserDefaults.standard.bool(forKey: Key.welcomed)
    private(set) var isSyncing = false
    private var currentRun: UUID?

    init(engine: BackupEngine, tools: ToolProviding) {
        self.engine = engine
        self.toolProvider = tools
        let defaults = UserDefaults.standard
        root = defaults.string(forKey: Key.root).map { URL(fileURLWithPath: $0) }
        CookieExporter.migrateLegacy(root: root)
        _ = VimeoSession.dataStoreID(legacyRoot: root)
        isSignedIn = VimeoSession.isSignedIn
        lastDownload = defaults.data(forKey: Key.lastDownload).flatMap { try? JSONDecoder().decode(LastDownload.self, from: $0) }
    }

    /// Startup: prepare the tools, then refresh if a backup folder is already chosen.
    func launch() {
        Task { _ = try? await toolset() }
        if root != nil { refresh() }
    }

    /// Re-reads Vimeo and the disk. Downloads nothing.
    func refresh() {
        let engine = engine
        run { config, onPhase in try await engine.refresh(config, log: Wiring.log(root: config.root), onPhase: onPhase) }
    }

    /// Problems and the last error that the user hasn't closed.
    var visibleProblems: [String] {
        ((summary?.problems ?? []) + (error.map { [$0] } ?? [])).filter { !dismissedProblems.contains($0) }
    }

    func sendLogs() {
        guard let root else { return }
        do {
            try SendLogs.send(root: root, problems: (summary?.problems ?? []) + (error.map { [$0] } ?? []))
        } catch {
            self.error = "Could not collect logs: \(error.localizedDescription)"
        }
    }

    func dismissProblems() {
        dismissedProblems.formUnion(visibleProblems)
    }

    func openDownload(title: String = "Download", scope: DownloadScope = DownloadScope(),
                      quality: Quality = .original, onlyIDs: Set<String>? = nil, preset: String? = nil) {
        sheet = SheetRequest(title: title, scope: scope, quality: quality, onlyIDs: onlyIDs, preset: preset)
    }

    /// Downloads `ids` at `quality`. `scope` is remembered for "Repeat last download".
    func download(ids: [String], quality: Quality, scope: DownloadScope?, preset: String? = nil) {
        if let scope {
            lastDownload = LastDownload(scope: scope, quality: quality, preset: preset)
            UserDefaults.standard.set(try? JSONEncoder().encode(lastDownload), forKey: Key.lastDownload)
        }
        let engine = engine
        run { config, onPhase in
            try await engine.download(config, videoIDs: ids, quality: quality,
                                      log: Wiring.log(root: config.root), onPhase: onPhase)
        }
    }

    /// Re-opens the sheet with the last scope and quality, resolved against the current listing.
    func repeatLastDownload() {
        guard let last = lastDownload else { return }
        openDownload(title: "Repeat last download", scope: last.scope, quality: last.quality, preset: last.preset)
    }

    func cancel() {
        task?.cancel()
    }

    /// Chooses the backup folder. With no cookies for it yet, the sign-in sheet opens.
    func setRoot(_ url: URL) {
        guard !isSyncing else { return }
        root = url
        UserDefaults.standard.set(url.path, forKey: Key.root)
        summary = nil
        error = nil
        refresh()
    }

    /// Get Started: step 1 is signing in, step 2 choosing the folder (SetupView).
    func finishWelcome() {
        welcomed = true
        UserDefaults.standard.set(true, forKey: Key.welcomed)
        if !isSignedIn { showSignIn = true }
    }

    /// Called by the sign-in sheet once the cookies file is written.
    func signedIn() {
        showSignIn = false
        isSignedIn = true
        if root != nil { refresh() }
    }

    func signOut() {
        guard !isSyncing else { return }
        Task {
            do {
                try await VimeoSession.signOut()
                isSignedIn = false
                summary = nil
            } catch {
                self.error = "Sign out failed: \(error.localizedDescription)"
            }
        }
    }

    /// Runs one engine job. Does nothing if a job is already running. Without cookies it opens sign-in.
    private func run(
        _ work: @escaping @Sendable (BackupConfig, @escaping @Sendable (SyncPhase) -> Void) async throws -> LibrarySummary
    ) {
        guard !isSyncing, let root else { return }
        let cookies = CookieExporter.cookiesURL()
        guard FileManager.default.fileExists(atPath: cookies.path) else {
            showSignIn = true
            return
        }
        isSyncing = true
        error = nil
        task = Task {
            defer {
                isSyncing = false
                phase = nil
                task = nil
                currentRun = nil
            }
            do {
                let tools = try await toolset()
                let config = BackupConfig(root: root, cookies: cookies, tools: tools)
                let run = UUID()
                currentRun = run
                summary = try await work(config) { [weak self] p in
                    // The main queue is FIFO, so phases arrive in order; late ones from a finished run are dropped.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.isSyncing, self.currentRun == run else { return }
                            self.phase = p
                        }
                    }
                }
            } catch is CancellationError {
                // Stopped by the user: keep the last summary.
            } catch VBackupError.loggedOut {
                // Clear the stale web session first, or the sign-in sheet would re-export its revoked cookie.
                try? await VimeoSession.signOut()
                isSignedIn = false
                error = VBackupError.loggedOut.errorDescription
                showSignIn = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Prepares yt-dlp/ffmpeg once. A failed attempt is retried on the next action.
    private func toolset() async throws -> Tools {
        let provider = toolProvider
        let pending = toolsTask ?? Task { try await provider.prepare(log: PrintLog()) }
        toolsTask = pending
        do {
            return try await pending.value
        } catch {
            toolsTask = nil
            throw error
        }
    }
}
