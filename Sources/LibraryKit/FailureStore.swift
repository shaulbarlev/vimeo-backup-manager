import Foundation
import Contracts

/// `.vbackup/failures.tsv`: id, reason, date. Recorded on a download failure, removed on success.
public struct FailureStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    private var fileURL: URL { root.appendingPathComponent(Naming.hiddenDir).appendingPathComponent("failures.tsv") }

    /// Video id -> reason.
    public func load() -> [String: String] {
        Dictionary(readRows().map { ($0.id, $0.reason) }, uniquingKeysWith: { _, last in last })
    }

    public func record(id: String, reason: String, at date: Date = Date()) throws {
        var rows = readRows().filter { $0.id != id }
        rows.append(Row(id: id, reason: Self.clean(reason), date: Self.day(date)))
        try write(rows)
    }

    public func clear(id: String) throws {
        let rows = readRows()
        guard rows.contains(where: { $0.id == id }) else { return }
        try write(rows.filter { $0.id != id })
    }

    // MARK: - File format

    private struct Row {
        var id: String
        var reason: String
        var date: String
    }

    private func readRows() -> [Row] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 2 else { return nil }
            return Row(id: String(f[0]), reason: String(f[1]), date: f.count > 2 ? String(f[2]) : "")
        }
    }

    private func write(_ rows: [Row]) throws {
        let dir = try Layout.hiddenDir(root)
        let text = rows.sorted { $0.id < $1.id }.map { "\($0.id)\t\($0.reason)\t\($0.date)" }.joined(separator: "\n")
        try (text.isEmpty ? "" : text + "\n").write(to: dir.appendingPathComponent("failures.tsv"), atomically: true, encoding: .utf8)
    }

    /// Tabs and newlines would break the file format.
    private static func clean(_ reason: String) -> String {
        reason.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
    }

    private static func day(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
