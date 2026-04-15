import Foundation

// MARK: - Decision

/// User's choice for an approval request.
enum ApprovalDecision: String {
    case allow          // let it run this one time
    case allowAlways    // let it run this time AND add a permanent rule
    case deny           // reject with message
}

// MARK: - Request

/// One pending permission request routed from a Claude Code `PermissionRequest` hook
/// into the TopDawg notch overlay.
///
/// The lifecycle:
///   1. ApprovalServer decodes the incoming HTTP POST → builds this struct
///   2. PendingApprovals.enqueue(…) puts it on the queue + notifies UI
///   3. User clicks Allow / Allow-always / Deny in the overlay
///   4. PendingApprovals.resolve(id, with:) resumes the continuation
///   5. ApprovalServer writes the HTTP response and closes the connection
final class ApprovalRequest: Identifiable, ObservableObject {

    let id: UUID
    let receivedAt: Date

    /// Tool Claude wants to run, e.g. "Bash", "Edit", "Write", "WebFetch", an MCP tool name.
    let toolName: String

    /// Raw JSON (already UTF-8 decoded string) of the tool's input payload, so we can
    /// render a nice preview without fighting Swift's typed JSON story.
    let toolInputJSON: String

    /// Session id from Claude Code's hook payload (for grouping / display).
    let sessionID: String?

    /// Working directory reported by the hook (if any).
    let cwd: String?

    /// Transcript path (if any) — we don't read it, just show its basename as context.
    let transcriptPath: String?

    /// Completion callback. The server awaits this; the overlay fires it on click.
    /// We use a plain closure + a once-only guard instead of a Continuation so
    /// cancellation/timeout paths are trivially safe to double-call.
    private var completion: ((ApprovalDecision) -> Void)?
    private var didComplete = false
    private let lock = NSLock()

    init(
        toolName: String,
        toolInputJSON: String,
        sessionID: String?,
        cwd: String?,
        transcriptPath: String?,
        completion: @escaping (ApprovalDecision) -> Void
    ) {
        self.id = UUID()
        self.receivedAt = Date()
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.completion = completion
    }

    /// Resolve once. Safe to call multiple times (subsequent calls are no-ops).
    func resolve(_ decision: ApprovalDecision) {
        lock.lock()
        guard !didComplete else { lock.unlock(); return }
        didComplete = true
        let cb = completion
        completion = nil
        lock.unlock()
        cb?(decision)
    }

    // MARK: - Display helpers

    /// Best-effort one-line summary for the overlay header.
    var headline: String {
        switch toolName {
        case "Bash":
            if let cmd = extractString("command") {
                return cmd
            }
            return "Bash command"
        case "Edit", "MultiEdit":
            if let path = extractString("file_path") {
                return "Edit \((path as NSString).lastPathComponent)"
            }
            return "Edit file"
        case "Write":
            if let path = extractString("file_path") {
                return "Write \((path as NSString).lastPathComponent)"
            }
            return "Write file"
        case "Read":
            if let path = extractString("file_path") {
                return "Read \((path as NSString).lastPathComponent)"
            }
            return "Read file"
        case "WebFetch":
            if let url = extractString("url") { return url }
            return "Fetch URL"
        default:
            return toolName
        }
    }

    /// SF Symbol for the tool.
    var toolIcon: String {
        switch toolName {
        case "Bash":                  return "terminal.fill"
        case "Edit", "MultiEdit":     return "pencil.line"
        case "Write":                 return "square.and.pencil"
        case "Read":                  return "doc.text.fill"
        case "WebFetch", "WebSearch": return "globe"
        case "Glob":                  return "magnifyingglass"
        case "Grep":                  return "text.magnifyingglass"
        case "Agent":                 return "brain.head.profile"
        case "TodoWrite":             return "checklist"
        default:                      return "wrench.and.screwdriver.fill"
        }
    }

    /// Multi-line detail body for the overlay.
    var detail: String {
        // Try common fields in a sensible order.
        if toolName == "Bash", let cmd = extractString("command") {
            if let desc = extractString("description") {
                return "\(cmd)\n\n\(desc)"
            }
            return cmd
        }
        if let path = extractString("file_path") {
            var out = path
            if let content = extractString("content") {
                let preview = content.split(separator: "\n").prefix(6).joined(separator: "\n")
                out += "\n\n" + preview
                if content.count > preview.count { out += "\n…" }
            } else if let old = extractString("old_string"), let new = extractString("new_string") {
                let oldPreview = old.split(separator: "\n").prefix(3).joined(separator: "\n")
                let newPreview = new.split(separator: "\n").prefix(3).joined(separator: "\n")
                out += "\n\n- \(oldPreview)\n+ \(newPreview)"
            }
            return out
        }
        // Fallback: pretty-print the raw JSON if it's small.
        return toolInputJSON
    }

    /// Short badge shown under the title, e.g. "cli · ~/Projects/foo".
    var contextBadge: String {
        var parts: [String] = []
        if let cwd {
            let home = NSHomeDirectory()
            let shown = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            parts.append(shown)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Private

    /// Ad-hoc string extractor — avoids a full JSON decode step.
    /// Used only for display; safe against missing/malformed keys.
    private func extractString(_ key: String) -> String? {
        guard let data = toolInputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }
}
