import Foundation
import GRDB

/// Per-cell placement for the wizard's preview grid and the persisted
/// `BoardTask` rows. `nil` slots only appear at the reserved centre
/// cell for FREE / CUSTOM_FREE centre types. Mirrors web's
/// `WizardPlacement`.
typealias WizardPlacement = [Task?]

/// Builds the persisted `BoardTask` rows for a board from a wizard placement.
///
/// `isCenter` is TRUE **only** for a `.chosen` centre task. FREE / CUSTOM_FREE
/// centres have a `nil` placement slot (so no row is produced), and a `.none`
/// centre holds an ordinary task that must render as a normal square — so it is
/// NOT flagged. Marking a `.none` centre `isCenter` makes the play grid render
/// a gold "FREE" cell over a real task (the preview never did, because it gates
/// on `centreType != .none`). This helper is the single source of truth shared
/// by the wizard-save and recurring-spawn paths so the rule can't diverge.
func makeWizardBoardTaskRows(
    placement: WizardPlacement,
    boardId: String,
    size: Int,
    centerType: CenterSquareType,
    now: String
) -> [BoardTask] {
    let isOdd = size % 2 != 0
    let centerRow = size / 2
    let centerCol = size / 2
    var rows: [BoardTask] = []
    for (i, slot) in placement.enumerated() {
        guard let task = slot else { continue }
        let row = i / size
        let col = i % size
        let isCenterPos = isOdd && row == centerRow && col == centerCol
        rows.append(BoardTask(
            id: AppDatabase.generateUUID(),
            boardId: boardId,
            taskId: task.id,
            row: row,
            col: col,
            isCenter: isCenterPos && centerType == .chosen,
            createdAt: now,
            updatedAt: now,
            version: 1
        ))
    }
    return rows
}

/// The pending (deferred-persist, Bug #85) payloads that should actually be
/// written when saving a board: only those whose task is placed on the board.
///
/// A task removed from the wizard pool can linger in `pendingTasks` (removal
/// only updates the selection binding). Without this guard it would be written
/// as an orphan `createdInWizard` Task row with no placement — which then leaks
/// into the library (a wizard-orphan with no live placement is browsable) and
/// reappears on draft resume.
func pendingPayloadsToPersist(
    pending: [String: PendingTaskPayload],
    placedTaskIds: Set<String>
) -> [PendingTaskPayload] {
    pending.values.filter { placedTaskIds.contains($0.task.id) }
}

/// Resolution result for the wizard's start/end dates. Mirrors web's
/// `ResolvedDates` discriminated union.
enum ResolvedWizardDates {
    /// `end` is nil for INDEFINITE boards (no deadline).
    case ok(start: String, end: String?)
    case error(String)
}

enum WizardStatus: String {
    case active
    case draft
}

/// Builds the full placement array for the wizard's current selection +
/// geometry. Used as the single source of truth for both the preview
/// grid and the `saveBoardTask` calls so what the user sees and what
/// gets persisted are identical. iOS twin of web's
/// `buildWizardPlacement`.
///
/// Bug #85 — pending tasks (in `controller.pendingTasks`) are merged into
/// the candidate pool so newly-created (not-yet-persisted) tasks appear
/// in the preview and placement just like library tasks.
func buildWizardPlacement(
    controller: BoardWizardViewModel,
    library: TaskLibraryViewModel
) -> WizardPlacement {
    let size = controller.size
    let isOdd = size % 2 != 0

    // Merge pending tasks with the live library so both appear in the grid.
    // Build a combined id → Task map; pending wins on collision (shouldn't
    // occur, but defensive). Then resolve selectedTaskIds against it.
    var taskById: [String: Task] = Dictionary(
        uniqueKeysWithValues: library.libraryTasks.map { ($0.id, $0) }
    )
    for payload in controller.pendingTasks.values {
        taskById[payload.task.id] = payload.task
    }

    let selected = controller.selectedTaskIds.compactMap { taskById[$0] }

    let chosenCenter: Task? = {
        guard isOdd, controller.centerType == .chosen, let id = controller.centerTaskId else {
            return nil
        }
        return selected.first(where: { $0.id == id })
    }()
    // When isRandomized is false (e.g. snapshot tests pin this for
    // deterministic baselines), sort by task id so Swift's non-deterministic
    // Set iteration order doesn't reshuffle the grid across process restarts.
    // Pre-sort here and pass `randomize: false` so the shared core preserves
    // the order verbatim; the randomized path lets the core shuffle. Center
    // handling + the cell walk are the shared placement math
    // (BoardPlacement.placeBoard — the Swift mirror of bingo-core `placeBoard`).
    let ordered: [Task] = controller.isRandomized
        ? selected
        : selected.sorted { $0.id < $1.id }

    return BoardPlacement.placeBoard(
        items: ordered,
        gridSize: size,
        centerType: isOdd ? controller.centerType : .none,
        chosenCenterId: chosenCenter?.id,
        randomize: controller.isRandomized
    )
}

