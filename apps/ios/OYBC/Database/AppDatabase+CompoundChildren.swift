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

    /// Fetch all non-deleted recurring templates whose seedTaskIds contain the
    /// given taskId. Soft-deleted tasks are intentionally retained in
    /// seedTaskIds per the schema, so this query filters only on template
    /// isDeleted — not on the task's own deletion state.
    ///
    /// - Parameter taskId: The task ID to search for.
    /// - Returns: Non-deleted templates referencing the task.
    func fetchTemplatesReferencingTask(_ taskId: String) throws -> [RecurringBoardTemplate] {
        return try read { db in
            // Fetch all non-deleted templates, then filter in-process.
            // seedTaskIds is stored as a JSON string; LIKE '%taskId%' would
            // be a cheaper SQL predicate, but it risks false-positives on
            // UUID prefix collisions and is harder to read. The template
            // table is small (tens of rows per user), so in-process filter
            // is acceptable here.
            let all = try RecurringBoardTemplate
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            return all.filter { $0.seedTaskIds.contains(taskId) }
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

}
