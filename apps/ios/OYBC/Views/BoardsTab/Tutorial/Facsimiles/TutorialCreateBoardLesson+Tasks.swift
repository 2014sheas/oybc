import SwiftUI

// MARK: - Lesson 2 · Tasks step, source sheet, Preview step

private typealias BoardFixture = TutorialCreateBoardFixture

// MARK: - Tasks step

/// Wizard step 2: the pool header, the ADD TASKS card (quick add, the Special
/// type button and "+ Add from a pool or board"), then — once Fitness is pulled —
/// the SOURCES section with the Fitness row (expandable) and ON YOUR BOARD with
/// the hand-added task. Footer: Back (inert) and Next, dimmed until the board is
/// full. The quick-add row is drawn at every step and lit at step 8.
struct TutorialCreateBoardTasksFacsimile: View {
    let state: TutorialCreateBoardState
    let step: Int
    let perform: (TutorialEvent) -> Void

    @FocusState private var quickFocused: Bool

    private typealias Step = TutorialCreateBoardState.Step

    /// The keyboard is up from the hand-add step until the task is added.
    private var wantsFocus: Bool { step == Step.handAdd && state.handAddedTitle == nil }

    /// Tasks still supplied by the pulled pool (the excluded one drops out).
    private var availableCount: Int { BoardFixture.fitness.count - (state.excluded ? 1 : 0) }

