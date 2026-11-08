import Foundation
import XCTest
import Contracts

// Foundation's ObjC runtime also exports a `Category`; pin ours for the test module.
typealias Category = Contracts.Category

/// Bytes of a JSON fixture under Tests/LibraryKitTests/Fixtures (copied into the test bundle).
func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Writes a 1-second 320x240 video with the installed ffmpeg, or skips the test when there is none.
func makeTinyVideo(at url: URL) throws {
    let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ffmpeg.path), "ffmpeg not installed")
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:duration=1",
                         "-pix_fmt", "yuv420p", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "ffmpeg failed")
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vbackup-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Collects log lines in memory. Tests use it from one task at a time.
final class CollectingLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(line)
    }
}

/// Serves canned responses per URL path, in order. Records the headers of every request.
/// Only used by tests; no real network is touched.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var retryAfter: String? = nil
    }

    private static let lock = NSLock()
    private static var queues: [String: [Reply]] = [:]
    private static var requests: [(path: String, headers: [String: String])] = []

    static func reset(_ replies: [String: [Reply]]) {
        lock.lock(); defer { lock.unlock() }
        queues = replies
        requests = []
    }

    static func recorded() -> [(path: String, headers: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let reply: Reply = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.requests.append((url.path, request.allHTTPHeaderFields ?? [:]))
            guard var queue = Self.queues[url.path], !queue.isEmpty else { return Reply(status: 404, body: Data()) }
            let first = queue.removeFirst()
            Self.queues[url.path] = queue
            return first
        }()
        var headers: [String: String] = [:]
        if let retry = reply.retryAfter { headers["Retry-After"] = retry }
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
