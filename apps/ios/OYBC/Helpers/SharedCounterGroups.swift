import Foundation

// MARK: - Shared Counter Groups (P1 read model)
//
// Swift port of `packages/shared/src/algorithms/sharedCounterGroups.ts`.
// Groups the existing shared-counter task graph into "counter" view-models
// for the Counters Hub and Counter Detail screens.
//
// A "counter" = one SOURCE counting task (a task with ≥1 live task linking
// to it via `sharedCounterId`) + every task that links to it. The source
// task's `currentCount` is the lifetime total; each member's displayed value
// is derived via `deriveDisplayedCount` (SharedCounter.swift).
//
// Keep in sync with the TS source. The 11 test cases in
// `OYBCTests/SharedCounterGroupsTests.swift` mirror those in
// `packages/shared/tests/algorithms/sharedCounterGroups.test.ts`.

// MARK: - View-model types

/// One card of a shared counter — a PLACEMENT (slice 2b), resolved to its
/// host board's window + progress, ready for a Hub/Detail row. Mirrors the
/// TS `SharedCounterMemberTask`.
struct SharedCounterMemberTask: Identifiable {
    /// Stable id for SwiftUI identity: one placement can carry two linked
    /// children of the same compound, so the card is (placement, task).
    var id: String { boardTaskId + ":" + taskId }
    /// The placement this card stands for.
    let boardTaskId: String
    /// The member task on the card: the root, a linked task, or — when the
    /// placement is a parent compound — the linked CHILD reached through it.
    let taskId: String
    /// The card's title: the placement's `titleOverride`, else the root's
    /// templates at the placement's goal, else the task's title.
    let taskTitle: String
    /// True when the card's task is the root (the accumulator).
    let isSource: Bool
    /// The host board.
    let boardId: String
    let boardName: String
    /// The host board's timeframe (accent dot colour + window label).
    let timeframe: Timeframe?
    /// Human window label for the host board's window, e.g. "Week of Mar 23 – 29, 2026".
    let window: String?
    /// The placement's goal — `targetOverride` (in the task's kind), a parent
    /// compound placement's `childTargets` entry, else the task's own
    /// `maxCount` — 0 when unset.
    let goal: CountValue
    /// The in-window displayed amount (when the caller passes
    /// `eventsByTaskId`): the ROOT's increment sum over the host board's
    /// window for a linked card, the root's OWN events for a root card — each
    /// bounded at a sealed board's `sealedAt`, the play cell's numbers.
    /// Without events, the lifetime arithmetic (`lifetime − baseline`).
    let logged: CountValue
    /// `logged >= goal` (only when goal > 0). Over-achievement is real.
    let met: Bool
    /// `logged - goal` when over the goal, else 0 (for the "N over" caption).
    let over: CountValue
    /// True when this card is "counting now" — its board is still in play.
    let isActive: Bool
    /// The parent compound placed here, when the card's task is a linked
    /// child reached through it; `nil` for a direct placement.
    let viaCompoundId: String?
}

/// A shared counter grouped for the Counters Hub / Detail.
struct SharedCounterGroup: Identifiable {
    /// Stable id = the source task's id.
    var id: String { counterId }
    /// Stable id = the source task's id.
    let counterId: String
    /// Display name — pair-derived via `CounterName.formatCounterName(action,
    /// unit)`, falling back to the source task's stored title when the pair
    /// can't produce a name (R1 counters refresh).
    let name: String
    /// Action verb (e.g. "Do") from the source task.
    let action: String?
    /// Unit noun (e.g. "reps") from the source task.
    let unit: String?
    /// All-time running total = the source task's `currentCount`.
    let lifetime: CountValue
    /// R2 Counters UX refresh — the counter's default log amount: the
    /// source task's `defaultLogAmount`, or `nil` when never set (callers
    /// fall back to `1`). Persisted per-counter via
    /// `AppDatabase.setCounterDefaultLogAmount`, updated to the
    /// most-recently-used log amount each time the user logs with a
    /// different one. Defaulted here so every pre-existing call site
    /// (previews, tests) that doesn't specify it keeps compiling.
    var defaultLogAmount: CountValue? = nil
    /// One card per placement — root cards first, then by board name, task, placement.
    let tasks: [SharedCounterMemberTask]
    /// Distinct member tasks with a card.
    let taskCount: Int
    /// Distinct live boards the counter appears on.
    let boardCount: Int
    /// Member tasks that are counting now (active board).
    let activeTaskCount: Int
    /// The family's kind (the source's — D5). Declared last, defaulted, so
    /// existing memberwise call sites compile unchanged.
    var countKind: CountKind = .discrete
}

