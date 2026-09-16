import SwiftUI

/// Per-window core-board pager — "masthead" layout (core-board surface
/// rework).
///
/// Chrome: a **fixed header row** (back square · window chip) above a
/// **window card** that swipes horizontally as one unit (±1 window,
/// cards tracking the finger with a 20pt gutter; 35%-of-width or
/// 300pt/s snap; 0.32s spring). With Reduce Motion the step is a 0.2s
/// cross-fade. A centred position caption (`‹ August · dots ·
/// October ›`) under the card steps ±1 on tap. The chip opens the
/// window picker half-sheet; tapping a tile lands on that window —
/// empty windows show the lazy `CoreBoardSetupPromptView` (**no board
/// row is ever created from navigation**).
///
/// Body states:
///   - **Loading** (`!viewModel.isLoaded`): Riso-styled `ProgressView`.
///   - **Filled**: embedded `BoardPlayView` (which owns the title row,
///     the Edit gate, and the sealed Read-only slot).
///   - **Draft**: DRAFT badge + dashed frame around the resume prompt
///     (drafts are never playable).
///   - **Empty**: muted title + dashed frame around the setup prompt.
///
/// While the embedded `BoardPlayView` is in edit mode
/// (`onEditModeChange`), the chip dims to 45% and swipe/caption
/// stepping are disabled; `BoardEditPanel` keeps its own Cancel/Save.
///
/// Mirrors the web `CoreBoardWindowPage`.
struct CoreBoardWindowView: View {

    // MARK: - Parameters

    let timeframe: Timeframe
    let seedWindowStart: String
    let userId: String
    let weekStartDay: String
    /// Cross-tab handoff: launch the wizard for the current window.
    /// Receives `(timeframe, windowStartDate)` — same signature as
    /// `MainTabView.onCreateForWindow` so the caller can stash both
    /// bindings and flip to Create tab.
    let onCreateForWindow: (Timeframe, Date) -> Void
    /// Navigate to an existing board. Forwarded through `BoardPlayView`'s
    /// `onOpenBoard` and also from the task-detail Usage section.
    let onOpenBoard: (String) -> Void
    /// Resume a DRAFT core board in the wizard (cross-tab). Receives the
    /// draft board id. Drafts are never opened as a playable board, so a
    /// draft window shows a "Resume draft" prompt that fires this.
    let onResumeDraft: (String) -> Void

    // MARK: - ViewModel + state

    @StateObject private var viewModel: CoreBoardWindowViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Window picker half-sheet visibility.
    @State private var isPickerOpen = false
    /// The embedded `BoardPlayView` is in edit mode — chip dims, swipe +
    /// caption stepping disable.
    @State private var childEditing = false
    /// Live horizontal drag translation of the window card.
    @State private var dragOffset: CGFloat = 0
    /// Direction of the incoming card while dragging/animating
    /// (+1 = next window sliding in from the right; 0 = idle).
    @State private var incomingDir: Int = 0
    /// Axis lock for the in-flight drag: nil = undecided, true =
    /// horizontal (we own it), false = vertical (the scroll view owns it).
    @State private var dragAxis: Bool? = nil
    /// A snap animation is in flight — ignore new drags until it lands.
    @State private var isAnimatingStep = false

    // MARK: - Init

    init(
        timeframe: Timeframe,
        seedWindowStart: String,
        userId: String,
        weekStartDay: String,
        onCreateForWindow: @escaping (Timeframe, Date) -> Void,
        onOpenBoard: @escaping (String) -> Void,
        onResumeDraft: @escaping (String) -> Void
    ) {
        self.timeframe = timeframe
        self.seedWindowStart = seedWindowStart
        self.userId = userId
        self.weekStartDay = weekStartDay
        self.onCreateForWindow = onCreateForWindow
        self.onOpenBoard = onOpenBoard
        self.onResumeDraft = onResumeDraft

        _viewModel = StateObject(wrappedValue: CoreBoardWindowViewModel(
            timeframe: timeframe,
            seedWindowStart: seedWindowStart,
            userId: userId,
            weekStartDay: weekStartDay
        ))
    }

