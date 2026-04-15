import SwiftUI
import AppKit

// MARK: - Setup Window Controller

final class SetupWindowController {
    static let shared = SetupWindowController()
    private var window: NSWindow?
    private init() {}

    func show(manager: ClaudeUsageManager, settings: ClaudeStatsSettings, onComplete: @escaping () -> Void) {
        close()
        let view = SetupView(manager: manager, settings: settings, onComplete: { [weak self] in
            self?.close()
            onComplete()
        })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "TopDawg Setup"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 560, height: 580))
        w.center()
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - Setup View

struct SetupView: View {
    @ObservedObject var manager: ClaudeUsageManager
    @ObservedObject var settings: ClaudeStatsSettings
    let onComplete: () -> Void

    @State private var step = 0
    @State private var sessionKey = ""
    @State private var isConnecting = false
    @State private var connectError: String? = nil
    @State private var selectedBrowser = "safari"
    @State private var showManualInput = false
    private let webLogin = WebLoginWindowController()

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.09, blue: 0.13),
                    Color(red: 0.12, green: 0.08, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicator
                stepIndicator
                    .padding(.top, 32)

                Spacer()

                // Content
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: connectStep
                    case 2: customizeStep
                    default: doneStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.spring(duration: 0.35), value: step)

                Spacer()

                // Navigation buttons
                navigationButtons
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 48)
        }
        .frame(width: 560, height: 580)
        .preferredColorScheme(.dark)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.claudeCoral : Color.white.opacity(0.15))
                    .frame(width: i == step ? 24 : 8, height: 6)
                    .animation(.spring(duration: 0.3), value: step)
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image("ClaudeLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .padding(20)
                .background(
                    Circle()
                        .fill(Color.claudeCoral.opacity(0.12))
                )

            Text("Welcome to TopDawg")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Your Claude usage, always visible —\nright beside your MacBook's notch.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            HStack(spacing: 24) {
                featurePill(icon: "chart.bar.fill", text: "Live Usage")
                featurePill(icon: "clock.fill", text: "Session & Weekly")
                featurePill(icon: "arrow.up.right", text: "Pacing")
            }
            .padding(.top, 8)
        }
    }

    private func featurePill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.claudeCoral)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.07))
        .clipShape(Capsule())
    }

    // MARK: - Step 1: Connect

    private var connectStep: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Connect your account")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Sign in to Claude to start tracking your usage.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
            }

            // ── Primary: One-click sign in ──
            VStack(spacing: 14) {
                Button(action: { openWebLogin() }) {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sign in with Claude")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Opens a browser window — just log in normally")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [.claudeCoralLight.opacity(0.9), .claudeCoral],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                if isConnecting {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("Waiting for sign-in…")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                if let err = connectError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.claudeAlert)
                }

                // How it works
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundColor(.claudeTeal)
                        Text("How it works")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text("A sign-in window opens where you log into claude.ai. After login, the app reads your session cookie automatically. Your credentials are never stored — only the session token.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
            }

            // ── Divider with "or" ──
            HStack {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                Text("or")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.horizontal, 8)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }

            // ── Fallback: Manual paste ──
            VStack(alignment: .leading, spacing: 8) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showManualInput.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: showManualInput ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Paste session key manually")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                if showManualInput {
                    VStack(alignment: .leading, spacing: 10) {
                        // Browser-specific instructions
                        HStack(spacing: 8) {
                            browserTab("Safari", icon: "safari", selected: selectedBrowser == "safari") { selectedBrowser = "safari" }
                            browserTab("Chrome", icon: "globe", selected: selectedBrowser == "chrome") { selectedBrowser = "chrome" }
                        }

                        if selectedBrowser == "safari" {
                            VStack(alignment: .leading, spacing: 5) {
                                instructionRow(n: 1, text: "Go to claude.ai and log in")
                                instructionRow(n: 2, text: "Safari → Settings → Advanced → Show Develop menu")
                                instructionRow(n: 3, text: "Develop → Show Web Inspector (⌥⌘I)")
                                instructionRow(n: 4, text: "Storage → Cookies → claude.ai → copy sessionKey value")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                instructionRow(n: 1, text: "Go to claude.ai and log in")
                                instructionRow(n: 2, text: "Press F12 → Application → Cookies → claude.ai")
                                instructionRow(n: 3, text: "Find sessionKey → copy the value")
                            }
                        }

                        TextField("Paste your sessionKey cookie value here…", text: $sessionKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(sessionKey.isEmpty ? Color.white.opacity(0.1) : Color.claudeCoral.opacity(0.5), lineWidth: 1)
                            )
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        } // end ScrollView
    }

    private func browserTab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selected ? .white : .white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.claudeCoral.opacity(0.25) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.claudeCoral.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func instructionRow(n: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.claudeCoral)
                .frame(width: 18, height: 18)
                .background(Color.claudeCoral.opacity(0.15))
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Customize

    private var customizeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Customize your notch")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Configure how TopDawg looks and behaves.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
            }

            VStack(spacing: 1) {
                settingRow(title: "Display Size") {
                    Picker("", selection: Binding(
                        get: { settings.sizePreset },
                        set: { settings.sizePreset = $0 }
                    )) {
                        ForEach(ClaudeStatsSizePreset.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .colorScheme(.dark)
                }

                settingRow(title: "Pacing Arrows") {
                    Picker("", selection: Binding(
                        get: { settings.pacingDisplayMode },
                        set: { settings.pacingDisplayMode = $0 }
                    )) {
                        ForEach(ClaudeStatsPacingDisplayMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .colorScheme(.dark)
                }

                settingRow(title: "Auto-refresh every") {
                    Picker("", selection: Binding(
                        get: { settings.refreshInterval },
                        set: { settings.refreshInterval = $0 }
                    )) {
                        ForEach(ClaudeStatsRefreshInterval.allCases, id: \.self) { i in
                            Text(i.displayName).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .colorScheme(.dark)
                }

                if NSScreen.screens.count > 1 {
                    settingRow(title: "Show on display") {
                        Picker("", selection: Binding(
                            get: { settings.assignedDisplayID },
                            set: { settings.assignedDisplayID = $0 }
                        )) {
                            ForEach(NSScreen.screens, id: \.displayID) { s in
                                Text(s.localizedName).tag(s.displayID)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                        .colorScheme(.dark)
                    }
                }
            }
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
        }
    }

    private func settingRow<C: View>(title: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    // MARK: - Step 3: Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.claudeTeal.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.claudeTeal)
            }

            Text("You're all set!")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("TopDawg is now active.\nYour usage stats will appear beside your MacBook's notch.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            VStack(spacing: 8) {
                tipRow(icon: "cursorarrow", text: "Hover over the notch to open the dashboard")
                tipRow(icon: "keyboard", text: "Press ⌃⌥C to toggle the panel anytime")
                tipRow(icon: "arrow.clockwise", text: "Data refreshes automatically in the background")
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.claudeCoral)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.65))
            Spacer()
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            if step > 0 && step < 3 {
                Button(action: { withAnimation { step -= 1 } }) {
                    Text("Back")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Primary button
            Group {
                switch step {
                case 0:
                    primaryButton("Get Started") { withAnimation { step = 1 } }
                case 1:
                    if manager.isAuthenticated {
                        primaryButton("Continue →") { withAnimation { step = 2 } }
                    } else {
                        primaryButton(isConnecting ? "Connecting…" : "Connect Account") {
                            connectAccount()
                        }
                        .disabled(sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                    }
                case 2:
                    primaryButton("Looks Good →") { withAnimation { step = 3 } }
                default:
                    primaryButton("Start Using TopDawg") { onComplete() }
                }
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [.claudeCoralLight, .claudeCoral],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func openWebLogin() {
        isConnecting = true
        connectError = nil
        webLogin.show { token in
            self.sessionKey = token
            self.finishConnect(token: token)
        }
    }

    private func connectAccount() {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        finishConnect(token: key)
    }

    private func finishConnect(token: String) {
        isConnecting = true
        connectError = nil
        manager.setSession(cookie: token, organizationId: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isConnecting = false
            if manager.isAuthenticated {
                withAnimation { step = 2 }
            } else {
                connectError = "Could not connect. Check your session key and try again."
            }
        }
    }
}
