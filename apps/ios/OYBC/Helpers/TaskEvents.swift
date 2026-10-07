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
    let count: CountValue
}

/// Context threaded through windowed compound evaluation (docs §Semantics —
/// "evaluateCompound gains a window-context parameter"). When present,
/// primitive children resolve against `windowStart` via
/// `resolveTaskWindowState`; window-stamped derived counters resolve from
/// their root's events (`resolveDerivedCounterWindowState`); any other linked
/// counting child resolves over the host window the same way (owner rule
/// 2026-10-01 — only a context with no `windowStart` still reads such a
/// child's latch); nested compounds inherit the SAME `windowStart` /
/// `windowEnd` (host-window inheritance). Mirrors the TS `CompoundWindowContext`.
struct CompoundWindowContext {
    /// Window lower bound (`board.startDate`), or `nil` for lifetime.
    let windowStart: String?
    /// Window INCLUSIVE upper bound (`board.endDate`, via `boardWindowEnd(_:)`),
    /// or `nil` for an open-ended window (indefinite boards, lifetime).
    /// 2026-09-24 amendment: a board's root squares evaluate `[startDate, endDate]`.
    let windowEnd: String?
    /// This workspace's non-deleted TaskEvents grouped by `taskId`.
    let eventsByTaskId: [String: [TaskEvent]]

    /// Memberwise init. `windowEnd` is REQUIRED (no default) so every
    /// construction site must decide its upper bound: a board passes
    /// `boardWindowEnd(board)`; only a genuinely open-ended context (an
    /// indefinite board, lifetime) passes `nil`. Mirrors the TS type, where
    /// `windowEnd: string | null` is required.
    ///
    /// - Parameters:
    ///   - windowStart: Window lower bound, or `nil` for lifetime.
    ///   - windowEnd: Window inclusive upper bound, or `nil` for none.
    ///   - eventsByTaskId: Non-deleted TaskEvents grouped by `taskId`.
    init(windowStart: String?, windowEnd: String?, eventsByTaskId: [String: [TaskEvent]]) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.eventsByTaskId = eventsByTaskId
    }
}

/// Context passed to `computeBoardStatsUpdate` / `computeSealedCompletedCells`
/// to switch them from lifetime (today's behavior) to windowed evaluation. The
/// board supplies its own `startDate` as the window lower bound — the caller
/// only provides the grouped events. Mirrors the TS `WindowEvaluationContext`.
struct WindowEvaluationContext {
    /// This workspace's non-deleted TaskEvents grouped by `taskId`.
    let eventsByTaskId: [String: [TaskEvent]]
}

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
/// Window semantics are `[windowStart, windowEnd]`, **inclusive at both ends**
/// (2026-09-24 amendment of WC Decision 1 — previously start-bound only, with
/// the upper bound left to sealing). `windowStart == nil` means no lower bound
/// (lifetime: library surfaces); `windowEnd == nil` (the default) means no
/// upper bound (indefinite boards, lifetime). A sealed board's snapshot is
/// narrowed further by `sealedAt` upstream (`boundWindowContextAtSeal`), so its
/// effective upper bound is `min(windowEnd, sealedAt)`.
/// Comparison is a parsed timestamp compare (`occurredAt >= windowStart`,
/// `occurredAt <= windowEnd`), never string equality — board dates are
/// LOCAL-ISO while event timestamps are UTC-`Z`. Mirrors the TS
/// `new Date(...).getTime()` compare: an unparseable bound or timestamp
/// resolves to "not in window", matching JS `NaN >= x === false`.
///
/// - Parameters:
///   - task: The event-owning task (normal or plain/source counting).
///   - events: This task's events (deleted rows ignored internally).
///   - windowStart: Window lower bound, or `nil` for lifetime.
///   - windowEnd: Window inclusive upper bound, or `nil` (default) for none.
/// - Returns: `{ isCompleted, count }`. For counting, `count` is the
///   low-clamped window sum (overshoot preserved — never high-clamped). For
///   normal, `count` is the number of in-window completion events.
func resolveTaskWindowState(
    task: Task,
    events: [TaskEvent],
    windowStart: String?,
    windowEnd: String? = nil
) -> TaskWindowState {
    let lowerDate: Date? = windowStart.flatMap { DateFormatting.parseISO($0) }
    let upperDate: Date? = windowEnd.flatMap { DateFormatting.parseISO($0) }

    func inWindow(_ e: TaskEvent) -> Bool {
        if e.isDeleted { return false }
        if windowStart == nil && windowEnd == nil { return true } // lifetime — every event counts
        guard let occurred = DateFormatting.parseISO(e.occurredAt) else { return false }
        if windowStart != nil {
            // windowStart provided but unparseable → nothing counts (mirrors NaN).
            guard let lower = lowerDate, occurred >= lower else { return false }
        }
        if windowEnd != nil {
            // windowEnd provided but unparseable → nothing counts (mirrors NaN).
            guard let upper = upperDate, occurred <= upper else { return false }
        }
        return true
    }

    if task.type == .counting {
        var sum: CountValue = 0
        for e in events where e.kind == .increment {
            guard inWindow(e) else { continue }
            sum += e.delta ?? 0
        }
        // Finalised by kind: low-clamped, quantized 2dp, whole kinds round the
        // SUM (D4). Overshoot preserved (never high-clamped).
        let count = finalizeWindowCount(sum, kind: resolveCountKind(task.countKind))
        let isCompleted = task.maxCount.map { count >= $0 } ?? false
        return TaskWindowState(isCompleted: isCompleted, count: count)
    }

    // NORMAL (and any defensive non-counting caller): complete iff a
    // non-deleted completion event falls in the window.
    var completions = 0
    for e in events where e.kind == .completion {
        guard inWindow(e) else { continue }
        completions += 1
    }
    return TaskWindowState(isCompleted: completions > 0, count: CountValue(completions))
}

