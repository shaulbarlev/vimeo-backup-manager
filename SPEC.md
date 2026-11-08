# vbackup build spec: three parallel workstreams

Product behavior is in `README.md`. This file says **who builds what** and the exact interfaces between the parts.

## Ground rules (all agents)

- Swift package, macOS 14+, Swift 6 toolchain in Swift 5 language mode. No third-party dependencies. Foundation, SwiftUI, WebKit and XCTest only.
- `Sources/Contracts/Contracts.swift` is the shared contract. **Do not edit it, and do not edit `Package.swift`.** If you need a contract change, work around it and list the request in your final report.
- Only touch your own directories (listed per workstream). You may delete the `Placeholder.swift` files in them.
- Build and test with `swift build` and `swift test --filter <YourTests>` from the repo root. Both must pass before you finish.
- Never log or print secrets: cookie values, the cookies file contents, video passwords, JWTs.
- Leave ONE runnable check per non-trivial piece of logic (XCTest). No mocking frameworks.
- When done: `git add` only your directories, commit on your branch with a clear message, and report what was built, what was tested (paste the test summary line), what is unverified, and any contract change requests.

## Verified facts about Vimeo (do not re-research)

- Web session: with the signed-in cookies, `GET https://vimeo.com/_next/viewer` (header `Accept: application/json`) returns JSON with a `jwt` field (short-lived; refresh when within 120 s of its `exp`). Then call `https://api.vimeo.com/...` with `Authorization: jwt <jwt>` and `Accept: application/vnd.vimeo.*+json;version=3.4`. This is exactly what yt-dlp does.
- Folders: `GET /me/projects?per_page=100&fields=uri,name,metadata.connections.ancestor_path` → `data[]` items like `{"name":"360","uri":"/users/1234567/projects/500001","metadata":{"connections":{"ancestor_path":[]}}}`. `ancestor_path` lists parent folders (each has `uri`), nearest parent last. Folder id = last path component of `uri`.
- Videos: `GET /me/videos?per_page=100&fields=uri,name,description,link,player_embed_url,duration,width,height,modified_time,privacy.view,privacy.download,parent_folder.uri,password`. Paging: follow `paging.next` (a path relative to `https://api.vimeo.com`) until null. Sample item:
  `{"uri":"/videos/1000000001","name":"sample clip 1","link":"https://vimeo.com/1000000001/a1b2c3d4e5","player_embed_url":"https://player.vimeo.com/video/1000000001?h=a1b2c3d4e5","duration":28,"width":1080,"height":1920,"modified_time":"2026-11-04T14:15:48+00:00","privacy":{"view":"unlisted","download":true},"parent_folder":null}`. `parent_folder` is null or `{"uri":"/users/X/projects/ID"}`. `password` only appears for password videos and may be absent.
- Account name: `GET /me?fields=name`.
- HTTP 429 from api.vimeo.com = rate limited. Back off (honor `Retry-After` if present, else 60 s, doubling, max 5 tries).
- yt-dlp with cookies uses `vimeo.com/ID/HASH` (`link`); this is needed for "only me" videos and originals. Without login, only `player_embed_url` works. The original appears as a format whose `format_id` passes `Naming.isOriginalFormatID`.

## On-disk contract (all agents)

Use `Naming` from Contracts for every name; never hand-build one.

```
<root>/<Naming.folderPath>/<Naming.fileStem(title,id,tag)>.mp4     video, tag = Naming.qualityTag(...)
<root>/<folder>/<Naming.base(title,id)>.info.json                    yt-dlp info json (has "format_id", "height", "width")
<root>/<folder>/<Naming.base(title,id)>.jpg                          thumbnail
<root>/<folder>/<Naming.base(title,id)>.<lang>.vtt                   captions
<root>/.vbackup/status.txt   logs/<yyyy-MM-dd_HHmm>.log   probe-cache.tsv   failures.tsv
```

- A video is backed up if any non-`.part` file with a video extension and its id exists anywhere under root (outside `.vbackup`).
- Never delete user files. Never create `root` itself. If it doesn't exist, throw `VBackupError.rootUnavailable`.

---

## Workstream A: LibraryKit (Vimeo listing, disk, classification, sync engine)

**Owns:** `Sources/LibraryKit/`, `Tests/LibraryKitTests/` (including `Fixtures/`).

Build:

