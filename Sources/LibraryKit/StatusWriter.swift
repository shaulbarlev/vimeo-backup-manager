import Foundation
import Contracts

/// Writes `.vbackup/status.txt`: a plain-text report rewritten after every sync.
public enum StatusWriter {
    public static func write(_ summary: LibrarySummary, root: URL, syncedAt: Date) throws {
        let dir = try Layout.hiddenDir(root)
        try render(summary, syncedAt: syncedAt).write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    public static func render(_ s: LibrarySummary, syncedAt: Date) -> String {
        var out: [String] = [
            "vbackup status",
            "Last sync:       \(stamp(syncedAt))",
            "Account:         \(s.accountName)",
            "Vimeo checked:   \(s.vimeoCheckedAt.map(stamp) ?? "never")",
            "Disk scanned:    \(s.diskScannedAt.map(stamp) ?? "never")",
            "",
            "Videos on Vimeo: \(s.total)",
            "Local size:      \(bytes(s.localBytes))",
            "Complete:        \(s.completeCount) / \(s.total) (\(percent(s.completeCount, s.total))%)",
            "",
        ]

        var categoryRows = [["Category", "Count", "%", "Size"]]
        for category in Category.allCases {
            let stat = s.stats[category] ?? CategoryStat()
            let size = category == .missing
                ? (s.missing.exact ? "" : "≈") + bytes(s.missing.bytes) + " as originals"
                : bytes(stat.bytes)
            categoryRows.append([category.label, "\(stat.count)", percent(stat.count, s.total), size])
        }
        out += table(categoryRows)

        out += ["", "Folders"]
        var folderRows = [["Folder", "Videos", "Orig", "Full", "Lower", "Missing", "Size"]]
        for f in s.folders {
            func pct(_ c: Category) -> String { percent(f.stats[c]?.count ?? 0, f.total) + "%" }
            folderRows.append([f.path, "\(f.total)", pct(.original), pct(.fullResolution), pct(.lower), pct(.missing), bytes(f.bytes)])
        }
        out += s.folders.isEmpty ? ["  (none)"] : table(folderRows)

        out += ["", "Failures (\(s.failures.count))"]
        out += s.failures.isEmpty ? ["  none"] : s.failures.map { "  \($0.videoID)  \($0.title)  - \($0.reason)" }

        out += ["", "Local-only files, removed on Vimeo (\(s.localOnly.count))"]
        out += s.localOnly.isEmpty ? ["  none"] : s.localOnly.map { "  \($0.url.lastPathComponent)  \(bytes($0.sizeBytes))" }

        out += ["", "Problems (\(s.problems.count))"]
        out += s.problems.isEmpty ? ["  none"] : s.problems.map { "  \($0)" }

        return out.joined(separator: "\n") + "\n"
    }

    /// One decimal place, e.g. "73.0". Zero when there is no total.
    public static func percent(_ count: Int, _ total: Int) -> String {
        total > 0 ? String(format: "%.1f", Double(count) * 100 / Double(total)) : "0.0"
    }

    // MARK: - Helpers

    /// Left-aligns the first column and right-aligns the rest, each column padded to its widest cell.
    private static func table(_ rows: [[String]]) -> [String] {
        guard let first = rows.first else { return [] }
        let widths = first.indices.map { col in rows.map { col < $0.count ? $0[col].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.indices.map { col in
                let cell = row[col]
                let pad = String(repeating: " ", count: widths[col] - cell.count)
                return col == 0 ? cell + pad : pad + cell
            }.joined(separator: "  ")
        }
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
