import XCTest
import Contracts
@testable import LibraryKit

final class ClassifierTests: XCTestCase {
    static let sourceSize: Int64 = 112_291_037

    /// A 1080p video whose source is `sourceSize` bytes, with 1080p/720p renditions (listed sizes, slightly high).
    private func video(_ id: String, w: Int = 1920, h: Int = 1080, seconds: Int = 10, folder: String? = nil,
                       renditions: [Rendition]? = nil) -> RemoteVideo {
        RemoteVideo(id: id, title: "title \(id)", folderID: folder, durationSeconds: seconds, width: w, height: h,
                    privacy: "anybody", downloadAllowed: true, modified: Date(timeIntervalSince1970: 0),
                    renditions: renditions ?? [
                        Rendition(name: "source", width: w, height: h, size: Self.sourceSize, md5: "abc"),
                        Rendition(name: "1080p", width: 1920, height: 1080, size: 17_964_875),
                        Rendition(name: "720p", width: 1280, height: 720, size: 9_307_321),
                    ],
                    pageURL: URL(string: "https://vimeo.com/\(id)")!, playerURL: URL(string: "https://player.vimeo.com/video/\(id)")!)
    }

    private func local(_ id: String, w: Int = 1920, h: Int = 1080, tag: String = "1080p",
                       videoBytes: Int64 = 1_000_000, sidecars: Int64 = 0) -> LocalFile {
        LocalFile(videoID: id, url: URL(fileURLWithPath: "/root/x [\(id)] [\(tag)].mp4"), sizeBytes: videoBytes + sidecars,
                  videoBytes: videoBytes, width: w, height: h, modified: Date(timeIntervalSince1970: 0))
    }

    private func original(_ id: String) -> LocalFile { local(id, tag: "orig", videoBytes: Self.sourceSize) }

    private func library(_ videos: [RemoteVideo], folders: [RemoteFolder] = []) -> RemoteLibrary {
        RemoteLibrary(accountName: "acct", folders: folders, videos: videos, fetchedAt: Date(timeIntervalSince1970: 100))
    }

    private func cat(_ v: RemoteVideo, _ l: LocalFile?, unreachable: Bool = false) -> Category {
        Classifier.category(for: v, local: l, unreachable: unreachable).0
    }

    // MARK: - Category rules

    func testExactSourceSizeIsOriginalWhateverTheName() {
        XCTAssertEqual(cat(video("1"), original("1")), .original)
        XCTAssertEqual(cat(video("1"), local("1", tag: "1080p", videoBytes: Self.sourceSize)), .original, "size decides, not the tag")
    }

    func testOrigTagWithWrongSizeIsABrokenOriginal() {
        let (category, mismatch) = Classifier.category(for: video("1"), local: local("1", tag: "orig", videoBytes: 5), unreachable: false)
        XCTAssertEqual(category, .missing)
        XCTAssertTrue(mismatch)
    }

    func testOrigTagWithoutListedSourceIsTrusted() {
        XCTAssertEqual(cat(video("1", renditions: []), local("1", tag: "orig")), .original)
    }

    func testNoLocalIsMissingUnlessFailureRecorded() {
        XCTAssertEqual(cat(video("1"), nil), .missing)
        XCTAssertEqual(cat(video("1"), nil, unreachable: true), .unreachable)
    }

    func testRenditionAtSourceResolutionIsFull() {
        XCTAssertEqual(cat(video("1"), local("1", h: 1080)), .fullResolution)
    }

    func testResolutionToleranceBoundary() {
        XCTAssertEqual(cat(video("1"), local("1", h: 1059)), .fullResolution) // 1059 >= 1058.4
        XCTAssertEqual(cat(video("1"), local("1", h: 1058)), .lower)
    }

    func testSmallerThanSourceIsLower() {
        XCTAssertEqual(cat(video("1"), local("1", w: 1280, h: 720, tag: "720p")), .lower)
    }

    func testVerticalVideoUsesShortSide() {
        XCTAssertEqual(cat(video("1", w: 1080, h: 1920), local("1", w: 1080, h: 1920)), .fullResolution)
        XCTAssertEqual(cat(video("1", w: 1080, h: 1920), local("1", w: 720, h: 1280)), .lower)
    }

    // MARK: - Summary

    func testSummaryCountsBytesAndEveryCategory() {
        let lib = library([video("a"), video("b"), video("c"), video("d"), video("e")])
        let locals = [
            local("a", tag: "orig", videoBytes: Self.sourceSize, sidecars: 10),
            local("b", videoBytes: 200),
            local("c", w: 960, h: 540, videoBytes: 300),
        ]
        let s = Classifier.classify(lib, locals, failures: ["e": "HTTP Error 403"])

        XCTAssertEqual(s.stats[.original], CategoryStat(count: 1, bytes: Self.sourceSize + 10))
        XCTAssertEqual(s.stats[.fullResolution], CategoryStat(count: 1, bytes: 200))
        XCTAssertEqual(s.stats[.lower], CategoryStat(count: 1, bytes: 300))
        XCTAssertEqual(s.stats[.missing], CategoryStat(count: 1, bytes: 0))
        XCTAssertEqual(s.stats[.unreachable], CategoryStat(count: 1, bytes: 0))
        XCTAssertEqual(Set(s.stats.keys), Set(Category.allCases), "every category key present")
        XCTAssertEqual(s.completeCount, 2)
        XCTAssertEqual(s.videos.map(\.id), ["a", "b", "c", "d", "e"], "every video, listing order")
        XCTAssertEqual(s.videos.first?.category, .original)
    }

