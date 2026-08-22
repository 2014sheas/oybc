import Foundation
import GRDB

/// Per-cell placement for the wizard's preview grid and the persisted
/// `BoardTask` rows. `nil` slots only appear at the reserved centre
/// cell for a FREE centre type. Mirrors web's `WizardPlacement`.
typealias WizardPlacement = [Task?]

/// Builds the persisted `BoardTask` rows for a board from a wizard placement.
///
/// `isCenter` is TRUE **only** for a `.chosen` centre task. A FREE centre has
/// a `nil` placement slot (so no row is produced), and a `.none`
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

/// Windowed "done" for a wizard-preview cell, resolved against the
/// PROSPECTIVE board's window (`[resolveWizardDates(...).start, ∞)`) — never
/// the task's lifetime cache. A shared library task completed in a PREVIOUS
/// window must preview grey on the new board, exactly as it will render after
/// Save (the "green squares from previous windows" bug).
///
/// Branch order mirrors web `taskToSquareState` (and the play surfaces):
/// compound → windowed `CompoundEvaluation`; derived (shared-counter-linked)
/// counting → lifetime carve-out; event-owning primitives → windowed events.
/// Achievements aren't placeable via the wizard, so no kernel cell-state is
/// needed here. Pinned by `WizardPreviewCompletionTests`.
func wizardPreviewIsCompleted(
    task: Task,
    taskById: [String: Task],
    childrenByCompound: [String: [CompoundChild]],
    eventsByTaskId: [String: [TaskEvent]],
    windowStart: String
) -> Bool {
    if task.type == .compound {
        return CompoundEvaluation.evaluate(
            compound: task,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            windowContext: CompoundWindowContext(
                windowStart: windowStart,
                eventsByTaskId: eventsByTaskId
            )
        )
    }
    guard isEventOwningTask(task) else { return task.isCompleted }
    return resolveTaskWindowState(
        task: task,
        events: eventsByTaskId[task.id] ?? [],
        windowStart: windowStart
    ).isCompleted
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
    // Overlay staged inline edits (Inline Task Editing) so the Step 3 preview
    // grid + summary reflect unsaved renames/goal changes — matching Step 2's
    // pool rows. The DB is untouched until create; the real patch is applied in
    // saveWizardBoard's transaction.
    for (id, patch) in controller.stagedEdits {
        if let base = taskById[id], patch.validate(type: base.type) == nil {
            taskById[id] = patch.applied(to: base)
        }
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

/// Merges `library.compoundChildrenByCompound` with any deferred (Bug #85)
/// pending compound's child links AND staged inline-editor child edits
/// (Inline Task Editing) — the single source of truth for "how many
/// sub-tasks does this compound have right now" across the wizard's Tasks
/// step pool subtitle (`RisoPoolListView`) and the Preview step's windowed-
/// completion evaluation (`wizardPreviewIsCompleted`).
///
/// A staged edit's KEPT sub-tasks (`TaskEditPatch.liveChildren` — non-deleted,
/// non-blank) replace the base entry with synthesized `CompoundChild` rows in
/// draft order. A brand-new sub-task (no real `childTaskId` yet, `isNew ==
/// true`) gets a synthetic id (`"staged-child-<patchChildId>"`) so it still
/// counts toward "N sub-tasks" — pair with `stagedNewChildPlaceholders(...)`
/// below so type-dependent reads (the "N with a goal" subcount, windowed
/// completion) can resolve it. A not-yet-persisted child trivially evaluates
/// as incomplete (no events exist for it yet), which is correct: it can't
/// have contributed to any past completion.
func effectiveCompoundChildrenByCompound(
    library: TaskLibraryViewModel,
    pendingTasks: [String: PendingTaskPayload],
    stagedEdits: [String: TaskEditPatch]
) -> [String: [CompoundChild]] {
    var merged = library.compoundChildrenByCompound
    for payload in pendingTasks.values where !payload.childLinks.isEmpty {
        merged[payload.task.id] = payload.childLinks
    }
    guard !stagedEdits.isEmpty else { return merged }
    let now = AppDatabase.currentTimestamp()
    for (taskId, patch) in stagedEdits {
        let kept = patch.liveChildren
        guard !kept.isEmpty else { continue }
        merged[taskId] = kept.enumerated().map { index, child in
            CompoundChild(
                id: "staged-\(taskId)-\(child.id)",
                compoundTaskId: taskId,
                childTaskId: child.childTaskId ?? "staged-child-\(child.id)",
                childIndex: index,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
        }
    }
    return merged
}

/// Synthesizes placeholder `Task` entries for brand-new staged compound
/// sub-tasks (no real Task row yet — `ChildPatch.isNew`), keyed by the same
/// synthetic id `effectiveCompoundChildrenByCompound` uses for their
/// `childTaskId` (`"staged-child-<patchChildId>"`), so a type-dependent
/// lookup (`effectiveTaskById[childTaskId]?.type == .counting`) resolves
/// correctly for a sub-task that only exists in the draft so far.
func stagedNewChildPlaceholders(
    userId: String,
    stagedEdits: [String: TaskEditPatch]
) -> [String: OYBC.Task] {
    guard !stagedEdits.isEmpty else { return [:] }
    let now = AppDatabase.currentTimestamp()
    var placeholders: [String: OYBC.Task] = [:]
    for patch in stagedEdits.values {
        for child in patch.liveChildren where child.isNew {
            let id = "staged-child-\(child.id)"
            placeholders[id] = OYBC.Task(
                id: id,
                userId: userId,
                title: child.title,
                type: child.isCounting ? .counting : .normal,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
        }
    }
    return placeholders
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
///   via `saveBoard`), soft-deletes (tombstones) all of its existing
///   `BoardTask` rows, then inserts the new placement.
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
    let chosenCenterId: String? = centerType == .chosen ? controller.centerTaskId : nil
    let draftBoardId = controller.draftBoardId
    let now = AppDatabase.currentTimestamp()
    let boardId = draftBoardId ?? AppDatabase.generateUUID()
    let boardStatusRaw = status == .active ? "active" : "draft"
    let capturedTimeframe = controller.timeframe
    let capturedIsRandomized = controller.isRandomized
    // Board Creation Split (PR B) — snapshot the recurring pool-mix state
    // alongside the other value-type captures below, so a recurring
    // draft's `recurringDraftMix` reflects exactly what the user had
    // selected at Save time (never a later in-session mutation).
    let capturedIsRecurring = controller.isRecurring
    let capturedPulledPoolIds = controller.pulledPoolIds
    let capturedManualTaskIds = controller.manualTaskIds
    let capturedRemovedTaskIds = controller.removedTaskIds
    // Bug #85 — snapshot the pending tasks dictionary from the controller
    // before going async so we don't race against concurrent mutations on
    // the main actor. Dictionary is a value type (copy-on-write) so this
    // is a safe O(n) snapshot.
    let capturedPendingTasks = controller.pendingTasks
    // Inline Task Editing — snapshot staged edits alongside pending tasks
    // (value types, safe O(n) copy) so the async write applies them atomically.
    let capturedStagedEdits = controller.stagedEdits

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
                // Preserve an existing board's tombstone state rather than
                // hardcoding false — a wizard resume/update save must not
                // silently resurrect + re-push a board that was soft-deleted
                // elsewhere (e.g. from the Boards tab on another device)
                // while this draft was open. Fresh creates (existing == nil)
                // are always isDeleted=false/deletedAt=nil.
                "isDeleted": existing?.isDeleted ?? false,
                // Phase 6.1 core-board marker. Preserve existing draft's
                // marker on update; for fresh creates, take it from the
                // controller (set true when the wizard was launched from
                // the recurring banner). Falls back to false for manual
                // Create-tab opens.
                "isCore": existing?.isCore ?? controller.isCore,
                // Board Creation Split (PR B) — mirrors isCore's
                // preserve-on-update / take-from-controller-on-create
                // posture. `persistWizardBoard` only ever runs with
                // `status == .active` for a ONE-OFF wizard (a recurring
                // "Create Board" always goes through
                // `persistRecurringTemplate` instead), so an active save
                // here is never recurring — this is safe to derive
                // straight from the controller for both create and
                // update.
                "isRecurringDraft": existing?.isRecurringDraft ?? capturedIsRecurring,
            ]
            // Omit endDate entirely for indefinite boards (nil) so the row and
            // its Firestore doc carry no deadline at all — no sentinel.
            if let end = dates.end {
                boardDict["endDate"] = end
            }
            if let id = chosenCenterId {
                boardDict["centerTaskId"] = id
            }
            // A preserved isDeleted=true tombstone must carry its deletedAt
            // too, or the record is internally inconsistent. Omit the key
            // (rather than encode NSNull) for the common nil case, matching
            // endDate's representation above.
            if let deletedAt = existing?.deletedAt {
                boardDict["deletedAt"] = deletedAt
            }
            // Board Creation Split (PR B) — a recurring wizard writes its
            // CURRENT pool-mix snapshot fresh on every save (the user may
            // have changed the pool mid-session; this is never merged with
            // a prior snapshot). A one-off save never sets the key at all
            // — decodes as nil, matching a plain draft's forward-compat
            // shape.
            if capturedIsRecurring {
                let mixPayload = RecurringDraftMixPayload(
                    poolIds: capturedPulledPoolIds,
                    manualTaskIds: Array(capturedManualTaskIds),
                    removedTaskIds: Array(capturedRemovedTaskIds)
                )
                if let encodedMix = mixPayload.encoded() {
                    boardDict["recurringDraftMix"] = encodedMix
                }
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
            // Merge staged inline edits into pending payloads (a pending task
            // edited before board-create) — but ONLY on an active create. A
            // draft must never carry a task edit (invariant), so a draft save
            // writes pending tasks with their pre-edit values and skips staged
            // edits entirely (library-task edits are likewise gated inside
            // saveWizardBoard on board.status).
            let isActiveCreate = status == .active
            let pendingForSave: [PendingTaskPayload] = isActiveCreate
                ? pendingToPersist.map { payload -> PendingTaskPayload in
                    // Compound edits (parent fields AND child/link CRUD) are
                    // applied once, in saveWizardBoard's compound branch, against
                    // the just-written pending rows — so DON'T pre-merge them here
                    // (that would double-apply the parent + bump version twice).
                    // Simple/counting pending edits ARE merged in-memory (no extra
                    // write) and skipped by that loop.
                    guard payload.task.type != .compound,
                          let patch = capturedStagedEdits[payload.task.id],
                          patch.validate(type: payload.task.type) == nil else { return payload }
                    return PendingTaskPayload(
                        task: patch.applied(to: payload.task),
                        childTasks: payload.childTasks,
                        childLinks: payload.childLinks
                    )
                }
                : pendingToPersist

            // The single atomic transaction (deferred pending tasks, then the
            // board record + its BoardTask rows, plus every matching
            // SyncQueueItem) is owned by `AppDatabase.saveWizardBoard`. Without
            // the sync items the board stays local-only (SyncService.pushSync
            // reads exclusively from sync_queue), so that method enqueues one
            // per write. Pending tasks are written FIRST so task → board_task
            // referential integrity holds even on a crash mid-write.
            try AppDatabase.shared.saveWizardBoard(
                board: board,
                boardTasks: boardTasks,
                pendingTasks: pendingForSave,
                stagedEdits: isActiveCreate ? capturedStagedEdits : [:],
                isUpdate: isUpdate,
                now: now
            )

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
/// **Inline Task Editing parity fix** — this path used to never apply
/// `controller.stagedEdits`, so an inline edit staged while building/editing
/// a repeating board's task pool (rename, counting-goal change, compound
/// sub-task edit) was silently dropped: the pre-edit task values persisted
/// even though the Preview step showed the edit applied (via
/// `buildWizardPlacement`'s staged-edit overlay). Fixed the same way P4
/// fixed the analogous pending-task drop: staged edits are now applied in
/// the SAME transaction as the pending-task drain
/// (`writeWizardPendingTasksAndEnqueue`), mirroring `saveWizardBoard`'s
/// staged-edits block exactly (see that function's doc for per-type
/// handling). Applies to BOTH the fresh-create and edit branches below —
/// staged edits are a property of the wizard session, not of which branch
/// runs. Unlike the one-off path there's no draft/active gate to mirror:
/// a `RecurringBoardTemplate` has no draft state (the cancel dialog's "Save
/// Draft" action calls this exact function too — see
/// `BoardWizardView.handleDialogSaveDraft`), so staged edits always apply.
///
/// **Task Pools + Recurring Boards Rework, P4 rewrite** — this used to be
/// two separate persist paths (this function for recurring vs.
/// `persistWizardBoard`/`saveWizardBoard` for one-off) that diverged in a
/// load-bearing way: `saveWizardBoard` drained the wizard's in-memory
/// (Bug #85) `pendingTasks` into GRDB before writing the board; this
/// function never did, so a pending task selected into a repeating
/// board's pool was silently dropped from the mix forever (see
/// `AppDatabase.writeWizardPendingTasksAndEnqueue`'s doc for the full
/// failure mode). P4 unifies the two paths' pending-task handling and
/// retires the P1→P3 shape-scoped legacy write-through
/// (`PoolMix.isLegacyShapedRecord` / pool-minting) entirely — the native
/// `poolIds`/`manualTaskIds`/`removedTaskIds` shape (already tracked on
/// `BoardWizardViewModel` since P3 for the Tasks-step UI) is now the ONLY
/// shape this function ever writes, for both fresh-create AND edit.
///
/// Sequence:
///   1. Drain the FULL selection's pending tasks (not a placement-based
///      subset — a repeating board's future windows draw from the whole
///      pool) via `writeWizardPendingTasksAndEnqueue`, in its own
///      transaction, BEFORE anything below reads tasks for mix resolution
///      or spawn.
///   2. **Edit** (`editingTemplateId` set): re-saves the template with the
///      controller's CURRENT `pulledPoolIds`/`manualTaskIds`/
///      `removedTaskIds` — no Pool write-through, no shape branching, no
///      pool minting. `seedTaskIds` is left untouched (verbatim/stale,
///      never read after P1). Does NOT spawn — edits don't retroactively
///      change previously-spawned boards, and the next window's spawn
///      naturally picks up the new mix via `PoolMix.resolveMix`.
///   3. **Fresh create** (no `editingTemplateId`): inserts the
///      `RecurringBoardTemplate` row with the same native fields (no Pool
///      is minted — an own-mix, zero-pool repeating board is first-class
///      per docs/POOLS_RECURRING.md), then immediately spawns the current
///      window's board via `RecurringBoardSpawn.spawnTemplateBoard`. The
///      writes are sequential GRDB transactions; if the spawn fails (e.g.
///      soft-deleted task race), the template still exists with
///      `lastSpawnedWindowKey=nil` and the next Boards-tab open retries.
///
/// `seedTaskIds` is kept ONLY as a decode-compat snapshot of the final
/// selection (mirrors `lastSyncedCount`'s inert-field precedent) — never
/// read back by this function or by hydration (see
/// `BoardWizardViewModel.resolveTemplateHydrationTaskIds`).
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
    let isRandomized = controller.isRandomized
    let selectedTaskIds = controller.selectedTaskIds
    let seedTaskIds = Array(selectedTaskIds)
    let poolIds = controller.pulledPoolIds
    let manualTaskIds = Array(controller.manualTaskIds)
    let removedTaskIds = Array(controller.removedTaskIds)
    let editingTemplateId = controller.editingTemplateId
    let weekStartDay = controller.weekStartDay
    let now = AppDatabase.currentTimestamp()
    // Board Creation Split (PR B) — "Convert draft → template on Create
    // Board": when this session started as a resumed RECURRING draft
    // (`controller.draftBoardId` set — mutually exclusive with
    // `editingTemplateId`, see `BoardWizardViewModel`'s doc), a
    // successful fresh-create tombstones the placeholder draft `Board`
    // right after the real `RecurringBoardTemplate` is created, so the
    // drafts list doesn't keep showing a "converted" draft alongside the
    // board it just spawned.
    let draftBoardIdToRetire = controller.draftBoardId
    // Bug #85 — snapshot + filter to the FULL final selection (not a
    // placement-based subset, unlike the one-off path — see
    // `writeWizardPendingTasksAndEnqueue`'s doc). Value-type snapshot so
    // this doesn't race concurrent mutations on the main actor.
    let pendingToPersist = controller.pendingTasks.values.filter { selectedTaskIds.contains($0.task.id) }
    // Inline Task Editing — snapshot staged edits alongside pending tasks
    // (value types, safe O(n) copy) so the async write applies them
    // atomically. See the function doc above for why this always applies
    // (no draft/active gate for recurring templates).
    let capturedStagedEdits = controller.stagedEdits

    DispatchQueue.global(qos: .userInitiated).async {
        // Board Creation Split (PR B) — best-effort tombstone of the
        // resumed draft, called from the fresh-create path's three exit
        // points below. Silent on failure (mirrors the rest of this
        // function's DB-read resilience posture): the template/board just
        // created is the important write and has already succeeded by the
        // time this runs, so a failed cleanup only leaves a stray
        // now-redundant draft row visible in the list — not silently lost
        // work.
        func retireResumedDraftIfNeeded() {
            guard let draftBoardIdToRetire else { return }
            do {
                try AppDatabase.shared.deleteDraftWithCascade(id: draftBoardIdToRetire)
            } catch {
                dlog("[persistRecurringTemplate] failed to retire resumed draft \(draftBoardIdToRetire): \(error)")
            }
        }
        do {
            // Merge staged simple/counting edits into their pending payload
            // in-memory (mirrors `persistWizardBoard`'s merge) so the
            // inline-created task is written with its edited values in one
            // shot. Compound edits (parent fields AND child/link CRUD) are
            // applied once inside `writeWizardPendingTasksAndEnqueue`,
            // against the just-written pending rows — so DON'T pre-merge
            // them here (that would double-apply the parent + bump version
            // twice).
            let pendingForSave: [PendingTaskPayload] = pendingToPersist.map { payload -> PendingTaskPayload in
                guard payload.task.type != .compound,
                      let patch = capturedStagedEdits[payload.task.id],
                      patch.validate(type: payload.task.type) == nil else { return payload }
                return PendingTaskPayload(
                    task: patch.applied(to: payload.task),
                    childTasks: payload.childTasks,
                    childLinks: payload.childLinks
                )
            }

            // Drain pending (Bug #85) tasks FIRST — before the edit path's
            // template re-save or the fresh-create path's spawn, both of
            // which resolve the mix / read tasks by id. Staged edits
            // (library tasks + pending compounds) are applied in the same
            // transaction — see `writeWizardPendingTasksAndEnqueue`'s doc.
            if !pendingForSave.isEmpty || !capturedStagedEdits.isEmpty {
                try AppDatabase.shared.writeWizardPendingTasksAndEnqueue(
                    pendingForSave, stagedEdits: capturedStagedEdits, now: now
                )
            }

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
                    isRandomized: isRandomized,
                    // Left verbatim/stale — decode-compat only, never read
                    // after P1 (see the function doc above).
                    seedTaskIds: existing.seedTaskIds,
                    poolIds: poolIds,
                    manualTaskIds: manualTaskIds,
                    removedTaskIds: removedTaskIds,
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
                try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                    updated, operation: .update, now: now
                )

                DispatchQueue.main.async { onSuccess(.updated(templateId: templateId)) }
                return
            }

            // ── Fresh-create path ─────────────────────────────────────
            // No Pool is minted (P4 retires the P1 auto-mint-on-create
            // behavior) — an own-mix, zero-pool repeating board is
            // first-class. `poolIds`/`manualTaskIds`/`removedTaskIds` come
            // straight from the controller's own P3 pool-mix state, which
            // is now authoritative end-to-end.
            let template = RecurringBoardTemplate(
                id: AppDatabase.generateUUID(),
                userId: userId,
                name: trimmedName,
                timeframe: timeframe,
                boardSize: boardSize,
                centerSquareType: centerType,
                isRandomized: isRandomized,
                seedTaskIds: seedTaskIds,
                poolIds: poolIds,
                manualTaskIds: manualTaskIds,
                removedTaskIds: removedTaskIds,
                lastSpawnedWindowKey: nil,
                isActive: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                template,
                operation: .create,
                now: now
            )

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
                retireResumedDraftIfNeeded()
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
            retireResumedDraftIfNeeded()
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
