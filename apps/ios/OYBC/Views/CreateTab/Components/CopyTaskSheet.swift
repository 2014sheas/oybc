import SwiftUI

/// Copy sheet for the `From a board` grid's `⎘ Add a copy of this task…`
/// action. Pre-fills every field from the source and exposes per-type
/// editable surface:
///
/// - normal:      title only
/// - counting:    title + action + maxCount + unit
/// - compound:    title only (children stay shared)
/// - achievement: title + trigger + requiredCount (template mode).
///                Reference target preserved from the source; re-target
///                is a follow-up — user can edit the new task from the
///                Tasks tab.
///
/// iOS twin of web's `CopyTaskModal`. Routes through
/// `AppDatabase.shared.copyTask` / `copyCompound` so validation +
/// sync writes match a brand-new task path.
struct CopyTaskSheet: View {
    let source: OYBC.Task
    let userId: String

    /// Called on success with the new Task. Parent marks the source as
    /// "copied this session" and auto-adds the new id to selection.
    let onCopied: (OYBC.Task) -> Void
    /// Cancel / Escape / swipe-down.
    let onCancel: () -> Void

    @State private var title: String
    @State private var action: String
    @State private var unit: String
    @State private var maxCountInput: String
    @State private var trigger: AchievementTrigger
    @State private var requiredCountInput: String
    @State private var error: String?
    @State private var saving: Bool = false

    init(
        source: OYBC.Task,
        userId: String,
        onCopied: @escaping (OYBC.Task) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.source = source
        self.userId = userId
        self.onCopied = onCopied
        self.onCancel = onCancel
        self._title = State(initialValue: source.title)
        self._action = State(initialValue: source.action ?? "")
        self._unit = State(initialValue: source.unit ?? "")
        self._maxCountInput = State(
            initialValue: source.maxCount.map(String.init) ?? ""
        )
        self._trigger = State(initialValue: source.achievementTrigger ?? .greenlog)
        self._requiredCountInput = State(
            initialValue: source.requiredCount.map(String.init) ?? ""
        )
    }

    var body: some View {
        let isCounting = source.type == .counting
        let isCompound = source.type == .compound
        let isAchievement = source.type == .achievement
        let isTemplateMode = isAchievement && source.referencedTemplateId != nil

        NavigationStack {
            Form {
                Section("Source") {
                    Text(source.title)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Title") {
                    TextField("Title", text: $title)
                }

                if isCounting {
                    Section("Counting") {
                        TextField("Action", text: $action)
                        TextField("Goal", text: $maxCountInput)
                            .keyboardType(.numberPad)
                        TextField("Unit", text: $unit)
                    }
                }

                if isAchievement {
                    Section("Achievement") {
                        Picker("Trigger", selection: $trigger) {
                            Text("Greenlog").tag(AchievementTrigger.greenlog)
                            Text("Bingo").tag(AchievementTrigger.bingo)
                        }
                        if isTemplateMode {
                            TextField("Required count", text: $requiredCountInput)
                                .keyboardType(.numberPad)
                        }
                    }
                    Section {
                        Text(
                            "The copy watches the same target as the source. To re-target, edit the new task from the Tasks tab after Save."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                if isCompound {
                    Section {
                        Text(
                            "The copy reuses the source's subtasks. Completing the original subtasks still completes them on the copy and vice versa (shared children)."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Add a copy of this task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save copy") {
                        handleSave(
                            isCounting: isCounting,
                            isCompound: isCompound,
                            isAchievement: isAchievement,
                            isTemplateMode: isTemplateMode
                        )
                    }
                    .disabled(saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Save

    private func handleSave(
        isCounting: Bool,
        isCompound: Bool,
        isAchievement: Bool,
        isTemplateMode: Bool
    ) {
        error = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            error = "Title is required"
            return
        }

        saving = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newTask: OYBC.Task
                if isCompound {
                    newTask = try AppDatabase.shared.copyCompound(
                        userId: userId,
                        source: source,
                        title: trimmedTitle
                    )
                } else {
                    var overrides = AppDatabase.CopyTaskOverrides(title: trimmedTitle)
                    if isCounting {
                        guard let parsedMax = Int(
                            maxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        ), parsedMax > 0 else {
                            throw NSError(
                                domain: "CopyTaskSheet",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "Goal must be a positive integer"]
                            )
                        }
                        overrides.action = action.trimmingCharacters(in: .whitespacesAndNewlines)
                        overrides.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        overrides.maxCount = parsedMax
                    }
                    if isAchievement {
                        overrides.achievementTrigger = trigger
                        if isTemplateMode {
                            guard let parsedRequired = Int(
                                requiredCountInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            ), parsedRequired > 0 else {
                                throw NSError(
                                    domain: "CopyTaskSheet",
                                    code: 2,
                                    userInfo: [NSLocalizedDescriptionKey:
                                        "Required count must be a positive integer"]
                                )
                            }
                            overrides.requiredCount = parsedRequired
                        }
                    }
                    newTask = try AppDatabase.shared.copyTask(
                        userId: userId,
                        source: source,
                        overrides: overrides
                    )
                }

                DispatchQueue.main.async {
                    saving = false
                    onCopied(newTask)
                }
            } catch {
                DispatchQueue.main.async {
                    saving = false
                    self.error = (error as NSError).localizedDescription
                }
            }
        }
    }
}
