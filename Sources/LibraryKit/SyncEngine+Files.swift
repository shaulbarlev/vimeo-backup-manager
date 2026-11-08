import Foundation
import Contracts

/// Disk-side helpers for SyncEngine. Every operation moves or reads; nothing is deleted.
extension SyncEngine {
    struct NameClash: LocalizedError {
        let name: String
        var errorDescription: String? { "\(name) already exists at the destination" }
    }

    static func foldersByID(_ lib: RemoteLibrary) -> [String: RemoteFolder] {
        Dictionary(lib.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Modification time of the video's info.json, or .distantPast when it is missing (which forces a refresh).
    static func infoModified(_ file: LocalFile) -> Date {
        let base = DiskScanner.base(of: file.url, id: file.videoID)
        let info = file.url.deletingLastPathComponent().appendingPathComponent(base + ".info.json")
        return ((try? FileManager.default.attributesOfItem(atPath: info.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Path of the file's folder relative to root ("" for the root itself).
    static func relativeDir(of file: URL, root: URL) -> String {
        let dir = file.deletingLastPathComponent().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return dir.count > rootPath.count ? String(dir.dropFirst(rootPath.count + 1)) : ""
    }

    func scanDisk(_ config: BackupConfig,
                  onPhase: @escaping @Sendable (SyncPhase) -> Void) async throws -> DiskScanner.Result {
        try await DiskScanner(ffprobe: config.tools.ffprobe).scan(root: config.root) { done, total in
            onPhase(.scanningDisk(done: done, total: total))
        }
    }

    /// Moves each local video whose folder differs from Vimeo's, with its sidecars. Returns how many moved.
    /// Never overwrites: a name clash skips that video and adds a problem.
    func relocate(_ lib: RemoteLibrary, _ files: [LocalFile], config: BackupConfig, log: LogSink,
                  problems: inout [String], onPhase: @escaping @Sendable (SyncPhase) -> Void) -> Int {
        let folders = Self.foldersByID(lib)
        let remote = Dictionary(lib.videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = files.filter { remote[$0.videoID] != nil }
        var moved = 0
        for (index, file) in candidates.enumerated() {
            onPhase(.relocating(done: index, total: candidates.count))
            guard let video = remote[file.videoID] else { continue }
            let expected = Naming.folderPath(folderID: video.folderID, folders: folders)
            // Case-only differences are the same folder on the default (case-insensitive) volume.
            guard Self.relativeDir(of: file.url, root: config.root).lowercased() != expected.lowercased() else { continue }
            do {
                try moveWithSidecars(file, toFolder: config.root.appending(path: expected))
                log.log("relocated \(file.url.lastPathComponent) -> \(expected)")
                moved += 1
            } catch {
                log.log("relocate failed: \(file.videoID): \(error.localizedDescription)")
                problems.append("relocation skipped for \(file.videoID): \(error.localizedDescription)")
            }
        }
        return moved
    }

    /// The video plus every sidecar with the same [id] base in its folder, moved together.
    /// Checks every target name first, so a clash leaves the video where it was.
    func moveWithSidecars(_ file: LocalFile, toFolder dest: URL) throws {
        let fm = FileManager.default
        let from = file.url.deletingLastPathComponent()
        let base = DiskScanner.base(of: file.url, id: file.videoID)
        let names = try fm.contentsOfDirectory(atPath: from.path).filter { name in
            name == file.url.lastPathComponent
                || (name.hasPrefix(base + ".") && !DiskScanner.isVideo(URL(fileURLWithPath: name)))
        }
        for name in names where fm.fileExists(atPath: dest.appendingPathComponent(name).path) {
            throw NameClash(name: name)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in names {
            try fm.moveItem(at: from.appendingPathComponent(name), to: dest.appendingPathComponent(name))
        }
    }

    /// A crash or force-quit mid-download can leave the previous copy parked as "<name>.vbackup-old".
    /// Puts it back under its own name, or into .vbackup/replaced when a newer file already took that name.
    func recoverParked(root: URL, log: LogSink, problems: inout [String]) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return }
        let parked = walker.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(".vbackup-old") }
        for file in parked {
            let original = file.deletingLastPathComponent()
                .appendingPathComponent(String(file.lastPathComponent.dropLast(".vbackup-old".count)))
            if FileManager.default.fileExists(atPath: original.path) {
                setAside(file, root: root, log: log, problems: &problems)
            } else {
                attempt("restore \(original.lastPathComponent)", log: log) {
                    try FileManager.default.moveItem(at: file, to: original)
                    log.log("restored \(original.lastPathComponent) left over from an interrupted run")
                }
            }
        }
    }

    /// Moves a replaced lower-quality video to .vbackup/replaced/. A name clash gets " (n)" appended.
    func setAside(_ old: URL, root: URL, log: LogSink, problems: inout [String]) {
        do {
            let fm = FileManager.default
            let dir = try Layout.hiddenDir(root).appendingPathComponent("replaced", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // A copy parked during a download carries ".vbackup-old"; it keeps its real name in replaced/.
            let name = URL(fileURLWithPath: old.lastPathComponent.replacingOccurrences(of: ".vbackup-old", with: ""))
            var dest = dir.appendingPathComponent(name.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(name.deletingPathExtension().lastPathComponent) (\(n)).\(name.pathExtension)")
                n += 1
            }
            try fm.moveItem(at: old, to: dest)
            log.log("replaced file moved to \(dest.path)")
        } catch {
            log.log("could not set aside \(old.lastPathComponent): \(error.localizedDescription)")
            problems.append("could not set aside replaced file \(old.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Runs a bookkeeping write. A failure is logged, not thrown, so the run carries on.
    func attempt(_ what: String, log: LogSink, _ body: () throws -> Void) {
        do { try body() } catch { log.log("\(what) failed: \(error.localizedDescription)") }
    }
}
