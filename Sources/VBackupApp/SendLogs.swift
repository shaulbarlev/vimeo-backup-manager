import AppKit
import Foundation

/// "Send Logs…": zips the backup folder's recent logs, status and failures plus app/system info,
/// and opens a new email with the zip attached. Cookies and passwords are never in these files.
enum SendLogs {
    /// Where log emails go.
    /// Set at build time (Info.plist `VBSupportEmail`, from SUPPORT_EMAIL in scripts/release.env). Empty: user fills it in.
    static var recipient: String? {
        (Bundle.main.object(forInfoDictionaryKey: "VBSupportEmail") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    static let recentLogCount = 10

    /// Builds the zip in a temp folder and returns its URL.
    static func bundle(root: URL, problems: [String]) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let work = fm.temporaryDirectory.appendingPathComponent("vbackup-logs-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("vbackup-logs-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        let hidden = root.appendingPathComponent(".vbackup", isDirectory: true)
        for name in ["status.txt", "failures.tsv"] {
            let src = hidden.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: stage.appendingPathComponent(name)) }
        }
        let logs = hidden.appendingPathComponent("logs", isDirectory: true)
        let recent = ((try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // names are timestamps
            .prefix(recentLogCount)
        if !recent.isEmpty {
            let dest = stage.appendingPathComponent("logs", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for log in recent { try fm.copyItem(at: log, to: dest.appendingPathComponent(log.lastPathComponent)) }
        }
        try info(root: root, problems: problems).write(to: stage.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)

        let zip = work.appendingPathComponent(stage.lastPathComponent + ".zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", stage.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    static func info(root: URL, problems: [String]) -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return """
        Vimeo Backup \(version)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Backup folder: \(root.path)
        Date: \(Date())

        Problems shown:
        \(problems.isEmpty ? "none" : problems.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    /// Opens a new email with the zip attached; without a mail account, reveals the zip and opens a mailto: draft.
    @MainActor
    static func send(root: URL, problems: [String]) throws {
        let zip = try bundle(root: root, problems: problems)
        let subject = "Vimeo Backup logs"
        let body = "What happened:\n\n"
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: [body, zip]) {
            mail.recipients = recipient.map { [$0] } ?? []
            mail.subject = subject
            mail.perform(withItems: [body, zip])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = recipient ?? ""
        c.queryItems = [URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body", value: body + "(Please attach \(zip.lastPathComponent), shown in Finder.)")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
