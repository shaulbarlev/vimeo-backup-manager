import Contracts
import Foundation

/// The ObjC runtime also exports a `Category` typedef, which makes the bare name ambiguous. This alias shadows it in this module.
typealias Category = Contracts.Category

/// Display helpers. Numbers use en_US so they match the English UI on any Mac locale.
enum Format {
    static let locale = Locale(identifier: "en_US")

    /// "3,912"
    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(locale))
    }

    /// "73.0%" by default; `decimals: 0` gives "73%". Zero total gives 0.
    static func percent(_ part: Int, of total: Int, decimals: Int = 1) -> String {
        let p = total > 0 ? Double(part) * 100 / Double(total) : 0
        return String(format: "%.\(decimals)f%%", p)
    }

    /// "1.98 TB"; zero is "0 bytes", not "Zero KB".
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    /// "3 minutes ago" / "in 3 minutes"
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = locale
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func vimeoURL(_ videoID: String) -> URL? {
        URL(string: "https://vimeo.com/\(videoID)")
    }
}

/// Segment widths for the overview bar. Non-zero segments get at least `minWidth`;
/// the rest of the width is shared by count.
enum BarLayout {
    static func widths(counts: [Int], width: Double, minWidth: Double = 3) -> [Double] {
        let total = counts.reduce(0, +)
        guard total > 0 else { return counts.map { _ in 0 } }
        let visible = Double(counts.filter { $0 > 0 }.count)
        let spare = max(0, width - minWidth * visible)
        return counts.map { $0 > 0 ? minWidth + spare * Double($0) / Double(total) : 0 }
    }
}

/// Remembers when the current kind of phase began, to derive ETA and speed from its fraction and bytes.
struct ProgressClock {
    private(set) var kind: String?
    private(set) var startedAt = Date()
    /// Fraction and bytes when this kind of phase began, so resumed bytes and earlier progress
    /// don't count as speed made since then.
    private(set) var startFraction = 0.0
    private(set) var startBytes: Int64 = 0

    mutating func update(_ phase: SyncPhase?, now: Date = Date()) {
        let k = phase.map(Self.kind)
        guard k != kind else { return }
        kind = k
        startedAt = now
        startFraction = phase?.fraction ?? 0
        if case .downloading(let p) = phase { startBytes = p.bytesDownloaded } else { startBytes = 0 }
    }

    /// Linear extrapolation over progress made since the phase began; nil until there is enough signal.
    func eta(fraction: Double, now: Date = Date()) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(startedAt)
        let made = fraction - startFraction
        guard made > 0.005, fraction < 1, elapsed >= 3 else { return nil }
        return elapsed * (1 - fraction) / made
    }

    func bytesPerSecond(_ bytes: Int64, now: Date = Date()) -> Double? {
        let elapsed = now.timeIntervalSince(startedAt)
        let made = bytes - startBytes
        return elapsed >= 3 && made > 0 ? Double(made) / elapsed : nil
    }

    static func kind(_ phase: SyncPhase) -> String {
        switch phase {
        case .listingVimeo: "listing"
        case .scanningDisk: "scanning"
        case .relocating: "relocating"
        case .downloading, .throttled: "downloading" // a throttle pause is part of the same download run
        case .refreshingMetadata: "metadata"
        case .writingStatus: "status"
        }
    }
}

extension Format {
    /// "~1h 20m left", "<1m left".
    static func eta(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "<1m left" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "~\(h)h \(m)m left" : "~\(m)m left"
    }

    /// "34.2% · 12.3 MB/s · 1.2 GB so far · ~1h 20m left"; parts appear once known.
    static func progressLine(phase: SyncPhase?, clock: ProgressClock, now: Date) -> String {
        guard let phase, let fraction = phase.fraction else { return " " }
        var parts = [String(format: "%.1f%%", fraction * 100)]
        if case .downloading(let p) = phase {
            if let speed = clock.bytesPerSecond(p.bytesDownloaded, now: now) {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
            }
            if p.bytesDownloaded > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: p.bytesDownloaded, countStyle: .file) + " so far")
            }
        }
        if let left = clock.eta(fraction: fraction, now: now) { parts.append(eta(left)) }
        return parts.joined(separator: " · ")
    }
}

extension Format {
    /// "1.2 GB" when exact, "≈1.2 GB" otherwise.
    static func estimate(_ s: SizeEstimate) -> String {
        (s.exact ? "" : "≈") + bytes(s.bytes)
    }
}
