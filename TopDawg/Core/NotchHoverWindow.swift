import AppKit
import SwiftUI
import Combine
import UserNotifications

// MARK: - Panel Navigation

enum PanelPage: String, CaseIterable, Hashable {
    case sessions, stats, analytics, focus, system, notes, about, settings

    var icon: String {
        switch self {
        case .sessions:  return "list.bullet.rectangle"
        case .stats:     return "chart.bar.fill"
        case .analytics: return "chart.line.uptrend.xyaxis"
        case .focus:     return "timer"
        case .system:    return "cpu"
        case .notes:     return "note.text"
        case .about:     return "info.circle"
        case .settings:  return "gear"
        }
    }
}

// MARK: - Layout

private enum NL {
    static let panelH:  CGFloat = 290
    static let cornerR: CGFloat = 10
    static let panelR:  CGFloat = 14
}

// MARK: - Window subclass (borderless windows can't become key by default)

private final class NotchWindow: NSWindow {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

final class NotchHoverWindow: NSObject, ObservableObject {

    @Published var isExpanded  = false
    @Published var activePage: PanelPage = .sessions

    let timerManager    = FocusTimerManager()
    let systemManager   = SystemMonitorManager()
    let editorState     = RichTextEditorState()
    let sessionRegistry = SessionRegistry()

    private var win:         NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var screen:      NSScreen
    private var manager:     ClaudeUsageManager
    private var settings:    ClaudeStatsSettings
    private var mouseMonitor: Any?
    private var hotKey:      HotKeyManager?
    private var cancellables = Set<AnyCancellable>()

    // Notch geometry
    private var notchH:    CGFloat = 37
    private var notchGapW: CGFloat = 162
    private var notchLeft: CGFloat = 0

    private var wingW: CGFloat { settings.sizePreset.wingWidth }
    private var barW:  CGFloat { wingW + notchGapW + wingW }
    private var barX:  CGFloat { notchLeft - wingW }

    // Alert tracking (resets each launch)
    private var alertedThresholds: Set<String> = []
    private var prevSessionPct:  Double = -1
    private var prevWeeklyPct:   Double = -1
    private var prevPaceRatio:   Double =  1.0

    // Smart tip cooldowns and rotation
    private var sentTips:     [String: Date] = [:]
    private var lastTipIndex: [String: Int]  = [:]

    init(manager: ClaudeUsageManager, settings: ClaudeStatsSettings, screen: NSScreen) {
        self.manager  = manager
        self.settings = settings
        self.screen   = screen
        super.init()
        // Sync timer durations from settings
        timerManager.workDuration       = TimeInterval(settings.timerWorkMinutes * 60)
        timerManager.shortBreakDuration = TimeInterval(settings.timerShortBreakMinutes * 60)
        timerManager.longBreakDuration  = TimeInterval(settings.timerLongBreakMinutes * 60)

        measure()
        build()
        startMouseTracking()
        registerHotKey()
        requestNotificationPermission()

        settings.$sizePreset
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionWindow() }
            .store(in: &cancellables)

        manager.$usageData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.checkAlerts(data)
                self?.checkSmartTips(data)
                self?.updateAdaptivePolling(data)
            }
            .store(in: &cancellables)

        settings.$refreshInterval
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateAdaptivePolling(self.manager.usageData)
            }
            .store(in: &cancellables)

        settings.$timerWorkMinutes
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.timerManager.workDuration = TimeInterval(m * 60) }
            .store(in: &cancellables)
        settings.$timerShortBreakMinutes
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.timerManager.shortBreakDuration = TimeInterval(m * 60) }
            .store(in: &cancellables)
        settings.$timerLongBreakMinutes
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.timerManager.longBreakDuration = TimeInterval(m * 60) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onOpenSettings),
            name: .openTopDawgSettings, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: – Geometry

    private func measure() {
        if let s = NSScreen.screens.first(where: { $0.displayID == screen.displayID }) {
            screen = s
        }
        if #available(macOS 12.0, *),
           screen.safeAreaInsets.top > 0,
           let left  = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchH    = screen.safeAreaInsets.top
            notchGapW = screen.frame.width - left.width - right.width
            notchLeft = screen.frame.origin.x + left.width
        } else {
            notchH    = screen.frame.maxY - screen.visibleFrame.maxY
            notchGapW = 150
            notchLeft = screen.frame.origin.x + screen.frame.width / 2 - notchGapW / 2
        }
    }

    // MARK: – Window

    private func build() {
        let w = NotchWindow(contentRect: collapsedFrame(),
                            styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor    = .clear
        w.isOpaque           = false
        w.hasShadow          = false
        w.level              = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        self.win = w
        loadContent()
    }

    private func loadContent() {
        let root = AnyView(NotchRootView(
            manager: manager, settings: settings, controller: self,
            timerManager: timerManager, systemManager: systemManager,
            editorState: editorState, sessionRegistry: sessionRegistry,
            notchH: notchH, notchGapW: notchGapW, panelH: NL.panelH
        ).ignoresSafeArea(.all))

        if let hv = hostingView {
            // Update the existing hosting view — preserves AppKit view hierarchy
            // so mid-click the button target never gets replaced
            hv.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.wantsLayer = true
            hv.layer?.backgroundColor = .clear
            win?.contentView = hv
            hostingView = hv
        }
    }

    private func repositionWindow() {
        win?.setFrame(isExpanded ? expandedFrame() : collapsedFrame(), display: true)
        loadContent()
    }

    // MARK: – Frames

    private func collapsedFrame() -> NSRect {
        NSRect(x: barX, y: screen.frame.maxY - notchH, width: barW, height: notchH)
    }

    private func expandedFrame() -> NSRect {
        NSRect(x: barX, y: screen.frame.maxY - notchH - NL.panelH,
               width: barW, height: notchH + NL.panelH)
    }

    // MARK: – Expand / Collapse

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        win?.ignoresMouseEvents = false
        systemManager.start()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win?.animator().setFrame(expandedFrame(), display: true)
        }
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded  = false
        activePage  = .stats
        win?.ignoresMouseEvents = true
        systemManager.stop()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win?.animator().setFrame(collapsedFrame(), display: true)
        }
    }

    func togglePanel() {
        isExpanded ? collapse() : expand()
    }

    // MARK: – Mouse

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            let m = NSEvent.mouseLocation
            let hover = self.collapsedFrame().insetBy(dx: -8, dy: -8)
            let keep  = self.expandedFrame().insetBy(dx: -12, dy: -12)
            DispatchQueue.main.async {
                if hover.contains(m)      { self.expand()   }
                else if !keep.contains(m) { self.collapse() }
            }
        }
    }

    // MARK: – Keyboard shortcut (⌃⌥C)

    private func registerHotKey() {
        // controlKey (4096) + optionKey (2048), kVK_ANSI_C (8)
        hotKey = HotKeyManager(keyCode: 8, modifiers: 4096 | 2048) { [weak self] in
            self?.togglePanel()
        }
    }

    // MARK: – Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkAlerts(_ data: ClaudeUsageData) {
        let threshold = settings.alertThreshold
        guard threshold > 0 else { alertedThresholds.removeAll(); return }
        let t = Double(threshold)

        let stats: [(String, Double)] = [
            ("Session", data.sessionPercentage),
            ("Weekly",  data.weeklyPercentage),
            ("Sonnet",  data.sonnetPercentage),
            ("Opus",    data.opusPercentage),
        ]
        for (name, pct) in stats {
            guard pct > 0 else { continue }
            let key = "\(name)_\(threshold)"
            if pct >= t, !alertedThresholds.contains(key) {
                alertedThresholds.insert(key)
                sendNotification(title: "Claude Usage Alert",
                                 body: "\(name) is at \(Int(pct))% — approaching your \(threshold)% threshold")
            }
            if pct < t { alertedThresholds.remove(key) }
        }

        // Session reset detection: utilization dropped significantly → window refilled
        let cur = data.sessionPercentage
        if prevSessionPct > 20 && cur < prevSessionPct - 15 {
            sendNotification(
                title: "✅ Claude Session Reset",
                body: "Fresh 5-hour window — full capacity available! Tip: start with a clear context prompt.")
            // Animate the UI refresh
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.loadContent()
            }
        }
        prevSessionPct = cur
    }

    // MARK: – Smart Claude Advisor

    private func checkSmartTips(_ data: ClaudeUsageData) {
        guard manager.isAuthenticated, data.sessionPercentage > 0 else { return }
        let sp = data.sessionPacing
        let sPct  = data.sessionPercentage
        let wPct  = data.weeklyPercentage
        let pace  = sp.paceRatio

        // 1. Sudden usage spike: pace ratio jumped hard (large file paste / long prompt)
        if prevPaceRatio < 2.0 && pace >= 3.5 {
            fireTip(key: "spike", cooldown: 20 * 60, tips: ClaudeTips.suddenSpike)
        }

        // 2. Very high sustained burn rate (> 2.5×) — suggest /compact or chunking
        if pace > 2.5 && prevPaceRatio <= 2.5 {
            fireTip(key: "burnHigh", cooldown: 25 * 60, tips: ClaudeTips.burnHigh)
        }

        // 3. Session crosses 70% — first proactive /compact reminder
        if sPct >= 70 && prevSessionPct < 70 {
            fireTip(key: "session70", cooldown: 60 * 60, tips: ClaudeTips.session70)
        }

        // 4. Session crosses 85% — urgent compact/clear
        if sPct >= 85 && prevSessionPct < 85 {
            fireTip(key: "session85", cooldown: 30 * 60, tips: ClaudeTips.session85)
        }

        // 5. Session crosses 95% — last-resort tip
        if sPct >= 95 && prevSessionPct < 95 {
            fireTip(key: "session95", cooldown: 20 * 60, tips: ClaudeTips.session95)
        }

        // 6. Weekly crosses 80%
        if wPct >= 80 && prevWeeklyPct < 80 {
            fireTip(key: "weekly80", cooldown: 120 * 60, tips: ClaudeTips.weekly80)
        }

        // 7. Weekly crosses 95%
        if wPct >= 95 && prevWeeklyPct < 95 {
            fireTip(key: "weekly95", cooldown: 60 * 60, tips: ClaudeTips.weekly95)
        }

        // 8. Session just reset (detected via big drop) — fresh-start tips
        if prevSessionPct > 20 && sPct < prevSessionPct - 15 {
            fireTip(key: "sessionReset", cooldown: 5 * 60, tips: ClaudeTips.sessionReset)
        }

        // 9. Sonnet approaching limit
        if data.sonnetPercentage >= 80 && (prevSessionPct < 0 || data.sonnetPercentage > 80) {
            fireTip(key: "sonnet80", cooldown: 90 * 60, tips: ClaudeTips.sonnet80)
        }

        // Update prev state
        prevPaceRatio = pace
        prevWeeklyPct = wPct
        // prevSessionPct is updated at end of checkAlerts — leave it there
    }

    private func fireTip(key: String, cooldown: TimeInterval, tips: [(String, String)]) {
        let last = sentTips[key] ?? .distantPast
        guard Date().timeIntervalSince(last) >= cooldown else { return }
        sentTips[key] = Date()

        // Rotate through tips, never repeating the same index consecutively
        let prev = lastTipIndex[key] ?? -1
        var idx  = Int.random(in: 0..<tips.count)
        if tips.count > 1 { while idx == prev { idx = Int.random(in: 0..<tips.count) } }
        lastTipIndex[key] = idx

        sendNotification(title: tips[idx].0, body: tips[idx].1)
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString,
                                       content: content, trigger: nil))
    }

    // MARK: – Adaptive polling

    private func updateAdaptivePolling(_ data: ClaudeUsageData) {
        let peak = max(data.sessionPercentage, data.weeklyPercentage)
        let interval: TimeInterval
        switch peak {
        case 85...: interval = 60
        case 70...: interval = 120
        default:    interval = settings.refreshInterval.seconds
        }
        manager.startPolling(interval: interval)
    }

    // MARK: – Public

    func show() {
        win?.setFrame(collapsedFrame(), display: true)
        win?.orderFrontRegardless()
    }

    func refresh() { loadContent() }

    func updateScreen(_ s: NSScreen) {
        screen = s; measure()
        win?.setFrame(isExpanded ? expandedFrame() : collapsedFrame(), display: true)
        loadContent()
    }

    @objc private func onOpenSettings(_ n: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.activePage = .settings
            self?.expand()
        }
    }

    @objc private func onScreenChange(_ n: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.measure()
            guard let self else { return }
            self.win?.setFrame(self.isExpanded ? self.expandedFrame() : self.collapsedFrame(),
                               display: true)
            self.loadContent()
        }
    }
}

