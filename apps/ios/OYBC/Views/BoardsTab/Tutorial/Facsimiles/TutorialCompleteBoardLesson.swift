import SwiftUI

// MARK: - Lesson 3 · Complete a board

/// The lesson 3 facsimiles, fed by `TutorialCompleteBoardState`: the Sample week
/// play board, its Edit panel, the replace sheet, the Stretch toast, the Read
/// square sheet, the hold menu and the shipped Bingo / Greenlog moments.
///
/// Every part is drawn from the shipped Riso primitives and props-only leaves
/// (`RisoBoardGrid`, `RisoBoardPlayCell`, `RisoStatBar`, `BoardOptionsSectionView`,
/// `UndoStrip`, `CounterLogToastView`, `RisoMomentOverlay`) — never the stateful
/// containers (`BoardPlayView`, `BoardEditPanel`, `SquareSheetView`). Exactly the
/// controls the current step names are wired; everything else is inert.
struct TutorialCompleteBoardLesson: View {
    let state: TutorialCompleteBoardState
    let step: Int
    let perform: (TutorialEvent) -> Void
    /// Snapshot seam: pins a moment's replay at a beat (no clock, no motion).
    var momentBeatOverride: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if state.editing {
                TutorialEditPanelFacsimile(state: state, perform: perform)
            } else {
                TutorialPlayBoardFacsimile(state: state, perform: perform)
            }

            if state.replaceSheetOpen {
                TutorialBehindSheetDim()
                TutorialReplaceSheetFacsimile(perform: perform)
            }

            if state.toastVisible {
                toast
            }

            if state.squareSheetOpen {
                TutorialBehindSheetDim()
                TutorialSquareSheetFacsimile(state: state, perform: perform)
            }

            // The shipped moment plays whole under the bar (the stage hides the
            // scrim and coach mark while it is up).
            Group {
                if let moment = state.moment {
                    momentOverlay(moment)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: state.moment)
        }
    }

    // MARK: Toast

    /// The Normal-square toast the step 5 tap leaves behind: lit read-only, its
    /// Undo does nothing (the lesson only shows where Undo lives).
    private var toast: some View {
        VStack {
            Spacer()
            CounterLogToastView(
                amount: 1,
                unit: "",
                verb: .logged,
                message: "\(TutorialSampleWeek.grid[TutorialSampleWeek.Slot.stretch].title) · done",
                detail: "\(TutorialSampleWeek.boardName) · \(state.completedCount) of 9",
                onUndo: {},
                onDone: {}
            )
            .tutorialWired(.undoToast)
            .tutorialInert()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 100)
        }
    }

    // MARK: Moment

    @ViewBuilder
    private func momentOverlay(_ moment: TutorialCompleteBoardState.Moment) -> some View {
        switch moment {
        case .bingo:
            // Share is shown disabled: the sample board is not the person's.
            RisoMomentOverlay(
                kind: .bingo,
                replay: TutorialCompleteBoardMoment.replay(for: state),
                cells: TutorialCompleteBoardMoment.cells(for: state),
                boardName: TutorialSampleWeek.boardName,
                linesCompleted: state.completeLines.count,
                beatOverride: momentBeatOverride,
                shareDisabled: true,
                onShare: {},
                onBack: { perform(.momentBackTapped) }
            )
        case .greenlog:
            RisoMomentOverlay(
                kind: .greenlog,
                replay: TutorialCompleteBoardMoment.replay(for: state),
                cells: TutorialCompleteBoardMoment.cells(for: state),
                boardName: TutorialSampleWeek.boardName,
                linesCompleted: state.completeLines.count,
                beatOverride: momentBeatOverride,
                shareDisabled: true,
                onShare: {},
                onBack: { perform(.momentBackTapped) },
                onNewBoard: { perform(.momentNewBoardTapped) }
            )
        }
    }
}

// MARK: - Moment inputs

/// Builds the shipped moment overlay's inputs from the lesson state, the same
/// way `computeBoardMomentReplay` does for a real board: completed cells in
/// landing order (the squares done at the start first, then the ones the person
/// finished in the lesson), and each complete line's closure beat.
enum TutorialCompleteBoardMoment {

