import XCTest
import Contracts
@testable import LibraryKit

/// End-to-end fetchLibrary through a URLProtocol stub. The stub replays fixture bodies per path.
final class VimeoWebClientTests: XCTestCase {
    private var cookies: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vbackup-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cookies = dir.appendingPathComponent("cookies.txt")
        try "# Netscape HTTP Cookie File\n.vimeo.com\tTRUE\t/\tTRUE\t0\tvimeo\tsession-value\n"
            .write(to: cookies, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cookies.deletingLastPathComponent())
    }

    private func client() -> VimeoWebClient {
        VimeoWebClient(cookiesFile: cookies, session: StubProtocol.session())
    }

    private func reply(_ name: String, status: Int = 200, retryAfter: String? = nil) throws -> StubProtocol.Reply {
        StubProtocol.Reply(status: status, body: try fixture(name), retryAfter: retryAfter)
    }

    func testFetchLibraryFollowsPagesAndSendsJWT() async throws {
        StubProtocol.reset([
            "/_next/viewer": [try reply("viewer_ok")],
            "/me": [try reply("me")],
            "/me/projects": [try reply("folders_page")],
            "/me/videos": [try reply("videos_page1"), try reply("videos_page2")],
        ])
        let pages = PageLog()
        let lib = try await client().fetchLibrary(log: CollectingLog()) { done, total in pages.add(done, total) }

        XCTAssertEqual(pages.all.map(\.0), [2, 3], "progress after each video page")
        XCTAssertEqual(pages.all.first?.1, 3, "library total read from the page")
        XCTAssertEqual(lib.accountName, "Fixture Account")
        XCTAssertEqual(lib.folders.count, 3)
        XCTAssertEqual(lib.videos.map(\.id), ["1000000001", "1000000002", "900000001"])

        let calls = StubProtocol.recorded()
        XCTAssertEqual(calls.map(\.path), ["/_next/viewer", "/me", "/me/projects", "/me/videos", "/me/videos"])
        XCTAssertEqual(calls[0].headers["Cookie"], "vimeo=session-value")
        XCTAssertEqual(calls[0].headers["Accept"], "application/json")
        XCTAssertTrue(calls[1].headers["Authorization"]?.hasPrefix("jwt eyJ") == true)
        XCTAssertEqual(calls[1].headers["Accept"], "application/vnd.vimeo.*+json;version=3.4")
        XCTAssertNotNil(calls[1].headers["User-Agent"])
    }

    func testLoggedOutViewerThrows() async throws {
        StubProtocol.reset(["/_next/viewer": [try reply("viewer_logged_out")]])
        await assertLoggedOut { try await self.client().fetchLibrary(log: CollectingLog()) }
    }

    func testUnauthorizedAPIThrowsLoggedOut() async throws {
        StubProtocol.reset([
            "/_next/viewer": [try reply("viewer_ok")],
            "/me": [try reply("me", status: 401)],
        ])
        await assertLoggedOut { try await self.client().fetchLibrary(log: CollectingLog()) }
    }

    func testMissingCookiesFileThrowsLoggedOutWithoutNetwork() async throws {
        try FileManager.default.removeItem(at: cookies)
        StubProtocol.reset([:])
        await assertLoggedOut { try await self.client().fetchLibrary(log: CollectingLog()) }
        XCTAssertTrue(StubProtocol.recorded().isEmpty)
    }

    func testThrottledThenSucceeds() async throws {
        StubProtocol.reset([
            "/_next/viewer": [try reply("viewer_ok")],
            "/me": [try reply("me", status: 429, retryAfter: "0"), try reply("me")],
            "/me/projects": [try reply("folders_page")],
            "/me/videos": [try reply("videos_page1"), try reply("videos_page2")],
        ])
        let log = CollectingLog()
        let lib = try await client().fetchLibrary(log: log)
        XCTAssertEqual(lib.accountName, "Fixture Account")
        XCTAssertEqual(StubProtocol.recorded().filter { $0.path == "/me" }.count, 2)
        XCTAssertTrue(log.lines.contains { $0.contains("429 on /me") })
    }

    func testThrottleGivesUpAfterFiveTries() async throws {
        StubProtocol.reset([
            "/_next/viewer": [try reply("viewer_ok")],
            "/me": Array(repeating: try reply("me", status: 429, retryAfter: "0"), count: 5),
        ])
        do {
            _ = try await client().fetchLibrary(log: CollectingLog())
            XCTFail("expected throttled")
        } catch {
            XCTAssertEqual(error as? VBackupError, .throttled(retryAfter: 0))
        }
        XCTAssertEqual(StubProtocol.recorded().filter { $0.path == "/me" }.count, 5)
    }

    /// Optional live check. Runs only with VBACKUP_COOKIES=/path/to/cookies.txt and prints counts only.
    func testLiveListingWhenCookiesProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["VBACKUP_COOKIES"] else {
            throw XCTSkip("set VBACKUP_COOKIES to run the live check")
        }
        let lib = try await VimeoWebClient(cookiesFile: URL(fileURLWithPath: path)).fetchLibrary(log: CollectingLog())
        print("live check: \(lib.folders.count) folders, \(lib.videos.count) videos")
    }

    private func assertLoggedOut<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected loggedOut", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VBackupError, .loggedOut, file: file, line: line)
        }
    }
}

final class PageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int?)] = []
    func add(_ done: Int, _ total: Int?) { lock.withLock { items.append((done, total)) } }
    var all: [(Int, Int?)] { lock.withLock { items } }
}