// MARK: - Root view

struct NotchRootView: View {
    @ObservedObject var manager:         ClaudeUsageManager
    @ObservedObject var settings:        ClaudeStatsSettings
    @ObservedObject var controller:      NotchHoverWindow
    @ObservedObject var timerManager:    FocusTimerManager
    @ObservedObject var systemManager:   SystemMonitorManager
    @ObservedObject var editorState:     RichTextEditorState
    @ObservedObject var sessionRegistry: SessionRegistry

    @State private var feedbackText = ""
    @State private var feedbackSent = false

    let notchH:    CGFloat
    let notchGapW: CGFloat
    let panelH:    CGFloat

    private var wingW:  CGFloat { settings.sizePreset.wingWidth }
    private var totalW: CGFloat { wingW + notchGapW + wingW }
    private var fs:     CGFloat { settings.sizePreset.titleFontSize }

    var body: some View {
        VStack(spacing: 0) {
            notchBar.frame(width: totalW, height: notchH)
            if controller.isExpanded {
                dropPanel.frame(width: totalW, height: panelH)
            }
        }
        .frame(width: totalW, alignment: .top)
    }

    // MARK: Collapsed bar

    private var notchBar: some View {
        HStack(spacing: 0) {
            ZStack {
                LeftWingShape(cornerR: NL.cornerR).fill(Color.black)
                leftChip.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: wingW, height: notchH)

            Color.black.frame(width: notchGapW, height: notchH)

            ZStack {
                RightWingShape(cornerR: NL.cornerR).fill(Color.black)
                rightChip.padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: wingW, height: notchH)
        }
    }

    @ViewBuilder private var leftChip: some View {
        if manager.isAuthenticated {
            PulsingChip(active: manager.usageData.sessionPercentage >= 80) {
                barChip(pct: manager.usageData.sessionPercentage,
                        pacing: manager.usageData.sessionPacing)
            }
        } else {
            Text("Setup")
                .font(.system(size: fs, weight: .semibold))
                .foregroundColor(.claudeCoral)
        }
    }

    @ViewBuilder private var rightChip: some View {
        if manager.isAuthenticated {
            PulsingChip(active: timerManager.isRunning
                            ? timerManager.remaining < 120
                            : manager.usageData.weeklyPercentage >= 80) {
                if timerManager.isRunning {
                    timerWingChip
                } else {
                    barChip(pct: manager.usageData.weeklyPercentage,
                            pacing: manager.usageData.weeklyPacing)
                }
            }
        }
    }

    private var timerWingChip: some View {
        HStack(spacing: 2) {
            Image(systemName: timerManager.phase == .work ? "timer" : "cup.and.heat.waves")
                .font(.system(size: fs - 2))
                .foregroundColor(timerWingColor)
            Text(timerManager.displayTime)
                .font(.system(size: fs, weight: .bold, design: .monospaced))
                .foregroundColor(timerWingColor)
        }
    }

    private var timerWingColor: Color {
        switch timerManager.phase {
        case .work:             return timerManager.remaining < 120 ? .claudeAlert : .claudeCoral
        case .shortBreak,
             .longBreak:        return .claudeTeal
        }
    }

