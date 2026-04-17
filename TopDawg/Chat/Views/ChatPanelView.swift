import SwiftUI
import Darwin

// MARK: - Live journal watcher

/// Watches a session's JSONL transcript file for writes and incrementally
/// appends new messages as Claude produces them. Owned by ChatPanelView via
/// @StateObject so it survives SwiftUI identity changes within one open session.
@MainActor
private final class JournalWatcher: ObservableObject {
    @Published var messages:    [ChatMessage] = []
    @Published var totalTokens: Int           = 0
    @Published var isLoading:   Bool          = true

    private var source:       DispatchSourceFileSystemObject?
    private var pollSource:   DispatchSourceTimer?
    private var watchedURL:   URL?
    private var fileOffset:   Int = 0

    func start(session: UnifiedSession) {
        guard let url = ConversationParser.expectedTranscriptURL(for: session) else {
            isLoading = false
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            beginWatching(url: url)
        } else {
            // File not created yet (new session). Poll every second until it appears.
            pollUntilExists(url: url)
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        pollSource?.cancel()
        pollSource = nil
    }

    private func pollUntilExists(url: URL) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            timer.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollSource = nil
                self.beginWatching(url: url)
            }
        }
        timer.resume()
        pollSource = timer
    }

    private func beginWatching(url: URL) {
        watchedURL = url
        load(url: url, fromOffset: 0, isInitial: true)
        watch(url: url)
    }

    private func load(url: URL, fromOffset offset: Int, isInitial: Bool) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let (msgs, newOffset) = ConversationParser.parseIncremental(url: url, fromOffset: offset)
            let tokens = msgs.compactMap(\.tokenUsage).reduce(0) { $0 + $1.total }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if isInitial {
                    self.messages    = msgs
                    self.totalTokens = tokens
                } else if !msgs.isEmpty {
                    self.messages.append(contentsOf: msgs)
                    self.totalTokens += tokens
                }
                self.fileOffset = newOffset
                self.isLoading  = false
            }
        }
    }

    private func watch(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let url = self.watchedURL else { return }
                self.load(url: url, fromOffset: self.fileOffset, isInitial: false)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}

// MARK: - Chat Panel

/// Full conversation view for a Claude Code session, shown inside the notch panel.
/// Reads the session's JSONL transcript live via DispatchSource file watching and
/// lets the user send new messages directly to the running CLI session.
struct ChatPanelView: View {
    let session: UnifiedSession
    let onBack:  () -> Void

    @StateObject private var watcher = JournalWatcher()
    @State private var inputText   = ""
    @State private var isSending   = false
    @State private var sendError:  String? = nil
    @State private var scrollID    = UUID()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            divider
            content
            if session.isRunning {
                divider
                inputBar
            }
        }
        .onAppear { watcher.start(session: session) }
        .onDisappear { watcher.stop() }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 6) {
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

            VStack(spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                if watcher.totalTokens > 0 {
                    Text(tokenLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.32))
                }
            }

            Spacer()

            if session.isRunning {
                ProcessingSpinner(size: 12, color: .claudeTeal)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var tokenLabel: String {
        let n = watcher.totalTokens
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1_000     { return "\(n / 1_000)k tok" }
        return "\(n) tok"
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if watcher.isLoading {
            loadingView
        } else if watcher.messages.isEmpty {
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
                .foregroundColor(.white.opacity(0.40))
            Text(session.isRunning
                 ? "Type a message below to start."
                 : "Session ended — no transcript found.")
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
                    ForEach(watcher.messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    Color.clear.frame(height: 1).id(scrollID)
                }
                .padding(.vertical, 6)
            }
            .onChange(of: watcher.messages.count) { _ in
                withAnimation { proxy.scrollTo(scrollID, anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo(scrollID, anchor: .bottom)
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let err = sendError {
                Text(err)
                    .font(.system(size: 9))
                    .foregroundColor(.claudeAlert)
                    .padding(.horizontal, 10)
                    .padding(.top, 5)
                    .transition(.opacity)
            }

            HStack(spacing: 6) {
                TextField("Message Claude…", text: $inputText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .foregroundColor(.white.opacity(0.90))
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }

                if isSending {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 18, height: 18)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(
                                canSend ? .claudeTeal : .claudeTeal.opacity(0.25)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color.white.opacity(0.04))
        .animation(.easeInOut(duration: 0.15), value: sendError != nil)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }

    // MARK: - Send

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        isSending = true
        sendError = nil

        Task {
            do {
                try await TerminalMessenger.send(text, to: session)
            } catch {
                sendError = error.localizedDescription
            }
            isSending = false
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
        return t.count > 200 ? String(t.prefix(200)) + "…" : t
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