    // MARK: - Derived

    private var neighborhood: [CoreWindowPicker.NeighborhoodDot] {
        CoreWindowPicker.buildNeighborhood(
            timeframe: timeframe,
            windowStart: viewModel.windowStart,
            todayWindowStart: viewModel.todayWindowStart,
            boardsByStart: viewModel.coreBoardsByStart,
            weekStartDay: weekStartDay
        )
    }

    /// The displayed window's board row (playable OR draft) — drives the
    /// chip's empty/closed styling.
    private var displayedBoardRow: Board? {
        viewModel.board ?? viewModel.draftBoard
    }

    private var chipLabel: String {
        viewModel.windowLabel + CoreWindowPicker.chipLabelSuffix(
            board: displayedBoardRow,
            isCurrentWindow: viewModel.isCurrentWindow,
            isPastWindow: viewModel.isPast
        )
    }

    private var chipA11yLabel: String {
        let current = viewModel.isCurrentWindow ? ", current window" : ""
        return "\(viewModel.windowLabel)\(current). Opens window picker."
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 14) {
            headerRow
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 8)

            windowCardArea
        }
        .background(RisoPaperBackground().ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { viewModel.reload() }
        .sheet(isPresented: $isPickerOpen) {
            CoreWindowPickerSheet(
                timeframe: timeframe,
                weekStartDay: weekStartDay,
                boardsByStart: viewModel.coreBoardsByStart,
                displayedWindowStart: viewModel.windowStart,
                onSelect: { start in
                    isPickerOpen = false
                    viewModel.jump(toWindowStart: start)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(22)
        }
    }

    // MARK: - Header row (fixed — does not swipe)

    private var headerRow: some View {
        HStack(spacing: 10) {
            if !childEditing {
                backSquare
            }
            Spacer(minLength: 8)
            CoreWindowChipView(
                label: chipLabel,
                dots: neighborhood,
                isOpen: isPickerOpen,
                isEmpty: viewModel.isLoaded && displayedBoardRow == nil,
                isDisabled: childEditing,
                accessibilityText: chipA11yLabel,
                action: { isPickerOpen = true }
            )
        }
        .frame(minHeight: 40)
    }

    /// 40×40 back square (paper2 fill, 2pt keyline, 2pt hard shadow).
    private var backSquare: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 40, height: 40)
                .risoCard(fill: .risoPaper2)
        }
        .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
        .accessibilityLabel("Back")
    }

    // MARK: - Window card area (swipes as one unit)

    /// Stable-identity paging (owner-reported jank, 2026-09-16): the
    /// displayed card and the incoming preview render through ONE builder
    /// inside a `ForEach` keyed by windowStart, so when a swipe commits,
    /// the incoming card KEEPS its view identity (and its already-loaded
    /// embedded `BoardPlayView`) as it becomes the displayed card — no
    /// remount, no reload, even for filled/completed boards. The old
    /// structure gave the preview a different id ("incoming-…") from the
    /// landed card, so every commit destroyed the loaded view and paid a
    /// fresh self-load.
    private var windowCardArea: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let displayed = viewModel.windowStart
            let cardStarts: [String] = {
                var starts = [displayed]
                if incomingDir != 0,
                   let neighbor = viewModel.neighborWindowStart(offset: incomingDir) {
                    starts.append(neighbor)
                }
                return starts
            }()

            ZStack(alignment: .top) {
                ForEach(cardStarts, id: \.self) { start in
                    let isDisplayed = start == displayed
                    card(windowStart: start, isDisplayed: isDisplayed)
                        .frame(width: width)
                        .offset(
                            x: dragOffset + (isDisplayed
                                ? 0
                                : CGFloat(incomingDir) * (width + Riso.gutter))
                        )
                        .opacity(isDisplayed ? outgoingOpacity(width: width) : 1)
                        .allowsHitTesting(isDisplayed && !swipeEngaged)
                }
            }
            .frame(width: width, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture(width: width))
        }
    }

    /// True from the first horizontal movement until the snap settles —
    /// gates every tap target on the cards (prompt CTAs, board squares)
    /// so a swipe can never fire a press (owner-reported, 2026-09-16).
    private var swipeEngaged: Bool {
        dragAxis == true || dragOffset != 0 || incomingDir != 0 || isAnimatingStep
    }

    /// Outgoing card fades to 55% linearly with drag progress.
    private func outgoingOpacity(width: CGFloat) -> Double {
        guard width > 0 else { return 1 }
        let progress = min(1, abs(dragOffset) / width)
        return 1 - 0.45 * progress
    }

    /// One card for any window — board / draft / empty — rendered from
    /// the VM's reconciled fields when displayed, else the always-loaded
    /// `coreBoardsByStart` map (the same source `commitWindow` seeds
    /// from, so the promoted card's data can't disagree).
    @ViewBuilder
    private func card(windowStart start: String, isDisplayed: Bool) -> some View {
        let mapBoard = viewModel.coreBoardsByStart[start]
        let row: Board? = isDisplayed
            ? (viewModel.board ?? viewModel.draftBoard)
            : mapBoard
        let label: String = isDisplayed
            ? viewModel.windowLabel
            : (parseISO8601Date(start).map {
                formatTimeframeLabel(timeframe: timeframe, startDate: $0)
            } ?? "")

        if !viewModel.isLoaded {
            loadingView
        } else if let b = row, b.status != .draft {
            VStack(spacing: 0) {
                BoardPlayView(
                    boardId: b.id,
                    onOpenBoard: onOpenBoard,
                    embedded: true,
                    pagerSwipeActive: swipeEngaged,
                    onResumeDraft: onResumeDraft,
                    onEditModeChange: { editing in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            childEditing = editing
                        }
                    }
                )
                caption
                    .padding(.bottom, 10)
            }
        } else if let draft = row {
            promptCard(
                kicker: boardKicker,
                kickerColor: .risoRed,
                title: draft.name,
                titleColor: .risoInk,
                isDraft: true
            ) {
                CoreBoardSetupPromptView(
                    label: label,
                    isPast: isDisplayed ? viewModel.isPast : false,
                    resumeDraft: true,
                    framed: true,
                    onSetUp: {
                        guard !swipeEngaged else { return }
                        onResumeDraft(draft.id)
                    }
                )
            }
        } else {
            promptCard(
                kicker: boardKicker,
                kickerColor: .risoMuted,
                title: label,
                titleColor: .risoMuted,
                isDraft: false
            ) {
                CoreBoardSetupPromptView(
                    label: label,
                    isPast: isDisplayed ? viewModel.isPast : false,
                    framed: true,
                    onSetUp: {
                        // Swipe-release must never fire the CTA; the wizard
                        // re-snaps the date to window boundaries, so the
                        // exact time of day passed here doesn't matter.
                        guard !swipeEngaged else { return }
                        if let date = parseISO8601Date(start) {
                            onCreateForWindow(timeframe, date)
                        }
                    }
                )
            }
        }
    }

    /// Shared empty/draft card scaffold: title block + 2.5pt dashed ink
    /// frame (radius 14) around the prompt content + the position caption.
    @ViewBuilder
    private func promptCard<Content: View>(
        kicker: String,
        kickerColor: Color,
        title: String,
        titleColor: Color,
        isDraft: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .risoKicker(kickerColor)
                HStack(spacing: 8) {
                    Text(title)
                        .font(.risoHead(24, .extraBold))
                        .tracking(-0.48)
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                    if isDraft {
                        draftBadge
                    }
                    if viewModel.streakCount >= 1 {
                        streakChip
                    }
                }
            }

            VStack(spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        Color.risoInk,
                        style: StrokeStyle(lineWidth: 2.5, dash: [8, 6])
                    )
            )

            caption
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.bottom, 10)
    }

    /// DRAFT pill beside the title (paper2 fill, muted text — matches the
    /// play header's draft status badge vocabulary).
    private var draftBadge: some View {
        Text("DRAFT")
            .font(.risoHead(10, .bold))
            .foregroundStyle(Color.risoMuted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }

    /// Gold flame streak capsule (ink-static content — it sits on gold).
    private var streakChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .bold))
            Text(compactStreakLabel(viewModel.streakCount, timeframe: timeframe))
                .font(.risoHead(11, .bold))
        }
        .foregroundStyle(Color.risoInkStatic)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.risoGold))
        .overlay(Capsule().strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.dense))
        .accessibilityElement()
        .accessibilityLabel("\(viewModel.streakCount) greenlog streak")
    }

    // MARK: - Position caption

    private var caption: some View {
        CoreWindowPositionCaption(
            prevLabel: viewModel.neighborWindowStart(offset: -1).map {
                CoreWindowPicker.captionSideLabel(timeframe: timeframe, windowStart: $0)
            } ?? "",
            nextLabel: viewModel.neighborWindowStart(offset: 1).map {
                CoreWindowPicker.captionSideLabel(timeframe: timeframe, windowStart: $0)
            } ?? "",
            dots: neighborhood,
            isDisabled: childEditing,
            onPrev: { animatedStep(-1) },
            onNext: { animatedStep(1) }
        )
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 6)
    }

    // MARK: - Stepping (swipe + caption)

    /// Step ±1 with the card-slide (or a cross-fade under Reduce Motion).
    private func animatedStep(_ direction: Int) {
        guard !childEditing, !isAnimatingStep else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.step(direction)
            }
            return
        }
        // Programmatic slide: mount the incoming card, animate the pair
        // across, then commit the step and reset offsets.
        incomingDir = direction
        isAnimatingStep = true
        // Read the card width from the main screen — the gesture path
        // passes the live geometry width instead.
        let width = UIScreen.main.bounds.width
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dragOffset = -CGFloat(direction) * (width + Riso.gutter)
        } completion: {
            commitStep(direction)
        }
    }

    /// Land the in-flight slide: commit the window change and reset the
    /// drag state without animation.
    private func commitStep(_ direction: Int) {
        viewModel.step(direction)
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            dragOffset = 0
            incomingDir = 0
        }
        isAnimatingStep = false
    }

    private func swipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard !childEditing, !isAnimatingStep else { return }
                if dragAxis == nil {
                    // Lock the axis on the first significant movement —
                    // vertical drags stay with the embedded scroll view.
                    dragAxis = abs(value.translation.width) > abs(value.translation.height)
                }
                guard dragAxis == true else { return }
                dragOffset = value.translation.width
                incomingDir = value.translation.width < 0 ? 1 : -1
            }
            .onEnded { value in
                let wasHorizontal = dragAxis == true
                dragAxis = nil
                guard wasHorizontal, !childEditing, !isAnimatingStep else { return }

                let velocity = value.velocity.width
                let passedDistance = abs(dragOffset) > width * 0.35
                let passedVelocity = abs(velocity) > 300
                    && (velocity < 0) == (dragOffset < 0)
                let direction = dragOffset < 0 ? 1 : -1

                if passedDistance || passedVelocity {
                    if reduceMotion {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.step(direction)
                        }
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            dragOffset = 0
                            incomingDir = 0
                        }
                    } else {
                        isAnimatingStep = true
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            dragOffset = -CGFloat(direction) * (width + Riso.gutter)
                        } completion: {
                            commitStep(direction)
                        }
                    }
                } else {
                    // Snap back.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        dragOffset = 0
                    } completion: {
                        incomingDir = 0
                    }
                }
            }
    }

    // MARK: - Bits

    /// Kicker text ("MONTHLY BOARD") for the empty/draft title blocks.
    private var boardKicker: String {
        switch timeframe {
        case .daily:   return "DAILY BOARD"
        case .weekly:  return "WEEKLY BOARD"
        case .monthly: return "MONTHLY BOARD"
        case .yearly:  return "YEARLY BOARD"
        case .custom:  return "CUSTOM BOARD"
        case .indefinite: return "ONGOING BOARD"
        }
    }

    private var loadingView: some View {
        ZStack {
            RisoPaperBackground()
            ProgressView()
                .tint(Color.risoInk)
        }
    }
}