    private func barChip(pct: Double, pacing: ClaudeStatsPacingData) -> some View {
        HStack(spacing: 2) {
            Text("\(Int(pct))%")
                .font(.system(size: fs, weight: .bold, design: .rounded))
                .foregroundColor(pct2color(pct))
            if settings.pacingDisplayMode != .hidden {
                Text(pacing.state.arrow)
                    .font(.system(size: fs - 1, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    // MARK: Drop panel

    private var dropPanel: some View {
        ZStack {
            PanelShape(cornerR: NL.panelR).fill(Color(red: 0.08, green: 0.08, blue: 0.10))
            PanelShape(cornerR: NL.panelR).stroke(Color.white.opacity(0.07), lineWidth: 1)

            VStack(spacing: 0) {
                activePage
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    .frame(maxHeight: .infinity, alignment: .top)

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                panelTabBar
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controller.activePage)
        .clipped()
    }

    @ViewBuilder private var activePage: some View {
        switch controller.activePage {
        case .sessions:  sessionsPage
        case .stats:     statsPage
        case .analytics: analyticsPage
        case .focus:     focusPage
        case .system:    systemPage
        case .notes:     notesPage
        case .about:     aboutPage
        case .settings:  settingsPage
        }
    }

    // v1: Sessions is primary; System Monitor + Notes hidden from tab bar
    // (enum cases retained so any deep-link / state restoration still compiles).
    private static let tabBarPages: [PanelPage] = [.sessions, .stats, .analytics, .focus, .about]

    private var sessionsPage: some View {
        SessionsPanelView(registry: sessionRegistry)
    }

    private var panelTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabBarPages, id: \.self) { page in
                tabBarIcon(page)
            }
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            tabBarIcon(.settings)
        }
        .padding(.horizontal, NL.panelR)
        .padding(.bottom, 4)
    }

    private func tabBarIcon(_ page: PanelPage) -> some View {
        Button(action: { controller.activePage = page }) {
            Image(systemName: page.icon)
                .font(.system(size: 10))
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .foregroundColor(controller.activePage == page
                    ? .claudeCoral
                    : .white.opacity(0.28))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Stats page

    private var statsPage: some View {
        VStack(spacing: 7) {
            // Header
            HStack {
                if let plan = manager.usageData.planDisplayName { planBadge(plan) }
                Spacer()
                HStack(spacing: 6) {
                    if manager.isLoading {
                        ProgressView().scaleEffect(0.5).frame(width: 10)
                    } else if let t = manager.usageData.lastUpdated {
                        (Text(t, style: .relative) + Text(" ago"))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.28))
                    }
                    Button(action: { manager.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                    }.buttonStyle(.plain)
                }
            }

            thinDivider

            // Insight line — burn rate or risk warning
            if let insight = sessionInsight {
                HStack(spacing: 4) {
                    Image(systemName: insight.icon)
                        .font(.system(size: 9))
                        .foregroundColor(insight.color)
                    Text(insight.text)
                        .font(.system(size: 10))
                        .foregroundColor(insight.color)
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(insight.color.opacity(0.08))
                .cornerRadius(6)
            }

            statRow("Session", sub: "5h",
                    pct: manager.usageData.sessionPercentage,
                    pacing: manager.usageData.sessionPacing,
                    resets: manager.usageData.sessionResetsAt,
                    history: manager.history.map(\.session))

            statRow("Weekly", sub: "7d",
                    pct: manager.usageData.weeklyPercentage,
                    pacing: manager.usageData.weeklyPacing,
                    resets: manager.usageData.weeklyResetsAt,
                    history: manager.history.map(\.weekly))

            if manager.usageData.sonnetPercentage > 0 {
                compactRow("Sonnet", sub: "7d",
                           pct: manager.usageData.sonnetPercentage,
                           resets: manager.usageData.sonnetResetsAt)
            }

            if manager.usageData.opusPercentage > 0 {
                compactRow("Opus", sub: "7d",
                           pct: manager.usageData.opusPercentage,
                           resets: manager.usageData.opusResetsAt)
            }

            if manager.usageData.extraUsageEnabled || manager.usageData.extraUsageCredits > 0 {
                extraUsageRow
            }

        }
    }

    // MARK: Session insight

    private struct Insight { let text: String; let color: Color; let icon: String }

    private var sessionInsight: Insight? {
        guard manager.isAuthenticated else { return nil }
        let data = manager.usageData
        let sp   = data.sessionPacing

        // Format the FIXED actual reset time — never drifts because it's a real Date
        let resetStr: String? = {
            guard let r = data.sessionResetsAt, r > Date() else { return nil }
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            fmt.dateStyle = .none
            fmt.timeZone  = TimeZone.current
            return fmt.string(from: r)
        }()

        // Critical: will exhaust before window resets
        if let eta = sp.minutesUntilExhaustion, eta < sp.minutesRemaining {
            let when = absoluteTime(addingMinutes: eta)
            if eta < 30 {
                return Insight(text: "Full at \(when) — critical! Use /compact",
                               color: .claudeAlert, icon: "exclamationmark.triangle.fill")
            }
            return Insight(text: "Full ~\(when) at this pace — try /compact",
                           color: .claudeAmber, icon: "clock.badge.exclamationmark")
        }

        // Show actual reset time + burn rate info
        if let when = resetStr {
            if sp.paceRatio > 2.0 {
                return Insight(
                    text: "Resets \(when) · \(String(format: "%.1f", sp.paceRatio))× burn rate",
                    color: .claudeAmber, icon: "flame")
            }
            if let rate = data.sessionBurnRatePerHour, rate > 0 {
                return Insight(
                    text: "Resets \(when) · ~\(Int(rate))%/hr",
                    color: .white.opacity(0.32), icon: "clock")
            }
            return Insight(
                text: "Session resets at \(when)",
                color: .white.opacity(0.28), icon: "clock")
        }

        return nil
    }

    private func absoluteTime(addingMinutes mins: Double) -> String {
        let d   = Date().addingTimeInterval(mins * 60)
        let fmt = DateFormatter()
        fmt.timeStyle  = .short    // respects user's 24h/12h locale preference
        fmt.dateStyle  = .none
        fmt.timeZone   = TimeZone.current  // explicit — never defaults to UTC
        return fmt.string(from: d)
    }


    // MARK: Stat row (with sparkline + ETA)

    private func statRow(_ label: String, sub: String, pct: Double,
                         pacing: ClaudeStatsPacingData, resets: Date?,
                         history: [Double]) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.28))
                Spacer()
                // Velocity chip (shows when usage pace is elevated)
                if pacing.paceRatio > 1.3 {
                    Text("\(String(format: "%.1f", pacing.paceRatio))×")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(pacing.state.color)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(pacing.state.color.opacity(0.15))
                        .cornerRadius(4)
                }
                Text("\(Int(pct))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(pct2color(pct))
                if settings.pacingDisplayMode != .hidden {
                    Text(pacing.state.arrow)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                // Always show session/weekly reset countdown — this is what users want to see
                if let r = resets, r > Date() {
                    Text(r, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(pct >= 100 ? .claudeAmber : .white.opacity(0.30))
                        .monospacedDigit()
                }
            }
            // Progress bar (animated)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(height: 3)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [pct2color(pct).opacity(0.5), pct2color(pct)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * min(pct / 100, 1), height: 3)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: pct)
                }
            }.frame(height: 3)
            // Sparkline or placeholder
            if history.count >= 2 {
                SparklineView(values: history, color: pct2color(pct))
                    .frame(height: 16)
                    .padding(.top, 1)
            } else {
                Text("collecting data…")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.20))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 16)
                    .padding(.top, 1)
            }
        }
    }

    // Compact row for Sonnet/Opus/Extra (no sparkline, less space)
    private func compactRow(_ label: String, sub: String?, pct: Double, resets: Date?) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                if let sub {
                    Text(sub)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
                Spacer()
                Text("\(Int(pct))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(pct2color(pct))
                if let r = resets, r > Date() {
                    Text(r, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                        .monospacedDigit()
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06)).frame(height: 2)
                    Capsule()
                        .fill(pct2color(pct).opacity(0.7))
                        .frame(width: g.size.width * min(pct / 100, 1), height: 2)
                }
            }.frame(height: 2)
        }
    }

    // Extra usage row — shows dollar spend, limit bar, and reset date
    private var extraUsageRow: some View {
        let data    = manager.usageData
        let credits = data.extraUsageCredits
        let dollars = credits / 100.0
        let limit   = data.extraUsageLimit
        let cur     = data.currencyCode.uppercased() == "EUR" ? "€" : "$"
        let pct: Double = {
            if let cap = limit, cap > 0 { return min(credits / cap * 100, 100) }
            return 0
        }()

        return VStack(spacing: 2) {
            // Row 1: label + amount + limit
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Extra")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%@%.2f", cur, dollars))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.claudeAmber)
                if let cap = limit {
                    Text("/ \(cur)\(String(format: "%.0f", cap / 100))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                } else {
                    Text("no cap")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.22))
                }
            }
            // Row 2: progress bar (if capped) or thin amber line proportional to spend
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06)).frame(height: 2)
                    if let cap = limit, cap > 0 {
                        Capsule()
                            .fill(Color.claudeAmber.opacity(0.7))
                            .frame(width: g.size.width * min(pct / 100, 1), height: 2)
                    } else {
                        // No cap: show a proportional indicator (scale: $100 = full bar)
                        Capsule()
                            .fill(Color.claudeAmber.opacity(0.5))
                            .frame(width: g.size.width * min(dollars / 100, 1), height: 2)
                    }
                }
            }.frame(height: 2)
            // Row 3: reset date
            if let r = data.extraUsageResetsAt, r > Date() {
                HStack {
                    Spacer()
                    Text("resets ")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.22))
                    Text(r, style: .date)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
        }
    }

    // MARK: ETA helpers

    private func etaString(pacing: ClaudeStatsPacingData) -> String? {
        guard let exhaustion = pacing.minutesUntilExhaustion, exhaustion > 1 else { return nil }
        let remaining = pacing.minutesRemaining
        // Only show if at-risk (will hit limit before window resets)
        guard exhaustion < remaining else { return nil }
        return "~\(formatMinutes(exhaustion)) left"
    }

    private func etaColor(pacing: ClaudeStatsPacingData) -> Color {
        guard let exhaustion = pacing.minutesUntilExhaustion else { return .white }
        if exhaustion < 60  { return .claudeAlert }
        if exhaustion < 180 { return .claudeAmber }
        return .claudeCoral
    }

    private func formatMinutes(_ m: Double) -> String {
        let total = Int(m)
        let days  = total / 1440
        let hours = (total % 1440) / 60
        let mins  = total % 60
        if days  > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return mins  > 0 ? "\(hours)h\(mins)m" : "\(hours)h" }
        return "\(total)m"
    }

    // MARK: Settings page

    // MARK: About page

    private var aboutPage: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {

                    // ── App identity ──
                    VStack(spacing: 6) {
                        Image("ClaudeLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                            .padding(10)
                            .background(Circle().fill(Color.claudeCoral.opacity(0.10)))

                        Text("TopDawg")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("v\(UpdateChecker.shared.currentVersion)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)

                    // ── Update status ──
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            if UpdateChecker.shared.isChecking {
                                ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                                Text("Checking for updates…")
                                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                            } else if UpdateChecker.shared.updateAvailable {
                                Circle().fill(Color.claudeCoral).frame(width: 6, height: 6)
                                Text("v\(UpdateChecker.shared.latestVersion ?? "") available")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.claudeCoral)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.claudeTeal)
                                Text("Up to date")
                                    .font(.system(size: 10))
                                    .foregroundColor(.claudeTeal.opacity(0.8))
                            }
                            Spacer()
                            Button(action: {
                                if UpdateChecker.shared.updateAvailable {
                                    UpdateChecker.shared.openDownload()
                                } else {
                                    UpdateChecker.shared.check(silent: false)
                                }
                            }) {
                                Text(UpdateChecker.shared.updateAvailable ? "Download" : "Check")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(UpdateChecker.shared.updateAvailable
                                        ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(UpdateChecker.shared.updateAvailable
                                        ? Color.claudeCoral : Color.white.opacity(0.08))
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                        if let last = UpdateChecker.shared.lastChecked {
                            HStack {
                                Text("Last checked ")
                                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.2))
                                Text(last, style: .relative)
                                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.2))
                                Text(" ago").font(.system(size: 9)).foregroundColor(.white.opacity(0.2))
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)

                    // ── Action buttons ──
                    VStack(spacing: 1) {
                        aboutActionRow(
                            icon: "star.fill",
                            iconColor: .yellow,
                            title: "Star on GitHub",
                            subtitle: "Support the project with a star"
                        ) {
                            if let url = URL(string: "https://github.com/\(UpdateChecker.repoOwner)/\(UpdateChecker.repoName)") {
                                NSWorkspace.shared.open(url)
                            }
                        }

                        aboutDivider

                        aboutActionRow(
                            icon: "cup.and.saucer.fill",
                            iconColor: Color(red: 1.0, green: 0.82, blue: 0.4),
                            title: "Buy me a coffee",
                            subtitle: "Support development via PayPal"
                        ) {
                            if let url = URL(string: "https://www.paypal.com/paypalme/carlo080908") {
                                NSWorkspace.shared.open(url)
                            }
                        }

                        aboutDivider

                        aboutActionRow(
                            icon: "ladybug.fill",
                            iconColor: .claudeAlert,
                            title: "Report a Bug",
                            subtitle: "Open a GitHub issue"
                        ) {
                            if let url = URL(string: "https://github.com/\(UpdateChecker.repoOwner)/\(UpdateChecker.repoName)/issues/new?labels=bug&template=bug_report.md") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)

                    // ── Inline feedback ──
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.claudeTeal)
                            Text("Send Feedback")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        if feedbackSent {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.claudeTeal)
                                Text("Thanks for your feedback!")
                                    .font(.system(size: 11))
                                    .foregroundColor(.claudeTeal)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        } else {
                            TextField("Ideas, bugs, anything…", text: $feedbackText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )

                            HStack {
                                Spacer()
                                Button(action: { submitFeedback() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 9))
                                        Text("Send")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(
                                        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? Color.white.opacity(0.08)
                                            : Color.claudeCoral
                                    )
                                    .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)

                    // ── Footer ──
                    VStack(spacing: 3) {
                        Text("Made with SwiftUI & AppKit")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.20))
                        Text("Not affiliated with Anthropic")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.15))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func aboutActionRow(icon: String, iconColor: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aboutDivider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 42)
    }

    private func submitFeedback() {
        let text = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Build a pre-filled GitHub issue URL
        let version = UpdateChecker.shared.currentVersion
        let build   = UpdateChecker.shared.currentBuild
        let os      = ProcessInfo.processInfo.operatingSystemVersionString

        let body = """
        **Feedback**
        \(text)

        ---
        *TopDawg v\(version) (\(build)) · macOS \(os)*
        """

        var components = URLComponents(string: "https://github.com/\(UpdateChecker.repoOwner)/\(UpdateChecker.repoName)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "Feedback: \(String(text.prefix(60)))"),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "feedback"),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }

        // Show confirmation
        withAnimation(.easeInOut(duration: 0.3)) {
            feedbackSent = true
            feedbackText = ""
        }

        // Reset after 4 seconds so user can send more
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { self.feedbackSent = false }
        }
    }

    // MARK: Settings page

    private var settingsPage: some View {
        VStack(spacing: 0) {
            // Fixed header
            HStack {
                Button(action: { controller.activePage = .stats }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.system(size: 12, weight: .medium))
                    }.foregroundColor(.white.opacity(0.6))
                }.buttonStyle(.plain)
                Spacer()
                Text("Settings").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                Spacer().frame(width: 40)
            }
            .padding(.bottom, 8)

            thinDivider.padding(.bottom, 8)

            // Scrollable rows — bounded height so footer is always visible
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    sectionLabel("Claude Usage")
                    settingRow("Size") {
                        SegmentPicker(options: ClaudeStatsSizePreset.allCases,
                                      selected: $settings.sizePreset) { sizeLabel($0) }
                    }
                    settingRow("Pacing") {
                        SegmentPicker(options: ClaudeStatsPacingDisplayMode.allCases,
                                      selected: $settings.pacingDisplayMode) { pacingLabel($0) }
                    }
                    settingRow("Alert at") {
                        SegmentPicker(options: [0, 80, 90, 95],
                                      selected: $settings.alertThreshold) { $0 == 0 ? "Off" : "\($0)%" }
                    }
                    settingRow("Refresh") {
                        Picker("", selection: $settings.refreshInterval) {
                            ForEach(ClaudeStatsRefreshInterval.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden()
                        .tint(.white.opacity(0.5))
                        .scaleEffect(0.9, anchor: .trailing)
                    }
                    settingRow("Auto-start") {
                        Toggle("", isOn: $settings.launchAtLogin)
                            .toggleStyle(.switch)
                            .scaleEffect(0.75, anchor: .trailing)
                            .tint(.claudeTeal)
                    }
                    settingRow("Hotkey") {
                        Text("⌃⌥C")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(5)
                    }

                    sectionLabel("Focus Timer")
                    settingRow("Work") {
                        SegmentPicker(options: [15, 25, 50],
                                      selected: $settings.timerWorkMinutes) { "\($0)m" }
                    }
                    settingRow("Short brk") {
                        SegmentPicker(options: [5, 10],
                                      selected: $settings.timerShortBreakMinutes) { "\($0)m" }
                    }
                    settingRow("Long brk") {
                        SegmentPicker(options: [15, 20, 30],
                                      selected: $settings.timerLongBreakMinutes) { "\($0)m" }
                    }

                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: .infinity)  // takes remaining space; keeps footer pinned below

            thinDivider.padding(.vertical, 4)

            // Footer: always visible at bottom of settings
            HStack(spacing: 0) {
                // Open Claude.ai
                Button(action: { NSWorkspace.shared.open(URL(string: "https://claude.ai")!) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "safari").font(.system(size: 11))
                        Text("Claude.ai").font(.system(size: 11))
                    }.foregroundColor(.white.opacity(0.45))
                }.buttonStyle(.plain)

                Spacer()

                // Logout
                Button(action: { manager.logout() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 11))
                        Text("Logout").font(.system(size: 11))
                    }.foregroundColor(.claudeCoral)
                }.buttonStyle(.plain)

                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 12).padding(.horizontal, 8)

                // Quit
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power").font(.system(size: 11))
                        Text("Quit").font(.system(size: 11))
                    }.foregroundColor(.white.opacity(0.30))
                }.buttonStyle(.plain)
            }
            .padding(.bottom, 2)
        }
    }

    // MARK: Analytics page

    private var analyticsPage: some View {
        // TimelineView auto-refreshes the view body every 10 s — no manual timer needed
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            VStack(spacing: 4) {
                HStack {
                    Text("Analytics")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    HStack(spacing: 3) {
                        Circle().fill(Color.claudeTeal).frame(width: 4, height: 4)
                        Text("live")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }

                thinDivider

                if manager.isAuthenticated {
                    analyticsCard(
                        label: "Session", windowLabel: "5h",
                        pct: manager.usageData.sessionPercentage,
                        pacing: manager.usageData.sessionPacing,
                        resetsAt: manager.usageData.sessionResetsAt,
                        burnRatePerHour: manager.usageData.sessionBurnRatePerHour,
                        history: manager.history.map { ($0.date, $0.session) }
                    )
                    analyticsCard(
                        label: "Weekly", windowLabel: "7d",
                        pct: manager.usageData.weeklyPercentage,
                        pacing: manager.usageData.weeklyPacing,
                        resetsAt: manager.usageData.weeklyResetsAt,
                        burnRatePerHour: nil,
                        history: manager.history.map { ($0.date, $0.weekly) }
                    )
                } else {
                    Spacer()
                    Text("Sign in to see forecasts")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                    Spacer()
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func analyticsCard(
        label: String,
        windowLabel: String,
        pct: Double,
        pacing: ClaudeStatsPacingData,
        resetsAt: Date?,
        burnRatePerHour: Double?,
        history: [(Date, Double)]
    ) -> some View {
        let isExhausted  = pct >= 100
        let etaMins      = pacing.minutesUntilExhaustion
        let minsLeft     = pacing.minutesRemaining
        let willHitLimit = (etaMins ?? .infinity) < minsLeft && (etaMins ?? 0) > 1
        let hoursLeft    = minsLeft / 60

        // Burn rate: prefer direct value, fallback to exhaustion-based calculation
        let burn: Double = {
            if let b = burnRatePerHour, b > 0 { return b }
            if let eta = etaMins, eta > 1 { return (100 - pct) / (eta / 60) }
            return 0
        }()

        // Projected % at window reset — can exceed 100 if burn is high
        let projAtReset = min(pct + burn * hoursLeft, 200)

        let c = pct2color(pct)

        return VStack(alignment: .leading, spacing: 2) {

            // ── Row 1: label + % + status chip ──
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                Text(windowLabel)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.25))
                Spacer()
                Text("\(Int(pct))%")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(c)
                if isExhausted {
                    aChip("Exhausted", .claudeAlert)
                } else if willHitLimit {
                    aChip((etaMins ?? 999) < 60 ? "⚠ Critical" : "⚠ At risk",
                          (etaMins ?? 999) < 60 ? .claudeAlert : .claudeAmber)
                } else {
                    aChip("✓ OK", .claudeTeal)
                }
            }

            // ── Row 2: Zoned forecast bar ──
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.claudeTeal.opacity(0.15)).frame(width: w * 0.40)
                        Rectangle().fill(Color.claudeAmber.opacity(0.15)).frame(width: w * 0.25)
                        Rectangle().fill(Color.claudeCoral.opacity(0.15)).frame(width: w * 0.20)
                        Rectangle().fill(Color.claudeAlert.opacity(0.15)).frame(width: w * 0.15)
                    }
                    .cornerRadius(2).frame(height: 3)

                    if burn > 0 && !isExhausted && projAtReset > pct {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pct2color(100).opacity(0.12))
                            .frame(width: w * min(projAtReset / 100, 1), height: 3)
                    }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [c.opacity(0.5), c],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * min(pct / 100, 1), height: 3)
                        .animation(.spring(response: 0.6), value: pct)
                }
            }
            .frame(height: 3)

            // ── Row 3: inline metrics ──
            HStack(spacing: 0) {
                if burn > 0.5 {
                    HStack(spacing: 1) {
                        Image(systemName: "flame").font(.system(size: 7))
                        Text(String(format: "%.1f%%/hr", burn))
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundColor(pct2color(max(pct, 50)))
                } else if pacing.paceRatio > 0 {
                    Text(String(format: "%.1f×", pacing.paceRatio))
                        .font(.system(size: 8)).foregroundColor(.white.opacity(0.30))
                }
                Spacer()
                if willHitLimit, let eta = etaMins {
                    Text("full \(absoluteTime(addingMinutes: eta))")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(pct2color(100))
                    Text(" · ").font(.system(size: 8)).foregroundColor(.white.opacity(0.15))
                }
                if let r = resetsAt, r > Date() {
                    Text(isExhausted ? "resets " : "ends ")
                        .font(.system(size: 8)).foregroundColor(.white.opacity(0.25))
                    Text(r, style: .relative)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(isExhausted ? .claudeAmber : .white.opacity(0.5))
                        .monospacedDigit()
                }
            }

            // ── Row 4: sparkline with projection ──
            if history.count >= 2 {
                let vals    = history.map { $0.1 }
                let projCol = pct2color(min(projAtReset, 100))
                Canvas { ctx, size in
                    let w = size.width; let h = size.height
                    let cap = max(100.0, projAtReset, vals.max() ?? 0)
                    func y(_ v: Double) -> CGFloat { h - h * 0.85 * CGFloat(min(v, cap) / cap) }

                    // 100% ceiling
                    var ceil = Path()
                    ceil.move(to: CGPoint(x: 0, y: y(100)))
                    ceil.addLine(to: CGPoint(x: w, y: y(100)))
                    ctx.stroke(ceil, with: .color(Color.white.opacity(0.06)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

                    let hEnd = w * 0.72
                    let step = hEnd / CGFloat(history.count - 1)

                    var fill = Path()
                    fill.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in vals.enumerated() { fill.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(v))) }
                    fill.addLine(to: CGPoint(x: hEnd, y: h)); fill.closeSubpath()
                    ctx.fill(fill, with: .color(c.opacity(0.10)))

                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(vals[0])))
                    for (i, v) in vals.enumerated() { line.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(v))) }
                    ctx.stroke(line, with: .color(c.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

                    let nowX = hEnd; let nowY = y(pct)
                    ctx.fill(Path(ellipseIn: CGRect(x: nowX - 2, y: nowY - 2, width: 4, height: 4)), with: .color(c))

                    if burn > 0 && projAtReset > pct {
                        var proj = Path()
                        proj.move(to: CGPoint(x: nowX, y: nowY))
                        proj.addLine(to: CGPoint(x: w, y: y(projAtReset)))
                        ctx.stroke(proj, with: .color(projCol.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        ctx.fill(Path(ellipseIn: CGRect(x: w - 2, y: y(projAtReset) - 2, width: 4, height: 4)),
                                 with: .color(projCol.opacity(0.6)))
                    }
                }
                .frame(height: 16)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .cornerRadius(7)
    }

    private func aChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.14))
            .cornerRadius(3)
    }

    // MARK: Focus Timer page

    private var focusPage: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Focus Timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                // Session dots (4 per long-break cycle)
                HStack(spacing: 3) {
                    ForEach(0..<4) { i in
                        Circle()
                            .fill(i < (timerManager.sessionCount % 4)
                                  ? Color.claudeCoral : Color.white.opacity(0.15))
                            .frame(width: 6, height: 6)
                    }
                }
                Text("×\(timerManager.sessionCount / 4 > 0 ? "\(timerManager.sessionCount / 4)" : "")")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(timerManager.sessionCount >= 4 ? 0.5 : 0))
            }

            thinDivider.padding(.vertical, 8)

            // Large countdown
            Text(timerManager.displayTime)
                .font(.system(size: 50, weight: .thin, design: .monospaced))
                .foregroundColor(focusTimerColor)
                .frame(maxWidth: .infinity)

            Text(focusPhaseLabel)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.38))
                .padding(.top, 2)

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(height: 2)
                    Capsule()
                        .fill(focusTimerColor.opacity(0.7))
                        .frame(width: g.size.width * timerManager.progress, height: 2)
                        .animation(.linear(duration: 1), value: timerManager.progress)
                }
            }.frame(height: 2).padding(.top, 10)

            // Controls
            HStack(spacing: 28) {
                Button(action: { timerManager.reset() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                }.buttonStyle(.plain)

                Button(action: {
                    timerManager.isRunning ? timerManager.pause() : timerManager.startOrResume()
                }) {
                    Image(systemName: timerManager.isRunning ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(focusTimerColor)
                }.buttonStyle(.plain)

                Button(action: { timerManager.skip() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(timerManager.isActive ? 0.35 : 0.12))
                }.buttonStyle(.plain).disabled(!timerManager.isActive)
            }.padding(.top, 14)

            Spacer(minLength: 0)

            if timerManager.sessionCount > 0 {
                Text("\(timerManager.sessionCount) session\(timerManager.sessionCount == 1 ? "" : "s") today")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.22))
            }
        }
    }

    private var focusTimerColor: Color {
        switch timerManager.phase {
        case .work:             return timerManager.remaining < 120 ? .claudeAlert : .claudeCoral
        case .shortBreak,
             .longBreak:        return .claudeTeal
        }
    }

    private var focusPhaseLabel: String {
        guard timerManager.isActive else { return "Ready to focus" }
        switch timerManager.phase {
        case .work:       return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak:  return "Long break"
        }
    }

    // MARK: System Monitor page

    private var systemPage: some View {
        VStack(spacing: 10) {
            HStack {
                Text("System")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if systemManager.cpuPct == 0 && systemManager.cpuHistory.allSatisfy({ $0 == 0 }) {
                    Text("Sampling…")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                }
            }

            thinDivider

            sysRow(label: "CPU",
                   value: "\(Int(systemManager.cpuPct))%",
                   pct: systemManager.cpuPct,
                   history: systemManager.cpuHistory,
                   color: cpuColor(systemManager.cpuPct))

            sysRow(label: "Memory",
                   value: String(format: "%.1f / %.0f GB",
                                 systemManager.ramUsedGB, systemManager.ramTotalGB),
                   pct: systemManager.ramPct,
                   history: systemManager.ramHistory,
                   color: ramColor(systemManager.ramPct))

            Spacer(minLength: 0)
        }
    }

    private func sysRow(label: String, value: String, pct: Double,
                        history: [Double], color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(height: 3)
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.5), color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * min(pct / 100, 1), height: 3)
                        .animation(.spring(response: 0.5), value: pct)
                }
            }.frame(height: 3)
            SparklineView(values: history, color: color).frame(height: 14)
        }
    }

    private func cpuColor(_ p: Double) -> Color {
        p >= 80 ? .claudeAlert : p >= 50 ? .claudeAmber : .claudeCoral
    }
    private func ramColor(_ p: Double) -> Color {
        p >= 85 ? .claudeAlert : p >= 70 ? .claudeAmber : .claudeTeal
    }

    // MARK: Notes page (rich text)

    private var notesPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
            }

            thinDivider.padding(.vertical, 6)

            // Formatting toolbar
            HStack(spacing: 3) {
                notesFmtBtn("B", font: .system(size: 11, weight: .bold),
                            active: editorState.isBold)       { editorState.toggleBold() }
                notesFmtBtn("I", font: .system(size: 11, weight: .regular).italic(),
                            active: editorState.isItalic)     { editorState.toggleItalic() }
                notesFmtBtn("U", underline: true,
                            active: editorState.isUnderline)  { editorState.toggleUnderline() }

                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 3)

                notesFmtBtn("H1", font: .system(size: 9, weight: .bold),
                            active: editorState.isHeading)    { editorState.setStyle(heading: true) }
                notesFmtBtn("¶",  font: .system(size: 11),
                            active: !editorState.isHeading)   { editorState.setStyle(heading: false) }

                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 3)

                ForEach(0..<6, id: \.self) { i in
                    Button(action: { editorState.setColor(index: i) }) {
                        ZStack {
                            Circle().fill(RichTextEditorState.paletteSwiftUI[i]).frame(width: 11, height: 11)
                            if editorState.activeColor == i {
                                Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                                    .frame(width: 14, height: 14)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.bottom, 6)

            // Editor — GeometryReader gives the NSViewRepresentable a concrete size
            GeometryReader { geo in
                RichTextView(state: editorState)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func notesFmtBtn(
        _ label: String,
        font: Font = .system(size: 11, weight: .medium),
        underline: Bool = false,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if underline {
                    Text(label).underline()
                } else {
                    Text(label)
                }
            }
            .font(font)
            .frame(width: 22, height: 20)
            .foregroundColor(active
                ? Color(red: 0.08, green: 0.08, blue: 0.10)
                : .white.opacity(0.55))
            .background(active ? Color.white.opacity(0.85) : Color.white.opacity(0.09))
            .cornerRadius(4)
        }.buttonStyle(.plain)
    }

    // MARK: Shared helpers

    private func settingRow<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.42))
                .frame(width: 58, alignment: .leading)
            Spacer()
            value()
        }
    }

    private var thinDivider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.25))
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .padding(.top, 2)
    }

    private func planBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [.claudeCoralLight, .claudeCoral],
                                            startPoint: .leading, endPoint: .trailing))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.claudeCoral.opacity(0.12))
            .clipShape(Capsule())
    }

    private func pct2color(_ p: Double) -> Color {
        if p >= 85 { return .claudeAlert }   // red
        if p >= 65 { return .claudeCoral }   // orange
        if p >= 40 { return .claudeAmber }   // yellow
        return .claudeTeal                    // green
    }

    private func timeLeft(_ d: Date) -> String {
        let s = d.timeIntervalSince(Date()); guard s > 0 else { return "" }
        let m = Int(s / 60); let h = m / 60; let day = h / 24
        if day > 0 { return "\(day)d" }
        if h  > 0 { let rm = m % 60; return rm > 0 ? "\(h)h\(rm)m" : "\(h)h" }
        return "\(m)m"
    }

    private func sizeLabel(_ s: ClaudeStatsSizePreset) -> String {
        switch s { case .small: return "S"; case .medium: return "M";
                   case .large: return "L"; case .extraLarge: return "XL" }
    }

    private func pacingLabel(_ m: ClaudeStatsPacingDisplayMode) -> String {
        switch m { case .hidden: return "Off"; case .arrowOnly: return "↑"; case .arrowWithTime: return "↑t" }
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let values: [Double]   // raw 0-100 values
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let vals = values
            let w = size.width
            let h = size.height
            let step = w / CGFloat(vals.count - 1)

            // Auto-scale Y axis: zoom to visible data range so any variation shows up.
            // Ensure a minimum span of 5 points so an identical-value series draws
            // a centred flat line rather than disappearing at the top of the chart.
            let rawMin = vals.min()!
            let rawMax = vals.max()!
            let dataRange = max(rawMax - rawMin, 5.0)
            let low  = rawMin - dataRange * 0.15
            let high = rawMax + dataRange * 0.15
            let span = high - low   // always > 0

            func pt(_ i: Int) -> CGPoint {
                let normalized = (vals[i] - low) / span
                return CGPoint(x: CGFloat(i) * step,
                               y: h - h * CGFloat(normalized))
            }

            // Gradient fill
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: h))
            for i in 0..<vals.count { fill.addLine(to: pt(i)) }
            fill.addLine(to: CGPoint(x: w, y: h))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.15)))

            // Line
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<vals.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(color.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            // Endpoint dot
            let last = pt(vals.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)),
                     with: .color(color))
        }
    }
}

