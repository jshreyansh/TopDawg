import SwiftUI

/// The new "Sessions" page in the notch dropdown — primary panel of v1.
/// Lists every running/recent Claude session across CLI, Desktop, and Cowork,
/// grouped by kind, with click-to-focus.
struct SessionsPanelView: View {
    @ObservedObject var registry: SessionRegistry
    var onOpenChat: ((UnifiedSession) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            thinDivider

            if registry.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(SessionKind.allCases, id: \.self) { kind in
                            let group = registry.sessions(of: kind)
                            if !group.isEmpty {
                                groupSection(kind: kind, sessions: group)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if !WindowFocuser.hasAccessibilityPermission {
                accessibilityPrimer
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Text("\(registry.runningCount) running")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))

            Spacer()

            Button(action: { registry.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    private func groupSection(kind: SessionKind, sessions: [UnifiedSession]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.displayName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .padding(.leading, 4)

            ForEach(sessions) { session in
                SessionRowView(session: session, onOpenChat: onOpenChat)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.25))
            Text("No active Claude sessions")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
            Text("Start `claude` in a terminal or open the desktop app.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    private var accessibilityPrimer: some View {
        Button(action: { WindowFocuser.requestAccessibilityPermission() }) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundColor(.claudeAmber)
                Text("Grant Accessibility to enable click-to-focus")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.claudeAmber.opacity(0.08))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}
