import SwiftUI
import AppKit

// MARK: - Brand Colors

extension Color {
    static let claudeCoral      = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let claudeCoralLight = Color(red: 0.95, green: 0.60, blue: 0.45)
    static let claudeBeige      = Color(red: 0.96, green: 0.93, blue: 0.88)
    static let claudeTeal       = Color(red: 0.45, green: 0.75, blue: 0.70)
    static let claudeAmber      = Color(red: 0.95, green: 0.70, blue: 0.35)
    static let claudeAlert      = Color(red: 0.90, green: 0.40, blue: 0.35)
}

// MARK: - Stat Item

struct ClaudeStatsStatItem: View {
    let label: String
    let percentage: Double
    let fontSize: CGFloat
    let resetsAt: Date?
    var pacing: ClaudeStatsPacingData? = nil
    var pacingDisplayMode: ClaudeStatsPacingDisplayMode = .arrowWithTime

    private var percentageColor: Color {
        if percentage >= 90 { return .claudeAlert }
        if percentage >= 75 { return .claudeAmber }
        if percentage >= 50 { return .claudeCoral }
        return .claudeTeal
    }

    private var timeRemainingText: String? {
        guard let resetsAt = resetsAt, resetsAt > Date() else { return nil }
        let seconds = resetsAt.timeIntervalSince(Date())
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 {
            let h = hours % 24
            return h > 0 ? "\(days)d \(h)h left" : "\(days)d left"
        } else if hours > 0 {
            let m = minutes % 60
            return m > 0 ? "\(hours)h \(m)m left" : "\(hours)h left"
        }
        return "\(minutes)m left"
    }

    var body: some View {
        VStack(spacing: 1) {
            if pacingDisplayMode == .arrowWithTime, let timeText = timeRemainingText {
                Text(timeText)
                    .font(.system(size: fontSize - 2, weight: .regular))
                    .foregroundColor(.claudeBeige.opacity(0.5))
            }
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: fontSize + 1, weight: .medium))
                    .foregroundColor(.claudeBeige.opacity(0.7))
                HStack(spacing: 2) {
                    Text("\(Int(percentage))%")
                        .font(.system(size: fontSize + 3, weight: .bold, design: .rounded))
                        .foregroundColor(percentageColor)
                    if pacingDisplayMode != .hidden, let pacing = pacing {
                        Text(pacing.state.arrow)
                            .font(.system(size: fontSize + 2, weight: .semibold))
                            .foregroundColor(pacing.state.color)
                    }
                }
            }
        }
    }
}

// MARK: - Main View

struct ClaudeStatsView: View {
    @ObservedObject var manager: ClaudeUsageManager
    @ObservedObject var settings: ClaudeStatsSettings

    var body: some View {
        Group {
            if manager.isAuthenticated {
                authenticatedView
            } else {
                unauthenticatedView
            }
        }
        .padding(.horizontal, settings.sizePreset.horizontalPadding)
        .padding(.top, 0)
        .padding(.bottom, settings.sizePreset.bottomPadding)
        .opacity(manager.isLoading ? 0.7 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: manager.isLoading)
    }

    private var authenticatedView: some View {
        HStack(spacing: settings.sizePreset.statSpacing + 4) {
            ClaudeStatsStatItem(
                label: "Session",
                percentage: manager.usageData.sessionPercentage,
                fontSize: settings.sizePreset.titleFontSize,
                resetsAt: manager.usageData.sessionResetsAt,
                pacing: manager.usageData.sessionPacing,
                pacingDisplayMode: settings.pacingDisplayMode
            )

            Image("ClaudeLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: settings.sizePreset.artworkSize * 1.1)

            ClaudeStatsStatItem(
                label: "Weekly",
                percentage: manager.usageData.weeklyPercentage,
                fontSize: settings.sizePreset.titleFontSize,
                resetsAt: manager.usageData.weeklyResetsAt,
                pacing: manager.usageData.weeklyPacing,
                pacingDisplayMode: settings.pacingDisplayMode
            )

            if manager.usageData.opusPercentage > 0 {
                Rectangle()
                    .fill(Color.claudeBeige.opacity(0.15))
                    .frame(width: 1, height: settings.sizePreset.artworkSize * 0.7)

                ClaudeStatsStatItem(
                    label: "Opus",
                    percentage: manager.usageData.opusPercentage,
                    fontSize: settings.sizePreset.titleFontSize,
                    resetsAt: manager.usageData.opusResetsAt
                )
            }
        }
    }

    private var unauthenticatedView: some View {
        HStack(spacing: 8) {
            Text("Claude")
                .font(.system(size: settings.sizePreset.titleFontSize, weight: .semibold, design: .rounded))
                .foregroundColor(.claudeCoral.opacity(0.5))
            Text("Click menu to login")
                .font(.system(size: settings.sizePreset.artistFontSize + 1, weight: .medium))
                .foregroundColor(.claudeBeige.opacity(0.5))
        }
    }
}