/// Resolves local-ISO start/end strings for the wizard's current
/// timeframe. Non-custom timeframes use `computeTimeframeBoundaries`;
/// custom timeframes require non-empty `customStartDate` /
/// `customEndDate` and validate the range. Mirrors web's
/// `resolveWizardDates`.
func resolveWizardDates(controller: BoardWizardViewModel) -> ResolvedWizardDates {
    // Indefinite boards have no deadline. Honor the chosen Start date (the
    // Custom section's Start picker is shown for ongoing boards too) — it's
    // the creation anchor + lower bound for achievement windows; fall back to
    // today when unset. End stays nil so the board carries no endDate.
    if controller.timeframe == .indefinite {
        let startDate: Date
        if !controller.customStartDate.isEmpty,
           let s = parseWizardCalendarDate(controller.customStartDate) {
            startDate = Calendar.current.startOfDay(for: s)
        } else {
            startDate = Calendar.current.startOfDay(for: Date())
        }
        return .ok(start: wizardLocalISOString(startDate), end: nil)
    }
    if controller.timeframe != .custom {
        guard let b = controller.computedBoundaries else {
            return .error("Could not resolve timeframe boundaries.")
        }
        return .ok(start: wizardLocalISOString(b.start), end: wizardLocalISOString(b.end))
    }
    guard !controller.customStartDate.isEmpty,
          !controller.customEndDate.isEmpty,
          let s = parseWizardCalendarDate(controller.customStartDate),
          let e = parseWizardCalendarDate(controller.customEndDate)
    else {
        return .error("Pick a start and end date.")
    }
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: s)
    let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e))!
    let dayEnd = nextDay.addingTimeInterval(-0.001)
    if dayEnd < dayStart {
        return .error("End date must be on or after the start date.")
    }
    return .ok(start: wizardLocalISOString(dayStart), end: wizardLocalISOString(dayEnd))
}

