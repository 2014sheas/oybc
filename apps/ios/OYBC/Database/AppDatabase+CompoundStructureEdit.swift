import Foundation
import GRDB

/// Compound-structure editing — sub-task CRUD for an existing compound
/// (the child Task rows + `compound_children` links), shared by the board
/// wizard's staged-edit apply (`saveWizardBoard` /
/// `writeWizardPendingTasksAndEnqueue`) and the Task Detail save
/// (`applyTaskEditPatch`). Split out of `AppDatabase+Boards.swift` (file-size
/// guardrail). Web twin: `apps/web/src/db/operations/compoundStructureEdit.ts`.
extension AppDatabase {
    /// Builds a fresh child Task row for a newly-added compound sub-task.
    private static func makeStagedChildTask(
        id: String, step: ChildPatch, title: String, userId: String, now: String
    ) -> Task {
        if step.isCounting {
            let action = step.action.trimmingCharacters(in: .whitespaces)
            let kind = step.countKind
            let unit = countKindNeedsUnit(kind) ? step.unit.trimmingCharacters(in: .whitespaces) : ""
            let goal = parseCountInput(step.goal, kind: kind) ?? 0
            var child = Task(
                id: id, userId: userId,
                title: TaskTitle.generateCounterTaskTitle(
                    action: action, maxCount: goal, unit: unit, providedTitle: title, countKind: kind
                ),
                type: .counting, action: action, unit: unit, maxCount: goal,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
            child.countKind = kind == .discrete ? nil : kind
            return child
        }
        return Task(
            id: id, userId: userId, title: title, type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    /// Applies a sub-task's edited fields onto its existing child Task (title,
    /// and for a counting sub-task the action/goal/unit + regenerated counting
    /// title). Returns the (possibly unchanged) task; caller bumps version if
    /// different.
    private static func applyStagedStepToChild(_ base: Task, step: ChildPatch, title: String) -> Task {
        var t = base
        if step.isCounting, base.type == .counting {
            let action = step.action.trimmingCharacters(in: .whitespaces)
            // An existing sub-task edits at its OWN kind (no picker).
            let kind = resolveCountKind(base.countKind)
            let unit = countKindNeedsUnit(kind) ? step.unit.trimmingCharacters(in: .whitespaces) : ""
            let goal = parseCountInput(step.goal, kind: kind) ?? base.maxCount ?? 0
            t.action = action; t.unit = unit; t.maxCount = goal
            t.title = TaskTitle.generateCounterTaskTitle(
                action: action, maxCount: goal, unit: unit, providedTitle: title, countKind: kind
            )
        } else {
            t.title = title
        }
        return t
    }

    /// Runs `CompoundChildEligibility.linkProblem` for every kept sub-task in
    /// `patch` that names an EXISTING task with no live link to `parentId` yet
    /// — i.e. a library task picked as a new sub-task. Kept = not marked
    /// deleted and not blank-titled (exactly what
    /// `applyStagedCompoundChildEdits` keeps). A task id missing from the DB
    /// is refused as deleted. Read-only. Web twin: `compoundLinkProblemForPatch`.
    ///
    /// - Parameters:
    ///   - db: An open GRDB connection (read or write).
    ///   - parentId: The compound being edited.
    ///   - patch: The staged / submitted compound patch.
    /// - Returns: The first user-facing problem, or nil when every new link is
    ///   eligible.
    static func compoundLinkProblem(db: Database, parentId: String, patch: TaskEditPatch) throws -> String? {
        let kept = patch.children.filter {
            !$0.markedDeleted
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.childTaskId != nil
        }
        guard !kept.isEmpty else { return nil }
        let allLinks = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let linkedHere = Set(allLinks.filter { $0.compoundTaskId == parentId }.map(\.childTaskId))
        for (i, step) in kept.enumerated() {
            guard let childId = step.childTaskId, !linkedHere.contains(childId) else { continue }
            // "Already a sub-task here" = any OTHER kept row names the same task.
            var others = Set<String>()
            for (j, other) in kept.enumerated() where j != i {
                if let id = other.childTaskId { others.insert(id) }
            }
            guard let candidate = try Task.fetchOne(db, key: childId) else {
                return CompoundChildEligibility.Message.deleted
            }
            if let problem = CompoundChildEligibility.linkProblem(
                parentId: parentId, candidate: candidate, allLinks: allLinks, currentChildIds: others
            ) {
                return problem
            }
        }
        return nil
    }

    /// Applies a compound patch's child edits to its `compound_children` links +
    /// child Task rows, inside an active write transaction. Called by
    /// `saveWizardBoard` for a staged compound edit (library or already-written
    /// pending compound). The parent Task itself is saved+cascaded by the caller
    /// AFTER this returns.
    ///
    /// Semantics (docs/INLINE_TASK_EDITING.md): a kept new sub-task mints a
    /// child Task + link; a kept existing sub-task edits its child Task
    /// GLOBALLY (with cascade) and reindexes its link to display order — or,
    /// for an existing library task picked as a sub-task (no link yet), mints
    /// its link at that position; a
    /// removed sub-task (deleted or blank-titled) soft-deletes the LINK only —
    /// the child Task survives (orphans acceptable). Sub-tasks render/persist
    /// in `patch.children` order.
    ///
    /// `scopeBoard` (Board Edit, the board wizard — docs/BOARD_SCOPED_TASK_EDITS.md
    /// §6) makes a changed existing sub-task BOARD-SCOPED: placed on any other
    /// board, it is forked (`ensureBoardScopedTask`) and the parent's link
    /// repointed to the fork, which takes the edit. nil = global (Task Detail,
    /// pool editor).
    static func applyStagedCompoundChildEdits(
        db: Database, parent: Task, patch: TaskEditPatch, now: String, scopeBoard: Board? = nil
    ) throws {
        let parentId = parent.id
        func readLinks() throws -> [CompoundChild] {
            try CompoundChild
                .filter(Column("compoundTaskId") == parentId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        var linkByChildId = Dictionary(try readLinks().map { ($0.childTaskId, $0) }, uniquingKeysWith: { a, _ in a })

        var keptChildIds = Set<String>()
        var displayIndex = 0
        for step in patch.children {
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Removed = explicitly deleted OR blank-titled ("dropped on save").
            guard !step.markedDeleted, !title.isEmpty else { continue }
            let index = displayIndex
            displayIndex += 1

            if step.isNew {
                let childId = AppDatabase.generateUUID()
                let child = makeStagedChildTask(id: childId, step: step, title: title, userId: parent.userId, now: now)
                try child.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks", entityId: childId, operationType: .create, payload: child, now: now
                ).enqueue(db)
                let link = CompoundChild(
                    id: AppDatabase.generateUUID(), compoundTaskId: parentId, childTaskId: childId,
                    childIndex: index, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                )
                try link.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "compoundChildren", entityId: link.id, operationType: .create, payload: link, now: now
                ).enqueue(db)
                keptChildIds.insert(childId)
            } else if var childId = step.childTaskId {
                // Child edit (rename / goal / unit) → save + cascade: global,
                // or — board-scoped — on a fork when placed on another board.
                var existingChild = try Task.fetchOne(db, key: childId)
                if let stored = existingChild {
                    let preview = applyStagedStepToChild(stored, step: step, title: title)
                    // `?? ""`: the editor round-trips an absent action/unit as
                    // "" — not a change (a picked unit-less counter stays untouched).
                    let changed = preview.title != stored.title
                        || (preview.action ?? "") != (stored.action ?? "")
                        || (preview.unit ?? "") != (stored.unit ?? "")
                        || preview.maxCount != stored.maxCount
                    if changed {
                        var scoped = BoardScopedTarget(targetId: childId, forked: false)
                        if let scopeBoard {
                            scoped = try ensureBoardScopedTask(
                                db: db, taskId: childId, board: scopeBoard, editedType: stored.type, now: now
                            )
                        }
                        var base = stored
                        if scoped.forked {
                            // The holder walk already repointed a placed
                            // parent's link; a parent not placed yet (the
                            // wizard) is repointed here.
                            try repointCompoundLink(
                                db: db, compoundId: parentId, oldChildId: childId, newChildId: scoped.targetId, now: now
                            )
                            linkByChildId = Dictionary(try readLinks().map { ($0.childTaskId, $0) }, uniquingKeysWith: { a, _ in a })
                            childId = scoped.targetId
                            base = try Task.fetchOne(db, key: childId) ?? stored
                            existingChild = base
                        }
                        var u = applyStagedStepToChild(base, step: step, title: title)
                        u.version += 1
                        u.updatedAt = now
                        try Self.saveTaskAndCascade(db: db, task: u)
                        try stampForkCaches(db: db, target: scoped, now: now)
                    }
                }
                keptChildIds.insert(childId)
                if linkByChildId[childId] == nil {
                    // An existing library task picked as a sub-task: it has no
                    // link to this compound yet, so mint one at its display
                    // position. Callers have already run
                    // `compoundLinkProblem(db:parentId:patch:)`; the live-row
                    // check here is defensive only (never link a missing /
                    // deleted task). The caller's parent cascade covers the
                    // parent's changed state.
                    if let existingChild, !existingChild.isDeleted {
                        let link = CompoundChild(
                            id: AppDatabase.generateUUID(), compoundTaskId: parentId, childTaskId: childId,
                            childIndex: index, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                            version: 1, isDeleted: false, deletedAt: nil
                        )
                        try link.save(db)
                        try SyncQueueBuilder.makeItem(
                            entityType: "compoundChildren", entityId: link.id, operationType: .create, payload: link, now: now
                        ).enqueue(db)
                    }
                } else if var link = linkByChildId[childId], link.childIndex != index {
                    // Reindex the link to display order if it moved.
                    link.childIndex = index
                    link.version += 1
                    link.updatedAt = now
                    try link.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "compoundChildren", entityId: link.id, operationType: .update, payload: link, now: now
                    ).enqueue(db)
                }
            }
        }

        // Soft-delete links whose child is no longer kept (link only — the child
        // Task stays in the library; orphans are acceptable per product decision).
        // Re-read: a board-scoped sub-task fork repointed links above.
        for link in try readLinks() where !keptChildIds.contains(link.childTaskId) {
            var l = link
            l.isDeleted = true
            l.deletedAt = now
            l.version += 1
            l.updatedAt = now
            try l.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "compoundChildren", entityId: l.id, operationType: .delete, payload: l, now: now
            ).enqueue(db)
        }
    }
}
