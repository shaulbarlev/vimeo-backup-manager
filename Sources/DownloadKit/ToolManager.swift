import Contracts
import Foundation

/// Installs yt-dlp into `<appSupport>/bin` and locates ffmpeg and ffprobe.
public struct ToolManager: ToolProviding {
    let appSupport: URL

    public init(appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("vbackup", isDirectory: true)) {
        self.appSupport = appSupport
    }

    public func prepare(log: LogSink) async throws -> Tools {
        let bin = appSupport.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Optional: only the yt-dlp fallback (videos without listed files) needs ffmpeg to merge streams.
        let ffmpeg = findTool("ffmpeg", in: bin) ?? bin.appendingPathComponent("ffmpeg")
        let ffprobe = findTool("ffprobe", in: bin) ?? bin.appendingPathComponent("ffprobe")
        if !FileManager.default.isExecutableFile(atPath: ffmpeg.path) {
            log.log("ffmpeg not found: videos without a Vimeo file listing can't be downloaded")
        }

        let ytdlp = bin.appendingPathComponent("yt-dlp")
        if !FileManager.default.fileExists(atPath: ytdlp.path) {
            try await installYtDlp(to: ytdlp, log: log)
        }
        await ytDlpSelfUpdate.run { await selfUpdate(ytdlp, log: log) }
        return Tools(ytdlp: ytdlp, ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    func installYtDlp(to dest: URL, log: LogSink) async throws {
        if let bundled = Bundle.main.url(forResource: "yt-dlp_macos", withExtension: nil) {
            try FileManager.default.copyItem(at: bundled, to: dest)
            log.log("yt-dlp: copied from app bundle")
        } else {
            try await downloadYtDlp(to: dest)
            log.log("yt-dlp: downloaded latest release")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        _ = removexattr(dest.path, "com.apple.quarantine", 0) // absent attribute is fine
    }

    /// Separate from `installYtDlp` so tests can skip the network by pre-placing `bin/yt-dlp`.
    func downloadYtDlp(to dest: URL) async throws {
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VBackupError.tool("yt-dlp download failed")
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Non-fatal: a failed self-update just leaves the installed yt-dlp as it is.
    // ponytail: no timeout on -U, so a hung update blocks prepare. Add a deadline if that happens.
    func selfUpdate(_ ytdlp: URL, log: LogSink) async {
        do {
            let run = try await runTool(ytdlp, ["-U"]) { line, _ in log.log("yt-dlp -U: \(line)") }
            log.log("yt-dlp -U exited \(run.status)")
        } catch {
            log.log("yt-dlp -U failed, continuing: \(error.localizedDescription)")
        }
    }

    /// Bundle resource, then `bin`, then the usual Homebrew dirs, then $PATH.
    func findTool(_ name: String, in bin: URL) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) { candidates.append(bundled) }
        let dirs = [bin.path, "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        candidates += dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Runs its work once per process; later callers return immediately.
private actor OnceGate {
    private var started = false
    func run(_ work: () async -> Void) async {
        guard !started else { return }
        started = true
        await work()
    }
}

private let ytDlpSelfUpdate = OnceGate()

// MARK: - Process runner

struct ToolRun: Sendable {
    public var status: Int32
    public var stdout: [String]
    public var stderr: [String]
}

/// Runs a tool and passes each output line to `onLine` (`isStderr` tells which stream) as it arrives.
/// If the calling task is cancelled, sends SIGINT (yt-dlp keeps its .part files) and returns once the process exits.
func runTool(_ exe: URL, _ args: [String],
             onLine: @escaping @Sendable (_ line: String, _ isStderr: Bool) -> Void = { _, _ in }) async throws -> ToolRun {
    // onCancel fires before any PID exists when the task is already cancelled, so never launch in that case.
    try Task.checkCancellation()
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err

    return try await withTaskCancellationHandler {
        // Detached, so cancellation cannot stop a reader early: a stopped reader leaves the pipe full and yt-dlp hangs.
        let stdout = Task.detached { try await readLines(out.fileHandleForReading) { onLine($0, false) } }
        let stderr = Task.detached { try await readLines(err.fileHandleForReading) { onLine($0, true) } }
        // The termination handler must be set before run(), or a fast exit is missed.
        let status = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do {
                try p.run()
                if Task.isCancelled { kill(p.processIdentifier, SIGINT) } // cancel raced the launch
            } catch {
                try? out.fileHandleForWriting.close() // let the readers see EOF
                try? err.fileHandleForWriting.close()
                c.resume(throwing: VBackupError.tool("cannot run \(exe.lastPathComponent): \(error.localizedDescription)"))
            }
        }
        return ToolRun(status: status, stdout: try await stdout.value, stderr: try await stderr.value)
    } onCancel: {
        let pid = p.processIdentifier
        if pid > 0 { kill(pid, SIGINT) }
    }
}

private func readLines(_ handle: FileHandle, _ each: (String) -> Void) async throws -> [String] {
    var all: [String] = []
    for try await line in handle.bytes.lines {
        each(line)
        all.append(line)
    }
    return all
}