/// Writes the wizard's state to GRDB.
///
/// - **Fresh create** (`draftBoardId` nil): inserts a new `Board`
///   (`status=active` or `status=draft`) plus per-cell `BoardTask`
///   rows in a single transaction. Version always starts at 1.
/// - **Draft update** (`draftBoardId` set): updates the existing
///   `Board` with new field values + target status (version bump
///   via `saveBoard`), hard-deletes all of its `BoardTask` rows, then
///   inserts the new placement.
///
/// Runs on a background queue; dispatches the provided callbacks on
/// the main queue. Callers should already have validated
/// `resolveWizardDates` before invoking this.
func persistWizardBoard(
    controller: BoardWizardViewModel,
    userId: String,
    placement: WizardPlacement,
    dates: (start: String, end: String?),
    status: WizardStatus,
    onSuccess: @escaping (_ boardId: String) -> Void,
    onError: @escaping (_ message: String) -> Void
) {
    let trimmedName = controller.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let size = controller.size
    let centerType = controller.centerType
    let customCenterName: String? = centerType == .customFree
        ? controller.centerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
    let chosenCenterId: String? = centerType == .chosen ? controller.centerTaskId : nil
    let draftBoardId = controller.draftBoardId
    let now = AppDatabase.currentTimestamp()
    let boardId = draftBoardId ?? AppDatabase.generateUUID()
    let boardStatusRaw = status == .active ? "active" : "draft"
    let capturedTimeframe = controller.timeframe
    let capturedIsRandomized = controller.isRandomized
    // Bug #85 — snapshot the pending tasks dictionary from the controller
    // before going async so we don't race against concurrent mutations on
    // the main actor. Dictionary is a value type (copy-on-write) so this
    // is a safe O(n) snapshot.
    let capturedPendingTasks = controller.pendingTasks

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let isUpdate = draftBoardId != nil
            let existing: Board? = isUpdate ? try AppDatabase.shared.fetchBoard(id: boardId) : nil

            // Preserve denormalised stats if updating — a draft should
            // never overwrite `completedTasks` / `linesCompleted` /
            // `completedLineIds` it inherited from a partially-activated
            // parent. For new boards these default to 0 / 0 / empty.
            var boardDict: [String: Any] = [
                "id": boardId,
                "userId": userId,
                "name": trimmedName,
                "status": boardStatusRaw,
                "boardSize": size,
                "timeframe": capturedTimeframe.rawValue,
                "startDate": dates.start,
                "centerSquareType": centerType.rawValue,
                "isRandomized": capturedIsRandomized,
                "totalTasks": size * size,
                "completedTasks": existing?.completedTasks ?? 0,
                "linesCompleted": existing?.linesCompleted ?? 0,
                "createdAt": existing?.createdAt ?? now,
                "updatedAt": now,
                "version": (existing?.version ?? 0) + 1,
                "isDeleted": false,
                // Phase 6.1 core-board marker. Preserve existing draft's
                // marker on update; for fresh creates, take it from the
                // controller (set true when the wizard was launched from
                // the recurring banner). Falls back to false for manual
                // Create-tab opens.
                "isCore": existing?.isCore ?? controller.isCore,
            ]
            // Omit endDate entirely for indefinite boards (nil) so the row and
            // its Firestore doc carry no deadline at all — no sentinel.
            if let end = dates.end {
                boardDict["endDate"] = end
            }
            if let name = customCenterName, !name.isEmpty {
                boardDict["centerSquareCustomName"] = name
            }
            if let id = chosenCenterId {
                boardDict["centerTaskId"] = id
            }

            let boardData = try JSONSerialization.data(withJSONObject: boardDict)
            let board = try JSONDecoder().decode(Board.self, from: boardData)

            let boardTasks = makeWizardBoardTaskRows(
                placement: placement,
                boardId: boardId,
                size: size,
                centerType: centerType,
                now: now
            )
            // Only persist deferred (Bug #85) tasks that are actually placed —
            // a task removed from the pool lingers in `pendingTasks` and must
            // not be written as an orphan Task row (see pendingPayloadsToPersist).
            let placedTaskIds = Set(boardTasks.map { $0.taskId })
            let pendingToPersist = pendingPayloadsToPersist(
                pending: capturedPendingTasks,
                placedTaskIds: placedTaskIds
            )

            // Single atomic transaction: writing pending new tasks, then
            // the board record + its BoardTask rows — plus all matching
            // SyncQueueItem records — must commit or roll back together.
            // Without the sync items the board stays local-only
            // (SyncService.pushSync reads exclusively from sync_queue),
            // so every write path below enqueues one.
            //
            // Bug #85: pending tasks are written FIRST (before board_tasks)
            // so the referential integrity of task → board_task is never
            // violated even during a crash mid-write (the txn rolls back).
            try AppDatabase.shared.write { db in
                // ── Bug #85: pending tasks (placed-only) ───────────────
                for payload in pendingToPersist {
                    try payload.task.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "tasks",
                        entityId: payload.task.id,
                        operationType: .create,
                        payload: payload.task,
                        now: now
                    ).save(db)
                    for childTask in payload.childTasks {
                        try childTask.save(db)
                        try SyncQueueBuilder.makeItem(
                            entityType: "tasks",
                            entityId: childTask.id,
                            operationType: .create,
                            payload: childTask,
                            now: now
                        ).save(db)
                    }
                    for link in payload.childLinks {
                        try link.save(db)
                        try SyncQueueBuilder.makeItem(
                            entityType: "compoundChildren",
                            entityId: link.id,
                            operationType: .create,
                            payload: link,
                            now: now
                        ).save(db)
                    }
                }

                // ── Board + BoardTask rows ─────────────────────────────
                try board.save(db)

                let boardSyncOp: SyncOperationType = isUpdate ? .update : .create
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: boardId,
                    operationType: boardSyncOp,
                    payload: board,
                    now: now
                ).save(db)

                if isUpdate {
                    // Snapshot the existing BoardTasks before deleting
                    // so each gets a matching DELETE sync item whose
                    // payload reflects the row that actually existed.
                    let oldBoardTasks = try BoardTask
                        .filter(Column("boardId") == boardId)
                        .fetchAll(db)
                    _ = try BoardTask
                        .filter(Column("boardId") == boardId)
                        .deleteAll(db)
                    for old in oldBoardTasks {
                        try SyncQueueBuilder.makeItem(
                            entityType: "boardTasks",
                            entityId: old.id,
                            operationType: .delete,
                            payload: old,
                            now: now
                        ).save(db)
                    }
                }

                for bt in boardTasks {
                    try bt.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: bt.id,
                        operationType: .create,
                        payload: bt,
                        now: now
                    ).save(db)
                }
            }

            DispatchQueue.main.async { onSuccess(boardId) }
        } catch {
            DispatchQueue.main.async {
                onError(error.localizedDescription)
            }
        }
    }
}

