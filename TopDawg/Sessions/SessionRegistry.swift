import Foundation
import Combine

/// Polls the three scanners on a timer and publishes a deduped, sorted list of
/// every Claude session currently visible on this Mac. Owned by `NotchHoverWindow`,
/// observed by `SessionsPanelView`.
final class SessionRegistry: ObservableObject {

    @Published private(set) var sessions: [UnifiedSession] = []
    @Published private(set) var lastRefresh: Date?

    private let cli     = CLIScanner()
    private let cowork  = CoworkScanner()
    private let desktop = DesktopScanner()

    private var timer: Timer?
    private let pollInterval: TimeInterval = 5

    init() {
        refresh()
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Hop back to the main actor — Timer's callback isn't isolated.
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Reruns all three scanners on a background queue and updates `sessions` on main.
    func refresh() {
        Task.detached(priority: .utility) { [cli, cowork, desktop] in
            let cliSessions     = cli.scan()
            let coworkSessions  = cowork.scan()
            let desktopSessions = desktop.scan()

            // Sort: running first, then by lastActivity desc.
            let merged = (cliSessions + coworkSessions + desktopSessions)
                .sorted { lhs, rhs in
                    if lhs.isRunning != rhs.isRunning { return lhs.isRunning && !rhs.isRunning }
                    return lhs.lastActivity > rhs.lastActivity
                }

            await MainActor.run { [weak self] in
                self?.sessions = merged
                self?.lastRefresh = Date()
            }
        }
    }

    // MARK: - Convenience accessors for the UI

    var runningCount: Int { sessions.filter { $0.isRunning }.count }

    func sessions(of kind: SessionKind) -> [UnifiedSession] {
        sessions.filter { $0.kind == kind }
    }
}
