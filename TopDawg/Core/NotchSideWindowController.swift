import AppKit
import SwiftUI
import Combine

// MARK: - Notch Side Window Controller

/// Displays a transparent overlay in the menu bar,
/// with stats content positioned LEFT and RIGHT of the hardware notch.
final class NotchSideWindowController: NSWindowController, ObservableObject {

    private var screen: NSScreen
    private var manager: ClaudeUsageManager
    private var settings: ClaudeStatsSettings

    // Hover state — shared with the SwiftUI content via @Published
    @Published var isHovering = false
    private var mouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(manager: ClaudeUsageManager, settings: ClaudeStatsSettings, screen: NSScreen) {
        self.manager  = manager
        self.settings = settings
        self.screen   = screen

        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque        = false
        window.hasShadow       = false
        window.level           = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true   // default pass-through; hover activates via global monitor

        super.init(window: window)

        setupContent()
        setupMouseTracking()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Content

    private func setupContent() {
        guard let window = window else { return }
        let hostingView = NSHostingView(rootView: makeRootView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        window.contentView = hostingView
        position()
    }

    private func makeRootView() -> some View {
        NotchBarRootView(
            manager: manager,
            settings: settings,
            controller: self,
            screen: screen
        )
    }

    func refresh() {
        setupContent()
    }

    // MARK: - Positioning

    func position() {
        guard let window = window else { return }

        // Use the latest matching screen
        if let updated = NSScreen.screens.first(where: { $0.frame.origin == screen.frame.origin }) {
            screen = updated
        }

        let barH = menuBarHeight(screen: screen)
        let sw = screen.frame.width

        window.setContentSize(NSSize(width: sw, height: barH))
        window.setFrameOrigin(NSPoint(
            x: screen.frame.origin.x,
            y: screen.frame.maxY - barH
        ))
    }

    func updateScreen(_ newScreen: NSScreen) {
        screen = newScreen
        setupContent()
        position()
    }

    // MARK: - Mouse Tracking (hover to reveal gear button)

    private func setupMouseTracking() {
        // Global mouse moved monitor — no special permission needed
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] _ in
            self?.checkMouseProximity()
        }
    }

    private func checkMouseProximity() {
        guard let window = window else { return }
        let mouse = NSEvent.mouseLocation
        let windowFrame = window.frame
        // Expand hit zone slightly beyond the window frame
        let zone = windowFrame.insetBy(dx: -4, dy: -4)
        let nowHovering = zone.contains(mouse)
        if nowHovering != isHovering {
            DispatchQueue.main.async { self.isHovering = nowHovering }
        }
    }

    // MARK: - Show/Hide

    func show() {
        position()
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    @objc private func screenChanged(_ notification: Notification) {
        position()
        setupContent()
    }

    // MARK: - Helper

    private func menuBarHeight(screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            return screen.safeAreaInsets.top
        }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }
}

// MARK: - Root View (positions content beside notch)

struct NotchBarRootView: View {
    @ObservedObject var manager: ClaudeUsageManager
    @ObservedObject var settings: ClaudeStatsSettings
    @ObservedObject var controller: NotchSideWindowController
    let screen: NSScreen

    private var geo: NotchGeometry { NotchGeometry(screen: screen) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            HStack(spacing: 0) {
                // LEFT side of notch
                HStack {
                    Spacer(minLength: 0)
                    leftContent
                        .padding(.trailing, 10)
                }
                .frame(width: geo.leftWidth)

                // Gap — the actual hardware notch lives here, leave transparent
                Spacer(minLength: geo.notchGap)

                // RIGHT side of notch
                HStack {
                    rightContent
                        .padding(.leading, 10)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.rightWidth)
            }
            .frame(width: geo.screenWidth, height: geo.barHeight, alignment: .center)
        }
        .frame(width: geo.screenWidth, height: geo.barHeight)
    }

    // MARK: - Left: Session

    @ViewBuilder
    private var leftContent: some View {
        if manager.isAuthenticated {
            HStack(spacing: 0) {
                BarStatLabel(
                    label: "Session",
                    percentage: manager.usageData.sessionPercentage,
                    pacing: manager.usageData.sessionPacing,
                    resetsAt: manager.usageData.sessionResetsAt,
                    pacingMode: settings.pacingDisplayMode,
                    fontSize: settings.sizePreset.titleFontSize
                )
                // Hover gear button on left side
                if controller.isHovering {
                    Button(action: openSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: controller.isHovering)
        } else {
            unauthenticatedView
        }
    }

    // MARK: - Right: Logo + Weekly (+ Opus)

    @ViewBuilder
    private var rightContent: some View {
        if manager.isAuthenticated {
            HStack(spacing: 6) {
                Image("ClaudeLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: settings.sizePreset.titleFontSize + 4,
                           height: settings.sizePreset.titleFontSize + 4)

                BarStatLabel(
                    label: "Weekly",
                    percentage: manager.usageData.weeklyPercentage,
                    pacing: manager.usageData.weeklyPacing,
                    resetsAt: manager.usageData.weeklyResetsAt,
                    pacingMode: settings.pacingDisplayMode,
                    fontSize: settings.sizePreset.titleFontSize
                )

                if manager.usageData.opusPercentage > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 14)

                    BarStatLabel(
                        label: "Opus",
                        percentage: manager.usageData.opusPercentage,
                        pacing: nil,
                        resetsAt: manager.usageData.opusResetsAt,
                        pacingMode: .hidden,
                        fontSize: settings.sizePreset.titleFontSize
                    )
                }

                if manager.isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                }
            }
        }
    }

    // MARK: - Not-authenticated hint

    private var unauthenticatedView: some View {
        Button(action: openSettings) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.claudeCoral)
                Text("Setup TopDawg")
                    .font(.system(size: settings.sizePreset.titleFontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Open Settings

    private func openSettings() {
        // Enable mouse events so the click registers, then open popover via menu bar
        // We post a notification that AppDelegate listens to
        NotificationCenter.default.post(name: .openTopDawgSettings, object: nil)
    }
}

// MARK: - Notch Geometry

struct NotchGeometry {
    let screenWidth: CGFloat
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let notchGap: CGFloat
    let barHeight: CGFloat

    init(screen: NSScreen) {
        screenWidth = screen.frame.width

        if #available(macOS 12.0, *),
           let left  = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            leftWidth  = left.width
            rightWidth = right.width
            notchGap   = screenWidth - left.width - right.width
            barHeight  = screen.safeAreaInsets.top
        } else {
            // Non-notch: treat full width as left, no gap
            leftWidth  = screenWidth / 2
            rightWidth = screenWidth / 2
            notchGap   = 0
            barHeight  = screen.frame.maxY - screen.visibleFrame.maxY
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let openTopDawgSettings = Notification.Name("openTopDawgSettings")
}
