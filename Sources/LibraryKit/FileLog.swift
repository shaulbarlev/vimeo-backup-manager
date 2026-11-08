import Foundation
import Contracts

/// Appends timestamped lines to `.vbackup/logs/<yyyy-MM-dd_HHmm>.log`. Deletes logs older than 30 days on init.
public final class FileLog: LogSink, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let handle: FileHandle

    /// Throws if root is missing. A second run in the same minute appends to the same file.
    public init(root: URL, run: Date = Date()) throws {
        let logs = try Layout.hiddenDir(root).appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("\(Self.runStamp.string(from: run)).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        Self.prune(logs, olderThan: run.addingTimeInterval(-30 * 24 * 3600))
    }

    deinit { try? handle.close() }

    public func log(_ line: String) {
        let text = "\(Self.lineStamp.string(from: Date())) \(line)\n"
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Helpers

    private static func prune(_ dir: URL, olderThan cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let runStamp = formatter("yyyy-MM-dd_HHmm")
    private static let lineStamp = formatter("yyyy-MM-dd HH:mm:ss")
}
