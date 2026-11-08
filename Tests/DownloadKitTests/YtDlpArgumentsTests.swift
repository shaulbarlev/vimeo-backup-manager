import Contracts
import XCTest
@testable import DownloadKit

final class YtDlpArgumentsTests: XCTestCase {
    private let pageURL = URL(string: "https://vimeo.com/76979871")!
    private let playerURL = URL(string: "https://player.vimeo.com/video/76979871")!

    private func request(_ quality: Quality, title: String = "Nike spot", password: String? = nil) -> DownloadRequest {
        let video = RemoteVideo(id: "76979871", title: title, folderID: nil, durationSeconds: 10, width: 1920, height: 1080,
                                privacy: "anybody", downloadAllowed: false, modified: Date(timeIntervalSince1970: 0),
                                pageURL: pageURL, playerURL: playerURL, password: password)
        return DownloadRequest(
            video: video,
            destinationDir: URL(fileURLWithPath: "/Backup/animation", isDirectory: true),
            quality: quality,
            cookies: URL(fileURLWithPath: "/tmp/cookies.txt"),
            tools: Tools(ytdlp: URL(fileURLWithPath: "/bin/yt-dlp"),
                         ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                         ffprobe: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")))
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    func testOriginalFormat() {
        let argv = YtDlpArguments.download(request(.original), url: pageURL)
        XCTAssertEqual(value(after: "-f", in: argv), "b[format_id~='(?i)^(original|source)']/bv*+ba/b")
        XCTAssertNil(value(after: "-S", in: argv))
    }

    func testCappedFormats() {
        for (quality, cap) in [(Quality.p1080, 1080), (.p720, 720), (.p540, 540), (.p360, 360)] {
            let argv = YtDlpArguments.download(request(quality), url: pageURL)
            XCTAssertEqual(value(after: "-f", in: argv), "bv*+ba/b", "\(quality)")
            XCTAssertEqual(value(after: "-S", in: argv), "res:\(cap)", "\(quality)")
        }
    }

    func testCommonArgsAndNaming() {
        let argv = YtDlpArguments.download(request(.p540), url: pageURL)
        XCTAssertEqual(value(after: "--cookies", in: argv), "/tmp/cookies.txt")
        XCTAssertEqual(value(after: "--ffmpeg-location", in: argv), "/opt/homebrew/bin")
        XCTAssertEqual(value(after: "-P", in: argv), "/Backup/animation")
        XCTAssertEqual(value(after: "-o", in: argv), "Nike spot [76979871].%(ext)s")
        for flag in ["--newline", "--no-overwrites", "--continue", "--no-playlist", "--write-info-json",
                     "--write-thumbnail", "--write-subs", "--no-write-playlist-metafiles"] {
            XCTAssertTrue(argv.contains(flag), flag)
        }
        XCTAssertEqual(value(after: "--merge-output-format", in: argv), "mp4")
        XCTAssertEqual(value(after: "--convert-thumbnails", in: argv), "jpg")
        XCTAssertEqual(value(after: "--progress-template", in: argv),
                       "download:VBP %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s")
        XCTAssertFalse(argv.contains("--skip-download"))
    }

    func testURLIsLastAndPlayerURLIsUsedWhenAsked() {
        XCTAssertEqual(YtDlpArguments.download(request(.p1080), url: pageURL).last, "https://vimeo.com/76979871")
        XCTAssertEqual(YtDlpArguments.download(request(.p1080), url: playerURL).last,
                       "https://player.vimeo.com/video/76979871")
    }

    func testPercentInTitleIsEscapedForTheTemplate() {
        let argv = YtDlpArguments.download(request(.p1080, title: "100% sure"), url: pageURL)
        XCTAssertEqual(value(after: "-o", in: argv), "100%% sure [76979871].%(ext)s")
    }

    func testPasswordIsPassedAndRedacted() {
        let argv = YtDlpArguments.download(request(.p1080, password: "s3cret"), url: pageURL)
        XCTAssertEqual(value(after: "--video-password", in: argv), "s3cret")

        let redacted = YtDlpArguments.redacted(argv)
        XCTAssertEqual(value(after: "--video-password", in: redacted), "***")
        XCTAssertFalse(redacted.contains("s3cret"))
        XCTAssertEqual(redacted.count, argv.count)
    }

    func testNoPasswordNoFlag() {
        let argv = YtDlpArguments.download(request(.p1080), url: pageURL)
        XCTAssertFalse(argv.contains("--video-password"))
        XCTAssertEqual(YtDlpArguments.redacted(argv), argv)
    }

    func testMetadataVariantSkipsDownloadAndFormats() {
        let argv = YtDlpArguments.metadata(request(.p540, password: "pw"), url: playerURL)
        XCTAssertTrue(argv.contains("--skip-download"))
        XCTAssertNil(value(after: "-f", in: argv))
        XCTAssertNil(value(after: "-S", in: argv))
        // Refresh must rewrite info.json, which --no-overwrites would keep.
        XCTAssertFalse(argv.contains("--no-overwrites"))
        XCTAssertTrue(argv.contains("--write-info-json"))
        XCTAssertEqual(value(after: "-o", in: argv), "Nike spot [76979871].%(ext)s")
        XCTAssertEqual(value(after: "--video-password", in: argv), "pw")
        XCTAssertEqual(argv.last, "https://player.vimeo.com/video/76979871")
    }
}