/// Outcome of `persistRecurringTemplate`.
enum RecurringTemplatePersistOutcome {
    /// Fresh template created and the current window's board was spawned
    /// inline. `boardId` is the spawned board for cross-tab navigation.
    case createdAndSpawned(templateId: String, boardId: String)
    /// Fresh template created but the spawn was skipped (validation
    /// failure — e.g. a seed task got soft-deleted between save and
    /// spawn). The template is intact and the Boards-tab spawn driver
    /// will retry on next open. `reason` surfaces in the UI.
    case createdSpawnSkipped(templateId: String, reason: SpawnAttentionReason)
    /// Existing template was updated (no spawn). `templateId` for any
    /// follow-up navigation.
    case updated(templateId: String)
}

/// Persist path for `controller.isRecurring == true`. iOS twin of web
/// `persistRecurringTemplate`.
///
/// Branches on `editingTemplateId`:
///
/// - **Fresh create** (no `editingTemplateId`): inserts the
///   `RecurringBoardTemplate` row, then immediately spawns the current
///   window's board via `RecurringBoardSpawn.spawnTemplateBoard`. The
///   two writes are sequential GRDB transactions; if the spawn fails
///   (e.g. soft-deleted task race), the template still exists with
///   `lastSpawnedWindowKey=nil` and the next Boards-tab open will retry.
/// - **Edit** (`editingTemplateId` set): updates the template via a
///   direct `saveRecurringBoardTemplate`. Does NOT spawn — edits don't
///   retroactively change previously-spawned boards.
///
/// Runs on a background queue; dispatches callbacks on the main queue.
func persistRecurringTemplate(
    controller: BoardWizardViewModel,
    userId: String,
    onSuccess: @escaping (RecurringTemplatePersistOutcome) -> Void,
    onError: @escaping (_ message: String) -> Void
) {
    let trimmedName = controller.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeframe = controller.timeframe
    let boardSize = controller.size
    let centerType = controller.centerType
    let customCenterName: String? = centerType == .customFree
        ? controller.centerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
    let isRandomized = controller.isRandomized
    let seedTaskIds = Array(controller.selectedTaskIds)
    let editingTemplateId = controller.editingTemplateId
    let weekStartDay = controller.weekStartDay
    let now = AppDatabase.currentTimestamp()

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            // ── Edit path ─────────────────────────────────────────────
            if let templateId = editingTemplateId {
                guard let existing = try AppDatabase.shared.fetchRecurringBoardTemplate(id: templateId) else {
                    DispatchQueue.main.async {
                        onError("Template no longer exists.")
                    }
                    return
                }
                let updated = RecurringBoardTemplate(
                    id: existing.id,
                    userId: existing.userId,
                    name: trimmedName,
                    timeframe: timeframe,
                    boardSize: boardSize,
                    centerSquareType: centerType,
                    centerSquareCustomName: customCenterName,
                    isRandomized: isRandomized,
                    seedTaskIds: seedTaskIds,
                    // `isActive` isn't surfaced in the wizard form (the
                    // templates list owns the pause toggle), so preserve.
                    lastSpawnedWindowKey: existing.lastSpawnedWindowKey,
                    isActive: existing.isActive,
                    createdAt: existing.createdAt,
                    updatedAt: now,
                    lastSyncedAt: existing.lastSyncedAt,
                    version: existing.version + 1,
                    isDeleted: false,
                    deletedAt: nil
                )
                try AppDatabase.shared.saveRecurringBoardTemplate(updated)
                try AppDatabase.shared.write { db in
                    try SyncQueueBuilder.makeItem(
                        entityType: "recurringBoardTemplates",
                        entityId: updated.id,
                        operationType: .update,
                        payload: updated,
                        now: now
                    ).save(db)
                }
                DispatchQueue.main.async { onSuccess(.updated(templateId: updated.id)) }
                return
            }

            // ── Fresh-create path ─────────────────────────────────────
            let template = RecurringBoardTemplate(
                id: AppDatabase.generateUUID(),
                userId: userId,
                name: trimmedName,
                timeframe: timeframe,
                boardSize: boardSize,
                centerSquareType: centerType,
                centerSquareCustomName: customCenterName,
                isRandomized: isRandomized,
                seedTaskIds: seedTaskIds,
                lastSpawnedWindowKey: nil,
                isActive: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try AppDatabase.shared.saveRecurringBoardTemplate(template)
            try AppDatabase.shared.write { db in
                try SyncQueueBuilder.makeItem(
                    entityType: "recurringBoardTemplates",
                    entityId: template.id,
                    operationType: .create,
                    payload: template,
                    now: now
                ).save(db)
            }

            // Compute spawn window + spawn. Mirrors web's
            // `persistRecurringTemplate` second-step. Reference date
            // honours `controller.targetWindowDate` so the core-board
            // browser can pre-spawn a future window's first board.
            guard let window = computeTimeframeBoundaries(
                timeframe: timeframe,
                referenceDate: controller.targetWindowDate ?? Date(),
                weekStartDay: weekStartDay
            ) else {
                // Computed-window failure for a recurring timeframe
                // shouldn't happen in practice (the form excludes
                // CUSTOM); template is saved either way, surface a
                // meaningful skip outcome.
                DispatchQueue.main.async {
                    onSuccess(.createdSpawnSkipped(
                        templateId: template.id,
                        reason: .unsupportedTimeframe
                    ))
                }
                return
            }

            let spawn = PendingTemplateSpawn(
                template: template,
                windowStart: wizardLocalISOString(window.start),
                windowEnd: wizardLocalISOString(window.end),
                suggestedName: deriveSpawnedBoardName(template: template, windowStart: wizardLocalISOString(window.start))
            )
            let outcome = try RecurringBoardSpawn.spawnTemplateBoard(spawn)
            switch outcome {
            case .spawned(let boardId, _, _):
                DispatchQueue.main.async {
                    onSuccess(.createdAndSpawned(templateId: template.id, boardId: boardId))
                }
            case .skipped(_, let reason):
                DispatchQueue.main.async {
                    onSuccess(.createdSpawnSkipped(templateId: template.id, reason: reason))
                }
            }
        } catch {
            DispatchQueue.main.async {
                onError(error.localizedDescription)
            }
        }
    }
}
