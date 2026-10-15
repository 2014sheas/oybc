import Foundation
import GRDB

// MARK: - BoardPlayViewModel + "Counts toward" board surfaces

extension BoardPlayViewModel {

    /// Whether a play cell draws the two-dot shared-counter mark: a linked /
    /// promoted counting square (the shared-counter detection), or — PR 4 — any
    /// task that counts toward a shared counter (`countsTowardCounterId`), of any
    /// type. Twin of web's `useBoardPlayData` shared-counter set.
    ///
    /// - Parameter task: The cell's task (nil for an empty / free cell).
    /// - Returns: True when the mark applies (the cell hides it once complete).
    func showsSharedCounterMark(for task: Task?) -> Bool {
        guard let t = task else { return false }
        if t.countsTowardCounterId != nil { return true }
        return t.type == .counting && sharedCounterSourceId(for: t) != nil
    }
}

// MARK: - Completion moment (PR 4 C4)

extension SharedCounterCreditToastPayload {
    /// What the credit toast's Undo reverses.
    enum UndoKind: Equatable {
        /// A hand log: the counter's last log entry (`undoLastCounterLog`).
        case counterLog
        /// A counts-toward completion: the tapped task's completion itself —
        /// the cascade then tombstones the credit. NEVER `undoLastCounterLog`.
        case uncomplete(taskId: String, boardTaskId: String?)
        /// A counting goal reached: restore the task's PREVIOUS windowed count.
        case restoreCount(taskId: String, boardTaskId: String, count: CountValue)
    }
}

/// The live credit events on each counter root a flagged task placed on this
/// board counts toward, read BEFORE a completion write (the toast diffs it).
struct CountsTowardCreditSnapshot {
    let liveIdsByRoot: [String: Set<String>]
}

extension BoardPlayViewModel {

    /// Snapshots the live credit-event ids on the roots of every flagged task
    /// placed on `currentBoardId`. Nil when no placed task counts toward a counter.
    /// Reads the database (call off the main actor).
    nonisolated static func countsTowardCreditSnapshot(
        database: AppDatabase, currentBoardId: String?, writtenTaskId: String
    ) -> CountsTowardCreditSnapshot? {
        guard let currentBoardId else { return nil }
        return try? database.read { db in
            let roots = Set(try onBoardContributors(db: db, boardId: currentBoardId, writtenTaskId: writtenTaskId)
                .compactMap(\.countsTowardCounterId))
            guard !roots.isEmpty else { return nil }
            var out: [String: Set<String>] = [:]
            for root in roots {
                out[root] = Set(try liveCreditIds(db: db, rootId: root))
            }
            return CountsTowardCreditSnapshot(liveIdsByRoot: out)
        }
    }

    /// The flagged tasks a write can credit: the WRITTEN task and its transitive
    /// parent compounds, placed on this board. (Never every on-board contributor:
    /// a credit another square — or a pull — lands between the two snapshots is
    /// not this write's, so it must not be attributed or undone.)
    private nonisolated static func onBoardContributors(db: Database, boardId: String, writtenTaskId: String) throws -> [Task] {
        let links = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let family = Set([writtenTaskId] + DerivationPass.findTransitiveParentCompounds(changedTaskId: writtenTaskId, children: links))
        let ids = try BoardTask.filter(Column("boardId") == boardId && Column("isDeleted") == false).fetchAll(db).map(\.taskId)
        return try Task.fetchAll(db, keys: Set(ids).intersection(family)).filter { !$0.isDeleted && $0.countsTowardCounterId != nil }
    }

    private nonisolated static func liveCreditIds(db: Database, rootId: String) throws -> [String] {
        try TaskEvent
            .filter(Column("taskId") == rootId && Column("kind") == TaskEventKind.increment.rawValue && Column("isDeleted") == false)
            .fetchAll(db).map(\.id)
    }

    /// The Undo for the write `intent` just made: a completion un-completes; a
    /// goal-reaching count restores the count it started from.
    nonisolated static func creditUndo(
        intent: AppDatabase.CompletionIntent, taskId: String, boardTaskId: String?, priorCount: CountValue
    ) -> SharedCounterCreditToastPayload.UndoKind {
        switch intent {
        case .setCompleted: return .uncomplete(taskId: taskId, boardTaskId: boardTaskId)
        case .setWindowedCount:
            guard let boardTaskId else { return .uncomplete(taskId: taskId, boardTaskId: nil) }
            return .restoreCount(taskId: taskId, boardTaskId: boardTaskId, count: priorCount)
        }
    }