    var body: some View {
        TutorialWizardFrame(kicker: "New one-off board", title: "Tasks", activeStep: 2) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        VStack(alignment: .leading, spacing: 14) {
                            RisoTasksPoolHeaderView(
                                capacity: state.poolCount,
                                tasksRequired: BoardFixture.required,
                                isRecurring: false,
                                centerTaskMode: false,
                                centerSatisfied: false
                            )
                            .tutorialInert()
                            addTasks
                            if state.poolAdded { sources }
                            onYourBoard
                        }
                        .padding(Riso.gutter)
                        .padding(.bottom, 40)
                    }
                }
                .onChange(of: step) { _, now in scroll(proxy, to: now) }
                .onAppear { DispatchQueue.main.async { scroll(proxy, to: step) } }
            }
        } footer: {
            RisoButton(title: "‹ Back", kind: .neutral) {}
                .tutorialInert()
                .frame(maxWidth: .infinity)
            RisoButton(title: "Next ›", kind: .primary) { perform(.tasksNextTapped) }
                .opacity(state.satisfied ? 1 : 0.45)
                .disabled(!state.satisfied)
                .tutorialWired(.tasksNext)
                .frame(maxWidth: .infinity)
        }
        .onAppear { quickFocused = wantsFocus }
        .onChange(of: wantsFocus) { _, now in quickFocused = now }
    }

    /// Brings the step's control into view: the member rows while Bike to work
    /// is offered, the top of the page for the hand-add step.
    private func scroll(_ proxy: ScrollViewProxy, to step: Int) {
        withAnimation(.easeOut(duration: 0.25)) {
            if step == Step.exclude, state.sourceExpanded {
                proxy.scrollTo("members", anchor: .center)
            } else if step >= Step.handAdd {
                proxy.scrollTo("top", anchor: .top)
            }
        }
    }

    // MARK: ADD TASKS

    private var addTasks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add tasks").risoSectionLabel().tutorialInert()
            VStack(spacing: 10) {
                quickRow
                specialRow.tutorialInert()
                sourceEntry
            }
            .padding(12)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.small)
        }
    }

    /// The text field + red Add (one control), lit at step 8.
    private var quickRow: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: Binding(get: { state.quickText }, set: { perform(.typed(.wizardQuickAdd, $0)) }),
                prompt: Text("e.g. Drink water").foregroundStyle(Color.risoMuted)
            )
            .font(.risoHead(15, .bold))
            .foregroundStyle(Color.risoInk)
            .tint(Color.risoBlue)
            .focused($quickFocused)
            .submitLabel(.done)
            .onSubmit { perform(.wizardQuickSubmitted) }
            .disabled(state.handAddedTitle != nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))

            RisoButton(title: "Add", kind: .primary) { perform(.wizardQuickSubmitted) }
                .opacity(state.trimmedQuick.isEmpty ? 0.45 : 1)
                .disabled(state.trimmedQuick.isEmpty)
        }
        .tutorialWired(.wizardQuickRow)
    }

    /// The dashed "＋ Counting · Compound · Achievement" button (lesson 1 covered it).
    private var specialRow: some View {
        HStack(spacing: 8) {
            Text("＋").font(.risoHead(15, .extraBold)).foregroundStyle(Color.risoBlue)
            Text("Counting · Compound · Achievement").font(.risoHead(13, .bold)).foregroundStyle(Color.risoInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4]))
                .foregroundStyle(Color.risoInk)
        )
    }

    /// The dashed "+ Add from a pool or board" row (wired at step 4).
    private var sourceEntry: some View {
        Button { perform(.addFromPoolTapped) } label: {
            Text("+ Add from a pool or board")
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk.opacity(0.5), style: StrokeStyle(lineWidth: Riso.Keyline.dense, dash: [5, 4]))
                )
                .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        }
        .buttonStyle(.plain)
        .tutorialWired(.addFromPool)
    }

    // MARK: SOURCES

    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources").risoSectionLabel().tutorialInert()
            VStack(spacing: 0) {
                sourceHeader
                if state.sourceExpanded { sourcePanel }
            }
            .background(Color.risoPaper2)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
    }

    /// Fitness: ink "P" square, name, subtitle, chevron and a dimmed ✕. The whole
    /// header is the tap target (the shipped row expands the same way).
    private var sourceHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(Color.risoInk)
                .frame(width: 20, height: 20)
                .overlay(Text("P").font(.risoBody(11, .extraBold)).foregroundStyle(Color.risoPaper))
                .overlay(RoundedRectangle(cornerRadius: Riso.cellRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            VStack(alignment: .leading, spacing: 1) {
                Text(BoardFixture.livePool)
                    .font(.risoBody(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Text(state.sourceSubtitle)
                    .font(.risoBody(10.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.risoMuted)
                .rotationEffect(.degrees(state.sourceExpanded ? 90 : 0))
                .frame(width: 28, height: 28)
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.risoMuted)
                .frame(width: 28, height: 28)
                .opacity(0.35)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .contentShape(Rectangle())
        .onTapGesture { perform(.sourceRowTapped) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(BoardFixture.livePool), \(state.sourceSubtitle)")
        .accessibilityHint(state.sourceExpanded ? "Collapses the source" : "Expands the source")
        .accessibilityAddTraits(.isButton)
        .tutorialWired(.sourceRow)
    }

    /// The expanded panel as the shipped row draws it: the ON THE BOARD range
    /// (inert) and the eight member rows, only Bike to work's ✕ live.
    private var sourcePanel: some View {
        VStack(spacing: 0) {
            hairline
            VStack(spacing: 0) {
                rangeBlock.tutorialInert()
                ForEach(Array(BoardFixture.fitness.enumerated()), id: \.offset) { index, task in
                    memberRow(task, isFirst: index == 0)
                }
            }
            .background(Color.risoPaper)
        }
        .id("members")
    }

    private var hairline: some View {
        Rectangle().fill(Color.risoInk.opacity(0.24)).frame(height: Riso.Keyline.dense)
    }

    private var rangeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("ON THE BOARD")
                    .font(.risoBody(10, .extraBold))
                    .kerning(0.9)
                    .foregroundStyle(Color.risoMuted)
                Spacer()
                Text("0–\(availableCount)")
                    .font(.risoHead(16, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Text("of \(availableCount)")
                    .font(.risoBody(10.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                Text("Use all")
                    .font(.risoBody(12, .bold))
                    .foregroundStyle(Color.risoBlue)
                    .opacity(0.35)
            }
            RisoRangeSlider(available: availableCount, minValue: 0, maxValue: nil, onChange: { _, _ in })
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { hairline }
    }

    /// One member: badge, title, a chevron on Counting rows and the ✕. Only the
    /// excluded task's ✕ is a Button; once excluded the row is struck through at
    /// 45% with an inert UNDO pill in its place.
    private func memberRow(_ task: TutorialFixtureTask, isFirst: Bool) -> some View {
        let isExcludedRow = task.title == BoardFixture.excludedTitle
        let isGone = isExcludedRow && state.excluded
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                RisoTypeBadge(kind: task.isCounting ? .counting : .normal, style: .letterSquare)
                Text(task.title)
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .strikethrough(isGone)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if task.isCounting {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .frame(width: 14)
                }
            }
            .tutorialInert()
            memberTrailing(task, isExcludedRow: isExcludedRow, isGone: isGone)
        }
        .padding(.leading, 40)
        .padding(.trailing, 3)
        .frame(minHeight: 44)
        .opacity(isGone ? 0.45 : 1)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Color.risoInk.opacity(0.15)).frame(height: Riso.Keyline.dense)
            }
        }
    }

    @ViewBuilder
    private func memberTrailing(_ task: TutorialFixtureTask, isExcludedRow: Bool, isGone: Bool) -> some View {
        if isGone {
            RisoUndoPill(accessibilityLabel: "Undo excluding \(task.title)", action: {})
                .padding(.trailing, 8)
                .tutorialInert()
        } else if isExcludedRow {
            Button { perform(.memberExcluded(task.title)) } label: {
                xGlyph
            }
            .buttonStyle(.plain)
            .tutorialWired(.memberExclude(task.title))
            .accessibilityLabel("Exclude \(task.title) for this board")
        } else {
            xGlyph.tutorialInert()
        }
    }

    /// The row ✕: an 11pt glyph in a 44pt target.
    private var xGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.risoMuted)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: ON YOUR BOARD

    private var onYourBoard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("On your board").risoSectionLabel()
                Text("\(state.handAddedTitle == nil ? 0 : 1)")
                    .font(.risoHead(10, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.risoInk))
            }
            if let title = state.handAddedTitle {
                handAddedRow(title)
            }
        }
        .tutorialInert()
    }

    private func handAddedRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            RisoTypeBadge(kind: .normal, style: .letterSquare)
            Text(title)
                .font(.risoHead(15, .bold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 36, height: 36)
                .risoCard(fill: .risoPaper)
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.risoMuted)
                .frame(width: 28, height: 28)
        }
        .padding(.leading, 13)
        .padding(.trailing, 11)
        .padding(.vertical, 9)
        .risoCard(fill: .risoPaper2)
    }
}

