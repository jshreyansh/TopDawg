import SwiftUI

struct SessionsPanelView: View {
    @ObservedObject var registry: SessionRegistry
    var onOpenChat: ((UnifiedSession) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.vertical, 5)

            if registry.sessions.isEmpty {
                emptyState
            } else {
                sessionsList
            }

            Spacer(minLength: 0)

            if !WindowFocuser.hasAccessibilityPermission {
                accessibilityPrimer
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.claudeTeal)
                .frame(width: 6, height: 6)

            Text("sessions")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))

            if registry.runningCount > 0 {
                Text("\(registry.runningCount) running")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.claudeTeal.opacity(0.65))
            } else if !registry.sessions.isEmpty {
                Text("\(registry.sessions.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
            }

            Spacer()

            Button(action: { NewSessionLauncher.launch() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.claudeTeal.opacity(0.14))
                    Image(systemName: "plus")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.claudeTeal.opacity(0.75))
                }
                .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
            .help("Start new Claude Code session")

            Button(action: { registry.refresh() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.06))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sessions list

    private var sessionsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SessionKind.allCases, id: \.self) { kind in
                    let group = registry.sessions(of: kind)
                    if !group.isEmpty {
                        groupSection(kind: kind, sessions: group)
                    }
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Group section

    private func groupSection(kind: SessionKind, sessions: [UnifiedSession]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(kind.displayName.lowercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.25))
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 1)

            ForEach(sessions) { session in
                SessionRowView(session: session, onOpenChat: onOpenChat)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.10 - Double(i) * 0.025))
                        .frame(width: 5, height: 5)
                }
            }
            Text("no active sessions")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.28))
            Text("start claude in a terminal or open the desktop app")
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.white.opacity(0.16))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    // MARK: - Accessibility primer

    private var accessibilityPrimer: some View {
        Button(action: { WindowFocuser.requestAccessibilityPermission() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.claudeAmber)
                    .frame(width: 5, height: 5)
                Text("grant accessibility to focus windows")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.25))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.claudeAmber.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.claudeAmber.opacity(0.15), lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
