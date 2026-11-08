import Foundation
import SwiftUI
import WebKit

/// The app-wide Vimeo web session: one WebKit data store and one cookies file.
enum VimeoSession {
    static let loginURL = URL(string: "https://vimeo.com/log_in")!
    private static let storeKey = "webStore"

    /// Reuses a data store from the per-folder era (so an existing sign-in carries over), else makes one.
    static func dataStoreID(legacyRoot: URL? = nil) -> UUID {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: storeKey), let id = UUID(uuidString: stored) { return id }
        let legacy = legacyRoot.flatMap { defaults.string(forKey: "webStore:" + $0.path) }.flatMap(UUID.init(uuidString:))
        let id = legacy ?? UUID()
        defaults.set(id.uuidString, forKey: storeKey)
        return id
    }

    static var isSignedIn: Bool { FileManager.default.fileExists(atPath: CookieExporter.cookiesURL().path) }

    /// Deletes the cookies file and the web data store.
    @MainActor
    static func signOut() async throws {
        let cookies = CookieExporter.cookiesURL()
        if FileManager.default.fileExists(atPath: cookies.path) {
            try FileManager.default.removeItem(at: cookies)
        }
        try await WKWebsiteDataStore.remove(forIdentifier: dataStoreID())
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}

/// Vimeo's own login page, plus a Cancel button. Once the `vimeo` session cookie appears,
/// the vimeo.com cookies are exported and the sheet is dismissed.
struct SignInSheet: View {
    let onSignedIn: () -> Void
    let onError: (Error) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WebSignIn(onSignedIn: onSignedIn, onError: onError)
            HStack(alignment: .firstTextBaseline) {
                Text("Google sign-in isn't supported. Use your Vimeo email and password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 900, height: 720)
    }
}

private struct WebSignIn: NSViewRepresentable {
    let onSignedIn: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSignedIn: onSignedIn, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: VimeoSession.dataStoreID())
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.start(web)
        web.load(URLRequest(url: VimeoSession.loginURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onSignedIn: () -> Void
        private let onError: (Error) -> Void
        private weak var web: WKWebView?
        private var poll: Task<Void, Never>?
        private var done = false

        init(onSignedIn: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onSignedIn = onSignedIn
            self.onError = onError
        }

        func start(_ web: WKWebView) {
            self.web = web
            poll = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.check()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        func stop() {
            poll?.cancel()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await check() }
        }

        private func check() async {
            guard !done, let store = web?.configuration.websiteDataStore.httpCookieStore else { return }
            let cookies = await store.allCookies()
            guard cookies.contains(where: { $0.name == "vimeo" && CookieExporter.isVimeo(domain: $0.domain) }) else {
                return
            }
            do {
                try CookieExporter.write(CookieExporter.vimeoCookies(cookies), to: CookieExporter.cookiesURL())
                done = true
                stop()
                onSignedIn()
            } catch {
                onError(error)
            }
        }
    }
}
