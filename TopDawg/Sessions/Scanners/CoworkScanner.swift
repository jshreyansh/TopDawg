import Foundation

/// Walks `~/Library/Application Support/Claude/local-agent-mode-sessions/{accountUuid}/{orgUuid}/local_*.json`
/// and emits one UnifiedSession per file. Cowork sessions store rich metadata
/// (title, model, lastActivity) so we don't need history fallbacks.
struct CoworkScanner {

    private struct CoworkSessionFile: Decodable {
        let sessionId: String            // "local_..."
        let processName: String?         // human slug, e.g. "gallant-ecstatic-ride"
        let cliSessionId: String?
        let cwd: String?
        let createdAt: Double            // Unix ms
        let lastActivityAt: Double       // Unix ms
        let model: String?
        let isArchived: Bool?
        let title: String?
        let vmProcessName: String?
    }

    func scan() -> [UnifiedSession] {
        let baseDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Claude/local-agent-mode-sessions", isDirectory: true)

        guard let baseDir,
              let enumerator = FileManager.default.enumerator(
                at: baseDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let decoder = JSONDecoder()
        var out: [UnifiedSession] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("local_") else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(CoworkSessionFile.self, from: data) else {
                continue
            }
            if file.isArchived == true { continue }

            let title = file.title
                ?? file.processName
                ?? "Cowork \(file.sessionId.prefix(12))"

            let lastActivity = Date(timeIntervalSince1970: file.lastActivityAt / 1000)

            // Cowork sessions don't expose a host-side PID — they run inside a VM —
            // so "isRunning" is decided by recency. 5 min is a generous heuristic
            // (will get refined when we add the AppleScript probe in v2).
            let isRunning = Date().timeIntervalSince(lastActivity) < 5 * 60

            out.append(UnifiedSession(
                id: "\(SessionKind.cowork.rawValue):\(file.sessionId)",
                kind: .cowork,
                title: title,
                model: file.model,
                cwd: file.cwd,
                pid: nil,
                sessionId: file.sessionId,
                lastActivity: lastActivity,
                isRunning: isRunning,
                isActivelyProcessing: false,
                sourcePath: url.path
            ))
        }

        return out
    }
}
