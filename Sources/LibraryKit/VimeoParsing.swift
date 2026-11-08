import Foundation
import Contracts

/// Pure parsing of Vimeo web-session and API responses. No I/O, no logging of secrets.
enum VimeoParsing {
    static let apiBase = URL(string: "https://api.vimeo.com")!

    /// Netscape cookies.txt -> "name=value; ..." for vimeo.com cookies only.
    static func cookieHeader(netscape text: String) -> String {
        text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var l = Substring(line)
            if l.hasPrefix("#HttpOnly_") { l = l.dropFirst("#HttpOnly_".count) } else if l.hasPrefix("#") { return nil }
            let f = l.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 7 else { return nil }
            let domain = f[0].hasPrefix(".") ? f[0].dropFirst() : f[0]
            guard domain == "vimeo.com" || domain.hasSuffix(".vimeo.com") else { return nil }
            return "\(f[5])=\(f[6])"
        }.joined(separator: "; ")
    }

    /// `_next/viewer` -> jwt. A missing or empty jwt means the web session is gone.
    static func jwt(viewer data: Data) throws -> String {
        struct Viewer: Decodable { let jwt: String? }
        guard let jwt = (try? makeDecoder().decode(Viewer.self, from: data))?.jwt, !jwt.isEmpty else {
            throw VBackupError.loggedOut
        }
        return jwt
    }

    /// `exp` claim of a JWT (unverified). nil if the payload can't be read.
    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let d = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let exp = (obj["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func accountName(me data: Data) throws -> String {
        struct Me: Decodable { let name: String? }
        return try decode(Me.self, data, "me").name ?? ""
    }

    /// Folder page -> folders (parent = last ancestor_path entry) + the next page path.
    static func folders(_ data: Data) throws -> (items: [RemoteFolder], next: String?) {
        let page = try decode(Page<APIFolder>.self, data, "folders")
        let folders = page.data.map { f -> RemoteFolder in
            let parent = f.metadata?.connections?.ancestorPath?.last
            return RemoteFolder(id: lastComponent(f.uri), name: f.name ?? "", parentID: parent.map { lastComponent($0.uri) })
        }
        return (folders, page.paging?.next)
    }

    /// Video page -> videos + the next page path.
    static func videos(_ data: Data) throws -> (items: [RemoteVideo], next: String?) {
        let page = try decode(Page<APIVideo>.self, data, "videos")
        let videos = page.data.map { v -> RemoteVideo in
            let id = lastComponent(v.uri)
            let isPassword = v.privacy?.view == "password"
            return RemoteVideo(
                id: id, title: v.name ?? "", folderID: v.parentFolder.map { lastComponent($0.uri) },
                durationSeconds: v.duration ?? 0, width: v.width ?? 0, height: v.height ?? 0,
                privacy: v.privacy?.view ?? "unknown", downloadAllowed: v.privacy?.download ?? false,
                modified: date(v.modifiedTime), created: date(v.createdTime),
                renditions: (v.download ?? []).compactMap(rendition),
                pageURL: v.link.flatMap { URL(string: $0) } ?? URL(string: "https://vimeo.com/\(id)")!,
                playerURL: v.playerEmbedUrl.flatMap { URL(string: $0) } ?? URL(string: "https://player.vimeo.com/video/\(id)")!,
                password: isPassword ? v.password : nil, description: v.description)
        }
        return (videos, page.paging?.next)
    }

    /// One `download[]` entry; entries without a size or name are dropped.
    private static func rendition(_ d: APIDownload) -> Rendition? {
        guard let name = d.rendition ?? d.publicName, let size = d.size, size > 0 else { return nil }
        return Rendition(name: name, width: d.width ?? 0, height: d.height ?? 0, size: size,
                         md5: d.md5, link: d.link.flatMap { URL(string: $0) })
    }

    /// Single video (fresh download links) -> RemoteVideo, reusing the list parser.
    static func video(_ data: Data) throws -> RemoteVideo {
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "data": [try JSONSerialization.jsonObject(with: data)], "paging": ["next": NSNull()],
        ])
        guard let v = try videos(wrapped).items.first else { throw VBackupError.vimeo("unexpected video response") }
        return v
    }

    /// Retry-After seconds if given, else 60 s doubling per attempt (attempt starts at 1).
    static func retryDelay(retryAfter: String?, attempt: Int) -> Int {
        if let s = retryAfter.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), s >= 0 { return s }
        return 60 << max(0, attempt - 1)
    }

    // MARK: - Helpers

    private struct Page<T: Decodable>: Decodable {
        let data: [T]
        let paging: Paging?
    }

    private struct Paging: Decodable { let next: String? }

    private struct APIRef: Decodable { let uri: String }

    private struct APIFolder: Decodable {
        let name: String?
        let uri: String
        let metadata: Metadata?
        struct Metadata: Decodable { let connections: Connections? }
        struct Connections: Decodable { let ancestorPath: [APIRef]? }
    }

    private struct APIVideo: Decodable {
        let uri: String
        let name: String?
        let description: String?
        let link: String?
        let playerEmbedUrl: String?
        let duration: Int?
        let width: Int?
        let height: Int?
        let modifiedTime: String?
        let createdTime: String?
        let download: [APIDownload]?
        let privacy: Privacy?
        let parentFolder: APIRef?
        let password: String?
        struct Privacy: Decodable {
            let view: String?
            let download: Bool?
        }
    }

    private struct APIDownload: Decodable {
        let rendition: String?
        let publicName: String?
        let width: Int?
        let height: Int?
        let size: Int64?
        let md5: String?
        let link: String?
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        do { return try makeDecoder().decode(type, from: data) } catch {
            throw VBackupError.vimeo("unexpected \(what) response")
        }
    }

    /// "/users/1234567/projects/500001" -> "500001"; "/videos/1000000001" -> "1000000001".
    private static func lastComponent(_ uri: String) -> String {
        uri.split(separator: "/").last.map(String.init) ?? uri
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Unparseable or missing dates become .distantPast, which only makes a metadata refresh more likely.
    private static func date(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        return isoPlain.date(from: s) ?? isoFractional.date(from: s) ?? .distantPast
    }
}
