import SwiftUI

/// The "something wants to run" panel that takes over the notch dropdown when a
/// PermissionRequest hook fires. Designed to be readable at a glance from across
/// the room, with a short-enough countdown bar to feel urgent without being pushy.
struct ApprovalOverlayView: View {

    @ObservedObject var pending: PendingApprovals
    let onResolve: (UUID, ApprovalDecision) -> Void

    // Countdown (purely visual — real timeout lives in ApprovalServer)
    @State private var progress: Double = 1.0
    @State private var timerToken = UUID()

    private let timeoutSeconds: Double = 120

    var body: some View {
        if let req = pending.current {
            content(for: req)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
                .id(req.id)
                .onAppear { startCountdown(for: req) }
        } else {
            EmptyView()
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(for req: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            header(for: req)

            // Divider
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                .padding(.horizontal, -16)
                .padding(.vertical, 10)

            // Preview body
            detailBody(for: req)

            Spacer(minLength: 8)

            // Countdown
            countdownBar

            Spacer(minLength: 10)

            // Actions
            actions(for: req)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(for req: ApprovalRequest) -> some View {
        HStack(spacing: 10) {
            // Animated pulsing dot
            PulseDot()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: req.toolIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.claudeCoralLight)
                    Text(req.toolName.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(.claudeCoralLight)

                    if pending.overflow > 0 {
                        Text("+\(pending.overflow) more")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.white.opacity(0.08))
                            )
                    }
                }

                Text(req.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
    }

    // MARK: - Body

    private func detailBody(for req: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !req.contextBadge.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.35))
                    Text(req.contextBadge)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                Text(req.detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 110)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    // MARK: - Countdown

    private var countdownBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: progress < 0.25
                                ? [.claudeAlert, .claudeCoral]
                                : [.claudeCoralLight, .claudeCoral],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 2)
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(for req: ApprovalRequest) -> some View {
        HStack(spacing: 6) {
            // Deny — quiet, on the left
            actionButton(
                title: "Deny",
                icon: "xmark",
                kind: .quiet
            ) {
                onResolve(req.id, .deny)
            }

            Spacer(minLength: 0)

            // Allow once — primary
            actionButton(
                title: "Allow once",
                icon: "checkmark",
                kind: .primary
            ) {
                onResolve(req.id, .allow)
            }

            // Allow always — stronger, emphasised
            actionButton(
                title: "Always",
                icon: "checkmark.seal.fill",
                kind: .accent
            ) {
                onResolve(req.id, .allowAlways)
            }
        }
    }

    // MARK: - Button styling

    private enum ButtonKind { case quiet, primary, accent }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        kind: ButtonKind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(foreground(for: kind))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minWidth: 72)
            .background(background(for: kind))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(stroke(for: kind), lineWidth: 1)
            )
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foreground(for kind: ButtonKind) -> Color {
        switch kind {
        case .quiet:   return .white.opacity(0.65)
        case .primary: return .white
        case .accent:  return .white
        }
    }

    @ViewBuilder
    private func background(for kind: ButtonKind) -> some View {
        switch kind {
        case .quiet:
            Color.white.opacity(0.04)
        case .primary:
            LinearGradient(
                colors: [.claudeTeal.opacity(0.85), .claudeTeal.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
        case .accent:
            LinearGradient(
                colors: [.claudeCoralLight, .claudeCoral],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private func stroke(for kind: ButtonKind) -> Color {
        switch kind {
        case .quiet:   return .white.opacity(0.08)
        case .primary: return .claudeTeal.opacity(0.4)
        case .accent:  return .claudeCoralLight.opacity(0.4)
        }
    }

    // MARK: - Countdown logic

    private func startCountdown(for req: ApprovalRequest) {
        progress = 1.0
        let elapsed = Date().timeIntervalSince(req.receivedAt)
        let remaining = max(0, timeoutSeconds - elapsed)
        guard remaining > 0 else { progress = 0; return }
        progress = remaining / timeoutSeconds
        withAnimation(.linear(duration: remaining)) {
            progress = 0
        }
    }
}

// MARK: - Pulse dot

private struct PulseDot: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.claudeCoral.opacity(on ? 0.0 : 0.4))
                .scaleEffect(on ? 2.0 : 1.0)
                .frame(width: 10, height: 10)
                .animation(
                    .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                    value: on
                )
            Circle()
                .fill(Color.claudeCoral)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { on = true }
    }
}
