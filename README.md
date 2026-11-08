<p align="center"><img src="assets/wordmark.png" alt="Vimeo Backup" width="480"></p>
<p align="center">Keep a copy of your whole Vimeo library on your Mac.</p>

Vimeo Backup is a Mac app that copies your Vimeo library to a folder on your Mac or an external drive. You sign in with your Vimeo account, pick a folder, and choose what to download: whole folders, a range of upload dates, or single videos, either as the original file or at a smaller size. Your Vimeo folders show up as folders on disk, and the main window tells you how much of the library you have and at what quality.

Run it again whenever you like. It only downloads videos that are new or missing, and if you stop partway it picks up where it left off next time. Grab the latest DMG from [Releases](https://github.com/shaulbarlev/vimeo-backup-manager/releases), drag the app to Applications and open it. It needs macOS 14 or later, and if something breaks, Send Logs in the app emails what happened.

## More info

The app signs in through Vimeo's own login page in a window, then keeps that web session (cookies only, stored in `~/Library/Application Support/vbackup/`, readable only by you). With it, the app lists every folder and video in your account, including each video's original file and its smaller versions with their sizes. Downloads come straight from those files. Originals are checked against Vimeo's byte size and MD5 after they land, so a broken copy never counts as backed up. Videos that Vimeo lists no files for go through [yt-dlp](https://github.com/yt-dlp/yt-dlp), which the app fetches and keeps updated on its own.

Each video becomes one file named after its title, its Vimeo ID and its quality, next to a few small extras (details, thumbnail, captions). Videos outside any Vimeo folder land in `_Unsorted`. The hidden `.vbackup` folder holds a plain-text status report and a log for every run:

```
Backup folder/
  commercials/
    Spring campaign [1000000002] [orig].mp4
    Spring campaign [1000000002].info.json
    Spring campaign [1000000002].jpg
  animation/sub-folder/…
  _Unsorted/…
  .vbackup/
    status.txt
    logs/2026-11-08_1530.log
```

The overview sorts every video into one of five groups: Original (the exact source file), Full resolution (a smaller file at the source's resolution), Lower resolution, Not backed up, and Unreachable (the last try failed, with the reason listed). It reads quality from the files themselves, so renaming or moving things around on disk doesn't fool it. If a video moves to another folder on Vimeo, the next download moves the local file to match instead of fetching it again. Nothing on disk is ever deleted; replaced copies go to `.vbackup/replaced`.

The code is a Swift package with four parts: `Contracts` (shared types and file naming), `LibraryKit` (Vimeo listing, disk scan, sorting and the download engine), `DownloadKit` (file downloads and yt-dlp) and `VBackupApp` (the SwiftUI app). `swift test` runs the test suite, and `swift run VBackupApp` starts the app from source. `scripts/release.sh` builds the signed DMG; it reads your App Store Connect key from `scripts/release.env`, which stays out of git.
