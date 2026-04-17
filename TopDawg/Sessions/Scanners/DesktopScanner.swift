import Foundation
import AppKit

/// Detects whether the Claude.app desktop binary is running and emits a single
/// pseudo-session row representing the open Desktop app. We don't enumerate
/// individual conversations because they live in an opaque IndexedDB inside the
/// Electron renderer — for v1, "Click to focus the Desktop app" is enough.
struct DesktopScanner {

    /// Bundle identifier of the Anthropic Desktop app.
    static let bundleID = "com.anthropic.claudefordesktop"

    func scan() -> [UnifiedSession] {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == DesktopScanner.bundleID }) else {
            return []
        }

        let pid = app.processIdentifier
        let launchDate = app.launchDate ?? Date()

        return [
            UnifiedSession(
                id: "\(SessionKind.desktop.rawValue):\(pid)",
                kind: .desktop,
                title: "Claude Desktop",
                model: nil,
                cwd: nil,
                pid: pid,
                sessionId: String(pid),
                lastActivity: launchDate,
                isRunning: true,
                isActivelyProcessing: false,
                sourcePath: nil
            )
        ]
    }
}
