import Foundation
import Combine

/// Main-thread store for live approval requests. SwiftUI binds to `queue` for display;
/// ApprovalServer calls `enqueue`/`resolve` via `DispatchQueue.main.async` so all
/// mutations happen on main. (Not declared `@MainActor` to keep the rest of the
/// codebase — notably `NotchHoverWindow`, which is a plain `NSObject` — free of
/// actor-isolation ceremony.)
final class PendingApprovals: ObservableObject {

    @Published private(set) var queue: [ApprovalRequest] = []

    /// The request currently shown in the overlay.
    var current: ApprovalRequest? { queue.first }

    /// Count of additional queued requests behind the current one.
    var overflow: Int { max(0, queue.count - 1) }

    init() {}

    /// Append a new request. Safe to call from any thread via `Task { @MainActor in … }`.
    func enqueue(_ req: ApprovalRequest) {
        queue.append(req)
    }

    /// Remove a request by id, calling its completion with `decision`.
    /// Any subsequent calls for the same id are no-ops (the request itself guards).
    func resolve(_ id: UUID, with decision: ApprovalDecision) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let req = queue.remove(at: idx)
        req.resolve(decision)
    }

    /// Deny everything in the queue (used on app quit / panic).
    func denyAll(reason: String) {
        for req in queue {
            req.resolve(.deny)
        }
        queue.removeAll()
    }
}