// MARK: - Pulsing chip (when usage >= 80%)

struct PulsingChip<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: () -> Content
    @State private var dim = false

    var body: some View {
        content()
            .opacity(dim ? 0.55 : 1.0)
            .onAppear { startIfNeeded() }
            .onChange(of: active) { _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        if active {
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                dim = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { dim = false }
        }
    }
}

// MARK: - Segment picker

struct SegmentPicker<T: Hashable>: View {
    let options:  [T]
    @Binding var selected: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                Button(action: { selected = opt }) {
                    Text(label(opt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(selected == opt
                            ? Color(red: 0.08, green: 0.08, blue: 0.10)
                            : .white.opacity(0.45))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(selected == opt
                            ? Color.white.opacity(0.88)
                            : Color.white.opacity(0.09))
                        .cornerRadius(5)
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Rich Text Editor State

final class RichTextEditorState: ObservableObject {
    weak var textView: NSTextView?

    @Published var isBold      = false
    @Published var isItalic    = false
    @Published var isUnderline = false
    @Published var isHeading   = false
    @Published var activeColor = 0

    // White, Coral, Amber, Teal, Sky, Lavender
    static let palette: [NSColor] = [
        NSColor.white.withAlphaComponent(0.82),
        NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        NSColor(red: 0.95, green: 0.70, blue: 0.35, alpha: 1),
        NSColor(red: 0.38, green: 0.87, blue: 0.76, alpha: 1),
        NSColor(red: 0.55, green: 0.80, blue: 1.00, alpha: 1),
        NSColor(red: 0.78, green: 0.65, blue: 1.00, alpha: 1),
    ]
    static let paletteSwiftUI: [Color] = [
        .white,
        Color(red: 0.85, green: 0.47, blue: 0.34),
        Color(red: 0.95, green: 0.70, blue: 0.35),
        Color(red: 0.38, green: 0.87, blue: 0.76),
        Color(red: 0.55, green: 0.80, blue: 1.00),
        Color(red: 0.78, green: 0.65, blue: 1.00),
    ]

    private let baseSize: CGFloat    = 12
    private let headingSize: CGFloat = 16

    func syncState() {
        guard let tv = textView else { return }
        let attrs: [NSAttributedString.Key: Any]
        let sel = tv.selectedRange()
        if sel.length > 0, let storage = tv.textStorage, storage.length > 0,
           sel.location < storage.length {
            attrs = storage.attributes(at: sel.location, effectiveRange: nil)
        } else {
            attrs = tv.typingAttributes
        }
        let font = attrs[.font] as? NSFont ?? NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        let fm   = NSFontManager.shared
        isBold      = fm.traits(of: font).contains(.boldFontMask)
        isItalic    = fm.traits(of: font).contains(.italicFontMask)
        isUnderline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        isHeading   = font.pointSize >= headingSize
        if let raw   = attrs[.foregroundColor] as? NSColor,
           let color = raw.usingColorSpace(.sRGB) {
            activeColor = Self.palette.firstIndex {
                guard let p = $0.usingColorSpace(.sRGB) else { return false }
                return abs(p.redComponent   - color.redComponent)   < 0.08 &&
                       abs(p.greenComponent - color.greenComponent) < 0.08
            } ?? 0
        } else { activeColor = 0 }
    }

    func toggleBold() {
        guard let tv = textView else { return }
        applyFontTrait(tv, mask: .boldFontMask)
        syncState(); save(tv)
    }

    func toggleItalic() {
        guard let tv = textView else { return }
        applyFontTrait(tv, mask: .italicFontMask)
        syncState(); save(tv)
    }

    func toggleUnderline() {
        guard let tv = textView else { return }
        let sel     = tv.selectedRange()
        let current = tv.typingAttributes[.underlineStyle] as? Int ?? 0
        let newVal  = current != 0 ? 0 : NSUnderlineStyle.single.rawValue
        if sel.length > 0 { tv.textStorage?.addAttribute(.underlineStyle, value: newVal, range: sel) }
        tv.typingAttributes[.underlineStyle] = newVal
        syncState(); save(tv)
    }

    func setColor(index: Int) {
        guard let tv = textView, index < Self.palette.count else { return }
        let color = Self.palette[index]
        let sel   = tv.selectedRange()
        if sel.length > 0 { tv.textStorage?.addAttribute(.foregroundColor, value: color, range: sel) }
        tv.typingAttributes[.foregroundColor] = color
        activeColor = index
        save(tv)
    }

    func setStyle(heading: Bool) {
        guard let tv = textView else { return }
        let size:   CGFloat         = heading ? headingSize : baseSize
        let weight: NSFont.Weight   = heading ? .semibold : .regular
        let sel = tv.selectedRange()
        if sel.length > 0 {
            tv.textStorage?.enumerateAttribute(.font, in: sel, options: []) { val, range, _ in
                let old = val as? NSFont ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                let new = NSFont(descriptor: old.fontDescriptor, size: size)
                        ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                tv.textStorage?.addAttribute(.font, value: new, range: range)
            }
        }
        tv.typingAttributes[.font] = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        isHeading = heading
        save(tv)
    }

    func save(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        if let data = storage.rtf(from: range, documentAttributes: [:]) {
            UserDefaults.standard.set(data, forKey: "cn.notesRTF")
        }
    }

    func loadContent() -> NSAttributedString {
        if let data = UserDefaults.standard.data(forKey: "cn.notesRTF"),
           let s    = NSAttributedString(rtf: data, documentAttributes: nil) { return s }
        return NSAttributedString()
    }

    private func applyFontTrait(_ tv: NSTextView, mask: NSFontTraitMask) {
        let fm  = NSFontManager.shared
        let sel = tv.selectedRange()
        let baseAttrs: [NSAttributedString.Key: Any] = {
            if sel.length > 0, let storage = tv.textStorage, storage.length > 0 {
                return storage.attributes(at: min(sel.location, storage.length - 1), effectiveRange: nil)
            }
            return tv.typingAttributes
        }()
        let font     = baseAttrs[.font] as? NSFont ?? NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        let hasTrait = fm.traits(of: font).contains(mask)

        if sel.length > 0 {
            tv.textStorage?.enumerateAttribute(.font, in: sel, options: []) { val, range, _ in
                let f   = val as? NSFont ?? NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
                let new = hasTrait ? fm.convert(f, toNotHaveTrait: mask) : fm.convert(f, toHaveTrait: mask)
                tv.textStorage?.addAttribute(.font, value: new, range: range)
            }
        }
        let newTyping = hasTrait ? fm.convert(font, toNotHaveTrait: mask) : fm.convert(font, toHaveTrait: mask)
        tv.typingAttributes[.font] = newTyping
    }
}

// MARK: - Rich Text NSView

struct RichTextView: NSViewRepresentable {
    @ObservedObject var state: RichTextEditorState

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.backgroundColor  = .clear
        tv.drawsBackground  = false
        tv.isRichText        = true
        tv.allowsUndo        = true
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.font              = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor         = NSColor.white.withAlphaComponent(0.82)
        tv.insertionPointColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        let saved = state.loadContent()
        if saved.length > 0 { tv.textStorage?.setAttributedString(saved) }
        sv.backgroundColor   = .clear
        sv.drawsBackground   = false
        sv.hasVerticalScroller = true
        sv.scrollerStyle     = .overlay
        state.textView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        state.textView = sv.documentView as? NSTextView
    }

    func makeCoordinator() -> Coordinator { Coordinator(state) }

    class Coordinator: NSObject, NSTextViewDelegate {
        let state: RichTextEditorState
        init(_ state: RichTextEditorState) { self.state = state }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            state.save(tv)
        }
        func textViewDidChangeSelection(_ n: Notification) {
            DispatchQueue.main.async { self.state.syncState() }
        }
    }
}

// MARK: - Shapes

struct LeftWingShape: Shape {
    let cornerR: CGFloat
    func path(in rect: CGRect) -> Path {
        let (w, h, r) = (rect.width, rect.height, min(cornerR, rect.height / 2))
        var p = Path()
        p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: w, y: 0))
        p.addLine(to: .init(x: w, y: h)); p.addLine(to: .init(x: r, y: h))
        p.addQuadCurve(to: .init(x: 0, y: h - r), control: .init(x: 0, y: h))
        p.closeSubpath(); return p
    }
}

