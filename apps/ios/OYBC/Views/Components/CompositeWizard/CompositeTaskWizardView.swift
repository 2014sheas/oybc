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

    /// Invoked with the newly created CompositeTask after a successful save.
    var onCreated: ((CompositeTask) -> Void)? = nil

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
    /// Transient banner shown when a threshold is clamped downward by
    /// subtask removal. Replaces the legacy silent clamp. Auto-dismisses
    /// after 4s via `clampToastToken`.
    @State private var clampToast: String?
    @State private var clampToastToken: Int = 0

    // MARK: - Library state

    @State private var libraryTasks: [OYBC.Task] = []
    @State private var libraryCompositeTasks: [CompositeTask] = []
    /// taskId → count of distinct boards the task is placed on. Drives
    /// the "on N boards" hint in the existing-task picker. iOS twin of
    /// `taskBoardCounts` on web.
    @State private var taskBoardCounts: [String: Int] = [:]
    /// taskId → number of non-deleted steps (progress tasks only).
    @State private var taskStepCounts: [String: Int] = [:]
    /// compositeTaskId → number of leaf subtasks.
    @State private var compositeSubtaskCounts: [String: Int] = [:]
    /// compositeTaskId → first few leaf titles for the picker subtitle.
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

            if let toast = clampToast {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(toast)
                        .font(.caption)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
                .transition(.opacity)
            }

            switch currentStep {
            case 1:
                CompositeWizardSetupStepView(
                    title: $compositeTitle,
                    operatorType: $operatorType,
                    threshold: $threshold,
                    subtaskCount: subtaskList.items.count,
                    onCancel: resetForm,
                    onNext: { currentStep = 2 }
                )
            case 2:
                CompositeWizardBuildStepView(
                    subtaskList: subtaskList,
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
        // Keep threshold in range whenever the operator flips to M_OF_N
        // (initial value may exceed `max(1, subtaskCount)`) or when the
        // subtask count shifts. Web twin uses a useEffect; same shape.
        .onChange(of: operatorType) { _ in clampThresholdAndMaybeToast() }
        .onChange(of: subtaskList.items.count) { _ in clampThresholdAndMaybeToast() }
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
        // Count-change hook on the body calls `clampThresholdAndMaybeToast`.
    }

    private func clampThreshold() {
        if operatorType == .mOfN {
            let count = subtaskList.items.count
            if count == 0 { threshold = 1; return }
            threshold = min(max(1, threshold), count)
        }
    }

    /// Variant of `clampThreshold` that surfaces a transient toast when
    /// the threshold actually moved. Only relevant for the removal path
    /// — adding a subtask can't reduce the threshold.
    private func clampThresholdAndMaybeToast() {
        let before = threshold
        clampThreshold()
        if threshold != before && operatorType == .mOfN {
            let count = subtaskList.items.count
            let noun = count == 1 ? "subtask" : "subtasks"
            showClampToast("Threshold lowered to \(threshold) (you only have \(count) \(noun)).")
        }
    }

    private func showClampToast(_ message: String) {
        clampToast = message
        clampToastToken += 1
        let token = clampToastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if clampToastToken == token { clampToast = nil }
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
                let tasks = try AppDatabase.shared.fetchTasks(userId: userId)
                let composites: [CompositeTask] = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == userId && Column("isDeleted") == false)
                        .order(Column("updatedAt").desc)
                        .fetchAll(db)
                }
                // Usage hints for the picker.
                let boardTasks: [BoardTask] = try AppDatabase.shared.read { db in
                    try BoardTask.fetchAll(db)
                }
                let nodes: [CompositeNode] = try AppDatabase.shared.read { db in
                    try CompositeNode
                        .filter(Column("isDeleted") == false)
                        .fetchAll(db)
                }
                let steps: [TaskStep] = try AppDatabase.shared.read { db in
                    try TaskStep
                        .filter(Column("isDeleted") == false)
                        .fetchAll(db)
                }

                var boardsByTask: [String: Set<String>] = [:]
                for bt in boardTasks {
                    boardsByTask[bt.taskId, default: []].insert(bt.boardId)
                }
                let taskCounts: [String: Int] = boardsByTask.mapValues { $0.count }

                var stepCounts: [String: Int] = [:]
                for step in steps {
                    stepCounts[step.taskId, default: 0] += 1
                }

                var leafCounts: [String: Int] = [:]
                var leavesByComposite: [String: [CompositeNode]] = [:]
                for node in nodes where node.nodeType == .leaf {
                    leafCounts[node.compositeTaskId, default: 0] += 1
                    leavesByComposite[node.compositeTaskId, default: []].append(node)
                }

                // Build composite leaf previews (first 3 leaf titles).
                let taskTitleById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })
                let compositeTitleById = Dictionary(uniqueKeysWithValues: composites.map { ($0.id, $0.title) })
                var previews: [String: CompositeLeafPreview] = [:]
                for (compositeId, leaves) in leavesByComposite {
                    let sortedLeaves = leaves.sorted { $0.nodeIndex < $1.nodeIndex }
                    var titles: [String] = []
                    for leaf in sortedLeaves.prefix(3) {
                        if let tid = leaf.taskId, let t = taskTitleById[tid] {
                            titles.append(t)
                        } else if let cid = leaf.childCompositeTaskId, let t = compositeTitleById[cid] {
                            titles.append(t)
                        }
                    }
                    previews[compositeId] = CompositeLeafPreview(
                        titles: titles,
                        totalLeaves: sortedLeaves.count
                    )
                }

                DispatchQueue.main.async {
                    self.libraryTasks = tasks
                    self.libraryCompositeTasks = composites
                    self.taskBoardCounts = taskCounts
                    self.taskStepCounts = stepCounts
                    self.compositeSubtaskCounts = leafCounts
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

    private func handleCreateCompositeTask() {
        errorMessage = nil
        isSubmitting = true

        let now = AppDatabase.currentTimestamp()
        let compositeTaskId = AppDatabase.generateUUID()
        let rootNodeId = AppDatabase.generateUUID()
        let capturedSubtasks = subtaskList.items
        let capturedTitle = compositeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedOperator = operatorType
        let capturedThreshold = threshold
        let capturedUserId = userId

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    var resolvedLeaves: [(taskId: String?, childCompositeTaskId: String?)] = []

                    for item in capturedSubtasks {
                        switch item.mode {
                        case .existing:
                            if item.selectionType == .task {
                                resolvedLeaves.append((taskId: item.selectedTaskId, childCompositeTaskId: nil))
                            } else {
                                resolvedLeaves.append((taskId: nil, childCompositeTaskId: item.selectedCompositeId))
                            }
                        case .inline_:
                            let newTaskId = AppDatabase.generateUUID()
                            let trimmedTitle = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedAction = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedUnit = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                            let parsedMax = Int(item.inlineMaxCountStr.trimmingCharacters(in: .whitespacesAndNewlines))
                            let taskType: TaskType
                            switch item.inlineType {
                            case .normal: taskType = .normal
                            case .counting: taskType = .counting
                            case .progress: taskType = .progress
                            }
                            // For counting tasks, mirror the shared
                            // `generateCounterTaskTitle` fallback — if
                            // the user left the title blank, derive it
                            // from `action + max + unit`. Matches the
                            // web wizard and the rest of the iOS create
                            // flow.
                            let resolvedTitle: String
                            if item.inlineType == .counting && trimmedTitle.isEmpty {
                                resolvedTitle = "\(trimmedAction) \(parsedMax ?? 0) \(trimmedUnit)"
                            } else {
                                resolvedTitle = trimmedTitle
                            }
                            let newTask = OYBC.Task(
                                id: newTaskId,
                                userId: capturedUserId,
                                title: resolvedTitle,
                                description: nil,
                                type: taskType,
                                action: item.inlineType == .counting ? trimmedAction : nil,
                                unit: item.inlineType == .counting ? trimmedUnit : nil,
                                maxCount: item.inlineType == .counting ? parsedMax : nil,
                                totalCompletions: 0,
                                totalInstances: 0,
                                createdAt: now,
                                updatedAt: now,
                                version: 1,
                                isDeleted: false
                            )
                            try newTask.save(db)

                            if item.inlineType == .progress {
                                for (stepIndex, step) in item.inlineSteps.enumerated() {
                                    let stepTrimTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let stepTrimAction = step.action.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let stepTrimUnit = step.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let stepMax = Int(step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines))
                                    let stepIsCounting = step.type == .counting
                                    // Mirror web: counting step with a
                                    // blank title gets the derived
                                    // `action + max + unit` title; other
                                    // steps keep whatever the user typed.
                                    let resolvedStepTitle: String
                                    if stepIsCounting && stepTrimTitle.isEmpty {
                                        resolvedStepTitle = "\(stepTrimAction) \(stepMax ?? 0) \(stepTrimUnit)"
                                    } else {
                                        resolvedStepTitle = stepTrimTitle
                                    }
                                    // Create a standalone Task per step
                                    // (same as the primary createTask
                                    // flow) so the step is immediately
                                    // pool-addable and participates in
                                    // cross-board rollup. Link it via
                                    // TaskStep.linkedTaskId.
                                    let stepTaskId = AppDatabase.generateUUID()
                                    let stepTask = OYBC.Task(
                                        id: stepTaskId,
                                        userId: capturedUserId,
                                        title: resolvedStepTitle,
                                        description: nil,
                                        type: stepIsCounting ? .counting : .normal,
                                        action: stepIsCounting ? stepTrimAction : nil,
                                        unit: stepIsCounting ? stepTrimUnit : nil,
                                        maxCount: stepIsCounting ? stepMax : nil,
                                        totalCompletions: 0,
                                        totalInstances: 0,
                                        createdAt: now,
                                        updatedAt: now,
                                        version: 1,
                                        isDeleted: false
                                    )
                                    try stepTask.save(db)
                                    let taskStep = TaskStep(
                                        id: AppDatabase.generateUUID(),
                                        taskId: newTaskId,
                                        stepIndex: stepIndex,
                                        title: resolvedStepTitle,
                                        type: stepIsCounting ? .counting : .normal,
                                        action: stepIsCounting ? stepTrimAction : nil,
                                        unit: stepIsCounting ? stepTrimUnit : nil,
                                        maxCount: stepIsCounting ? stepMax : nil,
                                        linkedTaskId: stepTaskId,
                                        createdAt: now,
                                        updatedAt: now,
                                        lastSyncedAt: nil,
                                        version: 1,
                                        isDeleted: false,
                                        deletedAt: nil
                                    )
                                    try taskStep.save(db)
                                }
                            }

                            resolvedLeaves.append((taskId: newTaskId, childCompositeTaskId: nil))
                        }
                    }

                    let compositeTask = CompositeTask(
                        id: compositeTaskId,
                        userId: capturedUserId,
                        title: capturedTitle,
                        description: nil,
                        rootNodeId: rootNodeId,
                        createdAt: now,
                        updatedAt: now,
                        lastSyncedAt: nil,
                        version: 1,
                        isDeleted: false,
                        deletedAt: nil
                    )
                    try compositeTask.save(db)

                    let rootNode = CompositeNode(
                        id: rootNodeId,
                        compositeTaskId: compositeTaskId,
                        parentNodeId: nil,
                        nodeIndex: 0,
                        nodeType: .operator,
                        operatorType: capturedOperator,
                        threshold: capturedOperator == .mOfN ? capturedThreshold : nil,
                        taskId: nil,
                        childCompositeTaskId: nil,
                        createdAt: now,
                        updatedAt: now,
                        lastSyncedAt: nil,
                        version: 1,
                        isDeleted: false,
                        deletedAt: nil
                    )
                    try rootNode.save(db)

                    for (index, leaf) in resolvedLeaves.enumerated() {
                        let leafNode = CompositeNode(
                            id: AppDatabase.generateUUID(),
                            compositeTaskId: compositeTaskId,
                            parentNodeId: rootNodeId,
                            nodeIndex: index,
                            nodeType: .leaf,
                            operatorType: nil,
                            threshold: nil,
                            taskId: leaf.taskId,
                            childCompositeTaskId: leaf.childCompositeTaskId,
                            createdAt: now,
                            updatedAt: now,
                            lastSyncedAt: nil,
                            version: 1,
                            isDeleted: false,
                            deletedAt: nil
                        )
                        try leafNode.save(db)
                    }
                }

                DispatchQueue.main.async {
                    resetForm()
                    successMessage = "Composite task created!"
                    loadLibrary()
                    if let callback = onCreated {
                        let createdComposite = CompositeTask(
                            id: compositeTaskId,
                            userId: capturedUserId,
                            title: capturedTitle,
                            description: nil,
                            rootNodeId: rootNodeId,
                            createdAt: now,
                            updatedAt: now,
                            lastSyncedAt: nil,
                            version: 1,
                            isDeleted: false,
                            deletedAt: nil
                        )
                        callback(createdComposite)
                    }
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
}
