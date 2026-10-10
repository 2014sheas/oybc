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
        maxCount: CountValue?,
        unit: String,
        providedTitle: String? = nil,
        countKind: CountKind = .discrete
    ) -> String {
        if let providedTitle {
            let trimmed = providedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // One generator (docs/SHARED_COUNTER_SETTINGS.md §1b): no stored
        // templates here, so `renderCounterTitle` takes its default path — the
        // formula "{action} {goal} {unit}" (Duration "{action} {Xh Ym}", the
        // goal locale-independent: titles are STORED), and a goal-less hub-born
        // accumulator renders the pair-derived name (`CounterName.formatCounterName`:
        // "Do" + "push-ups" → "Push-ups", "Run" + "miles" → "Run miles").
        return CounterSettings.renderCounterTitle(
            CounterSettings.Fields(action: action, unit: unit, countKind: countKind), goal: maxCount
        )
    }
}

// MARK: - Custom vs auto titles (owner bug 2026-10-06)

extension TaskTitle {

    /// Whether a counting task's title is the AUTO one — i.e. not a name the
    /// user chose. Twin of the TS `isAutoCounterTitle`.
    ///
    /// A title is auto iff, after trimming, it is empty OR equal to the title
    /// ``generateCounterTaskTitle(action:maxCount:unit:providedTitle:)``
    /// builds from the task's OWN `action` / `maxCount` / `unit` (also
    /// trimmed). The compare is **case-sensitive** ("read 10 pages" is a
    /// custom name for a "Read" / 10 / "pages" counter) and
    /// **whitespace-insensitive at the ends only** — inner spacing must match
    /// exactly.
    ///
    /// - Parameters:
    ///   - title: The stored title.
    ///   - action: The task's own action verb (`""` when absent).
    ///   - maxCount: The task's own goal (`nil` for goal-less).
    ///   - unit: The task's own unit (`""` when absent).
    ///   - countKind: The task's kind.
    ///   - settings: The ROOT's name + templates (template-aware: a title equal
    ///     to `CounterSettings.renderCounterTitle` for this goal is also auto;
    ///     the legacy formula always still counts). A copy carries none of its own.
    /// - Returns: `true` when the title is empty or generated; `false` when custom.
    static func isAutoCounterTitle(
        title: String,
        action: String,
        maxCount: CountValue?,
        unit: String,
        countKind: CountKind = .discrete,
        settings: CounterSettings.TitleSettings? = nil
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let auto = generateCounterTaskTitle(action: action, maxCount: maxCount, unit: unit, countKind: countKind)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == auto { return true }
        guard let settings else { return false }
        return trimmed == renderedTitle(settings, action: action, unit: unit, countKind: countKind, goal: maxCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `CounterSettings.renderCounterTitle` for a row's own action / unit /
    /// kind under a root's name + templates.
    static func renderedTitle(
        _ settings: CounterSettings.TitleSettings, action: String, unit: String, countKind: CountKind, goal: CountValue?
    ) -> String {
        CounterSettings.renderCounterTitle(
            CounterSettings.Fields(
                action: action, unit: unit, countKind: countKind, counterName: settings.counterName,
                titleTemplateSingular: settings.titleTemplateSingular, titleTemplatePlural: settings.titleTemplatePlural
            ),
            goal: goal
        )
    }

    /// The title a per-board COPY of a counting member carries. Twin of the
    /// TS `counterCopyTitle`.
    ///
    /// A custom member title (``isAutoCounterTitle(title:action:maxCount:unit:)``
    /// is `false`) carries over VERBATIM (trimmed) — even when the copy's
    /// target differs, because the user chose that name. An auto (or empty)
    /// title is regenerated from the copy's `action` / NEW `maxCount` /
    /// `unit` — through the member's own templates when it is a root carrying
    /// them (absent = the formula, exactly as before the 2026-10-06 fix). Shared by
    /// `BoardSources.planDerivedTasks`'s mint and the linked-counter window
    /// heal's `windowStampedCopyDraft` so the two mint paths can never
    /// disagree.
    ///
    /// - Parameters:
    ///   - member: The member being copied (its own title / action / unit / goal).
    ///   - newMaxCount: The copy's target.
    /// - Returns: The copy's title.
    static func counterCopyTitle(member: Task, newMaxCount: CountValue) -> String {
        let action = member.action ?? ""
        let unit = member.unit ?? ""
        let countKind = resolveCountKind(member.countKind)
        let settings = CounterSettings.TitleSettings(task: member)
        if !isAutoCounterTitle(
            title: member.title, action: action, maxCount: member.maxCount, unit: unit, countKind: countKind,
            settings: settings
        ) {
            return member.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A root member's own templates render the copy (absent → the formula).
        return renderedTitle(settings, action: action, unit: unit, countKind: countKind, goal: newMaxCount)
    }
}