struct RightWingShape: Shape {
    let cornerR: CGFloat
    func path(in rect: CGRect) -> Path {
        let (w, h, r) = (rect.width, rect.height, min(cornerR, rect.height / 2))
        var p = Path()
        p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: w, y: 0))
        p.addLine(to: .init(x: w, y: h - r))
        p.addQuadCurve(to: .init(x: w - r, y: h), control: .init(x: w, y: h))
        p.addLine(to: .init(x: 0, y: h)); p.closeSubpath(); return p
    }
}

struct PanelShape: Shape {
    let cornerR: CGFloat
    func path(in rect: CGRect) -> Path {
        let (w, h, r) = (rect.width, rect.height, cornerR)
        var p = Path()
        p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: w, y: 0))
        p.addLine(to: .init(x: w, y: h - r))
        p.addQuadCurve(to: .init(x: w - r, y: h), control: .init(x: w, y: h))
        p.addLine(to: .init(x: r, y: h))
        p.addQuadCurve(to: .init(x: 0, y: h - r), control: .init(x: 0, y: h))
        p.closeSubpath(); return p
    }
}

// MARK: - Claude Tips Library
// Context-aware tips covering slash commands, prompt techniques, and usage strategies.

private enum ClaudeTips {

    // MARK: Sudden spike (pace ratio jumped: likely large paste or file dump)
    static let suddenSpike: [(String, String)] = [
        ("📈 Token Spike — Try Artifacts",
         "Pasting large code? Use Claude Artifacts — they live outside the context window and are reusable across messages."),
        ("📈 Usage Spike Detected",
         "Sharp jump in usage! Tip: instead of pasting a whole file, share only the relevant function or section. Claude needs less context than you think."),
        ("📈 Big Context Jump",
         "If you pasted a large document, run /compact now to stabilize. It summarises the conversation and reclaims ~60 % of used context."),
        ("📈 Spike — Focused Prompts Help",
         "Spike detected! Instead of 'fix everything', be specific: 'Fix the auth bug in login.swift line 42.' Smaller prompts = less token overhead per answer."),
        ("📈 Upload Instead of Pasting",
         "Sharing large files? Use the file-upload button in Claude — it doesn't count against your context the same way as raw text paste."),
    ]

