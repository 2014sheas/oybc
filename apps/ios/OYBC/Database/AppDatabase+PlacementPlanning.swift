import Foundation
import GRDB

/// Board Sources "member rules", iOS half (docs/BOARD_SOURCES.md §Member
/// rules; docs/TASK_WINDOW_REWORK.md slice 3b). Nothing MINTS a derived row:
/// the planner emits placement parameters (``BoardSources/planDerivedTasks``)
/// and the writers put them on `board_tasks`. This file plans them
/// (`planPlacements` / `planWizardPlacements`). Every function takes an open
/// `Database` and MUST run inside the caller's transaction.
extension AppDatabase {

    // MARK: - Plan placements

    /// Plan the member rules for one board into PLACEMENT PARAMETERS
    /// (TASK_WINDOW_REWORK slice 3b: the planner emits parameters, never rows —
    /// nothing is minted). Runs inside the caller's open transaction.
    ///
    /// The returned placements are positionally 1:1 with `selectedIds`; the
    /// caller points each `board_tasks` row at `taskId` and writes the parameters with the row.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - selectedIds: The task ids picked for the board, in placement order.
    ///   - supplies: Per-source supplies, exclude-filtered and Split-up expanded.
    ///   - manualTaskIds: Hand-added ids.
    ///   - manualTaskVary: Hand-added members' vary levels.
    ///   - window: The window being assembled.
    ///   - mode: One-off or recurring (does not gate the target math).
    ///   - tasksById: Every id `selectedIds` / the supplies / the links name.
    ///   - childrenByCompoundId: Compound id → its live `compound_children` rows.
    ///   - sourceWindowByTaskId: Board-source members' (and their compound children's) source windows.
    ///   - rng: Unseeded in production; injected in tests.
    /// - Returns: One planned placement per selected id.
    static func planPlacements(
        db: Database,
        selectedIds: [String],
        supplies: [BoardSources.ExpandedSupply],
        manualTaskIds: [String],
        manualTaskVary: [String: VaryLevel],
        window: BoardSources.BoardWindow,
        mode: BoardSources.PlanMode,
        tasksById: [String: Task],
        childrenByCompoundId: [String: [CompoundChild]],
        sourceWindowByTaskId: [String: BoardSources.BoardWindow],
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) throws -> [BoardSources.PlannedPlacement] {
        // Roots' settings (docs/SHARED_COUNTER_SETTINGS.md §2): board pulls
        // consult its timeframe defaults; a member's title is
        // compared through its root's templates.
        var rootsById: [String: Task] = [:]
        for id in selectedIds {
            guard let sid = tasksById[id]?.sharedCounterId, !sid.isEmpty, tasksById[sid] == nil,
                  rootsById[sid] == nil, let root = try Task.fetchOne(db, key: sid) else { continue }
            rootsById[sid] = root
        }
        return BoardSources.planDerivedTasks(
            selectedIds: selectedIds,
            supplies: supplies,
            manualTaskIds: manualTaskIds,
            manualTaskVary: manualTaskVary,
            window: window,
            mode: mode,
            tasksById: tasksById,
            childrenByCompoundId: childrenByCompoundId,
            sourceWindowByTaskId: sourceWindowByTaskId,
            rootsById: rootsById,
            rng: rng
        ).placements
    }