// MARK: - Member visibility (B3, RC9)

/// Which linked MEMBERS a group lists — the Counters hub's "Show expired
/// tasks" toggle. Swift twin of the TS `SharedCounterMemberVisibility`.
///
/// Per-window derived counters carry their board window's `endDate`, so a
/// counter that has ridden a few boards accumulates members that are over;
/// with `showExpired == false` those are dropped from the group by the
/// Tasks tab's own predicate (`TaskExpiry.isTaskExpired(member, now:)`).
///
/// `buildSharedCounterGroups` applies it AFTER root detection, never before:
/// a board-born counter is a root only because a live task links to it, so
/// filtering the task set up front used to un-root a counter the moment its
/// last member's window closed and delete the whole group from the hub and
/// the Profile home (the hub-root-hidden-when-members-expire bug). A ROOT is
/// never hidden, whatever its own `endDate` — it IS the counter. A root whose
/// members have all expired is listed as a single-member group (lifetime
/// total, nothing counting now).
struct SharedCounterMemberVisibility {
    /// `true` lists expired members too.
    let showExpired: Bool
    /// Reference time for `isTaskExpired` and for each member's "counting
    /// now" check; injected for deterministic tests.
    var now: Date = Date()
}

/// The member-row predicate `buildSharedCounterGroups` applies once the roots
/// are known. Roots never pass through this (the source row is always
/// listed). Mirror of the TS `isVisibleCounterMember`.
private func isVisibleCounterMember(
    _ member: Task,
    _ visibility: SharedCounterMemberVisibility?
) -> Bool {
    guard let visibility, !visibility.showExpired else { return true }
    return !TaskExpiry.isTaskExpired(member, now: visibility.now)
}

// MARK: - Builder

/// Pick a member task's "primary" board placement: prefer a board still in
/// play (`isBoardActiveForList` — never the stored status, which stays ACTIVE
/// on an ended or closed board), then newest startDate, then stable id
/// tie-break. Mirrors the TS `pickPrimaryBoard`.
///
/// - Parameter now: Reference time for the in-play check (defaults to the clock).
func pickPrimaryBoard(
    taskId: String,
    boardTasks: [BoardTask],
    boardsById: [String: Board],
    now: Date = Date()
) -> Board? {
    var candidates: [Board] = []
    for bt in boardTasks {
        guard bt.taskId == taskId, !bt.isDeleted,
              let board = boardsById[bt.boardId],
              !board.isDeleted
        else { continue }
        candidates.append(board)
    }
    guard !candidates.isEmpty else { return nil }
    candidates.sort { a, b in
        let aActive = isBoardActiveForList(a, now: now) ? 0 : 1
        let bActive = isBoardActiveForList(b, now: now) ? 0 : 1
        if aActive != bActive { return aActive < bActive }
        // Newest startDate first (string ISO8601 sort is lexicographic = chronological).
        if a.startDate != b.startDate { return a.startDate > b.startDate }
        return a.id < b.id
    }
    return candidates.first
}

