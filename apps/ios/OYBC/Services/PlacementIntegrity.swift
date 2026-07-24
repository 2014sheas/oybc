import Foundation

/// Board-integrity PR-2 (docs/BOARD_INTEGRITY.md) — deterministic placement
/// winner rule + pure repair core. Swift twin of
/// `packages/shared/src/algorithms/placementResolution.ts`, case-for-case —
/// keep them in lockstep, same pattern as `PoolMix.swift`. Vector-pinned
/// cross-platform by `Fixtures/placementResolutionVectors.json`
/// (`PlacementResolutionVectorTests.swift` runs the SAME fixture the TS
/// suite does).
///
/// PR-1 gave `BoardTask` durable tombstones, but did nothing to fix ALREADY
/// corrupted boards (duplicate placement rows left behind from the
/// pre-tombstone era), nor to make collision resolution deterministic
/// across every reader. Two problems, one root fix:
///
///  1. When more than one live `BoardTask` row lands on the same cell (or
///     the same Task ends up placed more than once on one board), every
///     reader — render, edit-draft seeding, the derivation kernel — must
///     pick the SAME winner, or the visible grid and the persisted stats
///     can disagree.
///  2. The repair pass (Part 1, `AppDatabase+Sealing.repairPlacementIntegrityTx`)
///     needs a PURE decision procedure for which rows to tombstone, so two
///     devices independently repairing the SAME corrupted board converge on
///     tombstoning the SAME losers — no ping-pong, ordinary LWW reconciles
///     the tombstones afterward.
///
/// Both are driven by ONE winner rule: highest `version` → newest
/// `updatedAt` → lowest `id` (lexicographic).
///
/// `resolvePlacements` is the ROW-SET selector Part 2 wires into render
/// (`BoardPlayView.btByPosition`), edit-draft seeding (`seedEditDraft`), and
/// every cascade's derivation-input assembly — before repair even runs, no
/// two readers can disagree about which row occupies a cell. It resolves
/// ONLY same-cell collisions — it deliberately does NOT collapse same-task
/// duplicates across different (non-colliding) cells; two non-colliding
/// cells legitimately render/derive independently even when they happen to
/// share a taskId (that IS a board-wide invariant violation, but it's a
/// repair-pass concern, not a per-cell rendering concern). Full per-cell
/// resolver unification (task-duplicate collapsing at render time, etc.) is
/// deferred to PR-3.
///
/// `computeRepair` is the Part 1 core: given a board's full live placement
/// set, decide which rows are corrupt and must be tombstoned — cell
/// collisions AND same-task duplicates (a Task placed at >1 row on one
/// board), plus straight out-of-bounds rows (no winner to pick).
enum PlacementIntegrity {

    // MARK: - Winner rule

    /// True when `a` should win over `b`. Mirrors the shared TS
    /// `comparePlacementPrecedence`: highest `version` → newest `updatedAt`
    /// → lowest `id` (lexicographic). An unparseable `updatedAt` on EITHER
    /// side (or an exact-equal parsed instant) degrades straight to the id
    /// tie-break — never a raw string compare, matching the TS "unparseable
    /// or missing updatedAt degrades gracefully to the id tie-break rather
    /// than asserting a direction from an invalid comparison" contract.
    static func wins(_ a: BoardTask, over b: BoardTask) -> Bool {
        if a.version != b.version { return a.version > b.version }

        let aDate = DateFormatting.parseISO(a.updatedAt)
        let bDate = DateFormatting.parseISO(b.updatedAt)
        if let aDate, let bDate, aDate != bDate {
            return aDate > bDate
        }
        return a.id < b.id
    }

    /// Picks the single winner among a non-empty set of colliding/duplicate
    /// placements per the winner rule. Twin of TS `pickPlacementWinner`.
    ///
    /// - Precondition: `rows` is non-empty (callers never invoke with a
    ///   zero-length group — mirrors the TS contract, which throws).
    static func pickWinner(_ rows: [BoardTask]) -> BoardTask {
        precondition(!rows.isEmpty, "pickWinner: rows must be non-empty")
        var winner = rows[0]
        for row in rows.dropFirst() where wins(row, over: winner) {
            winner = row
        }
        return winner
    }

    // MARK: - resolvePlacements (render/derivation — CELL COLLISION ONLY)

    /// Resolves a raw (possibly corrupted) set of `BoardTask` rows for ONE
    /// board into a clean row-set: at most one row per `(row, col)` cell.
    ///
    /// Pure, order-independent. Filters tombstones (defense-in-depth — every
    /// known caller already pre-filters `!isDeleted`, but this is the shared
    /// choke point every reader funnels through) and drops out-of-bounds
    /// rows (`row`/`col` outside `[0, boardSize)`), then collapses any
    /// remaining `(row, col)` collision to its winner.
    ///
    /// Does NOT collapse same-task duplicates across different cells — see
    /// the type doc above. That is `computeRepair`'s job.
    ///
    /// Output is sorted by `(row, col, id)` ascending — stable and
    /// deterministic, matching `fetchBoardTasks`'s `ORDER BY row, col, id`
    /// (Part 2).
    ///
    /// - Parameters:
    ///   - rows: Raw `BoardTask` rows for a single board (any order, may
    ///     include tombstones / out-of-bounds / collisions).
    ///   - boardSize: The board's grid size (`Board.boardSize`).
    static func resolvePlacements(_ rows: [BoardTask], boardSize: Int) -> [BoardTask] {
        var byCell: [String: [BoardTask]] = [:]
        var cellOrder: [String] = []
        for bt in rows {
            if bt.isDeleted { continue }
            if bt.row < 0 || bt.col < 0 || bt.row >= boardSize || bt.col >= boardSize { continue }
            let key = "\(bt.row)-\(bt.col)"
            if byCell[key] == nil { cellOrder.append(key) }
            byCell[key, default: []].append(bt)
        }

        var out: [BoardTask] = []
        out.reserveCapacity(cellOrder.count)
        for key in cellOrder {
            let group = byCell[key]!
            out.append(group.count == 1 ? group[0] : pickWinner(group))
        }

        out.sort {
            if $0.row != $1.row { return $0.row < $1.row }
            if $0.col != $1.col { return $0.col < $1.col }
            return $0.id < $1.id
        }
        return out
    }

