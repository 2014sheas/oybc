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
                Picker("Timeframe", selection: $controller.timeframe) {
                    Text("Daily").tag(Timeframe.daily)
                    Text("Weekly").tag(Timeframe.weekly)
                    Text("Monthly").tag(Timeframe.monthly)
                    Text("Yearly").tag(Timeframe.yearly)
                    Text("Custom").tag(Timeframe.custom)
                }
                .pickerStyle(.segmented)
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
                        Text("Pick one of my board tasks").tag(CenterSquareType.chosen)
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
}
