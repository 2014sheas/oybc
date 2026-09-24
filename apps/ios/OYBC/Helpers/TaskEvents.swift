import Foundation

// MARK: - Task Events (Swift port of taskEvents.ts + migrationHelpers.ts backfill)
//
// Swift port of `packages/shared/src/algorithms/taskEvents.ts` (windowed
// evaluation + backstop) plus the two TaskEvent backfill helpers from
// `packages/shared/src/algorithms/migrationHelpers.ts`. The TS files are the
// source of truth; any change to the math there MUST be mirrored here.
//
// These are the shared kernel that PR B (write paths / grids / derivation) and
// PR C (sealing) build on. Pure — no I/O, no side effects. The 3 PR-A vector
// fixtures in `OYBCTests/Fixtures/` (taskWindowStateVectors / backfillEvent
// Vectors / sealReDerivationVectors) run through both this port and the TS
// twin, which is what proves the hand-mirrored implementations agree.

// MARK: - Window evaluation types

/// The result of resolving a task's state within a window: whether the square
/// is complete, and the windowed count (0 for normal tasks). Mirrors the TS
/// `TaskWindowState` interface.
struct TaskWindowState: Equatable {
    let isCompleted: Bool
    let count: Int
}

/// Context threaded through windowed compound evaluation (docs §Semantics —
/// "evaluateCompound gains a window-context parameter"). When present,
/// primitive children resolve against `windowStart` via
/// `resolveTaskWindowState`; window-stamped derived counters resolve from
/// their root's events (`resolveDerivedCounterWindowState`); hub-linked
/// derived-counting children fall back to their lifetime cache (the carve-out); nested compounds inherit the SAME
/// `windowStart` (host-window inheritance). Mirrors the TS `CompoundWindowContext`.
struct CompoundWindowContext {
    /// Window lower bound (`board.startDate`), or `nil` for lifetime.
    let windowStart: String?
    /// This workspace's non-deleted TaskEvents grouped by `taskId`.
    let eventsByTaskId: [String: [TaskEvent]]
}

/// Context passed to `computeBoardStatsUpdate` / `computeSealedCompletedCells`
/// to switch them from lifetime (today's behavior) to windowed evaluation. The
/// board supplies its own `startDate` as the window lower bound — the caller
/// only provides the grouped events. Mirrors the TS `WindowEvaluationContext`.
struct WindowEvaluationContext {
    /// This workspace's non-deleted TaskEvents grouped by `taskId`.
    let eventsByTaskId: [String: [TaskEvent]]
}

// MARK: - Constants

/// 48h cap on the auto-seal backstop, in milliseconds (docs §Sealing → backstop
/// table). Mirrors the TS `BACKSTOP_MAX_MS`.
let BACKSTOP_MAX_MS: Double = 48 * 60 * 60 * 1000

// MARK: - Predicates

/// Whether a Task **owns its completion state** as events (docs §New entity +
/// §Derived-task carve-out). Only event-owning tasks may have `TaskEvent` rows;
/// the write choke points call this before appending an event, and backfill
/// skips non-owning tasks.
///
///   - `.normal` → owns events.
///   - `.counting` with no `sharedCounterId` (plain / source) → owns events.
///   - `.counting` with `sharedCounterId` (derived) → does NOT (source-driven).
///   - `.compound` / `.achievement` → do NOT (derived from children / board state).
///
/// - Parameter task: The task to classify.
/// - Returns: `true` iff the task owns its state via events.
func isEventOwningTask(_ task: Task) -> Bool {
    if task.type == .normal { return true }
    if task.type == .counting { return task.sharedCounterId == nil }
    return false
}

// MARK: - Windowed resolution

