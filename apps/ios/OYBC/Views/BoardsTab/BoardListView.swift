import SwiftUI

/// BoardListView — Primary boards tab showing the user's bingo boards.
///
/// Displays a segmented filter (All / Active / Completed / Draft) above a
/// list of `BoardListItemView` rows, each navigating to `BoardPlayView`.
/// Boards are loaded from the local GRDB database on appear and filtered
/// client-side — no network calls.
///
/// Also renders a `CoreBoardsSectionView` whenever any recurring
/// timeframe pref is enabled. Each row is a single tap target →
/// `onBrowseTimeframe` opens the per-timeframe Core Board Browser.
///
/// Phase 6.1d note: the section is mounted **inside** the SwiftUI `List`
/// as a transparent header row (not above it as a sticky element) so the
/// user can scroll past the section to reach the board list below.
struct BoardListView: View {

    // MARK: - Inputs

    /// Cross-tab launch for a non-current window picked in the
    /// core-board browser. MainTabView wires this to set the
    /// `pendingRecurringTimeframe` + `pendingTargetWindowDate` bindings
    /// and flip to the Create tab. Optional for the playground /
    /// #Preview path. Receives the date in local time; the wizard
    /// uses it as the reference for `computeTimeframeBoundaries`.
    var onCreateForWindow: ((Timeframe, Date) -> Void)?

    /// Push the per-timeframe Core Board Browser onto the Boards-tab
    /// navigation stack. MainTabView appends a `CoreBrowserRoute` onto
    /// `boardsPath`. Also the tap target for the Core Boards section's
    /// rows (each row routes through here). Optional so the playground /
    /// #Preview path can leave it nil.
    var onBrowseTimeframe: ((Timeframe) -> Void)?

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var boards: [Board] = []
    // Default to 'active' so the boards a user is currently playing are
    // front-and-center. They can switch to 'all' for drafts / completed /
    // expired boards. Session-local — no UserPreferences persistence.
    @State private var activeFilter: String = "active"
    @State private var loadError: String?
    /// Drives the delete-confirmation alert when the user swipes Delete.
    @State private var boardPendingDelete: Board?
    @State private var deleteError: String?
    @State private var pendingRecurringVM = PendingRecurringBoardsViewModel()
    /// Phase 6.2: drives template-spawn detection + execution on tab open.
    /// Idempotent — repeated mounts after the first successful spawn are
    /// no-ops because `findTemplatesPendingSpawn` filters out templates
    /// whose `lastSpawnedWindowKey` matches the current window.
    @State private var spawnVM = RecurringBoardSpawnViewModel()

    // MARK: - Constants

    private let filters = ["all", "active", "completed", "draft"]

    // MARK: - Derived

    private var filteredBoards: [Board] {
        guard activeFilter != "all" else { return boards }
        return boards.filter { board in
            guard board.status.rawValue == activeFilter else { return false }
            // Expiry-aware: a board whose status is ACTIVE but whose
            // endDate has passed is no longer "active" for the user's
            // purposes. Excluded from the Active tab (still visible
            // under All). Other filters don't apply the expiry check.
            if activeFilter == "active", isBoardExpired(board) {
                return false
            }
            return true
        }
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
            } else if filteredBoards.isEmpty && pendingRecurringVM.slots.isEmpty {
                // True empty state: no boards, no enabled recurring
                // timeframes. Big ContentUnavailableView reads as expected.
                emptyStateView
            } else if filteredBoards.isEmpty {
                // No boards but we have core-board slots to surface — let
                // the section be the entire content in a ScrollView so the
                // user can act on it without an awkward "no boards" graphic
                // below. `.frame(maxHeight: .infinity)` ensures the
                // ScrollView fills the remaining vertical space below the
                // filter picker; without it, on small-screen devices with
                // 4 enabled slots the last card can be obscured by the tab
                // bar / home indicator with no way to scroll to it.
                ScrollView {
                    CoreBoardsSectionView(
                        slots: pendingRecurringVM.slots,
                        onSelect: { slot in
                            // Whole-row tap → per-timeframe browser
                            // (handles Create + Play + adjacent windows).
                            onBrowseTimeframe?(slot.timeframe)
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
                // Phase 6.2: fire any pending template spawns. Idempotent
                // — see VM doc. Reads weekStartDay from the user's
                // preferences (defaults to .monday if the row is absent).
                _Concurrency.Task {
                    // `try?` on `fetchUser(id:)` gives `User??` — flatten + default.
                    // `User.preferences` is a JSON-string column; `decodedPreferences`
                    // parses it (or returns `.defaults` for missing/malformed rows).
                    let user = (try? AppDatabase.shared.fetchUser(id: userId)) ?? nil
                    let weekStartDay = user?.decodedPreferences.weekStartDay ?? .monday
                    await spawnVM.runSpawnPass(userId: userId, weekStartDay: weekStartDay)
                    // Re-load the visible boards after spawn so the new
                    // boards appear without requiring a tab-switch.
                    await MainActor.run { loadBoards() }
                }
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
            if !pendingRecurringVM.slots.isEmpty {
                CoreBoardsSectionView(
                    slots: pendingRecurringVM.slots,
                    onSelect: { slot in
                        // Whole-row tap → per-timeframe browser.
                        onBrowseTimeframe?(slot.timeframe)
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
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        boardPendingDelete = board
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .alert(
            "Delete board?",
            isPresented: Binding(
                get: { boardPendingDelete != nil },
                set: { if !$0 { boardPendingDelete = nil } }
            ),
            presenting: boardPendingDelete
        ) { board in
            Button("Cancel", role: .cancel) { boardPendingDelete = nil }
            Button("Delete", role: .destructive) {
                performDelete(board: board)
            }
        } message: { board in
            Text("“\(board.name)” will be removed. This can't be undone from the app.")
        }
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { message in
            Text(message)
        }
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

    /// Soft-delete the board off the main thread and refresh the list.
    /// On failure, surfaces an error alert; the board stays put so the
    /// user can retry.
    private func performDelete(board: Board) {
        let boardId = board.id
        _Concurrency.Task {
            do {
                try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.deleteBoard(id: boardId)
                }.value
                await MainActor.run {
                    boardPendingDelete = nil
                    loadBoards()
                }
            } catch {
                await MainActor.run {
                    boardPendingDelete = nil
                    deleteError = "Failed to delete: \(error.localizedDescription)"
                }
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
