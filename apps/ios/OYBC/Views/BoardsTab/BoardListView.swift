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
                await MainActor.run {
                    boards = result
                    loadError = nil
                }
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
                // 8 tasks for a 3x3 board with FREE center — mix of all types
                var taskIds: [String] = []
                try AppDatabase.shared.write { db in
                    // Helper to create and insert a task, returning its ID
                    func makeTask(id: String, _ dict: [String: Any]) throws -> String {
                        let data = try JSONSerialization.data(withJSONObject: dict)
                        var task = try JSONDecoder().decode(Task.self, from: data)
                        try task.insert(db)
                        return id
                    }

                    // 4 normal tasks
                    for title in ["Meditate", "Call a friend", "Cook dinner", "Write in journal"] {
                        let id = AppDatabase.generateUUID()
                        taskIds.append(try makeTask(id: id, [
                            "id": id, "userId": userId, "title": title, "type": "normal",
                            "totalCompletions": 0, "totalInstances": 0,
                            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                        ]))
                    }

                    // 2 counting tasks
                    for (title, action, unit, maxCount) in [
                        ("Read 10 pages", "Read", "pages", 10),
                        ("Walk 3 km", "Walk", "km", 3),
                    ] as [(String, String, String, Int)] {
                        let id = AppDatabase.generateUUID()
                        taskIds.append(try makeTask(id: id, [
                            "id": id, "userId": userId, "title": title, "type": "counting",
                            "action": action, "unit": unit, "maxCount": maxCount,
                            "totalCompletions": 0, "totalInstances": 0,
                            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                        ]))
                    }

                    // 2 progress tasks with steps
                    for (title, stepTitles) in [
                        ("Morning Routine", ["Brush teeth", "Stretch", "Breakfast"]),
                        ("Clean House", ["Vacuum", "Dishes"]),
                    ] as [(String, [String])] {
                        let taskId = AppDatabase.generateUUID()
                        taskIds.append(try makeTask(id: taskId, [
                            "id": taskId, "userId": userId, "title": title, "type": "progress",
                            "totalCompletions": 0, "totalInstances": 0,
                            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                        ]))
                        for (i, stepTitle) in stepTitles.enumerated() {
                            let stepId = AppDatabase.generateUUID()
                            // Create standalone task for the step first (FK: linkedTaskId → tasks.id)
                            let linkedTaskId = AppDatabase.generateUUID()
                            let linkedData = try JSONSerialization.data(withJSONObject: [
                                "id": linkedTaskId, "userId": userId, "title": stepTitle, "type": "normal",
                                "totalCompletions": 0, "totalInstances": 0,
                                "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                            ] as [String: Any])
                            var linkedTask = try JSONDecoder().decode(Task.self, from: linkedData)
                            try linkedTask.insert(db)

                            let stepData = try JSONSerialization.data(withJSONObject: [
                                "id": stepId, "taskId": taskId, "stepIndex": i,
                                "title": stepTitle, "type": "normal",
                                "linkedTaskId": linkedTaskId,
                                "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
                            ] as [String: Any])
                            var step = try JSONDecoder().decode(TaskStep.self, from: stepData)
                            try step.insert(db)
                        }
                    }

                    let shuffled = taskIds.shuffled()
                    let boardId = AppDatabase.generateUUID()
                    let boardName = "Demo Board \(Int.random(in: 1...999))"
                    let boardDict: [String: Any] = [
                        "id": boardId, "userId": userId, "name": boardName, "status": "draft",
                        "boardSize": 3, "timeframe": "custom", "startDate": now,
                        "endDate": ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 24 * 60 * 60)),
                        "centerSquareType": "free", "isRandomized": true,
                        "totalTasks": 8, "completedTasks": 0, "linesCompleted": 0,
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
                print("❌ Demo board creation failed: \(error)")
                DispatchQueue.main.async {
                    isCreatingDemo = false
                    loadError = String(describing: error)
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
