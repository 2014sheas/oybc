import Foundation

/// Phase 6.3 — iOS mirror of TypeScript `AchievementSquareBadgeData`
/// (see `apps/web/src/components/InteractiveTaskSquare.tsx`).
///
/// Optional payload attached to a board-play cell (`RisoBoardPlayCell`) to
/// label a cell as an achievement square. The cell's actual completion state
/// still comes from `DerivationPass.computeBoardStatsUpdate`; this badge
/// just labels what the cell is watching so the user can see at a glance
/// that the cell is cross-board-bound rather than task-bound.
///
/// Computed at render time by `BoardPlayView` from the workspace's
/// boards + templates + the underlying `Task`'s reference fields
/// (`type == .achievement` carrying `referencedBoardId` XOR
/// `referencedTemplateId`). Only present when the backing Task is
/// ACHIEVEMENT-typed.
struct AchievementSquareBadgeData: Equatable {
    enum Mode: Equatable {
        case specificBoard
        case recurringTemplate
    }

    let mode: Mode

    // Specific-board mode. `referencedBoardName` is nil when the
    // referenced board was soft-deleted; the label falls back to
    // "(deleted)" so the user sees why the cell isn't completing.
    // `referencedBoardCompleted` indicates whether the referenced
    // board currently meets the Task's `achievementTrigger`.
    var referencedBoardName: String?
    var referencedBoardCompleted: Bool?

    // Recurring-template mode. `templateInWindowMet` is the number of
    // in-window spawns currently meeting the trigger;
    // `templateRequiredCount` is the user-set required N. Cell
    // completes when met >= required AND inWindow is non-empty.
    var templateName: String?
    var templateInWindowMet: Int?
    var templateRequiredCount: Int?

    /// Compact, mode-aware label for the cell badge. Mirrors the
    /// TS-side `formatAchievementBadgeLabel`. Falls back to "(deleted)"
    /// for missing names so the cell makes clear why it's stuck.
    var displayLabel: String {
        switch mode {
        case .specificBoard:
            let trimmed = (referencedBoardName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "(deleted)" : trimmed
            return (referencedBoardCompleted == true) ? "✓ \(name)" : name
        case .recurringTemplate:
            let trimmed = (templateName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "(deleted)" : trimmed
            let met = templateInWindowMet ?? 0
            let required = templateRequiredCount ?? 0
            return "\(met)/\(required) \(name)"
        }
    }
}
