import SwiftUI

/// BoardListView — Riso-styled Boards home screen.
///
/// The header (kicker + H1 + core timeframe grid + filter chips) scrolls
/// with the content — it is NOT sticky. Native `List` with `.listStyle(.plain)`
/// provides swipe-to-delete; each row gets `.listRowSeparator(.hidden)` +
/// `.listRowBackground(Color.clear)`.
///
/// Data flow is unchanged from the pre-Riso implementation:
/// - Boards fetched via `loadBoards()` on appear (GRDB, local-first).
/// - `activeFilter` drives `filteredBoards` client-side.
/// - `pendingRecurringVM` (renamed `CoreBoardSlotsViewModel`) provides the
///   current-window slot list for the 2×2 core timeframe grid.
/// - `spawnVM` fires template spawns on tab open (Phase 6.2).
///
/// The + button in the header navigates to the Create flow. Because
/// `BoardListView` has no direct route to the wizard (creation is wired
/// through `MainTabView`), the button fires `onCreateBoard()`, an optional
/// callback that defaults to nil. MainTabView wires it to switch to tab 2.
/// This parallels how `onCreateForWindow` was already wired pre-Riso.
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
    /// navigation stack. Also the fallback for core-card taps when no
    /// current-window board exists yet (lets the user reach the browser
    /// to create one). Optional so the playground / #Preview path can
    /// leave it nil.
    var onBrowseTimeframe: ((Timeframe) -> Void)?

    /// Open the per-window pager for the tapped Core Board slot.
    /// Fired when the user taps a core timeframe card that has a current
    /// board. Optional so the playground / #Preview path can leave it nil.
    var onOpenCoreWindow: ((Timeframe, String) -> Void)? = nil

    /// Switch to the Create tab for a fresh board (no timeframe pre-fill).
    /// Wired by MainTabView to `selectedTab = 2`. Nil in playground / preview.
    var onCreateBoard: (() -> Void)? = nil

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var boards: [Board] = []
    @State private var activeFilter: String = "active"
    @State private var loadError: String?
    @State private var boardPendingDelete: Board?
    @State private var deleteError: String?
    @State private var pendingRecurringVM = PendingRecurringBoardsViewModel()
    @State private var spawnVM = RecurringBoardSpawnViewModel()
    /// User's week-start pref ("monday"/"sunday") for the core grid's local
    /// window-boundary fallback. Loaded in `onAppearLoad`.
    @State private var weekStartDayPref: String = "monday"

    // MARK: - Constants

    private let filters: [(id: String, label: String)] = [
        ("all", "All"),
        ("active", "Active"),
        ("completed", "Completed"),
        ("draft", "Draft"),
    ]

    // MARK: - Derived

    private var filteredBoards: [Board] {
        guard activeFilter != "all" else { return boards }
        return boards.filter { board in
            guard board.status.rawValue == activeFilter else { return false }
            if activeFilter == "active", isBoardExpired(board) { return false }
            return true
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()
            boardContent
        }
        .navigationBarHidden(true)
        .onAppear { onAppearLoad() }
    }

    // MARK: - Content

    @ViewBuilder
    private var boardContent: some View {
        if let loadError {
            errorView(message: loadError)
        } else if filteredBoards.isEmpty && pendingRecurringVM.slots.isEmpty && boards.isEmpty {
            emptyStateList
        } else {
            boardList
        }
    }

    // MARK: - Board list (primary path)

    private var boardList: some View {
        List {
            // ---- Scrolling header (not sticky) ----
            Group {
                headerRow
                    .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                coreGridRow
                    .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                filterChipsRow
                    .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            // ---- Board cards ----
            if filteredBoards.isEmpty {
                emptyFilterRow
                    .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredBoards, id: \.id) { board in
                    NavigationLink(value: board.id) {
                        RisoBoardCard(
                            board: board,
                            timeframeLabel: boardTimeframeLabel(board),
                            isExpiring: isBoardExpiringSoon(board)
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 14, trailing: Riso.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // NOT `role: .destructive`: a destructive swipe button makes
                        // SwiftUI auto-animate the row's removal on tap, but this only
                        // opens the confirm alert (the board isn't deleted yet). The
                        // phantom removal vs. the unchanged data source crashes the
                        // List ("invalid number of items in section"). Plain red button
                        // runs the action; real removal happens after confirm.
                        Button {
                            boardPendingDelete = board
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }

            // Bottom padding
            Color.clear
                .frame(height: 20)
                .listRowInsets(.init())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .alert(
            "Delete board?",
            isPresented: Binding(
                get: { boardPendingDelete != nil },
                set: { if !$0 { boardPendingDelete = nil } }
            ),
            presenting: boardPendingDelete
        ) { board in
            Button("Cancel", role: .cancel) { boardPendingDelete = nil }
            Button("Delete", role: .destructive) { performDelete(board: board) }
        } message: { board in
            Text("\"\(board.name)\" will be removed. This can't be undone from the app.")
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

    // MARK: - Header

    /// Kicker + H1 display headline + gold + button.
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your boards")
                    .risoKicker()
                Text("BINGO,\nbut make it\nyour goals.")
                    .risoH1()
                    .multilineTextAlignment(.leading)
                    .lineSpacing(-2)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RisoIconButton(systemImage: "plus") {
                handleCreateTap()
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    /// 2×2 core timeframe grid.
    private var coreGridRow: some View {
        RisoCoreTimeframeGrid(
            slots: pendingRecurringVM.slots,
            now: Date(),
            weekStartDay: weekStartDayPref,
            streaks: pendingRecurringVM.streaks,
            onSelect: { timeframe, windowStart in
                // If there's a current board for this slot, open the pager.
                // Otherwise open the browser so the user can create or browse.
                let slot = pendingRecurringVM.slots.first(where: { $0.timeframe == timeframe })
                if slot?.currentBoard != nil {
                    onOpenCoreWindow?(timeframe, windowStart)
                } else {
                    onBrowseTimeframe?(timeframe)
                }
            }
        )
        .padding(.bottom, 4)
    }

    /// Filter chips: All / Active / Completed / Draft.
    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(filters, id: \.id) { filter in
                    RisoChip(
                        title: filter.label,
                        isOn: activeFilter == filter.id
                    ) {
                        activeFilter = filter.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.bottom, 14)
    }

    // MARK: - Empty filter state (boards exist but none match filter)

    private var emptyFilterRow: some View {
        VStack(spacing: 12) {
            Text("No \(currentFilterLabel) boards")
                .risoH2()
                .multilineTextAlignment(.center)
            Text("Switch to a different filter to see your boards.")
                .risoSub()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var currentFilterLabel: String {
        filters.first(where: { $0.id == activeFilter })?.label.lowercased() ?? activeFilter
    }

    // MARK: - Empty state (no boards at all)

    /// When there are truly no boards and no slots, render this in a list
    /// so the header + empty-state share the same scroll container.
    private var emptyStateList: some View {
        List {
            headerRow
                .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            coreGridRow
                .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            filterChipsRow
                .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            emptyStateCenteredRow
                .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyStateCenteredRow: some View {
        VStack(spacing: 16) {
            // Blip mascot placeholder — final illustrated asset TBD.
            // Built from shapes using the overprint/halftone language.
            BlipPlaceholder(size: 72, mood: .calm)
                .padding(.bottom, 2)

            Text("Nothing here yet")
                .risoH2()
                .multilineTextAlignment(.center)

            Text("Create your first board to start turning goals into bingo.")
                .risoSub()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            RisoButton(title: "New board", kind: .primary, systemImage: "plus") {
                handleCreateTap()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Error state

    private func errorView(message: String) -> some View {
        ContentUnavailableView(
            "Could Not Load Boards",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }

    // MARK: - Create action

    /// Fires the create-board callback. The production path is `onCreateBoard`
    /// (wired by MainTabView to switch to the Create tab with no pre-fill). The
    /// `onCreateForWindow` fallback covers the playground / preview path where
    /// only that callback is wired — note it *does* pre-fill the current daily
    /// window. If neither callback is wired, the tap is a no-op.
    private func handleCreateTap() {
        if let onCreateBoard {
            onCreateBoard()
            return
        }
        // Fallback (playground/preview): open the wizard pre-filled with the
        // current daily window via onCreateForWindow.
        if let onCreateForWindow,
           let window = computeTimeframeBoundaries(
               timeframe: .daily,
               referenceDate: Date(),
               weekStartDay: weekStartDayPref
           ) {
            onCreateForWindow(.daily, window.start)
        }
    }

    // MARK: - Helpers

    /// Human-readable label for a board's timeframe window (e.g. "This week · 4 days left").
    private func boardTimeframeLabel(_ board: Board) -> String {
        guard let startDate = parseISO8601Date(board.startDate) else {
            return board.timeframe.rawValue.capitalized
        }
        let base = formatTimeframeLabel(timeframe: board.timeframe, startDate: startDate)
        let expiry = getExpiryLabel(board)
        guard board.timeframe != .custom, !expiry.isEmpty, expiry != "No deadline" else {
            return base
        }
        return "\(base) · \(expiry)"
    }

    /// Returns true when the board's end date is within 24 hours of now.
    private func isBoardExpiringSoon(_ board: Board) -> Bool {
        guard board.status == .active,
              board.timeframe != .custom,
              let end = parseISO8601Date(board.endDate) else { return false }
        let hoursLeft = end.timeIntervalSinceNow / 3600
        return hoursLeft >= 0 && hoursLeft < 24
    }

    // MARK: - Data loading

    private func onAppearLoad() {
        loadBoards()
        if let userId = authService.currentUser?.id {
            pendingRecurringVM.reloadAsync(userId: userId)
            _Concurrency.Task {
                let user = (try? AppDatabase.shared.fetchUser(id: userId)) ?? nil
                let weekStartDay = user?.decodedPreferences.weekStartDay ?? .monday
                await MainActor.run { weekStartDayPref = weekStartDay.rawValue }
                await spawnVM.runSpawnPass(userId: userId, weekStartDay: weekStartDay)
                await MainActor.run { loadBoards() }
            }
        }
    }

    /// Fetches non-deleted boards for the current user from the local database.
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

// MARK: - Blip mascot placeholder

/// Shape-based placeholder for the Blip mascot — final illustrated asset TBD.
/// Built from circles/shapes in the overprint/halftone language of the design.
struct BlipPlaceholder: View {
    enum Mood { case calm, happy, cheer }
    var size: CGFloat = 72
    var mood: Mood = .calm

    var body: some View {
        ZStack {
            // Red multiply circle (back layer)
            Circle()
                .fill(Color.risoRed.opacity(0.35))
                .blendMode(.multiply)
                .frame(width: size * 0.9, height: size * 0.9)
                .offset(x: -size * 0.05, y: size * 0.05)

            // Blue circle body (main)
            Circle()
                .fill(Color.risoBlue)
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .strokeBorder(Color.risoInk, lineWidth: 2)
                )

            // Eyes
            HStack(spacing: size * 0.18) {
                Circle()
                    .fill(Color.risoPaper)
                    .frame(width: size * 0.14, height: size * 0.14)
                Circle()
                    .fill(Color.risoPaper)
                    .frame(width: size * 0.14, height: size * 0.14)
            }
            .offset(y: -size * 0.06)

            // Grin / expression
            moodShape
                .offset(y: size * 0.12)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var moodShape: some View {
        switch mood {
        case .calm:
            // Neutral line
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.risoGold)
                .frame(width: size * 0.28, height: size * 0.06)
        case .happy, .cheer:
            // Simple arc grin via capsule
            Capsule()
                .fill(Color.risoGold)
                .frame(width: size * 0.32, height: size * 0.1)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BoardListView()
            .environmentObject(AuthService())
    }
}
