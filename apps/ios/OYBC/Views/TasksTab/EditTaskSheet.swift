import SwiftUI

/// Inline edit form for the Task detail surface. Extracted from
/// `TaskDetailView.swift` so both `TaskDetailView` (route-pushed) and
/// `TaskDetailSheetView` (sheet-over-board) can present it without
/// duplication.
///
/// V1 edit scope: title + description + scalar type-specific fields
/// (counting: action/maxCount/unit; achievement: trigger/requiredCount).
/// Compound subtasks are edited from the board-creation wizard.
struct EditTaskSheet: View {
    let task: Task
    let onSubmit: (Patch) -> Void
    let onCancel: () -> Void

    struct Patch {
        var title: String
        var description: String
        var action: String
        var unit: String
        var maxCountStr: String
        var trigger: AchievementTrigger
        var requiredCountStr: String
    }

    @State private var title: String
    @State private var description: String
    @State private var action: String
    @State private var unit: String
    @State private var maxCountStr: String
    @State private var trigger: AchievementTrigger
    @State private var requiredCountStr: String

    init(task: Task, onSubmit: @escaping (Patch) -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _action = State(initialValue: task.action ?? "")
        _unit = State(initialValue: task.unit ?? "")
        _maxCountStr = State(initialValue: task.maxCount.map { String($0) } ?? "")
        _trigger = State(initialValue: task.achievementTrigger ?? .greenlog)
        _requiredCountStr = State(initialValue: task.requiredCount.map { String($0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Description") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
                if task.type == .counting {
                    Section("Counting") {
                        TextField("Action (e.g. Run)", text: $action)
                        TextField("Max count", text: $maxCountStr)
                            .keyboardType(.numberPad)
                        TextField("Unit (e.g. miles)", text: $unit)
                    }
                }
                if task.type == .achievement {
                    Section("Achievement") {
                        Picker("Trigger", selection: $trigger) {
                            Text("Greenlog").tag(AchievementTrigger.greenlog)
                            Text("Bingo").tag(AchievementTrigger.bingo)
                        }
                        if task.referencedTemplateId != nil {
                            TextField("Required count", text: $requiredCountStr)
                                .keyboardType(.numberPad)
                        }
                    }
                }
                if task.type == .compound {
                    Section {
                        Text("Compound subtasks are edited from the board-creation wizard. The title and description can still be changed here.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSubmit(
                            Patch(
                                title: title,
                                description: description,
                                action: action,
                                unit: unit,
                                maxCountStr: maxCountStr,
                                trigger: trigger,
                                requiredCountStr: requiredCountStr,
                            )
                        )
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
