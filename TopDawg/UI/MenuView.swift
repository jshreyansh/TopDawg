import SwiftUI
import AppKit

struct TopDawgMenuView: View {
    @ObservedObject var manager: ClaudeUsageManager
    @ObservedObject var settings: ClaudeStatsSettings
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image("ClaudeLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text("TopDawg")
                        .font(.system(size: 14, weight: .semibold))
                    if let plan = manager.usageData.planDisplayName {
                        Text(plan)
                            .font(.system(size: 11))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.claudeCoralLight, .claudeCoral],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                }

                Spacer()

                if manager.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if manager.isAuthenticated {
                // Usage summary
                usageSummarySection

                Divider()
            }

            // Settings section
            settingsSection

            Divider()

            // Auth section
            authSection

            Divider()

            // Quit
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                        .frame(width: 16)
                    Text("Quit TopDawg")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.primary)
        }
        .frame(width: 300)
    }

    // MARK: - Usage Summary

    private var usageSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USAGE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            VStack(spacing: 6) {
                usageRow(
                    label: "Session (5h)",
                    percentage: manager.usageData.sessionPercentage,
                    resetsAt: manager.usageData.sessionResetsAt
                )
                usageRow(
                    label: "Weekly (7d)",
                    percentage: manager.usageData.weeklyPercentage,
                    resetsAt: manager.usageData.weeklyResetsAt
                )
                if manager.usageData.sonnetPercentage > 0 {
                    usageRow(
                        label: "Sonnet",
                        percentage: manager.usageData.sonnetPercentage,
                        resetsAt: manager.usageData.sonnetResetsAt
                    )
                }
                if manager.usageData.opusPercentage > 0 {
                    usageRow(
                        label: "Opus",
                        percentage: manager.usageData.opusPercentage,
                        resetsAt: manager.usageData.opusResetsAt
                    )
                }
            }
            .padding(.horizontal, 16)

            if let updated = manager.usageData.lastUpdated {
                HStack {
                    Spacer()
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
            }

            Button(action: { manager.refresh() }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16)
                    Text("Refresh Now")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.accentColor)

            .padding(.bottom, 4)
        }
    }

    private func usageRow(label: String, percentage: Double, resetsAt: Date?) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(colorForPercentage(percentage))
                if let resetsAt = resetsAt, resetsAt > Date() {
                    Text(timeRemaining(resetsAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForPercentage(percentage))
                        .frame(width: geo.size.width * min(percentage / 100, 1.0), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private func colorForPercentage(_ p: Double) -> Color {
        if p >= 90 { return .claudeAlert }
        if p >= 75 { return .claudeAmber }
        if p >= 50 { return .claudeCoral }
        return .claudeTeal
    }

    private func timeRemaining(_ date: Date) -> String {
        let secs = date.timeIntervalSince(Date())
        guard secs > 0 else { return "" }
        let mins = Int(secs / 60)
        let hours = mins / 60
        let days = hours / 24
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            settingRow("Display") {
                Picker("", selection: Binding(
                    get: { settings.assignedDisplayID },
                    set: { settings.assignedDisplayID = $0 }
                )) {
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(screen.displayID)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            settingRow("Size") {
                Picker("", selection: Binding(
                    get: { settings.sizePreset },
                    set: { settings.sizePreset = $0 }
                )) {
                    ForEach(ClaudeStatsSizePreset.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            settingRow("Pacing") {
                Picker("", selection: Binding(
                    get: { settings.pacingDisplayMode },
                    set: { settings.pacingDisplayMode = $0 }
                )) {
                    ForEach(ClaudeStatsPacingDisplayMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            settingRow("Refresh") {
                Picker("", selection: Binding(
                    get: { settings.refreshInterval },
                    set: { settings.refreshInterval = $0 }
                )) {
                    ForEach(ClaudeStatsRefreshInterval.allCases, id: \.self) { i in
                        Text(i.displayName).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
        }
        .padding(.bottom, 8)
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    // MARK: - Auth

    private var authSection: some View {
        Group {
            if manager.isAuthenticated {
                Button(action: { manager.logout() }) {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .frame(width: 16)
                        Text("Logout")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.red)
            } else {
                Button(action: { ClaudeLoginWindowController.shared.showLogin(manager: manager) }) {
                    HStack {
                        Image(systemName: "key.fill")
                            .frame(width: 16)
                        Text("Login to Claude")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.orange)
            }
        }
    }
}
