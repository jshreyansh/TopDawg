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

            let historyTs = (titles[file.sessionId]?.timestamp).map { Date(timeIntervalSince1970: $0 / 1000) }
            let mtime     = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let started   = Date(timeIntervalSince1970: file.startedAt / 1000)

            // Locate the JSONL transcript for this session.
            let transcriptURL: URL? = {
                guard let cwd = file.cwd, !cwd.isEmpty else { return nil }
                let encoded = cwd.replacingOccurrences(of: "/", with: "-")
                let tURL = home
                    .appendingPathComponent(".claude/projects")
                    .appendingPathComponent(encoded)
                    .appendingPathComponent("\(file.sessionId).jsonl")
                return FileManager.default.fileExists(atPath: tURL.path) ? tURL : nil
            }()

            let transcriptMtime = transcriptURL.flatMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }

            let lastActivity = [historyTs, mtime, started, transcriptMtime].compactMap { $0 }.max() ?? started

            // Claude Code writes {"type":"last-prompt"} the instant it returns the
            // input prompt to the user. If that's the last entry, the session is idle.
            // Any other last type (assistant, tool_use, tool_result, user…) means
            // Claude is mid-execution. No transcript at all → not yet processing.
            let isActivelyProcessing: Bool = {
                guard alive, let tURL = transcriptURL else { return false }
                return lastTranscriptEntryType(at: tURL) != "last-prompt"
            }()

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
                isActivelyProcessing: isActivelyProcessing,
                sourcePath: url.path
            ))
        }

        return out
    }

    // MARK: - Transcript state

    /// Reads the last JSON line of the JSONL transcript and returns its "type" field.
    /// Reads only the final 4 KB to avoid loading large files into memory.
    private func lastTranscriptEntryType(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let readSize = min(size, 4096)
        guard (try? handle.seek(toOffset: size - readSize)) != nil,
              let data = try? handle.readToEnd(),
              let str = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = str.split(separator: "\n", omittingEmptySubsequences: true).last,
              let lineData = String(lastLine).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return nil }
        return json["type"] as? String
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
