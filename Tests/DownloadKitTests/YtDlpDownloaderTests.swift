import Contracts
import XCTest
@testable import DownloadKit

final class YtDlpDownloaderTests: XCTestCase {
    func testParseProgress() {
        XCTAssertEqual(YtDlpDownloader.parseProgress("VBP 50 200 NA"), 0.25)
        XCTAssertEqual(YtDlpDownloader.parseProgress("VBP 50 NA 400"), 0.125, "estimate used when total is NA")
        XCTAssertEqual(YtDlpDownloader.parseProgress("VBP 300 200 NA"), 1, "clamped")
        XCTAssertNil(YtDlpDownloader.parseProgress("VBP 50 NA NA"))
        XCTAssertNil(YtDlpDownloader.parseProgress("VBP NA 200 NA"))
        XCTAssertNil(YtDlpDownloader.parseProgress("VBP 0 0 0"))
        XCTAssertNil(YtDlpDownloader.parseProgress("[download]  5.0% of 10MiB"))
    }

    func testLoggedOutFromStderr() {
        XCTAssertEqual(YtDlpDownloader.classify([
            "ERROR: [vimeo] 76979871: This video only works when logged-in. Use --cookies-from-browser or --cookies for the authentication.",
        ]), .loggedOut)
        XCTAssertEqual(YtDlpDownloader.classify(["ERROR: [vimeo] 1: login required"]), .loggedOut)
    }

    func testCookiesHintInWarningDoesNotMeanLoggedOut() {
        XCTAssertEqual(YtDlpDownloader.classify([
            "WARNING: [vimeo] Use --cookies to get the original file",
            "ERROR: [vimeo] 1: No video formats found!",
        ]), .other("ERROR: [vimeo] 1: No video formats found!"))
    }

    func testRateLimited() {
        XCTAssertEqual(YtDlpDownloader.classify([
            "WARNING: [vimeo] retrying",
            "ERROR: [vimeo] 1: Unable to download JSON metadata: HTTP Error 429: Too Many Requests",
        ]), .rateLimited)
    }

    func testGenericFailureUsesLastErrorLine() {
        XCTAssertEqual(YtDlpDownloader.classify([
            "ERROR: first attempt failed",
            "[vimeo] 1: Downloading webpage",
            "ERROR: [vimeo] 1: No video formats found!",
        ]), .other("ERROR: [vimeo] 1: No video formats found!"))
    }

    func testFailureWithoutErrorLineFallsBackToLastLine() {
        XCTAssertEqual(YtDlpDownloader.classify(["Traceback (most recent call last):", "KeyError: 'x'"]),
                       .other("KeyError: 'x'"))
    }

    func testCancelSendsSIGINTAndReturnsAfterExit() async throws {
        // A stand-in process: traps INT, prints, and exits 130. The real yt-dlp path is covered by the live test.
        let script = "trap 'echo got-int; exit 130' INT; while true; do echo tick; sleep 0.1; done"
        let task = Task { try await runTool(URL(fileURLWithPath: "/bin/sh"), ["-c", script]) }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        let run = try await task.value
        XCTAssertEqual(run.status, 130)
        XCTAssertTrue(run.stdout.contains("got-int"))
    }
}