1. **`VimeoWebClient`**: `init(cookiesFile: URL, session: URLSession = .shared)`. Parses the Netscape cookies file and sends the vimeo.com cookies as a `Cookie` header on `_next/viewer`. Gets the JWT and `func fetchLibrary(log:) async throws -> RemoteLibrary` (account name, all folders with `parentID` from the last `ancestor_path` entry, all videos with every page followed). Map fields to `RemoteVideo` (id from `uri`, `folderID` from `parent_folder.uri`, `downloadAllowed` from `privacy.download`). A viewer response without a `jwt`, or a 401/403, throws `VBackupError.loggedOut`. Handle 429 as above. Set a Safari-like `User-Agent`. Keep JSON parsing in pure functions, tested with fixture JSON files you create under `Fixtures/` (folders page, two video pages with `paging.next`, a viewer response, a logged-out viewer response).
2. **`DiskScanner`**: walks root (skipping `.vbackup`, hidden files and `.part`), groups files by `Naming.videoID(fromFilename:)` and builds `LocalFile`s. Width and height come from `ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 <file>`. `isOriginal` comes from the sibling `<base>.info.json` `format_id` via `Naming.isOriginalFormatID`; it is false if there is no info.json. `sizeBytes` = video plus sidecars. Cache probe results in `.vbackup/probe-cache.tsv` (path, size, mtime, width, height, isOriginal) and re-probe only when size or mtime changes. Multiple video files for the same id: keep the largest short side and add a `problems` line for the duplicate. Reports progress via a callback `(done, total)`.
3. **`Classifier`** (pure, heavily tested): `(RemoteLibrary, [LocalFile], failures: [String: String], quality: Quality) -> LibrarySummary`.
   - No local file: `.unreachable` if a failure is recorded for that id, else `.missing`.
   - Local `isOriginal`: `.original`.
   - quality `.original` and `video.downloadAllowed` and the local file is not original: `.lower` (upgradeable).
   - target = `min(video.shortSide, quality.shortSideCap ?? .max)`. If local shortSide >= target × 0.98: `.fullResolution`, else `.lower`.
   - Bytes per category = sum of local `sizeBytes`. `estimatedMissingBytes` = Σ duration of missing and unreachable videos × average local bitrate (Σ local bytes / Σ durations of backed-up videos). Use 5 Mbit/s if there are no local files.
   - Folders: one `FolderSummary` per `Naming.folderPath`, every Category key present (zeros), sorted by path with `_Unsorted` last.
   - `localOnly` = local ids not on Vimeo. `failures` = unreachable videos with reasons.
4. **`FailureStore`**: `.vbackup/failures.tsv` (id, reason, date). Recorded on download failure, cleared on success.
5. **`FileLog: LogSink`**: appends timestamped lines to `.vbackup/logs/<run>.log` and deletes logs older than 30 days on init. Thread-safe.
6. **`StatusWriter`**: writes `.vbackup/status.txt`, a human-readable plain-text report: last sync time, account, totals, the five categories with count / % / size, the per-folder table, failures with reasons, local-only files, problems.
7. **`SyncEngine: BackupEngine`**: `init(downloader: VideoDownloading, makeClient: @escaping @Sendable (URL) -> VimeoWebClient = { VimeoWebClient(cookiesFile: $0) })`.
   - `refresh`: listing, then scan, then classify. A listing failure other than `.loggedOut` does not throw: classify against the disk only and put the error in `problems` with `vimeoCheckedAt = nil`.
   - `sync`: check root exists, list, scan, then **relocate**. A local file whose folder differs from `Naming.folderPath` moves together with all its sidecars (same `[id]` in the same dir) to the expected folder. Never overwrite; on conflict log it and add to problems. Then download every `.missing` and `.unreachable` video (plus `.lower` if `upgrade`) **one at a time** via the downloader into `root/<folderPath>`. After a successful upgrade, move the old lower-quality video file into `.vbackup/replaced/` (never delete). Per-video errors are recorded in FailureStore and the run continues. `.loggedOut` aborts the run and rethrows. Next, call `refreshMetadata` for videos whose Vimeo `modified` is newer than their info.json mtime. Finally rescan, classify, write status.txt and return.
   - Report `SyncPhase` throughout, map `DownloadEvent.throttled` to `.throttled(resumeAt:)`, check `Task.isCancelled` between videos, and log every step through `FileLog`.
   - Test with a fake `VideoDownloading` (a tiny struct in tests that writes a dummy file and info.json) plus a temp root. The test must cover relocate, download-missing, failure recording and status.txt being written. Inject a fake listing: if needed, add an internal init taking a `@Sendable () async throws -> RemoteLibrary` closure.

Optional live check (skip if no env): if `VBACKUP_COOKIES` points at a cookies file, a test runs `fetchLibrary` and prints counts only.

