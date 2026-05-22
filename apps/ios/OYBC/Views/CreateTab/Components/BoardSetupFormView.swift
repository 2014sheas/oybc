import SwiftUI

/// BoardSetupFormView — Pure presentational form for the wizard's
/// Setup step. iOS twin of web's `BoardSetupForm`.
///
/// Takes the wizard view-model via `@Bindable` so SwiftUI controls can
/// drive its state directly. The view is wizard-specific (not a
/// generic reusable form) — by accepting the view-model directly we
/// avoid plumbing 10+ individual `@Binding` props through the call
/// site.
///
/// Three layouts, gated by the controller's read-only `isCore` /
/// `isRecurring` flags (both set at wizard entry):
///   - **Core** (`isCore`): only board size + center, with a read-only
///     window caption. Title/timeframe are fixed to the window (#70).
///   - **Recurring** (`isRecurring`): name + size + timeframe (no
///     Custom) + center, with a cadence label. No "Make recurring"
///     toggle — recurrence is chosen at the Create hub (#71).
///   - **One-off** (default): name + size + timeframe (incl. Custom) +
///     center.
///
/// Placement is always randomized (#69), so there's no randomize toggle.
struct BoardSetupFormView: View {
    @Bindable var controller: BoardWizardViewModel

    /// `@State` mirrors of the controller's `yyyy-MM-dd` strings, used
    /// as `Date` bindings for `DatePicker`. Two-way synced with the
    /// controller via `.onAppear` and `.onChange`.
    @State private var customStartDateAsDate: Date = Date()
    @State private var customEndDateAsDate: Date = Date().addingTimeInterval(7 * 24 * 60 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.isCore {
                // Issue #70 — core boards only configure size + center.
                // The title is auto-set from the window label (shown
                // read-only) and the timeframe is fixed to the window,
                // so neither is a control here.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Core board for")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(controller.name.isEmpty ? "this window" : controller.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)

                sizeSection
                centerSection
            } else {
                // ── Board name ──
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board name")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    +
                    Text("*")
                        .font(.subheadline)
                        .foregroundColor(.red)
                    TextField("e.g., \"Spring Goals\"", text: $controller.name)
                        .textFieldStyle(.roundedBorder)
                }

                sizeSection

                // ── Timeframe ──
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeframe")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    // When `isRecurring`, hide Custom (recurring templates
                    // exclude `Timeframe.custom` — no computed window). The
                    // `updateTimeframe` setter rejects CUSTOM defensively
                    // even if the picker were to surface it.
                    Picker("Timeframe", selection: Binding(
                        get: { controller.timeframe },
                        set: { controller.updateTimeframe($0) }
                    )) {
                        Text("Daily").tag(Timeframe.daily)
                        Text("Weekly").tag(Timeframe.weekly)
                        Text("Monthly").tag(Timeframe.monthly)
                        Text("Yearly").tag(Timeframe.yearly)
                        if !controller.isRecurring {
                            Text("Custom").tag(Timeframe.custom)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // ── Auto-calculated timeframe display ──
                // Recurring boards show a cadence label ("Every week") with
                // the first-spawn window as the caption, so the wizard makes
                // the recurrence visible instead of looking identical to a
                // one-off board for the same window.
                if controller.timeframe != .custom, let boundaries = controller.computedBoundaries {
                    VStack(alignment: .leading, spacing: 2) {
                        let windowLabel = controller.timeframeDisplayLabel ?? ""
                        if controller.isRecurring {
                            Text(recurringCadenceLabel(timeframe: controller.timeframe))
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
                if controller.timeframe == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker(
                            "Start date",
                            selection: $customStartDateAsDate,
                            displayedComponents: .date
                        )
                        .font(.subheadline)
                        .onChange(of: customStartDateAsDate) { _, newValue in
                            controller.customStartDate = wizardCalendarISOString(newValue)
                        }
                        DatePicker(
                            "End date",
                            selection: $customEndDateAsDate,
                            in: customStartDateAsDate...,
                            displayedComponents: .date
                        )
                        .font(.subheadline)
                        .onChange(of: customEndDateAsDate) { _, newValue in
                            controller.customEndDate = wizardCalendarISOString(newValue)
                        }
                    }
                    .onAppear {
                        // Seed `@State` mirrors so a wizard re-mount shows
                        // sensible default dates.
                        if controller.customStartDate.isEmpty {
                            controller.customStartDate = wizardCalendarISOString(customStartDateAsDate)
                        } else if let d = parseWizardCalendarDate(controller.customStartDate) {
                            customStartDateAsDate = d
                        }
                        if controller.customEndDate.isEmpty {
                            controller.customEndDate = wizardCalendarISOString(customEndDateAsDate)
                        } else if let d = parseWizardCalendarDate(controller.customEndDate) {
                            customEndDateAsDate = d
                        }
                    }
                }

                centerSection
            }
        }
    }

    // MARK: - Shared sections

    /// Board-size picker — shared by all three layouts.
    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Board size")
                .font(.subheadline)
                .fontWeight(.semibold)
            Picker("Board size", selection: Binding(
                get: { controller.size },
                set: { controller.updateSize($0) }
            )) {
                Text("3×3").tag(3)
                Text("4×4").tag(4)
                Text("5×5").tag(5)
            }
            .pickerStyle(.segmented)
        }
    }

    /// Center-square picker (odd boards only) + custom-name field —
    /// shared by all three layouts.
    @ViewBuilder
    private var centerSection: some View {
        if controller.isOddBoard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Center square")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Picker("Center square", selection: Binding(
                    get: { controller.centerType },
                    set: { controller.updateCenterType($0) }
                )) {
                    Text("Free Space").tag(CenterSquareType.free)
                    Text("Custom Name").tag(CenterSquareType.customFree)
                    // CHOSEN center is excluded for recurring templates
                    // (MVP scope — would require a per-template
                    // `centerTaskId`).
                    if !controller.isRecurring {
                        Text("Pick one of my board tasks").tag(CenterSquareType.chosen)
                    }
                    Text("None").tag(CenterSquareType.none)
                }
                .pickerStyle(.menu)

                if controller.centerType == .chosen {
                    Text("You'll pick the center in the next step.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }

                if controller.centerType == .customFree {
                    TextField("Custom center name (e.g., \"Wild Card\")", text: $controller.centerCustomName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

}
