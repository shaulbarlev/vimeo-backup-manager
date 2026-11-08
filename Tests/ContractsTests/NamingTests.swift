import XCTest
@testable import Contracts

final class NamingTests: XCTestCase {
    func testIDRoundTrip() {
        let stem = Naming.fileStem(title: "Nike: spot/v2", id: "1000000002", qualityTag: "1080p")
        XCTAssertEqual(stem, "Nike_ spot_v2 [1000000002] [1080p]")
        XCTAssertEqual(Naming.videoID(fromFilename: stem + ".mp4"), "1000000002")
        XCTAssertEqual(Naming.videoID(fromFilename: Naming.base(title: "a [1] b", id: "123456") + ".info.json"), "123456")
        XCTAssertEqual(Naming.videoID(fromFilename: "x [123456].en.vtt"), "123456")
        XCTAssertNil(Naming.videoID(fromFilename: "random.mp4"))
    }

    func testOriginal() {
        XCTAssertTrue(Naming.isOriginalFormatID("Original"))
        XCTAssertTrue(Naming.isOriginalFormatID("source"))
        XCTAssertFalse(Naming.isOriginalFormatID("hls-fastly_skyfire-audio-high-Original"))
        XCTAssertFalse(Naming.isOriginalFormatID("hls-fastly_skyfire-4866"))
    }

    func testFolderPath() {
        let f = ["1": RemoteFolder(id: "1", name: "animation", parentID: nil),
                 "2": RemoteFolder(id: "2", name: "sub", parentID: "1")]
        XCTAssertEqual(Naming.folderPath(folderID: "2", folders: f), "animation/sub")
        XCTAssertEqual(Naming.folderPath(folderID: nil, folders: f), "_Unsorted")
        XCTAssertEqual(Naming.folderPath(folderID: "999", folders: f), "_Unsorted")
    }

    func testSafeCapsUTF8BytesForLongNonLatinTitles() {
        let hebrew = String(repeating: "א", count: 200)            // 400 UTF-8 bytes
        let name = Naming.fileStem(title: hebrew, id: "1000000001", qualityTag: "orig") + ".mp4.part"
        XCTAssertLessThanOrEqual(name.utf8.count, 255, "APFS name limit")
        XCTAssertLessThanOrEqual(Naming.safe("😀" + String(repeating: "x", count: 300)).utf8.count, 150)
    }
}
