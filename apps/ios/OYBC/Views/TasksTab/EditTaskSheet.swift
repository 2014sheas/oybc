import SwiftUI

/// Inline edit form for the Task detail surface. Extracted from
/// `TaskDetailView.swift` so both `TaskDetailView` (route-pushed) and
/// `TaskDetailSheetView` (sheet-over-board) can present it without
/// duplication.
///
/// M1 additions:
///   - Timeboxed fields: timeframe / startDate / endDate (all task types).
///   - Achievement re-target: mode toggle (specific board vs recurring
///     template) + picker. Cycle detection runs in the caller's save handler
///     before the DB write.
///
/// Compound subtasks are still edited from the board-creation wizard.
struct EditTaskSheet: View {
    let task: Task
    let onSubmit: (Patch) -> Void
    let onCancel: () -> Void

    // Available boards / templates loaded by the parent for the Achievement picker.
    var availableBoards: [Board] = []
    var availableTemplates: [RecurringBoardTemplate] = []

    // MARK: - Patch

    struct Patch {
        // Common
        var title: String
        var description: String
        // Counting
        var action: String
        var unit: String
        var maxCountStr: String
        // Timeboxed (all types) — nil means "no change"; clearTimeboxed=true
        // signals the user explicitly cleared the window.
        var timeframe: Timeframe?
        var startDate: String?
        var endDate: String?
        var clearTimeboxed: Bool
        // Achievement
        var trigger: AchievementTrigger
        var requiredCountStr: String
        // Achievement re-target
        var refMode: RefMode
        var selectedBoardId: String
        var selectedTemplateId: String

        enum RefMode {
            case board, template
        }
    }

    // MARK: - State

    @State private var title: String
    @State private var description: String
    @State private var action: String
    @State private var unit: String
    @State private var maxCountStr: String
    // Timeboxed
    @State private var timeframe: Timeframe?
    @State private var startDate: Date?
    @State private var endDate: Date?
    // Achievement
    @State private var trigger: AchievementTrigger
    @State private var requiredCountStr: String
    @State private var refMode: Patch.RefMode
    @State private var selectedBoardId: String
    @State private var selectedTemplateId: String

    // MARK: - Init

    init(
        task: Task,
        availableBoards: [Board] = [],
        availableTemplates: [RecurringBoardTemplate] = [],
        onSubmit: @escaping (Patch) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.availableBoards = availableBoards
        self.availableTemplates = availableTemplates
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _action = State(initialValue: task.action ?? "")
        _unit = State(initialValue: task.unit ?? "")
        _maxCountStr = State(initialValue: task.maxCount.map { String($0) } ?? "")
        // Timeboxed
        _timeframe = State(initialValue: task.timeframe)
        _startDate = State(initialValue: task.startDate.flatMap { iso in
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        })
        _endDate = State(initialValue: task.endDate.flatMap { iso in
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        })
        // Achievement
        _trigger = State(initialValue: task.achievementTrigger ?? .greenlog)
        _requiredCountStr = State(initialValue: task.requiredCount.map { String($0) } ?? "")
        _refMode = State(initialValue: task.referencedTemplateId != nil ? .template : .board)
        _selectedBoardId = State(initialValue: task.referencedBoardId ?? "")
        _selectedTemplateId = State(initialValue: task.referencedTemplateId ?? "")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // ── Common fields ──────────────────────────────────────────
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Description") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }

                // ── Counting ───────────────────────────────────────────────
                if task.type == .counting {
                    Section("Counting") {
                        TextField("Action (e.g. Run)", text: $action)
                        TextField("Max count", text: $maxCountStr)
                            .keyboardType(.numberPad)
                        TextField("Unit (e.g. miles)", text: $unit)
                    }
                }

                // ── Achievement ────────────────────────────────────────────
                if task.type == .achievement {
                    Section("Achievement") {
                        Picker("Trigger", selection: $trigger) {
                            Text("Greenlog").tag(AchievementTrigger.greenlog)
                            Text("Bingo").tag(AchievementTrigger.bingo)
                        }

                        Picker("Watches", selection: $refMode) {
                            Text("Specific board").tag(Patch.RefMode.board)
                            Text("Recurring template").tag(Patch.RefMode.template)
                        }

                        if refMode == .board {
                            Picker("Board", selection: $selectedBoardId) {
                                Text("— select a board —").tag("")
                                ForEach(availableBoards, id: \.id) { b in
                                    Text(b.name).tag(b.id)
                                }
                            }
                        } else {
                            Picker("Template", selection: $selectedTemplateId) {
                                Text("— select a template —").tag("")
                                ForEach(availableTemplates, id: \.id) { t in
                                    Text(t.name).tag(t.id)
                                }
                            }
                            TextField("Required count", text: $requiredCountStr)
                                .keyboardType(.numberPad)
                        }
                    }
                }

                // ── Compound hint ──────────────────────────────────────────
                if task.type == .compound {
                    Section {
                        Text("Compound subtasks are edited from the board-creation wizard. The title and description can still be changed here.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                // ── Timeboxed (all types) ──────────────────────────────────
                Section("Time window (optional)") {
                    Picker("Timeframe", selection: $timeframe) {
                        Text("None").tag(Optional<Timeframe>.none)
                        Text("Daily").tag(Optional(Timeframe.daily))
                        Text("Weekly").tag(Optional(Timeframe.weekly))
                        Text("Monthly").tag(Optional(Timeframe.monthly))
                        Text("Yearly").tag(Optional(Timeframe.yearly))
                        Text("Custom").tag(Optional(Timeframe.custom))
                    }
                    if timeframe != nil {
                        DatePicker(
                            "Start date",
                            selection: Binding(
                                get: { startDate ?? Date() },
                                set: { startDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        DatePicker(
                            "End date",
                            selection: Binding(
                                get: { endDate ?? Date() },
                                set: { endDate = $0 }
                            ),
                            displayedComponents: .date
                        )
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
                    Button("Save") { submit() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Submit

    private func submit() {
        let hadTimeboxed = task.timeframe != nil
        let nowHasTimeboxed = timeframe != nil
        let clearTimeboxed = hadTimeboxed && !nowHasTimeboxed

        // Snap to local start-of-day / end-of-day and serialize via
        // `wizardLocalISOString` so the calendar window matches the
        // wizard's storage convention (no timezone suffix, full-day
        // coverage). Earlier `ISO8601DateFormatter` path stored UTC
        // strings with `Z` suffix, which shifted the day in non-UTC
        // zones and didn't sit on day boundaries.
        let cal = Calendar.current
        func snapStart(_ d: Date) -> String {
            wizardLocalISOString(cal.startOfDay(for: d))
        }
        func snapEnd(_ d: Date) -> String {
            let startNext = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))!
            return wizardLocalISOString(startNext.addingTimeInterval(-0.001))
        }

        onSubmit(
            Patch(
                title: title,
                description: description,
                action: action,
                unit: unit,
                maxCountStr: maxCountStr,
                timeframe: timeframe,
                startDate: startDate.map { snapStart($0) },
                endDate: endDate.map { snapEnd($0) },
                clearTimeboxed: clearTimeboxed,
                trigger: trigger,
                requiredCountStr: requiredCountStr,
                refMode: refMode,
                selectedBoardId: selectedBoardId,
                selectedTemplateId: selectedTemplateId,
            )
        )
    }
}
