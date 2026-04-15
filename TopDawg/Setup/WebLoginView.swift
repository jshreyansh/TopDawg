import SwiftUI
import WebKit

// MARK: - Web Login Window

final class WebLoginWindowController {
    private var window: NSWindow?
    private var onToken: ((String) -> Void)?

    func show(onToken: @escaping (String) -> Void) {
        close()
        self.onToken = onToken

        let coordinator = WebLoginCoordinator { [weak self] token in
            DispatchQueue.main.async {
                onToken(token)
                self?.close()
            }
        }

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let vc = NSViewController()
        vc.view = webView

        let w = NSWindow(contentViewController: vc)
        w.title = "Sign in to Claude"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 900, height: 700))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w

        // Retain the coordinator for the lifetime of the window
        objc_setAssociatedObject(w, "coordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

        // Start polling cookies immediately + on every navigation
        coordinator.webView = webView
        coordinator.startPolling()

        // Load claude.ai
        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
        onToken = nil
    }
}

// MARK: - Coordinator

private final class WebLoginCoordinator: NSObject, WKNavigationDelegate {
    let onToken: (String) -> Void
    weak var webView: WKWebView?
    private var pollTimer: Timer?
    private var found = false

    init(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
    }

    deinit {
        pollTimer?.invalidate()
    }

    func startPolling() {
        // Poll cookies every 2 seconds — catches login completion even without navigation
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkCookies()
        }
    }

    // Check after every page load
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCookies()
    }

    private func checkCookies() {
        guard !found, let webView = webView else { return }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.found else { return }

            for cookie in cookies {
                if cookie.domain.contains("claude.ai") && cookie.name == "sessionKey" && !cookie.value.isEmpty {
                    self.found = true
                    self.pollTimer?.invalidate()
                    self.onToken(cookie.value)
                    return
                }
            }
        }
    }
}