// MARK: - Board window end + late-log stamp (2026-09-24 amendment)

/// The inclusive upper bound a board's LIVE windowed evaluation uses for its
/// root squares (and compound children, by host-window inheritance): the
/// board's own `endDate`, or `nil` for an indefinite board (2026-09-24
/// amendment of WC Decision 1 — `[startDate, endDate]`, not `[startDate, ∞)`).
/// Mirrors the TS `boardWindowEnd`.
///
/// - Parameter board: The board being evaluated (only `endDate` is read).
/// - Returns: `board.endDate`, or `nil` when the board has none.
func boardWindowEnd(_ board: Board) -> String? {
    board.endDate
}

/// The `occurredAt` to stamp on a log made from `board`'s OWN play surface at
/// `nowIso` (2026-09-24 amendment, decision C2 — "late logs"). Mirrors the TS
/// `lateLogOccurredAt`.
///
///   - Window still open (`now <= endDate`), or the board has no `endDate` →
///     `nowIso`, verbatim.
///   - Window ended (`now > endDate`) → the board's `endDate` instant
///     re-encoded as a UTC event timestamp (`DateFormatting.utcISOString`, the
///     JS `toISOString()` shape), so the overtime log still counts for this
///     board and for no later window.
///
/// The rule is plain `min(now, endDate)`, independent of `sealedAt`: a sealed
/// board never logs (play is locked), and if one ever did, clamping into its
/// own window is the safe direction.
///
/// Comparison is by parsed instant, never by string — board dates are
/// LOCAL-ISO, event timestamps are UTC ISO. An unparseable `endDate` or
/// `nowIso` fails open (returns `nowIso`).
///
/// - Parameters:
///   - board: The board the log is made from (only `endDate` is read).
///   - nowIso: The current instant as an ISO timestamp (the caller's clock).
/// - Returns: The ISO timestamp to store as the event's `occurredAt`.
func lateLogOccurredAt(board: Board, nowIso: String) -> String {
    guard let endDate = board.endDate else { return nowIso }
    guard let end = DateFormatting.parseISO(endDate),
          let now = DateFormatting.parseISO(nowIso) else { return nowIso }
    if now <= end { return nowIso }
    return DateFormatting.utcISOString(end)
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
/// Window membership follows `DateFormatting.isWithinTimeframe` — the same
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
    windowStampedDerivedState(
        startDate: task.startDate, endDate: task.endDate, maxCount: task.maxCount,
        countKind: task.countKind, rootEvents: rootEvents, sealedBound: nil
    )
}

/// A board's window as a linked counting square is evaluated against it:
/// `[startDate, endDate]`, inclusive both ends (`endDate == nil` = open-ended).
/// The shape a display / hub reader hands `resolveLinkedCounterDisplay` for a
/// row that is NOT window-stamped — the placing board's own window. Twin of
/// the TS `LinkedCounterWindow`.
struct LinkedCounterWindow: Equatable {
    let startDate: String
    let endDate: String?
}

