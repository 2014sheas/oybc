import SwiftUI

// MARK: - RisoBoardSetupForm

/// Wizard-only Riso-styled setup form for Step 1 of the board-creation wizard.
///
/// This is the wizard's create form. `BoardSetupFormView` is the separate
/// edit-only form used by `EditBoardSheet` (its old pre-Riso `.create` path
/// was removed once this component took over board creation).
///
/// Binds to the `BoardWizardViewModel` fields and calls its mutators
/// (`updateSize`, `updateTimeframe`, `updateCenterType`), keeping all
/// validation / VM state consistent.
///
/// Board Creation Split (iOS PR A) — this form now renders ONE of two fixed
/// shapes per `controller.isRecurring` (mode is locked at wizard init;
/// there's no more mid-form "Repeats" control that morphs the rest of the
/// fields):
///   - **One-off**: name → TIMEFRAME segmented (Daily/Weekly/Monthly/Yearly/
///     Custom) + date note/custom pickers → board size → center (Free/
///     Choose/None).
///   - **Recurring**: name → REPEATS EVERY segmented (Day/Week/Month/Year,
///     no Custom/ongoing) + dashed cadence note → board size → center
///     (Free/None — Choose is never offered).
///
/// Sections (per README §3 Step 1 + Handoff Spec's mode-difference table):
///   1. Board name — keyline input, red `*` required marker.
///   2. Schedule — one-off's Timeframe segmented + date note, OR recurring's
///      Repeats-every segmented + cadence note. Mutually exclusive.
///   3. Board size — `RisoBoardSizeCards` (3×3/4×4/5×5 dot-matrix cards).
///   4. Center square — `RisoSegmented` (Free Space / I'll choose / None); visible
///      only on odd boards. CHOSEN is suppressed in recurring mode.
///   5. Custom date pickers (one-off, when timeframe == .custom), in Riso cards.
///
/// Core boards skip sections 1–2 (name/schedule) and show a locked-name chip
/// instead. Core boards are always one-off (never recurring).
struct RisoBoardSetupForm: View {

    @Bindable var controller: BoardWizardViewModel

    // Local state mirrors for custom DatePicker <-> ISO string bridge.
    @State private var customStartAsDate: Date = Date()
    @State private var customEndAsDate: Date = Date().addingTimeInterval(7 * 24 * 3600)

    var body: some View {
        if controller.isCore {
            coreBoardLayout
        } else {
            standardLayout
        }
    }

    // MARK: - Standard layout

