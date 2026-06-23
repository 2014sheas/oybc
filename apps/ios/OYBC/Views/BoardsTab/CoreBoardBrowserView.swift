import SwiftUI

/// Hashable route value pushed onto the Boards-tab navigation stack
/// to open the per-timeframe core-board browser. Registered via
/// `.navigationDestination(for: CoreBrowserRoute.self)` in
/// `BoardListView`.
///
/// iOS twin of web's `/boards/core/:timeframe` route.
struct CoreBrowserRoute: Hashable {
    let timeframe: Timeframe
}

/// Per-timeframe core-board browser. Vertical list of calendar
/// windows; filled cells render `RisoBoardCard` inside a
/// `CoreBoardWindowCellView` and tap into `BoardPlayView`, empty cells
/// render a Riso-styled Create CTA that launches the wizard for that
/// window.
///
/// Bidirectional pagination via sentinel `.onAppear` at the top and
/// bottom of the list — first appearance triggers `loadEarlier()` /
/// `loadLater()` on the view-model, prepending or appending another
/// page (10 windows by default).
///
/// Rendered in the Riso design language: `RisoPaperBackground`, Riso
/// kicker + H2 header, paper-gutter spacing. All pagination logic is
/// unchanged from the pre-Riso implementation.
///
/// Mirrors web's `CoreBoardBrowserPage`.
struct CoreBoardBrowserView: View {
    let timeframe: Timeframe
    /// Callback that launches the wizard for a non-current window.
    /// Threaded up from MainTabView so the cross-tab handoff
    /// (`pendingRecurringTimeframe` + `pendingTargetWindowDate`) lives
    /// in one place. Receives `(timeframe, targetWindowDate)`.
    let onCreate: (Timeframe, Date) -> Void
    /// Callback to navigate to an existing board (filled cell tap).
    /// Forwarded from `BoardListView` so the user lands on
    /// `BoardPlayView` via the same boardsPath push the main list uses.
    let onOpenBoard: (String) -> Void
    /// Resume a DRAFT board in the wizard (cross-tab). A draft cell routes
    /// here instead of `onOpenBoard` — drafts are never opened as a playable
    /// board. Defaults to a no-op so existing call sites compile.
    var onResumeDraft: (String) -> Void = { _ in }

    @EnvironmentObject var authService: AuthService
    @State private var vm = CoreBoardBrowserViewModel()

    private var weekStartDay: String {
        authService.userPreferences.weekStartDay.rawValue
    }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            content
        }
        .navigationBarHidden(true)
        .overlay(alignment: .top) {
            if let err = vm.loadError {
                errorBanner(err)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Scrolling page header (not sticky)
                    headerSection
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 16)
                        .padding(.bottom, 14)

                    // Top sentinel — first time it appears, load 10
                    // older windows. SwiftUI fires `.onAppear` each time
                    // the view enters the visible region, so a user that
                    // scrolls back-and-forth keeps growing the past range.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { vm.loadEarlier() }

                    ForEach(vm.cells) { cell in
                        CoreBoardWindowCellView(
                            cell: cell,
                            timeframe: timeframe,
                            onOpenBoard: onOpenBoard,
                            // Cell exposes `(Date, Timeframe)`; the
                            // parent's `onCreate` takes `(Timeframe, Date)`.
                            // Adapt at the call site so both signatures
                            // read naturally in their own contexts.
                            onCreate: { date, tf in onCreate(tf, date) },
                            onResumeDraft: onResumeDraft
                        )
                        .id(cell.windowStart)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 14)
                    }

                    Color.clear
                        .frame(height: 1)
                        .onAppear { vm.loadLater() }

                    // Bottom breathing room
                    Color.clear.frame(height: 20)
                }
            }
            .onAppear {
                if let userId = authService.currentUser?.id {
                    vm.reload(
                        timeframe: timeframe,
                        weekStartDay: weekStartDay,
                        userId: userId
                    )
                    // Scroll-into-view the current window on first
                    // mount so the user lands oriented around "now".
                    // Tiny delay lets LazyVStack materialise the row
                    // before the scroll fires; without it, ScrollView
                    // tries to scroll to an id that isn't rendered yet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if vm.currentIndex >= 0 && vm.currentIndex < vm.cells.count {
                            let target = vm.cells[vm.currentIndex].windowStart
                            withAnimation(nil) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(timeframeTitle) boards")
                    .risoKicker()
                Text(timeframeTitle)
                    .risoH2()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.risoBody(12, .semibold))
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.risoRed)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
            .padding(.top, 12)
            .padding(.horizontal, Riso.gutter)
    }

    // MARK: - Helpers

    private var timeframeTitle: String {
        switch timeframe {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        case .custom:  return "Core" // never reached (route filters CUSTOM)
        }
    }
}
