import Foundation
import Combine
import UserNotifications

enum FocusPhase: Equatable { case work, shortBreak, longBreak }

final class FocusTimerManager: ObservableObject {
    @Published private(set) var remaining:    TimeInterval = 0
    @Published private(set) var isRunning:    Bool = false
    @Published private(set) var isActive:     Bool = false   // started at least once
    @Published private(set) var phase:        FocusPhase = .work
    @Published private(set) var sessionCount: Int = 0

    var workDuration:       TimeInterval = 25 * 60
    var shortBreakDuration: TimeInterval =  5 * 60
    var longBreakDuration:  TimeInterval = 15 * 60

    private var sink: AnyCancellable?

    // MARK: - Computed

    var displayTime: String {
        let t = max(0, Int(isActive ? remaining : workDuration))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var progress: Double {
        guard isActive else { return 0 }
        let total = phaseDuration(phase)
        return total > 0 ? max(0, min(1, 1.0 - remaining / total)) : 0
    }

    // MARK: - Controls

    func startOrResume() {
        if !isActive {
            remaining = workDuration
            phase = .work
            isActive = true
        }
        guard !isRunning else { return }
        isRunning = true
        sink = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func pause() {
        isRunning = false
        sink?.cancel(); sink = nil
    }

    func reset() {
        pause()
        isActive = false
        remaining = 0
        sessionCount = 0
        phase = .work
    }

    func skip() {
        guard isActive else { return }
        sink?.cancel(); sink = nil
        DispatchQueue.main.async { self.advance() }
    }

    // MARK: - Private

    private func tick() {
        remaining = max(0, remaining - 1)
        if remaining == 0 {
            sink?.cancel(); sink = nil
            DispatchQueue.main.async { self.advance() }
        }
    }

    private func advance() {
        switch phase {
        case .work:
            sessionCount += 1
            let long = sessionCount % 4 == 0
            phase = long ? .longBreak : .shortBreak
            remaining = phaseDuration(phase)
            notify(title: "Focus session done!",
                   body: long ? "Time for a long break — you've earned it." : "Nice work! Take a 5-min break.")
        case .shortBreak, .longBreak:
            phase = .work
            remaining = workDuration
            notify(title: "Break over!", body: "Time to focus again.")
        }
        isRunning = true
        sink = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func phaseDuration(_ p: FocusPhase) -> TimeInterval {
        switch p {
        case .work:       return workDuration
        case .shortBreak: return shortBreakDuration
        case .longBreak:  return longBreakDuration
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