    func testMissingSizeIsExactSumOfSources() {
        let lib = library([video("a"), video("m"), video("u")])
        let s = Classifier.classify(lib, [original("a")], failures: ["u": "x"])
        XCTAssertEqual(s.missing, SizeEstimate(bytes: 2 * Self.sourceSize, exact: true))
    }

    func testMissingSizeWithoutListedFilesIsAnEstimate() {
        let s = Classifier.classify(library([video("m", seconds: 10, renditions: [])]), [], failures: [:])
        XCTAssertFalse(s.missing.exact)
        XCTAssertEqual(s.missing.bytes, 10 * 20 * 125_000) // 10 s at the nominal 20 Mbit/s for originals
    }

    func testMismatchIsListedAndReported() {
        let s = Classifier.classify(library([video("a")]), [local("a", tag: "orig", videoBytes: 1)], failures: [:])
        XCTAssertEqual(s.mismatchedIDs, ["a"])
        XCTAssertEqual(s.stats[.missing]?.count, 1)
        XCTAssertEqual(s.problems.count, 1)
    }

    func testFailuresListOnlyUnreachableWithReasons() {
        let s = Classifier.classify(library([video("a"), video("b")]), [local("a")],
                                    failures: ["b": "Private video", "gone": "ignored: not on Vimeo"])
        XCTAssertEqual(s.failures, [Failure(videoID: "b", title: "title b", reason: "Private video")])
    }

    func testLocalOnlyIsNotInTotals() {
        let s = Classifier.classify(library([video("a")]), [local("a"), local("999", videoBytes: 4_000)], failures: [:])
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.localOnly.map(\.videoID), ["999"])
        XCTAssertEqual(s.localBytes, 1_000_000 + 4_000)
    }

    func testFolderSummariesHaveEveryKeyAndSortUnsortedLast() {
        let folders = [
            RemoteFolder(id: "1", name: "zoo", parentID: nil),
            RemoteFolder(id: "2", name: "animation", parentID: nil),
            RemoteFolder(id: "3", name: "sub", parentID: "2"),
        ]
        let lib = library([video("a", folder: "1"), video("b", folder: "3"), video("c"), video("d", folder: "unknown")],
                          folders: folders)
        let s = Classifier.classify(lib, [local("a")], failures: [:])
        XCTAssertEqual(s.folders.map(\.path), ["animation/sub", "zoo", "_Unsorted"])
        for f in s.folders { XCTAssertEqual(Set(f.stats.keys), Set(Category.allCases), f.path) }
        XCTAssertEqual(s.folders[1].stats[.fullResolution]?.count, 1)
        XCTAssertEqual(s.folders[2].stats[.missing]?.count, 2)
        XCTAssertEqual(s.videos.first { $0.id == "b" }?.folderPath, "animation/sub")
    }

    // MARK: - Needs download (shared rule)

    func testNeedsDownload() {
        func state(_ l: LocalFile?) -> VideoState {
            let (c, m) = Classifier.category(for: video("1"), local: l, unreachable: false)
            return VideoState(video: video("1"), folderPath: "", category: c, local: l, sizeMismatch: m)
        }
        XCTAssertTrue(state(nil).needsDownload(.p360))
        XCTAssertFalse(state(original("1")).needsDownload(.original), "original is the best there is")
        XCTAssertFalse(state(original("1")).needsDownload(.p720))
        XCTAssertTrue(state(local("1")).needsDownload(.original), "1080p copy, original requested")
        XCTAssertFalse(state(local("1")).needsDownload(.p1080))
        XCTAssertFalse(state(local("1")).needsDownload(.p720))
        XCTAssertTrue(state(local("1", w: 1280, h: 720)).needsDownload(.p1080))
        XCTAssertTrue(state(local("1", tag: "orig", videoBytes: 1)).needsDownload(.p360), "broken original")

        // No listed source: the best available counts as done for Original, so it isn't fetched every run.
        let bare = video("2", renditions: [])
        let (c, m) = Classifier.category(for: bare, local: local("2"), unreachable: false)
        XCTAssertFalse(VideoState(video: bare, folderPath: "", category: c, local: local("2"), sizeMismatch: m).needsDownload(.original))
    }

    // MARK: - Helpers and disk-only

    func testBestLocalPerIDIsLargestShortSideThenBytes() {
        let best = Classifier.bestLocalByID([local("a", w: 640, h: 360), local("a", videoBytes: 5), local("a", videoBytes: 9)])
        XCTAssertEqual(best["a"]?.videoBytes, 9)
    }

    func testDiskOnlySummaryHasNoVimeoData() {
        let s = Classifier.diskOnly(accountName: "", [local("a", tag: "orig", videoBytes: 10), local("b", videoBytes: 20)],
                                    diskScannedAt: Date(timeIntervalSince1970: 5), problems: ["Vimeo listing failed: boom"])
        XCTAssertEqual(s.stats[.original], CategoryStat(count: 1, bytes: 10))
        XCTAssertEqual(s.stats[.fullResolution], CategoryStat(count: 1, bytes: 20))
        XCTAssertNil(s.vimeoCheckedAt)
        XCTAssertEqual(s.problems, ["Vimeo listing failed: boom"])
        XCTAssertTrue(s.folders.isEmpty)
    }
}
