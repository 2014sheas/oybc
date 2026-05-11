import Foundation

/// Phase 6.3 — iOS mirror of TypeScript `AchievementSquareBadgeData`
/// (see `apps/web/src/components/InteractiveTaskSquare.tsx`).
///
/// Optional payload attached to an `InteractiveTaskSquareView` to label
/// a cell as an achievement square. The cell's actual completion state
/// still comes from `DerivationPass.computeBoardStatsUpdate`; this badge
/// just labels what the cell is watching (or counting) so the user can
/// see at a glance that the cell is cross-board-bound rather than
/// task-bound.
///
/// Computed at render time by `BoardPlayView` from the workspace's
/// boards + templates + this BoardTask's `referencedBoardId` /
/// `referencedTemplateId`. Orthogonal to `TaskType` — any task type
/// (normal / counting / compound) can be wrapped as an achievement
/// square; the badge renders on top of the cell's existing visuals.
struct AchievementSquareBadgeData: Equatable {
    enum Mode: Equatable {
        case aggregate
        case specificBoard
        case recurringTemplate
    }

    let mode: Mode

    // Aggregate mode (pre-6.3 counter-driven behavior)
    var achievementProgress: Int?
    var achievementCount: Int?

    // Specific-board mode. `referencedBoardName` is nil when the
    // referenced board was soft-deleted; the label falls back to
    // "(deleted)" so the user sees why the cell isn't completing.
    var referencedBoardName: String?
    var referencedBoardCompleted: Bool?

    // Recurring-template mode. Empty window ⇒ both counters are 0,
    // which renders as "0/0" with the standard caption — derivation
    // still treats this as incomplete (locked rule, see Phase 6.3 plan).
    var templateName: String?
    var templateInWindowGreenlogged: Int?
    var templateInWindowTotal: Int?

    /// Compact, mode-aware label for the cell badge. Mirrors the
    /// TS-side `formatAchievementBadgeLabel`. Falls back to "(deleted)"
    /// for missing names so the cell makes clear why it's stuck.
    var displayLabel: String {
        switch mode {
        case .aggregate:
            return "\(achievementProgress ?? 0)/\(achievementCount ?? 0)"
        case .specificBoard:
            let trimmed = (referencedBoardName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "(deleted)" : trimmed
            return (referencedBoardCompleted == true) ? "✓ \(name)" : name
        case .recurringTemplate:
            let trimmed = (templateName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "(deleted)" : trimmed
            let g = templateInWindowGreenlogged ?? 0
            let t = templateInWindowTotal ?? 0
            return "\(g)/\(t) \(name)"
        }
    }
}