/// The set of task ids that HEAD a shared-counter family.
///
/// A root is either (a) a live task pointed at by some live task's
/// `sharedCounterId` — window-stamped derived counters and P5 linked members
/// alike — or (b) a P5 hub-born counter (`counting` + `isCounter == true` +
/// no `sharedCounterId` of its own), which is a counter in its own right even
/// with zero members. This is exactly the root test
/// `buildSharedCounterGroups` runs, extracted so the library's row renderers
/// can ask "does this task head a family?" without rebuilding the whole
/// Counters-Hub view-model (owner ruling 2026-09-22: one generic family row in
/// the library, tapping through to the hub).
///
/// Soft-deleted tasks are ignored on BOTH sides: a deleted member does not
/// make its target a root, and a deleted `isCounter` row is not one either.
///
/// A link target counts only when it is actually PRESENT, live, and a COUNTING
/// task — the same predicate `buildSharedCounterGroups` applies when it skips
/// an orphaned group, so the two can never disagree. That matters twice over:
/// a dangling `sharedCounterId` (mid-sync, or a row an old client wrote) must
/// not conjure a family whose hub page would be empty, and it must not let
/// `BrowsableTasks.computeBrowsableTasks` hide a member the hub would never
/// show.
///
/// Mirror of the TS `sharedCounterGroups.ts` `sharedCounterRootIds`.
///
/// - Parameters:
///   - tasks: Candidate tasks (soft-deleted rows filtered internally).
///   - boardTasks: Placements (any state); a live one with a `targetOverride` roots its task (rule c).
/// - Returns: The root ids.
func sharedCounterRootIds(_ tasks: [Task], boardTasks: [BoardTask] = []) -> Set<String> {
    let live = tasks.filter { !$0.isDeleted }
    let liveById = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var roots = Set<String>()
    for task in live {
        guard let srcId = task.sharedCounterId else { continue }
        if let root = liveById[srcId], root.type == .counting { roots.insert(srcId) }
    }
    for task in live
    where task.type == .counting && task.isCounter == true && task.sharedCounterId == nil {
        roots.insert(task.id)
    }
    // (c) Slice 2b: a plain counter with a live placement carrying a
    // `targetOverride` heads a family — a per-board goal on one counter is
    // what a hub counter is. (Not "placed on more than one board": that would
    // make every recurring plain counter a hub counter.)
    for bt in boardTasks where !bt.isDeleted && bt.targetOverride != nil {
        if let t = liveById[bt.taskId], t.type == .counting, t.sharedCounterId == nil { roots.insert(t.id) }
    }
    return roots
}

