import Foundation

// MARK: - Counting task title generation
//
// Swift twin of `packages/shared/src/algorithms/taskTitle.ts`
// (`generateCounterTaskTitle`). CLAUDE.md calls this out as "the canonical
// way to build counting task titles — don't duplicate this logic on either
// platform." Any change here MUST be mirrored in the TS file (source of
// truth). Extracted from inline title-building in `CreateFormViewModel`
// (issue #246 part 2).
enum TaskTitle {

    /// Generates a display title for a COUNTING task.
    ///
    /// If a non-blank `providedTitle` is given, returns it trimmed.
    /// Otherwise, generates a title from `action`, `maxCount`, and `unit`.
    ///
    /// - Parameters:
    ///   - action: Action verb (e.g., "Read").
    ///   - maxCount: Target count (e.g., 100), or `nil` for a goal-less
    ///     hub-born counter (P5) — a running tally with no threshold.
    ///   - unit: Unit of measurement (e.g., "pages").
    ///   - providedTitle: Optional user-provided title.
    /// - Returns: The resolved task title string.
    static func generateCounterTaskTitle(
        action: String,
        maxCount: Int?,
        unit: String,
        providedTitle: String? = nil
    ) -> String {
        if let providedTitle {
            let trimmed = providedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        // P5 — hub-born counters are goal-less accumulators; title carries the
        // activity + unit ("Push-ups (reps)") so same-activity counters with
        // different units stay distinguishable.
        guard let maxCount else {
            return "\(trimmedAction) (\(trimmedUnit))"
        }
        return "\(trimmedAction) \(maxCount) \(trimmedUnit)"
    }
}
