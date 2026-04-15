import SwiftUI

// MARK: - Single stat label (used in the notch bar)

struct BarStatLabel: View {
    let label: String
    let percentage: Double
    var pacing: ClaudeStatsPacingData?
    let resetsAt: Date?
    let pacingMode: ClaudeStatsPacingDisplayMode
    let fontSize: CGFloat

    private var color: Color {
        if percentage >= 90 { return .claudeAlert }
        if percentage >= 75 { return .claudeAmber }
        if percentage >= 50 { return .claudeCoral }
        return .claudeTeal
    }

    private var timeLeft: String? {
        guard pacingMode == .arrowWithTime,
              let resetsAt, resetsAt > Date() else { return nil }
        let secs = resetsAt.timeIntervalSince(Date())
        let mins = Int(secs / 60)
        let hours = mins / 60
        let days = hours / 24
        if days > 0 { return "\(days)d" }
        if hours > 0 {
            let m = mins % 60
            return m > 0 ? "\(hours)h\(m)m" : "\(hours)h"
        }
        return "\(mins)m"
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.55))

            Text("\(Int(percentage))%")
                .font(.system(size: fontSize + 1, weight: .bold, design: .rounded))
                .foregroundColor(color)

            if pacingMode != .hidden, let pacing {
                Text(pacing.state.arrow)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(pacing.state.color)
            }

            if let t = timeLeft {
                Text(t)
                    .font(.system(size: fontSize - 1))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}