    /// The "+N {counter}" credit toast, ONLY when the write + cascade just made
    /// NEW live credits (diffed against `snapshot`) that a contributor placed on
    /// THIS board owns (`candidateContributionIds`), AND the counter has squares
    /// (root or live copies) on OTHER non-deleted, non-draft boards whose window
    /// contains a credit's `occurredAt`. Nothing credited (late log before
    /// `since`, seal-suppressed, lineage already credited, unflagged, sub-task
    /// of an unplaced compound) means no toast. Reads the database (off-main).
    ///
    /// - Parameters:
    ///   - database: The injected database.
    ///   - snapshot: `countsTowardCreditSnapshot` taken before the write.
    ///   - currentBoardId: The board being played.
    ///   - undo: What Undo reverses (`creditUndo`).
    nonisolated static func countsTowardCreditToast(
        database: AppDatabase, snapshot: CountsTowardCreditSnapshot?, currentBoardId: String?, writtenTaskId: String,
        undo: SharedCounterCreditToastPayload.UndoKind
    ) -> SharedCounterCreditToastPayload? {
        guard let snapshot, let currentBoardId else { return nil }
        return try? database.read { db in
            let onBoard = try onBoardContributors(db: db, boardId: currentBoardId, writtenTaskId: writtenTaskId)
            let tasks = try Task.fetchAll(db)
            var taskById: [String: Task] = [:]
            for t in tasks { taskById[t.id] = t }
            for (root, before) in snapshot.liveIdsByRoot.sorted(by: { $0.key < $1.key }) {
                guard let rootTask = taskById[root], !rootTask.isDeleted else { continue }
                let fresh = try TaskEvent
                    .filter(Column("taskId") == root && Column("kind") == TaskEventKind.increment.rawValue && Column("isDeleted") == false)
                    .fetchAll(db).filter { !before.contains($0.id) }
                let mine = onBoard.filter { $0.countsTowardCounterId == root }
                guard !fresh.isEmpty, !mine.isEmpty else { continue }
                let contributors = tasks.filter { !$0.isDeleted && $0.countsTowardCounterId == root }
                let inputs = try AppDatabase.countsTowardInputs(
                    db: db, counterId: root, tasks: tasks, taskById: taskById, contributors: contributors
                )
                var owned = Set<String>()
                for c in mine { owned.formUnion(CountsToward.candidateContributionIds(c, inputs: inputs, rootIds: [root])) }
                let credits = fresh.filter { owned.contains($0.id) }
                guard !credits.isEmpty else { continue }
                // Other boards placing the root or a live copy whose window holds a credit.
                let memberIds = [root] + tasks.filter { !$0.isDeleted && $0.sharedCounterId == root }.map(\.id)
                let boardIds = Set(try BoardTask.filter(memberIds.contains(Column("taskId")) && Column("isDeleted") == false)
                    .fetchAll(db).map(\.boardId)).subtracting([currentBoardId])
                var others: [AppDatabase.AffectedBoard] = []
                for board in try Board.fetchAll(db, keys: boardIds) where !board.isDeleted && board.status != .draft {
                    // A sealed board bounds at min(endDate, sealedAt) (`buildSealImmuneWindows`).
                    let (startMs, endMs): (Double, Double) = {
                        if let sealedAt = board.sealedAt {
                            let w = buildSealImmuneWindows(sealedBoards: [(board.startDate, board.endDate, sealedAt)])[0]
                            return (w.startMs, w.endMs)
                        }
                        return (CountsToward.epochMs(board.startDate), board.endDate.map(CountsToward.epochMs) ?? .infinity)
                    }()
                    let holds = credits.contains { e in
                        let at = CountsToward.epochMs(e.occurredAt)
                        return !at.isNaN && (startMs.isNaN || at >= startMs) && (endMs.isNaN || at <= endMs)
                    }
                    if holds { others.append(AppDatabase.AffectedBoard(boardId: board.id, boardName: board.displayName)) }
                }
                guard !others.isEmpty else { continue }
                others.sort { $0.boardId < $1.boardId }
                let amount = credits.reduce(CountValue(0)) { $0 + ($1.delta ?? 0) }
                let kind = resolveCountKind(rootTask.countKind)
                return SharedCounterCreditToastPayload(
                    sourceTaskId: root, amount: amount, unit: "", isIncrement: true,
                    message: sharedCreditToastText(
                        counterName: CounterSettings.counterDisplayName(rootTask), amount: amount, kind: kind,
                        isIncrement: true
                    ),
                    undo: undo
                )
            }
            return nil
        }
    }

    /// The credit toast's Undo: a hand-log credit reverses the counter's last
    /// log; a counts-toward credit reverses the exact write made — un-complete
    /// the task, or restore the count it started from (no-op when it no longer
    /// holds in this window).
    func undoCreditToast(_ undo: SharedCounterCreditToastPayload.UndoKind, sourceTaskId: String) {
        switch undo {
        case .counterLog:
            undoSharedCounterLog(sourceTaskId: sourceTaskId)
        case let .uncomplete(taskId, boardTaskId):
            guard windowedState(forTaskId: taskId).isCompleted else { return }
            if let boardTaskId, let placement = boardTasks.first(where: { $0.id == boardTaskId }) {
                handleNormalTap(boardTask: placement)
            } else if let task = taskMap[taskId] {
                handleCompoundChildToggle(childTask: task)
            }
        case let .restoreCount(taskId, boardTaskId, count):
            guard !isProcessing, let placement = boardTasks.first(where: { $0.id == boardTaskId }) else { return }
            runOrchestration(taskId: taskId, intent: .setWindowedCount(count), boardTask: placement)
        }
    }
}
