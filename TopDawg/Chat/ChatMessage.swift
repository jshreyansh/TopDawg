import Foundation

// MARK: - Chat Message

struct ChatMessage: Identifiable {
    let id: String
    let role: MessageRole
    let blocks: [ContentBlock]
    let timestamp: Date
    let tokenUsage: TokenUsage?

    enum MessageRole { case user, assistant }

    enum ContentBlock: Identifiable {
        case text(String)
        case thinking(String)
        case toolUse(id: String, name: String, inputJSON: String)
        case toolResult(toolUseId: String, content: String, isError: Bool)

        var id: String {
            switch self {
            case .text(let s):                  return "txt_\(s.hashValue)"
            case .thinking(let s):              return "thk_\(s.hashValue)"
            case .toolUse(let id, _, _):        return "tu_\(id)"
            case .toolResult(let id, _, _):     return "tr_\(id)"
            }
        }
    }

    struct TokenUsage {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int

        var total: Int { inputTokens + outputTokens }

        var formatted: String {
            let t = total
            return t >= 1000 ? "\(t / 1000)k" : "\(t)"
        }
    }
}
