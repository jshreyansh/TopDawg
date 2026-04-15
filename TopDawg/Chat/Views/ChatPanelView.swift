import SwiftUI

// MARK: - Chat Panel

/// Full conversation view for a Claude Code session, shown inside the notch dropdown.
/// Reads the session's JSONL transcript from disk and renders messages in real-time.
struct ChatPanelView: View {
    let session: UnifiedSession
    let onBack: () -> Void

    @State private var messages:    [ChatMessage] = []
    @State private var isLoading    = true
    @State private var totalTokens  = 0
    @State private var scrollAnchor = UUID()

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            divider
            content
        }
        .onAppear { loadMessages() }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 6) {
            // Back
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                    Text("Sessions")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Spacer()

            // Session title + tokens
            VStack(spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                if totalTokens > 0 {
                    Text(tokenLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.32))
                }
            }

            Spacer()

            // Live status dot
            HStack(spacing: 4) {
                if session.isRunning {
                    ProcessingSpinner(size: 12, color: .claudeTeal)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var tokenLabel: String {
        let n = totalTokens
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1_000     { return "\(n / 1_000)k tok" }
        return "\(n) tok"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if isLoading {
            loadingView
        } else if messages.isEmpty {
            emptyView
        } else {
            messageList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProcessingSpinner(size: 16)
            Text("Loading conversation…")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.18))
            Text("No messages yet")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            Text("Start chatting in the terminal to see the conversation here.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    // Invisible anchor at the bottom for auto-scroll
                    Color.clear.frame(height: 1).id(scrollAnchor)
                }
                .padding(.vertical, 6)
            }
            .onChange(of: messages.count) { _ in
                withAnimation { proxy.scrollTo(scrollAnchor, anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo(scrollAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: - Data

    private func loadMessages() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = ConversationParser.transcriptURL(for: session) else {
                DispatchQueue.main.async { isLoading = false }
                return
            }
            let parsed = ConversationParser.parse(url: url)
            let tokens = parsed
                .compactMap(\.tokenUsage)
                .reduce(0) { $0 + $1.total }

            DispatchQueue.main.async {
                messages   = parsed
                totalTokens = tokens
                isLoading  = false
            }
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack(alignment: .top) {
                Spacer(minLength: 20)
                userContent
            }
        } else {
            HStack(alignment: .top) {
                assistantContent
                Spacer(minLength: 20)
            }
        }
    }

    // MARK: User

    private var userContent: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(message.blocks) { block in
                if case .text(let t) = block {
                    Text(t)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.claudeCoralLight.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.claudeCoralLight.opacity(0.22), lineWidth: 0.5)
                        )
                        .cornerRadius(10)
                }
            }
        }
    }

    // MARK: Assistant

    @ViewBuilder private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.blocks) { block in
                switch block {
                case .text(let t):
                    InlineMarkdown(text: t)
                        .foregroundColor(.white.opacity(0.88))
                        .textSelection(.enabled)

                case .thinking(let t):
                    ThinkingBlock(text: t)

                case .toolUse(_, let name, let inputJSON):
                    ToolUseChip(name: name, inputJSON: inputJSON)

                case .toolResult(_, let content, let isError):
                    ToolResultChip(content: content, isError: isError)
                }
            }

            // Token badge on last assistant block
            if let usage = message.tokenUsage {
                Text(usage.formatted + " tok")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.22))
                    .padding(.top, 1)
            }
        }
    }
}

// MARK: - Inline Markdown

/// Renders text with basic markdown via AttributedString (macOS 12+).
/// Falls back to plain Text on older systems.
private struct InlineMarkdown: View {
    let text: String

    var body: some View {
        if #available(macOS 12.0, *) {
            let attr = (try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )) ?? AttributedString(text)
            Text(attr)
                .font(.system(size: 11))
                .lineSpacing(2)
        } else {
            Text(text)
                .font(.system(size: 11))
                .lineSpacing(2)
        }
    }
}

// MARK: - Thinking block

private struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Thinking")
                        .font(.system(size: 9, weight: .medium))
                    if !expanded {
                        Text("·  \(text.prefix(40))…")
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                }
                .foregroundColor(.white.opacity(0.28))
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                    .italic()
                    .lineLimit(25)
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
    }
}

// MARK: - Tool Use Chip

private struct ToolUseChip: View {
    let name: String
    let inputJSON: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 5) {
                    Image(systemName: icon(for: name))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.claudeAmber)
                    Text(name)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.3)
                        .foregroundColor(.claudeAmber)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                        .foregroundColor(.claudeAmber.opacity(0.5))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(inputJSON)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(12)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 5)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.claudeAmber.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.claudeAmber.opacity(0.18), lineWidth: 0.5)
        )
        .cornerRadius(6)
    }

    private func icon(for name: String) -> String {
        switch name {
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
}

// MARK: - Tool Result Chip

private struct ToolResultChip: View {
    let content: String
    let isError: Bool

    private var trimmed: String {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 200
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundColor(isError ? .claudeAlert : .claudeTeal)
                .padding(.top, 1)

            Text(trimmed.isEmpty ? "(empty)" : trimmed)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(isError ? 0.6 : 0.45))
                .lineLimit(6)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .cornerRadius(6)
    }
}
