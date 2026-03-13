import SwiftUI

// MARK: - Supporting Types

/// The type of task a square represents, used to control appearance and interactions.
enum TaskSquareType {
    case normal
    case counting
    case progress
}

/// A step within a progress task, tracking individual completion.
struct PlaygroundStep: Identifiable {
    let id: String
    let label: String
    var isCompleted: Bool = false
}

/// Data describing a single task square in the playground demo grid.
struct TaskSquareData: Identifiable {
    let id: String
    let title: String
    let type: TaskSquareType
    var description: String? = nil
    var action: String? = nil
    var unit: String? = nil
    var maxCount: Int? = nil
    var steps: [PlaygroundStep]? = nil
}

/// Mutable state for a task square (completion progress).
struct SquareState {
    var isCompleted: Bool = false
    var currentCount: Int = 0
    var completedStepIds: Set<String> = []

    /// Whether the square counts as fully complete, factoring in task type.
    func isFullyComplete(for data: TaskSquareData) -> Bool {
        switch data.type {
        case .normal:
            return isCompleted
        case .counting:
            guard let maxVal = data.maxCount else { return isCompleted }
            return currentCount >= maxVal
        case .progress:
            guard let steps = data.steps else { return isCompleted }
            return steps.allSatisfy { completedStepIds.contains($0.id) }
        }
    }
}

// MARK: - Demo Data

private let demoSquares: [TaskSquareData] = [
    TaskSquareData(
        id: "sq-0",
        title: "Morning Run",
        type: .counting,
        action: "Run",
        unit: "km",
        maxCount: 5
    ),
    TaskSquareData(
        id: "sq-1",
        title: "Read a book",
        type: .normal,
        description: "Spend 30 min reading"
    ),
    TaskSquareData(
        id: "sq-2",
        title: "Weekly Workout",
        type: .progress,
        steps: [
            PlaygroundStep(id: "sq-2-s0", label: "Mon strength"),
            PlaygroundStep(id: "sq-2-s1", label: "Wed cardio"),
            PlaygroundStep(id: "sq-2-s2", label: "Fri yoga"),
        ]
    ),
    TaskSquareData(
        id: "sq-3",
        title: "Cook at home",
        type: .normal,
        description: "Prepare a meal from scratch"
    ),
    TaskSquareData(
        id: "sq-4",
        title: "Drink water",
        type: .counting,
        action: "Drink",
        unit: "glasses",
        maxCount: 8
    ),
    TaskSquareData(
        id: "sq-5",
        title: "Meditate",
        type: .normal,
        description: "Sit quietly for 10 min"
    ),
    TaskSquareData(
        id: "sq-6",
        title: "Learn Spanish",
        type: .progress,
        steps: [
            PlaygroundStep(id: "sq-6-s0", label: "Duolingo lesson"),
            PlaygroundStep(id: "sq-6-s1", label: "Vocab review"),
            PlaygroundStep(id: "sq-6-s2", label: "Podcast"),
        ]
    ),
    TaskSquareData(
        id: "sq-7",
        title: "Write in journal",
        type: .normal,
        description: "Reflect on your day"
    ),
    TaskSquareData(
        id: "sq-8",
        title: "Walk the dog",
        type: .counting,
        action: "Walk",
        unit: "km",
        maxCount: 3
    ),
]

// MARK: - Detail Sheet

/// Sheet content showing task details and allowing state modification.
private struct SelectedSquare: Identifiable {
    let id: String
}

