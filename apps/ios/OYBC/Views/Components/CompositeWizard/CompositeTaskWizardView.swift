import SwiftUI
import GRDB

/// CompositeTaskWizardView — 3-step mini-wizard (Setup → Build → Review)
/// that replaces the legacy `CompositeTaskFormView` monolith. Owns the
/// full draft state, step transitions, and the atomic submit
/// transaction. Step content delegates to `CompositeWizardSetupStepView`,
/// `CompositeWizardBuildStepView`, and `CompositeWizardReviewStepView`.
/// iOS twin of web's `CompositeTaskWizard`.
struct CompositeTaskWizardView: View {

    /// User ID for task ownership. Defaults to playground user when omitted.
    var userId: String = playgroundUserId

    /// Invoked with the newly created compound Task after a successful save.
    var onCreated: ((OYBC.Task) -> Void)? = nil

    // MARK: - Core form state

    @State private var compositeTitle = ""
    @State private var operatorType: OperatorType = .and
    @State private var threshold: Int = 2
    /// Wrapped observable so parent-level derived state (readiness,
    /// threshold clamp) picks up edits inside child cards. See
    /// `CompositeSubtaskList` for the rebroadcast wiring.
    @StateObject private var subtaskList = CompositeSubtaskList()

    // MARK: - UI state

    @State private var currentStep: CompositeWizardStep = 1
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    // MARK: - Library state

    /// All non-compound tasks in the user's library (pool of potential children).
    @State private var libraryTasks: [OYBC.Task] = []
    /// Compound tasks (type=.compound && !isOrdered) — used as selectable
    /// nested children in the Build step.
    @State private var libraryCompositeTasks: [OYBC.Task] = []
    /// taskId → count of distinct boards the task is placed on. Drives
    /// the "on N boards" hint in the existing-task picker. iOS twin of
    /// `taskBoardCounts` on web.
    @State private var taskBoardCounts: [String: Int] = [:]
    /// taskId → number of non-deleted steps (progress tasks only).
    @State private var taskStepCounts: [String: Int] = [:]
    /// compoundTaskId → number of direct children (CompoundChild rows).
    @State private var compositeSubtaskCounts: [String: Int] = [:]
    /// compoundTaskId → first few child task titles for the picker subtitle.
    @State private var compositeLeafPreviews: [String: CompositeLeafPreview] = [:]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompositeWizardStepperView(
                currentStep: currentStep,
                onStepClick: { step in
                    if step < currentStep { currentStep = step }
                }
            )

            switch currentStep {
            case 1:
                CompositeWizardSetupStepView(
                    title: $compositeTitle,
                    operatorType: $operatorType,
                    onCancel: resetForm,
                    onNext: { currentStep = 2 }
                )
            case 2:
                CompositeWizardBuildStepView(
                    subtaskList: subtaskList,
                    operatorType: operatorType,
                    threshold: $threshold,
                    libraryTasks: libraryTasks,
                    libraryCompositeTasks: libraryCompositeTasks,
                    taskBoardCounts: taskBoardCounts,
                    taskStepCounts: taskStepCounts,
                    compositeSubtaskCounts: compositeSubtaskCounts,
                    compositeLeafPreviews: compositeLeafPreviews,
                    onRemove: { item in removeSubtask(item) },
                    onCommitLibraryDiff: commitLibraryDiff,
                    onAddInline: addInlineSubtask,
                    onBack: { currentStep = 1 },
                    onNext: { currentStep = 3 }
                )
            default:
                CompositeWizardReviewStepView(
                    title: compositeTitle,
                    operatorType: operatorType,
                    threshold: threshold,
                    subtasks: subtaskList.items,
                    libraryTasks: libraryTasks,
                    libraryCompositeTasks: libraryCompositeTasks,
                    isSubmitting: isSubmitting,
                    errorMessage: errorMessage,
                    onBack: { currentStep = 2 },
                    onCreate: handleCreateCompositeTask
                )
            }

