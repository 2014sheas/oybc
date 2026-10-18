import Foundation

// MARK: - Placement sweep planner (TASK_WINDOW_REWORK slice 4a derived counters, 4b derived compounds)
//
// Swift twin of `packages/shared/src/algorithms/placementSweep.ts`, pinned by
// `placementSweepVectors.json`. A pure, deterministic, equivalence-gated plan:
// every live placement that still points at a legacy window-stamped derived
// counter is repointed at the row's ROOT with the row's frozen goal as
// `targetOverride` (a custom title becomes `titleOverride`), but only when the
// kernel, run over the same event union before and after the repoint, agrees
// on every cell, the completed count and the bingo lines (bounded at
// `sealedAt` for a sealed board). A refused board has its marked rows' window
// marks stripped. Orphans (marked, unplaced and unlinked BEFORE the run) are
// tombstoned; a row this run repoints away from retires on the next run.
// The applier is `AppDatabase+PlacementSweep.swift`.

extension BoardSources {

    /// The rows the planner reads — any superset; deleted rows are filtered here.
    struct SweepWorkspace {
        var tasks: [Task]
        var boards: [Board]
        var boardTasks: [BoardTask]
        var compoundChildren: [CompoundChild]
        var events: [TaskEvent]
    }

    /// One placement repoint: `boardTaskId` now points at `toTaskId` with these parameters.
    struct SweepRepoint: Codable, Equatable {
        var boardId: String
        var boardTaskId: String
        var fromTaskId: String
        var toTaskId: String
        var targetOverride: CountValue?
        var targetKind: CountKind?
        /// Slice 4b: a derived compound's forward-mapped per-child targets, keyed by the SOURCE child id.
        var childTargets: [PlacementChildTarget]?
        var titleOverride: String?
        /// The board is sealed — the applier takes the named `repointSealedPlacement` path.
        var sealed: Bool
    }

    enum SweepBoardOutcomeKind: String, Codable, Equatable { case repointed, refused }

    enum SweepRefusalReason: String, Codable, Equatable { case rootMissing, duplicateRoot, derivationChanged, compoundMismatch }

    struct SweepBoardOutcome: Codable, Equatable {
        var boardId: String
        var outcome: SweepBoardOutcomeKind
        /// Why a board was refused; nil when it was repointed (encoded as an explicit null).
        var reason: SweepRefusalReason?
        /// A sealed board whose stored snapshot already differs from the kernel's re-derivation.
        var sealedSnapshotDrift: Bool

