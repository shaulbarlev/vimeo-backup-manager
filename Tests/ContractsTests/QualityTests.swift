import XCTest
@testable import Contracts

final class QualityTests: XCTestCase {
    let r: [Rendition] = [
        Rendition(name: "source", width: 3840, height: 2160, size: 900, md5: "m"),
        Rendition(name: "2160p", width: 3840, height: 2160, size: 500),
        Rendition(name: "1080p", width: 1920, height: 1080, size: 200),
        Rendition(name: "720p", width: 1280, height: 720, size: 100),
        Rendition(name: "360p", width: 640, height: 360, size: 30),
    ]

    func testPick() {
        XCTAssertEqual(Quality.original.pick(r)?.name, "source")
        XCTAssertEqual(Quality.p1080.pick(r)?.name, "1080p")
        XCTAssertEqual(Quality.p540.pick(r)?.name, "360p", "no 540p: next lower")
        XCTAssertEqual(Quality.p360.pick(Array(r.prefix(3)))?.name, "1080p", "nothing small enough: smallest")
        XCTAssertEqual(Quality.original.pick(Array(r.dropFirst()))?.name, "2160p", "no source: largest")
        XCTAssertNil(Quality.p720.pick([]))
    }

    func testVerticalVideoUsesShortSide() {
        let v = [Rendition(name: "1080p", width: 1080, height: 1920, size: 1), Rendition(name: "720p", width: 720, height: 1280, size: 1)]
        XCTAssertEqual(Quality.p1080.pick(v)?.name, "1080p")
    }

    func testSizeExactOnlyForSource() {
        let video = RemoteVideo(id: "1", title: "t", folderID: nil, durationSeconds: 100, width: 3840, height: 2160,
                                privacy: "anybody", downloadAllowed: true, modified: .distantPast, renditions: r,
                                pageURL: URL(string: "https://vimeo.com/1")!, playerURL: URL(string: "https://player.vimeo.com/video/1")!)
        XCTAssertEqual(Quality.original.size(of: video), SizeEstimate(bytes: 900, exact: true))
        XCTAssertEqual(Quality.p720.size(of: video), SizeEstimate(bytes: 100, exact: false))
        var bare = video
        bare.renditions = []
        XCTAssertEqual(Quality.p1080.size(of: bare), SizeEstimate(bytes: 100 * 8 * 125_000, exact: false))
    }

    func testScope() {
        func state(_ id: String, folder: String, day: Double) -> VideoState {
            let v = RemoteVideo(id: id, title: id, folderID: nil, durationSeconds: 1, width: 1, height: 1, privacy: "x",
                                downloadAllowed: true, modified: .distantPast, created: Date(timeIntervalSince1970: day * 86_400),
                                pageURL: URL(string: "https://vimeo.com/1")!, playerURL: URL(string: "https://vimeo.com/1")!)
            return VideoState(video: v, folderPath: folder, category: .missing, local: nil, sizeMismatch: false)
        }
        let a = state("a", folder: "x", day: 10), b = state("b", folder: "y", day: 20), c = state("c", folder: "x", day: 30)
        let scope = DownloadScope(folderPaths: ["x"], from: Date(timeIntervalSince1970: 10 * 86_400),
                                  to: Date(timeIntervalSince1970: 20 * 86_400), excludedIDs: [])
        XCTAssertEqual([a, b, c].filter(scope.matches).map(\.id), ["a"], "inclusive bounds, folder filter")
        var excluded = scope
        excluded.excludedIDs = ["a"]
        XCTAssertTrue(excluded.inRange(a))
        XCTAssertFalse(excluded.matches(a))
        XCTAssertEqual([a, b, c].filter(DownloadScope().matches).count, 3)
    }

    func testQualityTagFromFilename() {
        XCTAssertEqual(Naming.qualityTag(fromFilename: "Nike [1000000002] [orig].mp4"), "orig")
        XCTAssertEqual(Naming.qualityTag(fromFilename: "a [b] c [123456] [1080p].mov"), "1080p")
        XCTAssertNil(Naming.qualityTag(fromFilename: "Nike [1000000002].info.json"))
    }
}
