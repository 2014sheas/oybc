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
///
/// Visual design: Riso vocabulary — ScrollView over `Color.risoPaper`,
/// NavigationStack toolbar with a gold pill Save button and a muted Cancel.
/// Each section is a `.risoCard(fill: .risoPaper2)` block with a
/// `.risoSectionLabel()` heading. Text fields use the kit's
/// `RisoTextField` / `RisoNumberField`; pickers use `RisoSegmented`
/// (2-option rows) or a Riso-styled `Menu` (6-option timeframe row).
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // ── Type badge + title context ──────────────────────────
                    headerBadge

                    // ── Common fields ───────────────────────────────────────
                    commonSection

                    // ── Counting ────────────────────────────────────────────
                    if task.type == .counting {
                        countingSection
                    }

                    // ── Achievement ─────────────────────────────────────────
                    if task.type == .achievement {
                        achievementSection
                    }

                    // ── Compound hint ───────────────────────────────────────
                    if task.type == .compound {
                        compoundHintSection
                    }

                    // ── Time window ─────────────────────────────────────────
                    timeWindowSection
                }
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit task")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        Text("Save")
                            .font(.risoHead(13, .extraBold))
                            .foregroundStyle(Color.risoInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.risoGold))
                            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    }
                    .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }

    // MARK: - Header

    /// A tasteful type badge + truncated task title at the top of the sheet,
    /// giving the user instant context about what they are editing.
    private var headerBadge: some View {
        HStack(spacing: 8) {
            RisoTypeBadge(kind: task.type.risoKind, style: .pill)
            Text(task.title)
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections

    /// Title + Description card.
    private var commonSection: some View {
        risoSection(label: "Details") {
            VStack(alignment: .leading, spacing: 11) {
                fieldRow(label: "Title") {
                    RisoTextField(placeholder: "Task title", text: $title)
                }
                fieldRow(label: "Description") {
                    RisoTextField(
                        placeholder: "Optional description",
                        text: $description,
                        axis: .vertical,
                        reservedLines: 3
                    )
                }
            }
        }
    }

    /// Counting-specific fields: Action / Goal / Unit.
    private var countingSection: some View {
        risoSection(label: "Counting") {
            VStack(alignment: .leading, spacing: 11) {
                fieldRow(label: "Action") {
                    RisoTextField(placeholder: "e.g. Run", text: $action)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Goal")
                        RisoNumberField(placeholder: "5", text: $maxCountStr)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Unit")
                        RisoTextField(placeholder: "e.g. miles", text: $unit)
                    }
                }
            }
        }
    }

    /// Achievement-specific fields: Trigger + Watches mode + picker + required count.
    private var achievementSection: some View {
        risoSection(label: "Achievement") {
            VStack(alignment: .leading, spacing: 11) {
                // Trigger — Greenlog / Bingo
                fieldRow(label: "Completes on") {
                    RisoSegmented(
                        options: [
                            (value: AchievementTrigger.greenlog, label: "Greenlog"),
                            (value: AchievementTrigger.bingo,    label: "Bingo"),
                        ],
                        selection: $trigger
                    )
                }

                // Watches mode — Specific board / Recurring template
                fieldRow(label: "Watches") {
                    RisoSegmented(
                        options: [
                            (value: Patch.RefMode.board,    label: "Specific board"),
                            (value: Patch.RefMode.template, label: "Recurring template"),
                        ],
                        selection: $refMode
                    )
                }

                // Target picker
                if refMode == .board {
                    fieldRow(label: "Board") {
                        risoMenuPicker(
                            placeholder: "— select a board —",
                            items: availableBoards.map { ($0.id, $0.name) },
                            selectedId: $selectedBoardId
                        )
                    }
                } else {
                    fieldRow(label: "Template") {
                        risoMenuPicker(
                            placeholder: "— select a template —",
                            items: availableTemplates.map { ($0.id, $0.name) },
                            selectedId: $selectedTemplateId
                        )
                    }
                    fieldRow(label: "Required count") {
                        RisoNumberField(placeholder: "e.g. 3", text: $requiredCountStr)
                    }
                }
            }
        }
    }

    /// Compound hint card — shown when the task type is compound.
    private var compoundHintSection: some View {
        risoSection(label: "Compound") {
            Text("Compound subtasks are edited from the board-creation wizard. The title and description can still be changed here.")
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Time window card — shown for all task types.
    private var timeWindowSection: some View {
        risoSection(label: "Time window (optional)") {
            VStack(alignment: .leading, spacing: 11) {
                // Timeframe — 6 options; use a Riso-styled Menu row so all
                // options fit cleanly at 393pt without a cramped segmented bar.
                fieldRow(label: "Timeframe") {
                    risoTimeframeMenu
                }

                if timeframe != nil {
                    // Start date
                    HStack {
                        Text("Start date")
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoInk)
                        Spacer()
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { startDate ?? Date() },
                                set: { startDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .tint(Color.risoBlue)
                    }
                    // End date
                    HStack {
                        Text("End date")
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoInk)
                        Spacer()
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { endDate ?? Date() },
                                set: { endDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .tint(Color.risoBlue)
                    }
                }
            }
        }
    }

    // MARK: - Timeframe Menu

    /// Riso-styled Menu row for the 6-option timeframe picker. Ink keyline,
    /// chevron trailing, selected label shown inline.
    private var risoTimeframeMenu: some View {
        Menu {
            Button("None") { timeframe = nil }
            Divider()
            Button("Daily")   { timeframe = .daily }
            Button("Weekly")  { timeframe = .weekly }
            Button("Monthly") { timeframe = .monthly }
            Button("Yearly")  { timeframe = .yearly }
            Button("Custom")  { timeframe = .custom }
        } label: {
            HStack {
                Text(timeframeLabel)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
        }
    }

    /// Human-readable label for the currently selected timeframe.
    private var timeframeLabel: String {
        switch timeframe {
        case .none:    return "None"
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        case .custom:  return "Custom"
        }
    }

    // MARK: - Shared Riso layout helpers

    /// A card section: `.risoSectionLabel()` heading above a `.risoCard` body.
    ///
    /// - Parameters:
    ///   - label: The uppercase section heading text.
    ///   - content: The card interior content.
    @ViewBuilder
    private func risoSection<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .risoSectionLabel()
            content()
                .padding(12)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
        }
    }

    /// Label + field stacked vertically.
    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            content()
        }
    }

    /// Muted uppercase field label matching the Riso spec's `fieldLabel` helper.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .risoSectionLabel()
    }

    /// Riso-styled Menu picker row for board / template selection.
    ///
    /// - Parameters:
    ///   - placeholder: Text shown when nothing is selected (empty string id).
    ///   - items: `(id, name)` pairs to populate the menu.
    ///   - selectedId: Binding to the currently selected id string.
    private func risoMenuPicker(
        placeholder: String,
        items: [(String, String)],
        selectedId: Binding<String>
    ) -> some View {
        Menu {
            Button(placeholder) { selectedId.wrappedValue = "" }
            Divider()
            ForEach(items, id: \.0) { id, name in
                Button(name) { selectedId.wrappedValue = id }
            }
        } label: {
            let currentName = items.first(where: { $0.0 == selectedId.wrappedValue })?.1
            HStack {
                Text(currentName ?? placeholder)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(currentName != nil ? Color.risoInk : Color.risoMuted)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
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

// MARK: - TaskType + RisoTaskKind bridge

private extension TaskType {
    /// Maps a `TaskType` to the matching `RisoTaskKind` for badge rendering.
    var risoKind: RisoTaskKind {
        switch self {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }
}
