import Contracts
import Foundation

/// yt-dlp argv builders. Pure: no I/O. The URL is always the last element.
public enum YtDlpArguments {
    /// Downloads the video and its sidecars for one URL (`pageURL` or `playerURL`).
    public static func download(_ r: DownloadRequest, url: URL) -> [String] {
        build(r, url: url, metadataOnly: false)
    }

    /// Rewrites only the sidecars (info.json, thumbnail, subs) next to the video. No video download.
    public static func metadata(_ r: DownloadRequest, url: URL) -> [String] {
        build(r, url: url, metadataOnly: true)
    }

    /// Replaces the value after `--video-password` with `***`, for logging.
    public static func redacted(_ argv: [String]) -> [String] {
        var out: [String] = []
        var hideNext = false
        for arg in argv {
            if hideNext {
                out.append("***")
                hideNext = false
            } else {
                out.append(arg)
                hideNext = arg == "--video-password"
            }
        }
        return out
    }

    static func formatArgs(_ quality: Quality) -> [String] {
        switch quality {
        case .original: ["-f", "b[format_id~='(?i)^(original|source)']/bv*+ba/b"]
        case .p1080, .p720, .p540, .p360: ["-f", "bv*+ba/b", "-S", "res:\(quality.shortSideCap!)"]
        }
    }

    /// "<Naming.base>.%(ext)s". yt-dlp reads `%` as a template, so titles escape it as `%%`.
    static func outputTemplate(_ video: RemoteVideo) -> String {
        Naming.base(title: video.title, id: video.id).replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
    }

    private static func build(_ r: DownloadRequest, url: URL, metadataOnly: Bool) -> [String] {
        var argv = [
            "--cookies", r.cookies.path,
            "--ffmpeg-location", r.tools.ffmpeg.deletingLastPathComponent().path,
            "--newline", "--no-colors", "--continue",
            "--no-playlist", "--merge-output-format", "mp4",
            "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--write-subs", "--sub-langs", "all", "--no-write-playlist-metafiles",
            "--progress-template",
            "download:VBP %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "-P", r.destinationDir.path,
            "-o", outputTemplate(r.video),
        ]
        // --no-overwrites would keep an existing info.json, so the metadata refresh must leave it off.
        if metadataOnly {
            argv += ["--skip-download"]
        } else {
            argv += ["--no-overwrites"] + formatArgs(r.quality)
        }
        if let password = r.video.password {
            argv += ["--video-password", password]
        }
        argv.append(url.absoluteString)
        return argv
    }
}
