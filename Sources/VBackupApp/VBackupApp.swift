import AppKit
import SwiftUI

@main
struct VBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(engine: Wiring.engine(), tools: Wiring.tools())

    init() {
        // Headless visual check: render the overview to a PNG and exit. No window is shown.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-overview"), i + 1 < args.count {
            exit(RenderOverview.run(to: args[i + 1], problems: args.contains("--problems"), sheet: args.contains("--sheet")))
        }
    }

    var body: some Scene {
        WindowGroup("Vimeo Backup") {
            RootView(model: model)
                .task {
                    appDelegate.model = model
                    model.launch()
                }
        }
        .defaultSize(width: 1100, height: 800)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Cmd-Q during a download asks first, and stops the download cleanly (finished files kept, .part resumes).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isSyncing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop and quit?"
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.cancel()
        Task { @MainActor in
            while model.isSyncing { try? await Task.sleep(nanoseconds: 100_000_000) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift run starts without a bundle: make it a normal app with a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Welcome once, then setup until a backup folder exists, then the overview. The sign-in sheet sits on top when needed.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.welcomed {
                WelcomeView(model: model)
            } else if model.root == nil {
                SetupView(model: model)
            } else {
                OverviewView(model: model)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowCloseGuardView(model: model))
        .sheet(isPresented: $model.showHelp) {
            WelcomeView(model: model, revisit: true).frame(width: 820, height: 560)
        }
        .sheet(isPresented: $model.showSignIn) {
            SignInSheet(
                onSignedIn: { model.signedIn() },
                onError: { model.error = $0.localizedDescription },
                onCancel: { model.showSignIn = false })
        }
    }
}

/// Puts a close guard on the hosting window, so closing it during a sync asks first.
private struct WindowCloseGuardView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> GuardHostView { GuardHostView(model: model) }
    func updateNSView(_ nsView: GuardHostView, context: Context) {}
}

private final class GuardHostView: NSView {
    private let model: AppModel
    private var guardian: WindowCloseGuard?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !(window.delegate is WindowCloseGuard) else { return }
        let proxy = WindowCloseGuard(original: window.delegate, model: model)
        guardian = proxy
        window.delegate = proxy
    }
}

/// Window delegate proxy. Asks before closing while a check or download runs; every other call goes to SwiftUI's delegate.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private let original: NSWindowDelegate?
    private weak var model: AppModel?

    init(original: NSWindowDelegate?, model: AppModel) {
        self.original = original
        self.model = model
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isSyncing else {
            return original?.windowShouldClose?(sender) ?? true
        }
        let alert = NSAlert()
        alert.messageText = "Stop and close?"
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        model.cancel()
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}
