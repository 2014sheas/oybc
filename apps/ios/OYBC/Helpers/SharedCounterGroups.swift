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

/// One member task of a shared counter, resolved to its board placement +
/// window + progress, ready for a Hub/Detail row.
struct SharedCounterMemberTask: Identifiable {
    /// Stable id for SwiftUI identity (equals taskId).
    var id: String { taskId }
    /// The member task's id.
    let taskId: String
    /// The member task's display title.
    let taskTitle: String
    /// True for the source task (the accumulator), false for a linked task.
    let isSource: Bool
    /// The board this task is primarily placed on (non-deleted), or nil when
    /// the task has no live board placement.
    let boardId: String?
    let boardName: String?
    /// The task's timeframe (for the accent dot color + window label).
    let timeframe: Timeframe?
    /// Human window label e.g. "This week" → "Week of Mar 23 – 29, 2026",
    /// "February 2026", "2026". Nil when no timeframe/date is known.
    let window: String?
    /// The task's personal target (`maxCount`), 0 when unset.
    let goal: Int
    /// The task's window-scoped displayed amount (derived from lifetime).
    let logged: Int
    /// `logged >= goal` (only when goal > 0). Over-achievement is real.
    let met: Bool
    /// `logged - goal` when over the goal, else 0 (for the "N over" caption).
    let over: Int
    /// True when this task is "counting now" — its board is ACTIVE.
    /// Draft / completed / archived / placeless tasks are inactive.
    let isActive: Bool
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
    let lifetime: Int
    /// R2 Counters UX refresh — the counter's default log amount: the
    /// source task's `defaultLogAmount`, or `nil` when never set (callers
    /// fall back to `1`). Persisted per-counter via
    /// `AppDatabase.setCounterDefaultLogAmount`, updated to the
    /// most-recently-used log amount each time the user logs with a
    /// different one. Defaulted here so every pre-existing call site
    /// (previews, tests) that doesn't specify it keeps compiling.
    var defaultLogAmount: Int? = nil
    /// Source task first, then linked tasks (deterministic order).
    let tasks: [SharedCounterMemberTask]
    /// Total member tasks (source + linked).
    let taskCount: Int
    /// Distinct live boards the counter appears on.
    let boardCount: Int
    /// Member tasks that are counting now (active board).
    let activeTaskCount: Int
}

// MARK: - Builder

/// Pick a member task's "primary" board placement: prefer ACTIVE board, then
/// newest startDate, then stable id tie-break. Mirrors the TS `pickPrimaryBoard`.
private func pickPrimaryBoard(
    taskId: String,
    boardTasks: [BoardTask],
    boardsById: [String: Board]
) -> Board? {
    var candidates: [Board] = []
    for bt in boardTasks {
        guard bt.taskId == taskId,
              let board = boardsById[bt.boardId],
              !board.isDeleted
        else { continue }
        candidates.append(board)
    }
    guard !candidates.isEmpty else { return nil }
    candidates.sort { a, b in
        let aActive = a.status == .active ? 0 : 1
        let bActive = b.status == .active ? 0 : 1
        if aActive != bActive { return aActive < bActive }
        // Newest startDate first (string ISO8601 sort is lexicographic = chronological).
        if a.startDate != b.startDate { return a.startDate > b.startDate }
        return a.id < b.id
    }
    return candidates.first
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
/// - Returns: Sorted `[SharedCounterGroup]`, one per source counter.
func buildSharedCounterGroups(
    tasks: [Task],
    boardTasks: [BoardTask],
    boards: [Board]
) -> [SharedCounterGroup] {
    let liveTasks = tasks.filter { !$0.isDeleted }
    let tasksById = Dictionary(uniqueKeysWithValues: liveTasks.map { ($0.id, $0) })
    let boardsById = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })

    // Map source task id → its linked (derived) tasks.
    var linkedBySource: [String: [Task]] = [:]
    for t in liveTasks {
        guard let srcId = t.sharedCounterId else { continue }
        linkedBySource[srcId, default: []].append(t)
    }

    // P5 — hub-born counters: a COUNTING task flagged `isCounter` is a
    // counter in its own right, even with zero linked tasks. Seed an empty
    // linked list for flagged sources the link walk didn't already
    // discover, so they flow through the same member-view pipeline as
    // single-member groups. A flagged row that is itself derived
    // (`sharedCounterId` set) is malformed — the create-input validators
    // reject the combination, but synced rows are unguarded — and is
    // ignored defensively here.
    for t in liveTasks {
        if t.type == .counting,
           t.isCounter == true,
           t.sharedCounterId == nil,
           linkedBySource[t.id] == nil {
            linkedBySource[t.id] = []
        }
    }

    var groups: [SharedCounterGroup] = []

    for (sourceId, linked) in linkedBySource {
        // Skip orphaned groups: source deleted / missing / not a counting task.
        guard let source = tasksById[sourceId],
              source.type == .counting
        else { continue }

        let lifetime = source.currentCount ?? 0
        let members: [Task] = [source] + linked

        var boardIdSet = Set<String>()
        var activeCount = 0

        var memberViews: [SharedCounterMemberTask] = members.map { m in
            let isSource = m.id == sourceId
            // Source has baseline 0 (accumulates the full count).
            let baseline = isSource ? 0 : (m.baseline ?? 0)
            let goal = m.maxCount ?? 0
            let result = deriveDisplayedCount(
                derivedBaseline: baseline,
                derivedMaxCount: goal,
                sourceCurrentCount: lifetime
            )
            let displayed = result.displayed

            let board = pickPrimaryBoard(
                taskId: m.id,
                boardTasks: boardTasks,
                boardsById: boardsById
            )
            if let b = board { boardIdSet.insert(b.id) }
            let isActive = board?.status == .active
            if isActive { activeCount += 1 }

            // Window from the task's own timeframe/startDate; falls back to its board's.
            let tf = m.timeframe ?? board?.timeframe
            let startStr = m.startDate ?? board?.startDate
            let window: String?
            if let tf, let startStr, let startDate = parseISO8601Date(startStr) {
                window = formatTimeframeLabel(timeframe: tf, startDate: startDate)
            } else {
                window = nil
            }

            let met = goal > 0 && displayed >= goal
            return SharedCounterMemberTask(
                taskId: m.id,
                taskTitle: m.title,
                isSource: isSource,
                boardId: board?.id,
                boardName: board?.name,
                timeframe: tf,
                window: window,
                goal: goal,
                logged: displayed,
                met: met,
                over: met ? displayed - goal : 0,
                isActive: isActive
            )
        }

        // Source first, then by board name, then stable id tie-break.
        memberViews.sort { a, b in
            if a.isSource != b.isSource { return a.isSource }
            let an = a.boardName ?? ""
            let bn = b.boardName ?? ""
            if an != bn { return an < bn }
            return a.taskId < b.taskId
        }

        groups.append(SharedCounterGroup(
            counterId: sourceId,
            // R1: pair-derived display name (CounterName.formatCounterName),
            // stored-title fallback when the (action, unit) pair can't
            // produce one (e.g. a legacy row with neither field set).
            name: {
                let derived = CounterName.formatCounterName(action: source.action, unit: source.unit)
                return derived.isEmpty ? source.title : derived
            }(),
            action: source.action,
            unit: source.unit,
            lifetime: lifetime,
            defaultLogAmount: source.defaultLogAmount,
            tasks: memberViews,
            taskCount: memberViews.count,
            boardCount: boardIdSet.count,
            activeTaskCount: activeCount
        ))
    }

    // Sort by counter name, case-insensitive (mirrors TS localeCompare base).
    groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return groups
}