private struct TaskDetailSheetContent: View {
    let data: TaskSquareData
    @Binding var state: SquareState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.title)
                        .font(.headline)
                    Text(typeLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            List {
                switch data.type {
                case .normal:
                    // Description section
                    if let desc = data.description {
                        Section("Description") {
                            Text(desc)
                                .foregroundColor(.secondary)
                        }
                    }
                    // Toggle section
                    Section("Completion") {
                        Toggle("Mark Complete", isOn: $state.isCompleted)
                            .tint(.green)
                    }

                case .counting:
                    let maxVal = data.maxCount ?? 1
                    Section("Progress") {
                        ProgressView(
                            value: Double(min(state.currentCount, maxVal)),
                            total: Double(maxVal)
                        )
                        .tint(.orange)
                        .padding(.vertical, 4)

                        Text("\(state.currentCount) / \(maxVal) \(data.unit ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 16) {
                            Button {
                                if state.currentCount > 0 {
                                    state.currentCount -= 1
                                    if state.currentCount < maxVal {
                                        state.isCompleted = false
                                    }
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.title2)
                            }
                            .disabled(state.currentCount == 0)

                            Spacer()

                            Button {
                                if state.currentCount < maxVal {
                                    state.currentCount += 1
                                    if state.currentCount >= maxVal {
                                        state.isCompleted = true
                                    }
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .tint(.orange)
                            }
                            .disabled(state.currentCount >= maxVal)
                        }
                        .buttonStyle(.borderless)
                    }
                    // Complete toggle
                    Section("Completion") {
                        Toggle("Mark Complete", isOn: $state.isCompleted)
                            .tint(.green)
                    }

                case .progress:
                    let allSteps = data.steps ?? []
                    Section("Steps") {
                        ForEach(allSteps) { step in
                            Button {
                                withAnimation {
                                    if state.completedStepIds.contains(step.id) {
                                        state.completedStepIds.remove(step.id)
                                        state.isCompleted = false
                                    } else {
                                        state.completedStepIds.insert(step.id)
                                        if allSteps.allSatisfy({ state.completedStepIds.contains($0.id) }) {
                                            state.isCompleted = true
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: state.completedStepIds.contains(step.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(state.completedStepIds.contains(step.id) ? .green : .secondary)
                                    Text(step.label)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Complete toggle
                    Section("Completion") {
                        Toggle("Mark Complete", isOn: $state.isCompleted)
                            .tint(.green)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .presentationDetents([.medium, .large])
    }

    private var typeLabel: String {
        switch data.type {
        case .normal: return "Normal task"
        case .counting: return "Counting task"
        case .progress: return "Progress task"
        }
    }
}

// MARK: - TaskBingoSquareView

/// A single 80pt bingo square that renders differently based on task type.
/// Tap to act, long-press for context menu with type-specific actions.
private struct TaskBingoSquareView: View {
    let data: TaskSquareData
    @Binding var state: SquareState
    let onTapBody: () -> Void
    let onShowDetail: () -> Void

    @State private var isPressed: Bool = false

    private var isComplete: Bool { state.isFullyComplete(for: data) }

    private var fillFraction: Double {
        switch data.type {
        case .normal:
            return isComplete ? 1.0 : 0.0
        case .counting:
            guard let maxVal = data.maxCount, maxVal > 0 else { return 0 }
            return min(Double(state.currentCount) / Double(maxVal), 1.0)
        case .progress:
            guard let steps = data.steps, !steps.isEmpty else { return 0 }
            return min(Double(state.completedStepIds.count) / Double(steps.count), 1.0)
        }
    }

    private var barColor: Color {
        switch data.type {
        case .normal: return .green
        case .counting: return .orange
        case .progress: return .purple
        }
    }

    private var barLabel: String {
        switch data.type {
        case .normal: return ""
        case .counting:
            let maxVal = data.maxCount ?? 0
            let unit = data.unit ?? ""
            return unit.isEmpty ? "\(state.currentCount)/\(maxVal)" : "\(state.currentCount)/\(maxVal) \(unit)"
        case .progress:
            let steps = data.steps ?? []
            return "\(state.completedStepIds.count)/\(steps.count) steps"
        }
    }

    private var actionHintText: String? {
        guard data.type == .counting, let unit = data.unit else { return nil }
        return "Tap: +1 \(unit)"
    }

    private var showProgressBar: Bool {
        data.type == .counting || data.type == .progress
    }

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(isComplete ? Color.green : Color(.systemBackground))
            RoundedRectangle(cornerRadius: 8)
                .stroke(isComplete ? Color.green : Color(.systemGray4), lineWidth: 1.5)

            // Content
            VStack(spacing: 2) {
                Spacer()

                Text(data.title)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .foregroundColor(isComplete ? .white : .primary)
                    .padding(.horizontal, 4)

                if let hint = actionHintText, state.currentCount == 0 {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.7))
                }

                Spacer()

                // Progress bar (counting/progress only)
                if showProgressBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.2))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor)
                                .frame(width: geo.size.width * fillFraction)
                            Text(barLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 14)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }

            // Checkmark (top-right, visible when complete)
            if isComplete {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.3))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(4)
            }
        }
        .frame(width: 80, height: 80)
        .scaleEffect(isPressed ? 0.93 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onTapGesture {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            onTapBody()
        }
        .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .contextMenu {
            contextMenuItems(for: data, state: $state, isComplete: isComplete, onShowDetail: onShowDetail)
        }
    }

    /// Builds context menu items appropriate for the task type.
    @ViewBuilder
    private func contextMenuItems(
        for data: TaskSquareData,
        state: Binding<SquareState>,
        isComplete: Bool,
        onShowDetail: @escaping () -> Void
    ) -> some View {
        switch data.type {
        case .normal:
            Button(isComplete ? "Mark Incomplete" : "Mark Complete", systemImage: "checkmark.circle") {
                withAnimation { state.wrappedValue.isCompleted.toggle() }
            }
            Button("View Details", systemImage: "info.circle") {
                onShowDetail()
            }

        case .counting:
            let maxVal = data.maxCount ?? 1
            let actionLabel = data.action ?? "item"
            Button("+ Add \(actionLabel)", systemImage: "plus") {
                withAnimation {
                    if state.wrappedValue.currentCount < maxVal {
                        state.wrappedValue.currentCount += 1
                        if state.wrappedValue.currentCount >= maxVal {
                            state.wrappedValue.isCompleted = true
                        }
                    }
                }
            }
            Button("- Remove \(actionLabel)", systemImage: "minus") {
                withAnimation {
                    if state.wrappedValue.currentCount > 0 {
                        state.wrappedValue.currentCount -= 1
                        if state.wrappedValue.currentCount < maxVal {
                            state.wrappedValue.isCompleted = false
                        }
                    }
                }
            }
            .disabled(state.wrappedValue.currentCount == 0)
            Button("Reset", systemImage: "arrow.counterclockwise") {
                withAnimation {
                    state.wrappedValue.currentCount = 0
                    state.wrappedValue.isCompleted = false
                }
            }
            .disabled(state.wrappedValue.currentCount == 0)
            Button("View Details", systemImage: "info.circle") {
                onShowDetail()
            }

        case .progress:
            let steps = data.steps ?? []
            Button("View Steps", systemImage: "list.bullet") {
                onShowDetail()
            }
            Button("Mark All Complete", systemImage: "checkmark.circle.fill") {
                withAnimation {
                    steps.forEach { state.wrappedValue.completedStepIds.insert($0.id) }
                    state.wrappedValue.isCompleted = true
                }
            }
            .disabled(isComplete)
            Button("Mark Incomplete", systemImage: "xmark.circle") {
                withAnimation {
                    state.wrappedValue.completedStepIds.removeAll()
                    state.wrappedValue.isCompleted = false
                }
            }
            .disabled(!isComplete)
            Button("View Details", systemImage: "info.circle") {
                onShowDetail()
            }
        }
    }
}

// MARK: - TaskSquareActionsPlayground

/// Playground section demonstrating the "Act + Context Menu" interaction model.
///
/// Presents a 3x3 grid of mixed task types (normal, counting, progress).
/// Tap to perform the primary action. Long-press for a context menu with
/// type-specific quick actions and a "View Details" option.
struct TaskSquareActionsPlayground: View {

    @State private var squareStates: [String: SquareState] = {
        var states: [String: SquareState] = [:]
        demoSquares.forEach { states[$0.id] = SquareState() }
        return states
    }()
    @State private var selectedSquare: SelectedSquare? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description
            Text("Tap a square to perform its primary action. Long-press for a context menu with type-specific quick actions and details.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Gesture hint
            Text("Tap to act · Long-press for quick options")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()

            // 3x3 grid
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(80), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(demoSquares) { square in
                    let state = Binding<SquareState>(
                        get: { squareStates[square.id] ?? SquareState() },
                        set: { squareStates[square.id] = $0 }
                    )
                    TaskBingoSquareView(
                        data: square,
                        state: state,
                        onTapBody: {
                            handleTapBody(for: square, state: state)
                        },
                        onShowDetail: {
                            selectedSquare = SelectedSquare(id: square.id)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity)

            // Reset button
            Button("Reset All") {
                withAnimation {
                    demoSquares.forEach { squareStates[$0.id] = SquareState() }
                }
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .sheet(item: $selectedSquare) { selected in
            if let squareData = demoSquares.first(where: { $0.id == selected.id }) {
                let state = Binding<SquareState>(
                    get: { squareStates[squareData.id] ?? SquareState() },
                    set: { squareStates[squareData.id] = $0 }
                )
                TaskDetailSheetContent(data: squareData, state: state)
            }
        }
    }

    // MARK: - Helpers

    /// Handles the primary tap-to-act interaction for a given square.
    private func handleTapBody(for square: TaskSquareData, state: Binding<SquareState>) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch square.type {
            case .normal:
                state.wrappedValue.isCompleted.toggle()

            case .counting:
                let maxVal = square.maxCount ?? 1
                if state.wrappedValue.currentCount < maxVal {
                    state.wrappedValue.currentCount += 1
                    if state.wrappedValue.currentCount >= maxVal {
                        state.wrappedValue.isCompleted = true
                    }
                }
                // Already at max — no-op (use detail sheet to decrement)

            case .progress:
                // Tap opens detail sheet so user can act on individual steps
                selectedSquare = SelectedSquare(id: square.id)
            }
        }
    }

}

#Preview {
    ScrollView {
        TaskSquareActionsPlayground()
            .padding()
    }
}
