import XCTest
import Contracts
@testable import LibraryKit

final class VimeoParsingTests: XCTestCase {
    func testFoldersPageParentFromLastAncestor() throws {
        let page = try VimeoParsing.folders(try fixture("folders_page"))
        XCTAssertNil(page.next)
        XCTAssertEqual(page.items, [
            RemoteFolder(id: "500001", name: "360", parentID: nil),
            RemoteFolder(id: "500002", name: "sub", parentID: "500001"),
            RemoteFolder(id: "500003", name: "commercials", parentID: nil),
        ])
    }

    func testVideoPageMapsFieldsAndFollowsPaging() throws {
        let p1 = try VimeoParsing.videos(try fixture("videos_page1"))
        XCTAssertEqual(p1.next, "/me/videos?page=2&per_page=2&fields=uri,name")
        XCTAssertEqual(p1.items.count, 2)

        let first = p1.items[0]
        XCTAssertEqual(first.id, "1000000001")
        XCTAssertEqual(first.title, "sample clip 1")
        XCTAssertEqual(first.folderID, "500001")
        XCTAssertEqual(first.durationSeconds, 28)
        XCTAssertEqual(first.width, 1080)
        XCTAssertEqual(first.height, 1920)
        XCTAssertEqual(first.shortSide, 1080)
        XCTAssertEqual(first.privacy, "unlisted")
        XCTAssertTrue(first.downloadAllowed)
        XCTAssertEqual(first.pageURL.absoluteString, "https://vimeo.com/1000000001/a1b2c3d4e5")
        XCTAssertEqual(first.playerURL.absoluteString, "https://player.vimeo.com/video/1000000001?h=a1b2c3d4e5")
        XCTAssertEqual(first.modified, ISO8601DateFormatter().date(from: "2026-11-04T14:15:48Z"))

        let second = p1.items[1]
        XCTAssertEqual(second.id, "1000000002")
        XCTAssertNil(second.folderID, "parent_folder null means _Unsorted")
        XCTAssertFalse(second.downloadAllowed)
        XCTAssertNil(second.password, "password is kept only for privacy == password")
    }

    func testLastVideoPageHasNoNextAndKeepsPassword() throws {
        let p2 = try VimeoParsing.videos(try fixture("videos_page2"))
        XCTAssertNil(p2.next)
        XCTAssertEqual(p2.items.map(\.id), ["900000001"])
        XCTAssertEqual(p2.items[0].password, "hunter2")
        XCTAssertEqual(p2.items[0].folderID, "500002")
    }

    func testPagesChainViaNextLinks() throws {
        // Two pages, end to end through the parsers: page 1 names page 2 and page 2 ends the chain.
        let p1 = try VimeoParsing.videos(try fixture("videos_page1"))
        let p2 = try VimeoParsing.videos(try fixture("videos_page2"))
        let all = p1.items + p2.items
        XCTAssertEqual(all.count, 3)
        XCTAssertNotNil(p1.next)
        XCTAssertNil(p2.next)
        XCTAssertEqual(Set(all.map(\.id)).count, 3)
    }

    func testViewerWithJWT() throws {
        let jwt = try VimeoParsing.jwt(viewer: try fixture("viewer_ok"))
        XCTAssertTrue(jwt.hasPrefix("eyJ"))
    }

    func testLoggedOutViewerThrows() throws {
        XCTAssertThrowsError(try VimeoParsing.jwt(viewer: try fixture("viewer_logged_out"))) { error in
            XCTAssertEqual(error as? VBackupError, .loggedOut)
        }
        XCTAssertThrowsError(try VimeoParsing.jwt(viewer: Data("<html>not json</html>".utf8))) { error in
            XCTAssertEqual(error as? VBackupError, .loggedOut)
        }
    }

    func testAccountName() throws {
        XCTAssertEqual(try VimeoParsing.accountName(me: try fixture("me")), "Fixture Account")
    }

    func testMalformedListingIsVimeoError() {
        XCTAssertThrowsError(try VimeoParsing.videos(Data("{}".utf8))) { error in
            guard case VBackupError.vimeo = error else { return XCTFail("expected .vimeo, got \(error)") }
        }
    }

    func testJWTExpiryReadsExpClaim() {
        // Unsigned token with payload {"exp":1700000000}, base64url without padding.
        let payload = Data(#"{"exp":1700000000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        XCTAssertEqual(VimeoParsing.jwtExpiry(token), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(VimeoParsing.jwtExpiry("not-a-jwt"))
    }

    func testCookieHeaderKeepsOnlyVimeoCookies() {
        let netscape = """
        # Netscape HTTP Cookie File
        .vimeo.com\tTRUE\t/\tTRUE\t0\tvimeo\tsession-value
        #HttpOnly_vimeo.com\tTRUE\t/\tTRUE\t1893456000\tvuid\tabc
        .example.com\tTRUE\t/\tFALSE\t0\tother\tzzz

        """
        XCTAssertEqual(VimeoParsing.cookieHeader(netscape: netscape), "vimeo=session-value; vuid=abc")
        XCTAssertEqual(VimeoParsing.cookieHeader(netscape: "# only a header\n"), "")
    }

    func testRetryDelayHonorsHeaderThenDoubles() {
        XCTAssertEqual(VimeoParsing.retryDelay(retryAfter: "17", attempt: 1), 17)
        XCTAssertEqual(VimeoParsing.retryDelay(retryAfter: nil, attempt: 1), 60)
        XCTAssertEqual(VimeoParsing.retryDelay(retryAfter: nil, attempt: 2), 120)
        XCTAssertEqual(VimeoParsing.retryDelay(retryAfter: nil, attempt: 3), 240)
        XCTAssertEqual(VimeoParsing.retryDelay(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", attempt: 1), 60)
    }
}
