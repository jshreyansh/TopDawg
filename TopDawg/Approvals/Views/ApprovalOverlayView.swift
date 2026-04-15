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

    // MARK: - Actions (hover-invert ActionButtons with staggered entry)

    @ViewBuilder
    private func actions(for req: ApprovalRequest) -> some View {
        HStack(spacing: 6) {
            // Deny — appears first
            ActionButton("Deny", icon: "xmark", color: .white.opacity(0.55)) {
                onResolve(req.id, .deny)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))

            Spacer(minLength: 0)

            // Allow once — appears 0.08s later
            ActionButton("Allow once", icon: "checkmark", color: .claudeTeal) {
                onResolve(req.id, .allow)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))

            // Always — appears 0.16s later
            ActionButton("Always", icon: "checkmark.seal.fill", color: .claudeCoralLight) {
                onResolve(req.id, .allowAlways)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
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