/// Resolve an event-owning task's state within a window (docs §Semantics).
///
/// Callers MUST branch derived / compound / achievement tasks BEFORE calling —
/// this function only handles `.normal` and plain / source `.counting`. Events
/// are filtered to non-deleted defensively (a tombstoned event never counts),
/// so a tombstoned vector resolves the same whether or not the caller
/// pre-filtered.
///
/// Window semantics have a **start bound only** (`[windowStart, ∞)`); the upper
/// bound is enforced by sealing, not filtering. `windowStart == nil` means
/// lifetime (library surfaces, indefinite semantics) — every event counts.
/// Comparison is a parsed timestamp compare (`occurredAt >= windowStart`),
/// never string equality, to stay robust to local-ISO vs UTC-`Z` encodings —
/// mirrors the TS `new Date(...).getTime()` compare (an unparseable timestamp
/// resolves to "not in window", matching JS `NaN >= x === false`).
///
/// - Parameters:
///   - task: The event-owning task (normal or plain/source counting).
///   - events: This task's events (deleted rows ignored internally).
///   - windowStart: Window lower bound, or `nil` for lifetime.
/// - Returns: `{ isCompleted, count }`. For counting, `count` is the
///   low-clamped window sum (overshoot preserved — never high-clamped). For
///   normal, `count` is the number of in-window completion events.
func resolveTaskWindowState(
    task: Task,
    events: [TaskEvent],
    windowStart: String?
) -> TaskWindowState {
    let hasWindow = windowStart != nil
    let lowerDate: Date? = windowStart.flatMap { DateFormatting.parseISO($0) }

    func inWindow(_ e: TaskEvent) -> Bool {
        if e.isDeleted { return false }
        if !hasWindow { return true } // lifetime — every event counts
        // windowStart provided but unparseable → nothing counts (mirrors NaN).
        guard let lower = lowerDate else { return false }
        guard let occurred = DateFormatting.parseISO(e.occurredAt) else { return false }
        return occurred >= lower
    }

    if task.type == .counting {
        var sum = 0
        for e in events where e.kind == .increment {
            guard inWindow(e) else { continue }
            sum += e.delta ?? 0
        }
        // Low-end clamp only — overshoot invariant preserved (never high-clamped).
        let count = max(0, sum)
        let isCompleted = task.maxCount != nil && count >= task.maxCount!
        return TaskWindowState(isCompleted: isCompleted, count: count)
    }

    // NORMAL (and any defensive non-counting caller): complete iff a
    // non-deleted completion event falls in the window.
    var completions = 0
    for e in events where e.kind == .completion {
        guard inWindow(e) else { continue }
        completions += 1
    }
    return TaskWindowState(isCompleted: completions > 0, count: completions)
}

// MARK: - Window-stamped derived counters (amended carve-out, 2026-09-23)

/// Resolve a **window-stamped derived counter**'s state from its ROOT's events
/// (docs/WINDOWED_COMPLETION.md §Derived-task carve-out, amended 2026-09-23;
/// docs/BOARD_SOURCES.md §Plan B2 notes → "Window-stamped derived counters").
///
/// The row owns no events, but carries its own window (`startDate` /
/// `endDate`, stamped from the board it was minted for) and per-window target
/// (`maxCount`), so its completion is a pure function of the root's converged
/// increment events inside that window — never the one-way propagation latch,
/// which a LATER window's increments can set (audit 2026-09-23 finding #1).
///
/// Window membership uses `DateFormatting.isWithinTimeframe` — the same
/// `[startDate, endDate]` convention (inclusive both ends, parsed compare,
/// `nil` `endDate` = unbounded) the kernel uses for board windows. Signed
/// deltas are summed as-is, then low-clamped at 0; completion is
/// `count >= (maxCount ?? 0)` (the `deriveDisplayedCount` convention).
/// Overshoot is valid. `baseline` is NOT read.
///
/// Mirrors the TS `resolveWindowStampedDerivedState`.
///
/// - Parameters:
///   - task: The window-stamped derived counter (its window + target).
///   - rootEvents: The ROOT task's events; deleted rows and completion events
///     are ignored internally.
/// - Returns: `{ isCompleted, count }` with `count` the clamped in-window sum.
func resolveWindowStampedDerivedState(task: Task, rootEvents: [TaskEvent]) -> TaskWindowState {
    var sum = 0
    if let startDate = task.startDate, !startDate.isEmpty {
        for e in rootEvents where !e.isDeleted && e.kind == .increment {
            guard DateFormatting.isWithinTimeframe(
                e.occurredAt, startDate: startDate, endDate: task.endDate
            ) else { continue }
            sum += e.delta ?? 0
        }
    }
    let count = max(0, sum)
    return TaskWindowState(isCompleted: count >= (task.maxCount ?? 0), count: count)
}