/// Shared body of `resolveWindowStampedDerivedState` and the sealed display
/// path. The window bounds (and `sealedBound`) are parsed ONCE per call and
/// each event's `occurredAt` once, then compared as `Date`s — a wizard row's
/// local-ISO bounds cost a `DateFormatter` allocation per `parseISO`, so
/// re-parsing them per event (via `isWithinTimeframe`) was thousands of
/// allocations per body pass on the main thread.
///
/// Edge semantics are exactly `DateFormatting.isWithinTimeframe`'s: an
/// unparseable `startDate` → count 0; an `endDate` present but unparseable →
/// count 0; `endDate == nil` → unbounded above; inclusive both ends; an
/// unparseable `occurredAt` is out. `sealedBound` additionally drops events
/// with `occurredAt > sealedBound` (the `boundWindowContextAtSeal` rule).
///
/// - Parameters:
///   - startDate: The window's inclusive lower bound (a row's own stamp, or
///     the placing board's `startDate`).
///   - endDate: The window's inclusive upper bound, or `nil` for open-ended.
///   - maxCount: The per-window target (`task.maxCount`).
///   - rootEvents: The ROOT task's events.
///   - sealedBound: The parsed `sealedAt` of the row's board, or `nil`.
/// - Returns: `{ isCompleted, count }` with `count` the clamped in-window sum.
private func windowStampedDerivedState(
    startDate: String?,
    endDate: String?,
    maxCount: CountValue?,
    countKind: CountKind?,
    rootEvents: [TaskEvent],
    sealedBound: Date?
) -> TaskWindowState {
    /// Clamped-below in-window sum; 0 when the bounds don't parse.
    func windowSum() -> CountValue {
        guard let startDate, !startDate.isEmpty,
              let lower = DateFormatting.parseISO(startDate) else { return 0 }
        var upper: Date?
        if let endDate {
            // Present but unparseable → nothing is in-window.
            guard let parsed = DateFormatting.parseISO(endDate) else { return 0 }
            upper = parsed
        }
        var sum: CountValue = 0
        for e in rootEvents where !e.isDeleted && e.kind == .increment {
            guard let occurred = DateFormatting.parseISO(e.occurredAt),
                  occurred >= lower else { continue }
            if let upper, occurred > upper { continue }
            if let sealedBound, occurred > sealedBound { continue }
            sum += e.delta ?? 0
        }
        return sum
    }
    let count = finalizeWindowCount(windowSum(), kind: resolveCountKind(countKind))
    return TaskWindowState(isCompleted: count >= (maxCount ?? 0), count: count)
}

