import SwiftUI

/// BoardListView — Primary boards tab showing the user's bingo boards.
///
/// Displays a segmented filter (All / Active / Completed / Draft) above a
/// list of `BoardListItemView` rows, each navigating to `BoardPlayView`.
/// Boards are loaded from the local GRDB database on appear and filtered
/// client-side — no network calls.
///
/// Phase 6.1: also renders a `PendingCoreBoardsSectionView` when the user
/// has recurring board prefs enabled and the current window has no covering
/// board. Tapping a card invokes `onCreateRecurring` (set by MainTabView)
/// which switches to the Create tab with the timeframe prefilled.
///
/// Phase 6.1d note: the section is mounted **inside** the SwiftUI `List`
/// as a transparent header row (not above it as a sticky element) so the
/// user can scroll past the section to reach the board list below — when
/// 4 windows are pending the cards take ~520pt and would otherwise
/// dominate the screen on iPhone-class widths.
struct BoardListView: View {

    // MARK: - Inputs

    /// Invoked when the user taps Create on a recurring-boards banner row.
    /// MainTabView wires this to switch to the Create tab and stash the
    /// timeframe for `CreateHubView` to consume. Optional for the playground
    /// + #Preview path where cross-tab navigation isn't available — the
    /// banner Create button no-ops in that case.
    var onCreateRecurring: ((Timeframe) -> Void)?

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var boards: [Board] = []
    @State private var activeFilter: String = "all"
    @State private var loadError: String?
    @State private var pendingRecurringVM = PendingRecurringBoardsViewModel()

    // MARK: - Constants

    private let filters = ["all", "active", "completed", "draft"]

    // MARK: - Derived

    private var filteredBoards: [Board] {
        guard activeFilter != "all" else { return boards }
        return boards.filter { $0.status.rawValue == activeFilter }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Filter picker stays sticky above the scrolling content (mirrors
            // standard mobile UX — segmented filters at top, content scrolls
            // beneath). The pending-core-boards section is INSIDE the
            // `boardList` List below so it scrolls together with the board
            // rows; previously it lived here in the outer VStack and pinned
            // to the top, dominating the screen when 4 windows were pending.
            filterPicker
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if let loadError {
                errorView(message: loadError)
            } else if filteredBoards.isEmpty && pendingRecurringVM.pending.isEmpty {
                // True empty state: no boards, no pending core windows. Big
                // ContentUnavailableView reads as expected.
                emptyStateView
            } else if filteredBoards.isEmpty {
                // No boards but we have pending core boards to surface — let
                // the section be the entire content in a ScrollView so the
                // user can act on it without an awkward "no boards" graphic
                // below. `.frame(maxHeight: .infinity)` ensures the
                // ScrollView fills the remaining vertical space below the
                // filter picker; without it, on small-screen devices with
                // 4 pending cards the last card can be obscured by the tab
                // bar / home indicator with no way to scroll to it.
                ScrollView {
                    PendingCoreBoardsSectionView(
                        pending: pendingRecurringVM.pending,
                        variant: .boardsTab,
                        onCreate: { entry in
                            onCreateRecurring?(entry.timeframe)
                        }
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                boardList
            }
        }
        .navigationTitle("Boards")
        .onAppear {
            loadBoards()
            // Reload pending recurring boards alongside the board list so the
            // section stays in sync with creates/deletes that happened
            // off-tab. Same pattern as `loadBoards()`.
            if let userId = authService.currentUser?.id {
                pendingRecurringVM.reloadAsync(userId: userId)
            }
        }
    }

    // MARK: - Subviews

    private var filterPicker: some View {
        Picker("Filter", selection: $activeFilter) {
            ForEach(filters, id: \.self) { filter in
                Text(filter.capitalized).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    private var boardList: some View {
        List {
            // Pending core boards section as a transparent List header row
            // so it scrolls together with the board rows. Without
            // `.listRowInsets` the row would inherit List's default 16pt
            // horizontal padding, double-padding the section's own card
            // backgrounds. `.listRowSeparator(.hidden)` removes the divider
            // line that List would otherwise draw between this row and the
            // first board row. `.listRowBackground(Color.clear)` keeps the
            // section's tinted card backgrounds from being washed out by
            // the List's default row background.
            if !pendingRecurringVM.pending.isEmpty {
                PendingCoreBoardsSectionView(
                    pending: pendingRecurringVM.pending,
                    variant: .boardsTab,
                    onCreate: { entry in
                        onCreateRecurring?(entry.timeframe)
                    }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            ForEach(filteredBoards, id: \.id) { board in
                // Value-based NavigationLink so cross-tab callers
                // (CreateHubView.onBoardCompleted) can push onto the
                // Boards tab's path programmatically. The
                // `navigationDestination(for: String.self)` that maps
                // the id to BoardPlayView lives on MainTabView.
                NavigationLink(value: board.id) {
                    BoardListItemView(board: board)
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            boards.isEmpty ? "No Boards Yet" : "No \(activeFilter.capitalized) Boards",
            systemImage: "square.grid.3x3",
            description: Text(
                boards.isEmpty
                ? "Head to the Create tab to build your first board!"
                : "Switch to a different filter to see your boards."
            )
        )
    }

    private func errorView(message: String) -> some View {
        ContentUnavailableView(
            "Could Not Load Boards",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }

    // MARK: - Data Loading

    /// Fetches non-deleted boards for the current user from the local database.
    ///
    /// Runs on a background thread and publishes results back to the main actor.
    /// Any database error is surfaced as a localised string in `loadError`.
    private func loadBoards() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task {
            do {
                let result = try AppDatabase.shared.fetchBoards(userId: userId)
                await MainActor.run {
                    boards = result
                    loadError = nil
                }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }

}

#Preview {
    NavigationStack {
        BoardListView()
            .environmentObject(AuthService())
    }
}
