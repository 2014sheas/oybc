import SwiftUI

/// Feature item structure for collapsible sections
struct Feature: Identifiable {
    let id: String
    let title: String
    let content: AnyView
}

// MARK: - Task Creation Playground

/// NORMAL Task Creation form and task list for Playground testing.
///
/// Allows creating NORMAL tasks with title and optional description,
/// validates input, persists to local database, and displays created tasks.
struct TaskCreationPlayground: View {
    @State private var title = ""
    @State private var taskDescription = ""
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var tasks: [Task] = []
    @FocusState private var focusedField: TaskField?

    enum TaskField { case title, description }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // -- Creation Form --
            VStack(alignment: .leading, spacing: 12) {
                // Title field
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Task Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .description }
                    Text("\(title.count)/200")
                        .font(.caption)
                        .foregroundColor(title.count > 200 ? .red : .secondary)
                }

                // Description field
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Task Description", text: $taskDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .description)
                        .lineLimit(5...)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    Text("\(taskDescription.count)/1000")
                        .font(.caption)
                        .foregroundColor(taskDescription.count > 1000 ? .red : .secondary)
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Success message
                if showSuccess {
                    Text("Task created!")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Create button
                Button("Create Task") {
                    handleCreateTask()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            // -- Task List --
            VStack(alignment: .leading, spacing: 8) {
                if tasks.isEmpty {
                    Text("No tasks created yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(tasks, id: \.id) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(task.title)
                                    .font(.headline)
                                Spacer()
                                Text("NORMAL")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            if let desc = task.description {
                                Text(desc)
                                    .font(.body)
                            }
                            Text("Created: \(formatDate(task.createdAt))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadTasks()
        }
    }

    // MARK: - Actions

    /// Validates input and creates a NORMAL task in the local database.
    ///
    /// Database write is dispatched to a background thread to avoid blocking the main thread.
    /// UI state updates are dispatched back to the main thread after the write completes.
    private func handleCreateTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        guard !trimmedTitle.isEmpty else {
            errorMessage = "Title is required"
            return
        }
        guard title.count <= 200 else {
            errorMessage = "Title must be 200 characters or less"
            return
        }
        guard taskDescription.count <= 1000 else {
            errorMessage = "Description must be 1000 characters or less"
            return
        }

        errorMessage = nil

        let newTask = Task(
            id: AppDatabase.generateUUID(),
            userId: "playground-user-1",
            title: trimmedTitle,
            description: taskDescription.isEmpty ? nil : taskDescription,
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: AppDatabase.currentTimestamp(),
            updatedAt: AppDatabase.currentTimestamp(),
            version: 1,
            isDeleted: false
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.saveTask(newTask)
                DispatchQueue.main.async {
                    self.title = ""
                    self.taskDescription = ""
                    self.showSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.showSuccess = false
                    }
                    self.loadTasks()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to create task: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Ensures the playground user exists in the users table (required by FK constraint on tasks).
    private func ensurePlaygroundUser() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if try AppDatabase.shared.fetchUser(id: "playground-user-1") == nil {
                    let user = User(
                        id: "playground-user-1",
                        email: "playground@oybc.local",
                        displayName: "Playground User",
                        photoURL: nil,
                        createdAt: AppDatabase.currentTimestamp(),
                        updatedAt: AppDatabase.currentTimestamp(),
                        lastSyncedAt: nil,
                        version: 1
                    )
                    try AppDatabase.shared.saveUser(user)
                }
            } catch {
                // Non-fatal: surface error so tasks will fail visibly rather than silently
                DispatchQueue.main.async {
                    self.errorMessage = "Setup error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads all non-deleted tasks for the playground user from the local database.
    private func loadTasks() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: "playground-user-1")
                DispatchQueue.main.async {
                    self.tasks = fetched
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load tasks"
                }
            }
        }
    }

    /// Formats an ISO8601 string into a medium-style date with time for display.
    ///
    /// - Parameter iso: An ISO8601 date string.
    /// - Returns: A human-readable date string with time, or the original string if parsing fails.
    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

/// Playground View
///
/// A dedicated space for testing new features before integrating them into the main app.
/// Features are displayed in collapsible sections using DisclosureGroup.
struct PlaygroundView: View {
    /// Features under test - new features will be added here (newest first)
    private let features: [Feature] = [
        Feature(
            id: "task-creation",
            title: "NORMAL Task Creation",
            content: AnyView(TaskCreationPlayground())
        ),
        Feature(
            id: "center-space-free",
            title: "Center Space: True Free Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is auto-completed, shows \"FREE SPACE\", locked (cannot toggle off), counts toward bingo.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .free)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-custom-free",
            title: "Center Space: Customizable Free Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is auto-completed with custom text, locked, counts toward bingo.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .customFree, centerSquareCustomName: "My Goal!")
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-chosen",
            title: "Center Space: User-Chosen Center (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center has a fixed task (e.g., \"My Special Task\"), NOT auto-completed, can toggle like any square.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .chosen)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-none",
            title: "Center Space: No Center Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is an ordinary square, no special treatment.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .none)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-3x3",
            title: "Center Space: Works on 3x3 Too!",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("True Free Space works on smaller odd-sized boards (center is index 4 on 3x3).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 3, squareSize: 80, centerSquareType: .free)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-square",
            title: "Bingo Square",
            content: AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    Text("A single bingo board square that toggles between incomplete and completed states. Tap to toggle.")
                        .font(.body)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading) {
                            BingoSquare()
                            Text("Default (100pt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading) {
                            BingoSquare(size: 150)
                            Text("Large (150pt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading) {
                            BingoSquare(initialCompleted: true)
                            Text("Initially Completed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            )
        ),
        Feature(
            id: "bingo-board",
            title: "5x5 Bingo Board Grid",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 5x5 bingo board grid with 25 toggleable squares. The center square (Task 13) has special styling with an orange border and star marker.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-board-3x3",
            title: "3x3 Mini Board",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A compact 3x3 mini bingo board with 9 toggleable squares. The center square (Task 5) has special styling.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 3, squareSize: 80)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-board-4x4",
            title: "4x4 Standard Board",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 4x4 standard bingo board with 16 toggleable squares. Even-sized grids have no center square.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 4, squareSize: 70)
                        .frame(maxWidth: .infinity)
                }
            )
        )
    ]

    @State private var expandedFeatureIds: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Feature Playground")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Isolated space for testing features before integrating them into the main app.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 8)

                    // Features — plain state-driven expand/collapse, no DisclosureGroup gesture overhead
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Features Under Test")
                            .font(.title2)
                            .fontWeight(.semibold)

                        ForEach(features) { feature in
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    if expandedFeatureIds.contains(feature.id) {
                                        expandedFeatureIds.remove(feature.id)
                                    } else {
                                        expandedFeatureIds.insert(feature.id)
                                    }
                                } label: {
                                    HStack {
                                        Text(feature.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: expandedFeatureIds.contains(feature.id) ? "chevron.up" : "chevron.down")
                                            .foregroundColor(.secondary)
                                            .font(.subheadline)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if expandedFeatureIds.contains(feature.id) {
                                    feature.content
                                        .padding(.top, 4)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 8)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray6))
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Playground")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaygroundView()
    }
}
