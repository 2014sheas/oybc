import SwiftUI

// MARK: - BoardSetupFormMode

/// Rendering mode for `BoardSetupFormView`.
///
/// - `create`: Full wizard setup step. Board size is editable. Wizard-only
///   affordances (size picker, recurring cadence label, etc.) are shown.
/// - `editActive`: Editing an already-active board. Board size is omitted
///   from the form (the `EditBoardSheet` renders it as a read-only chip).
///   Wizard-only affordances are hidden.
enum BoardSetupFormMode {
    case create
    case editActive
}

// MARK: - BoardSetupFormView

/// BoardSetupFormView — Pure presentational form for the wizard's
/// Setup step. iOS twin of web's `BoardSetupForm`.
///
/// **Modes**:
///   - `.create` (default for wizard callers): driven by a `BoardWizardViewModel`.
///     Three sub-layouts gated by `isCore` / `isRecurring`.
///   - `.editActive`: driven by explicit `@Binding` props from `EditBoardSheet`.
///     Board size is suppressed (rendered as a read-only chip in the enclosing
///     sheet). Recurring/core affordances are always hidden.
///
/// Existing callers that use `init(controller:)` continue to work unchanged.
struct BoardSetupFormView: View {

    // ── Mode + wizard controller ───────────────────────────────────────────

    var mode: BoardSetupFormMode
    var controller: BoardWizardViewModel?

    // ── Edit-active: explicit bindings ────────────────────────────────────

    var nameBinding: Binding<String>
    var timeframeBinding: Binding<Timeframe>
    var customStartDateBinding: Binding<Date>
    var customEndDateBinding: Binding<Date>
    var centerTypeBinding: Binding<CenterSquareType>
    var centerCustomNameBinding: Binding<String>
    var weekStartDay: String
    /// When true (edit-active only), the CHOSEN option in the center picker is
    /// guarded with an explanatory note.
    var chosenCenterDisabled: Bool

    // ── State mirrors for custom DatePicker bindings (create mode) ─────────

    @State private var customStartDateAsDate: Date = Date()
    @State private var customEndDateAsDate: Date = Date().addingTimeInterval(7 * 24 * 60 * 60)

    // MARK: - Body

    var body: some View {
        if mode == .editActive {
            editActiveBody
        } else {
            createBody
        }
    }

    // MARK: - Create layout (wizard-driven)

