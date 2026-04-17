import AppKit
import ApplicationServices
import CoreGraphics

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

// MARK: - Terminal Messenger

/// Sends a text message to a running Claude CLI session.
/// Strategy: tries tmux `send-keys` first (silent, no clipboard interference),
/// falls back to clipboard + CGEvent paste for non-tmux terminals.
enum TerminalMessenger {

    enum SendError: LocalizedError {
        case noPID, noTerminal, accessibilityRequired
        var errorDescription: String? {
            switch self {
            case .noPID:                 return "Session has no process ID"
            case .noTerminal:            return "Could not locate the owning terminal"
            case .accessibilityRequired: return "Grant Accessibility permission in System Settings → Privacy & Security → Accessibility to send messages"
            }
        }
    }

    @MainActor
    static func send(_ message: String, to session: UnifiedSession) async throws {
        guard let pid = session.pid else { throw SendError.noPID }

        // 1. Try tmux send-keys — silent, no focus steal, no clipboard touch.
        let sentViaTmux = await Task.detached(priority: .userInitiated) {
            guard let tmuxPath = Self.tmuxExecutable(),
                  let paneID   = Self.tmuxPane(containing: pid, tmuxPath: tmuxPath)
            else { return false }
            shellRun(tmuxPath, args: ["send-keys", "-t", paneID, "-l", message])
            shellRun(tmuxPath, args: ["send-keys", "-t", paneID, "Enter"])
            return true
        }.value
        if sentViaTmux { return }

        // 2. Terminal.app AppleScript — finds the exact tab by tty, no Accessibility needed.
        let sentViaScript = await Task.detached(priority: .userInitiated) {
            Self.sendViaTerminalAppleScript(message: message, toPID: pid)
        }.value
        if sentViaScript { return }

        // 3. CGEvent clipboard paste — requires Accessibility permission.
        guard AXIsProcessTrusted() else { throw SendError.accessibilityRequired }

        guard let termPID = ProcessProbe.owningTerminalPID(for: pid),
              let app = NSRunningApplication(processIdentifier: termPID)
        else { throw SendError.noTerminal }

        let pb    = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(message, forType: .string)

        app.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: 400_000_000)

        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)!
        vDown.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 80_000_000)

        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 150_000_000)

        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
    }

    /// Sends a message to the Terminal.app tab whose tty matches the claude process.
    /// Uses `do script … in tab` which delivers text as input to the foreground process
    /// without requiring Accessibility. Returns false if the tab cannot be located or the
    /// terminal is not Terminal.app.
    private static func sendViaTerminalAppleScript(message: String, toPID: Int32) -> Bool {
        guard let ttyName = ProcessProbe.controllingTTY(of: toPID) else { return false }
        let devPath = "/dev/\(ttyName)"

        // Build an AppleScript-safe string literal, handling embedded double-quotes by
        // splitting on them and concatenating with AppleScript's `quote` constant.
        let parts = message.components(separatedBy: "\"")
        let asLiteral: String
        if parts.count == 1 {
            asLiteral = "\"\(message)\""
        } else {
            asLiteral = parts.map { "\"\($0)\"" }.joined(separator: " & quote & ")
        }

        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t = "\(devPath)" then
                        do script \(asLiteral) in t
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError  = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        let reply = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reply == "true"
    }

    // MARK: - Tmux helpers

    private static func tmuxExecutable() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Finds the tmux pane whose process tree contains `claudePID`.
    /// Runs `tmux list-panes -a` and checks if any pane PID is an ancestor of claudePID.
    private static func tmuxPane(containing claudePID: Int32, tmuxPath: String) -> String? {
        guard let output = shellRun(tmuxPath, args: ["list-panes", "-a", "-F",
                                                     "#{pane_id} #{pane_pid}"])
        else { return nil }

        // Collect the full ancestor chain of the claude process.
        var ancestors = Set<Int32>()
        var cur: Int32? = claudePID
        for _ in 0..<15 {
            guard let p = cur else { break }
            ancestors.insert(p)
            cur = ProcessProbe.parentPID(of: p)
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let panePID = Int32(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            if ancestors.contains(panePID) { return String(parts[0]) }
        }
        return nil
    }

}

// MARK: - Shell helper

@discardableResult
private func shellRun(_ executable: String, args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments     = args
    let out = Pipe(), err = Pipe()
    proc.standardOutput = out
    proc.standardError  = err
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

// MARK: - New Session Launcher

/// Starts a brand-new `claude` CLI session in a terminal window.
/// Tries tmux first (new-window in the active session), then falls back
/// to Terminal.app via AppleScript.
enum NewSessionLauncher {

    static func launch(cwd: String? = nil) {
        let dir  = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let cmd  = "cd \(shellQuote(dir)) && claude"

        if let tmuxPath = tmuxExecutable(), launchInTmux(command: cmd, tmuxPath: tmuxPath) {
            return
        }
        launchInTerminal(command: cmd)
    }

    private static func launchInTmux(command: String, tmuxPath: String) -> Bool {
        // Check that a tmux server is running by listing sessions.
        guard let sessions = shellRun(tmuxPath, args: ["list-sessions"]),
              !sessions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        shellRun(tmuxPath, args: ["new-window", "-n", "claude", command])
        return true
    }

    private static func launchInTerminal(command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments     = ["-e", script]
        try? proc.run()
    }

    private static func tmuxExecutable() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
