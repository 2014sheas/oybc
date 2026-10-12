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
    /// Open anyway after this long (web's gate).
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

    /// Open once the minimum has passed AND (ready OR timed out).
    static func shouldOpen(elapsed: TimeInterval, ready: Bool) -> Bool {
        elapsed >= minimumDelay && (ready || elapsed >= timeout)
    }

    /// Two triggers pending at once: greenlog wins; two bingos merge their lines.
    static func coalesce(_ a: MomentTrigger, _ b: MomentTrigger) -> MomentTrigger {
        let kind: MomentTrigger.Kind = (a.kind == .greenlog || b.kind == .greenlog) ? .greenlog : .bingo
        return MomentTrigger(kind: kind, newLineIds: Array(Set(a.newLineIds + b.newLineIds)).sorted())
    }

    /// Whether a ready trigger may take the screen: nothing open, or an open
    /// bingo upgraded by a greenlog. Never downgrades or restarts the same kind.
    static func shouldReplace(open: MomentTrigger.Kind?, new: MomentTrigger.Kind) -> Bool {
        guard let open else { return true }
        return open == .bingo && new == .greenlog
    }
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
