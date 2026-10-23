import SwiftUI

/// Navigation marker for pushing the tutorial board onto the Boards stack.
struct TutorialRoute: Hashable {}

// MARK: - Content (props-only)

/// The tutorial board's screen content (handoff 02): header, intro, progress
/// row, the 3×3 grid and — once the free row is done — the next-step card.
/// Props-only so every state snapshots; `TutorialBoardView` owns the wiring.
struct TutorialBoardContent: View {
    let progress: TutorialProgress
    /// The lesson whose square plays the done pop, with the token that triggers it.
    var popLesson: TutorialLessonID? = nil
    var popToken: Int = 0
    var onBack: () -> Void = {}
    var onTapLesson: (TutorialLessonID) -> Void = { _ in }
    var onGoToBoards: () -> Void = {}
    var onSeePro: () -> Void = {}

    private var done: Int { progress.doneCount }
    private var fraction: Double { Double(done) / Double(TutorialLessonID.total) }

    /// The intro line: swaps once the free row is done.
    private var introLine: String {
        progress.middleRowDone
            ? "The middle row is yours. The other six lessons come with Pro."
            : "Each square is a lesson. Finish the middle row for a Bingo, all nine for a Greenlog."
    }

    /// "Create a task · step 2 of 7" for the lesson left mid-way, else the generic line.
    private var statusLine: String {
        for id in TutorialLessonID.middleRow {
            if case .inProgress(let step) = progress.state(of: id) {
                let info = TutorialCatalog.info(for: id)
                return "\(info.title) · step \(step + 1) of \(info.steps.count)"
            }
        }
        return progress.statusLine(activeLesson: nil, activeStep: nil)
    }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(introLine)
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        progressRow
                        grid
                        if progress.middleRowDone && !progress.isComplete {
                            TutorialFreeRowCard(onGoToBoards: onGoToBoards, onSeePro: onSeePro)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 3) {
                Text("Getting started").risoKicker()
                Text("Learn by playing").risoH2()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(done)/\(TutorialLessonID.total)")
                .font(.risoHead(13, .extraBold))
                .monospacedDigit()
                .foregroundStyle(Color.risoPaper)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(Capsule().fill(progress.isComplete ? Color.risoGreen : Color.risoBlue))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: Progress row

    private var progressRow: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.risoPaper2)
                    Capsule().fill(Color.risoGreen)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            }
            .frame(height: 10)
            Text(statusLine)
                .font(.risoBody(12, .bold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Grid

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Riso.cellGap), count: 3)
        return LazyVGrid(columns: columns, spacing: Riso.cellGap) {
            ForEach(TutorialCatalog.lessons) { info in
                Button { onTapLesson(info.id) } label: {
                    TutorialBoardCell(
                        info: info,
                        state: progress.state(of: info.id),
                        ringed: progress.middleRowDone && info.id.isFree,
                        popToken: popLesson == info.id ? popToken : 0
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Container

/// The Getting Started tutorial board, pushed on the Boards stack. A tap on a
/// free square opens its start sheet (or, mid-lesson, resumes straight into
/// the stage); a Pro square opens its stub sheet. The stage is a full-screen
/// cover over facsimile screens; where it lands on close comes back through
/// `TutorialCoordinator.justCompleted`.
struct TutorialBoardView: View {
    @EnvironmentObject private var coach: TutorialCoordinator

    let onBack: () -> Void
    /// "Go to my boards" — leave the tutorial for the user's Boards tab.
    let onGoToBoards: () -> Void
    /// The tutorial Greenlog's "Start my first board" and the lessons' "Open
    /// Create" / "Start a new board": open the Create tab.
    let onStartFirstBoard: () -> Void
    /// Lesson 1's "Open Tasks": switch to the real Tasks tab.
    var onOpenTasks: () -> Void = {}

    @State private var startLesson: TutorialLessonID?
    /// Start was tapped: the stage opens once the start sheet is gone.
    @State private var pendingStart: TutorialLessonID?
    @State private var stageLesson: TutorialLessonID?
    @State private var proLesson: TutorialLessonID?
    @State private var middleRowWasDone = false
    @State private var popLesson: TutorialLessonID?
    @State private var popToken = 0
    @State private var showBingoToast = false
    @State private var showGreenlog = false

    var body: some View {
        ZStack(alignment: .top) {
            TutorialBoardContent(
                progress: coach.progress,
                popLesson: popLesson,
                popToken: popToken,
                onBack: onBack,
                onTapLesson: open,
                onGoToBoards: onGoToBoards,
                onSeePro: seePro
            )

            if showBingoToast {
                TutorialBingoToast()
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
            }

            if showGreenlog {
                RisoMomentOverlay(
                    kind: .greenlog,
                    replay: MomentPresentation.tutorialGreenlog.replay,
                    cells: MomentPresentation.tutorialGreenlog.cells,
                    boardName: "Getting started",
                    linesCompleted: 8,
                    tutorialButtons: true,
                    onBack: { withAnimation(.easeOut(duration: 0.25)) { showGreenlog = false } },
                    onNewBoard: {
                        showGreenlog = false
                        onStartFirstBoard()
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $startLesson, onDismiss: {
            guard let lesson = pendingStart else { return }
            pendingStart = nil
            if coach.start(lesson) { stageLesson = lesson }
        }) { lesson in
            TutorialStartSheet(
                info: TutorialCatalog.info(for: lesson),
                onStart: { pendingStart = lesson; startLesson = nil },
                onNotNow: { startLesson = nil }
            )
            .presentationDetents([.medium])
        }
        .fullScreenCover(item: $stageLesson, onDismiss: stageDismissed) { lesson in
            TutorialStageView(lesson: lesson)
        }
        .sheet(item: $proLesson) { lesson in
            TutorialProSheet(
                title: TutorialCatalog.info(for: lesson).title,
                onSeePro: seePro,
                onNotNow: { proLesson = nil }
            )
            .presentationDetents([.medium])
        }
        .onAppear { middleRowWasDone = coach.progress.middleRowDone }
        // The stage dismisses itself when the lesson closes; dropping the item
        // here too means a dismissal lost under a nested sheet can't leave a
        // dead cover with no exit.
        .onChange(of: coach.isClosing) { _, closing in
            if closing { stageLesson = nil }
        }
    }

    /// A tap on a square: a Pro square opens the stub; an in-progress free
    /// lesson resumes straight into its stage; any other free lesson shows
    /// its start sheet first.
    private func open(_ id: TutorialLessonID) {
        guard id.isFree else {
            proLesson = id
            return
        }
        middleRowWasDone = coach.progress.middleRowDone
        if case .inProgress = coach.progress.state(of: id) {
            if coach.start(id) { stageLesson = id }
        } else {
            startLesson = id
        }
    }

    /// The paywall entry. No entitlement or paywall exists on dev (monetization
    /// is parked — PR #452), so this does nothing yet.
    private func seePro() {}

    /// Back from a lesson: play the square's pop, then the middle-row Bingo toast
    /// or the all-nine Greenlog when those just completed — or hand off to the
    /// tab the lesson's exit named.
    private func stageDismissed() {
        // Whatever dismissed the cover, a still-running lesson is left (saving its
        // place) and the session is torn down only now.
        coach.stageDidDismiss()
        guard let finished = coach.justCompleted else { return }
        coach.consumeJustCompleted()
        popLesson = finished.lesson
        popToken += 1
        switch finished.exit {
        case .tasks:
            onOpenTasks()
            return
        case .create:
            onStartFirstBoard()
            return
        case .board:
            break
        }
        if coach.progress.isComplete {
            withAnimation(.easeIn(duration: 0.3)) { showGreenlog = true }
        } else if coach.progress.middleRowDone && !middleRowWasDone {
            middleRowWasDone = true
            withAnimation(.spring(duration: 0.35)) { showBingoToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                withAnimation(.easeOut(duration: 0.25)) { showBingoToast = false }
            }
        }
    }
}

extension TutorialLessonID: Identifiable {
    var id: String { rawValue }
}
