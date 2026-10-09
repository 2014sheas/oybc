import Foundation

// MARK: - Board-scoped task edits — fork ids + planner (PR 1, inert)
//
// Swift twin of `packages/shared/src/algorithms/boardScopedFork.ts`
// (docs/BOARD_SCOPED_TASK_EDITS.md). An edit made from a board affects the
// task ONLY on that board: when the task is placed on any other board, the
// edit lands on a FORK — a new Task that replaces the original on this
// board's placement. This file is the pure planning half; nothing calls it
// yet (PR 2 wires it into the Board Edit / wizard commit transactions).
//
// Pinned by `boardScopedForkVectors.json` (`BoardScopedForkVectorTests`). A
// change here is a change in two places.
enum BoardScopedFork {

    // MARK: - Deterministic ids

    /// uuidv5 name prefix for a board-scoped fork of a task.
    static let forkTaskNamespace = "fork:task"
    /// uuidv5 name prefix for an event copied onto a fork.
    static let forkEventNamespace = "fork:event"
    /// uuidv5 name prefix for a `compound_children` link copied onto a forked compound.
    static let forkLinkNamespace = "fork:link"

    /// Deterministic id of the fork of `taskId` on `boardId`.
    ///
    /// - Parameters:
    ///   - boardId: The board the edit is made from.
    ///   - taskId: The task being forked (the original).
    /// - Returns: A stable uuidv5 — forking the same square again yields the same id.
    static func forkTaskId(boardId: String, taskId: String) -> String {
        UUIDv5.uuidv5(name: "\(forkTaskNamespace):\(boardId):\(taskId)")
    }

    /// Deterministic id of the copy of `eventId` migrated onto `forkId`. Keyed
    /// on the fork as well as the event: one event can sit inside two
    /// overlapping windows (a daily inside its monthly) and so be migrated
    /// onto two different forks.
    ///
    /// - Parameters:
    ///   - forkId: The fork the copy belongs to.
    ///   - eventId: The original event's id.
    /// - Returns: A stable uuidv5.
    static func forkedEventId(forkId: String, eventId: String) -> String {
        UUIDv5.uuidv5(name: "\(forkEventNamespace):\(forkId):\(eventId)")
    }

    /// Deterministic id of the link from a forked compound to one of the
    /// original's (shared) children.
    ///
    /// - Parameters:
    ///   - forkId: The forked compound's id.
    ///   - childTaskId: The child task the link points at.
    /// - Returns: A stable uuidv5.
    static func forkLinkId(forkId: String, childTaskId: String) -> String {
        UUIDv5.uuidv5(name: "\(forkLinkNamespace):\(forkId):\(childTaskId)")
    }

    // MARK: - Plan

    /// Repoint the edited board's placement from the original to the fork.
    struct Repoint: Equatable {
        let boardTaskId: String
        let newTaskId: String
    }

    /// Output of ``plan(task:board:editedType:placements:boards:compoundChildren:events:now:)``.
    enum Plan {
        /// Edit the task row itself.
        case inPlace
        /// Insert `fork`, the event copies and the link copies, then repoint
        /// (`nil` when the task is on this board only through a compound).
        /// `onBoardHolderCompoundIds` = the compounds with a live placement on
        /// THIS board that contain the task directly or transitively (over
        /// live links), sorted by id: PR 2 repoints the task's link within
        /// each holder's subtree, forking a holder that is itself placed
        /// elsewhere first. Mirrors the TS field of the same name.
        case fork(
            fork: Task,
            eventCopies: [TaskEvent],
            childLinksToCopy: [CompoundChild],
            repoint: Repoint?,
            onBoardHolderCompoundIds: [String]
        )
    }

    /// The event kind a task type owns, or `nil` for a type that owns none.
    private static func ownedEventKind(_ type: TaskType) -> TaskEventKind? {
        switch type {
        case .normal: return .completion
        case .counting: return .increment
        case .compound, .achievement: return nil
        }
    }

    /// Epoch ms of an ISO instant, `NaN` when unparseable (the TS
    /// `new Date(x).getTime()` degrade — every comparison then fails).
    private static func ms(_ iso: String) -> Double {
        DateFormatting.parseISO(iso).map { $0.timeIntervalSince1970 * 1000 } ?? Double.nan
    }

    /// Plain code-unit string order (matches JS `<` on strings).
    private static func precedes(_ a: String, _ b: String) -> Bool {
        Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
    }