/// Kernel dispatch for the derived-counter branch: a `.counting` row with a
/// `sharedCounterId` resolves from its ROOT's increment events over the window
/// that applies to it; anything else returns `nil` so the caller falls through
/// (event-owning → `resolveTaskWindowState`).
///
/// Which window (owner rule 2026-10-01 — a counting square on a board accounts
/// ONLY for the counter's logs inside that board's window):
///   - Window-stamped (`BoardSources.isWindowStampedDerived`) → the row's OWN
///     stamped `[startDate, endDate]`, as before.
///   - Any other linked row (hub-linked, or windowed but not wizard-born) WITH
///     a context window (`windowStart != nil`) → the CONTEXT window
///     `[windowStart, windowEnd]` — the placing board's. The lifetime-latch
///     carve-out these rows used to take on a board is retired.
///   - No context window (a lifetime / library reader) → `nil`: the caller
///     keeps its latch read for that context-less case only.
///
/// A root with no entry in `eventsByTaskId` resolves as zero events — never as
/// a latch fallback. Every production context builder loads the workspace's
/// non-deleted events keyed by `taskId`, and the sealed context drops only keys
/// whose events were all bounded away (its bound is already applied).
///
/// Mirrors the TS `resolveDerivedCounterWindowState`.
///
/// - Parameters:
///   - task: The task being resolved.
///   - eventsByTaskId: The window context's grouped events.
///   - windowStart: The evaluating board's window start, or `nil` (context-less).
///   - windowEnd: Its inclusive upper bound, or `nil` for open-ended.
/// - Returns: The derived window state, or `nil` when `task` is not a linked
///   counter, or is a non-window-stamped one with no context window.
func resolveDerivedCounterWindowState(
    task: Task,
    eventsByTaskId: [String: [TaskEvent]],
    windowStart: String? = nil,
    windowEnd: String? = nil
) -> TaskWindowState? {
    guard task.type == .counting, let rootId = task.sharedCounterId else { return nil }
    let rootEvents = eventsByTaskId[rootId] ?? []
    if BoardSources.isWindowStampedDerived(task) {
        return resolveWindowStampedDerivedState(task: task, rootEvents: rootEvents)
    }
    // Owner rule 2026-10-01: a linked row that is NOT window-stamped resolves
    // over the CONTEXT window — the placing board's — never its lifetime latch.
    guard let windowStart else { return nil }
    return windowStampedDerivedState(
        startDate: windowStart, endDate: windowEnd, maxCount: task.maxCount,
        countKind: task.countKind, rootEvents: rootEvents, sealedBound: nil
    )
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
/// - Any other linked row (hub-linked, or windowed but not wizard-born) with
///   an event map AND a `window` — the placing board's `[startDate, endDate]`
///   (owner rule 2026-10-01): the ROOT's increment sum inside THAT window,
///   bounded at `sealedAt` the same way. The kernel resolves the cell over the
///   same context window (`resolveDerivedCounterWindowState`), so display and
///   stats agree here too. The row's own `startDate` (if any) is NOT read.
/// - No event map, or a non-window-stamped row with no `window` (library /
///   lifetime readers): `currentCount − baseline` (low-clamped) for the count
///   and the propagation-stamped latch `task.isCompleted` for completion — the
///   only place the latch is still read for a linked row.
///
/// Mirrors the TS `resolveLinkedCounterDisplay`; pinned by
/// `taskWindowStateVectors.json#linkedCounterDisplay`.
///
/// - Parameters:
///   - task: The linked counting task being rendered.
///   - eventsByTaskId: Non-deleted events grouped by `taskId`, or `nil`.
///   - sealedAt: The row's board `sealedAt`, when that board is sealed.
///   - window: The placing board's window, for a row that is not
///     window-stamped; ignored for a window-stamped row.
/// - Returns: The displayed count and completion.
func resolveLinkedCounterDisplay(
    task: Task,
    eventsByTaskId: [String: [TaskEvent]]?,
    sealedAt: String? = nil,
    window: LinkedCounterWindow? = nil
) -> DeriveDisplayedCountResult {
    if let eventsByTaskId, task.type == .counting, let rootId = task.sharedCounterId,
       BoardSources.isWindowStampedDerived(task) || window != nil {
        let stamped = BoardSources.isWindowStampedDerived(task)
        // An unparseable `sealedAt` applies no bound (parsed once, not per event).
        let sealedBound = sealedAt.flatMap { DateFormatting.parseISO($0) }
        let state = windowStampedDerivedState(
            startDate: stamped ? task.startDate : window?.startDate,
            endDate: stamped ? task.endDate : window?.endDate,
            maxCount: task.maxCount,
            countKind: task.countKind,
            rootEvents: eventsByTaskId[rootId] ?? [],
            sealedBound: sealedBound
        )
        return DeriveDisplayedCountResult(displayed: state.count, isCompleted: state.isCompleted)
    }
    let shown = deriveDisplayedCount(
        derivedBaseline: task.baseline ?? 0,
        derivedMaxCount: task.maxCount ?? 0,
        sourceCurrentCount: task.currentCount ?? 0,
        countKind: task.countKind
    )
    return DeriveDisplayedCountResult(displayed: shown.displayed, isCompleted: task.isCompleted)
}

/// Cascade reachability for linked (derived) counters: `ids` UNION the ids
/// of every LIVE row whose `sharedCounterId` is in `ids` — window-stamped AND
/// hub-linked alike (owner rule 2026-10-01; before it, only
/// `BoardSources.isWindowStampedDerived` rows were added). A root is never
/// placed, but every linked row resolves FROM its events on a board (its own
/// window, or the placing board's), so a changed root must reach the boards
/// placing any of them — in the LIVE cascade, the SEALED re-derivation and
/// the increment cascade alike. Non-root ids pass through. (The name predates
/// the widening and is kept for its call sites.)
///
/// Mirrors the TS `expandToWindowStampedDerived`.
///
/// - Parameters:
///   - ids: The task ids whose events changed.
///   - tasks: Candidate rows (any superset of the linked rows).
/// - Returns: `ids` plus the reachable linked row ids.
func expandToWindowStampedDerived<S: Sequence>(ids: Set<String>, tasks: S) -> Set<String> where S.Element == Task {
    var out = ids
    guard !ids.isEmpty else { return out }
    for t in tasks where !t.isDeleted {
        guard let root = t.sharedCounterId, !root.isEmpty, ids.contains(root) else { continue }
        out.insert(t.id)
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
    /// Inclusive upper bound as epoch ms: `min(endDate, sealedAt)` — the same
    /// bound that built the sealed record (Decision 1 end bound + Decision 9).
    /// An absent/unparseable `endDate` is open-ended, so the bound is `sealedAt`.
    let endMs: Double
    /// The sealed board's `sealedAt` as epoch ms (Board Edit redesign slice 4,
    /// D10): a board-authored event CREATED after this instant is a late log
    /// made on the closed board, and stays undoable (`isEventSealImmune`).
    let sealedAtMs: Double
}

/// Build the immune windows for a task from the sealed boards that place it
/// (docs Decision 9 + §Write paths). The caller resolves *which* non-deleted
/// sealed boards place the task (directly or via a placed compound — the same
/// reachability the pull-path re-derivation uses) and passes their
/// `startDate`/`endDate`/`sealedAt`; this turns them into epoch-ms bounds.
///
/// The immune window is `[startDate, min(endDate, sealedAt)]` — exactly the
/// set of events the sealed record counted. An event in the overtime gap
/// `(endDate, sealedAt]` belongs to the NEXT window's board, never counted on
/// the sealed board, and so stays tombstonable there.
///
/// Mirrors the TS `buildSealImmuneWindows`.
///
/// - Parameter sealedBoards: Sealed boards placing the task (each with a set
///   `sealedAt`; `endDate` nil/unparseable = open-ended).
/// - Returns: One immune window per sealed board. Unparseable start/sealedAt
///   map to `NaN` (matching the TS `new Date(...).getTime()` → `NaN` degrade,
///   which fails every comparison — a defensive no-op, not a live window).
func buildSealImmuneWindows(
    sealedBoards: [(startDate: String, endDate: String?, sealedAt: String)]
) -> [SealImmuneWindow] {
    sealedBoards.map { b in
        let startMs = DateFormatting.parseISO(b.startDate).map { $0.timeIntervalSince1970 * 1000 } ?? Double.nan
        let sealedAtMs = DateFormatting.parseISO(b.sealedAt).map { $0.timeIntervalSince1970 * 1000 } ?? Double.nan
        let endDateMs = b.endDate.flatMap(DateFormatting.parseISO).map { $0.timeIntervalSince1970 * 1000 }
        let endMs = endDateMs.map { min($0, sealedAtMs) } ?? sealedAtMs
        return SealImmuneWindow(
            startMs: startMs,
            endMs: sealedAtMs.isNaN ? Double.nan : endMs,
            sealedAtMs: sealedAtMs
        )
    }
}

/// Whether an EVENT is sealed-window immune (docs Decision 9 as amended by the
/// Board Edit redesign slice 4, D10 / owner ruling R2). Immune iff some sealed
/// board S placing its task has `occurredAt ∈ [S.startDate, min(S.endDate,
/// S.sealedAt)]` AND the event is NOT a late log made on a closed board —
/// NOT (`boardId != nil` AND `createdAt > S.sealedAt`). The `boardId` conjunct
/// keeps heal-on-pull / backfill mints (no `boardId`) immune; a late log
/// re-freezes once any containing board seals after it was created. Mirrors
/// the TS `isEventSealImmune`.
///
/// - Parameters:
///   - occurredAt: The event's semantic timestamp (ISO8601).
///   - createdAt: The event's write time (ISO8601).
///   - boardId: The event's board provenance, if any.
///   - windows: The task's immune windows (from `buildSealImmuneWindows`).
/// - Returns: `true` iff the event can never be tombstoned.
func isEventSealImmune(
    occurredAt: String,
    createdAt: String,
    boardId: String?,
    windows: [SealImmuneWindow]
) -> Bool {
    guard !windows.isEmpty else { return false }
    guard let occurred = DateFormatting.parseISO(occurredAt) else { return false }
    let t = occurred.timeIntervalSince1970 * 1000
    // An unparseable createdAt compares false against every seal (TS NaN degrade).
    let createdMs = DateFormatting.parseISO(createdAt).map { $0.timeIntervalSince1970 * 1000 } ?? Double.nan
    let boardAuthored = boardId != nil
    return windows.contains { w in
        w.startMs <= t && t <= w.endMs && !(boardAuthored && createdMs > w.sealedAtMs)
    }
}

/// Convenience overload of `isEventSealImmune` for a `TaskEvent` row.
func isEventSealImmune(_ event: TaskEvent, windows: [SealImmuneWindow]) -> Bool {
    isEventSealImmune(
        occurredAt: event.occurredAt,
        createdAt: event.createdAt,
        boardId: event.boardId,
        windows: windows
    )
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
