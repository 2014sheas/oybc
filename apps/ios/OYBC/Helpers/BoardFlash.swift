import Foundation

// MARK: - MomentTrigger

/// The payload that opens the Bingo / Greenlog moment overlay. Carried on
/// `BoardPlayFlashEvent.moment`, so the view routes on the payload — never on
/// the legacy message string.
struct MomentTrigger: Equatable {
    enum Kind: Equatable { case bingo, greenlog }
    let kind: Kind
    /// The line ids this write newly completed (empty for a greenlog that
    /// completed no new line, or when the cascade did not report them).
    let newLineIds: [String]
}

// MARK: - BoardFlashOutcome

/// What a board write's before/after transition means for the play surface:
/// the transient message (kept for the legacy `bingoMessage` readers) plus the
/// moment to open, if any. One ladder for every write path — priority is
/// reactivated > lost bingo > greenlog > new bingo, so a write that completes
/// the board AND closes lines is ONE greenlog trigger, and two lines closing
/// at once are ONE bingo trigger.
struct BoardFlashOutcome: Equatable {
    let message: String?
    let moment: MomentTrigger?

    static let none = BoardFlashOutcome(message: nil, moment: nil)

    /// Applies the ladder to explicit transition facts.
    ///
    /// - Parameters:
    ///   - wasReactivated: the board went COMPLETED → ACTIVE.
    ///   - lost: bingo line ids that dropped.
    ///   - gained: bingo line ids newly completed.
    ///   - didGreenlog: the board just auto-completed.
    static func resolve(
        wasReactivated: Bool, lost: [String], gained: [String], didGreenlog: Bool
    ) -> BoardFlashOutcome {
        let lost = lost.sorted(), gained = gained.sorted()
        if wasReactivated {
            return BoardFlashOutcome(message: "Board reactivated — no longer complete", moment: nil)
        }
        if !lost.isEmpty {
            return BoardFlashOutcome(message: "Bingo lost: \(lost.joined(separator: ", "))", moment: nil)
        }
        if didGreenlog {
            return BoardFlashOutcome(message: "GREENLOG!", moment: MomentTrigger(kind: .greenlog, newLineIds: gained))
        }
        if !gained.isEmpty {
            return BoardFlashOutcome(
                message: "Bingo! (\(gained.joined(separator: ", ")))",
                moment: MomentTrigger(kind: .bingo, newLineIds: gained)
            )
        }
        return .none
    }

    /// The ladder over a re-fetched `before` / `after` board pair. A decrement
    /// or undo passes `allowGains: false` — only the reactivated / lost rungs
    /// can fire on a reversal.
    static func resolve(before: Board?, after: Board?, allowGains: Bool = true) -> BoardFlashOutcome {
        guard let before, let after else { return .none }
        let prev = Set(before.completedLineIds ?? []), next = Set(after.completedLineIds ?? [])
        let isGreenlogNow = after.completedTasks >= after.boardSize * after.boardSize
        return resolve(
            wasReactivated: before.status == .completed && after.status == .active,
            lost: Array(prev.subtracting(next)),
            gained: allowGains ? Array(next.subtracting(prev)) : [],
            didGreenlog: allowGains && isGreenlogNow && after.status == .completed && before.status == .active
        )
    }
}

extension BoardFlashOutcome {
    /// The ladder over a local-interaction cascade's per-board result (nil —
    /// the board was not part of the cascade — resolves to no flash).
    static func resolve(cascade result: AppDatabase.CascadeBoardResult?) -> BoardFlashOutcome {
        guard let result else { return .none }
        return resolve(
            wasReactivated: result.wasReactivated,
            lost: Array(result.update.lostBingos),
            gained: Array(result.update.newBingos),
            didGreenlog: result.didAutoComplete
        )
    }
}
