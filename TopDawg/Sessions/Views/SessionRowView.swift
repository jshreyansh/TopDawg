import SwiftUI

struct SessionRowView: View {
    let session: UnifiedSession
    var onOpenChat: ((UnifiedSession) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Status dot — pulsing when running
            statusDot

            // Title + metadata
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let model = session.model {
                        Text(modelShort(model))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.28))
                    }
                }

                if let cwd = session.cwd {
                    Text(cwdShort(cwd))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.22))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            // Time + hover actions
            HStack(spacing: 8) {
                if isHovered {
                    Button(action: { onOpenChat?(session) }) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 10))
                            .foregroundColor(.claudeTeal.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("View conversation")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    Button(action: { WindowFocuser.focus(session) }) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.30))
                    }
                    .buttonStyle(.plain)
                    .help("Focus terminal")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    Text(timeAgo(session.lastActivity))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.20))
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onOpenChat?(session) }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
    }

    // MARK: - Status dot

    @ViewBuilder
    private var statusDot: some View {
        if session.isRunning {
            ZStack {
                Circle()
                    .fill(Color.claudeTeal.opacity(0.3))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(Color.claudeTeal)
                    .frame(width: 5, height: 5)
            }
        } else {
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 5, height: 5)
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
