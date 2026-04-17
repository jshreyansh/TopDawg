import Foundation

/// Which Claude surface a session belongs to.
enum SessionKind: String, Codable, CaseIterable, Hashable {
    case cli            // `claude` running interactively in a terminal
    case desktop        // session spawned from the Claude.app desktop binary
    case cowork         // sandboxed Cowork agent session

    var displayName: String {
        switch self {
        case .cli:     return "Claude Code"
        case .desktop: return "Claude Desktop"
        case .cowork:  return "Cowork"
        }
    }

    var icon: String {
        switch self {
        case .cli:     return "terminal"
        case .desktop: return "macwindow"
        case .cowork:  return "cube.transparent"
        }
    }
}

/// A single Claude session unified across CLI / Desktop / Cowork.
struct UnifiedSession: Identifiable, Hashable {
    let id: String                  // stable: "{kind}:{primaryKey}"
    let kind: SessionKind
    let title: String               // human-readable title or fallback
    let model: String?              // e.g. "claude-sonnet-4-6"
    let cwd: String?
    let pid: Int32?                 // owning process PID, if known
    let sessionId: String           // Claude's own session UUID
    let lastActivity: Date
    let isRunning: Bool             // whether the owning process is alive

    /// mtime of the session's JSONL transcript. Written continuously while Claude
    /// executes tools; goes stale the moment Claude finishes and waits for input.
    /// nil for surfaces that don't have a known transcript path (Desktop, Cowork).
    let transcriptMtime: Date?

    /// Backing JSON file path on disk, for "Reveal in Finder" later.
    let sourcePath: String?
}

extension UnifiedSession {
    /// Time-ago for sorting + display.
    var lastActivityAgo: TimeInterval {
        Date().timeIntervalSince(lastActivity)
    }
}