    /// Plan a board-scoped edit of `task` from `board`. Mirrors the TS
    /// `planBoardScopedFork` rule for rule — see its doc for the full
    /// contract. In short:
    ///
    /// - **In place** when the task is a fork (`forkedFromTaskId` set) or a
    ///   linked counter (`sharedCounterId` set), or has no live placement on
    ///   any OTHER board (live = placement not deleted, board present and not
    ///   deleted — sealed/archived boards count, D1; reached directly or via
    ///   any transitive parent compound over live links; pools/templates are
    ///   not placements, D2).
    /// - **Fork** otherwise: the original row re-identified
    ///   (`forkTaskId(board, task)`), `forkedFromTaskId = task.id`,
    ///   `createdInWizard`, `isCounter = false`, version 1, timestamps `now`,
    ///   sync metadata dropped, lifetime caches reset (PR 2 stamps them from
    ///   the fork's events after applying the edit); in-window events
    ///   (`[startDate, min(endDate, sealedAt)]`, inclusive, instant compare)
    ///   of the kind the EDITED type owns, copied; the compound's live child
    ///   links re-parented (children stay shared); the smallest-id direct
    ///   placement on this board repointed; the placed compounds on this
    ///   board that contain the task reported as `onBoardHolderCompoundIds`.
    ///
    /// - Parameters:
    ///   - task: The task being edited (pre-edit row).
    ///   - board: The board the edit is made from.
    ///   - editedType: The task type AFTER the edit (selects migrated events).
    ///   - placements: `board_tasks` rows of the task and its parent compounds
    ///     (rows for other tasks are ignored).
    ///   - boards: Boards referenced by `placements`; absent = not live.
    ///   - compoundChildren: Links (the task's parents and children).
    ///   - events: The task's events (rows for other tasks are ignored).
    ///   - now: The write instant stamped on every minted row.
    /// - Returns: The plan.
    static func plan(
        task: Task,
        board: Board,
        editedType: TaskType,
        placements: [BoardTask],
        boards: [Board],
        compoundChildren: [CompoundChild],
        events: [TaskEvent],
        now: String
    ) -> Plan {
        if task.forkedFromTaskId != nil || task.sharedCounterId != nil { return .inPlace }

        let liveBoardIds = Set(boards.filter { !$0.isDeleted }.map(\.id))
        var holders = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: task.id,
            children: compoundChildren
        )
        holders.insert(task.id)

        var elsewhere = false
        var repointId: String?
        var onBoardHolders = Set<String>()
        for p in placements where !p.isDeleted && holders.contains(p.taskId) && liveBoardIds.contains(p.boardId) {
            if p.boardId != board.id {
                elsewhere = true
            } else if p.taskId != task.id {
                onBoardHolders.insert(p.taskId)
            } else if repointId.map({ precedes(p.id, $0) }) ?? true {
                repointId = p.id
            }
        }
        if !elsewhere { return .inPlace }

        let forkId = forkTaskId(boardId: board.id, taskId: task.id)
        var fork = task
        fork.id = forkId
        fork.forkedFromTaskId = task.id
        fork.createdInWizard = true
        fork.isCounter = false
        fork.version = 1
        fork.createdAt = now
        fork.updatedAt = now
        fork.lastSyncedAt = nil
        fork.isDeleted = false
        fork.deletedAt = nil
        fork.isCompleted = false
        fork.completedAt = nil
        fork.currentCount = task.type == .counting ? 0 : nil
        fork.totalCompletions = 0
        fork.totalInstances = 1

        var eventCopies: [TaskEvent] = []
        if let kind = ownedEventKind(editedType) {
            let lower = ms(board.startDate)
            let bounds = [board.endDate, board.sealedAt].compactMap { $0 }.map(ms)
            func inWindow(_ e: TaskEvent) -> Bool {
                let t = ms(e.occurredAt)
                return t >= lower && bounds.allSatisfy { t <= $0 }
            }
            eventCopies = events
                .filter { $0.taskId == task.id && !$0.isDeleted && $0.kind == kind && inWindow($0) }
                .sorted { a, b in
                    let ta = ms(a.occurredAt)
                    let tb = ms(b.occurredAt)
                    if ta != tb { return ta < tb }
                    return precedes(a.id, b.id)
                }
                .map { e in
                    var copy = e
                    copy.id = forkedEventId(forkId: forkId, eventId: e.id)
                    copy.taskId = forkId
                    copy.createdAt = now
                    copy.updatedAt = now
                    copy.lastSyncedAt = nil
                    copy.version = 1
                    copy.isDeleted = false
                    copy.deletedAt = nil
                    return copy
                }
        }

        let childLinksToCopy = compoundChildren
            .filter { !$0.isDeleted && $0.compoundTaskId == task.id }
            .sorted { a, b in
                if a.childIndex != b.childIndex { return a.childIndex < b.childIndex }
                return precedes(a.id, b.id)
            }
            .map { l in
                CompoundChild(
                    id: forkLinkId(forkId: forkId, childTaskId: l.childTaskId),
                    compoundTaskId: forkId,
                    childTaskId: l.childTaskId,
                    childIndex: l.childIndex,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: false,
                    deletedAt: nil
                )
            }

        return .fork(
            fork: fork,
            eventCopies: eventCopies,
            childLinksToCopy: childLinksToCopy,
            repoint: repointId.map { Repoint(boardTaskId: $0, newTaskId: forkId) },
            onBoardHolderCompoundIds: onBoardHolders.sorted(by: precedes)
        )
    }
}