---

## Workstream B: DownloadKit (yt-dlp / ffmpeg tooling and downloading)

**Owns:** `Sources/DownloadKit/`, `Tests/DownloadKitTests/`.

Build:

1. **`ToolManager: ToolProviding`**: `init(appSupport: URL = ~/Library/Application Support/vbackup)`. Tools live in `<appSupport>/bin/`.
   - **yt-dlp:** if missing, copy `Bundle.main` resource `yt-dlp_macos` if present. Otherwise download `https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos`. `chmod 755` and remove the `com.apple.quarantine` xattr. Then run `yt-dlp -U` **once per process** (non-fatal; log the outcome).
   - **ffmpeg / ffprobe:** `Bundle.main` resources, then `<appSupport>/bin`, then `/opt/homebrew/bin`, `/usr/local/bin`, `$PATH`. Throw `VBackupError.tool("ffmpeg not found")` if absent.
   - Make the yt-dlp download a separate function so tests can skip it.
2. **`YtDlpArguments`** (pure, heavily tested): builds the argv for a `DownloadRequest` and URL choice:
   - Common: `--cookies <file> --ffmpeg-location <ffmpeg dir> --newline --no-colors --continue --no-overwrites --no-playlist --merge-output-format mp4 --write-info-json --write-thumbnail --convert-thumbnails jpg --write-subs --sub-langs all --no-write-playlist-metafiles -P <destinationDir> -o "<Naming.base>.%(ext)s"`, plus `--progress-template "download:VBP %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s"`.
   - Format: `.original` → `-f "b[format_id~='(?i)^(original|source)']/bv*+ba/b"`. `.best` → `-f "bv*+ba/b"`. `.p1080/.p720/.p540` → `-f "bv*+ba/b" -S "res:<cap>"` (res = shorter side, so vertical video works).
   - `--video-password <pw>` when `video.password != nil`.
   - `refreshMetadata` variant: same output naming plus `--skip-download`, no format args.
   - A `redacted(argv)` helper replaces the value after `--video-password` with `***` for logging.
3. **`YtDlpDownloader: VideoDownloading`**:
   - Run yt-dlp with `Process`. Stream stdout/stderr line by line, parse `VBP` lines into `.progress` fractions (`total_bytes` or the estimate; ignore `NA`), and log every line except progress lines.
   - **URL order:** try `video.pageURL` first. If that fails (non-zero exit), retry once with `video.playerURL`.
   - **Errors:** if both fail and stderr contains `only works when logged-in` / `login required` / `--cookies`, throw `.loggedOut`. On `HTTP Error 429` wait 60 s, doubling, up to 5 tries, emitting `.throttled(retryInSeconds)` before each wait; then throw `.throttled`. Any other failure throws `.tool(<last ERROR: line>)`.
   - **After success:** read `<base>.info.json` (`format_id`, `width`, `height`; fall back to ffprobe for width and height) and rename the video file to `Naming.fileStem(... qualityTag: Naming.qualityTag(isOriginal:shortSide:))` + ext. Sidecars keep the base name. Return the final URL.
   - **Cancellation:** on Task cancel, send SIGINT to yt-dlp (so `.part` stays resumable), wait for exit, throw `CancellationError`.
   - Log the full redacted command line for every run.
4. **Tests:** argv tests for every quality, the password and its redaction, and the metadata variant. Progress-line parser tests. Error-classification tests from sample stderr strings (logged-in message, 429, generic ERROR). Gated live test: if `VBACKUP_NET=1`, `ToolManager.prepare` then download public video `https://vimeo.com/76979871` (player URL `https://player.vimeo.com/video/76979871`) at `.p540` into a temp dir with an empty cookies file. Assert the final file name ends in `[540p].mp4` (or the actual short side), and that info.json and jpg exist.

---

## Workstream C: VBackupApp (SwiftUI app, sign-in, overview UI)

**Owns:** `Sources/VBackupApp/`, `Tests/AppTests/`. Delete the placeholder `main.swift`. Use `@main struct VBackupApp: App`, and in an `NSApplicationDelegate` call `NSApp.setActivationPolicy(.regular)` and activate, so `swift run VBackupApp` shows a normal window.

Build:

1. **`AppModel`** (`@MainActor @Observable`): holds the backup root (UserDefaults path), quality (UserDefaults, default `.original`), `summary: LibrarySummary?`, `phase: SyncPhase?`, `error: String?`, `isSyncing`, and `showSignIn`. Depends only on `BackupEngine` and `ToolProviding` (from Contracts).
   - **On launch:** `tools.prepare`. If root and cookies exist, `engine.refresh`.
   - **Errors:** `.loggedOut` sets `showSignIn = true`; `.rootUnavailable` becomes a red banner.
   - **Actions:** `sync()`, `upgrade()` (sync with `upgrade: true`), `cancel()` (cancels the Task). Downloading the N missing videos is the same as `sync()`.