        enum CodingKeys: String, CodingKey { case boardId, outcome, reason, sealedSnapshotDrift }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(boardId, forKey: .boardId)
            try c.encode(outcome, forKey: .outcome)
            try c.encode(reason, forKey: .reason)
            try c.encode(sealedSnapshotDrift, forKey: .sealedSnapshotDrift)
        }
    }

    struct PlacementSweepPlan: Codable, Equatable {
        var repoints: [SweepRepoint] = []
        /// Marked rows whose window marks are stripped.
        var strips: [String] = []
        /// Marked rows with no live placement and no live parent link anywhere.
        var orphanTombstones: [String] = []
        /// derived row id → root id, for re-keying stored rules.
        var rekey: [String: String] = [:]
        /// Boards with at least one repoint — the applier re-derives them.
        var touchedBoardIds: [String] = []
        var outcomes: [SweepBoardOutcome] = []

        /// True when the plan writes nothing and reports nothing.
        var isEmpty: Bool {
            repoints.isEmpty && strips.isEmpty && orphanTombstones.isEmpty && outcomes.isEmpty
        }
    }

    private struct SweepSignature: Equatable {
        var grid: [Bool]
        var completedTasks: Int
        var lines: [String]
    }

    private static func sweepSignature(
        board: Board, placements: [BoardTask], childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task], allBoards: [Board], ctx: WindowEvaluationContext
    ) -> SweepSignature {
        let r = DerivationPass.computeBoardGrid(
            board: board, boardTasksOnBoard: placements, childrenByCompound: childrenByCompound,
            taskById: taskById, allBoards: allBoards, windowContext: ctx
        )
        let lines = BingoDetection.detectBingos(completionGrid: r.grid, gridSize: board.boardSize).completedLines.sorted()
        return SweepSignature(grid: r.grid, completedTasks: r.completedTasks, lines: lines)
    }

    /// The repoint a legacy derived counter's placement gets: its root, the
    /// frozen goal as the override (a slice-3a override on the placement wins),
    /// the row's kind, and a custom title carried over.
    private static func sweepRepoint(_ bt: BoardTask, row: Task, root: Task, sealed: Bool) -> SweepRepoint {
        let kind = resolveCountKind(row.countKind)
        let custom = !TaskTitle.isAutoCounterTitle(
            title: row.title, action: row.action ?? "", maxCount: row.maxCount, unit: row.unit ?? "",
            countKind: kind, settings: CounterSettings.TitleSettings(task: root)
        )
        var out = SweepRepoint(
            boardId: bt.boardId, boardTaskId: bt.id, fromTaskId: row.id, toTaskId: root.id, sealed: sealed
        )
        if let target = bt.targetOverride ?? row.maxCount, target > 0 {
            out.targetOverride = target
            out.targetKind = (bt.targetOverride != nil && bt.targetKind != nil) ? bt.targetKind : kind
        }
        let existing = bt.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = !existing.isEmpty ? existing : (custom ? row.title.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        if !title.isEmpty { out.titleOverride = title }
        return out
    }

    /// The placement row as the repoint would write it.
    private static func applySweepRepoint(_ bt: BoardTask, _ r: SweepRepoint) -> BoardTask {
        var next = bt
        next.taskId = r.toTaskId
        next.targetOverride = r.targetOverride
        next.targetKind = r.targetOverride != nil ? r.targetKind : nil
        next.childTargets = r.childTargets
        next.titleOverride = r.titleOverride
        return next
    }

    /// A legacy per-window derived COMPOUND (B2): a compound carrying a window
    /// stamp and the wizard provenance mark. Twin of the TS helper.
    static func isWindowStampedDerivedCompound(_ task: Task) -> Bool {
        task.type == .compound && !(task.startDate ?? "").isEmpty && task.createdInWizard
    }

    /// A counting task's own goal in its kind (whole kinds floor, `>= 1`; continuous quantizes), or nil.
    private static func sweepOwnGoal(_ t: Task) -> CountValue? {
        guard let max = t.maxCount else { return nil }
        if isWholeCountKind(resolveCountKind(t.countKind)) { return max >= 1 ? max.rounded(.down) : nil }
        return max > 0 ? quantizeCount(max) : nil
    }

    private struct SweepCompoundMatch {
        var source: Task
        var childTargets: [PlacementChildTarget]
        /// derived child id to its root, for the rule re-key map.
        var childRekey: [String: String]
    }

    /// Slice 4b: find a derived compound's SOURCE by forward uuidv5 match and
    /// map its children forward. Twin of the TS `matchDerivedCompound`.
    private static func matchDerivedCompound(
        derived: Task, placingBoardId: String, bt: BoardTask, liveTasks: [Task], taskById: [String: Task],
        allBoardIds: [String], childrenByCompound: [String: [CompoundChild]]
    ) -> SweepCompoundMatch? {
        let derivedKidSet = Set((childrenByCompound[derived.id] ?? []).map(\.childTaskId))
        let sources = liveTasks.filter {
            $0.type == .compound && !isWindowStampedDerivedCompound($0)
                && $0.operatorType == derived.operatorType && $0.threshold == derived.threshold
        }.sorted { $0.id < $1.id }
        let mintBoards = [placingBoardId] + allBoardIds.filter { $0 != placingBoardId }
        for mint in mintBoards {
            for source in sources {
                guard derivedCompoundId(boardId: mint, compoundId: source.id) == derived.id else { continue }
                let sourceKids = (childrenByCompound[source.id] ?? []).sorted {
                    $0.childIndex != $1.childIndex ? $0.childIndex < $1.childIndex : $0.childTaskId < $1.childTaskId
                }
                var mapped = Set<String>()
                var childTargets: [PlacementChildTarget] = []
                var childRekey: [String: String] = [:]
                var ok = !sourceKids.isEmpty
                for k in sourceKids {
                    guard let c = taskById[k.childTaskId], !c.isDeleted else { ok = false; break }
                    var target = c.id
                    if c.type == .counting {
                        let root = c.sharedCounterId ?? c.id
                        let part = derivedTaskId(boardId: mint, rootTaskId: root)
                        if derivedKidSet.contains(part), let partRow = taskById[part], !partRow.isDeleted {
                            target = part
                            childRekey[part] = root
                            let existing = bt.childTargets?.first { $0.childId == c.id } ?? bt.childTargets?.first { $0.childId == part }
                            if let goal = existing?.target ?? partRow.maxCount, goal > 0, goal != sweepOwnGoal(c),
                               !childTargets.contains(where: { $0.childId == c.id }) {
                                childTargets.append(PlacementChildTarget(childId: c.id, target: goal))
                            }
                        }
                    }
                    mapped.insert(target)
                }
                if !ok { continue }
                if mapped != derivedKidSet { continue }
                return SweepCompoundMatch(source: source, childTargets: childTargets, childRekey: childRekey)
            }
        }
        return nil
    }

    /// Plan the sweep over a workspace (slice 4a — derived counters). Twin of
    /// the TS `planPlacementSweep`; `now` is reserved for the applier's stamps.
    ///
    /// - Parameters:
    ///   - ws: The workspace rows (any superset; deleted rows filtered here).
    ///   - now: ISO8601 write instant (unused by the plan itself).
    /// - Returns: The plan; empty when no marked row exists.
    static func planPlacementSweep(ws: SweepWorkspace, now: String) -> PlacementSweepPlan {
        _ = now
        let liveTasks = ws.tasks.filter { !$0.isDeleted }
        let marked = liveTasks.filter { ($0.type == .counting && isWindowStampedDerived($0)) || isWindowStampedDerivedCompound($0) }
        if marked.isEmpty { return PlacementSweepPlan() }

        var taskById: [String: Task] = [:]
        for t in ws.tasks { taskById[t.id] = t }
        let markedById = Dictionary(marked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allBoards = ws.boards.filter { !$0.isDeleted }
        let boardById = Dictionary(allBoards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allBoardIds = ws.boards.map(\.id).sorted()
        let livePlacements = ws.boardTasks.filter { !$0.isDeleted && boardById[$0.boardId] != nil }
        let liveLinks = ws.compoundChildren.filter { !$0.isDeleted }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in liveLinks { childrenByCompound[c.compoundTaskId, default: []].append(c) }
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        for e in ws.events where !e.isDeleted { eventsByTaskId[e.taskId, default: []].append(e) }

        var placementsByBoard: [String: [BoardTask]] = [:]
        for bt in livePlacements { placementsByBoard[bt.boardId, default: []].append(bt) }
        let candidateBoardIds = placementsByBoard
            .filter { $0.value.contains { markedById[$0.taskId] != nil } }
            .map(\.key).sorted()

        var repoints: [SweepRepoint] = []
        var strips = Set<String>()
        var rekey: [String: String] = [:]
        var touched: [String] = []
        var outcomes: [SweepBoardOutcome] = []

        for boardId in candidateBoardIds {
            guard let board = boardById[boardId] else { continue }
            let sealed = board.sealedAt != nil
            let placements = placementsByBoard[boardId, default: []].sorted {
                $0.row != $1.row ? $0.row < $1.row : ($0.col != $1.col ? $0.col < $1.col : $0.id < $1.id)
            }
            let markedHere = placements.filter { markedById[$0.taskId] != nil }
            func refuse(_ reason: SweepRefusalReason, _ drift: Bool) {
                for bt in markedHere { strips.insert(bt.taskId) }
                outcomes.append(SweepBoardOutcome(boardId: boardId, outcome: .refused, reason: reason, sealedSnapshotDrift: drift))
            }

            // A sealed board's events are bounded at `sealedAt` (unparseable ⇒ no bound).
            let ctx: WindowEvaluationContext
            if sealed, let sealedAt = board.sealedAt, let date = DateFormatting.parseISO(sealedAt) {
                ctx = boundWindowContextAtSeal(eventsByTaskId: eventsByTaskId, sealedAtMs: date.timeIntervalSince1970 * 1000)
            } else {
                ctx = WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
            }

            let before = sweepSignature(
                board: board, placements: placements, childrenByCompound: childrenByCompound,
                taskById: taskById, allBoards: allBoards, ctx: ctx
            )
            let drift = sealed ? !sweepGridMatchesSnapshot(before.grid, board.sealedCompletedCells) : false

            var proposed: [BoardTask] = []
            var boardRepoints: [SweepRepoint] = []
            var childRekeys: [String: String] = [:]
            var placedTaskIds = Set(placements.filter { markedById[$0.taskId] == nil }.map(\.taskId))
            var reason: SweepRefusalReason?
            for bt in placements {
                guard let row = markedById[bt.taskId] else { proposed.append(bt); continue }

                if row.type == .compound {
                    guard let match = matchDerivedCompound(
                        derived: row, placingBoardId: boardId, bt: bt, liveTasks: liveTasks, taskById: taskById,
                        allBoardIds: allBoardIds, childrenByCompound: childrenByCompound
                    ) else { reason = .compoundMismatch; break }
                    if placedTaskIds.contains(match.source.id) { reason = .duplicateRoot; break }
                    placedTaskIds.insert(match.source.id)
                    var r = SweepRepoint(
                        boardId: boardId, boardTaskId: bt.id, fromTaskId: row.id, toTaskId: match.source.id, sealed: sealed
                    )
                    if !match.childTargets.isEmpty { r.childTargets = match.childTargets }
                    let existingTitle = bt.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let rowTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = !existingTitle.isEmpty
                        ? existingTitle
                        : (rowTitle != match.source.title.trimmingCharacters(in: .whitespacesAndNewlines) ? rowTitle : "")
                    if !title.isEmpty { r.titleOverride = title }
                    for (part, root) in match.childRekey { childRekeys[part] = root }
                    boardRepoints.append(r)
                    proposed.append(applySweepRepoint(bt, r))
                    continue
                }
                guard let rootId = row.sharedCounterId, !rootId.isEmpty,
                      let root = taskById[rootId], !root.isDeleted else { reason = .rootMissing; break }
                if placedTaskIds.contains(root.id) { reason = .duplicateRoot; break }
                placedTaskIds.insert(root.id)
                let r = sweepRepoint(bt, row: row, root: root, sealed: sealed)
                boardRepoints.append(r)
                proposed.append(applySweepRepoint(bt, r))
            }
            if let reason { refuse(reason, drift); continue }

            let after = sweepSignature(
                board: board, placements: proposed, childrenByCompound: childrenByCompound,
                taskById: taskById, allBoards: allBoards, ctx: ctx
            )
            if before != after { refuse(.derivationChanged, drift); continue }
            repoints.append(contentsOf: boardRepoints)
            for r in boardRepoints { rekey[r.fromTaskId] = r.toTaskId }
            for (part, root) in childRekeys { rekey[part] = root }
            touched.append(boardId)
            outcomes.append(SweepBoardOutcome(boardId: boardId, outcome: .repointed, reason: nil, sealedSnapshotDrift: drift))
        }

        // A row repointed on one board is not stripped on another.
        for r in repoints { strips.remove(r.fromTaskId) }

        // Orphans: marked, unplaced and not a child of a live compound BEFORE this run.
        let placedBefore = Set(livePlacements.map(\.taskId))
        let childOfLive = Set(liveLinks.filter { taskById[$0.compoundTaskId].map { !$0.isDeleted } ?? false }.map(\.childTaskId))
        let orphans = marked.filter { !placedBefore.contains($0.id) && !childOfLive.contains($0.id) }.map(\.id).sorted()

        return PlacementSweepPlan(
            repoints: repoints, strips: strips.sorted(), orphanTombstones: orphans,
            rekey: rekey, touchedBoardIds: touched, outcomes: outcomes
        )
    }

    private static func sweepGridMatchesSnapshot(_ grid: [Bool], _ cells: [Int]?) -> Bool {
        let snap = Set(cells ?? [])
        for i in grid.indices where grid[i] != snap.contains(i) { return false }
        return true
    }

    // MARK: - Rule re-keying

    /// Re-key an id list through `map` (derived id → root id): order preserved,
    /// duplicates collapsed (first wins). Returns the input unchanged (equal)
    /// when nothing maps. Twin of the TS `rekeyIds`.
    static func rekeyIds(_ ids: [String], map: [String: String]) -> [String] {
        guard ids.contains(where: { map[$0] != nil }) else { return ids }
        var out: [String] = []
        var seen = Set<String>()
        for id in ids {
            let next = map[id] ?? id
            if seen.insert(next).inserted { out.append(next) }
        }
        return out
    }

    /// Re-key a record's keys through `map`: keys visited ascending, the FIRST
    /// key landing on a target wins. Returns the input when nothing maps.
    /// Twin of the TS `rekeyRecordKeys`.
    static func rekeyRecordKeys<V>(_ record: [String: V], map: [String: String]) -> [String: V] {
        guard record.keys.contains(where: { map[$0] != nil }) else { return record }
        var out: [String: V] = [:]
        for k in record.keys.sorted() {
            let next = map[k] ?? k
            if out[next] != nil { continue }
            out[next] = record[k]
        }
        return out
    }
}