    // MARK: Sustained high burn rate (pace > 2.5×)
    static let burnHigh: [(String, String)] = [
        ("⚡ Burning Fast — Use /compact",
         "Your session is burning faster than usual. Type /compact in Claude to compress conversation history — it keeps context but cuts token count significantly."),
        ("⚡ High Usage — /compact Is Your Friend",
         "/compact summarises your chat into a concise handoff and continues from there. Perfect when you're deep in a long conversation."),
        ("⚡ Reduce Overhead With XML Tags",
         "High burn rate tip: structure prompts with XML tags. E.g. <context>…</context><task>…</task>. Claude processes structured input more efficiently."),
        ("⚡ Chain-of-Thought = Fewer Retries",
         "Burning fast? Ask Claude to 'think step by step' upfront. You get the answer in one go instead of iterating with follow-ups — net token saving."),
        ("⚡ One Goal Per Message",
         "High usage tip: each message should have exactly one clear goal. Multi-part prompts generate longer responses and exhaust context faster."),
    ]

    // MARK: Session 70% — first proactive reminder
    static let session70: [(String, String)] = [
        ("💛 Session at 70 % — Run /compact",
         "You're 70 % through your 5-hour window. A great time to /compact — Claude will summarise everything and continue with a much smaller context footprint."),
        ("💛 70 % — Checkpoint Your Work",
         "At 70 %! Tip: ask Claude 'Summarise what we've built so far in 5 bullet points.' Paste that into the next session if the window resets."),
        ("💛 Context Tip: Use /compact Now",
         "/compact at 70 % is ideal — enough history to summarise well, enough runway left to keep working. Type it directly in Claude's chat."),
        ("💛 Session 70 % — Consider /clear",
         "If you're switching to a new topic, /clear starts a fresh chat within the same 5-hour window. No waste, clean context."),
    ]

