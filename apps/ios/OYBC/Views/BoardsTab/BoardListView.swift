import SwiftUI

/// BoardListView — Primary boards tab showing the user's bingo boards.
///
/// Displays a segmented filter (All / Active / Completed / Draft) above a
/// list of `BoardListItemView` rows, each navigating to `BoardPlayView`.
/// Boards are loaded from the local GRDB database on appear and filtered
/// client-side — no network calls.
///
/// Phase 6.1: also renders a `RecurringBoardsBannerView` above the filter
/// row when the user has recurring board prefs enabled and the current
/// window has no covering board. Tapping a banner row invokes
/// `onCreateRecurring` (set by MainTabView) which switches to the Create
/// tab with the timeframe prefilled.
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
            if !pendingRecurringVM.pending.isEmpty {
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

            filterPicker
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if let loadError {
                errorView(message: loadError)
            } else if filteredBoards.isEmpty {
                emptyStateView
            } else {
                boardList
            }
        }
        .navigationTitle("Boards")
        .onAppear {
            loadBoards()
            // Reload pending recurring boards alongside the board list so
            // the banner stays in sync with creates/deletes that happened
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
