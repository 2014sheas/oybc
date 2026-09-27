import SwiftUI

// MARK: - BoardSetupFormView

/// BoardSetupFormView — Riso-styled board setup form for editing an
/// already-active board. Driven by explicit `@Binding` props from
/// `BoardDetailsSheetView` (Board Edit redesign slice 2 — the retired
/// `EditBoardSheet`'s successor); board size is suppressed (rendered as a
/// read-only chip in the enclosing sheet), and recurring/core affordances
/// don't apply to edits.
///
/// Slice 2 (D5): the timeframe never switches after creation — this view no
/// longer offers the Daily/Weekly/Monthly/Yearly/Custom segmented. A
/// calendar-timeframe board renders its read-only computed window; a
/// custom/ongoing board renders the date pickers, where the End-date "None"
/// choice is still the one supported Custom ⇄ Ongoing conversion (OQ6).
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
    var weekStartDay: String
    /// When true (edit-active only), the CHOSEN option in the center picker is
    /// guarded with an explanatory note.
    var chosenCenterDisabled: Bool
    /// The board's OWN stored window (slice 2 self-review). An existing
    /// board's dates never move, so a calendar timeframe's read-only note
    /// shows these rather than the window containing today (which would
    /// label last month's still-active board as "this month" and make the
    /// note date-dependent). Nil falls back to the computed-from-today window.
    var storedWindow: (start: Date, end: Date)?

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

            // Slice 2 (D5): no segmented — the timeframe never switches
            // after creation. A calendar timeframe (Daily/Weekly/Monthly/
            // Yearly) renders its read-only computed window; Custom /
            // Ongoing render the date pickers, where the End-date "None"
            // menu is still the one supported Custom ⇄ Ongoing conversion.
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
        if let boundaries = Self.readOnlyWindow(
            timeframe: timeframeBinding.wrappedValue,
            storedWindow: storedWindow,
            weekStartDay: weekStartDay,
            now: Date()
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
        }
    }

    private var editCenterOptions: [(value: CenterSquareType, label: String)] {
        // Short labels so the 3 equal-width segments don't clip.
        [
            (.free,   "Free"),
            (.chosen, "Choose"),
            (.none,   "None"),
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
        weekStartDay: String,
        chosenCenterDisabled: Bool = false,
        storedWindow: (start: Date, end: Date)? = nil
    ) {
        self.nameBinding = name
        self.timeframeBinding = timeframe
        self.customStartDateBinding = customStartDate
        self.customEndDateBinding = customEndDate
        self.centerTypeBinding = centerType
        self.weekStartDay = weekStartDay
        self.chosenCenterDisabled = chosenCenterDisabled
        self.storedWindow = storedWindow
    }

    /// The window the read-only calendar-timeframe note shows: the board's
    /// stored window when known, else the window containing `now`.
    ///
    /// - Parameters:
    ///   - timeframe: The board's timeframe (custom / ongoing have no note).
    ///   - storedWindow: The board's own parsed start/end, if any.
    ///   - weekStartDay: Week-start preference for the computed fallback.
    ///   - now: Clock for the computed fallback.
    /// - Returns: The window to display, or nil for custom / ongoing.
    static func readOnlyWindow(
        timeframe: Timeframe,
        storedWindow: (start: Date, end: Date)?,
        weekStartDay: String,
        now: Date
    ) -> (start: Date, end: Date)? {
        guard timeframe != .custom, timeframe != .indefinite else { return nil }
        if let storedWindow { return storedWindow }
        return computeTimeframeBoundaries(
            timeframe: timeframe, referenceDate: now, weekStartDay: weekStartDay
        )
    }
}
