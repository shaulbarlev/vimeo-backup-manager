import AppKit
import Contracts
import SwiftUI

/// `--render-overview <png> [--problems]`: draws OverviewView with mock data at 1100x800 points (2x) and writes a PNG.
@MainActor
enum RenderOverview {
    static func run(to path: String, problems: Bool, sheet: Bool = false) -> Int32 {
        let model = AppModel(engine: Wiring.engine(), tools: Wiring.tools())
        model.root = URL(fileURLWithPath: "/Volumes/Backup/vimeo")
        model.summary = problems
            ? MockEngine.summary(vimeoCheckedAt: nil, problems: [
                "Vimeo listing failed: Vimeo error: HTTP 503. Numbers below come from the disk only.",
                MockEngine.duplicateProblem,
                "Move conflict: 1000000005 already exists in commercials. Not overwritten.",
            ])
            : MockEngine.summary(vimeoCheckedAt: Date().addingTimeInterval(-180), problems: [MockEngine.duplicateProblem])

        // ImageRenderer draws nothing for ScrollView and Table (AppKit-backed), so host the view
        // in an offscreen window and cache its display instead.
        let size = sheet ? NSSize(width: 1000, height: 700) : NSSize(width: 1100, height: 800)
        let content: AnyView = sheet
            ? AnyView(DownloadSheet(model: model, summary: model.summary!, root: URL(fileURLWithPath: "/"),
                                    request: .init(title: "Download", scope: DownloadScope(), quality: .p720, onlyIDs: nil)))
            : AnyView(OverviewView(model: model))
        let view = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("render failed")
            return 1
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            print("write failed: \(error.localizedDescription)")
            return 1
        }
    }
}
