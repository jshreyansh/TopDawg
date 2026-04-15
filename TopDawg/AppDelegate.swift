import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    let manager  = ClaudeUsageManager()
    let settings = ClaudeStatsSettings()

    private var notchWindow:  NotchHoverWindow?
    private var cancellables  = Set<AnyCancellable>()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNotchWindow()
        setupObservers()

        let hasSetup = UserDefaults.standard.bool(forKey: "cn.setupComplete")
        if !hasSetup || !manager.isAuthenticated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SetupWindowController.shared.show(manager: self.manager, settings: self.settings) {
                    UserDefaults.standard.set(true, forKey: "cn.setupComplete")
                }
            }
        }

        // Auto-updater disabled. Re-enable only after pointing
        // UpdateChecker.swift at a repo you control (and wiring up releases).
        // DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        //     UpdateChecker.shared.checkOnLaunchIfNeeded()
        // }
    }

    // MARK: - Notch Window

    private func setupNotchWindow() {
        let screen = targetScreen()
        notchWindow = NotchHoverWindow(manager: manager, settings: settings, screen: screen)
        notchWindow?.show()
        manager.startPolling(interval: settings.refreshInterval.seconds)
    }

    private func targetScreen() -> NSScreen {
        let id = settings.assignedDisplayID
        return NSScreen.screens.first { $0.displayID == id } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Observers

    private func setupObservers() {
        settings.$refreshInterval
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] i in self?.manager.startPolling(interval: i.seconds) }
            .store(in: &cancellables)

        settings.$assignedDisplayID
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notchWindow?.updateScreen(self.targetScreen())
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            settings.$sizePreset.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pacingDisplayMode.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.notchWindow?.refresh() }
        .store(in: &cancellables)

        manager.$isAuthenticated.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.notchWindow?.refresh() }
            .store(in: &cancellables)

        manager.$usageData.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.notchWindow?.refresh() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notchWindow?.updateScreen(self.targetScreen())
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let self else { return }
                    self.notchWindow?.updateScreen(self.targetScreen())
                    self.manager.refresh()
                }
            }
            .store(in: &cancellables)
    }
}
