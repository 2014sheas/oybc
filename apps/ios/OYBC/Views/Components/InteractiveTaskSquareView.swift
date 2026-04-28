import SwiftUI

/// A reusable interactive bingo square that adapts its appearance and behavior to the task type.
///
/// Supports all task types with type-specific visual indicators:
/// - **Normal**: Tap toggles completion. Checkmark overlay when complete.
/// - **Counting**: Tap increments count. Shows "X / max unit" progress bar and a "+1 unit" hint.
/// - **Progress**: Read-only in the grid (steps are managed elsewhere). Shows "X / Y steps" progress bar.
/// - **Compound**: Tap opens the compound detail sheet. Shows operator-aware fill bar and a "C" badge.
///
/// The square is 90 × 90 pt by default (matching the web `InteractiveTaskSquare`) and can be
/// made read-only by omitting `onTap` or setting `isReadOnly = true`.
///
/// - Parameters:
///   - title: Text displayed in the centre of the square.
///   - taskType: Controls appearance and interaction behaviour.
///   - isCompleted: Whether the square is fully complete (green background + checkmark).
///   - currentCount: Current count for counting tasks.
///   - maxCount: Target count for counting tasks.
///   - unit: Unit label for counting tasks (e.g. "pages", "km").
///   - completedSteps: Number of completed steps for progress tasks.
///   - totalSteps: Total number of steps for progress tasks.
///   - compoundOperator: Logical operator for compound tasks (.and / .or / .mOfN).
///   - compoundThreshold: M threshold for .mOfN compound tasks.
///   - compoundChildCount: Total number of active children for compound tasks.
///   - compoundDoneCount: Number of completed children for compound tasks.
///   - onTap: Optional tap handler. When nil the square is not interactive (unless `isReadOnly`
///     is explicitly set). Progress tasks ignore `onTap` from the grid.
///   - isReadOnly: Suppresses tap handling even when `onTap` is provided (used for Board A).
///   - size: Width and height in points (default 90).
struct InteractiveTaskSquareView: View {

    // MARK: - Parameters

    let title: String
    let taskType: TaskType
    let isCompleted: Bool

    // Counting-specific
    var currentCount: Int = 0
    var maxCount: Int = 0
    var unit: String = ""

    // Progress-specific
    var completedSteps: Int = 0
    var totalSteps: Int = 0

    // Compound-specific (only meaningful when taskType == .compound)
    var compoundOperator: OperatorType? = nil
    var compoundThreshold: Int? = nil
    var compoundChildCount: Int = 0
    var compoundDoneCount: Int = 0

    // Interaction
    var onTap: (() -> Void)? = nil
    var isReadOnly: Bool = false

    // Size
    var size: CGFloat = 90

    // MARK: - Local State

    @State private var isPressed: Bool = false

    // MARK: - Derived Properties

    /// Whether a progress bar should be shown at the bottom of the square.
    private var showProgressBar: Bool {
        taskType == .counting || taskType == .progress || taskType == .compound
    }

    /// Fraction (0–1) to fill the progress bar.
    private var fillFraction: Double {
        switch taskType {
        case .normal:
            return isCompleted ? 1.0 : 0.0
        case .counting:
            guard maxCount > 0 else { return 0 }
            return min(Double(currentCount) / Double(maxCount), 1.0)
        case .progress:
            guard totalSteps > 0 else { return 0 }
            return min(Double(completedSteps) / Double(totalSteps), 1.0)
        case .compound:
            if compoundChildCount == 0 { return 0 }
            switch compoundOperator {
            case .or:
                return compoundDoneCount > 0 ? 1.0 : 0.0
            case .mOfN:
                let threshold = compoundThreshold ?? 0
                if threshold == 0 { return 0 }
                return min(Double(compoundDoneCount) / Double(threshold), 1.0)
            case .and, .none:
                return Double(compoundDoneCount) / Double(compoundChildCount)
            }
        }
    }

    /// Accent colour for the progress bar, matching TaskSquareActionsPlayground conventions.
    private var barColor: Color {
        switch taskType {
        case .normal:   return .green
        case .counting: return .orange
        case .progress: return .purple
        case .compound: return Color(red: 0.39, green: 0.4, blue: 0.95)  // indigo, mirrors web's #6366f1
        }
    }

    /// Label text displayed inside the progress bar.
    private var barLabel: String {
        switch taskType {
        case .normal:
            return ""
        case .counting:
            let unitText = unit.isEmpty ? "" : " \(unit)"
            return "\(currentCount)/\(maxCount)\(unitText)"
        case .progress:
            return "\(completedSteps)/\(totalSteps) steps"
        case .compound:
            switch compoundOperator {
            case .or:
                return compoundDoneCount > 0 ? "complete" : "0 of \(compoundChildCount)"
            case .mOfN:
                return "\(compoundDoneCount)/\(compoundThreshold ?? 0)"
            case .and, .none:
                return "\(compoundDoneCount)/\(compoundChildCount)"
            }
        }
    }

    /// Short hint shown below the title for counting tasks before any progress has been made.
    private var actionHintText: String? {
        guard taskType == .counting, !unit.isEmpty, currentCount == 0 else { return nil }
        return "Tap: +1 \(unit)"
    }

