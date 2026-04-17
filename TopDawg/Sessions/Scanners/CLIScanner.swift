import Foundation

/// Reads `~/.claude/sessions/*.json` and `~/.claude/history.jsonl` to discover
/// every Claude Code session that ever started, marking each as running/dead via
/// `ProcessProbe`.
struct CLIScanner {

    /// Per-session record stored as `~/.claude/sessions/{pid}.json`.
    private struct CLISessionFile: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let startedAt: Double            // Unix ms
        let kind: String?
        let entrypoint: String?
    }

    /// One line of `~/.claude/history.jsonl`.
    private struct HistoryEntry: Decodable {
        let display: String?
        let timestamp: Double            // Unix ms
        let project: String?
        let sessionId: String?
    }

    func scan() -> [UnifiedSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        let historyURL  = home.appendingPathComponent(".claude/history.jsonl")

        // Build a sessionId → (latestDisplay, latestTimestamp) index from history.
        let titles = readTitleIndex(historyURL: historyURL)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        var out: [UnifiedSession] = []

        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(CLISessionFile.self, from: data) else {
                continue
            }

            // Discriminate Desktop-spawned sessions via the `entrypoint` field.
            let kind: SessionKind = (file.entrypoint == "claude-desktop") ? .desktop : .cli

            let alive = ProcessProbe.isAlive(file.pid)

            // Derive title: latest user message for this session, else cwd basename.
            let titleFromHistory = titles[file.sessionId]?.display
            let cwdBasename = (file.cwd as NSString?)?.lastPathComponent
            let title = titleFromHistory
                ?? cwdBasename
                ?? "Session \(file.sessionId.prefix(8))"

            // Last activity = max(history ts, session file mtime, transcript mtime, startedAt).
            // The JSONL transcript is written continuously while Claude executes tools,
            // so its mtime is the most reliable indicator of "actively processing".
            let historyTs = (titles[file.sessionId]?.timestamp).map { Date(timeIntervalSince1970: $0 / 1000) }
            let mtime     = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let started   = Date(timeIntervalSince1970: file.startedAt / 1000)

            let transcriptMtime: Date? = {
                guard let cwd = file.cwd, !cwd.isEmpty else { return nil }
                let encoded = cwd.replacingOccurrences(of: "/", with: "-")
                let tURL = home
                    .appendingPathComponent(".claude/projects")
                    .appendingPathComponent(encoded)
                    .appendingPathComponent("\(file.sessionId).jsonl")
                return try? tURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }()

            let lastActivity = [historyTs, mtime, started, transcriptMtime].compactMap { $0 }.max() ?? started

            out.append(UnifiedSession(
                id: "\(kind.rawValue):\(file.sessionId)",
                kind: kind,
                title: title,
                model: nil,                  // CLI session files don't record the model
                cwd: file.cwd,
                pid: file.pid,
                sessionId: file.sessionId,
                lastActivity: lastActivity,
                isRunning: alive,
                transcriptMtime: transcriptMtime,
                sourcePath: url.path
            ))
        }

        return out
    }

    // MARK: - History indexing

    /// Streams `history.jsonl` and keeps only the latest message per sessionId.
    private func readTitleIndex(historyURL: URL) -> [String: HistoryEntry] {
        guard let raw = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return [:]
        }
        let decoder = JSONDecoder()
        var index: [String: HistoryEntry] = [:]

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(HistoryEntry.self, from: data),
                  let sid = entry.sessionId else {
                continue
            }
            if let existing = index[sid], existing.timestamp >= entry.timestamp {
                continue
            }
            index[sid] = entry
        }
        return index
    }
}