    // MARK: Session 85% — urgent
    static let session85: [(String, String)] = [
        ("🟠 Session 85 % — Compact Now!",
         "85 % used — don't wait! Type /compact in Claude immediately. It frees up context so you can keep going instead of hitting the wall."),
        ("🟠 85 % — Last Good Time to /compact",
         "/compact at 85 % still works well. After it runs, tell Claude: 'Continue from where we left off.' Full context is preserved in the summary."),
        ("🟠 Nearly Full — Save Your Work",
         "Session almost full! Ask Claude: 'Give me a compact handoff note of everything we've done.' Paste it into the next session or after /clear."),
        ("🟠 85 % — Switch Topics? Use /clear",
         "Starting something new? /clear opens a blank slate within the same session window. You lose the current thread but gain a full fresh context."),
    ]

    // MARK: Session 95% — critical
    static let session95: [(String, String)] = [
        ("🔴 Session Critical — /compact Now",
         "95 %! Type /compact immediately — it's your last chance to reclaim context before the window fills. Claude will keep going from the summary."),
        ("🔴 Almost Full — Get a Handoff Summary",
         "About to hit the limit! Ask: 'Write a one-paragraph summary of our work so far.' Save it — you'll paste it at the top of your next session."),
        ("🔴 95 % — /clear Resets the Clock",
         "/clear opens a completely fresh context within the same 5-hour window. If your current task is done, /clear is the cleanest option."),
        ("🔴 Last Tokens — Be Terse",
         "Nearly full! Keep messages ultra-short now. Ask for code only, no explanations. Every token counts when you're this close to the limit."),
    ]

