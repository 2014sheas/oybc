import Foundation
import GRDB

extension AppDatabase {
    // MARK: - CompoundChildren

    /// Fetch every non-deleted compound_children row in the workspace.
    /// Used by the derivation pass to find transitive parent compounds and
    /// build the childrenByCompound map fed into computeBoardStatsUpdate.
    func fetchAllCompoundChildren() throws -> [CompoundChild] {
        return try read { db in
            try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch the parent compound Tasks that reference the given task as a child
    /// (via non-deleted compound_children rows where childTaskId == taskId).
    /// Returns de-duplicated, non-deleted Task rows ordered by title.
    ///
    /// - Parameter taskId: The child task's ID.
    /// - Returns: Non-deleted compound Task rows that are parents of this task.
    func fetchCompoundParents(forTaskId taskId: String) throws -> [Task] {
        return try read { db in
            let links = try CompoundChild
                .filter(Column("childTaskId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            let parentIds = Array(Set(links.map { $0.compoundTaskId }))
            guard !parentIds.isEmpty else { return [] }
            return try Task
                .filter(parentIds.contains(Column("id")) && Column("isDeleted") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    /// Fetch the child Tasks of a compound, ordered by childIndex.
    /// Returns non-deleted Task rows only; soft-deleted children are excluded.
    ///
    /// - Parameter parentTaskId: The parent compound task's ID.
    /// - Returns: Child Task rows ordered by compound_children.childIndex.
    func fetchCompoundChildrenTasks(parentTaskId: String) throws -> [Task] {
        return try read { db in
            let links = try CompoundChild
                .filter(Column("compoundTaskId") == parentTaskId && Column("isDeleted") == false)
                .order(Column("childIndex"))
                .fetchAll(db)
            guard !links.isEmpty else { return [] }
            // Preserve the childIndex ordering: look up tasks and re-sort.
            let childIds = links.map { $0.childTaskId }
            let tasks = try Task
                .filter(childIds.contains(Column("id")) && Column("isDeleted") == false)
                .fetchAll(db)
            let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            return links.compactMap { taskById[$0.childTaskId] }
        }
    }

    /// Fetch every non-deleted repeating board that can pull the given task —
    /// Task Detail's "used in repeating boards" list (2026-09 audit T2).
    ///
    /// Membership is the shared `BoardSources.templateReferencesTask`: the
    /// task is in the record's hand-added layer, or in the available supply
    /// (raw supply − excludes) of any of its sources. Supplies come from the
    /// resolvers the spawn uses — pool: `BoardSources.poolSourceSupplyById`;
    /// board: the series-bound live instance via `fetchBoardSourceSupply` —
    /// with the done-filter and ranges deliberately NOT applied (a person
    /// deciding whether to edit/delete the task needs every board that could
    /// deal it) — by ruling, not omission. Split-up child tasks are NOT
    /// listed: only the source's own supply counts, so a compound member's
    /// parts (dealt via Split-up) don't list the board; the compound itself
    /// does. Web twin: `fetchTemplatesReferencingTask`.
    ///
    /// This used to match `seedTaskIds`, a creation-time snapshot the
    /// template edit path leaves stale — so a task removed in an edit stayed
    /// listed and a task added in an edit never appeared.
    ///
    /// Opens several reads (not one transaction): `fetchBoardSourceSupply`
    /// opens its own `read`, and nesting it would deadlock. Call off-main.
    ///
    /// - Parameter taskId: The task ID to search for.
    /// - Returns: Non-deleted templates referencing the task.
    /// - Throws: A GRDB error from any of the reads.
    func fetchTemplatesReferencingTask(_ taskId: String) throws -> [RecurringBoardTemplate] {
        let templates = try read { db in
            try RecurringBoardTemplate
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
        }
        guard !templates.isEmpty else { return [] }
        let sources = templates.flatMap { t in
            BoardSources.sourcesForRecord(
                sources: t.sources, poolIds: t.poolIds, removedTaskIds: t.removedTaskIds
            )
        }

        var poolIds: [String] = []
        var boardIds: [String] = []
        for source in sources {
            switch source.kind {
            case .pool where !poolIds.contains(source.sourceId): poolIds.append(source.sourceId)
            case .board where !boardIds.contains(source.sourceId): boardIds.append(source.sourceId)
            default: break
            }
        }
        let pools = try fetchPools(ids: poolIds)
        let poolsById = Dictionary(pools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let members = try fetchTasks(ids: Array(Set(pools.flatMap { $0.taskIds })))
        let tasksById = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var suppliesBySourceId: [String: [String]] = [:]
        for poolId in poolIds {
            suppliesBySourceId[poolId] = BoardSources.poolSourceSupplyById(
                poolId, poolsById: poolsById, tasksById: tasksById
            )
        }
        for boardId in boardIds {
            suppliesBySourceId[boardId] = try fetchBoardSourceSupply(boardId: boardId)?.supplyTaskIds ?? []
        }

        return templates.filter {
            BoardSources.templateReferencesTask($0, taskId: taskId, suppliesBySourceId: suppliesBySourceId)
        }
    }

    /// Fetch all non-deleted compound_children rows for a single parent compound,
    /// ordered by childIndex.
    ///
    /// - Parameter compoundTaskId: The parent compound task's ID.
    /// - Returns: All matching children ordered by `childIndex`.
    func fetchCompoundChildren(compoundTaskId: String) throws -> [CompoundChild] {
        return try read { db in
            try CompoundChild
                .filter(Column("compoundTaskId") == compoundTaskId && Column("isDeleted") == false)
                .order(Column("childIndex"))
                .fetchAll(db)
        }
    }

    /// Batched twin of ``fetchCompoundChildren(compoundTaskId:)`` — the live
    /// `compound_children` rows of MANY parents in one query, grouped by
    /// parent and ordered by `childIndex` within each group.
    ///
    /// Board Sources §Member rules (B2): the wizard mint needs the children of
    /// every compound the plan can name (placed ones, whose parts a One-square
    /// rule re-targets, and supplied ones, which a Split-up rule expands), and
    /// issuing one query per compound inside the board-save transaction is the
    /// n+1 this replaces. An empty `compoundTaskIds` reads nothing.
    ///
    /// `static` + `db`-taking (unlike its single-parent sibling, which opens
    /// its own `read`) because every caller is already inside an open write
    /// transaction — a nested `read` on the same `DatabaseQueue` is reentrant
    /// and would deadlock.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - compoundTaskIds: The parent compound ids to fetch children for.
    /// - Returns: Parent compound id → its live children, ordered by
    ///   `childIndex`. Parents with no live children are absent from the map.
    static func fetchCompoundChildren(
        db: Database,
        compoundTaskIds: [String]
    ) throws -> [String: [CompoundChild]] {
        guard !compoundTaskIds.isEmpty else { return [:] }
        let rows = try CompoundChild
            .filter(compoundTaskIds.contains(Column("compoundTaskId")) && Column("isDeleted") == false)
            .order(Column("childIndex"))
            .fetchAll(db)
        var byCompound: [String: [CompoundChild]] = [:]
        for row in rows { byCompound[row.compoundTaskId, default: []].append(row) }
        return byCompound
    }

    /// Board Sources §Member rules (B3) — the live children of whichever of
    /// `candidateTaskIds` are COMPOUND tasks, in ONE read transaction (two
    /// queries: the type filter, then the batched children fetch). The
    /// wizard's Split-up expansion asks this of a source's whole raw supply,
    /// where most ids are not compounds at all.
    ///
    /// - Parameter candidateTaskIds: Ids that MIGHT be compounds (a source's
    ///   raw supply). Empty reads nothing.
    /// - Returns: Compound task id → its live children, ordered by
    ///   `childIndex`. Non-compound / soft-deleted ids are absent.
    func fetchCompoundChildren(
        forCandidateTaskIds candidateTaskIds: [String]
    ) throws -> [String: [CompoundChild]] {
        guard !candidateTaskIds.isEmpty else { return [:] }
        return try read { db in
            let compoundIds = try Task
                .filter(candidateTaskIds.contains(Column("id")) && Column("isDeleted") == false)
                .fetchAll(db)
                .filter { $0.type == .compound }
                .map { $0.id }
            return try Self.fetchCompoundChildren(db: db, compoundTaskIds: compoundIds)
        }
    }

    /// Inputs for the compound editor's sub-task quick-add row, read in one
    /// snapshot: the user's browsable library (`BrowsableTasks.computeBrowsableTasks`
    /// — hides wizard drafts, goal-less hub counters and shared-counter
    /// members, exactly like the Tasks tab) and every live link under one of
    /// the user's compounds (the loop check's graph; scoped so another
    /// account's rows on this device never leak in). Twin of web
    /// `TaskEditSheet`'s `loadPickerInputs`.
    ///
    /// - Parameter userId: The signed-in user.
    /// - Returns: The browsable library tasks and live links.
    /// - Throws: A GRDB error if the read fails.
    func fetchCompoundPickerInputs(userId: String) throws -> (libraryTasks: [Task], allLinks: [CompoundChild]) {
        try read { db in
            let tasks = try Task
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
            let compoundIds = Set(tasks.filter { $0.type == .compound }.map(\.id))
            let links = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
                .filter { compoundIds.contains($0.compoundTaskId) }
            let boardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
            let boards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
            let boardStatusById = Dictionary(boards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            var childToParents: [String: [String]] = [:]
            for l in links { childToParents[l.childTaskId, default: []].append(l.compoundTaskId) }
            let browsable = BrowsableTasks.computeBrowsableTasks(
                tasks: tasks,
                boardTasks: boardTasks,
                boardStatusById: boardStatusById,
                childToParents: childToParents
            )
            return (browsable, links)
        }
    }
}