2. **`Wiring.swift`**: `enum Wiring { static func engine() -> BackupEngine; static func tools() -> ToolProviding }`, returning **`MockEngine` / `MockTools`** (in this target). The integrator swaps in the real `SyncEngine(downloader: YtDlpDownloader())` and `ToolManager()` later. Keep it to that one file. `MockEngine` returns a realistic summary: the README numbers (5,357 videos, 14 folders, all five categories, some failures, 2 local-only files, one problem string). Its `sync` steps through every `SyncPhase` over a few seconds.
3. **Sign-in (`SignInSheet`)**: `WKWebView` (via `NSViewRepresentable`) loading `https://vimeo.com/log_in`, with a `WKWebsiteDataStore(forIdentifier:)` per backup root (UUID stored in UserDefaults keyed by root path) so accounts stay separate.
   - After each navigation and every 1 s, read `httpCookieStore.getAllCookies`. When a cookie named `vimeo` on a `vimeo.com` domain exists, export all `vimeo.com` cookies and dismiss, then refresh.
   - The user only ever sees Vimeo's own page plus a Cancel button.
   - Show a note under the web view: "Google sign-in isn't supported. Use your Vimeo email and password."
4. **`CookieExporter`** (pure, tested): `[HTTPCookie] -> String` in Netscape format (`# Netscape HTTP Cookie File` header). Each line is `domain \t TRUE/FALSE (subdomains: domain starts with ".") \t path \t TRUE/FALSE (secure) \t expiry unix seconds (0 if session) \t name \t value`. `write(to:)` creates the file with POSIX permissions 0600 at `~/Library/Application Support/vbackup/cookies/<first 16 hex of SHA256(root path)>.txt` (CryptoKit is allowed). `AppModel` passes this path as `BackupConfig.cookies`.
5. **Setup view** (no root yet): "Choose backup folder…" (`fileImporter`, directories), then the sign-in.
6. **`OverviewView`** (root view, the most important screen; clear and reliable):
   - **Header:** account name · total videos · local size · "Vimeo checked X ago · disk scanned Y ago" (`RelativeDateTimeFormatter`). A nil date shows "never" in red.
   - **Problems banner** (red) when `summary.problems` is non-empty or there's an error. Never hide failures.
   - **One horizontal stacked bar** of the five categories in fixed order and colors (original = green, fullResolution = teal, lower = yellow, missing = gray, unreachable = red). Any non-zero segment gets at least 3 pt so it stays visible.
   - **Legend rows:** swatch, label, count, percent of total (one decimal), size (`ByteCountFormatter`). `missing` shows "~<estimatedMissingBytes> est.". Buttons: "Upgrade N" on lower and "Download N" on missing, each disabled while syncing.
   - **"Complete: X / total (P%)"** in large type.
   - **Folder table** (`Table`): Folder, Videos, Orig %, Full %, Lower %, Missing %, Size.
   - **Collapsible lists:** Unreachable (title, reason, link to `https://vimeo.com/<id>`) and Local-only files (filename, size, Reveal in Finder).
   - **Progress strip** while syncing, showing the current `SyncPhase` in words with a progress bar, plus Cancel.
   - **Toolbar:** Sync button, quality `Picker` (`Quality.allCases`, `label`), backup folder name with "Change…", and a Sign out item (deletes the cookies file and the data store for that root).
   - **Closing the window while syncing** asks "Stop the sync?"; stopping cancels the sync.
   - Put percent/size formatting in pure functions and test them, e.g. percents of `[3912, 801, 210, 398, 36]` over 5357 → `73.0, 15.0, 3.9, 7.4, 0.7`.
7. **Render check:** `swift run VBackupApp --render-overview <out.png>` renders `OverviewView` with the `MockEngine` summary through `ImageRenderer` at 1100×800, writes the PNG and exits without showing a window. Generate it, then open it with your image-reading tool and check it visually: no clipped text, every category visible, numbers match the mock.

---

## Integration (done by the integrator after A, B and C merge, not by agents)

Swap `Wiring` to the real engine and tools. Sign in for real, then validate the three README assumptions: listing via the web JWT, the 36 "only me" videos, and originals plus the rate limit. Then do a first partial sync, and package as a `.dmg`.
