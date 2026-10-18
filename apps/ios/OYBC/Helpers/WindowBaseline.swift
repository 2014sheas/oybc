import Foundation

// MARK: - Window baseline + legacy derived-row predicates
//
// Swift twin of the baseline half of `packages/shared/src/algorithms/memberRules.ts`.
// (The B2 row builder was retired in TASK_WINDOW_REWORK slice 3b.)

extension BoardSources {

    // MARK: - Baseline

    /// The window baseline of a shared-counter root: the lifetime count the
    /// root had reached when the window opened, so the derived counter's
    /// displayed value (`root.currentCount − baseline`) starts this window at
    /// zero.
    ///
    /// Ruling RB2 — the sum of the `delta`s of the root's LIVE increment
    /// events whose `occurredAt` is strictly BEFORE `boundary`, clamped at 0.
    /// Completion events, tombstoned events and other tasks' events are
    /// ignored, and an event exactly ON the boundary belongs to the new
    /// window, not to the baseline.
    ///
    /// Both sides are compared as INSTANTS (`DateFormatting.parseISO`), never
    /// as strings: board dates are local ISO (`2026-09-18T00:00:00`, no
    /// offset) while events carry a UTC stamp, so a lexical compare — or
    /// re-stamping a local date as UTC — would move the boundary by the local
    /// offset and admit or drop every event either side of local midnight.
    /// `parseISO` is the repo's existing parser and accepts all three shapes
    /// the two sides can take (fractional-second internet time, plain internet
    /// time, and the wizard's offset-less local ISO). A stamp that doesn't
    /// parse (on either side) skips the event rather than counting it.
    ///
    /// `boundary` is decided by the CALLER (the board's `startDate`, or the
    /// mint instant for an INDEFINITE / date-less board) — this helper never
    /// guesses it. It must be a FULL timestamp; a date-only string is not
    /// supported (`parseISO` has no date-only format and returns nil, and the
    /// TS twin's `Date.parse` would read it as UTC midnight — the two would
    /// disagree).
    ///
    /// - Parameters:
    ///   - rootTaskId: The shared-counter root whose events are summed.
    ///   - events: Candidate events; any task's, any kind, live or tombstoned.
    ///   - boundary: ISO8601 instant the window opens at.
    /// - Returns: The baseline count (≥ 0).
    static func computeWindowBaseline(
        rootTaskId: String,
        events: [TaskEvent],
        boundary: String
    ) -> CountValue {
        guard let boundaryDate = DateFormatting.parseISO(boundary) else { return 0 }
        var sum: CountValue = 0
        for event in events {
            guard !event.isDeleted,
                  event.taskId == rootTaskId,
                  event.kind == .increment,
                  // A malformed increment with no delta is SKIPPED, not
                  // treated as 0 — matching the TS twin's finite-number guard.
                  let delta = event.delta,
                  let occurred = DateFormatting.parseISO(event.occurredAt),
                  occurred < boundaryDate
            else { continue }
            sum += delta
        }
        return Swift.max(0, quantizeCount(sum))
    }

    /// Is this STORED task row one of our per-window derived counters?
    ///
    /// All three marks together — a shared-counter link, a window start, and
    /// the wizard-born provenance flag. Each alone is ordinary user data: a
    /// hand-made linked counter has the first, a timeboxed task the second, a
    /// wizard-born task the third. Only the three together identify a row this
    /// pipeline minted for one window (and may therefore refresh or retire
    /// when that window is re-derived).
    ///
    /// - Parameter task: The task row to test.
    /// - Returns: True when the row is a window-stamped derived counter.
    static func isWindowStampedDerived(_ task: Task) -> Bool {
        !(task.sharedCounterId ?? "").isEmpty
            && !(task.startDate ?? "").isEmpty
            && task.createdInWizard
    }

    /// Is this STORED row a window-stamped derived counter whose window has
    /// ENDED, so shared-counter propagation must skip it (the propagation
    /// freeze)? Twin of the TS `isFrozenDerivedRow`, pinned by the
    /// `frozenDerivedRow` section of `memberRuleVectors.json`.
    ///
    /// Increment / decrement / undo skip a frozen row's authored write and
    /// enqueue; completion reads the ROOT's in-window events, not the latch.
    /// Increment / decrement (event stamped `now`) skip its cascade too; undo
    /// cascades — never writes — the rows `isFrozenRowReachedByEvent` names
    /// (TaskEvents.swift). `refreshDerivedBaselines` is NOT gated by this.
    ///
    /// "Ended" uses the kernel's inclusive window convention
    /// (`DateFormatting.isWithinTimeframe`): frozen only once `now` is
    /// strictly after the `endDate` instant. Rows with no `endDate` and
    /// hub-linked rows (no `startDate`) are never frozen. An unparseable
    /// `endDate` or `now` is treated as not frozen.
    ///
    /// - Parameters:
    ///   - task: The linked task row to test.
    ///   - now: The current instant as an ISO8601 string (a parameter, never
    ///     read from the clock here, so the predicate stays pure).
    /// - Returns: True when propagation must skip the row.
    static func isFrozenDerivedRow(_ task: Task, now: String) -> Bool {
        guard isWindowStampedDerived(task),
              let endDate = task.endDate,
              let end = DateFormatting.parseISO(endDate),
              let nowDate = DateFormatting.parseISO(now) else { return false }
        return nowDate > end
    }
}
