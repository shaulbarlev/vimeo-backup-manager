import Foundation
import XCTest
@testable import VBackupApp

final class CookieExporterTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String, path: String = "/",
                        secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { props[.secure] = "TRUE" }
        if let expires { props[.expires] = expires }
        return HTTPCookie(properties: props)!
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func testNetscapeFormat() {
        // HTTPCookie clamps expiry to about 400 days, so take the expected value from the cookie itself.
        let vimeo = cookie("vimeo", "abc", domain: ".vimeo.com", secure: true,
                           expires: Date().addingTimeInterval(30 * 86_400))
        let expiry = Int(vimeo.expiresDate!.timeIntervalSince1970)
        XCTAssertEqual(CookieExporter.netscape([vimeo, cookie("locale", "en", domain: "player.vimeo.com")]), """
            # Netscape HTTP Cookie File
            .vimeo.com\tTRUE\t/\tTRUE\t\(expiry)\tvimeo\tabc
            player.vimeo.com\tFALSE\t/\tFALSE\t0\tlocale\ten

            """)
    }

    func testNetscapeEmptyHasOnlyHeader() {
        XCTAssertEqual(CookieExporter.netscape([]), "# Netscape HTTP Cookie File\n")
    }

    func testVimeoDomainFilter() {
        XCTAssertTrue(CookieExporter.isVimeo(domain: ".vimeo.com"))
        XCTAssertTrue(CookieExporter.isVimeo(domain: "vimeo.com"))
        XCTAssertTrue(CookieExporter.isVimeo(domain: "player.vimeo.com"))
        XCTAssertFalse(CookieExporter.isVimeo(domain: "notvimeo.com"))
        XCTAssertFalse(CookieExporter.isVimeo(domain: "vimeo.com.evil.net"))
        let kept = CookieExporter.vimeoCookies([
            cookie("a", "1", domain: ".vimeo.com"),
            cookie("b", "2", domain: ".google.com"),
        ])
        XCTAssertEqual(kept.map(\.name), ["a"])
    }

    func testWriteCreatesFileWith0600() throws {
        let url = try tempDir().appendingPathComponent("cookies/x.txt")
        try CookieExporter.write([cookie("vimeo", "abc", domain: ".vimeo.com")], to: url)
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "# Netscape HTTP Cookie File\n.vimeo.com\tTRUE\t/\tFALSE\t0\tvimeo\tabc\n")
    }

    func testWriteTightensAndReplacesExistingFile() throws {
        let url = try tempDir().appendingPathComponent("x.txt")
        try "stale".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try CookieExporter.write([cookie("vimeo", "new", domain: ".vimeo.com")], to: url)
        XCTAssertEqual(try permissions(url), 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("vimeo\tnew\n"))
        XCTAssertFalse(text.contains("stale"))
    }

    func testAppWideCookiesAndLegacyMigration() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("as-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = URL(fileURLWithPath: "/Volumes/Backup")
        // SHA256("/Volumes/Backup") starts with 411a8d1af1f5c783
        let legacy = CookieExporter.legacyCookiesURL(forRoot: root, appSupport: base)
        XCTAssertEqual(legacy.lastPathComponent, "411a8d1af1f5c783.txt")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "session".write(to: legacy, atomically: true, encoding: .utf8)

        CookieExporter.migrateLegacy(root: root, appSupport: base)

        let current = CookieExporter.cookiesURL(appSupport: base)
        XCTAssertEqual(current.lastPathComponent, "vimeo.txt")
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