            if let success = successMessage {
                Text(success)
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadLibrary()
        }
    }

    // MARK: - Subtask mutators

    private func addInlineSubtask() {
        let item = SubtaskItem(mode: .inline_)
        item.inlineSteps = [ProgressStepFormState()]
        subtaskList.append(item)
    }

    private func removeSubtask(_ item: SubtaskItem) {
        // Threshold clamping is handled centrally by the
        // `.onChange(of: subtaskList.items.count)` hook on the body so
        // this stays a pure state mutation.
        subtaskList.remove(where: { $0.id == item.id })
    }

    /// Apply a LibraryPickerSheetView commit: drop existing-mode
    /// subtasks whose selected id is in the remove set, then append
    /// fresh existing-mode items for each add. Inline subtasks are
    /// untouched. Threshold may shrink if the net count drops —
    /// surface the clamp toast so the change is visible, matching
    /// the per-row remove path.
    private func commitLibraryDiff(_ diff: LibraryDiff) {
        subtaskList.remove { item in
            guard item.mode == .existing else { return false }
            let id = item.selectionType == .task ? item.selectedTaskId : item.selectedCompositeId
            return diff.remove.contains(id)
        }
        for entry in diff.add {
            let item = SubtaskItem(mode: .existing)
            item.selectionType = entry.kind
            if entry.kind == .task {
                item.selectedTaskId = entry.id
            } else {
                item.selectedCompositeId = entry.id
            }
            subtaskList.append(item)
        }
    }

    // MARK: - Reset

    private func resetForm() {
        compositeTitle = ""
        operatorType = .and
        threshold = 2
        subtaskList.removeAll()
        currentStep = 1
        errorMessage = nil
        isSubmitting = false
    }

    // MARK: - Library load

    private func loadLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // All tasks for this user.
                let allTasks: [OYBC.Task] = try AppDatabase.shared.read { db in
                    try OYBC.Task
                        .filter(Column("userId") == userId && Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                // Split into primitives + compound (composite) tasks.
                let primitives = allTasks.filter { $0.type != .compound }
                let compounds  = allTasks.filter { $0.type == .compound && $0.isOrdered != true }

                // Usage hints: board placements per task.
                let boardTasks: [BoardTask] = try AppDatabase.shared.read { db in
                    try BoardTask.fetchAll(db)
                }
                var boardsByTask: [String: Set<String>] = [:]
                for bt in boardTasks {
                    boardsByTask[bt.taskId, default: []].insert(bt.boardId)
                }
                let taskCounts = boardsByTask.mapValues { $0.count }

                // Step counts for progress tasks.
                let steps: [TaskStep] = try AppDatabase.shared.read { db in
                    try TaskStep
                        .filter(Column("isDeleted") == false)
                        .fetchAll(db)
                }
                var stepCounts: [String: Int] = [:]
                for step in steps {
                    stepCounts[step.taskId, default: 0] += 1
                }

                // CompoundChild counts + previews for compound tasks.
                let children: [CompoundChild] = try AppDatabase.shared.read { db in
                    try CompoundChild
                        .filter(Column("isDeleted") == false)
                        .fetchAll(db)
                }
                var childCounts: [String: Int] = [:]
                var childrenByCompound: [String: [CompoundChild]] = [:]
                for child in children {
                    childCounts[child.compoundTaskId, default: 0] += 1
                    childrenByCompound[child.compoundTaskId, default: []].append(child)
                }
                let taskTitleById = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0.title) })
                var previews: [String: CompositeLeafPreview] = [:]
                for (compoundId, kids) in childrenByCompound {
                    let sorted = kids.sorted { $0.childIndex < $1.childIndex }
                    var titles: [String] = []
                    for child in sorted.prefix(3) {
                        if let t = taskTitleById[child.childTaskId] {
                            titles.append(t)
                        }
                    }
                    previews[compoundId] = CompositeLeafPreview(
                        titles: titles,
                        totalLeaves: sorted.count
                    )
                }

                DispatchQueue.main.async {
                    self.libraryTasks = primitives
                    self.libraryCompositeTasks = compounds
                    self.taskBoardCounts = taskCounts
                    self.taskStepCounts = stepCounts
                    self.compositeSubtaskCounts = childCounts
                    self.compositeLeafPreviews = previews
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load library: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Submit

    /// Creates the compound task in the unified schema:
    /// 1. Insert a Task row with type=.compound + operator/threshold fields.
    /// 2. For each existing-reference subtask: create CompoundChild row.
    /// 3. For each inline-created primitive (.normal / .counting): insert
    ///    the new Task first, then the CompoundChild row.
    /// 4. Inline progress-subtask creation is NOT supported here — drop with
    ///    a TODO for Phase 8 (matches web's decision in commit 63e90f3).
    /// All writes are atomic in a single AppDatabase.write block.
    private func handleCreateCompositeTask() {
        // Precondition: inline progress subtasks aren't yet supported under the unified
        // model — autoCreate doesn't carry nested children. Block submission with a clear
        // error so the user understands the workaround, rather than silently skipping the
        // item and losing data (which is what the `continue` in the save loop would do).
        let hasInlineProgress = subtaskList.items.contains { item in
            item.mode == .inline_ && item.inlineType == .progress
        }
        if hasInlineProgress {
            errorMessage = "Inline Progress subtasks aren't supported yet — create the inner Progress task first as a standalone task, then add it here as an existing subtask."
            return
        }

        errorMessage = nil
        isSubmitting = true

        let now = AppDatabase.currentTimestamp()
        let compoundTaskId = AppDatabase.generateUUID()
        let capturedSubtasks = subtaskList.items
        let capturedTitle = compositeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedOperator = operatorType
        let capturedThreshold = threshold
        let capturedUserId = userId

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Items to enqueue for sync AFTER the transaction.
                var syncItems: [(entityType: String, entityId: String, payload: String)] = []

                // Build the parent compound Task.
                let compoundTask = OYBC.Task(
                    id: compoundTaskId,
                    userId: capturedUserId,
                    title: capturedTitle,
                    description: nil,
                    type: .compound,
                    operatorType: capturedOperator,
                    threshold: capturedOperator == .mOfN ? capturedThreshold : nil,
                    isOrdered: false,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                if let payload = Self.encodePayload(compoundTask) {
                    syncItems.append(("tasks", compoundTaskId, payload))
                }

                try AppDatabase.shared.write { db in
                    try compoundTask.save(db)

                    // Sync items get inserted at the end of this same transaction so
                    // entity writes + sync entries land atomically. A crash between
                    // them previously left the new compound unreachable from any
                    // other device — the legacy two-block pattern was unsafe.
                    for (index, item) in capturedSubtasks.enumerated() {
                        var childTaskId: String

                        switch item.mode {
                        case .existing:
                            // Reference to a task already in the library.
                            childTaskId = item.selectionType == .task
                                ? item.selectedTaskId
                                : item.selectedCompositeId

                        case .inline_:
                            // Inline-created primitive child task.
                            let trimmedTitle  = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedAction = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedUnit   = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                            let parsedMax     = Int(item.inlineMaxCountStr.trimmingCharacters(in: .whitespacesAndNewlines))

                            switch item.inlineType {
                            case .progress:
                                // TODO Phase 8: inline progress subtasks in the composite
                                // wizard are not yet supported in the unified model.
                                // Matches web's same decision (commit 63e90f3). Skip.
                                continue

                            case .normal:
                                let newId   = AppDatabase.generateUUID()
                                let newTask = OYBC.Task(
                                    id: newId,
                                    userId: capturedUserId,
                                    title: trimmedTitle,
                                    description: nil,
                                    type: .normal,
                                    totalCompletions: 0,
                                    totalInstances: 0,
                                    createdAt: now,
                                    updatedAt: now,
                                    version: 1,
                                    isDeleted: false
                                )
                                try newTask.save(db)
                                if let p = Self.encodePayload(newTask) {
                                    syncItems.append(("tasks", newId, p))
                                }
                                childTaskId = newId

                            case .counting:
                                let newId = AppDatabase.generateUUID()
                                // Mirror shared `generateCounterTaskTitle` fallback.
                                let resolvedTitle: String = trimmedTitle.isEmpty
                                    ? "\(trimmedAction) \(parsedMax ?? 0) \(trimmedUnit)"
                                    : trimmedTitle
                                let newTask = OYBC.Task(
                                    id: newId,
                                    userId: capturedUserId,
                                    title: resolvedTitle,
                                    description: nil,
                                    type: .counting,
                                    action: trimmedAction,
                                    unit: trimmedUnit,
                                    maxCount: parsedMax,
                                    totalCompletions: 0,
                                    totalInstances: 0,
                                    createdAt: now,
                                    updatedAt: now,
                                    version: 1,
                                    isDeleted: false
                                )
                                try newTask.save(db)
                                if let p = Self.encodePayload(newTask) {
                                    syncItems.append(("tasks", newId, p))
                                }
                                childTaskId = newId
                            }
                        }

                        let childRow = CompoundChild(
                            id: AppDatabase.generateUUID(),
                            compoundTaskId: compoundTaskId,
                            childTaskId: childTaskId,
                            childIndex: index,
                            createdAt: now,
                            updatedAt: now,
                            lastSyncedAt: nil,
                            version: 1,
                            isDeleted: false,
                            deletedAt: nil
                        )
                        try childRow.save(db)
                        if let p = Self.encodePayload(childRow) {
                            syncItems.append(("compound_children", childRow.id, p))
                        }
                    }

                    // Sync items inside the SAME transaction as the entity
                    // writes — atomicity guarantees that either every entity
                    // + every sync entry lands or nothing does. The legacy
                    // two-block pattern dropped sync entries on a crash window.
                    for item in syncItems {
                        let syncItem = SyncQueueItem(
                            id: AppDatabase.generateUUID(),
                            entityType: item.entityType,
                            entityId: item.entityId,
                            operationType: .create,
                            payload: item.payload,
                            status: .pending,
                            retryCount: 0,
                            lastError: nil,
                            createdAt: now,
                            lastAttemptAt: nil,
                            completedAt: nil,
                            priority: 1
                        )
                        try syncItem.save(db)
                    }
                }

                DispatchQueue.main.async {
                    resetForm()
                    successMessage = "Compound task created!"
                    loadLibrary()
                    onCreated?(compoundTask)
                    DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
                        successMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed: \(error.localizedDescription)"
                    isSubmitting = false
                }
            }
        }
    }

    // MARK: - Helpers

    /// JSON-encodes a Codable value to a UTF-8 string suitable for the sync
    /// queue payload column. Returns nil on encoding failure (non-fatal —
    /// the local write already succeeded; the row will be picked up on the
    /// next full pull).
    private static func encodePayload<T: Codable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
