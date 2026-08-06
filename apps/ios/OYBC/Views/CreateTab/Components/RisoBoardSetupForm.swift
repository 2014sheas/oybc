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
/// Sections (per README §3 Step 1 + prototype `wizard.jsx`):
///   1. Board name — keyline input, red `*` required marker.
///   2. Timeframe — `RisoSegmented` (Daily/Weekly/Monthly/Yearly; adds Custom unless
///      recurring) + dashed-keyline date note.
///   3. Board size — three size cards with dot-matrix previews; selected = gold
///      fill + hard shadow, dots turn red.
///   4. Center square — `RisoSegmented` (Free Space / I'll choose / None); visible
///      only on odd boards. CHOSEN is suppressed in recurring mode.
///   5. Custom date pickers (when timeframe == .custom), in Riso cards.
///
/// Core boards skip sections 1–2 (name/timeframe) and show a locked-name chip
/// instead.
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
            timeframeSection
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

    // MARK: - Section: Timeframe

    @ViewBuilder
    private var timeframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIMEFRAME")
                .risoSectionLabel()

            // Segmented options — omit Custom in recurring mode. The "Custom"
            // segment covers both a dated range AND an ongoing (indefinite)
            // board; the End-date control inside the custom section is where
            // the user chooses "None" (ongoing) vs a date — so indefinite is
            // never a separate segment cluttering the row.
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
        var opts: [(value: Timeframe, label: String)] = [
            (.daily,   "Daily"),
            (.weekly,  "Weekly"),
            (.monthly, "Monthly"),
            (.yearly,  "Yearly"),
        ]
        // Custom (which also hosts the ongoing/no-end-date option) is excluded
        // from recurring boards — recurrence needs a computed window cadence.
        if !controller.isRecurring {
            opts.append((.custom, "Custom"))
        }
        return opts
    }

    /// Dashed-keyline note card: "This week · Jun 8 – 14" (mirrors `.r-note`).
    @ViewBuilder
    private var timeframeDateNote: some View {
        if let label = controller.timeframeDisplayLabel {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.risoMuted)
                // For recurring boards, prefix with cadence ("Every week · …").
                Text(controller.isRecurring
                     ? "\(formatRecurringCadence(timeframe: controller.timeframe)) · starting \(label)"
                     : label)
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

            HStack(spacing: 8) {
                ForEach([3, 4, 5], id: \.self) { n in
                    SizeCard(n: n, isSelected: controller.size == n) {
                        controller.updateSize(n)
                    }
                }
            }

            Text(tasksRequiredCaption)
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
        }
    }

    /// Live requirement line, recomputed from `size` + `centerType` via the
    /// shared `tasksNeededForBoard` helper (never hardcoded). Recurring
    /// boards get "at least" copy since an overfilled pool is valid and
    /// intended (spawns draw a random subset each window); one-off boards
    /// need exactly this many, so plain copy. Renders under the size
    /// selector in both the standard and core-board layouts (both call
    /// `sizeSection`) — this is what pre-empts the Tasks-step's dead-Next
    /// problem, so `RisoTasksPoolHeaderView` is left untouched (issue #321).
    private var tasksRequiredCaption: String {
        let n = controller.size
        let count = controller.tasksRequired
        return controller.isRecurring
            ? "A \(n)×\(n) board needs at least \(count) tasks."
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

// MARK: - SizeCard

/// Dot-matrix size card: 3×3 / 4×4 / 5×5.
///
/// CSS equivalent: `.r-sizecard` + `.r-sizecard.on { background: gold; box-shadow: 3px 3px 0 ink }`.
/// Dots are 7×7 pt squares with 2pt gaps; selected = gold background, dots turn red.
private struct SizeCard: View {
    let n: Int
    let isSelected: Bool
    let action: () -> Void

    private let dotSize: CGFloat = 7
    private let dotGap: CGFloat = 2

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                dotMatrix
                Text("\(n)×\(n)")
                    .font(.risoHead(14, .extraBold))
                    // Selected card is gold — non-inverting ink for dark mode.
                    .foregroundStyle(isSelected ? Color.risoInkStatic : Color.risoInk)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .risoCard(fill: isSelected ? .risoGold : .risoPaper2)
        }
        .buttonStyle(isSelected ? RisoButtonStyle(offset: Riso.Shadow.button) : RisoButtonStyle(offset: 0))
    }

    /// n×n grid of tiny squares (dot-matrix preview).
    @ViewBuilder
    private var dotMatrix: some View {
        VStack(spacing: dotGap) {
            ForEach(0..<n, id: \.self) { _ in
                HStack(spacing: dotGap) {
                    ForEach(0..<n, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? Color.risoRed : Color.risoPaper)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1)
                                    .strokeBorder(Color.risoInk, lineWidth: 1)
                            )
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
    }
}