/// Kernel dispatch for the window-stamped derived-counter branch: a `.counting`
/// row that `BoardSources.isWindowStampedDerived` identifies resolves from its
/// root's events via `resolveWindowStampedDerivedState`; anything else returns
/// `nil` so the caller falls through (event-owning → `resolveTaskWindowState`;
/// hub-linked derived with no `startDate` → the lifetime latch, unchanged).
///
/// A root with no entry in `eventsByTaskId` resolves as zero events — never as
/// a latch fallback. Every production context builder loads the workspace's
/// non-deleted events keyed by `taskId`, and the sealed context drops only keys
/// whose events were all bounded away. The only latch fallback is a
/// context-less (lifetime) resolution, handled by callers before this branch.
///
/// Mirrors the TS `resolveDerivedCounterWindowState`.
func resolveDerivedCounterWindowState(
    task: Task,
    eventsByTaskId: [String: [TaskEvent]]
) -> TaskWindowState? {
    guard task.type == .counting, BoardSources.isWindowStampedDerived(task),
          let rootId = task.sharedCounterId else { return nil }
    return resolveWindowStampedDerivedState(task: task, rootEvents: eventsByTaskId[rootId] ?? [])
}

/// What a LINKED (derived) counting square or row SHOWS: its displayed count
/// and its completion — the events-based variant of `deriveDisplayedCount`
/// (docs/WINDOWED_COMPLETION.md §Derived-task carve-out, amended 2026-09-23).
///
/// - Window-stamped (`BoardSources.isWindowStampedDerived`, `.counting`) with
///   an event map: the ROOT's increment sum inside the row's own
///   `[startDate, endDate]` via `resolveWindowStampedDerivedState` — the SAME
///   function the kernel resolves the cell with, so a cell can never paint
///   green (or read N/N) while board stats count it incomplete. With
///   `sealedAt` (the row's board is sealed) root events after it are dropped
///   first, matching `boundWindowContextAtSeal`; an unparseable `sealedAt`
///   applies no bound. Overshoot is shown, never high-clamped.
/// - Hub-linked (no `startDate`) or no event map: `currentCount − baseline`
///   (low-clamped) for the count and the propagation-stamped latch
///   `task.isCompleted` for completion — the kernel's own carve-out.
///
/// Mirrors the TS `resolveLinkedCounterDisplay`; pinned by
/// `taskWindowStateVectors.json#linkedCounterDisplay`.
///
/// - Parameters:
///   - task: The linked counting task being rendered.
///   - eventsByTaskId: Non-deleted events grouped by `taskId`, or `nil`.
///   - sealedAt: The row's board `sealedAt`, when that board is sealed.
/// - Returns: The displayed count and completion.
func resolveLinkedCounterDisplay(
    task: Task,
    eventsByTaskId: [String: [TaskEvent]]?,
    sealedAt: String? = nil
) -> DeriveDisplayedCountResult {
    if let eventsByTaskId, task.type == .counting, BoardSources.isWindowStampedDerived(task),
       let rootId = task.sharedCounterId {
        var rootEvents = eventsByTaskId[rootId] ?? []
        if let sealedAt, let sealedDate = DateFormatting.parseISO(sealedAt) {
            rootEvents = rootEvents.filter {
                guard let occurred = DateFormatting.parseISO($0.occurredAt) else { return false }
                return occurred <= sealedDate
            }
        }
        let state = resolveWindowStampedDerivedState(task: task, rootEvents: rootEvents)
        return DeriveDisplayedCountResult(displayed: state.count, isCompleted: state.isCompleted)
    }
    let shown = deriveDisplayedCount(
        derivedBaseline: task.baseline ?? 0,
        derivedMaxCount: task.maxCount ?? 0,
        sourceCurrentCount: task.currentCount ?? 0
    )
    return DeriveDisplayedCountResult(displayed: shown.displayed, isCompleted: task.isCompleted)
}

