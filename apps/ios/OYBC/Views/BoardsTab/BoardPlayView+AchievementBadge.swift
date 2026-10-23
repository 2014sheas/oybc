import SwiftUI

// Split out of `BoardPlayView.swift`, which is frozen at its file-size cap
// (`scripts/audit/file-size-allowlist.json`). Pure move, no behaviour change.
extension BoardPlayView {

    // MARK: - Phase 6.3: per-cell achievement-task badge data

    /// Compute the achievement-task badge for one BoardTask. nil if the
    /// backing Task is not ACHIEVEMENT-typed (or the kernel has no
    /// achievement metadata for it — e.g. no reference set). Mirrors the
    /// TS-side `achievementBadgesByBoardTaskId` memo in BoardPlayPage.tsx.
    ///
    /// Board-integrity PR-3 — the met/count/required numbers come straight
    /// from `kernelCellStates`; only the display NAME lookups (board /
    /// template name) stay local, since names aren't part of the kernel's
    /// completion-derivation domain.
    func achievementBadge(for bt: BoardTask) -> AchievementSquareBadgeData? {
        guard let task = taskMap[bt.taskId], task.type == .achievement else { return nil }
        guard let achievement = kernelCellStates[bt.id]?.achievement else { return nil }
        switch achievement.mode {
        case .specificBoard:
            let ref = achievement.referencedBoardId.flatMap { refId in
                allBoardsInWorkspace.first(where: { $0.id == refId && !$0.isDeleted })
            }
            return AchievementSquareBadgeData(
                mode: .specificBoard,
                referencedBoardName: ref?.name,
                referencedBoardCompleted: achievement.referencedBoardCompleted ?? false
            )
        case .recurringTemplate:
            let template = achievement.referencedTemplateId.flatMap { tid in
                allTemplatesInWorkspace.first(where: { $0.id == tid })
            }
            return AchievementSquareBadgeData(
                mode: .recurringTemplate,
                templateName: template?.name,
                templateInWindowMet: achievement.templateInWindowMet ?? 0,
                templateRequiredCount: achievement.templateRequiredCount ?? 0
            )
        }
    }
}
