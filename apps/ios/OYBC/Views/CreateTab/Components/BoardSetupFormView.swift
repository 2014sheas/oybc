import SwiftUI

/// BoardSetupFormView — Pure presentational form for the wizard's
/// Setup step. iOS twin of web's `BoardSetupForm`.
///
/// Takes the wizard view-model via `@Bindable` so SwiftUI controls can
/// drive its state directly. The view is wizard-specific (not a
/// generic reusable form) — by accepting the view-model directly we
/// avoid plumbing 10+ individual `@Binding` props through the call
/// site.
struct BoardSetupFormView: View {
    @Bindable var controller: BoardWizardViewModel
    /// Phase 6.1: when true, render the Timeframe field as a read-only
    /// chip rather than the segmented selector. Used by the recurring-
    /// banner flow so the user can't accidentally pick a different
    /// timeframe than the banner promised.
    var lockTimeframe: Bool = false

    /// `@State` mirrors of the controller's `yyyy-MM-dd` strings, used
    /// as `Date` bindings for `DatePicker`. Two-way synced with the
    /// controller via `.onAppear` and `.onChange`.
    @State private var customStartDateAsDate: Date = Date()
    @State private var customEndDateAsDate: Date = Date().addingTimeInterval(7 * 24 * 60 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

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

            // ── Board size ──
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

            // ── Timeframe ──
            VStack(alignment: .leading, spacing: 4) {
                Text("Timeframe")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if lockTimeframe {
                    // Locked variant: show the selected timeframe as a
                    // disabled chip with an explanatory hint. Mirrors web's
                    // BoardSetupForm `timeframeLocked` branch.
                    HStack {
                        Text(timeframeLabel(controller.timeframe))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(6)
                        Spacer()
                    }
                    Text("Timeframe set from the recurring boards banner. Cancel and use \"Start a new board\" to pick a different one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                } else {
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
                    if controller.isRecurring {
                        Text("Recurring boards use computed windows — Custom timeframe is unavailable. Toggle \"Make recurring\" off to pick custom dates.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }

            // ── Recurring toggle (Phase 6.2) ──
            // Rendered between Timeframe and Center square so the user
            // sees recurrence visibly affect the timeframe picker. The
            // pool is always loose-fit — extras become the random
            // subset for each spawn.
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { controller.isRecurring },
                    set: { controller.updateIsRecurring($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make recurring")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Auto-spawn a fresh board each window from a task pool.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if controller.isRecurring {
                    Text("Pool can be larger than the board; the spawn picks a random subset each window.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            // ── Auto-calculated timeframe display ──
            if controller.timeframe != .custom, let boundaries = controller.computedBoundaries {
                VStack(alignment: .leading, spacing: 2) {
                    if let label = controller.timeframeDisplayLabel {
                        Text(label)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    let start = DateFormatter.localizedString(from: boundaries.start, dateStyle: .medium, timeStyle: .none)
                    let end = DateFormatter.localizedString(from: boundaries.end, dateStyle: .medium, timeStyle: .none)
                    Text("\(start) – \(end)")
                        .font(.caption)
                        .foregroundColor(.secondary)
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

            // ── Center square (odd boards only) ──
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
                        Text("You'll mark which selected task is the center in the next step.")
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

            // ── Randomize toggle ──
            Toggle("Randomize task positions on the board", isOn: $controller.isRandomized)
                .font(.subheadline)
        }
    }

    // MARK: - Display helpers

    private func timeframeLabel(_ timeframe: Timeframe) -> String {
        switch timeframe {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        case .custom:  return "Custom"
        }
    }

}