    /// Whether tapping the square should trigger the handler.
    private var isTappable: Bool {
        guard !isReadOnly, let _ = onTap else { return false }
        // Progress tasks are not directly actionable from the grid; compound taps open the detail sheet.
        return taskType != .progress
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Background ──
            RoundedRectangle(cornerRadius: 8)
                .fill(isCompleted ? Color.green : Color(.systemGray6))
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCompleted ? Color.green.opacity(0.8) : Color(.systemGray4), lineWidth: 1.5)

            // ── Content ──
            VStack(spacing: 2) {
                Spacer()

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .foregroundColor(isCompleted ? .white : .primary)
                    .padding(.horizontal, 4)

                if let hint = actionHintText {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.7))
                }

                Spacer()

                // Progress bar (counting / progress types only)
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

            // ── Checkmark overlay (top-right corner when complete) ──
            if isCompleted {
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

            // ── Read-only badge (top-left corner for Board A squares) ──
            if isReadOnly {
                VStack {
                    HStack {
                        Image(systemName: "eye")
                            .font(.system(size: 8))
                            .foregroundColor(isCompleted ? Color.white.opacity(0.6) : Color.secondary.opacity(0.5))
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
            }

            // ── "C" badge (top-left corner for compound squares) ──
            if taskType == .compound {
                VStack {
                    HStack {
                        Text("C")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Color(red: 0.39, green: 0.4, blue: 0.95))
                            .clipShape(Circle())
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressed ? 0.93 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        // Tap handling
        .onTapGesture {
            guard isTappable else { return }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            onTap?()
        }
        // Press visual feedback
        .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
            if isTappable { isPressed = pressing }
        }, perform: {})
        // Accessibility
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isTappable ? .isButton : [])
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch taskType {
        case .normal:
            return "\(title) — \(isCompleted ? "completed" : "incomplete")"
        case .counting:
            let unitText = unit.isEmpty ? "" : " \(unit)"
            return "\(title) — \(currentCount) of \(maxCount)\(unitText)"
        case .progress:
            return "\(title) — \(completedSteps) of \(totalSteps) steps completed"
        case .compound:
            switch compoundOperator {
            case .or:
                return "\(title) — compound task, \(compoundDoneCount > 0 ? "complete" : "0 of \(compoundChildCount) children done")"
            case .mOfN:
                return "\(title) — compound task, \(compoundDoneCount) of \(compoundThreshold ?? 0) required children done"
            case .and, .none:
                return "\(title) — compound task, \(compoundDoneCount) of \(compoundChildCount) children done"
            }
        }
    }

    private var accessibilityValue: String {
        isCompleted ? "completed" : "incomplete"
    }
}

// MARK: - Previews

#Preview("Normal — Incomplete") {
    InteractiveTaskSquareView(
        title: "Read a book",
        taskType: .normal,
        isCompleted: false,
        onTap: {}
    )
    .padding()
}

#Preview("Normal — Complete") {
    InteractiveTaskSquareView(
        title: "Meditate",
        taskType: .normal,
        isCompleted: true
    )
    .padding()
}

#Preview("Counting — In Progress") {
    InteractiveTaskSquareView(
        title: "Morning Run",
        taskType: .counting,
        isCompleted: false,
        currentCount: 2,
        maxCount: 5,
        unit: "km",
        onTap: {}
    )
    .padding()
}

#Preview("Counting — Complete") {
    InteractiveTaskSquareView(
        title: "Drink water",
        taskType: .counting,
        isCompleted: true,
        currentCount: 8,
        maxCount: 8,
        unit: "glasses"
    )
    .padding()
}

#Preview("Progress — Partial") {
    InteractiveTaskSquareView(
        title: "Weekly Workout",
        taskType: .progress,
        isCompleted: false,
        completedSteps: 1,
        totalSteps: 3
    )
    .padding()
}

#Preview("Read-Only") {
    InteractiveTaskSquareView(
        title: "Read 100 pages",
        taskType: .counting,
        isCompleted: false,
        currentCount: 40,
        maxCount: 100,
        unit: "pages",
        isReadOnly: true
    )
    .padding()
}

#Preview("Grid Sample") {
    LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(90), spacing: 8), count: 3),
        spacing: 8
    ) {
        InteractiveTaskSquareView(title: "Normal", taskType: .normal, isCompleted: false, onTap: {})
        InteractiveTaskSquareView(title: "Done", taskType: .normal, isCompleted: true)
        InteractiveTaskSquareView(title: "Run 5km", taskType: .counting, isCompleted: false,
                                  currentCount: 0, maxCount: 5, unit: "km", onTap: {})
        InteractiveTaskSquareView(title: "Run 5km", taskType: .counting, isCompleted: false,
                                  currentCount: 3, maxCount: 5, unit: "km", onTap: {})
        InteractiveTaskSquareView(title: "Run 5km", taskType: .counting, isCompleted: true,
                                  currentCount: 5, maxCount: 5, unit: "km")
        InteractiveTaskSquareView(title: "Clean House", taskType: .progress, isCompleted: false,
                                  completedSteps: 2, totalSteps: 3)
    }
    .padding()
}
