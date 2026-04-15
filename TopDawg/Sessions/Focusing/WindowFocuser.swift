import AppKit
import ApplicationServices

/// Brings a target session forward when the user clicks a row in the notch.
///
/// Strategy per kind:
/// - **CLI**: walk the parent-process chain from the `claude` PID to find the owning
///   terminal app (Terminal, iTerm, Ghostty, Warp, VS Code, Cursor, …) and activate
///   that app. We don't try to switch *tabs* in v1 — too terminal-specific. The user
///   is one Cmd+` away from the right tab.
/// - **Desktop**: launch `claude://` URL or activate the running Claude.app.
/// - **Cowork**: same as Desktop — Cowork sessions surface in the Desktop app UI.
enum WindowFocuser {

    static func focus(_ session: UnifiedSession) {
        switch session.kind {
        case .cli:
            focusCLI(session)
        case .desktop, .cowork:
            focusDesktop()
        }
    }

    // MARK: - CLI

    private static func focusCLI(_ session: UnifiedSession) {
        guard let pid = session.pid else { return }

        // Walk up to find the owning terminal app PID.
        if let terminalPID = ProcessProbe.owningTerminalPID(for: pid),
           let app = NSRunningApplication(processIdentifier: terminalPID) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }

        // Fallback: reveal cwd in Finder so the user at least sees where it ran.
        if let cwd = session.cwd {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
        }
    }

    // MARK: - Desktop / Cowork

    private static func focusDesktop() {
        let runningApps = NSWorkspace.shared.runningApplications
        if let app = runningApps.first(where: { $0.bundleIdentifier == DesktopScanner.bundleID }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        // Not running — try the URL scheme, which will boot the app.
        if let url = URL(string: "claude://") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permissions

    /// Whether the user has granted Accessibility permission. Polled by the
    /// onboarding wizard / panel header to decide whether to show a primer.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt to add the app to Accessibility. Safe to call
    /// repeatedly — it's a no-op if already granted.
    static func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: [CFString: Any] = [key: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
