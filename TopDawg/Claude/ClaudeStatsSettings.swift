import SwiftUI
import ServiceManagement

enum ClaudeStatsSizePreset: String, CaseIterable {
    case small, medium, large, extraLarge

    var displayName: String {
        switch self {
        case .small:      return "Small"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    // Legacy properties kept for ClaudeStatsView compatibility
    var artworkSize: CGFloat      { switch self { case .small: return 26; case .medium: return 32; case .large: return 40; case .extraLarge: return 48 } }
    var earSize: CGFloat          { switch self { case .small: return 10; case .medium: return 12; case .large: return 14; case .extraLarge: return 16 } }
    var artistFontSize: CGFloat   { switch self { case .small: return 7;  case .medium: return 8;  case .large: return 10; case .extraLarge: return 12 } }
    var bottomCornerRadius: CGFloat { switch self { case .small: return 12; case .medium: return 16; case .large: return 20; case .extraLarge: return 24 } }
    var horizontalPadding: CGFloat { switch self { case .small: return 4;  case .medium: return 6;  case .large: return 8;  case .extraLarge: return 10 } }
    var bottomPadding: CGFloat    { switch self { case .small: return 6;  case .medium: return 8;  case .large: return 10; case .extraLarge: return 12 } }
    var statSpacing: CGFloat      { switch self { case .small: return 6;  case .medium: return 8;  case .large: return 10; case .extraLarge: return 12 } }

    var titleFontSize: CGFloat {
        switch self {
        case .small:      return 9
        case .medium:     return 11
        case .large:      return 13
        case .extraLarge: return 15
        }
    }

    var wingWidth: CGFloat {
        switch self {
        case .small:      return 52
        case .medium:     return 64
        case .large:      return 76
        case .extraLarge: return 90
        }
    }
}

enum ClaudeStatsPacingDisplayMode: String, CaseIterable {
    case hidden, arrowOnly, arrowWithTime

    var displayName: String {
        switch self {
        case .hidden:        return "% Only"
        case .arrowOnly:     return "% + Arrow"
        case .arrowWithTime: return "% + Time + Arrow"
        }
    }
}

enum ClaudeStatsRefreshInterval: Int, CaseIterable {
    case oneMinute     = 60
    case twoMinutes    = 120
    case fiveMinutes   = 300
    case tenMinutes    = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var displayName: String {
        switch self {
        case .oneMinute:      return "1 min"
        case .twoMinutes:     return "2 min"
        case .fiveMinutes:    return "5 min"
        case .tenMinutes:     return "10 min"
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes:  return "30 min"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue) }
}

final class ClaudeStatsSettings: ObservableObject {

    // MARK: - Keys
    private static let sizePresetKey         = "cn.sizePreset"
    private static let refreshKey            = "cn.refreshInterval"
    private static let pacingKey             = "cn.pacingDisplayMode"
    private static let displayIDKey          = "cn.displayID"
    private static let alertThresholdKey     = "cn.alertThreshold"
    private static let launchAtLoginKey      = "cn.launchAtLogin"
    private static let timerWorkKey          = "cn.timerWork"
    private static let timerShortBreakKey    = "cn.timerShortBreak"
    private static let timerLongBreakKey     = "cn.timerLongBreak"

    // MARK: - Published

    @Published var sizePreset: ClaudeStatsSizePreset {
        didSet { save() }
    }

    @Published var refreshInterval: ClaudeStatsRefreshInterval {
        didSet { save() }
    }

    @Published var pacingDisplayMode: ClaudeStatsPacingDisplayMode {
        didSet { save() }
    }

    @Published var assignedDisplayID: CGDirectDisplayID {
        didSet { save() }
    }

    /// 0 = off, otherwise notify when any stat crosses this % (e.g. 80, 90, 95)
    @Published var alertThreshold: Int {
        didSet { save() }
    }

    @Published var launchAtLogin: Bool {
        didSet { save(); applyLaunchAtLogin() }
    }

    /// Pomodoro durations
    @Published var timerWorkMinutes: Int       { didSet { save() } }
    @Published var timerShortBreakMinutes: Int { didSet { save() } }
    @Published var timerLongBreakMinutes: Int  { didSet { save() } }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard

        let sizeRaw = d.string(forKey: Self.sizePresetKey) ?? ClaudeStatsSizePreset.medium.rawValue
        self.sizePreset = ClaudeStatsSizePreset(rawValue: sizeRaw) ?? .medium

        let refreshRaw = d.integer(forKey: Self.refreshKey)
        self.refreshInterval = ClaudeStatsRefreshInterval(rawValue: refreshRaw) ?? .fiveMinutes

        let pacingRaw = d.string(forKey: Self.pacingKey) ?? ClaudeStatsPacingDisplayMode.arrowWithTime.rawValue
        self.pacingDisplayMode = ClaudeStatsPacingDisplayMode(rawValue: pacingRaw) ?? .arrowWithTime

        if let savedID = d.object(forKey: Self.displayIDKey) as? Int {
            self.assignedDisplayID = CGDirectDisplayID(savedID)
        } else {
            self.assignedDisplayID = CGMainDisplayID()
        }

        let savedThreshold = d.integer(forKey: Self.alertThresholdKey)
        self.alertThreshold = savedThreshold   // 0 = off by default

        self.timerWorkMinutes       = d.object(forKey: Self.timerWorkKey)       as? Int ?? 25
        self.timerShortBreakMinutes = d.object(forKey: Self.timerShortBreakKey) as? Int ?? 5
        self.timerLongBreakMinutes  = d.object(forKey: Self.timerLongBreakKey)  as? Int ?? 15

        // Read stored value; cross-check with actual SMAppService status
        let stored = d.bool(forKey: Self.launchAtLoginKey)
        if #available(macOS 13.0, *) {
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            self.launchAtLogin = stored
        }
    }

    // MARK: - Persist

    func save() {
        let d = UserDefaults.standard
        d.set(sizePreset.rawValue,       forKey: Self.sizePresetKey)
        d.set(refreshInterval.rawValue,  forKey: Self.refreshKey)
        d.set(pacingDisplayMode.rawValue, forKey: Self.pacingKey)
        d.set(Int(assignedDisplayID),    forKey: Self.displayIDKey)
        d.set(alertThreshold,            forKey: Self.alertThresholdKey)
        d.set(launchAtLogin,             forKey: Self.launchAtLoginKey)
        d.set(timerWorkMinutes,          forKey: Self.timerWorkKey)
        d.set(timerShortBreakMinutes,    forKey: Self.timerShortBreakKey)
        d.set(timerLongBreakMinutes,     forKey: Self.timerLongBreakKey)
    }

    // MARK: - Launch at Login

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Silently ignore — user can toggle again
            }
        }
    }
}
