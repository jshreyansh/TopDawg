import Foundation

/// Appends "permissions.allow" entries to ~/.claude/settings.json when the user picks
/// "Always" in the notch overlay. Best-effort and conservative: we only write rules
/// we can derive a safe pattern for (Bash exact-command prefix, Edit/Write/Read bare
/// tool name). For everything else we fall back to adding the bare tool name, which
/// Claude Code treats as "allow this tool unconditionally".
enum ApprovalRuleWriter {

    static func appendAllowRule(for req: ApprovalRequest) {
        let rule = derivedRule(from: req)
        guard !rule.isEmpty else { return }
        do {
            try appendRule(rule)
        } catch {
            // Silent failure — the one-time allow still went through.
            NSLog("[TopDawg] Could not append allow rule: \(error)")
        }
    }

    // MARK: - Rule derivation

    private static func derivedRule(from req: ApprovalRequest) -> String {
        switch req.toolName {
        case "Bash":
            if let cmd = firstString(req.toolInputJSON, key: "command") {
                // Use the first token as the prefix so "git status" allows "git *".
                // This matches Claude Code's common pattern: Bash(prefix:*).
                let firstToken = cmd.split(separator: " ").first.map(String.init) ?? ""
                if !firstToken.isEmpty, !firstToken.contains("'"), !firstToken.contains("\"") {
                    return "Bash(\(firstToken):*)"
                }
            }
            return "Bash"
        case "Edit", "MultiEdit", "Write", "Read":
            // Scoping by file path is brittle; allow the tool broadly.
            return req.toolName
        default:
            return req.toolName
        }
    }

    // MARK: - File I/O

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private static func appendRule(_ rule: String) throws {
        let url = settingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root: [String: Any] = {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return obj
        }()

        var permissions: [String: Any] = root["permissions"] as? [String: Any] ?? [:]
        var allow: [String] = permissions["allow"] as? [String] ?? []

        if !allow.contains(rule) {
            allow.append(rule)
            permissions["allow"] = allow
            root["permissions"] = permissions

            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func firstString(_ json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }
}
