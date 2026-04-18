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
    @State private var subtasks: [SubtaskItem] = []

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
                    subtaskCount: subtasks.count,
                    onCancel: resetForm,
                    onNext: { currentStep = 2 }
                )
            case 2:
                CompositeWizardBuildStepView(
                    subtasks: $subtasks,
                    libraryTasks: libraryTasks,
                    libraryCompositeTasks: libraryCompositeTasks,
                    onRemove: { item in removeSubtask(item) },
                    onAddExisting: addExistingSubtask,
                    onAddInline: addInlineSubtask,
                    onBack: { currentStep = 1 },
                    onNext: { currentStep = 3 }
                )
            default:
                CompositeWizardReviewStepView(
                    title: compositeTitle,
                    operatorType: operatorType,
                    threshold: threshold,
                    subtasks: subtasks,
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

    private func addExistingSubtask() {
        // Adding can only grow the subtask count, so any previously
        // valid threshold stays valid. Clamping here would silently
        // reduce the user's threshold choice (legacy-monolith bug).
        subtasks.append(SubtaskItem(mode: .existing))
    }

    private func addInlineSubtask() {
        let item = SubtaskItem(mode: .inline_)
        item.inlineSteps = [ProgressStepFormState()]
        subtasks.append(item)
    }

    private func removeSubtask(_ item: SubtaskItem) {
        subtasks.removeAll { $0.id == item.id }
        clampThresholdAndMaybeToast()
    }

    private func clampThreshold() {
        if operatorType == .mOfN {
            let count = subtasks.count
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
            let count = subtasks.count
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
        subtasks = []
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
                DispatchQueue.main.async {
                    self.libraryTasks = tasks
                    self.libraryCompositeTasks = composites
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
        let capturedSubtasks = subtasks
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
                            let taskType: TaskType
                            switch item.inlineType {
                            case .normal: taskType = .normal
                            case .counting: taskType = .counting
                            case .progress: taskType = .progress
                            }
                            let newTask = OYBC.Task(
                                id: newTaskId,
                                userId: capturedUserId,
                                title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
                                description: nil,
                                type: taskType,
                                action: item.inlineType == .counting ? item.inlineAction : nil,
                                unit: item.inlineType == .counting ? item.inlineUnit : nil,
                                maxCount: item.inlineType == .counting ? Int(item.inlineMaxCountStr) : nil,
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
                                    let stepTitleTrim = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let taskStep = TaskStep(
                                        id: AppDatabase.generateUUID(),
                                        taskId: newTaskId,
                                        stepIndex: stepIndex,
                                        title: stepTitleTrim.isEmpty ? "Untitled Step" : stepTitleTrim,
                                        type: step.type == .counting ? .counting : .normal,
                                        action: step.type == .counting ? step.action : nil,
                                        unit: step.type == .counting ? step.unit : nil,
                                        maxCount: step.type == .counting ? Int(step.maxCount) : nil,
                                        linkedTaskId: nil,
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
