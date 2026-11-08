import CryptoKit
import Foundation

/// Writes the signed-in Vimeo cookies as a Netscape cookies.txt for yt-dlp.
enum CookieExporter {
    /// `~/Library/Application Support/vbackup`
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vbackup", isDirectory: true)
    }

    /// The app-wide Vimeo session: `<appSupport>/cookies/vimeo.txt`.
    static func cookiesURL(appSupport: URL = appSupport) -> URL {
        appSupport.appendingPathComponent("cookies/vimeo.txt")
    }

    /// Versions up to 1.0.0 kept one session per backup folder. Adopts that file as the app-wide one.
    static func migrateLegacy(root: URL?, appSupport: URL = appSupport) {
        let fm = FileManager.default
        let current = cookiesURL(appSupport: appSupport)
        guard let root, !fm.fileExists(atPath: current.path) else { return }
        let legacy = legacyCookiesURL(forRoot: root, appSupport: appSupport)
        if fm.fileExists(atPath: legacy.path) { try? fm.moveItem(at: legacy, to: current) }
    }

    /// `<appSupport>/cookies/<first 16 hex of SHA256(root path)>.txt` (per-folder sessions, before 1.1).
    static func legacyCookiesURL(forRoot root: URL, appSupport: URL = appSupport) -> URL {
        let digest = SHA256.hash(data: Data(root.path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return appSupport.appendingPathComponent("cookies/\(hex).txt")
    }

    /// vimeo.com and any subdomain (".vimeo.com", "player.vimeo.com").
    static func isVimeo(domain: String) -> Bool {
        let d = domain.lowercased()
        return d == "vimeo.com" || d.hasSuffix(".vimeo.com")
    }

    static func vimeoCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { isVimeo(domain: $0.domain) }
    }

    /// Netscape format: `domain TRUE|FALSE path TRUE|FALSE expiry name value`, tab-separated.
    /// The subdomain flag is TRUE when the domain starts with ".". Session cookies get expiry 0.
    static func netscape(_ cookies: [HTTPCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies {
            let fields = [
                c.domain,
                c.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                c.path,
                c.isSecure ? "TRUE" : "FALSE",
                String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)),
                c.name,
                c.value,
            ]
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the file with mode 0600, also when it already exists with looser permissions.
    /// The mode is set before the contents are written.
    static func write(_ cookies: [HTTPCookie], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Data(netscape(cookies).utf8).write(to: url)
    }
}