    // MARK: Session reset (window just refreshed)
    static let sessionReset: [(String, String)] = [
        ("✅ Fresh 5-Hour Window",
         "Session reset! Tip: start complex tasks with a system-style opener — 'You are helping me build X. Here's the context: …' Sets the tone for the whole session."),
        ("✅ New Session — Claude Forgets Everything",
         "Fresh window! Remember: Claude has no memory of previous sessions unless you give it context. Paste a short project brief at the start of important chats."),
        ("✅ Reset! Use Claude Projects",
         "New session! If you work on the same project repeatedly, Claude Projects store persistent instructions so you never have to re-explain your stack."),
        ("✅ Fresh Start — Best Practices",
         "New window opened! Tip: one focused goal per session = maximum efficiency. Avoid switching topics — it fragments context and burns tokens on context-switching."),
        ("✅ Session Refreshed — Try /help",
         "New 5-hour window! Not sure what Claude can do? Type /help in any chat for a full list of slash commands and features."),
    ]

    // MARK: Weekly 80%
    static let weekly80: [(String, String)] = [
        ("📊 Weekly Quota at 80 %",
         "80 % of your weekly quota used. Tip: combine related questions into single messages — fewer round-trips = less overhead per answer."),
        ("📊 Weekly 80 % — Prioritise Tasks",
         "Running low weekly. Focus remaining quota on high-value work. Use Haiku for quick lookups and Sonnet for complex reasoning."),
        ("📊 80 % Weekly — Projects Save Quota",
         "80 % weekly! Claude Projects let you store persistent instructions and files. Less time re-explaining = fewer tokens spent on setup each session."),
        ("📊 Weekly Tip: Batch Your Questions",
         "Weekly at 80 %! Instead of one question at a time, batch: 'Answer these 3 questions: 1) … 2) … 3) …' One response covers all three."),
    ]

    // MARK: Weekly 95%
    static let weekly95: [(String, String)] = [
        ("🔴 Weekly Quota Nearly Gone",
         "95 % of weekly quota used. Reserve remaining usage for critical tasks only. Your quota resets in a few days."),
        ("🔴 Weekly Critical — Use Claude.ai Wisely",
         "Almost at weekly limit! Ultra-short prompts only. Skip pleasantries — Claude doesn't need them and each word costs context."),
        ("🔴 Weekly 95 % — Efficiency Mode",
         "Last 5 % of the week! Tip: ask Claude to reply in bullet points or code only. Concise output = more answers before the quota resets."),
    ]

    // MARK: Sonnet approaching 80%
    static let sonnet80: [(String, String)] = [
        ("🤖 Sonnet at 80 % — Switch Models",
         "Sonnet usage at 80 %! For simpler tasks (summaries, quick edits, Q&A), switch to Haiku via the model picker — it's much lighter on quotas."),
        ("🤖 Sonnet Running Low",
         "Sonnet 80 %! Tip: use Claude Haiku for iteration and drafts, save Sonnet for the final polish. You'll stretch your quota much further."),
        ("🤖 Sonnet 80 % — Task Matching",
         "Running low on Sonnet! Match model to task: Sonnet for complex reasoning & code, Haiku for summaries, Q&A, and formatting tasks."),
    ]
}
