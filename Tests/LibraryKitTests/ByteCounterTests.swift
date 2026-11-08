import XCTest
@testable import LibraryKit

final class ByteCounterTests: XCTestCase {
    func testStreamResetsAccumulate() {
        let c = ByteCounter()
        c.update(100); c.update(300)      // video stream
        c.update(50)                      // audio stream restarts the count
        XCTAssertEqual(c.total, 350)
        c.finishVideo()
        c.update(10)                      // next video
        XCTAssertEqual(c.total, 360)
    }
}