/// Cascade reachability for window-stamped derived counters: `ids` UNION the
/// ids of every live window-stamped derived row
/// (`BoardSources.isWindowStampedDerived`) whose `sharedCounterId` is in `ids`.
/// A root is never placed, but its window-stamped rows resolve FROM its
/// events, so a changed root must reach the boards placing them — in the LIVE
/// pull cascade and the SEALED re-derivation alike. Hub-linked rows are not
/// added (they resolve from their latch). Non-root ids pass through.
///
/// Mirrors the TS `expandToWindowStampedDerived`.
///
/// - Parameters:
///   - ids: The task ids whose events changed.
///   - tasks: Candidate rows (any superset of the linked rows).
/// - Returns: `ids` plus the reachable window-stamped derived row ids.
func expandToWindowStampedDerived<S: Sequence>(ids: Set<String>, tasks: S) -> Set<String> where S.Element == Task {
    var out = ids
    guard !ids.isEmpty else { return out }
    for t in tasks where !t.isDeleted {
        guard let root = t.sharedCounterId, ids.contains(root) else { continue }
        if BoardSources.isWindowStampedDerived(t) { out.insert(t.id) }
    }
    return out
}

/// Bound a window context's events at a sealed board's `sealedAt` (docs §Seal
/// snapshots re-derive from the event union): keep only events with
/// `occurredAt <= sealedAtMs`, dropping a task's key when none survive. Applied
/// to EVERY task's events — including a shared-counter ROOT's, which a
/// window-stamped derived cell reads — so a post-seal increment never leaks
/// into a frozen record. An unparseable `occurredAt` is dropped (mirrors JS
/// `NaN <= x === false`).
///
/// Mirrors the TS `boundWindowContextAtSeal`; both platforms' sealing data
/// layers and the seal vectors run it.
func boundWindowContextAtSeal(
    eventsByTaskId: [String: [TaskEvent]],
    sealedAtMs: Double
) -> WindowEvaluationContext {
    var bounded: [String: [TaskEvent]] = [:]
    for (taskId, evs) in eventsByTaskId {
        let kept = evs.filter {
            guard let occurred = DateFormatting.parseISO($0.occurredAt) else { return false }
            return occurred.timeIntervalSince1970 * 1000 <= sealedAtMs
        }
        if !kept.isEmpty { bounded[taskId] = kept }
    }
    return WindowEvaluationContext(eventsByTaskId: bounded)
}

// MARK: - Sealed-window tombstone immunity (Decision 9)

/// A sealed board's frozen window as epoch-ms bounds (docs §Write paths →
/// "Sealed-window immunity"). An event is immune to tombstoning iff its
/// `occurredAt` falls inside one of these windows. Mirrors the TS
/// `SealImmuneWindow` interface.
struct SealImmuneWindow: Equatable {
    /// Sealed board's `startDate` as epoch ms (inclusive lower bound).
    let startMs: Double
    /// Sealed board's `sealedAt` as epoch ms (inclusive upper bound).
    let sealedAtMs: Double
}

/// Build the immune windows for a task from the sealed boards that place it
/// (docs Decision 9 + §Write paths). The caller resolves *which* non-deleted
/// sealed boards place the task (directly or via a placed compound — the same
/// reachability the pull-path re-derivation uses) and passes their
/// `startDate`/`sealedAt`; this turns them into epoch-ms bounds.
///
/// Mirrors the TS `buildSealImmuneWindows`.
///
/// - Parameter sealedBoards: Sealed boards placing the task (each with a set `sealedAt`).
/// - Returns: One immune window per sealed board. Unparseable dates map to
///   `0` (matching the TS `new Date(...).getTime()` → `NaN` degrade, which
///   fails every comparison — a defensive no-op, not a live window).
func buildSealImmuneWindows(
    sealedBoards: [(startDate: String, sealedAt: String)]
) -> [SealImmuneWindow] {
    sealedBoards.map { b in
        let startMs = DateFormatting.parseISO(b.startDate).map { $0.timeIntervalSince1970 * 1000 } ?? Double.nan
        let sealedAtMs = DateFormatting.parseISO(b.sealedAt).map { $0.timeIntervalSince1970 * 1000 } ?? Double.nan
        return SealImmuneWindow(startMs: startMs, sealedAtMs: sealedAtMs)
    }
}