    @ViewBuilder
    private var createBody: some View {
        // Wrap the optional controller in a local @Bindable so SwiftUI installs
        // proper observation tracking for the @Observable BoardWizardViewModel.
        // Without @Bindable, a plain stored `var controller: BoardWizardViewModel?`
        // may not trigger body re-evaluation when ctrl.size / ctrl.centerType
        // change, even though the object is @Observable. (Copilot review #6)
        if let unwrapped = controller {
            @Bindable var ctrl = unwrapped
            VStack(alignment: .leading, spacing: 16) {
                if ctrl.isCore {
                    // Issue #70 — core boards only configure size + center.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Core board for")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(ctrl.name.isEmpty ? "this window" : ctrl.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)

                    wizardSizeSection(ctrl: ctrl)
                    wizardCenterSection(ctrl: ctrl)
                } else {
                    // ── Board name ──
                    VStack(alignment: .leading, spacing: 4) {
                        (Text("Board name")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        +
                        Text("*")
                            .font(.subheadline)
                            .foregroundColor(.red))
                        TextField("e.g., \"Spring Goals\"", text: Binding(
                            get: { ctrl.name },
                            set: { ctrl.name = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    wizardSizeSection(ctrl: ctrl)

                    // ── Timeframe ──
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timeframe")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Picker("Timeframe", selection: Binding(
                            get: { ctrl.timeframe },
                            set: { ctrl.updateTimeframe($0) }
                        )) {
                            Text("Daily").tag(Timeframe.daily)
                            Text("Weekly").tag(Timeframe.weekly)
                            Text("Monthly").tag(Timeframe.monthly)
                            Text("Yearly").tag(Timeframe.yearly)
                            if !ctrl.isRecurring {
                                Text("Custom").tag(Timeframe.custom)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // ── Auto-calculated timeframe display ──
                    if ctrl.timeframe != .custom, let boundaries = ctrl.computedBoundaries {
                        VStack(alignment: .leading, spacing: 2) {
                            let windowLabel = ctrl.timeframeDisplayLabel ?? ""
                            if ctrl.isRecurring {
                                Text(recurringCadenceLabel(timeframe: ctrl.timeframe))
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("Starting: \(windowLabel)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(windowLabel)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                let start = DateFormatter.localizedString(from: boundaries.start, dateStyle: .medium, timeStyle: .none)
                                let end = DateFormatter.localizedString(from: boundaries.end, dateStyle: .medium, timeStyle: .none)
                                Text("\(start) – \(end)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                    }

                    // ── Custom date pickers ──
                    if ctrl.timeframe == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            DatePicker(
                                "Start date",
                                selection: $customStartDateAsDate,
                                displayedComponents: .date
                            )
                            .font(.subheadline)
                            .onChange(of: customStartDateAsDate) { _, newValue in
                                ctrl.customStartDate = wizardCalendarISOString(newValue)
                            }
                            DatePicker(
                                "End date",
                                selection: $customEndDateAsDate,
                                in: customStartDateAsDate...,
                                displayedComponents: .date
                            )
                            .font(.subheadline)
                            .onChange(of: customEndDateAsDate) { _, newValue in
                                ctrl.customEndDate = wizardCalendarISOString(newValue)
                            }
                        }
                        .onAppear {
                            if ctrl.customStartDate.isEmpty {
                                ctrl.customStartDate = wizardCalendarISOString(customStartDateAsDate)
                            } else if let d = parseWizardCalendarDate(ctrl.customStartDate) {
                                customStartDateAsDate = d
                            }
                            if ctrl.customEndDate.isEmpty {
                                ctrl.customEndDate = wizardCalendarISOString(customEndDateAsDate)
                            } else if let d = parseWizardCalendarDate(ctrl.customEndDate) {
                                customEndDateAsDate = d
                            }
                        }
                    }

                    wizardCenterSection(ctrl: ctrl)
                }
            }
        }
    }

    // MARK: - Edit-active layout (explicit bindings)
    //
    // Board size is suppressed — the enclosing `EditBoardSheet` renders it
    // as a read-only Form row. Recurring / core affordances are always hidden.
    // This section emits SwiftUI `Section` views for use inside a `Form`.

    @ViewBuilder
    private var editActiveBody: some View {
        // ── Board name ──
        Section("Board name") {
            TextField("e.g., \"Spring Goals\"", text: nameBinding)
        }

        // ── Timeframe ──
        Section("Timeframe") {
            Picker("Timeframe", selection: timeframeBinding) {
                Text("Daily").tag(Timeframe.daily)
                Text("Weekly").tag(Timeframe.weekly)
                Text("Monthly").tag(Timeframe.monthly)
                Text("Yearly").tag(Timeframe.yearly)
                Text("Custom").tag(Timeframe.custom)
            }

            if timeframeBinding.wrappedValue != .custom,
               let boundaries = computeTimeframeBoundaries(
                   timeframe: timeframeBinding.wrappedValue,
                   referenceDate: Date(),
                   weekStartDay: weekStartDay
               ) {
                let start = DateFormatter.localizedString(from: boundaries.start, dateStyle: .medium, timeStyle: .none)
                let end = DateFormatter.localizedString(from: boundaries.end, dateStyle: .medium, timeStyle: .none)
                Text("\(start) – \(end)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if timeframeBinding.wrappedValue == .custom {
                DatePicker("Start date", selection: customStartDateBinding, displayedComponents: .date)
                DatePicker(
                    "End date",
                    selection: customEndDateBinding,
                    in: customStartDateBinding.wrappedValue...,
                    displayedComponents: .date
                )
            }
        }

        // ── Center square ──
        Section("Center square") {
            Picker("Center square", selection: centerTypeBinding) {
                Text("Free Space").tag(CenterSquareType.free)
                Text("Custom Name").tag(CenterSquareType.customFree)
                Text("Pick one of my board tasks").tag(CenterSquareType.chosen)
                Text("None").tag(CenterSquareType.none)
            }
            .pickerStyle(.menu)
            .onChange(of: centerTypeBinding.wrappedValue) { _, newVal in
                // Revert to .free if the user somehow selects CHOSEN
                // when no candidate tasks exist.
                if newVal == .chosen && chosenCenterDisabled {
                    centerTypeBinding.wrappedValue = .free
                }
            }

            if centerTypeBinding.wrappedValue == .chosen && chosenCenterDisabled {
                Text("No tasks are placed on this board — CHOSEN is unavailable.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if centerTypeBinding.wrappedValue == .chosen {
                Text("The existing center task is kept. Switch away to change the center type.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if centerTypeBinding.wrappedValue == .customFree {
                TextField(
                    "Custom center name (e.g., \"Wild Card\")",
                    text: centerCustomNameBinding
                )
            }
        }
    }

    // MARK: - Shared sub-views (create mode)

    @ViewBuilder
    private func wizardSizeSection(ctrl: BoardWizardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Board size")
                .font(.subheadline)
                .fontWeight(.semibold)
            Picker("Board size", selection: Binding(
                get: { ctrl.size },
                set: { ctrl.updateSize($0) }
            )) {
                Text("3×3").tag(3)
                Text("4×4").tag(4)
                Text("5×5").tag(5)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func wizardCenterSection(ctrl: BoardWizardViewModel) -> some View {
        if ctrl.isOddBoard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Center square")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Picker("Center square", selection: Binding(
                    get: { ctrl.centerType },
                    set: { ctrl.updateCenterType($0) }
                )) {
                    Text("Free Space").tag(CenterSquareType.free)
                    Text("Custom Name").tag(CenterSquareType.customFree)
                    if !ctrl.isRecurring {
                        Text("Pick one of my board tasks").tag(CenterSquareType.chosen)
                    }
                    Text("None").tag(CenterSquareType.none)
                }
                .pickerStyle(.menu)

                if ctrl.centerType == .chosen {
                    Text("You'll pick the center in the next step.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }

                if ctrl.centerType == .customFree {
                    TextField("Custom center name (e.g., \"Wild Card\")", text: Binding(
                        get: { ctrl.centerCustomName },
                        set: { ctrl.centerCustomName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}

// MARK: - Convenience inits

extension BoardSetupFormView {
    /// Wizard-mode initialiser — preserves the call site of all existing
    /// callers without requiring them to pass mode or binding parameters.
    init(controller: BoardWizardViewModel) {
        self.mode = .create
        self.controller = controller
        // Binding stubs — unused in create mode (wizard drives state via controller).
        self.nameBinding = .constant("")
        self.timeframeBinding = .constant(.monthly)
        self.customStartDateBinding = .constant(Date())
        self.customEndDateBinding = .constant(Date())
        self.centerTypeBinding = .constant(.free)
        self.centerCustomNameBinding = .constant("")
        self.weekStartDay = "monday"
        self.chosenCenterDisabled = false
    }

    /// Edit-active mode initialiser — takes explicit `@Binding` props.
    init(
        mode: BoardSetupFormMode,
        name: Binding<String>,
        timeframe: Binding<Timeframe>,
        customStartDate: Binding<Date>,
        customEndDate: Binding<Date>,
        centerType: Binding<CenterSquareType>,
        centerCustomName: Binding<String>,
        weekStartDay: String,
        chosenCenterDisabled: Bool = false
    ) {
        self.mode = mode
        self.controller = nil
        self.nameBinding = name
        self.timeframeBinding = timeframe
        self.customStartDateBinding = customStartDate
        self.customEndDateBinding = customEndDate
        self.centerTypeBinding = centerType
        self.centerCustomNameBinding = centerCustomName
        self.weekStartDay = weekStartDay
        self.chosenCenterDisabled = chosenCenterDisabled
    }
}
