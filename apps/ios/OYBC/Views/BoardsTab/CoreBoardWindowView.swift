import SwiftUI

/// Per-window core-board pager.
///
/// Renders a `CoreBoardWindowBarView` (prev / label / next / list) above
/// one of three body states:
///
///   - **Loading** (`!viewModel.isLoaded`): Riso-styled `ProgressView` on paper.
///   - **Filled** (`viewModel.board != nil`): embedded `BoardPlayView`
///     (with `embedded: true` so it yields the navigation title to us).
///   - **Empty**: `CoreBoardSetupPromptView` with a lazy Create CTA.
///
/// Prev/next paging is handled in-place (`viewModel.step(±1)`), not via
/// navigation pushes, so the back button always returns to the list.
/// The list button fires `onBrowseTimeframe` to open the full browser.
/// The setup button fires `onCreateForWindow` with the window start Date.
///
/// The surrounding chrome (bar + loading / empty states) is rendered in
/// the Riso design language; the embedded `BoardPlayView` is already Riso
/// (#112) and is left unmodified.
///
/// Mirrors the web `CoreBoardWindowPage` / `CoreBoardWindowView` concept.
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
    /// Open the full browser for `timeframe`. MainTabView appends a
    /// `CoreBrowserRoute` onto `boardsPath`.
    let onBrowseTimeframe: (Timeframe) -> Void
    /// Navigate to an existing board. Forwarded through `BoardPlayView`'s
    /// `onOpenBoard` and also from the task-detail Usage section.
    let onOpenBoard: (String) -> Void

    // MARK: - ViewModel

    @StateObject private var viewModel: CoreBoardWindowViewModel

    // MARK: - Init

    init(
        timeframe: Timeframe,
        seedWindowStart: String,
        userId: String,
        weekStartDay: String,
        onCreateForWindow: @escaping (Timeframe, Date) -> Void,
        onBrowseTimeframe: @escaping (Timeframe) -> Void,
        onOpenBoard: @escaping (String) -> Void
    ) {
        self.timeframe = timeframe
        self.seedWindowStart = seedWindowStart
        self.userId = userId
        self.weekStartDay = weekStartDay
        self.onCreateForWindow = onCreateForWindow
        self.onBrowseTimeframe = onBrowseTimeframe
        self.onOpenBoard = onOpenBoard

        _viewModel = StateObject(wrappedValue: CoreBoardWindowViewModel(
            timeframe: timeframe,
            seedWindowStart: seedWindowStart,
            userId: userId,
            weekStartDay: weekStartDay
        ))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            CoreBoardWindowBarView(
                label: viewModel.windowLabel,
                streakCount: viewModel.streakCount,
                streakTimeframe: timeframe,
                onPrev: { viewModel.step(-1) },
                onNext: { viewModel.step(1) },
                onOpenList: { onBrowseTimeframe(timeframe) }
            )

            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationBarHidden(true)
        .onAppear { viewModel.reload() }
    }

    // MARK: - Body content

    @ViewBuilder
    private var bodyContent: some View {
        if !viewModel.isLoaded {
            loadingView
        } else if let board = viewModel.board {
            BoardPlayView(
                boardId: board.id,
                onOpenBoard: onOpenBoard,
                embedded: true
            )
        } else {
            CoreBoardSetupPromptView(
                label: viewModel.windowLabel,
                isPast: viewModel.isPast,
                onSetUp: {
                    // The wizard re-snaps this date to full window boundaries
                    // via `computeTimeframeBoundaries`, so the exact time of day
                    // passed here doesn't matter. Mirrors `CoreBoardWindowCellView`.
                    if let date = parseISO8601Date(viewModel.windowStart) {
                        onCreateForWindow(timeframe, date)
                    }
                }
            )
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ZStack {
            RisoPaperBackground()
            ProgressView()
                .tint(Color.risoInk)
        }
    }
}