/// Build the Counters-Hub / Counter-Detail view-models from the task graph.
///
/// Returns one `SharedCounterGroup` per source counting task that has at least
/// one live linked task, sorted by counter name (case-insensitive) for a
/// stable display order. Returns an empty array when the user has no shared
/// counters.
///
/// - Parameters:
///   - tasks: All (non-deleted-inclusive) tasks for the user. Internal
///            filtering removes soft-deleted rows.
///   - boardTasks: All board-task placement rows visible to the query.
///   - boards: All boards for the user (any status).
///   - compoundChildren: Compound links (any state). A linked task placed only
///     through a parent compound gets a card per placement of that compound
///     (slice 2b), at the placement's `childTargets` goal.
///   - eventsByTaskId: Optional non-deleted events grouped by `taskId` (at
///     least the roots'). When given, every PLACED member's `logged` is its
///     in-window count — a linked member via `resolveLinkedCounterDisplay`,
///     a placed source via `resolveTaskWindowState` over its board's window
///     — bounded at a sealed board's `sealedAt`: the play cell's and the
///     kernel's rule. `nil` keeps the lifetime derivation, byte-identical to before.
///     Mirrors the TS `BuildSharedCounterGroupsInput.eventsByTaskId`.
///   - memberVisibility: Optional — which linked members each group lists
///     (see `SharedCounterMemberVisibility`). Applied AFTER root detection,
///     which runs over EVERY live task; a root is never dropped. `nil` lists
///     every live member (the vector-pinned output).
/// - Returns: Sorted `[SharedCounterGroup]`, one per source counter.
func buildSharedCounterGroups(
    tasks: [Task],
    boardTasks: [BoardTask],
    boards: [Board],
    compoundChildren: [CompoundChild] = [],
    eventsByTaskId: [String: [TaskEvent]]? = nil,
    memberVisibility: SharedCounterMemberVisibility? = nil
) -> [SharedCounterGroup] {
    let liveTasks = tasks.filter { !$0.isDeleted }
    let tasksById = Dictionary(uniqueKeysWithValues: liveTasks.map { ($0.id, $0) })
    let boardsById = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
    let now = memberVisibility?.now ?? Date()
    let livePlacements = boardTasks.filter { !$0.isDeleted }
    // A card IS a placement: the ONE reach (slice 2c) — the root's own
    // placements, its linked rows' placements and the placements of their
    // transitive parent compounds — shared with the cascade and the sealed
    // re-derive, so the hub can never list a square the kernel doesn't reach.

    // Map source task id → its linked tasks. The key set is
    // `sharedCounterRootIds` — every task pointed at by a live
    // `sharedCounterId`, PLUS the P5 hub-born counters, PLUS a plain counter
    // placed with a `targetOverride` (slice 2b). Seeding an empty linked list
    // for a member-less root lets it flow through the same card pipeline. A
    // flagged row that is itself derived (`sharedCounterId` set) is malformed
    // — the create-input validators reject the combination, but synced rows
    // are unguarded — and the helper ignores it defensively.
    var linkedBySource: [String: [Task]] = [:]
    for rootId in sharedCounterRootIds(liveTasks, boardTasks: livePlacements) { linkedBySource[rootId] = [] }
    for t in liveTasks {
        guard let srcId = t.sharedCounterId else { continue }
        // A link whose target is missing / deleted / not a counter has no key
        // — the helper already applied this function's own orphan predicate,
        // so the optional chain drops exactly the members whose group the
        // loop below would skip.
        // Expired members are dropped HERE — after the root walk above, which
        // saw them — so a root keeps its group when every member is over.
        guard isVisibleCounterMember(t, memberVisibility) else { continue }
        linkedBySource[srcId]?.append(t)
    }

    var groups: [SharedCounterGroup] = []

    for (sourceId, linked) in linkedBySource {
        // Skip orphaned groups: source deleted / missing / not a counting task.
        guard let source = tasksById[sourceId], source.type == .counting else { continue }

        let lifetime = quantizeCount(source.currentCount ?? 0)
        // The root is the title-settings source for its linked cards (`BoardPlayViewModel.placedTask`).
        let settings = CounterSettings.TitleSettings(task: source)
        let linkedById = Dictionary(uniqueKeysWithValues: linked.map { ($0.id, $0) })
        var boardIdSet = Set<String>()
        var memberTaskIds = Set<String>()
        var activeTaskIds = Set<String>()
        /// `showExpired == false` also hides a card whose HOST window has ended or closed (a card is a placement).
        func isExpiredPlacement(_ board: Board) -> Bool {
            guard let memberVisibility, !memberVisibility.showExpired else { return false }
            if board.sealedAt != nil { return true }
            guard let end = board.endDate.flatMap({ DateFormatting.parseISO($0) }) else { return false }
            return end < now
        }

        /// One card: the placement `bt` on `board`, standing for `task` (already placement-adjusted).
        func card(_ bt: BoardTask, _ board: Board, _ task: Task, isSource: Bool, viaCompoundId: String?) -> SharedCounterMemberTask {
            let goal = task.maxCount ?? 0
            let hostWindow = LinkedCounterWindow(startDate: board.startDate, endDate: board.endDate)
            let displayed: CountValue
            if isSource, let eventsByTaskId {
                // A PLACED root (a board-born counter's own square) is an
                // event-owning counting row: it reads its OWN events over its
                // board's window, sealed-bounded — the play cell's rule —
                // never the lifetime total, which is the group's `lifetime`.
                let ownEvents = eventsByTaskId[task.id] ?? []
                // An absent / unparseable `sealedAt` applies no bound.
                let events: [TaskEvent] = board.sealedAt.flatMap { DateFormatting.parseISO($0) }.map { sealed in
                    boundWindowContextAtSeal(
                        eventsByTaskId: [task.id: ownEvents], sealedAtMs: sealed.timeIntervalSince1970 * 1000
                    ).eventsByTaskId[task.id] ?? []
                } ?? ownEvents
                displayed = resolveTaskWindowState(
                    task: task, events: events, windowStart: board.startDate, windowEnd: boardWindowEnd(board)
                ).count
            } else if !isSource, let eventsByTaskId {
                // Context window wins (slice 0): a placed linked task — stamped
                // or not, direct or through a parent compound — reads the host
                // board's window from the ROOT's events.
                displayed = resolveLinkedCounterDisplay(
                    task: task, eventsByTaskId: eventsByTaskId, sealedAt: board.sealedAt, window: hostWindow
                ).displayed
            } else {
                // No events supplied: the library's lifetime arithmetic (source baseline 0).
                displayed = deriveDisplayedCount(
                    derivedBaseline: isSource ? 0 : (task.baseline ?? 0),
                    derivedMaxCount: goal,
                    sourceCurrentCount: lifetime,
                    countKind: task.countKind
                ).displayed
            }
            boardIdSet.insert(board.id)
            memberTaskIds.insert(task.id)
            // "Counting now" is the Boards tab's in-play rule, not the stored
            // status — a board past its endDate (or closed) stays ACTIVE in the row.
            let isActive = isBoardActiveForList(board, now: now)
            if isActive { activeTaskIds.insert(task.id) }
            let window = parseISO8601Date(board.startDate).map { formatTimeframeLabel(timeframe: board.timeframe, startDate: $0) }
            let met = goal > 0 && displayed >= goal
            return SharedCounterMemberTask(
                boardTaskId: bt.id,
                taskId: task.id,
                taskTitle: task.title,
                isSource: isSource,
                boardId: board.id,
                boardName: board.displayName,
                timeframe: board.timeframe,
                window: window,
                goal: goal,
                logged: displayed,
                met: met,
                over: met ? quantizeCount(displayed - goal) : 0,
                isActive: isActive,
                viaCompoundId: viaCompoundId
            )
        }

        var memberViews: [SharedCounterMemberTask] = []
        let reached = DerivationPass.placementsReachedByRoot(
            rootId: sourceId, tasks: liveTasks, compoundChildren: compoundChildren, boardTasks: livePlacements
        ).placements
        for hit in reached {
            let bt = hit.boardTask
            guard let board = boardsById[bt.boardId], !board.isDeleted, !isExpiredPlacement(board) else { continue }
            if hit.memberTaskId == sourceId {
                if hit.viaCompoundId != nil { continue } // a root is never a compound child
                memberViews.append(card(bt, board, PlacementParams.apply(source, placement: bt, settings: settings), isSource: true, viaCompoundId: nil))
                continue
            }
            // The reach lists every live linked row; the hub shows the visible ones.
            guard let linkedTask = linkedById[hit.memberTaskId] else { continue }
            if let via = hit.viaCompoundId {
                // `childTargets` bind direct children only; a nested child keeps its own goal.
                memberViews.append(card(bt, board, PlacementParams.withChildTarget(linkedTask, childTargets: bt.childTargets), isSource: false, viaCompoundId: via))
            } else {
                memberViews.append(card(bt, board, PlacementParams.apply(linkedTask, placement: bt, settings: settings), isSource: false, viaCompoundId: nil))
            }
        }

        // Deterministic card order: root cards first, then by board name, task id, placement id.
        memberViews.sort { a, b in
            if a.isSource != b.isSource { return a.isSource }
            if a.boardName != b.boardName { return a.boardName < b.boardName }
            if a.taskId != b.taskId { return a.taskId < b.taskId }
            return a.boardTaskId < b.boardTaskId
        }

        groups.append(SharedCounterGroup(
            counterId: sourceId,
            // The root's counterName, else R1 pair-derived (CounterName.formatCounterName),
            // stored-title fallback when the (action, unit) pair can't
            // produce one (e.g. a legacy row with neither field set).
            name: CounterSettings.counterDisplayName(source),
            action: source.action,
            unit: source.unit,
            lifetime: lifetime,
            defaultLogAmount: source.defaultLogAmount,
            tasks: memberViews,
            taskCount: memberTaskIds.count,
            boardCount: boardIdSet.count,
            activeTaskCount: activeTaskIds.count,
            countKind: resolveCountKind(source.countKind)
        ))
    }

    // Sort by counter name, case-insensitive (mirrors TS localeCompare base).
    groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return groups
}
