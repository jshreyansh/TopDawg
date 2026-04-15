import SwiftUI

/// A single session row inside `SessionsPanelView`.
/// - Tap the row body → open the chat panel for this session.
/// - Tap the terminal icon → focus the owning terminal/app (previous behavior).
struct SessionRowView: View {
    let session: UnifiedSession
    var onOpenChat: ((UnifiedSession) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // ── Status dot ──────────────────────────────────────────────────
            Circle()
                .fill(session.isRunning ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)

            // ── Kind icon ───────────────────────────────────────────────────
            Image(systemName: session.kind.icon)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 14)

            // ── Title + subtitle ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    if let model = session.model {
                        Text(modelShort(model))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.40))
                    }
                    if let cwd = session.cwd {
                        Text(cwdShort(cwd))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.28))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 4)

            // ── Time + action icons ─────────────────────────────────────────
            HStack(spacing: 6) {
                Text(timeAgo(session.lastActivity))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.28))

                // Chat button (visible on hover)
                if isHovered {
                    Button(action: { onOpenChat?(session) }) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.claudeTeal.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("View conversation")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))

                    // Focus terminal button
                    Button(action: { WindowFocuser.focus(session) }) {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Focus terminal")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovered ? 0.06 : 0.03))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onTapGesture {
            // Primary tap opens chat view
            onOpenChat?(session)
        }
    }

    // MARK: - Helpers

    private func modelShort(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus")   { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku")  { return "haiku" }
        return model
    }

    private func cwdShort(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60     { return "now" }
        if secs < 3600   { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }
}