    // MARK: - computeRepair (Part 1 — OOB + cell collision + same-task dup)

    /// The outcome of a placement-integrity repair pass over one board.
    struct RepairResult {
        /// Live rows that violate an invariant and must be soft-deleted
        /// (tombstoned) by the caller. Empty when the board is already
        /// clean — repairing a clean board is always a zero-write no-op
        /// (idempotency).
        let toTombstone: [BoardTask]
    }

    /// Pure repair core (Part 1): given a board's full LIVE (non-tombstoned)
    /// placement set, decide which rows are corrupt and must be tombstoned.
    ///
    /// Three violation classes, resolved in this order so the result is a
    /// single deterministic pass (no violation class re-triggers another):
    ///
    ///   1. Out-of-bounds (`row`/`col` outside `[0, boardSize)`) — no winner
    ///      to pick, every such row is tombstoned outright.
    ///   2. Cell collisions (>1 in-bounds row at the same `(row, col)`) —
    ///      the winner rule picks ONE survivor per cell; every other row in
    ///      the group is tombstoned.
    ///   3. Same-task duplicates (one Task placed at >1 surviving row on
    ///      this board, evaluated AFTER cell-collision resolution) — the
    ///      winner rule again picks ONE survivor per taskId; every other
    ///      row is tombstoned.
    ///
    /// Deterministic ⇒ two devices independently repairing the SAME
    /// corrupted board pick the SAME winners, so there is no repair
    /// ping-pong. Idempotent: running this again on the post-repair
    /// survivor set always returns `toTombstone: []`.
    ///
    /// - Parameters:
    ///   - livePlacements: All live (non-tombstoned) `BoardTask` rows for
    ///     ONE board. Callers are responsible for pre-filtering `isDeleted`
    ///     and scoping to a single `boardId` — this function trusts its
    ///     input is already scoped.
    ///   - boardSize: The board's grid size (`Board.boardSize`).
    static func computeRepair(_ livePlacements: [BoardTask], boardSize: Int) -> RepairResult {
        var toTombstoneIds = Set<String>()
        var byId: [String: BoardTask] = [:]
        for bt in livePlacements { byId[bt.id] = bt }

        // 1. Out-of-bounds — no winner, straight tombstone.
        var inBounds: [BoardTask] = []
        for bt in livePlacements {
            if bt.row < 0 || bt.col < 0 || bt.row >= boardSize || bt.col >= boardSize {
                toTombstoneIds.insert(bt.id)
            } else {
                inBounds.append(bt)
            }
        }

        // 2. Cell collisions — winner rule per (row, col).
        var byCell: [String: [BoardTask]] = [:]
        var cellOrder: [String] = []
        for bt in inBounds {
            let key = "\(bt.row)-\(bt.col)"
            if byCell[key] == nil { cellOrder.append(key) }
            byCell[key, default: []].append(bt)
        }
        var afterCellResolution: [BoardTask] = []
        afterCellResolution.reserveCapacity(cellOrder.count)
        for key in cellOrder {
            let group = byCell[key]!
            if group.count == 1 {
                afterCellResolution.append(group[0])
                continue
            }
            let winner = pickWinner(group)
            afterCellResolution.append(winner)
            for bt in group where bt.id != winner.id {
                toTombstoneIds.insert(bt.id)
            }
        }

        // 3. Same-task duplicates — winner rule per taskId, evaluated on the
        //    cell-collision survivors (a row already tombstoned in step 2
        //    must not also "win" a task-duplicate group).
        var byTask: [String: [BoardTask]] = [:]
        var taskOrder: [String] = []
        for bt in afterCellResolution {
            if byTask[bt.taskId] == nil { taskOrder.append(bt.taskId) }
            byTask[bt.taskId, default: []].append(bt)
        }
        for taskId in taskOrder {
            let group = byTask[taskId]!
            guard group.count > 1 else { continue }
            let winner = pickWinner(group)
            for bt in group where bt.id != winner.id {
                toTombstoneIds.insert(bt.id)
            }
        }

        var toTombstone: [BoardTask] = []
        toTombstone.reserveCapacity(toTombstoneIds.count)
        for id in toTombstoneIds {
            if let bt = byId[id] { toTombstone.append(bt) }
        }
        // Deterministic output order (id ascending) — no functional
        // significance, just keeps caller writes/tests stable.
        toTombstone.sort { $0.id < $1.id }

        return RepairResult(toTombstone: toTombstone)
    }
}
