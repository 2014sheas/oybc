import Foundation

// MARK: - Windowed linked counters — heal planner + placement gate
//
// Swift twin of `packages/shared/src/algorithms/linkedCounterWindowHeal.ts`
// (owner rule 2026-10-01: a counting square on a board accounts ONLY for the
// counter's logs inside that board's window). The *hub-linked* kind of linked
// counter — `sharedCounterId` set, no window stamp — is retired for anything
// placed on a board: every linked placement is a per-board window-stamped
// row. This file is the pure planning half of that migration; the data layer
// (`AppDatabase+LinkedCounterWindowHeal`) applies the plan as AUTHORED writes
// with deterministic content so every device converges on the same rows.
//
// Pinned by `linkedCounterWindowHealVectors.json`
// (`LinkedCounterWindowHealVectorTests`). A change here is a change in two
// places.

extension BoardSources {
    /// Do two stored `startDate`s name the same window opening?
    ///
    /// `Board.startDate` has TWO live encodings — the offset-less local ISO
    /// the wizard writes (`2026-09-18T00:00:00`) and the full UTC form a sync
    /// round-trip can hand back — and a derived row copies whichever one its
    /// board carried at mint time. Those never compare equal as strings, so a
    /// plain `==` would answer "not mine" for a re-encoded pull. Comparing
    /// INSTANTS is what makes the two encodings agree; a stamp that doesn't
    /// parse on either side falls back to string equality rather than
    /// claiming a match. Two absent values are equal; an absent and a present
    /// one are not. (Moved here from `AppDatabase+DerivedCounters` so the
    /// placement gate and `isMintedForBoard` share one definition.)
    ///
    /// - Parameters:
    ///   - a: One stored start date (a derived row's).
    ///   - b: The other (its candidate board's).
    /// - Returns: True when both name the same instant (or the same literal).
    static func sameWindowStart(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == b }
        guard let da = DateFormatting.parseISO(a), let db = DateFormatting.parseISO(b) else {
            return a == b
        }
        return da == db
    }

    /// Is `task` a window-stamped derived counter stamped for THIS board's
    /// window — i.e. the row a placement on `board` may point at as-is?
    ///
    /// The placement choke points' gate: placing a task with a
    /// `sharedCounterId` that is NOT window-stamped for the target board (not
    /// window-stamped at all, or stamped for a different window) must resolve
    /// to that board's own per-window row (`derivedTaskId(board.id, root)`)
    /// instead. Only the window START is compared (``sameWindowStart(_:_:)``).
    ///
    /// Mirrors the TS `isWindowStampedForBoard`.
    ///
    /// - Parameters:
    ///   - task: The row about to be placed.
    ///   - board: The board it is being placed on.
    /// - Returns: True when the row is this board's own window-stamped artifact.
    static func isWindowStampedForBoard(_ task: Task, board: Board) -> Bool {
        isWindowStampedDerived(task) && sameWindowStart(task.startDate, board.startDate)
    }

    /// Stamp an existing hub-linked row IN PLACE with its first board's
    /// window. Applying it sets `timeframe` / `startDate` / `endDate` AND
    /// `createdInWizard = true`, so the row becomes `isWindowStampedDerived`
    /// and is never a candidate again (the plan's idempotency rests on that
    /// flag). Twin of the TS `LinkedCounterWindowStamp`.
    struct LinkedCounterWindowStamp: Equatable {
        let taskId: String
        /// The board whose window is stamped (for the caller's cascade).
        let boardId: String
        let timeframe: Timeframe
        let startDate: String
        let endDate: String?
    }

    /// Mint a fresh per-board copy for a direct placement that cannot keep
    /// its row — a FURTHER placement of a hub-linked row being stamped
    /// elsewhere, or a window-stamped row placed on a board it is not
    /// stamped for — and repoint that placement at it. `id` is
    /// `derivedTaskId(boardId, rootTaskId)` — the same id the wizard / spawn
    /// would mint for this window, so a later re-plan or a concurrent device
    /// converges on one row. Twin of the TS `LinkedCounterWindowCopy`.
    struct LinkedCounterWindowCopy: Equatable {
        /// `derivedTaskId(boardId, rootTaskId)`.
        let id: String
        let boardId: String
        /// The `board_tasks` row to repoint from `sourceTaskId` to `id`.
        let boardTaskId: String
        /// The linked row this copy stands in for on `boardId`.
        let sourceTaskId: String
        /// The shared-counter root (`sourceTask.sharedCounterId`).
        let rootTaskId: String
        let timeframe: Timeframe
        let startDate: String
        let endDate: String?
    }

    /// Output of ``planLinkedCounterWindowHeal(tasks:boardTasks:boards:compoundChildren:)``.
    struct LinkedCounterWindowHealPlan: Equatable {
        let stamps: [LinkedCounterWindowStamp]
        let copies: [LinkedCounterWindowCopy]
    }

    /// Total order on boards: window start ascending (as INSTANTS, so the two
    /// `startDate` encodings sort together), then id. When either start
    /// doesn't parse the pair falls back to string order; equal starts
    /// tie-break on id. Twin of the TS `compareBoardWindows`.
    private static func boardWindowPrecedes(_ a: Board, _ b: Board) -> Bool {
        if let da = DateFormatting.parseISO(a.startDate), let db = DateFormatting.parseISO(b.startDate) {
            if da != db { return da < db }
        } else if a.startDate != b.startDate {
            return a.startDate < b.startDate
        }
        return a.id < b.id
    }

    /// Plan the one-time heal of linked counters into per-board
    /// window-stamped rows. Two kinds of row are planned:
    ///
    /// 1. **Unstamped candidates** (COUNTING, `sharedCounterId` set, not
    ///    `isWindowStampedDerived`): all-or-nothing. The row is stamped with
    ///    its FIRST placing board's window (direct or reached through a
    ///    compound alike; boards ordered by startDate as instants, then id)
    ///    ONLY IF every further placing board is a DIRECT placement AND —
    ///    when there is more than one board — the row has a goal; every
    ///    further board then gets a copy (`derivedTaskId(board, root)`,
    ///    placement repointed). Otherwise (a further board reached only
    ///    through a compound, or goal-less on >1 board) the plan holds
    ///    NOTHING for the row: once stamped it would resolve from its own
    ///    window everywhere and freeze the skipped boards out of
    ///    propagation, whereas unstamped the kernel's context-window
    ///    fallback renders every board correctly. Single-board candidates
    ///    are stamped regardless of goal. Unplaced rows → nothing.
    /// 2. **Mis-placed window-stamped rows** (`isWindowStampedDerived`, with
    ///    a goal): a copy for every live DIRECT placement on a board the row
    ///    is not `isWindowStampedForBoard` — no stamp, the row keeps its own
    ///    window. A placement whose board's deterministic id is the row's
    ///    own id is left alone (that row IS the board's artifact with stale
    ///    dates — the Board Edit date path's job; a copy would repoint the
    ///    placement at itself forever).
    ///
    /// Deterministic and idempotent; output sorted by task id then board id.
    /// Mirrors the TS twin `planLinkedCounterWindowHeal` in
    /// `linkedCounterWindowHeal.ts` exactly, pinned by the shared vectors.
    ///
    /// - Parameters:
    ///   - tasks: Every task row (deleted rows are skipped here).
    ///   - boardTasks: Every placement row (tombstones are skipped here).
    ///   - boards: Every board row (deleted boards are skipped here).
    ///   - compoundChildren: Every link row (tombstones are skipped here).
    /// - Returns: The stamps and copies to apply, sorted by task id then board id.
    static func planLinkedCounterWindowHeal(
        tasks: [Task],
        boardTasks: [BoardTask],
        boards: [Board],
        compoundChildren: [CompoundChild]
    ) -> LinkedCounterWindowHealPlan {
        var boardsById: [String: Board] = [:]
        for board in boards where !board.isDeleted { boardsById[board.id] = board }
        var tasksById: [String: Task] = [:]
        for task in tasks where !task.isDeleted { tasksById[task.id] = task }

        // taskId → boardId → the live placement row id (smallest id if a
        // malformed workspace holds two live rows for one task on one board).
        var placementsByTaskId: [String: [String: String]] = [:]
        for bt in boardTasks where !bt.isDeleted && boardsById[bt.boardId] != nil {
            var byBoard = placementsByTaskId[bt.taskId] ?? [:]
            if let existing = byBoard[bt.boardId], existing <= bt.id { continue }
            byBoard[bt.boardId] = bt.id
            placementsByTaskId[bt.taskId] = byBoard
        }

        // childId → its live, non-deleted COMPOUND parents.
        var parentsByChildId: [String: Set<String>] = [:]
        for link in compoundChildren where !link.isDeleted {
            guard let parent = tasksById[link.compoundTaskId], parent.type == .compound else { continue }
            parentsByChildId[link.childTaskId, default: []].insert(link.compoundTaskId)
        }

        var stamps: [LinkedCounterWindowStamp] = []
        var copies: [LinkedCounterWindowCopy] = []

        func copy(for task: Task, root: String, board: Board, boardTaskId: String) -> LinkedCounterWindowCopy {
            LinkedCounterWindowCopy(
                id: derivedTaskId(boardId: board.id, rootTaskId: root),
                boardId: board.id,
                boardTaskId: boardTaskId,
                sourceTaskId: task.id,
                rootTaskId: root,
                timeframe: board.timeframe,
                startDate: board.startDate,
                endDate: board.endDate
            )
        }

        for task in tasksById.values {
            guard task.type == .counting, let root = task.sharedCounterId, !root.isEmpty else { continue }
            let direct = placementsByTaskId[task.id] ?? [:]
            let hasGoal = hasCopyGoal(task.maxCount, kind: resolveCountKind(task.countKind))

            if isWindowStampedDerived(task) {
                // 2. Mis-placed window-stamped rows: a copy per direct placement
                //    on a board the row is not stamped for; no stamp.
                guard hasGoal else { continue }
                for (boardId, boardTaskId) in direct {
                    guard let board = boardsById[boardId], !isWindowStampedForBoard(task, board: board),
                          derivedTaskId(boardId: board.id, rootTaskId: root) != task.id else { continue }
                    copies.append(copy(for: task, root: root, board: board, boardTaskId: boardTaskId))
                }
                continue
            }

            // 1. Unstamped candidates: stamp the first board and copy every
            //    further one — or do nothing at all.
            var boardIds = Set(direct.keys)
            for parentId in parentsByChildId[task.id] ?? [] {
                for boardId in (placementsByTaskId[parentId] ?? [:]).keys { boardIds.insert(boardId) }
            }
            if boardIds.isEmpty { continue }

            let ordered = boardIds.compactMap { boardsById[$0] }.sorted(by: boardWindowPrecedes)
            guard let first = ordered.first else { continue }
            let further = ordered.dropFirst()
            let repointable = further.allSatisfy { direct[$0.id] != nil } && (further.isEmpty || hasGoal)
            guard repointable else { continue }

            stamps.append(LinkedCounterWindowStamp(
                taskId: task.id,
                boardId: first.id,
                timeframe: first.timeframe,
                startDate: first.startDate,
                endDate: first.endDate
            ))
            for board in further {
                copies.append(copy(for: task, root: root, board: board, boardTaskId: direct[board.id]!))
            }
        }

        stamps.sort { a, b in
            if a.taskId != b.taskId { return a.taskId < b.taskId }
            return a.boardId < b.boardId
        }
        copies.sort { a, b in
            if a.sourceTaskId != b.sourceTaskId { return a.sourceTaskId < b.sourceTaskId }
            return a.boardId < b.boardId
        }
        return LinkedCounterWindowHealPlan(stamps: stamps, copies: copies)
    }

    /// Whether a goal can seed a per-window copy: whole kinds need `>= 1`, a
    /// continuous goal any positive value. Mirrors the TS `hasCopyGoal`.
    static func hasCopyGoal(_ maxCount: CountValue?, kind: CountKind) -> Bool {
        guard let maxCount else { return false }
        return isWholeCountKind(kind) ? maxCount >= 1 : maxCount > 0
    }

    /// The ``DerivedTaskDraft`` for one heal ``LinkedCounterWindowCopy``, so
    /// the data layer materialises it through the existing
    /// ``buildDerivedRows(drafts:userId:now:rootsById:compoundsById:)`` (which
    /// sets `createdInWizard`, mirrors the root's count, stamps the latch, …).
    ///
    /// Action / unit / goal come from the SOURCE row (the copy keeps the
    /// linked row's own target — no pro-rating, no vary); the title is
    /// `TaskTitle.counterCopyTitle` — a custom name carries over verbatim, an
    /// auto one is regenerated (2026-10-06); `replacesId` / `sourceMemberId`
    /// are the source; the window is the copy's.
    /// `baseline` is the caller's event-derived count of the root at the
    /// copy's `startDate` (``computeWindowBaseline(rootTaskId:events:boundary:)``),
    /// low-clamped at 0. Returns `nil` for a goal-less source — the planner
    /// never emits a copy for such a row; this is the defensive twin of that
    /// rule. Mirrors the TS `windowStampedCopyDraft`.
    ///
    /// - Parameters:
    ///   - copy: The planned copy.
    ///   - sourceTask: The linked row it stands in for.
    ///   - baseline: The root's event-derived count at the copy's window start.
    /// - Returns: The draft, or `nil` when the source has no goal.
    static func windowStampedCopyDraft(
        copy: LinkedCounterWindowCopy,
        sourceTask: Task,
        baseline: CountValue
    ) -> DerivedTaskDraft? {
        let countKind = resolveCountKind(sourceTask.countKind)
        guard let goal = sourceTask.maxCount, hasCopyGoal(goal, kind: countKind) else { return nil }
        func whole(_ x: CountValue) -> CountValue {
            isWholeCountKind(countKind) ? x.rounded(.down) : quantizeCount(x)
        }
        let maxCount = whole(goal)
        let action = sourceTask.action ?? ""
        let unit = sourceTask.unit ?? ""
        return DerivedTaskDraft(
            id: copy.id,
            rootTaskId: copy.rootTaskId,
            sourceMemberId: copy.sourceTaskId,
            replacesId: copy.sourceTaskId,
            maxCount: maxCount,
            countKind: countKind,
            baseline: Swift.max(0, whole(baseline)),
            title: TaskTitle.counterCopyTitle(member: sourceTask, newMaxCount: maxCount),
            action: action,
            unit: unit,
            timeframe: copy.timeframe,
            startDate: copy.startDate,
            endDate: copy.endDate
        )
    }
}