/// Whether an event's `occurredAt` is sealed-window immune (docs Decision 9):
/// it falls inside `[startDate, sealedAt]` of some sealed board that places the
/// task. Immune events can never be tombstoned by any un-complete/decrement
/// gesture — history stays history. Bounds are inclusive on both ends (the
/// boundary instants belong to the frozen record). Mirrors the TS
/// `isOccurredAtSealImmune`.
///
/// - Parameters:
///   - occurredAt: The event's semantic timestamp (ISO8601).
///   - windows: The task's immune windows (from `buildSealImmuneWindows`).
/// - Returns: `true` iff the event is immune to tombstoning.
func isOccurredAtSealImmune(_ occurredAt: String, windows: [SealImmuneWindow]) -> Bool {
    guard !windows.isEmpty else { return false }
    guard let occurred = DateFormatting.parseISO(occurredAt) else { return false }
    let t = occurred.timeIntervalSince1970 * 1000
    return windows.contains { $0.startMs <= t && t <= $0.sealedAtMs }
}

// MARK: - Backstop formula

/// The auto-seal backstop **duration** for a board's window (docs §Sealing):
/// `min(48h, windowLength/4)`. Timeframe-scaling falls out of the window length
/// itself — daily → 6h, weekly → 42h, monthly/yearly/custom≥8d → 48h — so one
/// formula owns every timeframe. Mirrors the TS `backstopWindowMs`.
///
/// - Parameters:
///   - startDate: Board window start (ISO8601).
///   - endDate: Board window end (ISO8601).
/// - Returns: Backstop duration in ms, capped at 48h and floored at 0. Returns
///   0 if either bound is unparseable (defensive; valid data never hits this).
func backstopWindowMs(startDate: String, endDate: String) -> Double {
    guard
        let s = DateFormatting.parseISO(startDate),
        let e = DateFormatting.parseISO(endDate)
    else { return 0 }
    let lengthMs = (e.timeIntervalSince1970 - s.timeIntervalSince1970) * 1000
    return min(BACKSTOP_MAX_MS, max(0, lengthMs) / 4)
}

/// The absolute auto-seal deadline for a board, as epoch ms (docs §Sealing →
/// "deadline keys off `max(endDate, activatedAt)`"). Returning ms — rather than
/// an ISO string — sidesteps the local-ISO vs UTC encoding decision; callers
/// compare `nowMs > deadline`. Mirrors the TS `computeBackstopDeadlineMs`.
///
/// A draft activated AFTER its window already expired keys off `activatedAt`,
/// so it still gets one full prompt cycle instead of an instant silent seal.
/// Indefinite boards (no `endDate`) never seal → `nil`.
///
/// - Parameters:
///   - startDate: Board window start (ISO8601).
///   - endDate: Board window end (ISO8601), or nil for indefinite.
///   - activatedAt: When the board was activated (ISO8601), if known.
/// - Returns: Epoch-ms deadline, or `nil` when the board never seals.
func computeBackstopDeadlineMs(
    startDate: String,
    endDate: String?,
    activatedAt: String? = nil
) -> Double? {
    guard let endDate else { return nil }
    guard let endDate_ = DateFormatting.parseISO(endDate) else { return nil }
    let endMs = endDate_.timeIntervalSince1970 * 1000
    let activatedMs = activatedAt.flatMap { DateFormatting.parseISO($0) }
        .map { $0.timeIntervalSince1970 * 1000 } ?? endMs
    let anchor = max(endMs, activatedMs)
    return anchor + backstopWindowMs(startDate: startDate, endDate: endDate)
}

// MARK: - Backfill helpers (Swift port of migrationHelpers.ts §TaskEvent backfill)
//
// Both platforms call these from their one-transaction migration so the event
// ids + timestamps agree regardless of which device migrates first. The
// determinism is what makes the union-dedupe converge: same task snapshot →
// same kind-qualified id.

/// The deterministic, kind-qualified id for a task's backfill event
/// (docs §Migration & backfill): `uuidv5(taskId + "|backfill|" + kind, NS)`.
///
/// Kind-qualified so a task whose type was edited between two devices'
/// migrations can't collide a `completion` row against an `increment` row.
///
/// - Parameters:
///   - taskId: The owning task's id.
///   - kind: `.completion` (normal) or `.increment` (counting).
/// - Returns: A deterministic v5 UUID.
func backfillTaskEventId(taskId: String, kind: TaskEventKind) -> String {
    UUIDv5.uuidv5(name: "\(taskId)|backfill|\(kind.rawValue)")
}