    /// The replay for the squares done in `state`.
    /// - Parameter state: The lesson state when the moment opened.
    /// - Returns: A replay whose `lineClosureBeat` keys are the ids
    ///   `BingoDetection.detectBingos` emits (the middle row is `row_1`).
    static func replay(for state: TutorialCompleteBoardState) -> BoardMomentReplay {
        let initial = TutorialSampleWeek.initiallyDone
        let slots = initial.sorted() + state.done.subtracting(initial).sorted()
        let order = slots.map { MomentOrderEntry(boardTaskId: "tutorial-week-\($0)", idx: $0, completedAt: nil) }

        var landBeat: [Int: Int] = [:]
        for (i, entry) in order.enumerated() { landBeat[entry.idx] = i + 1 }
        let size = 3
        let grid = (0..<(size * size)).map { state.done.contains($0) }
        var closure: [String: Int] = [:]
        for line in BingoDetection.detectBingos(completionGrid: grid, gridSize: size).completedLines {
            let cells = BingoDetection.getHighlightedSquares(completedLines: [line], gridSize: size)
            closure[line] = (cells.compactMap { landBeat[$0] }.max() ?? 0) + 1
        }
        return BoardMomentReplay(
            order: order, freeIdx: nil, lineClosureBeat: closure,
            completedTasks: state.completedCount, totalTasks: size * size, size: size
        )
    }

    /// The nine cells, with their end-state completion and counts.
    static func cells(for state: TutorialCompleteBoardState) -> [MomentCellInput] {
        TutorialSampleWeek.grid.indices.map { slot in
            let square = TutorialSampleWeek.grid[slot]
            return MomentCellInput(
                idx: slot,
                title: state.title(at: slot),
                taskType: square.isCounting ? .counting : .normal,
                endCompleted: state.done.contains(slot),
                currentCount: CountValue(TutorialPlayBoardFacsimile.count(at: slot, in: state)),
                maxCount: CountValue(square.goal ?? 0)
            )
        }
    }
}

// MARK: - Play board

/// The play board: back square, title block with the Edit button, the stat bar,
/// the 3×3 grid and the inert tab bar. Every square is tagged for the stage and
/// reports a tap or a hold; the hold menu is drawn over the Tidy desk square.
struct TutorialPlayBoardFacsimile: View {
    let state: TutorialCompleteBoardState
    let perform: (TutorialEvent) -> Void

    /// The hold menu's width (the system menu's).
    private static let menuWidth: CGFloat = 233

    /// A square's count as shown now (Read follows the lesson state).
    static func count(at slot: Int, in state: TutorialCompleteBoardState) -> Int {
        slot == TutorialSampleWeek.Slot.read ? state.readCount : TutorialSampleWeek.grid[slot].count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RisoPaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 12)

