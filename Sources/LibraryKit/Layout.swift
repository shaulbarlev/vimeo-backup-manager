import Foundation
import Contracts

/// Paths under the backup folder. The root itself is never created: a missing root means the drive is not mounted.
enum Layout {
    static func requireRoot(_ root: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw VBackupError.rootUnavailable(root.path)
        }
    }

    /// <root>/.vbackup, created on demand. Throws if root is missing.
    static func hiddenDir(_ root: URL) throws -> URL {
        try requireRoot(root)
        let dir = root.appendingPathComponent(Naming.hiddenDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
