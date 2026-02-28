import SwiftUI
import GRDB

/// Board Generator Playground
///
/// Lets the user create tasks via the Unified Task Creator and generate a 3×3
/// bingo board from them. The center square is always a FREE space. At least 8
/// tasks are required to generate a board. Tasks are randomly drawn from the
/// playground task pool.
struct BoardGeneratorPlayground: View {

    private let boardSize = 3
    private var centerIndex: Int { CenterSquare.getCenterSquareIndex(gridSize: boardSize) }
    private var tasksNeeded: Int { boardSize * boardSize - 1 } // 8

    @State private var isGeneratingSamples: Bool = false
    @State private var sampleError: String? = nil

    @State private var tasks: [Task] = []

    @State private var boardTaskNames: [String] = []
    @State private var boardGenerated: Bool = false
    @State private var boardKey: Int = 0

    private var canGenerate: Bool { tasks.count >= tasksNeeded }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Create tasks using the task creator below, then generate a 3×3 bingo board from them. The center square is always a free space. You need at least \(tasksNeeded) tasks to generate a board.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Quick seed button
            VStack(alignment: .leading, spacing: 4) {
                Button(isGeneratingSamples ? "Generating…" : "Generate Sample Tasks") {
                    handleGenerateSamples()
                }
                .disabled(isGeneratingSamples)
                .buttonStyle(.bordered)

                if let error = sampleError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Task creation and library via Unified Task Creator
            UnifiedTaskCreatorPlayground()

            Divider()

            // Task count + generate board
            VStack(alignment: .leading, spacing: 8) {
                Text("\(tasks.count) task\(tasks.count != 1 ? "s" : "") available\(!canGenerate ? " — need \(tasksNeeded - tasks.count) more" : "")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Generate Board") {
                    handleGenerateBoard()
                }
                .disabled(!canGenerate)
                .buttonStyle(.borderedProminent)
            }

            // Generated board
            if boardGenerated {
                BingoBoard(
                    taskNames: boardTaskNames,
                    gridSize: boardSize,
                    squareSize: 90,
                    centerSquareType: .free
                )
                .id(boardKey)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            ensurePlaygroundUser()
        }
        .task {
            let observation = ValueObservation.tracking { db in
                try Task
                    .filter(Column("userId") == playgroundUserId && Column("isDeleted") == false)
                    .order(Column("title"))
                    .fetchAll(db)
            }
            do {
                for try await fetched in observation.values(in: AppDatabase.shared.reader) {
                    tasks = fetched
                }
            } catch {
                // Non-fatal in Playground context
            }
        }
    }

    private func handleGenerateSamples() {
        isGeneratingSamples = true
        sampleError = nil
        let titles = generateSampleTaskTitles()
        let now = AppDatabase.currentTimestamp()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for title in titles {
                    let task = Task(
                        id: AppDatabase.generateUUID(),
                        userId: playgroundUserId,
                        title: title,
                        type: .normal,
                        totalCompletions: 0,
                        totalInstances: 0,
                        createdAt: now,
                        updatedAt: now,
                        version: 1,
                        isDeleted: false
                    )
                    try AppDatabase.shared.saveTask(task)
                }
                DispatchQueue.main.async {
                    isGeneratingSamples = false
                }
            } catch {
                DispatchQueue.main.async {
                    sampleError = "Failed to generate sample tasks"
                    isGeneratingSamples = false
                }
            }
        }
    }

    private func handleGenerateBoard() {
        // Shuffle all available tasks, pick 8, insert placeholder at center
        var shuffled = Shuffle.fisherYatesShuffle(tasks.map { $0.title })
        var selected = Array(shuffled.prefix(tasksNeeded))
        selected.insert("", at: centerIndex) // placeholder — center always shows "FREE SPACE"
        boardTaskNames = selected
        boardGenerated = true
        boardKey += 1
    }
}

#Preview {
    ScrollView {
        BoardGeneratorPlayground()
            .padding()
    }
}
