import Foundation

/// Parses Claude Code's JSONL conversation files into `ChatMessage` arrays.
///
/// File location: `~/.claude/projects/{cwd_encoded}/{sessionId}.jsonl`
/// where `cwd_encoded` = the working directory path with every `/` replaced by `-`.
struct ConversationParser {

    // MARK: - Public API

    /// Returns the URL of the JSONL transcript for `session`, or nil if not found.
    static func transcriptURL(for session: UnifiedSession) -> URL? {
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Encode: "/Users/alice/Proj" → "-Users-alice-Proj"
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")

        let url = home
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(session.sessionId).jsonl")

        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Parse a JSONL transcript URL into an ordered array of chat messages.
    /// Only `user` and `assistant` record types are surfaced; internal queue ops are skipped.
    static func parse(url: URL) -> [ChatMessage] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var out: [ChatMessage] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch obj["type"] as? String {
            case "user":
                if let m = parseUser(obj) { out.append(m) }
            case "assistant":
                if let m = parseAssistant(obj) { out.append(m) }
            default:
                break
            }
        }
        return out
    }

    // MARK: - Per-type parsers

    private static func parseUser(_ obj: [String: Any]) -> ChatMessage? {
        guard let message  = obj["message"]   as? [String: Any],
              let uuid      = obj["uuid"]      as? String,
              let timestamp = parseTimestamp(obj["timestamp"])
        else { return nil }

        let blocks = parseContent(message["content"])
        guard !blocks.isEmpty else { return nil }
        return ChatMessage(id: uuid, role: .user, blocks: blocks,
                           timestamp: timestamp, tokenUsage: nil)
    }

    private static func parseAssistant(_ obj: [String: Any]) -> ChatMessage? {
        guard let message  = obj["message"]   as? [String: Any],
              let uuid      = obj["uuid"]      as? String,
              let timestamp = parseTimestamp(obj["timestamp"])
        else { return nil }

        let blocks = parseContent(message["content"])
        guard !blocks.isEmpty else { return nil }

        let usage: ChatMessage.TokenUsage?
        if let u = message["usage"] as? [String: Any] {
            usage = ChatMessage.TokenUsage(
                inputTokens:         u["input_tokens"]                as? Int ?? 0,
                outputTokens:        u["output_tokens"]               as? Int ?? 0,
                cacheReadTokens:     u["cache_read_input_tokens"]     as? Int ?? 0,
                cacheCreationTokens: u["cache_creation_input_tokens"] as? Int ?? 0
            )
        } else {
            usage = nil
        }

        return ChatMessage(id: uuid, role: .assistant, blocks: blocks,
                           timestamp: timestamp, tokenUsage: usage)
    }

    // MARK: - Content blocks

    private static func parseContent(_ raw: Any?) -> [ChatMessage.ContentBlock] {
        // Claude returns content as either a plain String or an array of typed blocks.
        if let str = raw as? String, !str.isEmpty {
            return [.text(str)]
        }
        guard let array = raw as? [[String: Any]] else { return [] }

        return array.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let t = block["text"] as? String, !t.isEmpty else { return nil }
                return .text(t)

            case "thinking":
                guard let t = block["thinking"] as? String, !t.isEmpty else { return nil }
                return .thinking(t)

            case "tool_use":
                guard let id   = block["id"]   as? String,
                      let name = block["name"] as? String else { return nil }
                let inputJSON: String
                if let inp = block["input"] {
                    let d = try? JSONSerialization.data(withJSONObject: inp,
                                                       options: [.prettyPrinted, .sortedKeys])
                    inputJSON = d.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                } else {
                    inputJSON = "{}"
                }
                return .toolUse(id: id, name: name, inputJSON: inputJSON)

            case "tool_result":
                guard let toolId = block["tool_use_id"] as? String else { return nil }
                let isError = block["is_error"] as? Bool ?? false
                let content: String
                if let str = block["content"] as? String {
                    content = str
                } else if let arr = block["content"] as? [[String: Any]] {
                    content = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    content = ""
                }
                return .toolResult(toolUseId: toolId, content: content, isError: isError)

            default:
                return nil
            }
        }
    }

    // MARK: - Timestamp

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let str = value as? String {
            // ISO 8601 with and without fractional seconds
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: str) { return d }
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.date(from: str)
        }
        if let ms = value as? Double {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }
}