    @ViewBuilder
    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            nameSection
            if controller.isRecurring {
                recurringScheduleSection
            } else {
                timeframeSection
            }
            sizeSection
            if controller.isOddBoard {
                centerSection
            }
        }
    }

    // MARK: - Core board layout (size + center only)

    @ViewBuilder
    private var coreBoardLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Locked name chip
            HStack(spacing: 8) {
                Text("Core board for")
                    .risoSectionLabel()
                Text(controller.name.isEmpty ? "this window" : controller.name)
                    .font(.risoHead(14, .extraBold))
                    .foregroundStyle(Color.risoInk)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .risoCard()

            sizeSection
            if controller.isOddBoard {
                centerSection
            }
        }
    }

    // MARK: - Section: Board name

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Text("BOARD NAME")
                    .risoSectionLabel()
                Text("*")
                    .font(.risoBody(11, .bold))
                    .foregroundStyle(Color.risoRed)
            }
            RisoNameInput(text: Binding(
                get: { controller.name },
                set: { controller.name = $0 }
            ))
        }
    }

    // MARK: - Section: Timeframe (one-off only)

    /// One-off Setup's schedule field. Board Creation Split (iOS PR A) —
    /// this view is only ever mounted when `controller.isRecurring == false`
    /// (the caller branches in `standardLayout`), so the old repeatsValue
    /// gate + Custom-suppression are gone: Custom is always offered here.
    @ViewBuilder
    private var timeframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIMEFRAME")
                .risoSectionLabel()

            // The "Custom" segment covers both a dated range AND an ongoing
            // (indefinite) board; the End-date control inside the custom
            // section is where the user chooses "None" (ongoing) vs a date —
            // so indefinite is never a separate segment cluttering the row.
            RisoSegmented(
                options: timeframeOptions,
                selection: Binding(
                    get: { controller.timeframe == .indefinite ? .custom : controller.timeframe },
                    set: { newValue in
                        // "Custom" defaults to an ongoing board (End date =
                        // None); a date is opt-in. Only set it when arriving
                        // from a calendar timeframe — re-tapping Custom keeps the
                        // user's current End-date choice (date or None) intact.
                        if newValue == .custom {
                            if controller.timeframe != .custom && controller.timeframe != .indefinite {
                                controller.updateTimeframe(.indefinite)
                            }
                        } else {
                            controller.updateTimeframe(newValue)
                        }
                    }
                )
            )

            // Date region: custom pickers (covers dated + ongoing via the
            // End-date "None" option), or the computed-window note.
            switch controller.timeframe {
            case .custom, .indefinite:
                customDateSection
            default:
                timeframeDateNote
            }
        }
    }

    private var timeframeOptions: [(value: Timeframe, label: String)] {
        [
            (.daily,   "Daily"),
            (.weekly,  "Weekly"),
            (.monthly, "Monthly"),
            (.yearly,  "Yearly"),
            (.custom,  "Custom"),
        ]
    }

    /// Dashed-keyline note card: "Week of Aug 17 – 23, 2026" (mirrors `.r-note`).
    @ViewBuilder
    private var timeframeDateNote: some View {
        if let label = controller.timeframeDisplayLabel {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.risoMuted)
                Text(label)
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [6, 4]))
                    .foregroundStyle(Color.risoInk)
            )
        }
    }

    // MARK: - Section: Repeats every (recurring only)

    /// Recurring Setup's schedule field — Board Creation Split (iOS PR A).
    /// Replaces the retired mid-form "Repeats" segmented: a recurring
    /// wizard's cadence is set here directly via `updateTimeframe(_:)` (the
    /// wizard's mode itself, `isRecurring`, is fixed at init and can't be
    /// changed from this or any control). No Custom, no ongoing option —
    /// recurrence needs a computed window cadence.
    @ViewBuilder
    private var recurringScheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REPEATS EVERY")
                .risoSectionLabel()

            RisoSegmented(
                options: repeatsCadenceOptions,
                selection: Binding(
                    get: { controller.timeframe },
                    set: { controller.updateTimeframe($0) }
                )
            )

            recurringScheduleNote
        }
    }

    private var repeatsCadenceOptions: [(value: Timeframe, label: String)] {
        [
            (.daily,   "Day"),
            (.weekly,  "Week"),
            (.monthly, "Month"),
            (.yearly,  "Year"),
        ]
    }

    /// Canonical copy (README §Copy strings): "A fresh board every {day|
    /// week|month|year} · starts {window}".
    @ViewBuilder
    private var recurringScheduleNote: some View {
        if let label = controller.timeframeDisplayLabel {
            HStack(spacing: 8) {
                Image(systemName: "repeat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.risoMuted)
                Text("A fresh board every \(recurringCadenceNoun) · starts \(label)")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [6, 4]))
                    .foregroundStyle(Color.risoInk)
            )
        }
    }

    /// Lowercase singular cadence noun for the recurring note's "every
    /// {noun}" slot. `.custom`/`.indefinite` are unreachable while
    /// `isRecurring` (guarded by `updateTimeframe`) — `"week"` is a
    /// defensive fallback, never actually shown.
    private var recurringCadenceNoun: String {
        switch controller.timeframe {
        case .daily:   return "day"
        case .weekly:  return "week"
        case .monthly: return "month"
        case .yearly:  return "year"
        case .custom, .indefinite: return "week"
        }
    }

    // MARK: - Section: Custom dates

    @ViewBuilder
    private var customDateSection: some View {
        VStack(spacing: 10) {
            // Start date card
            DatePicker(
                "Start date",
                selection: $customStartAsDate,
                displayedComponents: .date
            )
            .font(.risoBody(14, .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .risoCard()
            .onChange(of: customStartAsDate) { _, newValue in
                controller.customStartDate = wizardCalendarISOString(newValue)
            }

            // End date card — a date OR "None" (ongoing). The trailing menu
            // offers "None" as a first-class option; picking None makes the
            // board indefinite (no deadline).
            HStack {
                Text("End date")
                    .font(.risoBody(14, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                if controller.timeframe == .indefinite {
                    Text("None")
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoInk)
                } else {
                    DatePicker(
                        "",
                        selection: $customEndAsDate,
                        in: customStartAsDate...,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .onChange(of: customEndAsDate) { _, newValue in
                        controller.customEndDate = wizardCalendarISOString(newValue)
                    }
                }
                Menu {
                    Button {
                        controller.updateTimeframe(.custom)
                        // Switching back from None — make sure a concrete end
                        // date exists so step-1 validation passes.
                        if controller.customEndDate.isEmpty {
                            controller.customEndDate = wizardCalendarISOString(customEndAsDate)
                        }
                    } label: {
                        endMenuLabel("Pick a date", selected: controller.timeframe == .custom)
                    }
                    Button {
                        controller.updateTimeframe(.indefinite)
                    } label: {
                        endMenuLabel("None — no end date", selected: controller.timeframe == .indefinite)
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .risoCard()
        }
        .onAppear {
            // Sync state mirrors from the controller's stored ISO strings.
            if controller.customStartDate.isEmpty {
                controller.customStartDate = wizardCalendarISOString(customStartAsDate)
            } else if let d = parseWizardCalendarDate(controller.customStartDate) {
                customStartAsDate = d
            }
            // Don't seed an end date for an ongoing board — it should stay
            // empty until the user picks "Pick a date" (which seeds it then).
            if controller.timeframe != .indefinite && controller.customEndDate.isEmpty {
                controller.customEndDate = wizardCalendarISOString(customEndAsDate)
            } else if let d = parseWizardCalendarDate(controller.customEndDate) {
                customEndAsDate = d
            }
        }
    }

    /// Menu row label — shows a checkmark on the active End-date option.
    @ViewBuilder
    private func endMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Section: Board size

    @ViewBuilder
    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOARD SIZE")
                .risoSectionLabel()

            // Board Creation Split (iOS PR A) — extracted to the reusable
            // `RisoBoardSizeCards` component (`Views/Components/`) so it's
            // shared, not re-implemented per surface.
            RisoBoardSizeCards(selectedSize: controller.size) { n in
                controller.updateSize(n)
            }

            Text(tasksRequiredCaption)
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
        }
    }

    /// Live requirement line, recomputed from `size` + `centerType` via the
    /// shared `tasksNeededForBoard` helper (never hardcoded). Renders under
    /// the size selector in both the standard and core-board layouts (both
    /// call `sizeSection`) — this is what pre-empts the Tasks-step's
    /// dead-Next problem, so `RisoTasksPoolHeaderView` is left untouched
    /// (issue #321).
    ///
    /// Board Creation Split (iOS PR A) — copy diverges per mode (README
    /// §Copy strings): one-off states the exact requirement against the
    /// board's own geometry; recurring drops the "A n×n board" framing
    /// entirely since overfill is the intended variety mechanism there.
    private var tasksRequiredCaption: String {
        let n = controller.size
        let count = controller.tasksRequired
        return controller.isRecurring
            ? "Needs at least \(count) tasks — extras rotate in."
            : "A \(n)×\(n) board needs \(count) tasks."
    }

    // MARK: - Section: Center square

    @ViewBuilder
    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CENTER SQUARE")
                .risoSectionLabel()

            RisoSegmented(
                options: centerOptions,
                selection: Binding(
                    get: { controller.centerType },
                    set: { controller.updateCenterType($0) }
                )
            )

            // Extra affordances depending on selection.
            if controller.centerType == .chosen {
                Text("You'll pick the center task in the next step.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }

        }
    }

    private var centerOptions: [(value: CenterSquareType, label: String)] {
        // Short labels so the (up to 3) equal-width segments don't clip.
        var opts: [(value: CenterSquareType, label: String)] = [
            (.free, "Free"),
        ]
        // CHOSEN is suppressed for recurring boards (same rule as BoardSetupFormView).
        if !controller.isRecurring {
            opts.append((.chosen, "Choose"))
        }
        opts.append((.none, "None"))
        return opts
    }
}

// MARK: - RisoNameInput

/// Keyline text field: 2px ink border, 16px Bricolage 700, paper2 bg.
/// Focus state adds a 3px hard shadow (no glow) per spec.
///
/// CSS equivalent: `.r-input` + `.r-input:focus { box-shadow: 3px 3px 0 var(--ink) }`.
private struct RisoNameInput: View {
    @Binding var text: String
    var placeholder: String = "e.g., \"Spring Goals\""

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.risoHead(16, .bold))
            .foregroundStyle(Color.risoInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.risoPaper2)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: isFocused ? 3 : Riso.Keyline.container)
            )
            .background(
                // Hard shadow (3px offset) — visible only when focused.
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(Color.risoInk)
                    .offset(x: isFocused ? Riso.Shadow.button : 0,
                            y: isFocused ? Riso.Shadow.button : 0)
                    .animation(.easeOut(duration: Riso.pressDuration), value: isFocused)
            )
            .focused($isFocused)
            .autocorrectionDisabled()
    }
}
