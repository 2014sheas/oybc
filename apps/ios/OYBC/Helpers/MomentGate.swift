import Foundation

// MARK: - MomentGate

/// When the moment may open, and how competing triggers combine. Pure, so the
/// gate is unit-tested without a view.
///
/// A write's flash fires the instant its reload STARTS; the replay must read
/// the data that reload applies. So a trigger opens only once (a) the cell pop
/// has had its minimum, and (b) the post-write reload has applied — the VM's
/// `applyCount` moved past the trigger's and the loaded board shows the
/// outcome (greenlog: `.completed`; bingo: the new lines in
/// `completedLineIds`) — or the 1.5 s timeout expires (open anyway).
enum MomentGate {
    /// The cell pop finishes first (~340 ms + margin).
    static let minimumDelay: TimeInterval = 0.52
    /// After the minimum, wait up to this much MORE for readiness (web's gate:
    /// 0.52 s then up to 1.5 s, ≈2.02 s worst case), then open anyway.
    static let timeout: TimeInterval = 1.5

    /// Whether the loaded `board` reflects the trigger's outcome AND the
    /// reload that carries it has applied. A different board (a pager swipe)
    /// is never ready.
    static func isReady(
        _ trigger: MomentTrigger, boardId: String, board: Board?, applyCount: Int, applyCountAtTrigger: Int
    ) -> Bool {
        guard let board, board.id == boardId, applyCount > applyCountAtTrigger else { return false }
        switch trigger.kind {
        case .greenlog: return board.status == .completed
        case .bingo: return Set(trigger.newLineIds).isSubset(of: Set(board.completedLineIds ?? []))
        }
    }

    /// Open once the minimum has passed AND (ready OR the extra wait ran out).
    static func shouldOpen(elapsed: TimeInterval, ready: Bool) -> Bool {
        elapsed >= minimumDelay && (ready || elapsed >= minimumDelay + timeout)
    }

    /// Whether a poll chain (identified by its pending's `id`) is still the
    /// live one: a disappear cleared the pending, or a newer pending started.
    static func isLive(chain id: UUID, pending: MomentPending?) -> Bool { pending?.id == id }

    /// A trigger arriving while another is PENDING: a greenlog replaces
    /// whatever is pending (carrying the lines of both); a bingo never
    /// replaces anything.
    static func coalesce(pending: MomentTrigger, arriving: MomentTrigger) -> MomentTrigger {
        guard arriving.kind == .greenlog else { return pending }
        return MomentTrigger(kind: .greenlog, newLineIds: Array(Set(pending.newLineIds + arriving.newLineIds)).sorted())
    }

    /// A ready trigger takes the screen only when no moment is open — nothing
    /// interrupts an open moment.
    static func shouldOpen(whileOpen open: MomentTrigger.Kind?) -> Bool { open == nil }
}

// MARK: - MomentIntent

extension Notification.Name {
    /// Posted by the greenlog moment's "Start a new board"; `MainTabView`
    /// flips to the Create tab (web twin: navigate to `/create`). A
    /// notification, not a callback: `BoardPlayView` is embedded inside the
    /// core-window pager (and pushed standalone), so there is no callback
    /// path to the tab host.
    static let momentStartNewBoard = Notification.Name("oybc.moment.startNewBoard")
}

enum MomentIntent {
    /// The "Start a new board" intent — what the overlay's `onNewBoard` runs.
    static func startNewBoard() {
        NotificationCenter.default.post(name: .momentStartNewBoard, object: nil)
    }
}