    /// The one-off wizard's planning entry point: resolve this board's
    /// per-member rules into placement parameters inside `saveWizardBoard`'s
    /// transaction, before the `board_tasks` rows that will carry them.
    ///
    /// Rebuilds the supplies the same way the spawn path does — pool members
    /// via `poolSourceSupplyById`, board members via `resolveSourceBoard`
    /// (series binding) + `resolveSupply` (the done-filter) — then
    /// exclude-filters and Split-up-expands them through `applyMemberRules`.
    /// An unresolvable board source contributes an empty supply rather than
    /// failing the save.
    ///
    /// - Parameters:
    ///   - db: `saveWizardBoard`'s open transaction.
    ///   - selectedIds: The placed task ids, in placement order.
    ///   - sources: The wizard's pulled sources.
    ///   - manualTaskIds: The hand-added layer.
    ///   - manualTaskVary: Dice for hand-added counting members.
    ///   - window: The board's own window.
    ///   - rng: Uniform `[0, 1)` source for the dice rolls.
    /// - Returns: One planned placement per selected id, positionally.
    static func planWizardPlacements(
        db: Database,
        selectedIds: [String],
        sources: [BoardSource],
        manualTaskIds: [String],
        manualTaskVary: [String: VaryLevel],
        window: BoardSources.BoardWindow,
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) throws -> [BoardSources.PlannedPlacement] {
        // The planner gets LIVE rows only — a soft-deleted root reachable
        // through a member's `sharedCounterId` must not be mirrored into a new
        // derived row.
        var tasksById: [String: Task] = [:]
        for task in try Task.filter(Column("isDeleted") == false).fetchAll(db) {
            tasksById[task.id] = task
        }

        let poolSourceIds = sources.filter { $0.kind == .pool }.map { $0.sourceId }
        let pools = poolSourceIds.isEmpty
            ? []
            : try Pool.filter(poolSourceIds.contains(Column("id"))).fetchAll(db)
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

        var rawSupplies: [BoardSources.Supply] = []
        var sourceBoardWindow: [String: BoardSources.BoardWindow] = [:]
        for source in sources {
            switch source.kind {
            case .pool:
                rawSupplies.append(BoardSources.Supply(
                    // Pool-level default dice (2026-10-06) — the fallback for a
                    // member the Sources sheet never seeded.
                    source: BoardSources.withEffectiveMemberRules(
                        source: source, pool: poolsById[source.sourceId]
                    ),
                    supplyTaskIds: BoardSources.poolSourceSupplyById(
                        source.sourceId, poolsById: poolsById, tasksById: tasksById
                    )
                ))
            case .board:
                // The board open now (owner ruling 2026-09-24: sources are
                // open boards) — the same clock the wizard's live supply used.
                guard let board = try Self.resolveSourceBoard(
                    db: db,
                    storedBoardId: source.sourceId
                ) else {
                    rawSupplies.append(BoardSources.Supply(source: source, supplyTaskIds: []))
                    continue
                }
                sourceBoardWindow[source.sourceId] = BoardSources.BoardWindow(
                    timeframe: board.timeframe,
                    startDate: board.startDate,
                    endDate: board.endDate
                )
                let info = try Self.resolveSupply(db: db, board: board)
                let raw = BoardSources.availableSupplyIds(
                    source: source,
                    supplyTaskIds: info.supplyTaskIds,
                    doneTaskIds: info.doneTaskIds
                )
                rawSupplies.append(BoardSources.Supply(
                    source: source, supplyTaskIds: raw, goalByTaskId: info.goalByTaskId
                ))
            }
        }

        // Compound children for every compound the plan can name — the placed
        // ones (a One-square compound re-targets its parts) and the supplied
        // ones (a Split-up member expands into its children). ONE batched read.
        var compoundIds = Set<String>()
        func noteCompound(_ id: String) {
            if tasksById[id]?.type == .compound { compoundIds.insert(id) }
        }
        for id in selectedIds { noteCompound(id) }
        for supply in rawSupplies { for id in supply.supplyTaskIds { noteCompound(id) } }
        let childrenByCompoundId = try Self.fetchCompoundChildren(
            db: db, compoundTaskIds: Array(compoundIds)
        )

        let supplies = BoardSources.applyMemberRules(
            rawSupplies.map {
                BoardSources.Supply(
                    source: $0.source,
                    supplyTaskIds: BoardSources.resolveSourceAvailable($0),
                    goalByTaskId: $0.goalByTaskId
                )
            },
            childrenByCompoundId: childrenByCompoundId,
            tasksById: tasksById
        )

        // Auto targets pro-rate by the SOURCE window, looked up per supplied
        // id and per child of a compound member (never by the compound's own
        // id) — a caller that keys only the member ids silently gets no
        // pro-rating.
        var sourceWindowByTaskId: [String: BoardSources.BoardWindow] = [:]
        for supply in supplies {
            guard let sourceWindow = sourceBoardWindow[supply.source.sourceId] else { continue }
            for id in supply.supplyTaskIds {
                sourceWindowByTaskId[id] = sourceWindow
                for link in childrenByCompoundId[id] ?? [] {
                    sourceWindowByTaskId[link.childTaskId] = sourceWindow
                }
            }
        }

        return try planPlacements(
            db: db,
            selectedIds: selectedIds,
            supplies: supplies,
            manualTaskIds: manualTaskIds,
            manualTaskVary: manualTaskVary,
            window: window,
            // A repeating board never reaches here (its "Create Board"
            // persists a record and spawns), so this path is always one-off.
            mode: .oneOff,
            tasksById: tasksById,
            childrenByCompoundId: childrenByCompoundId,
            sourceWindowByTaskId: sourceWindowByTaskId,
            rng: rng
        )
    }
}
