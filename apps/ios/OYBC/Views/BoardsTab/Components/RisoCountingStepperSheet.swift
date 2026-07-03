import SwiftUI

// MARK: - RisoCountingStepperSheet

/// Small sheet (`.presentationDetents([.height(160)])`) that surfaces
/// the counting stepper for a cell tap on a counting-type square.
///
/// Wires directly to the caller's `handleCountingTap` / `handleCountingDecrement`
/// via the `onIncrement` / `onDecrement` closures. The sheet itself carries no
/// write logic.
///
/// P2: `sharedHint` adds an "↔ Shared · also counts on …" line beneath the
/// stepper when the task belongs to a shared-counter group and the group spans
/// other boards. `isLinkedCounter` no longer disables the `−` button — the
/// new `decrementSharedCounter` engine handles shared decrements.
struct RisoCountingStepperSheet: View {

    // MARK: - Data

    let taskTitle: String
    let currentCount: Int
    let maxCount: Int
    let unitText: String
    /// True when this task has `sharedCounterId != nil` (a linked derived counter).
    /// Kept for BoardPlayView routing but no longer disables the `−` button (P2).
    let isLinkedCounter: Bool
    /// Optional "also counts on …" hint shown beneath the stepper for shared-counter
    /// squares. Nil when the task is not in a shared group or has no other boards.
    /// Format (verbatim per spec): "↔ Shared · also counts on {board}" or
    /// "↔ Shared · also counts on {board} + {N} more"
    var sharedHint: String? = nil

    // MARK: - Actions

    var onIncrement: () -> Void = {}
    var onDecrement: () -> Void = {}

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()

            VStack(spacing: 12) {
                // ── Label pill ──
                labelPill

                // ── Stepper row ──
                stepperRow

                // ── Shared hint (P2) ──
                if let hint = sharedHint {
                    Text(hint)
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoBlue)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, Riso.gutter)
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, Riso.gutter)
        }
        // Taller when hint is shown to avoid content clipping.
        .presentationDetents(sharedHint != nil ? [.height(180)] : [.height(140)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.risoPaper)
    }

    // MARK: - Label pill

    private var labelPill: some View {
        Text("\(taskTitle) · \(currentCount)/\(maxCount)\(unitText.isEmpty ? "" : " \(unitText)")")
            .font(.risoHead(13, .bold))
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.risoInk))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - Stepper

    private var stepperRow: some View {
        HStack(spacing: 0) {
            // − button: disabled only when count is 0 (P2: no longer disabled for isLinkedCounter)
            Button {
                onDecrement()
            } label: {
                Text("−")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
            .disabled(currentCount == 0)

            // Value display
            Text("\(currentCount)/\(maxCount)")
                .font(.risoHead(15, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(minWidth: 70)
                .padding(.horizontal, 6)
                .frame(height: 44)
                .overlay(
                    HStack {
                        Rectangle()
                            .fill(Color.risoInk)
                            .frame(width: Riso.Keyline.container)
                        Spacer()
                        Rectangle()
                            .fill(Color.risoInk)
                            .frame(width: Riso.Keyline.container)
                    }
                )

            // + button
            Button {
                onIncrement()
            } label: {
                Text("+")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
        }
        .background(Color.risoPaper2)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        .background(
            Capsule()
                .fill(Color.risoInk)
                .offset(x: Riso.Shadow.button, y: Riso.Shadow.button)
        )
        .fixedSize()
    }
}

// MARK: - Stepper button style (gold flash on press)

private struct StepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.risoGold : Color.clear)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview("Counting stepper sheet") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "10k steps",
                currentCount: 6,
                maxCount: 10,
                unitText: "k",
                isLinkedCounter: false
            )
        }
}

#Preview("Counting stepper sheet — shared hint") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Push-ups",
                currentCount: 20,
                maxCount: 30,
                unitText: "reps",
                isLinkedCounter: false,
                sharedHint: "↔ Shared · also counts on February Fitness"
            )
        }
}

#Preview("Counting stepper sheet — shared hint multi-board") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Push-ups",
                currentCount: 20,
                maxCount: 30,
                unitText: "reps",
                isLinkedCounter: true,
                sharedHint: "↔ Shared · also counts on February Fitness + 2 more"
            )
        }
}
