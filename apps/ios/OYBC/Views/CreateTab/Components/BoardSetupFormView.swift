import SwiftUI

// MARK: - BoardSetupFormView

/// BoardSetupFormView — Riso-styled board setup form for editing an
/// already-active board. Driven by explicit `@Binding` props from
/// `EditBoardSheet`; board size is suppressed (rendered as a read-only chip in
/// the enclosing sheet), and recurring/core affordances don't apply to edits.
///
/// The board-CREATION wizard uses `RisoBoardSetupForm` instead — the older
/// pre-Riso `.create` path that once lived here was removed once the wizard
/// migrated.
struct BoardSetupFormView: View {

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

    // MARK: - Body

    var body: some View {
        editActiveBody
    }

    // MARK: - Edit-active layout (explicit bindings)
    //
    // Board size is suppressed — the enclosing `EditBoardSheet` renders it
    // as a Riso chip above this view. Recurring / core affordances are always
    // hidden. Sections use Riso card vocabulary matching `RisoBoardSetupForm`.

    @ViewBuilder
    private var editActiveBody: some View {
        // ── Board name ──
        editNameSection

        // ── Timeframe ──
        editTimeframeSection

        // ── Center square ──
        editCenterSection
    }

    // MARK: - Edit-active: Board name section

    @ViewBuilder
    private var editNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Text("BOARD NAME")
                    .risoSectionLabel()
                Text("*")
                    .font(.risoBody(11, .bold))
                    .foregroundStyle(Color.risoRed)
            }
            EditBoardNameInput(text: nameBinding)
        }
    }

    // MARK: - Edit-active: Timeframe section

    @ViewBuilder
    private var editTimeframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIMEFRAME")
                .risoSectionLabel()

            // Daily/Weekly/Monthly/Yearly/Custom. The "Custom" segment hosts
            // both a dated range and the ongoing (indefinite) board — the user
            // picks "None" in the End-date control to make it ongoing, so there
            // is no separate "Ongoing" segment crowding the row.
            RisoSegmented(
                options: [
                    (.daily,   "Daily"),
                    (.weekly,  "Weekly"),
                    (.monthly, "Monthly"),
                    (.yearly,  "Yearly"),
                    (.custom,  "Custom"),
                ],
                selection: Binding(
                    get: { timeframeBinding.wrappedValue == .indefinite ? .custom : timeframeBinding.wrappedValue },
                    set: { newValue in
                        // "Custom" defaults to ongoing (End date = None); a date
                        // is opt-in. Re-tapping Custom keeps the current
                        // End-date choice; arriving from a calendar timeframe
                        // lands on None.
                        if newValue == .custom {
                            if timeframeBinding.wrappedValue != .custom && timeframeBinding.wrappedValue != .indefinite {
                                timeframeBinding.wrappedValue = .indefinite
                            }
                        } else {
                            timeframeBinding.wrappedValue = newValue
                        }
                    }
                )
            )

            // Date region: custom pickers (dated + ongoing via the End-date
            // "None" option), or the computed-window note.
            switch timeframeBinding.wrappedValue {
            case .custom, .indefinite:
                editCustomDateSection
            default:
                editTimeframeDateNote
            }
        }
    }

    /// Dashed-keyline note card showing the resolved window for the current
    /// timeframe — mirrors `RisoBoardSetupForm.timeframeDateNote`.
    @ViewBuilder
    private var editTimeframeDateNote: some View {
        if let boundaries = computeTimeframeBoundaries(
            timeframe: timeframeBinding.wrappedValue,
            referenceDate: Date(),
            weekStartDay: weekStartDay
        ) {
            let start = DateFormatter.localizedString(from: boundaries.start, dateStyle: .medium, timeStyle: .none)
            let end = DateFormatter.localizedString(from: boundaries.end, dateStyle: .medium, timeStyle: .none)
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.risoMuted)
                Text("\(start) – \(end)")
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

    /// Custom date pickers in Riso card style — mirrors
    /// `RisoBoardSetupForm.customDateSection`.
    @ViewBuilder
    private var editCustomDateSection: some View {
        VStack(spacing: 10) {
            DatePicker(
                "Start date",
                selection: customStartDateBinding,
                displayedComponents: .date
            )
            .font(.risoBody(14, .bold))
            .foregroundStyle(Color.risoInk)
            .tint(Color.risoBlue)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .risoCard()

            // End date — a date OR "None" (ongoing), chosen via the trailing
            // menu. Picking None converts the board to indefinite.
            HStack {
                Text("End date")
                    .font(.risoBody(14, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                if timeframeBinding.wrappedValue == .indefinite {
                    Text("None")
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoInk)
                } else {
                    DatePicker(
                        "",
                        selection: customEndDateBinding,
                        in: customStartDateBinding.wrappedValue...,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .tint(Color.risoBlue)
                }
                Menu {
                    Button {
                        timeframeBinding.wrappedValue = .custom
                    } label: {
                        editEndMenuLabel("Pick a date", selected: timeframeBinding.wrappedValue == .custom)
                    }
                    Button {
                        timeframeBinding.wrappedValue = .indefinite
                    } label: {
                        editEndMenuLabel("None — no end date", selected: timeframeBinding.wrappedValue == .indefinite)
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
    }

    /// Menu row label — shows a checkmark on the active End-date option.
    @ViewBuilder
    private func editEndMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Edit-active: Center square section

    @ViewBuilder
    private var editCenterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CENTER SQUARE")
                .risoSectionLabel()

            RisoSegmented(
                options: editCenterOptions,
                selection: Binding(
                    get: { centerTypeBinding.wrappedValue },
                    set: { newVal in
                        // Revert to .free if the user selects CHOSEN when no
                        // candidate tasks exist (same guard as the old Form path).
                        if newVal == .chosen && chosenCenterDisabled {
                            centerTypeBinding.wrappedValue = .free
                        } else {
                            centerTypeBinding.wrappedValue = newVal
                        }
                    }
                )
            )

            // Contextual notes.
            if centerTypeBinding.wrappedValue == .chosen && chosenCenterDisabled {
                Text("No tasks are placed on this board — CHOSEN is unavailable.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            } else if centerTypeBinding.wrappedValue == .chosen {
                Text("The existing center task is kept. Switch away to change the center type.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }

            // Custom center name input.
            if centerTypeBinding.wrappedValue == .customFree {
                EditBoardNameInput(
                    text: centerCustomNameBinding,
                    placeholder: "Custom center name (e.g. Wild Card)"
                )
            }
        }
    }

    private var editCenterOptions: [(value: CenterSquareType, label: String)] {
        // Short labels so the 4 equal-width segments don't clip.
        [
            (.free,       "Free"),
            (.customFree, "Custom"),
            (.chosen,     "Choose"),
            (.none,       "None"),
        ]
    }
}

// MARK: - EditBoardNameInput

/// Keyline text field matching `RisoNameInput` in `RisoBoardSetupForm` —
/// 2px ink border, Bricolage 700 text, paper2 background. Focus state adds
/// a 3px hard shadow (no glow) per Riso spec.
///
/// Defined here as a `private` helper used only by `BoardSetupFormView`'s
/// edit-active sections. It is visually identical to `RisoNameInput` but
/// kept separate so neither file reaches into the other's private scope.
private struct EditBoardNameInput: View {
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

// MARK: - Convenience inits

extension BoardSetupFormView {
    /// Edit-active initialiser — takes explicit `@Binding` props from
    /// `EditBoardSheet`.
    init(
        name: Binding<String>,
        timeframe: Binding<Timeframe>,
        customStartDate: Binding<Date>,
        customEndDate: Binding<Date>,
        centerType: Binding<CenterSquareType>,
        centerCustomName: Binding<String>,
        weekStartDay: String,
        chosenCenterDisabled: Bool = false
    ) {
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