// MARK: - Source sheet

/// The "Add from a pool or board" sheet, drawn inside the stage: title + Done,
/// the search field, POOLS (Fitness live, Reading and Home locked) and BOARDS
/// (a single line — the tutorial never pulls from the person's boards).
struct TutorialSourceSheetFacsimile: View {
    let state: TutorialCreateBoardState
    let perform: (TutorialEvent) -> Void

    var body: some View {
        TutorialSheetPanel(top: 12, grabber: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Add from a pool or board")
                        .font(.risoHead(19, .extraBold))
                        .foregroundStyle(Color.risoInk)
                        .tutorialInert()
                    Spacer(minLength: 8)
                    RisoButton(title: "Done", kind: .primary) { perform(.sourcesDoneTapped) }
                        .opacity(state.poolChecked ? 1 : 0.45)
                        .disabled(!state.poolChecked)
                        .tutorialWired(.sourcesDone)
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 18)

                TutorialSearchFieldFacsimile(placeholder: "Search pools and boards", fontSize: 15)
                    .padding(.horizontal, Riso.gutter)

                Text("Pools")
                    .risoSectionLabel()
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    .tutorialInert()

                VStack(spacing: 10) {
                    ForEach(Array(BoardFixture.pools.enumerated()), id: \.offset) { _, pool in
                        if pool.name == BoardFixture.livePool {
                            liveRow(pool.name, count: pool.count)
                        } else {
                            lockedRow(pool.name, count: pool.count)
                        }
                    }
                }
                .padding(.horizontal, Riso.gutter)

                Text("Boards")
                    .risoSectionLabel()
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                    .tutorialInert()

                Text("Your boards are not used in the tutorial.")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, Riso.gutter)
                    .tutorialInert()
            }
        }
    }

    private func badge(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: Riso.cellRadius)
            .fill(fill)
            .frame(width: 22, height: 22)
            .overlay(Text("P").font(.risoHead(11, .extraBold)).foregroundStyle(Color.risoPaper))
    }

    /// Fitness: paper-2 row, ink badge, a 26pt toggle that fills green with a check.
    private func liveRow(_ name: String, count: Int) -> some View {
        Button { perform(.poolToggled(name)) } label: {
            HStack(spacing: 12) {
                badge(.risoInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.risoHead(16, .extraBold)).foregroundStyle(Color.risoInk)
                    Text("\(count) tasks").font(.risoBody(12, .semibold)).foregroundStyle(Color.risoMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Circle()
                    .fill(state.poolChecked ? Color.risoGreen : Color.clear)
                    .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.risoPaper)
                            .opacity(state.poolChecked ? 1 : 0)
                    )
                    .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        }
        .buttonStyle(.plain)
        .tutorialWired(.poolRow(name))
        .accessibilityLabel("\(name), \(count) tasks")
        .accessibilityAddTraits(state.poolChecked ? .isSelected : [])
    }

    /// Reading / Home: paper row, keyline at 40% ink, muted badge + name, a lock chip.
    private func lockedRow(_ name: String, count: Int) -> some View {
        HStack(spacing: 12) {
            badge(.risoMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.risoHead(16, .extraBold)).foregroundStyle(Color.risoMuted)
                Text("\(count) tasks").font(.risoBody(12, .semibold)).foregroundStyle(Color.risoMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TutorialLockChip(size: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk.opacity(0.4), lineWidth: Riso.Keyline.container))
        .tutorialInert()
    }
}

