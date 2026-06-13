import SwiftUI

// MARK: - RisoBoardSetupForm

/// Wizard-only Riso-styled setup form for Step 1 of the board-creation wizard.
///
/// This is a NET-NEW component — it does NOT replace or modify
/// `BoardSetupFormView`, which remains shared with `EditBoardSheet` and is
/// intentionally left unstyled here. Any changes to the shared form must go
/// through `BoardSetupFormView`.
///
/// Binds to the same `BoardWizardViewModel` fields and calls the same mutators
/// (`updateSize`, `updateTimeframe`, `updateCenterType`) as `BoardSetupFormView`'s
/// create-mode path, so all validation / VM state stays identical.
///
/// Sections (per README §3 Step 1 + prototype `wizard.jsx`):
///   1. Board name — keyline input, red `*` required marker.
///   2. Timeframe — `RisoSegmented` (Daily/Weekly/Monthly/Yearly; adds Custom unless
///      recurring) + dashed-keyline date note.
///   3. Board size — three size cards with dot-matrix previews; selected = gold
///      fill + hard shadow, dots turn red.
///   4. Center square — `RisoSegmented` (Free Space / I'll choose / None); visible
///      only on odd boards; Custom Name field when `.customFree`.
///      CHOSEN is suppressed in recurring mode (same rule as `BoardSetupFormView`).
///   5. Custom date pickers (when timeframe == .custom), in Riso cards.
///
/// Core boards skip sections 1–2 (name/timeframe) and show a locked-name chip
/// instead — same as `BoardSetupFormView`'s `isCore` branch.
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

            // Segmented options — omit Custom in recurring mode.
            RisoSegmented(
                options: timeframeOptions,
                selection: Binding(
                    get: { controller.timeframe },
                    set: { controller.updateTimeframe($0) }
                )
            )

            // Date note (non-custom) or custom date pickers.
            if controller.timeframe != .custom {
                timeframeDateNote
            } else {
                customDateSection
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

            // End date card (min = start date)
            DatePicker(
                "End date",
                selection: $customEndAsDate,
                in: customStartAsDate...,
                displayedComponents: .date
            )
            .font(.risoBody(14, .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .risoCard()
            .onChange(of: customEndAsDate) { _, newValue in
                controller.customEndDate = wizardCalendarISOString(newValue)
            }
        }
        .onAppear {
            // Sync state mirrors from the controller's stored ISO strings.
            if controller.customStartDate.isEmpty {
                controller.customStartDate = wizardCalendarISOString(customStartAsDate)
            } else if let d = parseWizardCalendarDate(controller.customStartDate) {
                customStartAsDate = d
            }
            if controller.customEndDate.isEmpty {
                controller.customEndDate = wizardCalendarISOString(customEndAsDate)
            } else if let d = parseWizardCalendarDate(controller.customEndDate) {
                customEndAsDate = d
            }
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
        }
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

            if controller.centerType == .customFree {
                RisoNameInput(
                    text: Binding(
                        get: { controller.centerCustomName },
                        set: { controller.centerCustomName = $0 }
                    ),
                    placeholder: "Custom center name (e.g. Wild Card)"
                )
            }
        }
    }

    private var centerOptions: [(value: CenterSquareType, label: String)] {
        var opts: [(value: CenterSquareType, label: String)] = [
            (.free,       "Free Space"),
            (.customFree, "Custom Name"),
        ]
        // CHOSEN is suppressed for recurring boards (same rule as BoardSetupFormView).
        if !controller.isRecurring {
            opts.append((.chosen, "I'll choose"))
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
                    .foregroundStyle(Color.risoInk)
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
