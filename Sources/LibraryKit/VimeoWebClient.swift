import Foundation
import Contracts

/// Lists the signed-in account's folders and videos through the web session:
/// cookies -> vimeo.com/_next/viewer (jwt) -> api.vimeo.com.
public struct VimeoWebClient: Sendable {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    static let maxTries = 5
    static let viewerURL = URL(string: "https://vimeo.com/_next/viewer")!
    static let videoFields = "uri,name,description,link,player_embed_url,duration,width,height,modified_time,created_time,privacy.view,privacy.download,parent_folder.uri,password,download.rendition,download.public_name,download.width,download.height,download.size,download.md5,download.link"

    public let cookiesFile: URL
    public let session: URLSession

    public init(cookiesFile: URL, session: URLSession = .shared) {
        self.cookiesFile = cookiesFile
        self.session = session
    }

    /// `onProgress(videosListed, libraryTotal)` fires after every page of videos.
    public func fetchLibrary(log: LogSink,
                             onProgress: @escaping @Sendable (Int, Int?) -> Void = { _, _ in }) async throws -> RemoteLibrary {
        let cookieText = (try? String(contentsOf: cookiesFile, encoding: .utf8)) ?? ""
        let cookies = VimeoParsing.cookieHeader(netscape: cookieText)
        guard !cookies.isEmpty else { throw VBackupError.loggedOut }

        let firstToken = try await sessionToken(cookies: cookies, log: log)
        let tokens = TokenBox(first: (firstToken.jwt, firstToken.expires)) {
            let t = try await self.sessionToken(cookies: cookies, log: log)
            return (t.jwt, t.expires)
        }

        // Authorized GET. The jwt is short-lived; the box refreshes it (once, even with parallel callers).
        @Sendable func api(_ url: URL) async throws -> Data {
            try await send(url, headers: [
                "Authorization": "jwt \(try await tokens.jwt())",
                "Accept": "application/vnd.vimeo.*+json;version=3.4",
            ], log: log)
        }

        // Follows paging.next until null. A repeated URL stops the loop instead of spinning.
        func paged<T>(_ first: URL, onPage: (Int, Int?) -> Void = { _, _ in },
                      _ parse: (Data) throws -> (items: [T], next: String?)) async throws -> [T] {
            var out: [T] = []
            var seen = Set<URL>()
            var next: URL? = first
            while let url = next, seen.insert(url).inserted {
                let data = try await api(url)
                let page = try parse(data)
                out += page.items
                let total = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["total"] as? Int
                onPage(out.count, total)
                next = page.next.flatMap { URL(string: $0, relativeTo: VimeoParsing.apiBase)?.absoluteURL }
            }
            return out
        }

        let name = try VimeoParsing.accountName(me: try await api(apiURL("/me?fields=name")))
        let folders = try await paged(apiURL("/me/projects?per_page=100&fields=uri,name,metadata.connections.ancestor_path")) {
            try VimeoParsing.folders($0)
        }
        log.log("vimeo: listed \(folders.count) folders")
        let videos = try await parallelPages(apiURL("/me/videos?per_page=\(Self.pageSize)&fields=\(Self.videoFields)"),
                                             api: api, onProgress: onProgress)
        log.log("vimeo: listed \(videos.count) videos")
        return RemoteLibrary(accountName: name, folders: folders, videos: videos, fetchedAt: Date())
    }

    /// One video with fresh (signed, expiring) download links.
    public func fetchVideo(id: String, log: LogSink) async throws -> RemoteVideo {
        let cookies = VimeoParsing.cookieHeader(netscape: (try? String(contentsOf: cookiesFile, encoding: .utf8)) ?? "")
        guard !cookies.isEmpty else { throw VBackupError.loggedOut }
        let token = try await sessionToken(cookies: cookies, log: log)
        let data = try await send(apiURL("/videos/\(id)?fields=\(Self.videoFields)"), headers: [
            "Authorization": "jwt \(token.jwt)",
            "Accept": "application/vnd.vimeo.*+json;version=3.4",
        ], log: log)
        return try VimeoParsing.video(data)
    }

    static let pageSize = 100
    static let parallelRequests = 12