/// Build the single backfill `TaskEvent` for one non-deleted, event-owning
/// task, or `nil` when the task has nothing to backfill / doesn't own events.
///
/// Rules (docs §Migration & backfill step 2):
///   - Derived / compound / achievement tasks are skipped (carve-out) → `nil`.
///   - `.normal && isCompleted` → one `.completion` event,
///     `occurredAt = completedAt ?? updatedAt` (best-effort anchor, docs
///     §Heal-on-pull — never dropped for a missing completedAt).
///   - `.counting && currentCount > 0` (plain/source only) → one `.increment`
///     event, `delta = currentCount`, `occurredAt = completedAt ?? updatedAt`.
///   - Otherwise (`.normal` never completed, counting at 0, etc.) → `nil`.
///
/// Timestamps come from the **task snapshot, not migration wall-clock**
/// (`createdAt`/`updatedAt = task.updatedAt`): two devices with divergent
/// pre-migration caches mint same-id rows whose LWW tie-break (equal
/// `version`, compare timestamps) selects the one derived from the fresher
/// task state.
///
/// The returned event carries no `boardId` (backfill has no board provenance)
/// and no `lastSyncedAt`; the caller enqueues it for sync CREATE.
///
/// - Parameter task: The task snapshot to derive an event from.
/// - Returns: A TaskEvent, or `nil` if nothing to backfill.
func buildBackfillTaskEvent(task: Task) -> TaskEvent? {
    if task.isDeleted { return nil }
    if !isEventOwningTask(task) { return nil }

    if task.type == .normal {
        guard task.isCompleted else { return nil }
        // Best-effort anchor (heal-on-pull, docs §Heal-on-pull): a completed
        // task must never be lost for lack of a completedAt — fall back to
        // updatedAt (always present) so a legacy isCompleted-without-completedAt
        // row still mints an event instead of being dropped.
        let occurredAt = task.completedAt ?? task.updatedAt
        return TaskEvent(
            id: backfillTaskEventId(taskId: task.id, kind: .completion),
            userId: task.userId,
            taskId: task.id,
            kind: .completion,
            delta: nil,
            occurredAt: occurredAt,
            boardId: nil,
            createdAt: task.updatedAt,
            updatedAt: task.updatedAt,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    // COUNTING (plain / source — isEventOwningTask already excluded derived).
    let count = task.currentCount ?? 0
    if count <= 0 { return nil }
    return TaskEvent(
        id: backfillTaskEventId(taskId: task.id, kind: .increment),
        userId: task.userId,
        taskId: task.id,
        kind: .increment,
        delta: count,
        occurredAt: task.completedAt ?? task.updatedAt,
        boardId: nil,
        createdAt: task.updatedAt,
        updatedAt: task.updatedAt,
        lastSyncedAt: nil,
        version: 1,
        isDeleted: false,
        deletedAt: nil
    )
}

// MARK: - Undo across the window end (derived-counter freeze)

extension BoardSources {
    /// Undo across the window end: is `task` a FROZEN window-stamped derived
    /// row (`isFrozenDerivedRow(_:now:)`) whose own `[startDate, endDate]`
    /// contains `occurredAt` — the instant of the event an undo just
    /// tombstoned? The kernel counts that event toward the row, so the undo
    /// can flip its completion: its boards must be re-derived (cascade only —
    /// the freeze still forbids an authored write / enqueue). Window
    /// membership is the kernel's own `DateFormatting.isWithinTimeframe`.
    ///
    /// Mirrors the TS `isFrozenRowReachedByEvent`; pinned by
    /// `memberRuleVectors.json#frozenRowReachedByEvent`.
    ///
    /// - Parameters:
    ///   - task: The linked task row to test.
    ///   - occurredAt: The undone event's `occurredAt`.
    ///   - now: The undo's timestamp (the freeze clock).
    /// - Returns: True when the undo must cascade (never write) this row.
    static func isFrozenRowReachedByEvent(_ task: Task, occurredAt: String, now: String) -> Bool {
        guard isFrozenDerivedRow(task, now: now), let startDate = task.startDate else { return false }
        return DateFormatting.isWithinTimeframe(occurredAt, startDate: startDate, endDate: task.endDate)
    }
}