                    RisoStatBar(
                        completedTasks: state.completedCount,
                        totalTasks: 9,
                        linesCompleted: state.completeLines.count,
                        expiryText: TutorialSampleWeek.daysLeft
                    )
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 14)
                    .padding(.bottom, 13)
                    .tutorialInert()

                    RisoBoardGrid(gridSize: 3) { _, _, index in
                        cell(index)
                    }
                    .overlay {
                        if state.holdMenuOpen {
                            GeometryReader { geo in
                                holdMenu
                                    .frame(width: Self.menuWidth)
                                    .offset(
                                        x: geo.size.width - Self.menuWidth,
                                        y: menuTop(gridWidth: geo.size.width)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 8)

                    Spacer(minLength: 20)
                }
                .padding(.bottom, 110)
            }

            TutorialTabBarFacsimile(active: .boards)
                .padding(.bottom, 30)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 44, height: 44)
                .risoCard()
                .risoHardShadow(Riso.Shadow.small)
                .tutorialInert()

            VStack(alignment: .leading, spacing: 4) {
                Text(TutorialSampleWeek.kicker).risoKicker()
                Text(TutorialSampleWeek.boardName)
                    .font(.risoHead(22, .extraBold))
                    .tracking(-0.44)
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(2)
                Text("ACTIVE")
                    .font(.risoHead(10, .bold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.risoBlue))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tutorialInert()

            RisoButton(title: "Edit", kind: .neutral, systemImage: "pencil", small: true) { perform(.editTapped) }
                .accessibilityLabel("Edit board")
                .tutorialWired(.editButton)
                .padding(.top, 22)
        }
    }

    // MARK: Grid

    /// One square. A tap reports `squareTapped`; a 0.4s hold reports
    /// `squareHeld` alongside the cell's own tap (the state ignores whichever
    /// the step does not want).
    @ViewBuilder
    private func cell(_ slot: Int) -> some View {
        let square = TutorialSampleWeek.grid[slot]
        RisoBoardPlayCell(
            title: state.title(at: slot),
            taskType: square.isCounting ? .counting : .normal,
            isCompleted: state.done.contains(slot),
            isBingoLine: state.ringedSlots.contains(slot),
            currentCount: CountValue(Self.count(at: slot, in: state)),
            maxCount: CountValue(square.goal ?? 0),
            onTap: { perform(.squareTapped(slot)) }
        )
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in perform(.squareHeld(slot)) })
        .accessibilityAction(named: "Show quick actions") { perform(.squareHeld(slot)) }
        .tutorialWired(.square(slot), radius: Riso.cellRadius)
    }

    // MARK: Hold menu

    /// Where the menu's top edge sits inside the grid: 8pt under the Tidy desk
    /// square (middle row), so the menu never covers it.
    private func menuTop(gridWidth: CGFloat) -> CGFloat {
        let side = RisoBoardGrid<EmptyView>.cellSide(forSideLength: gridWidth, gridSize: 3)
        return 2 * side + Riso.cellGap + 8
    }

    /// A tutorial copy of the system context menu: Mark done is the one live
    /// row; Details and Open in library are drawn disabled. The system face
    /// (17pt system font) is deliberate.
    private var holdMenu: some View {
        VStack(spacing: 0) {
            Text("\(TutorialSampleWeek.grid[TutorialSampleWeek.Slot.tidy].title) · Not done")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 9)
                .padding(.bottom, 7)
                .tutorialInert()
            menuRule

            Button { perform(.markDoneTapped) } label: {
                menuRow("Mark done", symbol: "checkmark.circle")
            }
            .buttonStyle(.plain)
            .tutorialWired(.markDone, radius: 6)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 8).tutorialInert()

            menuRow("Details", symbol: "info.circle")
                .opacity(0.4)
                .tutorialInert()
            menuRule
            menuRow("Open in library", symbol: "book")
                .opacity(0.4)
                .tutorialInert()
        }
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.97))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var menuRule: some View {
        Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 0.5)
    }

    private func menuRow(_ title: String, symbol: String) -> some View {
        HStack {
            Text(title).font(.system(size: 17)).tracking(-0.4)
            Spacer(minLength: 8)
            Image(systemName: symbol).font(.system(size: 17))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Edit panel

/// The Edit panel as `BoardEditPanel` lays it out: Cancel and the gold Editing
/// pill, SQUARES with the grid, the BOARD rows, and the pinned footer. Only the
/// Journal square and Save changes are wired.
struct TutorialEditPanelFacsimile: View {
    let state: TutorialCompleteBoardState
    let perform: (TutorialEvent) -> Void

    private var canSave: Bool { state.changeCount > 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            RisoPaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topBar
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SQUARES").risoSectionLabel().tutorialInert()
                        RisoBoardGrid(gridSize: 3) { _, _, index in
                            editCell(index)
                        }
                    }
                    BoardOptionsSectionView(items: [.details, .repeatBoard, .archive, .delete], onSelect: { _ in })
                        .tutorialInert()
                    Spacer().frame(height: 76)
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.vertical, 16)
            }

            footer
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("Cancel")
                .font(.risoBody(15, .semibold))
                .foregroundStyle(Color.risoMuted)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(Color.risoRed).frame(width: 7, height: 7)
                Text("Editing")
                    .font(.risoBody(13, .bold))
                    .foregroundStyle(Color.risoInkStatic)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Color.risoGold))
            .overlay(Capsule().strokeBorder(Color.risoInkStatic.opacity(0.25), lineWidth: Riso.Keyline.dense))
        }
        .tutorialInert()
    }

    // MARK: Grid

    /// A square in edit chrome: the shared cell face, display-only. Journal is
    /// the one tappable square; after the swap it reads the replacement and
    /// carries the gold staged-edit chip.
    @ViewBuilder
    private func editCell(_ slot: Int) -> some View {
        let square = TutorialSampleWeek.grid[slot]
        let isJournal = slot == TutorialSampleWeek.Slot.journal
        let tap: (() -> Void)? = isJournal ? { perform(.editSquareTapped(slot)) } : nil
        let face = RisoBoardPlayCell(
            title: state.title(at: slot),
            taskType: square.isCounting ? .counting : .normal,
            isCompleted: state.done.contains(slot),
            showsDirtyChip: isJournal && state.swapped,
            currentCount: CountValue(TutorialPlayBoardFacsimile.count(at: slot, in: state)),
            maxCount: CountValue(square.goal ?? 0),
            onTap: tap
        )
        if isJournal {
            face.tutorialWired(.editSquare(slot), radius: Riso.cellRadius)
        } else {
            face.tutorialInert()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.risoInk.opacity(0.12)).frame(height: 1)
            HStack(spacing: 12) {
                Text(state.changeCount == 0 ? "No changes" : "\(state.changeCount) change\(state.changeCount == 1 ? "" : "s")")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(canSave ? Color.risoInk : Color.risoMuted)
                Spacer()
                RisoButton(title: "Shuffle", kind: .neutral, systemImage: "shuffle", small: true) {}
                    .tutorialInert()
                RisoToolbarPill(title: "Save changes") { perform(.saveTapped) }
                    .opacity(canSave ? 1 : 0.45)
                    .tutorialWired(.saveChanges, radius: 999)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Color.risoPaper.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: - Replace sheet

/// The tutorial twin of the square-replace sheet: kicker, the square's name,
/// Cancel, a search field and four library rows of which only Meditate 5 min is
/// live. Drawn inside the stage, never presented.
struct TutorialReplaceSheetFacsimile: View {
    let perform: (TutorialEvent) -> Void

    var body: some View {
        TutorialSheetPanel(top: 12, grabber: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Replace square").risoKicker()
                        Text(TutorialSampleWeek.grid[TutorialSampleWeek.Slot.journal].title).risoH2()
                    }
                    Spacer(minLength: 8)
                    Text("Cancel")
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.top, 4)
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 16)
                .tutorialInert()

                TutorialSearchFieldFacsimile(placeholder: "Search tasks")
                    .padding(.horizontal, Riso.gutter)

                Text("From your library")
                    .risoSectionLabel()
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .tutorialInert()

                VStack(spacing: 8) {
                    ForEach(TutorialSampleWeek.replaceLibrary, id: \.self) { title in
                        row(title)
                    }
                }
                .padding(.horizontal, Riso.gutter)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String) -> some View {
        if title == TutorialSampleWeek.replacement {
            Button { perform(.replaceRowTapped(title)) } label: {
                rowFace(title, live: true)
            }
            .buttonStyle(.plain)
            .tutorialWired(.replaceRow(title))
        } else {
            rowFace(title, live: false)
                .tutorialInert()
        }
    }

    private func rowFace(_ title: String, live: Bool) -> some View {
        HStack(spacing: 10) {
            RisoTypeBadge(kind: .normal, style: .letterSquare)
            Text(title)
                .font(.risoBody(15, .semibold))
                .foregroundStyle(live ? Color.risoInk : Color.risoMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if live {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            } else {
                TutorialLockChip()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(live ? Color.risoPaper2 : Color.risoPaper))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(live ? Color.risoInk : Color.risoInk.opacity(0.4), lineWidth: Riso.Keyline.dense)
        )
        .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
    }
}

// MARK: - Square sheet

/// The Read 20 pages square sheet as `SquareSheetCountingView` draws it: header,
/// hero count + status pill, progress bar, TAP TO LOG with the chips, the Undo
/// strip once a log happened, and "− Remove…". Only the +5 chip is wired (the
/// Undo strip is lit, inert).
struct TutorialSquareSheetFacsimile: View {
    let state: TutorialCompleteBoardState
    let perform: (TutorialEvent) -> Void

    private var current: CountValue { CountValue(state.readCount) }
    private var goal: CountValue { CountValue(state.readGoal) }
    private var isGoalMet: Bool { goal > 0 && current >= goal }
    private var title: String { TutorialSampleWeek.grid[TutorialSampleWeek.Slot.read].title }
    private var unit: String { TutorialSampleWeek.grid[TutorialSampleWeek.Slot.read].unit }

    var body: some View {
        TutorialSheetPanel(top: 300, grabber: false, topRule: true) {
            VStack(alignment: .leading, spacing: 0) {
                header
                hero
                RisoProgressBar(
                    value: goal > 0 ? min(current, goal) / goal : 0,
                    color: isGoalMet ? .risoGreen : .risoBlue,
                    height: 12
                )
                .padding(.top, 10)
                .tutorialInert()
                logControls
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 14)
        }
    }

    // MARK: Header + hero

    private var header: some View {
        HStack(spacing: 10) {
            RisoTypeBadge(kind: .counting, style: .letterSquare, size: 22)
            Text(title)
                .font(.risoHead(18, .extraBold))
                .tracking(-0.36)
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text("Library")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .font(.risoHead(12, .bold))
            .foregroundStyle(Color.risoInk)
            .padding(.vertical, 6)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .tutorialInert()
    }

    private var hero: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text("\(state.readCount)")
                .font(.risoHead(SquareSheetFormat.heroCountSize(.discrete), .extraBold))
                .tracking(-0.9)
                .monospacedDigit()
                .foregroundStyle(Color.risoBlue)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(SquareSheetFormat.countLine(goal: goal, unit: unit, kind: .discrete, board: TutorialSampleWeek.boardName))
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            if let status = SquareSheetFormat.countStatus(current: current, goal: goal) {
                RisoStatusPill(status: status)
            }
        }
        .padding(.top, 14)
        .tutorialInert()
    }

    // MARK: Logging

    /// The lesson's chips (handoff: +1 · +5 · +rest ✓ · Other…): the fixture's
    /// presets, then the rest of the goal while it is positive, then Other.
    private var lessonChips: [CounterLogAmount.TapChip] {
        var chips = TutorialSampleWeek.chips.map {
            CounterLogAmount.TapChip(value: CountValue($0), label: "+\($0)", role: .preset)
        }
        let rest = state.readGoal - state.readCount
        if rest > 0, !TutorialSampleWeek.chips.contains(rest) {
            chips.append(CounterLogAmount.TapChip(value: CountValue(rest), label: "+\(rest) ✓", role: .rest))
        }
        chips.append(CounterLogAmount.TapChip(value: nil, label: "Other…", role: .other))
        return chips
    }

    @ViewBuilder
    private var logControls: some View {
        HStack(alignment: .firstTextBaseline) {
            SquareSheetEyebrow(text: "Tap to log")
            Spacer()
            if let rest = SquareSheetFormat.restLine(current: current, goal: goal, kind: .discrete, board: TutorialSampleWeek.boardName) {
                Text(rest)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
        .padding(.top, 14)
        .tutorialInert()

        TutorialChipRow(
            chips: lessonChips,
            wired: TutorialSampleWeek.chip,
            unit: unit,
            onChip: { perform(.chipTapped($0)) }
        )
        .padding(.top, 6)

        if let undo = state.undoText {
            UndoStrip(text: undo, disabled: true, onUndo: {})
                .tutorialWired(.undoStrip)
                .tutorialInert()
                .padding(.top, 10)
        }

        Text("− Remove…")
            .font(.risoHead(12, .bold))
            .foregroundStyle(Color.risoMuted)
            .padding(.vertical, 6)
            .padding(.top, 6)
            .tutorialInert()
    }
}

// MARK: - Chip row

/// The tap-to-log chip row, drawn like `TapLogChipRow` (same weights, sizes and
/// colours) so the one wired chip can be tagged on its own.
private struct TutorialChipRow: View {
    let chips: [CounterLogAmount.TapChip]
    /// The preset amount that is wired (+5).
    let wired: Int
    let unit: String
    let onChip: (Int) -> Void

    private static let gap: CGFloat = 6
    private static let height: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let total = chips.reduce(0) { $0 + TapLogChipRow.weight($1) }
            let room = geo.size.width - Self.gap * CGFloat(max(chips.count - 1, 0))
            HStack(spacing: Self.gap) {
                ForEach(chips, id: \.rowID) { chip in
                    chipView(chip)
                        .frame(width: total > 0 ? room * TapLogChipRow.weight(chip) / total : 0)
                }
            }
        }
        .frame(height: Self.height)
        // The hard shadow draws outside the row's frame.
        .padding(.trailing, Riso.Shadow.small)
        .padding(.bottom, Riso.Shadow.small)
    }

    private func face(_ chip: CounterLogAmount.TapChip) -> some View {
        let isOther = chip.role == .other
        return Text(chip.label)
            .font(.risoHead(TapLogChipRow.fontSize(chip, size: .regular), isOther ? .bold : .extraBold))
            .monospacedDigit()
            .foregroundStyle(isOther ? Color.risoInk : Color.risoInkStatic)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(isOther ? Color.risoPaper2 : Color.risoGold))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(isOther ? Color.risoInk : Color.risoInkStatic, lineWidth: Riso.Keyline.container)
            )
    }

    @ViewBuilder
    private func chipView(_ chip: CounterLogAmount.TapChip) -> some View {
        if chip.role == .preset, chip.value == CountValue(wired) {
            Button { onChip(wired) } label: {
                face(chip).contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            }
            .buttonStyle(TutorialChipButtonStyle())
            .tutorialWired(.chip(wired))
            .accessibilityLabel(TapLogChipRow.accessibilityName(chip, unit: unit))
        } else {
            face(chip)
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(Color.risoInk)
                        .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
                )
                .tutorialInert()
        }
    }
}

/// Press = translate 2pt and the 2pt hard shadow to 0 (`TapLogChipRow`'s style).
private struct TutorialChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let offset = Riso.Shadow.small
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(Color.risoInk)
                    .offset(x: pressed ? 0 : offset, y: pressed ? 0 : offset)
            )
            .offset(x: pressed ? offset : 0, y: pressed ? offset : 0)
            .animation(.easeOut(duration: Riso.pressDuration), value: pressed)
    }
}