    /// Page 1 gives the total; pages 2...N are fetched `parallelRequests` at a time and reassembled in order.
    /// A video uploaded mid-listing can shift pages by one, so ids are de-duplicated (first wins).
    private func parallelPages(_ base: URL, api: @escaping @Sendable (URL) async throws -> Data,
                               onProgress: @escaping @Sendable (Int, Int?) -> Void) async throws -> [RemoteVideo] {
        let first = try await api(base)
        let firstPage = try VimeoParsing.videos(first)
        let json = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any]
        let total = json?["total"] as? Int
        let perPage = max(1, (json?["per_page"] as? Int) ?? Self.pageSize)
        onProgress(firstPage.items.count, total)
        guard firstPage.next != nil, let total, total > perPage else { return firstPage.items }

        let pageCount = (total + perPage - 1) / perPage
        let listed = PageCounter(firstPage.items.count)
        var pages: [Int: [RemoteVideo]] = [1: firstPage.items]
        try await withThrowingTaskGroup(of: (Int, [RemoteVideo]).self) { group in
            var nextPage = 2
            func addNext() {
                guard nextPage <= pageCount else { return }
                let page = nextPage
                nextPage += 1
                let url = URL(string: base.absoluteString + "&page=\(page)")!
                group.addTask {
                    let items = try VimeoParsing.videos(try await api(url)).items
                    onProgress(listed.add(items.count), total)
                    return (page, items)
                }
            }
            for _ in 0..<Self.parallelRequests { addNext() }
            while let (page, items) = try await group.next() {
                pages[page] = items
                addNext()
            }
        }
        var seen = Set<String>()
        return (1...pageCount).flatMap { pages[$0] ?? [] }.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Internals

    private struct Token {
        let jwt: String
        let expires: Date?
    }

    private func apiURL(_ path: String) -> URL {
        URL(string: path, relativeTo: VimeoParsing.apiBase)!.absoluteURL
    }

    private func sessionToken(cookies: String, log: LogSink) async throws -> Token {
        let data = try await send(Self.viewerURL, headers: ["Accept": "application/json", "Cookie": cookies], log: log)
        let jwt = try VimeoParsing.jwt(viewer: data)
        return Token(jwt: jwt, expires: VimeoParsing.jwtExpiry(jwt))
    }

    /// One GET with a 429 backoff loop (max `maxTries` responses). 401/403 means logged out.
    /// Only the URL path is ever logged, never the query, cookies or jwt.
    private func send(_ url: URL, headers: [String: String], log: LogSink) async throws -> Data {
        var attempt = 0
        while true {
            var req = URLRequest(url: url)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw VBackupError.vimeo("no HTTP response") }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw VBackupError.loggedOut
            case 500, 502, 503, 504:
                // Listings with download links are heavy; Vimeo's gateway sometimes times out. Retry briefly.
                attempt += 1
                guard attempt < Self.maxTries else { throw VBackupError.vimeo("HTTP \(http.statusCode) for \(url.path)") }
                log.log("vimeo: \(http.statusCode) on \(url.path), retry \(attempt) in \(5 * attempt)s")
                try await Task.sleep(for: .seconds(5 * attempt))
            case 429:
                attempt += 1
                let wait = VimeoParsing.retryDelay(retryAfter: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)
                guard attempt < Self.maxTries else { throw VBackupError.throttled(retryAfter: wait) }
                log.log("vimeo: 429 on \(url.path), waiting \(wait)s (try \(attempt) of \(Self.maxTries))")
                try await Task.sleep(for: .seconds(wait))
            default:
                throw VBackupError.vimeo("HTTP \(http.statusCode) for \(url.path)")
            }
        }
    }
}

/// The session jwt, shared by parallel requests. Refreshes when within 120 s of expiry, one refresh at a time.
actor TokenBox {
    private var token: (jwt: String, expires: Date?)
    private var refreshing: Task<(jwt: String, expires: Date?), Error>?
    private let refresh: @Sendable () async throws -> (jwt: String, expires: Date?)

    init(first: (jwt: String, expires: Date?), refresh: @escaping @Sendable () async throws -> (jwt: String, expires: Date?)) {
        token = first
        self.refresh = refresh
    }

    func jwt() async throws -> String {
        guard let exp = token.expires, exp.timeIntervalSinceNow < 120 else { return token.jwt }
        let task = refreshing ?? Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        token = try await task.value
        return token.jwt
    }
}

/// Running total across concurrent page fetches.
final class PageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int
    init(_ start: Int) { n = start }
    func add(_ k: Int) -> Int { lock.withLock { n += k; return n } }
}
