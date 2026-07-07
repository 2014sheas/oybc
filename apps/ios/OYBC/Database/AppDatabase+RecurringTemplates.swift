import Foundation
import GRDB

extension AppDatabase {
    // MARK: - RecurringBoardTemplates (Phase 6.2)

    /// Fetch all non-deleted templates for a user, ordered by `updatedAt desc`.
    func fetchRecurringBoardTemplates(userId: String) throws -> [RecurringBoardTemplate] {
        return try read { db in
            try RecurringBoardTemplate
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single template by id (including soft-deleted, for completeness).
    func fetchRecurringBoardTemplate(id: String) throws -> RecurringBoardTemplate? {
        return try read { db in
            try RecurringBoardTemplate.fetchOne(db, key: id)
        }
    }

    /// Insert / update a template. The caller is responsible for bumping
    /// `version` and `updatedAt` (mirror of `saveBoard`).
    func saveRecurringBoardTemplate(_ template: RecurringBoardTemplate) throws {
        try write { db in
            try template.save(db)
        }
    }

    /// Soft-delete a template. Spawned boards remain — they're independent
    /// once spawned (per Phase 6.2 design). Bumps `version` so LWW treats
    /// the deletion as later-wins.
    func softDeleteRecurringBoardTemplate(id: String) throws {
        try write { db in
            guard var template = try RecurringBoardTemplate.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            template.isDeleted = true
            template.deletedAt = now
            template.updatedAt = now
            template.version += 1
            try template.update(db)
        }
    }

    // MARK: - Atomic save + sync-enqueue (templates & pools)
    //
    // Mirror of `saveTaskAndEnqueueUpdate`: the model write and its
    // sync-queue item live in ONE transaction so a crash between them
    // can't leave the local row ahead of Firestore with no recovery.

    /// Save a template and enqueue its sync op atomically. The caller
    /// bumps `version`/`updatedAt` before calling; `operation` is
    /// `.create` for the first save, `.update` thereafter.
    func saveRecurringBoardTemplateAndEnqueue(
        _ template: RecurringBoardTemplate,
        operation: SyncOperationType,
        now: String
    ) throws {
        try write { db in
            try template.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: template.id,
                operationType: operation,
                payload: template,
                now: now
            ).save(db)
        }
    }

    /// Soft-delete a template and enqueue the delete op atomically.
    func softDeleteRecurringBoardTemplateAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var t = try RecurringBoardTemplate.fetchOne(db, key: id) else { return }
            t.isDeleted = true
            t.deletedAt = now
            t.updatedAt = now
            t.version += 1
            try t.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: t.id,
                operationType: .delete,
                payload: t,
                now: now
            ).save(db)
        }
    }

}
