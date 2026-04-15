import SwiftUI

/// A single session row inside `SessionsPanelView`. Click → focus the owning
/// terminal/app via `WindowFocuser`.
struct SessionRowView: View {
    let session: UnifiedSession

    var body: some View {
        Button(action: { WindowFocuser.focus(session) }) {
            HStack(spacing: 8) {
                statusDot
                    .frame(width: 6, height: 6)

                Image(systemName: session.kind.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 14)

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
                                .foregroundColor(.white.opacity(0.45))
                        }
                        if let cwd = session.cwd {
                            Text(cwdShort(cwd))
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 4)

                Text(timeAgo(session.lastActivity))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.03))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusDot: some View {
        Circle()
            .fill(session.isRunning ? Color.green : Color.gray.opacity(0.5))
    }

    private func modelShort(_ model: String) -> String {
        // "claude-sonnet-4-6" → "sonnet 4.6"
        let lower = model.lowercased()
        if lower.contains("opus")    { return "opus" }
        if lower.contains("sonnet")  { return "sonnet" }
        if lower.contains("haiku")   { return "haiku" }
        return model
    }

    private func cwdShort(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60        { return "now" }
        if secs < 3600      { return "\(secs / 60)m" }
        if secs < 86_400    { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }
}
