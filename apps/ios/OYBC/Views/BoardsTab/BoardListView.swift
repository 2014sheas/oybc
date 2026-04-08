import SwiftUI

/// BoardListView — Primary boards tab showing the user's bingo boards.
///
/// Displays a segmented filter (All / Active / Completed / Draft) above a
/// list of `BoardListItemView` rows, each navigating to `BoardPlayView`.
/// Boards are loaded from the local GRDB database on appear and filtered
/// client-side — no network calls.
struct BoardListView: View {

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var boards: [Board] = []
    @State private var activeFilter: String = "all"
    @State private var loadError: String?
    @State private var isCreatingDemo: Bool = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SwiftUI.Button {
                    createDemoBoard()
                } label: {
                    Label("Demo Board", systemImage: "plus")
                }
                .disabled(isCreatingDemo)
            }
        }
        .onAppear { loadBoards() }
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
                NavigationLink {
                    BoardPlayView(boardId: board.id)
                } label: {
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
                await MainActor.run { boards = result }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }

    // Temporary demo board creator — will be removed when Create tab is built (Phase 4)
    private func createDemoBoard() {
        guard let userId = authService.currentUser?.id, !isCreatingDemo else { return }
        isCreatingDemo = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let now = AppDatabase.currentTimestamp()
                let taskTitles = ["Meditate", "Call a friend", "Cook dinner", "Write in journal",
                                  "Read a chapter", "Go for a walk", "Try a new recipe", "Clean up", "Stretch"]
                var taskIds: [String] = []
                try AppDatabase.shared.write { db in
                    for title in taskTitles {
                        let id = AppDatabase.generateUUID()
                        let taskDict: [String: Any] = [
                            "id": id, "userId": userId, "title": title, "type": "normal",
                            "totalCompletions": 0, "totalInstances": 0,
                            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                        ]
                        let data = try JSONSerialization.data(withJSONObject: taskDict)
                        var task = try JSONDecoder().decode(Task.self, from: data)
                        try task.save(db)
                        taskIds.append(id)
                    }

                    let shuffled = taskIds.shuffled()
                    let boardId = AppDatabase.generateUUID()
                    let boardName = "Demo Board \(Int.random(in: 1...999))"
                    let boardDict: [String: Any] = [
                        "id": boardId, "userId": userId, "name": boardName, "status": "draft",
                        "boardSize": 3, "timeframe": "custom", "startDate": now, "endDate": now,
                        "centerSquareType": "free", "isRandomized": true,
                        "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
                        "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                    ]
                    let boardData = try JSONSerialization.data(withJSONObject: boardDict)
                    var board = try JSONDecoder().decode(Board.self, from: boardData)
                    try board.save(db)

                    var idx = 0
                    for row in 0..<3 {
                        for col in 0..<3 {
                            if row == 1 && col == 1 { continue }
                            guard idx < shuffled.count else { break }
                            let btId = AppDatabase.generateUUID()
                            let btDict: [String: Any] = [
                                "id": btId, "boardId": boardId, "taskId": shuffled[idx],
                                "row": row, "col": col, "isCenter": false, "isCompleted": false,
                                "currentCount": 0,
                                "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                            ]
                            let btData = try JSONSerialization.data(withJSONObject: btDict)
                            var bt = try JSONDecoder().decode(BoardTask.self, from: btData)
                            try bt.save(db)
                            idx += 1
                        }
                    }
                }
                DispatchQueue.main.async {
                    isCreatingDemo = false
                    loadBoards()
                }
            } catch {
                DispatchQueue.main.async {
                    isCreatingDemo = false
                    loadError = error.localizedDescription
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