// MARK: - Preview step

/// Wizard step 3: the board's name and meta line, the Preview / Rearrange row
/// (inert), the 3×3 grid of the final eight around the FREE centre (inert) and
/// the footer with Back (inert) and Activate Board.
struct TutorialCreateBoardPreviewFacsimile: View {
    let state: TutorialCreateBoardState
    let perform: (TutorialEvent) -> Void

    private var cells: [TutorialFixtureTask?] {
        BoardFixture.previewCells(handAdded: state.handAddedTitle ?? BoardFixture.handAddedDefault)
    }

    var body: some View {
        TutorialWizardFrame(kicker: "Last look", title: "Preview", activeStep: 3) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Text(BoardFixture.boardName)
                            .font(.risoHead(22, .extraBold))
                            .tracking(-0.44)
                            .foregroundStyle(Color.risoInk)
                        Text("Weekly · 3×3 · \(BoardFixture.required) tasks")
                            .font(.risoHead(13, .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .tutorialInert()

                    HStack(spacing: 6) {
                        TutorialSegment(label: "Preview", isOn: true)
                        TutorialSegment(label: "Rearrange")
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Riso.cellGap), count: 3), spacing: Riso.cellGap) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            gridCell(cell)
                        }
                    }
                    .tutorialInert()
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        } footer: {
            RisoButton(title: "‹ Back", kind: .neutral) {}
                .tutorialInert()
            RisoButton(title: "Activate Board", kind: .primary, fullWidth: true) { perform(.activateTapped) }
                .tutorialWired(.activate)
        }
    }

    /// A Counting cell carries its ×goal tag and 0/goal bar; the centre is FREE.
    @ViewBuilder
    private func gridCell(_ cell: TutorialFixtureTask?) -> some View {
        if let task = cell {
            RisoBoardPlayCell(
                title: task.title,
                taskType: task.isCounting ? .counting : .normal,
                isCompleted: false,
                currentCount: 0,
                maxCount: CountValue(task.goal ?? 0)
            )
        } else {
            RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)
        }
    }
}
